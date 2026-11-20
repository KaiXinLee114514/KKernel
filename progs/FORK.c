/* ============================================================================
 *  FORK.C — 进程地基的冒烟测试:fork + 写时复制 + wait + exit
 *
 *  它证明四件事:
 *    1. int 0x30 的 fork(功能 18)能复制出跑在 ring3 的子进程,
 *       子进程从 int 0x30 的下一条指令继续,拿到的返回值为 0;
 *    2. 父子共享的页是写时复制:子进程写 shared[0]=99,父进程看到的仍是 0;
 *    3. wait(功能 19)能回收子进程并拿回退出码;
 *    4. exit(功能 20)能把退出码交给父进程(不是"跑完返回 shell"的老路)。
 *
 *  运行: run FORK.BIN
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <kkernel.h>

static volatile int shared[8];

int main(void)
{
    int me, pid, code;

    me = j_getpid();
    shared[0] = 0;
    printf("forktest: start pid=%d\n", me);

    pid = j_fork();
    if (pid < 0) {
        printf("forktest: FAIL fork returned -1\n");
        return 1;
    }
    if (pid == 0) {
        /* 子进程:写一页共享内存,应该触发写时复制 */
        shared[0] = 99;
        printf("forktest: child pid=%d shared0=%d\n", j_getpid(), shared[0]);
        j_exit_code(7);                 /* 退出码 7,父进程 wait 时拿回 */
    }

    code = j_wait(pid);
    printf("forktest: parent child=%d code=%d shared0=%d\n",
           pid, code, shared[0]);

    if (code != 7 || shared[0] != 0) {
        printf("forktest: FAIL code=%d shared0=%d\n", code, shared[0]);
        return 1;
    }

    printf("forktest: PASS pid=%d child=%d code=%d shared0=%d\n",
           me, pid, code, shared[0]);

    /* 没有别的子进程了,这次 wait 应该返回 -1 */
    printf("forktest: extra wait=%d\n", j_wait(-1));
    return 0;
}
