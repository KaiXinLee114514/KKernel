[简体中文](zh-CN/quickstart.md)

# Five-Minute Quickstart: Write a Program for KKernel in Pure C

**You won't touch a single line of assembly.** Write whatever you want in `main()` — `printf`, `argv`, file I/O are all there.

## 0. Prerequisites (One-Time)

```bash
sudo apt install gcc-multilib nasm qemu-system-x86 python3   # Debian/Ubuntu
git clone https://github.com/KaiXinLee114514/KKernel.git && cd KKernel
make            # builds the kernel and image (takes a while the first time)
```

## 1. Write a C File

`sdk/examples/hello.c` is a ready-made template — copy it and edit:

```c
#include <stdio.h>
#include <kkernel.h>

int main(void)
{
    j_color(KK_LCYAN);
    printf("hello from C!\n");
    j_color(KK_GREY);
    printf("你给我的参数是:%s\n", j_arg());
    return 0;
}
```

## 2. Build + Run (Two Commands)

```bash
bin/kkernel-cc myprog.c -o MYPROG.BIN     # pure C → a flat binary for KKernel
bin/kkernel-run MYPROG.BIN                # build the image + start QEMU
```

In the window, type `run MYPROG` — your program is now running on the system you wrote yourself. `bin/kkernel-run myprog.c` does it in one step (it calls `kkernel-cc` first).

## 3. What You Can Use

| Header | What's in it |
|---|---|
| `<kkernel.h>` | wrappers for screen/keyboard/files/arguments: `j_print` `j_color` `j_clear` `j_goto` `j_key` `j_event` `j_read_file` `j_write_file` `j_screensize` `j_arg` `j_puts_at` `j_beep`, palette constants like `KK_RED`, arrow-key codes like `KK_KEY_UP` |
| `<stdio.h>` | `printf` `puts` `putchar` `getchar` (mini implementation, supports `%d %x %s %c %u`, **no** `%f`) |
| `<string.h>` `<stdlib.h>` `<ctype.h>` | `memcpy` `strlen` `strcmp` `malloc` `free` `atoi` … |
| `<malloc.h>` | `malloc/free` (the heap starts at 0x180000; query the end with `j_heap_end()`) |

The file API **supports paths**, relative to the current directory: `j_read_file("DOCS/NOTE.TXT", buf, sizeof buf)`.

## 4. Boundaries You Must Know (There's No Permission Model — the Kernel Trusts You)

* Programs are loaded at **0x120000** (virtual address); the entry point is the first byte (the linker script takes care of that); that region and the heap region (0x180000–heap top) are now your **own private pages**, and they are **handed out on demand**: the kernel builds the page tables but gives you nothing up front; your code takes a fresh, zeroed page when it touches one, and the pages go back when the program exits — the virtual address stays the same, the physical page may differ every time. So "memory you never touch costs no physical pages", and so if you accidentally step into an unwritten spot in the heap window you `won't read anyone else's data` either (you just get a fresh zero page); `run TOUCH` demonstrates exactly this — run it to see how much memory you're using;
* Your code/data, the argument block and the heap are yours to use; **don't write** 0x10000–0x30000 (kernel), 0x100000/0x110000 (kernel buffers), or kernel data outside the heap window (0x3B0000 upward: PINYIN/USB/bitmaps; the font lives high at runtime — leave it alone);
* **Above 4 MiB is the kernel's physical page pool** (0x400000 to the identity-map limit; the limit adapts to machine memory — 0x7C00000 (124 MiB) at the default QEMU 128 MiB, max 256 MiB; the identity-map page tables also come from this pool). Programs must not touch it — memory returned by `malloc` lives in 0x180000–0x1EDFFF, so you don't need to worry about it;
* `ret` back to the shell = program exit; don't disable interrupts (`cli`), or the system loses its clock;
* You **can no longer read** other programs' memory (each runs in its own address space), but the kernel still can't stop you — this is a homemade toy system, not Linux.

## 5. FAQ

