[English](../font.md)

# 中文与字库

> 原为 README §9，数据生成见 font/README.md。

中文**能正常显示**:图形模式下把 16×16 点阵直接 blit 到帧缓冲,`cat DOCS/ZH.TXT` 就能看到
(演示文本放在镜像里;中文/日文/韩文/英文各一个 .TXT,不做成命令)。

数据来源与生成方式见 [font/README.md](../../font/README.md):`font/` 目录里是 GNU Unifont 抽出的字形
(入库的是 416 字形的 23 KB `.hex` 子集 + 二进制;完整 42 112 字形的 1.8 MB 字库**放在磁盘镜像里**,
由 `tools/mkfontsubset.py` 生成)。**授权按 GPL-2+ 单独标注**(不并入仓库的 MIT)。

**编码现状**:字符编号是标准 Unicode 码位,**内核文本也已经是标准 UTF-8** ——
`term_print` 会先把 UTF-8 解成码位再画(见 `kernel/utf8.asm`),所以中文文案可以像普通字符串一样
`db '你好,世界!', 0` 写进内核,程序里也一样;坏字节会画成替换字符 `�` 而不是卡死。
细节(包括之前那套"码位数组"的历史)见 [docs/encoding.md](../encoding.md)。
