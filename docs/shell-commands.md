# shell 命令参考

> 原为 README §7。



```
help          列出命令
echo <text>   把文字打回来
clear         清屏
info          CR0/CR2/CR3/CR4、IDT 基址与限长、段寄存器、读盘方式
debug <什么>  诊断/自检类命令都在这条下面(演示命令以前散着放,现在收起来了):
  debug page <hex>   逐级走页表,查虚拟地址映射到哪(例:debug page 0x400000)
  debug pmem         物理页池:总页数、已用、空闲、位图地址
  debug pmap <va>    从页池拿一页,动态建页表映到虚拟地址(玩分页最直接的一条)
  debug pumap <va>   解掉映射并把页还回池子(页表空了会一起回收)
  debug ptest        自测:分配→建表→虚拟地址写/物理地址读→解映射→归还,查泄漏
  debug fault        故意踩没映射的地址,看页错误 panic 屏
reboot        重启(通过 8042 键盘控制器)
ls            列当前目录(名字 + 字节数;硬盘模式才有;根目录下是八个分类子目录)
cat <file>    把文件(UTF-8 文本)打出来,中文能直接看;
              /DEV 下是虚拟设备:cat DEV/RTC 看时间、cat DEV/DEVICES 列设备
write <f> <t> 写文件(创建或覆盖,真的落到磁盘上);
              目标已存在时先问 R/D/O:R 改名、D(或 Esc)不写、O 覆盖;
              /DEV 下:write DEV/CON hi 打到屏幕、write DEV/NULL 丢进黑洞
cp <src> <dst> 复制文件(源读进 60 KiB 文件缓冲再写到目标);
              目标写 DOCS/ 这样(以 / 收尾)或已存在的目录名 → 拷进该目录、名字不变;
              落地文件已存在时也问 R/D/O(同上)
mv <src> <dst> 改名/移动文件(实现是 复制+删源,FAT 目录项搬家;子目录、长文件名都支持);
              目标已存在时同样问 R/D/O
run <file>    给程序建一套独立地址空间(按需分页)再跑(名字不带点会自动补 .BIN;
              裸敲 run 打印接口说明;跑完会报补了多少页:run TOUCH 最能看出来)
A | B         管道(顺序执行,最多 4 段):A 的屏幕输出被内核吃进 64 KB 缓冲,
              跑完 A 再把缓冲当 B 的 stdin(B 用 int 0x30 功能 17 读,见 docs/pipes.md);
              例:cat DOCS/README.TXT | run WC / ls BIN | run GREP HELLO
              管道工具:WC(行/词/字节)、UPPER(转大写)、GREP <子串>、HEAD [行数]
usbdisk       只读裸盘 U 盘(USB 大容量储存):裸 usbdisk 看设备信息(INQUIRY/容量);
              usbdisk read <lba> 读一个扇区打印 64B / hexdump <lba> 看完整 512B /
              mbr 解分区表 / sense 读 SCSI 感应数据
date [fmt]    读 CMOS 时钟:裸 date 打日期+时间+星期,加 ymd / mdy / dmy / time 换格式
style [名字]  换提示符样式:kao(颜文字 (・ω・),报错变 (；ω；),默认)/ plain(朴素 >)/ moe(萌:かいかーねる>,报错带吐槽)/ dos(C:\>)/ c64(READY.);裸 style 看现在用的哪个
pci [b:s.f]   PCI 总线枚举:裸 pci 列出总线上所有设备,加 0:1.2 这种地址看单台详情
uptime        开机到现在多久(内含 tick 数,例:up 4 s (432 ticks at 100 Hz))
sleep <秒>    用 hlt 睡这么多秒(空闲不烧 CPU;上限 3600 秒)
ps            列出内核线程(编号 / 名字 / 拿到过多少 tick / 被调度过几次)
spawn [who]   起一个演示线程(alpha / beta 每秒各打一行;不带参数就轮流起)
kill <id>     杀掉一个线程,把它的栈还给物理页池(0~3 号是 shell 自己人,杀不掉)
shell [n]     列出 4 条 shell(标出键盘现在归谁),或者 shell 3 直接跳过去;
              随时 Ctrl+Left / Ctrl+Right 换成隔壁那条(卡死的 shell 也能被换走)
rc [什么]     rc.conf(key=value 的服务/事件库,见 docs/rc-conf.md):
  rc                概要:配置文件名、几个 key、hostname、autostart / on_crash
  rc list           列出服务(编号 / 程序 / enabled-disabled / 参数)
  rc get <key>      取一个 key 的值(key 不分大小写)
  rc start <n>      把第 n 号服务当程序跑一遍(和 run 同一条路)
  rc log            事件账本:开机/读配置/服务起停/程序跑完/崩了/kill/换 shell,各带 tick
  rc reload         重新读磁盘上的 /SYS/RC.CONF(shell 里 write 过就能立刻生效)
```