| Symptom | Cause |
|---|---|
| `file not found` | file names in the system are uppercase 8.3 (`MYPROG.BIN`); `run myprog` works too (`.BIN` is appended automatically) |
| compiler errors about `-m32` | `gcc-multilib` isn't installed |
| Chinese shows as `?` on screen | you're looking at the ASCII region with Alt; Chinese can display (the font has to be on disk — the `make hd` image has it) |
| want to run an extension (vi, say) | `make ext-img && make run-ext` — that's the optional toy set, not in the default image |
| `run PLAY` makes no sound at all | QEMU 7+ needs an audio backend wired to the PC speaker: `-machine pcspk-audiodev=snd0 -audiodev pa,id=snd0` (see §8 below); VirtualBox doesn't emulate a PC speaker, so you won't hear it there |
| pitch is right, tempo is fast/slow | pitch is set by PIT hardware (accurate), **durations are busy-wait estimates**: `SPKR_LOOPS_PER_MS` in `kernel/speaker.asm`; another machine or KVM can differ by several times — just change that one number |

## 6. How Others Add "Extensions"

Drop the source into `extensions/<name>/`, add one line to `EXT_BINS` in the Makefile, and `make ext` builds it. The rules are in `extensions/README.md`: **extensions must not drag down the main line** — if one breaks, `make test` must still be unaffected.

## 7. Typing Chinese/Japanese/Korean With the Keyboard (Alt Code-Point Input)

The keyboard only does ASCII? Hold **Left Alt**, type the **decimal code point** on the keypad/main keyboard, release Alt — the character is injected as UTF-8 into the current program (editor, `write`, shell all accept it):

| Want to type | Type |
|---|---|
| 中 | hold Alt + `20013`, release |
| あ | hold Alt + `12354`, release |
| 한 | hold Alt + `54620`, release |
| 😀 | hold Alt + `128512`, release (4-byte UTF-8; drawn if it can be drawn) |

Because it's "code points straight through", **Japanese/Korean work too** without touching the kernel — the on-disk font has all hiragana, all katakana, all Hangul syllables and the 20,000+ CJK basic block. Typing digits by hand is tedious; use the conversion script:

```bash
python3 tools/text2alt.py "日本語 한국어"       # each character = Alt+what, and check whether the font has the glyph
python3 tools/text2alt.py --line "こんにちは"   # just a line of numbers you can type along
python3 tools/text2alt.py --send build/qmp.sock "こんにちは"
                                 # ↑ types straight into the running VM (the QMP socket from make hd is at build/qmp.sock)
```

* The code point is the Unicode number (decimal): `中` = U+4E2D = 20013;
* pressing another key before releasing Alt cancels that input;
* digits typed during Alt are **not** echoed; the character appears when you release;
* by the way: **Shift or Caps Lock** both work for case (letters are `Shift XOR Caps Lock`, so turning both on gives lowercase); pressing Caps Lock also sends `0xED` to the keyboard so the LED matches;
* **Ctrl+← / Ctrl+→ switch shells**: four shells start at boot and the keyboard belongs to the "currently active" one. When one shell is stuck in a program that won't let go, like `run HANG` (prints a line, exits by itself after ~40 seconds), press `Ctrl+→` to move next door and keep working (the switch happens in the keyboard interrupt, so even the stuck one can be switched away from); `shell` lists the four, `shell 3` jumps straight there;
* in the shell a multi-byte character is **echoed as a whole and deleted as a whole** (drawing byte by byte would shatter one character into three "missing glyph" boxes); full-screen programs (EDIT/calculator) still work byte by byte internally;
* this requires the font to be on disk (the `make hd` image has it, 40k glyphs) — otherwise only the built-in ASCII subset displays and Chinese turns into boxes.

## 8. Making KKernel Sing: Buzzer + Text Scores

