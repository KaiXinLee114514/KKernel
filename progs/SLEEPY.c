/* ============================================================================
 *  SLEEPY.C — 睡眠 / 唤醒 / 超时的证据(A5 测试程序)
 *
 *  它证明:
 *    1. 子进程可以用 j_sleep(ms)主动睡眠,内核把它挂起(不是忙等!),
 *    2. 子进程醒来后继续跑,exit(7) 把退出码交给父进程;
 *    3. 父进程 j_wait 会睡眠等子进程(不是空转),收回退出码 7;
 *    4. 没有子进程时 j_wait(-1) 立刻返回 -1(没有可收的僵尸)。
 *
 *  运行: run SLEEPY.BIN
 *  期望输出: sleepytest: PASS child=N code=7
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <kkernel.h>

int main(void)
{
    int pid, code;

    printf("sleepytest: start\n");

    pid = j_fork();
    if (pid < 0) {
        printf("sleepytest: FAIL fork\n");
        return 1;
    }
    if (pid == 0) {
        /* 真睡眠 250 ms:走 int 0x30 功能 26,内核把它挂起、定时器叫醒 */
        j_sleep(250);
        printf("sleepytest: child awake pid=%d\n", j_getpid());
        j_exit_code(7);
    }

    /* 父进程睡眠等子进程(内核 process_wait 走 sleep_on/wakeup) */
    code = j_wait(pid);
    if (code != 7) {
        printf("sleepytest: FAIL code=%d\n", code);
        return 1;
    }

    /* 没有子进程了:应当立刻返回 -1 */
    if (j_wait(-1) != -1) {
        printf("sleepytest: FAIL extra wait\n");
        return 1;
    }

    printf("sleepytest: PASS child=%d code=%d\n", pid, code);
    return 0;
}
