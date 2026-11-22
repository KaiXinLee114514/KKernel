/* ============================================================================
 *  RACEWAIT.C — wait 竞态压力测试(Phase D wait-race)
 *
 *  测试里会同时起两个实例(`run RACEWAIT.BIN &` 两次),各自:
 *    循环 50 轮:fork 一个子进程,子进程 exit(期望码),父进程 j_wait(pid) 拿回
 *    退出码并校验"拿到的正好是我这一轮写下去的那个";任何一个不对就 FAIL。
 *
 *  两个实例的父进程会**同时卡在 process_wait2 里睡觉** —— 如果 wait 的睡眠状态
 *  (pw_tcb/pw_sleeping)或事件出参(proc_wait_XXX / proc_last_XXX)还是跨线程全局,
 *  它们会互相覆盖:收错尸、拿到别的作业的退出码、甚至对已经清掉的 TCB 再收尸。
 *  修好后每个线程只读自己内核栈帧 / 自己 TCB 上的字段,互不干扰。
 *
 *  另外,两个实例用不同的退出码区间(按自己的 pid 分组),交叉串码会被立刻抓到。
 *
 *  期望输出(两台各一行):
 *      racewait: PASS pid=N rounds=50
 *  失败:
 *      racewait: BAD  pid=N round=i want=W got=G   (某一轮退出码不对)
 *      racewait: FAIL pid=N fail=K
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <kkernel.h>

#define ROUNDS 50

int main(void)
{
    int me, i, pid, code, want, fail = 0;

    me = j_getpid();
    printf("racewait: start pid=%d rounds=%d\n", me, ROUNDS);

    for (i = 0; i < ROUNDS; i++) {
        /* 两台进程的退出码区间错开:交叉收尸/拿错码时几乎一定对不上 */
        want = (me & 3) * 60 + i + 1;
        pid = j_fork();
        if (pid < 0) {
            printf("racewait: FAIL pid=%d round=%d fork=%d\n", me, i, pid);
            return 1;
        }
        if (pid == 0)
            j_exit_code(want);          /* 子进程:带着期望码退出 */

        code = j_wait(pid);             /* 父进程:睡在 wait 上,等这一轮的孩子 */
        if (code != want) {
            fail++;
            printf("racewait: BAD pid=%d round=%d want=%d got=%d\n",
                   me, i, want, code);
            if (fail > 3)
                break;
        }
    }

    if (fail) {
        printf("racewait: FAIL pid=%d fail=%d\n", me, fail);
        return 1;
    }
    printf("racewait: PASS pid=%d rounds=%d\n", me, ROUNDS);
    return 0;
}