The kernel gained **function 14, `beep`** (in C it's `j_beep(freq_hz, ms)`), and `progs/PLAY.C` uses it as a player: a score is a **plain text file** on FAT, no recompiling anything — `run EDIT MYSONG.TXT`, change a couple of lines, and you have a different tune.

> **The player is there, but no sample scores ship by default — write your own.**
> The image contains no ready-made tunes: type a few lines in the 8.2 format below and you have a song.
> (The PC speaker is a square wave with no volume control; full volume is too harsh, so the sample scores were removed — writing your own lets you pick something quieter.)

### 8.1 First, Make It Beep

```bash
make hd          # or just build the image: make -s build/kkernel-hd.img
# ★ From QEMU 7 on, the PC speaker needs an explicit audio backend or it is completely silent:
# ★ a square wave has no volume control and full volume is harsh — use out.stream-name to name the stream
#   so you can recognise it in the host mixer and turn it down separately (see the first point below); turn it down before listening:
qemu-system-i386 -machine pcspk-audiodev=snd0 -audiodev pa,id=snd0,out.stream-name=KKernel \
    -drive file=build/kkernel-hd.img,format=raw,if=ide,index=0 -boot c
```

In the window, type (the score is yours to write; format in 8.2):

```
> run PLAY MYSONG.TXT        ← play a score
> run PLAY --list MYSONG.TXT ← parse only, print the score to the screen (no sound; use it to check your edits)
```

* **How to keep the buzzer quiet**: the PC speaker is a square wave and **the hardware has no volume control** (the two bits at `0x61` are just "on / off"), so volume can only be adjusted on the host — lower the system volume, or in the host mixer (`wpctl` / `pavucontrol`) turn the QEMU stream down separately (above we gave it a recognisable name with `out.stream-name=KKernel`, otherwise a pile of `qemu-system-i386` streams is indistinguishable);
* ★ **There is no `out.volume=` parameter in `-audiodev`**: that spelling circulates online, but QEMU refuses to start with it (`Parameter 'out.volume' is unexpected`, measured on QEMU 10.0.11 locally; upstream QAPI's `AudiodevPerDirectionOptions` only has frequency / channels / voices / format / buffer-length / mixing-engine). Don't treat it as a volume knob — the host mixer is;
* **Don't want any sound at all**: switch the backend to `-audiodev wav,id=snd0,path=/tmp/kk.wav` (records without playing, and you can check intonation from the recording), or `-audiodev none,id=snd0` (nothing connected);
* `-audiodev pa,id=snd0` is the spelling for PipeWire/PulseAudio hosts (old QEMU's `pa` backend has the same name); if there's no sound, first check whether QEMU reported an audio error, or try `-audiodev none,id=snd0` first (at least it won't error);
* **VirtualBox doesn't emulate a PC speaker**, so you can't hear it there (recorded in [known-issues.md](known-issues.md));
* the sound comes from the host audio backend — there's no real speaker in the VM; what beeps is your sound card.

### 8.2 Score Format (Three Things in Total)

```
# if the first character of a word is # → everything from there to end of line is a comment
tempo 140          # beats per minute (default 120); quarter note = 60000/tempo milliseconds
A4  8              # note name + duration: 1 whole / 2 half / 4 quarter / 8 eighth / 16 sixteenth
C#5 8              # write sharps as # (note: a # inside a note name is not a comment — only a word-initial # is)
R   4              # R = rest (silent, just wait that long)
```

* **Note names** = letters `C D E F G A B` (either case) + optional `#` + octave digit (1~9). The player only has a frequency table for the C4~B4 octave; other octaves are shifted by ×2 / ÷2 (in equal temperament an octave up is exactly double the frequency), so `C4`~`B5` obviously work, and two octaves further out is fine too;
* a line can hold several notes: `A4 4 C5 8 D5 16` is equivalent to three lines (name duration name duration …);
* `tempo` can change mid-score; wherever it appears it affects the notes after it;
* durations aren't limited to powers of two: `3` works too (triplet-ish), but `1/2/4/8/16` reads best;
* a mistake tells you **which line** and what's wrong (unknown note name, missing duration, out of the buzzer's range…).

### 8.3 Pitch Reference (Hard-Coded in the Player, Equal Temperament A4 = 440 Hz)

| Note | C4 | C#4 | D4 | D#4 | E4 | F4 | F#4 | G4 | G#4 | A4 | A#4 | B4 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Hz | 262 | 277 | 294 | 311 | 330 | 349 | 370 | 392 | 415 | 440 | 466 | 494 |

An octave up multiplies the table by 2 (C5 = 524), an octave down divides by 2 (C3 = 131). The table is rounded to whole Hz: the buzzer is a square wave, nobody can hear a fraction of a hertz.

### 8.4 Write Your Own Song

1. `run EDIT MYSONG.TXT` → type a few lines in the format above → `Ctrl-S` saves, `Ctrl-Q` quits (`Ctrl-F` finds a word) (or write it on your own computer and stuff it into the image with `python3 tools/mkfat.py build/kkernel-hd.img 6144 8 MYSONG.TXT=my.txt`);
2. `run PLAY --list MYSONG.TXT` to check note names/frequencies against the screen (a typo reports its line number here);
3. `run PLAY MYSONG.TXT` to listen. To change tempo, edit the `tempo` line; nothing else needs touching.

**The player is there, but no sample scores ship by default — write your own**: the image has no `.TXT` scores; step 1 above is the starting point (it used to ship two samples, but a square wave at full volume was too harsh, so they were removed).
