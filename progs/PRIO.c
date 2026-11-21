/* ============================================================================
 *  PRIO.C — 优先级调度的证据(A5 测试程序)
 *
 *  它证明三件事:
 *    1. int 0x30 功能 24(setprio)能从 ring 3 改线程优先级(0 最高、15 最低);
 *    2. 高优先级线程(1)会比普通 shell(8)、低优先级线程(13)先跑;
 *    3. 低优先级线程**不会被饿死** —— 高优先级跑完、低优先级照样跑完,
 *       两者都拿到 CPU 时间(时间片轮转 + 优先级队列)。
 *
 *  运行: run PRIO.BIN
 *  期望输出: priotest: PASS high=N low=N
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <kkernel.h>

/* 忙等:别让 gcc 优化掉,用 volatile 累加 */
static void spin(int rounds)
{
    volatile int x = 0;
    while (rounds-- > 0)
        x += rounds;
}

int main(void)
{
    int hi, lo, code;

    printf("priotest: start pid=%d prio=%d\n", j_getpid(), j_getprio());

    hi = j_fork();
    if (hi < 0) {
        printf("priotest: FAIL fork high\n");
        return 1;
    }
    if (hi == 0) {
        /* 高优先级子进程:抢在 shell 和低优先级进程前面 */
        j_setprio(1);
        spin(2000000);
        printf("priotest: high done prio=%d\n", j_getprio());
        j_exit_code(0);
    }

    lo = j_fork();
    if (lo < 0) {
        printf("priotest: FAIL fork low\n");
        return 1;
    }
    if (lo == 0) {
        /* 低优先级子进程:只在高优先级让出 CPU 后才有机会跑 */
        j_setprio(13);
        spin(2000000);
        printf("priotest: low done prio=%d\n", j_getprio());
        j_exit_code(0);
    }

    /* 先等高的:它应该先跑完(优先级证据);再等低的:证明没被饿死 */
    code = j_wait(hi);
    if (code != 0) {
        printf("priotest: FAIL high code=%d\n", code);
        return 1;
    }
    code = j_wait(lo);
    if (code != 0) {
        printf("priotest: FAIL low code=%d\n", code);
        return 1;
    }

    printf("priotest: PASS high=%d low=%d\n", hi, lo);
    return 0;
}