`uptime` / `sleep` 的样子(定时器就是靠 100 Hz 的 IRQ0 数出来的):

```
> uptime
up 4 s (432 ticks at 100 Hz)
> sleep 2
slept 2 s (200 ticks)
> uptime
up 13 s (1306 ticks at 100 Hz)
```

`date` 的样子(读的是 CMOS 里的真实时间;窗口版 QEMU 加了 `-rtc base=localtime`,所以跟你手腕上的表一致):

```
> date
2026-10-07 11:03:36 星期三
RTC: BCD, 24-hour mode (no timezone handling)
> date ymd
2026-10-07
> date mdy
10/07/2026
> date dmy
07/10/2026
> date time
11:03:42
> date xxx
date: unknown format, try ymd / mdy / dmy / time (got: xxx)
```

`debug page` / `debug pmap` 的输出示例(这就是分页在干的事):

```
> debug page 0x400000    ← 恒等映射:虚拟地址 = 物理地址
virtual      = 0x00400000
PDE index    = 0x00000001 [1] = 0x00003003  present + writable
PTE index    = 0x00000000 [0] = 0x00400003  present
physical     = 0x00400000
> debug page 0x20000000  ← 恒等映射封顶(256 MiB)以外没映射
virtual      = 0x20000000
PDE index    = 0x00000080 [128] = 0x00000000  PDE not present -> would page-fault
> debug pmap 0x8000000   ← 现建一张页表,拿页池里的物理页映上去
mapped 0x08000000 -> physical 0x00400000  (page table created on demand; check with: debug page <va>)
> debug page 0x8000000
virtual      = 0x08000000
PDE index    = 0x00000020 [32] = 0x00401003  present + writable
PTE index    = 0x00000000 [0] = 0x00400003  present
physical     = 0x00400000
> debug pumap 0x8000000
unmapped, gave back 0x00400000  (page returned to the pool; empty page table recycled)
```

键盘直接给字节;中文靠 **Shift 切拼音输入法**输入(候选条浮在屏幕最底两行,见 [架构文档](architecture.md));
也可以直接用 `cat` 看 UTF-8 文件:`cat DOCS/ZH.TXT` 是现成的演示。

想在系统里自己编程序,可以跑 TCC(系统内 C 编译器):

```
> run TCC.BIN -c src/tcc_inc.c -o tcc_inc.o
> run TCC.BIN -static -nostdlib tcc_inc.o lib/crt_tcc.o lib/minic.o -o tcc_inc.elf
> run tcc_inc.elf        ← TCC #include: include works / sizeof(size_t)=4
```

系统头文件在镜像的 `/INCLUDE` 里(来自仓库 `tccinc/`),`#include <stdio.h>` / `<string.h>` 这些
都能用;细节见 [extensions/tcc/README.md](extensions/tcc/README.md)。注意 TCC 按**后缀**认文件,
命令行里写小写 `.c` / `.o`(FAT 查找大小写不敏感,但 TCC 拿到的是你敲的那个字符串)。

