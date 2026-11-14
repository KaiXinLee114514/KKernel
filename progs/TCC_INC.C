/* TCC 系统头文件示例:镜像里 /INCLUDE 下的头文件由 tccinc/ 生成 */
#include <stdio.h>
#include <string.h>

int main(void)
{
    char buf[64];
    strcpy(buf, "include works");
    printf("TCC #include: %s\n", buf);
    printf("sizeof(size_t)=%d\n", (int)sizeof(size_t));
    return 0;
}
