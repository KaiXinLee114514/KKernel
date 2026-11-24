[简体中文](zh-CN/pci.md)

# PCI: Finding Out What's Plugged Into the Machine

Things like USB keyboards and network cards aren't at "fixed ports" on x86 — they hang off the **PCI bus**. The first thing you do when writing a USB driver is enumerate that bus: find the USB controller and read its register window. KKernel's `kernel/pci.asm` does exactly that one job; it scans once at boot, and the shell's `pci` command shows you the result.

## Mechanism #1: Two Ports Cover the Configuration Space

A PCI device has a 256-byte "configuration space" inside it (the first 64 bytes are the standard header). Two I/O ports are all you need to get at it:

| Port | What it does |
|---|---|
| `0xCF8` | write a 32-bit "address": bit31 = 1 (enable), bits16~23 = bus number, bits11~15 = device number, bits8~10 = function number, bits0~7 = register offset (4-byte aligned) |
| `0xCFC` | read/write 32-bit data |

So reading one register is three steps: build the address → `out 0xCF8` → `in 0xCFC`. **The trap most people fall into is forgetting bit31**: without it the CPU never starts a configuration cycle, every read comes back 0, and nothing reports an error ([pitfalls](pitfalls.md) 6.26).

## Scanning the Bus: Don't Forget the "Sibling Functions"

Enumeration order: bus 0 → devices 0~31 → functions 0~7 of each device.

- Read the 32 bits at offset 0 first: **vendor ID 0xFFFF = no device here** (an empty slot returns 0xFFFF, not 0).
- If there is a device, read the header type at offset 0x0C; **bit7 = 1 means it's a "multi-function device"**, and then functions 1~7 all have to be scanned — the machine's IDE (00:01.1) and USB (00:01.2) are functions of the ISA bridge (00:01.0), so scanning only function 0 would show you none of them ([pitfalls](pitfalls.md) 6.27).

The `8086:7010` in a device name is "vendor ID:device ID" (8086 = Intel). The class code (offset 0x0B/0x0A — e.g. `01.01` = IDE, `0C.03` = USB UHCI, `03.00` = display) tells you what kind of thing it actually is.

## BARs: A Device's Register Windows

From offset 0x10 in the device header there are 6 **BARs (Base Address Registers)**, 4 bytes each:

- The **low bit** tells you whether it's a memory window or an I/O window: `bit0 = 1` = I/O port, `= 0` = memory address.
- To get the **size**: write all 1s to the BAR and read it back; the bits that didn't change are the ones "the device needs" — invert from there (for a memory BAR, also mask off the low 4 flag bits). Write the original value back when you're done.
  ⚠️ We **only do this to memory BARs**: in testing, doing it once to an I/O BAR made the whole of QEMU's configuration space unreadable ([pitfalls](pitfalls.md) 6.32), and the base address an I/O BAR reports is good enough anyway.

## Using the Command

```
> pci
 00:00.0  8086:1237  06.00  host bridge  irq 0
 00:01.0  8086:7000  06.01  ISA bridge  irq 0
 00:01.1  8086:7010  01.01  IDE controller  irq 0
 00:01.2  8086:7020  0C.03  UHCI 1.1  irq 11
 00:01.3  8086:7113  06.80  bridge (other)  irq 9
 00:02.0  1234:1111  03.00  VGA display controller  irq 0
 00:03.0  8086:100E  02.00  Ethernet controller  irq 11
pci: 7 device(s) found on bus 0

> pci 0:1.2
 00:01.2  8086:7020  0C.03  UHCI 1.1  irq 11
 class 0C.03  prog-if 00  rev 01  header 00  irq 11  command 0107  bus master: yes
 BAR0    --
 BAR1    --
 BAR2    --
 BAR3    --
 BAR4  I/O    0x0000C040
 BAR5    --
```

The address syntax is `bus:device.function`; if it can't make sense of it (you name a device that doesn't exist, say) it tells you straight away.

![pci command screenshot](screenshot-pci.png)

## Where to Go From Here

| Step | What to do | What you'll trip over |
|---|---|---|
| ① PCI enumeration | ✅ can already list devices and read BARs | bit31, multi-function devices, 0xFFFF ([pitfalls](pitfalls.md) 6.26~6.29) |
| ② UHCI init | power up the controller: reset it, then hang the frame list (1024 entries) and the async queue head off it | those are **physical addresses**, so they have to live in the identity-mapped region (0~ident) |
| ③ EP0 control transfers | an 8-byte SETUP packet + data + handshake; this is the first time you really "send DMA" | buffers must be **physically contiguous**; USB is **little-endian**, so descriptors have to be pulled apart bit by bit |
| ④ HID keyboard | interrupt transfers + polling: the key code is in the "report", not a PS/2 scancode | report lengths differ and modifier keys are a bitmask, so you need a translation table of your own |
| ⑤ EHCI / mass storage | high-speed devices + the SCSI subset (reading blocks goes through CBW/CSW) | it's "a whole string of descriptors per frame", very different from UHCI |

The good news is that on an x86 PC **you don't have to worry about cache coherency**: the CPU and PCI share the same physical memory, so a DMA buffer is directly readable and writable as long as it sits inside the identity-mapped region (0~ident).

## Current Limitations

- Only **bus 0** is scanned: buses behind bridges (behind PCIe, say) are invisible
- Interrupt numbers can be read out, but **there is no corresponding gate in the IDT yet**, which is why USB can only poll for now
- I/O BARs don't report a size (reason in [pitfalls](pitfalls.md) 6.32); a few memory BARs come out too large (we measure VGA's BAR2 as 64 KiB, QEMU's `info pci` says 4 KiB)
- Configuration space is read-only: enumeration only ever flips three switches — I/O, MMIO and Bus Master
