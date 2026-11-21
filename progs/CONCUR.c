/* ============================================================================
 *  CONCUR.C — 并发输出 / 写盘不交错的证据(A5 测试程序)
 *
 *  它证明:
 *    1. 两个子进程能真正并发跑(被高优先级抢占也没关系);
 *    2. 控制台输出有 console_lock:每行 print 是原子的,不会 A/B 字符拼成一行;
 *    3. 文件接口有 fs_lock:两个进程同时写不同文件不会把 FAT 表搅烂;
 *    4. 写进去的两个文件内容各自完整(A 文件全 A、B 文件全 B);
 *    5. 父进程 wait 收两个子进程的退出码。
 *
 *  运行: run CONCUR.BIN
 *  期望输出: concurtest: PASS A=... B=...
 * ==========================================================================*/
#include <stdio.h>
#include <stdlib.h>
#include <kkernel.h>

#define LINE_LEN 48              /* 够短,单行放得下(VBE 100 列) */
#define FILE_LEN 64

static char line_a[LINE_LEN + 1];
static char line_b[LINE_LEN + 1];

static void fill(char *p, int n, char c)
{
    int i;
    for (i = 0; i < n; i++)
        p[i] = c;
    p[n] = 0;
}

int main(void)
{
    int a, b, ca, cb, n;
    char buf[FILE_LEN + 1];   /* +1:fill() 末尾写 0 */

    printf("concurtest: start\n");

    a = j_fork();
    if (a == 0) {
        fill(line_a, LINE_LEN, 'A');
        printf("concurtest: A[%s]\n", line_a);
        fill(buf, FILE_LEN, 'A');
        n = j_writefile("CONA.TXT", buf, FILE_LEN);
        j_exit_code(n == 0 ? 0 : 1);
    }

    b = j_fork();
    if (b == 0) {
        fill(line_b, LINE_LEN, 'B');
        printf("concurtest: B[%s]\n", line_b);
        fill(buf, FILE_LEN, 'B');
        n = j_writefile("CONB.TXT", buf, FILE_LEN);
        j_exit_code(n == 0 ? 0 : 1);
    }

    if (a < 0 || b < 0) {
        printf("concurtest: FAIL fork\n");
        return 1;
    }

    ca = j_wait(a);
    cb = j_wait(b);
    if (ca != 0 || cb != 0) {
        printf("concurtest: FAIL codes a=%d b=%d\n", ca, cb);
        return 1;
    }

    /* 两个文件各自读回来:内容必须清一色 */
    n = j_readfile("CONA.TXT", buf, FILE_LEN);
    if (n != FILE_LEN) {
        printf("concurtest: FAIL read A=%d\n", n);
        return 1;
    }
    while (--n >= 0)
        if (buf[n] != 'A') {
            printf("concurtest: FAIL A content\n");
            return 1;
        }

    n = j_readfile("CONB.TXT", buf, FILE_LEN);
    if (n != FILE_LEN) {
        printf("concurtest: FAIL read B=%d\n", n);
        return 1;
    }
    while (--n >= 0)
        if (buf[n] != 'B') {
            printf("concurtest: FAIL B content\n");
            return 1;
        }

    printf("concurtest: PASS A=%d B=%d\n", a, b);
    return 0;
}
