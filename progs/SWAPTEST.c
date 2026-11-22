/* ============================================================================
 *  SWAPTEST.C — swap(页换出/换入)的证据程序(Phase C 测试)
 *
 *  证明三件事:
 *    1. 程序能通过 int 0x30 功能 31(anon_alloc)申请**远大于物理页池**的匿名
 *       内存,逐页写/读都正确 —— 物理页不够时内核把冷页换出到 swap 区,
 *       程序完全无感;
 *    2. fork 出来的多个进程各自申请内存时也正确(跨进程的换出/换入);
 *    3. 程序退出后 shell 里 `swap`/`meminfo` 能看到 swap 占用回落到 0。
 *
 *  运行: make test-swap
 *        (-m 16:物理页池空闲只有 ~5.7 MiB,会触发 swap;
 *         -m 64:对照,全部驻留,swapout 保持 0)
 *
 *  说明:QEMU/TCG 下 ATA PIO 写一个 4 KiB 页要 ~20 ms 量级,所以程序
 *  "写一页马上校验"省掉一整轮换入换出,最后只抽样(每 SAMPLE_STEP 页)
 *  重读一遍,专门验证"页被换出后再读回来数据仍然正确"。这样 -m16 一轮
 *  大约 1 分钟,交互上等得起,同时覆盖换出+换入两个方向。
 *
 *  期望输出: swaptest: PASS size=... children=2
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <kkernel.h>

#define BIG_MB      8                   /* 主程序申请 8 MiB(-m16 空闲页池约 5.7 MiB) */
#define CHILD_MB    2                   /* 每个子进程再申请 2 MiB */
#define SAMPLE_STEP 8                   /* 第二阶段每 8 页抽查一页(换入往返) */

static unsigned char *mem;
static int size_kb;

/* 页 i 的填充值:每页不同,能抓出"换错页/丢页" */
static unsigned char pat(int page, int off)
{
    return (unsigned char)((page * 31 + off * 7 + 0x5A) ^ (page >> 8));
}

/* 逐页"写一页、立刻校验这一页"——这一轮触发换出(物理页不够时) */
static int fill_and_check(int bytes)
{
    int pages = bytes / 4096;
    int i, off;

    for (i = 0; i < pages; i++) {
        for (off = 0; off < 4096; off += 256)
            mem[i * 4096 + off] = pat(i, off);
        for (off = 0; off < 4096; off += 256)
            if (mem[i * 4096 + off] != pat(i, off)) {
                printf("swaptest: FAIL page=%d off=%d got=%x want=%x\n",
                       i, off, mem[i * 4096 + off], pat(i, off));
                return -1;
            }
    }
    return 0;
}

/* 第二阶段:抽样重读。抽到的页多半已被换出 → 走缺页换入路径 */
static int sample_check(int bytes)
{
    int pages = bytes / 4096;
    int i, off;

    for (i = 0; i < pages; i += SAMPLE_STEP) {
        for (off = 0; off < 4096; off += 256)
            if (mem[i * 4096 + off] != pat(i, off)) {
                printf("swaptest: FAIL page=%d off=%d got=%x want=%x\n",
                       i, off, mem[i * 4096 + off], pat(i, off));
                return -1;
            }
    }
    return 0;
}

static int child_job(int idx)
{
    unsigned char *c = (unsigned char *)j_anon_alloc(CHILD_MB * 1024 * 1024);
    if (!c) {
        printf("swaptest: FAIL child %d anon_alloc\n", idx);
        j_exit_code(1);
        return 1;
    }
    mem = c;
    if (fill_and_check(CHILD_MB * 1024 * 1024) != 0) {
        printf("swaptest: FAIL child %d verify\n", idx);
        j_exit_code(1);
        return 1;
    }
    printf("swaptest: child %d ok (%d MiB)\n", idx, CHILD_MB);
    j_exit_code(0);
    return 0;
}

int main(void)
{
    int child[2];
    int i, code;

    size_kb = BIG_MB * 1024;
    mem = (unsigned char *)j_anon_alloc(BIG_MB * 1024 * 1024);
    if (!mem) {
        printf("swaptest: FAIL anon_alloc %d MiB\n", BIG_MB);
        return 1;
    }
    printf("swaptest: start anon=%x size=%d\n", (unsigned)mem, BIG_MB * 1024 * 1024);

    if (fill_and_check(BIG_MB * 1024 * 1024) != 0)
        return 1;
    printf("swaptest: phase1 fill+verify ok (%d MiB)\n", BIG_MB);

    /* 主进程的大块内存留着(变成"冷页"),让子进程把剩下的物理页吃掉。 */
    for (i = 0; i < 2; i++) {
        child[i] = j_fork();
        if (child[i] < 0) {
            printf("swaptest: FAIL fork %d\n", i);
            return 1;
        }
        if (child[i] == 0) {
            child_job(i);
        }
    }
    for (i = 0; i < 2; i++) {
        code = j_wait(child[i]);
        if (code != 0) {
            printf("swaptest: FAIL child %d code=%d\n", i, code);
            return 1;
        }
    }

    /* 子进程都退了,抽样重读自己的大块内存 —— 抽到的冷页可能刚被换出,
     * 这次读会触发缺页换入,数据必须原样回来。 */
    if (sample_check(BIG_MB * 1024 * 1024) != 0)
        return 1;
    printf("swaptest: phase2 sample verify ok\n");

    printf("swaptest: PASS size=%d children=2\n", BIG_MB * 1024 * 1024);
    return 0;
}
