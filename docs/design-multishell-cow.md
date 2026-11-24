[简体中文](zh-CN/design-multishell-cow.md)

# Multi-shell virtual consoles + fork/COW

> Design draft, **not implemented yet**. The baseline is the 2026-11-14 working tree: Phase 1 "per-thread address space"
> is already done (uncommitted), and the 4 shells each run their own programs; but there's only one screen, and FAT/ATA are still global.
>
> Line numbers drift (the Phase 1 changes moved a good few), so look for function names; line numbers marked "approx." are only guaranteed to have been right when this draft was written.

What you can do now: open 4 shells, switch the keyboard with Ctrl+←/→, and each shell runs its own ring 3 program.
What you can't do: **see** two programs' screens at the same time (the later output covers the earlier one), and `fork`.

This design comes in two phases:

| Phase | Goal | Key changes |
|---|---|---|
| Phase 2 | 4 **virtual consoles**: each shell gets a text buffer, Ctrl+←/→ switches the whole screen; two shells can run programs at the same time | `kernel/cons.asm` (new), output routing, switch redraw, per-console keyboard ring, big filesystem lock |
| Phase 3 | `fork` + copy-on-write (COW): a parent program forks, the child writes its own pages, the parent's data doesn't change | new APIs 18/19/20, page-table cloning, page-pool refcounting, COW page faults, zombies/wait |

Out of scope: `fork+exec`, per-console IME state, SMP, per-console scrollback (only one screen is kept),
turning the kernel fully reentrant (Phase 2 sidesteps this with one "big filesystem lock", rationale in §3.6).

---

## 0. Conclusions first

- **The screen isn't something you "paint again"; it's "one 14,800-byte grid per screen"**. 4 screens = 16 pages,
  taken from the physical page pool, identity-mapped, used directly as pointers.
- The output path has exactly one real fork in it: `term_print_cp` (vgafont.asm:147). Under VBE it currently
  tail-calls `fb_putcp` directly; Phase 2 changes it to write the current shell's grid first and then decide whether to draw.
- **The switch happens inside the keyboard interrupt and only changes a few globals**: `sh_active`, `sh_switch_flag`,
  `cons_redraw`, `ime_switch`. Redrawing is left to threads (in the shell thread's `.mine`, or in a resident
  `cons` thread); the interrupt doesn't touch a single `fb_`.
- The filesystem's pile of global buffers is not going to be converted to reentrant one by one; instead we add a **scheduler-level big lock** (`sched_noswitch`):
  IRQ0 still arrives while the lock is held, but **no thread switch happens**. Better than `cli`: no lost keys, no stopped clock.
- fork's page-table cloning only handles **USER=1 and present** pages; kernel identity-mapped pages stay shared and are not COW'd
  (ring 3 can't reach them). COW uses PTE **bit 9** (current code only uses bits 0/1/2; bit 9 is free).
- Refcounting uses a **4-bit-per-page** nibble table at `0x3D2000` (above the 0x3D0000-0x3D1FFF bitmap,
  no conflict with USB's 0x3Cxxxx; 8 pages is enough for 64,512 pages). The 15-sharer limit = at most 15 processes share one page along one chain, i.e. a fork depth limit of 14 levels.

---

## 1. Baseline: what we already have

### 1.1 Threads (TCB)

`kernel/sched.asm` currently: `SCHED_MAX = 6`, `TCB_SIZE = 112`, each thread gets 2 pages (8 KiB) of kernel stack,
`SLICE_TICKS = 2` (20 ms).

| Offset | Field | Description |
|---:|---|---|
| 0 | `TCB_ESP` | esp saved on switch-out, pointing at the frame on the stack |
| 4 | `TCB_CR3` | its page directory (the program's own while a program runs) |
| 8 | `TCB_STATE` | 0 free / 1 alive / 2 dead (reserved) |
| 12 | `TCB_TICKS` | ticks received so far |
| 16 | `TCB_STACK` | physical base of the kernel stack (returned to the pool on death) |
| 20 | `TCB_NAME` | name shown by `ps` |
| 24 | `TCB_RUNS` | how many times it has been scheduled |
| 28 | `TCB_OWNER` | which shell it was born on (currently only used for display) |
| 32–104 | `TCB_SP_*` | address space: PD/PT/LIVE/PAGES/IMGBYTES/PFRUN/PFIMG/PFHEAP/FIRSTPA/RUNESP/RUNSTAT/FREED/HEAPPAGES/ARGSVA/STACKVA/STACKTOP/RUNNING/STAGE_PA/STAGE_PAGES |
| 108 | `TCB_SP_KILLREQ` | another shell asks to kill the program on this thread |

The switch frame format (consistent with `irq0_stub`, low address to high address):

```
[pushad's eight registers][vector 0x20][error code 0][eip][cs][eflags]
```

`sched_pick` saves esp/cr3, writes `space_cur`, does `mov cr3`, `tss_blk+TSS_ESP0 = [TCB_SP_RUNESP]`.
`irq0_stub` (pit.asm) checks `SP_KILLREQ` on a ring 3 frame and, if set, jumps straight to `run_resume_kernel`
to tear things down — **Phase 3 reuses this mechanism, but fork's children have no `cmd_run` frame, see §4.7.5**.

### 1.2 shell

`kernel/shell.asm`: `SH_MAX = 4`, `SHELL_LINE_MAX = 128`, `SH_BUF_SZ = 132`, `SH_DIR_SZ = 64`.

- 4 shells = 4 kernel threads; 0 is the boot thread (uses the boot stack), 1–3 each have 2 stack pages.
- `sh_active` decides who owns the keyboard; `Ctrl+←/→` directly calls `shell_switch_step` → `shell_switch_to`
  in the **keyboard interrupt** (approx. :286), which only moves `sh_nbuf/sh_nlen/sh_ndir`, sets `sh_switch_flag`, and prints nothing.
- `shell_main` (approx. :39) main loop: if it isn't its turn, it `hlt`s and waits; when its turn comes and `sh_switch_flag` is set,
  it prints a newline + `--- shell N ---` + the prompt + the half-typed line (`shell_readline_resume`).
- `cmd_run` (approx. :2014) now builds a separate address space per thread: the load lock `loader_lock` (approx. :2382)
  only covers "read file → build PD/PT → copy arguments" and is dropped before `iret` into ring 3, so **the programs themselves run in parallel**.
- `cmd_kill` for a shell thread only sets `SP_KILLREQ` (the next IRQ0 tears it down on its own stack);
  for ordinary threads it does `sched_kill` + snapshot + `space_destroy_at`.

### 1.3 Address space

`kernel/paging.asm`:
`PD_ADDR = 0x1000`, `PT_LOW = 0x2000` (identity 0–4 MiB, `P|RW`, **no USER**),
`PT_LFB = 0x4000`; `PAGE_P = 1`, `PAGE_RW = 2`, `PAGE_USER = 4` — **only these three bits**.

- `space_create` (approx. :346): takes 1 page from the pool as PD and 1 as PT, copying 1024 dwords each out of `PD_ADDR`/`PT_LOW`;
  `PD[0] = PT | P|RW|USER`; clears the `96 + SP_HEAPPAGES` entries starting at PT index 288
  (image window 0x120000–0x17FFFF is 96 pages, heap window 0x180000–0x3AFFFF is 560 pages at 128 MiB).
- `page_fault_try_handle` (approx. :472): only fills "not present" pages; image pages are copied from `[SP_STAGE_PA]`
  by offset within the page, heap pages are zeroed; installs `PTE = pa | P|RW|USER`, `invlpg`.
- `space_destroy` (approx. :621): scans present PTEs in both windows, dec-refs page by page; private PT/PD are returned directly,
  the staging area is dec-ref'd page by page.
- The user stack/argument page are the last pages of the heap window (`args=0x3AE000`, `stack=0x3AF000`, `top=0x3AFFFC`),
  and the trampoline is the last page of the image window (0x17F000); together the two windows **cover every user page** — Phase 3's
  COW/refcounting can reuse this scan directly.

### 1.4 Screen

`kernel/fbterm.asm` is a VBE graphics terminal, not text mode:

- Character cell **8×16** pixels; ASCII 8 wide, Chinese 16 wide; the font is moved at runtime to the top of the identity mapping.
- Text grid = `fb_width >> 3` columns × `(fb_height & ~15) >> 4` rows. 800×600 → **100×37**
  (600 = 37×16 + 8, the bottom 8 pixels unused; `fb_newline` clamps to 576 = 36×16).
- 13-page line buffer (holds only the current line, flushed by dirty segment via `fb_flush`); 26-page overlay restore buffer (`fb_bar_*`).
- `fb_putcp`'s newline semantics: **draw first, `fb_cur_x += width`, then check `>= fb_width` to call `fb_newline`**;
  a Chinese character at the last column draws half a cell past the edge before wrapping. The console buffer has to copy this order exactly, or redraws will be off by one cell.
- `fb_putcp_at(eax=codepoint, ebx=row, ecx=col)` doesn't move the cursor, just right for full-screen redraw;
  it does one `fb_flush` per line (37 lines = 37 flushes).

### 1.5 Terminal output, keyboard, files, pipes

- Output: see the call graph in §3.2. The real UTF-8 decoder is `term_print` (kmain.asm:839),
  which calls `term_print_cp` (vgafont.asm:147) after decoding; **under VBE `term_print_cp` tail-calls
  `fb_putcp` directly, bypassing `term_putc`**. `term_puts_at` (kmain.asm:771) is only for the IME overlay.
- Keyboard: `kernel/keyboard.asm` has one 64-byte ring (`kbd_buf`, `KBD_BUF_SIZE=64`),
  `kbd_push` in IRQ1; the readers `kbd_getchar`/`kbd_getkey` do `fb_flush; hlt` when it's empty.
- Files: `kernel/fat.asm` uses a global `FAT_BUF = 0x100000`, one 4 KiB sector buffer, a global
  `[fat_dir]`, plus a pile of `fat_scan_*`/`lfn_*` temporaries; `kernel/ata.asm` has the
  `ata_lba/ata_buf/ata_src/ata_left/ata_chunk` globals. **The whole thing is non-reentrant.**
- Pipes: `kernel/pipe.asm` has globals `pipe_capture_on/pipe_out_buf/...`; its header comment says outright
  "only one ring 3 program runs at a time, so no wait queue is needed" — after Phase 2 that sentence no longer holds.
- `int 0x30` is a **DPL=3 32-bit interrupt gate (0xEE)**; entry has `IF=0`: a system call **cannot be preempted at all**.
  That's good (the API's `fat_*` is naturally atomic) and bad (you can't `hlt` waiting for a lock inside).

### 1.6 Things in the current state that get in the way

| # | Problem | Location | Impact |
|---:|---|---|---|
| 1 | The screen is globally unique | `fb_*` global cursor/line buffer | later output covers earlier output |
| 2 | `fat_dir` is global | fat.asm | two shells doing `cd`/reading files concurrently get their directories crossed |
| 3 | `kbd_buf` is global | keyboard.asm | background programs steal the active shell's keys |
| 4 | Pipe capture is global | pipe.asm | two pipe chains running concurrently get their buffers crossed |
| 5 | `kbd_getchar`'s `hlt` doesn't enable interrupts | keyboard.asm:519 | sleeps forever inside an `IF=0` API (see P0.1) |
| 6 | No `CR0.WP` | paging.asm `paging_init` | Phase 3 COW kernel writes won't fault |

---

## 2. Loose ends first (P0: don't start Phase 2 without these)

- [ ] **P0.1 Fix the `hlt` in keyboard waiting**: `kbd_getkey`/`kbd_getchar`'s `.wait` currently does a bare `hlt`.
  The API gate enters with `IF=0`, and `hlt` can't wait for maskable interrupts. Change it to:

  ```asm
  .wait:
      call fb_flush
      pushfd
      sti
      hlt
      popfd          ; back to the caller's original IF (shell=1, API=0)
      jmp .loop
  ```

  This isn't just groundwork for Phase 2 — right now "press any key to continue inside a program" is a hard freeze on real hardware;
  on QEMU it happens to wake up with an interrupt pending, but don't bet on that.
- [ ] **P0.2 Clear out the remains of "only one program runs at a time"**: README lines 83/533, the relevant paragraphs in `docs/known-issues.md`,
  and the test assertion `another shell is running a program`. Phase 1 already runs programs in parallel;
  Phase 2 just separates the screens too.
- [ ] **P0.3 Sync `cmd_run`'s comments/docs**: `cmd_run` already stages images per thread and `loader_lock`
  only covers loading; the README's program chapter is still written for a single program.
- [ ] **P0.4 Decide the display thread's slot**: Phase 2 adds a resident `cons` thread (`SCHED_MAX 6 → 8`),
  and the "4 alive / 6 slots" in `ps`/tests has to change with it.
- [ ] **P0.5 Leave `CR0.WP` for Phase 3** (in `paging_init`, change `or eax, 0x80000000` to
  `or eax, 0x00010000 | 0x80000000`); Phase 2 doesn't need it, so don't change it early, or kernel writes to read-only pages will
  trigger a pile of mysterious #14s.

---

## 3. Phase 2: one virtual console per shell

### 3.1 Buffers: sizing, placement, shape

#### 3.1.1 Size

| Item | Calculation | Value |
|---|---|---:|
| Columns | `fb_width >> 3` | 100 |
| Rows | `(fb_height & ~15) >> 4` | 37 |
| Cells | 100 × 37 | 3 700 |
| Per cell | 4 bytes (see below) | 4 B |
| Per block | 3 700 × 4 | **14 800 B** |
| Pages per block | `(14800+4095)>>12` | **4 pages** (16 384 B, 1 584 B wasted at the tail) |
| 4 blocks | 4 × 4 | **16 pages** (65 536 B) |

For comparison: the full screen in pixels is 800×600×4 = **1.92 MB**, and 4 of those simply don't fit; a text grid is on the order of 1/130 of that.
That's why "virtual consoles" store **character cells**, not pixels.

#### 3.1.2 Cell format

```text
 31      24 23 22 21 20                    0
+----------+--+--+--+-----------------------+
|   attr   |W |T |保留|       码位 cp        |
+----------+--+--+--+-----------------------+
```

| Bit | Name | Meaning |
|---|---|---|
| 0–20 | `cp` | Unicode code point (0x10FFFF needs only 21 bits) |
| 21 | reserved | left for "underline/reverse video" and the like, 0 for now |
| 22 | `CELL_TAIL` | 1 = this is the second cell of a Chinese character, skip it on redraw |
| 23 | `CELL_WIDE` | 1 = head cell of a Chinese character (16 pixels wide = 2 cells) |
| 24–31 | `attr` | same format as `term_color` (`0x0F` white on black) |

- Not a "UTF-8 byte stream": cursor positioning, backspace, and redraw all need random access, and a variable-length encoding would force decoding from the start every time.
- `attr` uses `term_color` directly; on redraw `fb_color_of(attr)` is `term_fb_color`, so there's no need to invent another palette.
- Blank cells are uniformly `0x07000020` (space + 0x07). `cons_init` fills whole blocks with `rep stosd`.

#### 3.1.3 Where they come from

Insert in `kmain.asm` after `paging_init` (approx. :265) and before `sched_init` (approx. :363):

```asm
    call cons_init          ; 4 × pmem_alloc_pages(4); any failure → back out everything + cons_ok=0
```

At this point the page pool (`pmem_init`, :165) and the identity mapping (`paging_init`) are ready, and `term_init` (:177) is too,
so we can print a line right away:

```text
cons: 4 consoles x 100x37 (14800 B each, 16 pages)
```

The physical addresses allocated are their virtual addresses (identity mapping), so no page tables need building. `pmem_alloc_pages` guarantees
**4 contiguous pages**; the start is only guaranteed to be 4 KiB-page aligned (not 16 KiB aligned), but 14,800 B always fits
inside those 4 pages, so `rep stosd` won't step on anyone else.
The default 128 MiB config has a 30,207-page pool, and 16 pages is 0.05%, negligible; with `-m 8` there is no page pool, so
`pmem_alloc_pages` returns 0, `cons_ok=0`, and we fall back to the old "one screen + keyboard switching only" behavior (see §3.1.5).

#### 3.1.4 Console table

BSS in `kernel/cons.asm` (new file):

```asm
cons_buf      dd 4 dup(0)        ; base address of each 4-page block (physical = virtual)
cons_cx       dd 4 dup(0)        ; cursor column (cells)
cons_cy       dd 4 dup(0)        ; cursor row
cons_attr     dd 4 dup(07h)      ; current color (attr byte)
cons_seq      dd 4 dup(0)        ; +1 per write; redraw uses it to spot "someone wrote while we were painting"
cons_redraw   dd 0               ; console number to redraw + 1; 0 = no redraw needed
cons_pages    dd 0               ; how many pages are actually used (for layout/tests)
cons_ok       db 0               ; 0 = no consoles, everything takes the old path
cons_cols     dd 0
cons_rows     dd 0
```

Add two fields to the TCB (Phase 2):

| Offset | Field | Description |
|---:|---|---|
| 112 | `TCB_CONS` | which console this thread's output/keyboard belongs to (0–3) |
| 116 | `TCB_CWD` | snapshot of `fat_dir` at the moment of switch-out (called CWD, but it actually stores the raw cluster number, see §3.6.3) |

`TCB_SIZE` 112 → **120**, `SCHED_MAX` 6 → **8** (4 shells + 1 `cons` thread + 3 spare).
`sched_init` sets thread 0's `TCB_CONS=0`; `shell_spawn_extra` sets `TCB_CONS` to `ebp` when starting 1–3;
`sched_spawn` defaults it to 0 (the cons thread counts as console 0). Slot convention: **0–3 = shells, 4 = cons,
5+ = fork/demo threads** (7 in Phase 2, 11 in Phase 3). `cmd_kill` must reject `tid == 4` (the cons thread can't be killed); for 0–3 it only pokes `KILLREQ` at the program they're running, and only from 5 up does it take the "thread plus address space" path. **`sched_spawn` must also initialize `TCB_CWD`
to the `[fat_dir]` of the moment**, not leave it 0 — otherwise a thread started inside a subdirectory gets
yanked back to the root directory the first time it's scheduled. `cmd_spawn` (demo threads) must explicitly set `TCB_CONS` to `[space_cur+TCB_CONS]`,
so a thread started from a background shell doesn't paint characters onto console 0.

> Why exactly 4 blocks: to line up with `SH_MAX=4`. Adding a shell means adding 4 pages at the same time; don't get greedy.

#### 3.1.5 Failure path

- `cons_init`'s four `pmem_alloc_pages(4)` calls are **all or nothing**: if any one fails, return the pages already acquired
  to the pool, set `cons_ok=0`, **don't start the `cons` thread**, and every `term_*` takes the original direct-draw path.
  Ctrl+←/→ still only switches the keyboard, and the screen keeps the old behavior. The `layout` line says `cons=0`, and tests skip
  the console assertions accordingly.
- No half-broken "only got 1–3 blocks" state: the 4 shells share the same screen semantics, and missing even one block would produce the weird
  "this one is virtual, that one draws direct" situation, so better to fall back wholesale.

### 3.2 Output routing: branch off at `term_print_cp`

First, the current call graph (only the parts that write to the screen):

```text
term_print(kmain:839) ──UTF-8 decode──> term_print_cp(vgafont:147)
                                        ├─ control chars (<0x20) → term_putc(kmain:567)
                                        └─ VBE printable ─────> fb_putcp(fbterm:444) ─> fb_blit
term_putc ─────────────────────────────────────────────────> fb_putc(fbterm:404) ─> fb_putcp
term_puts_at(kmain:771) ───────────────────────────────────> fb_putcp_at(fbterm:486)  [IME bar]
program API 3 ─────────────────────────────────────────────> term_print_cp
program API 6 clear ───────────────────────────────────────> term_clear → fb_clear
program API 9 set_cursor ──────────────────────────────────> term_set_cursor
```

Key fact: **under VBE, printable characters don't go through `term_putc` at all** — `term_print_cp` tail-calls
`fb_putcp`. So hooking only `term_putc` would miss every normal piece of text (a sneaky pitfall: small wonder Chinese couldn't be caught).

#### 3.2.1 Which points to hook

| Function | Now | Phase 2 |
|---|---|---|
| `term_print_cp`(vgafont:147) | `jne fb_putcp` | `jne cons_putcp` (cons decides internally whether to draw) |
| `term_putc`(kmain:567) | control chars → `fb_putc` | `call cons_putc_byte` first, then decide `fb_putc` based on the active console |
| `term_clear`(the wrapper around `fb_clear` in kmain) | whole screen black | `call cons_clear` (clear the current buffer + cursor); only `fb_clear` if active and `!cons_repaint_busy` |
| `term_set_cursor`(kmain:719) | change `fb_cur_*` | store `cons_cx/cy`, only touch `fb_cur_*` if active |
| `term_set_color`(kmain:558) | change `term_color/term_fb_color` | also store `cons_attr[cur]` |
| `term_puts_at`(kmain:771) | write pixels directly | **don't capture**; only the active console may draw (background calls are dropped, see §3.4) |
| `term_print`'s pipe capture | early return when `pipe_capture_on` | add a `pipe_owner == current console` check (§3.6) |

`term_putc` details: it currently handles `\n\r\b`, then `fb_putc`. Change it to:

```asm
term_putc:
    ; ... existing pipe_capture check (return directly when capturing, don't enter the console) ...
    cmp byte [cons_ok], 0
    je .old
    mov edx, [space_cur]
    test edx, edx
    jz .old                    ; early boot (before sched_init) has no TCB
    call cons_putc_byte        ; write buffer/cursor; eax=1 means "I even did the drawing for you"
    test eax, eax
    jnz .done
    mov eax, [edx + TCB_CONS]
    cmp eax, [sh_active]
    jne .done                  ; background: once the buffer is written, we're done
    cmp byte [cons_repaint_busy], 0
    jne .done                  ; full-screen repaint in progress: don't cut in, the seq re-check will catch it
.old:
    jmp fb_putc                ; the original path (active console / no cons)
.done:
    ret
```

`cons_putc_byte` handles three classes:

- `8/10/13`: **handle the screen entirely itself and return `eax=1`**. Backspace sets `fb_cur_x = cx*8` and then draws a space
  (otherwise `fb_putc(8)` only steps back 8 pixels, and a Chinese character would step back half a cell); carriage return only sets `fb_cur_x=0`;
  newline changes the buffer first; only when **the console is active and `cons_repaint_busy==0`** does it call `fb_putc(10)`
  (which does the `fb_newline`/scroll). Returning 1 is
  so the tail doesn't draw it a second time — if `\n` returned 0 it would become a double newline.
- Printable ASCII: only record the byte in the buffer and advance `cons_cx/cy` (on overflow just scroll the buffer), return 0,
  and let the tail `fb_putc` draw it once. **Don't `fb_newline` here**; screen wrapping/scrolling is done by
  `fb_putc`/`fb_putcp` themselves, otherwise double newline.
- Other control bytes: ignored.

The `term_print_cp` path is already handled by `cons_putcp`, so there's no duplication (because under VBE printable characters
don't go through `term_putc`).

#### 3.2.2 What `cons_putcp` does

```text
cons_putcp(eax=codepoint)
  1. id = [space_cur+TCB_CONS]; if cons_ok=0 / space_cur=0 → jmp fb_putcp (old path)
  2. width = fb_glyph(cp) width >> 3 (1 or 2; a missing glyph counts as 1)
  3. if width=2 and col=cols-1: cons_newline first; the active console also does fb_newline first
     (to keep Chinese characters from drawing outside the framebuffer, see below)
  4. clear any half a Chinese character (head/tail) sitting on the target cells, write the head cell; if width 2 write the tail cell (CELL_TAIL)
  5. col += width; if col >= cols → cons_newline (only scrolls the buffer, cursor back to zero;
     the screen's wrapping/scrolling is done by fb_putcp in step 6; calling fb_newline again here would double it)
  6. if id == [sh_active] and [cons_repaint_busy]==0:
       term_fb_color = fb_color_of([cons_attr+id*4])
       fb_putcp(cp)            ; it advances fb_cur_x/y and calls fb_newline if needed
  7. ret
```

Details that must make it into the code:

1. **Draw first, then check overflow**: `fb_putcp` "draws, then `add fb_cur_x, width`, then checks `>= fb_width`".
   The buffer follows the same order, otherwise the cursor is off by one cell on redraw. But **width 2 at the last column**: `fb_blit`
   writes 16 pixels, past width 800 and into the next row — that hazard exists today, and the console buffer fixes it along the way:
   `if (col + w > cols) cons_newline()` before writing. The price is "the last Chinese character wraps early",
   which is almost invisible to the eye.
2. **Overwriting half a Chinese character**: if the target cell is `CELL_TAIL`, erase its head cell to a space first; if the target is
   `CELL_WIDE`, erase its tail cell too. Otherwise you get a "half a character + new character" ghost.
3. **Backspace**: if `cx>0`, `cx--`; if it lands on `CELL_TAIL`, `cx--` again and erase both cells.
   `fb_putc(8)` only steps back 8 pixels (half a Chinese character), so on the active console backspace is done by `cons_putc_byte`
   directly setting `fb_cur_x = cx*8` and drawing a space, not via `fb_putc`.
4. **`\r` / `\n`**: `\r` only resets the column; `\n` goes through `cons_newline`: row +1, and at the bottom shift
   `(rows-1)*cols*4` bytes en masse (a 14.8 KiB `rep movsd`), fill the last row with spaces.
   The active console also lets `fb_putc(10)` go through `fb_newline` (which scrolls VBE itself).
5. **Clear screen**: `cons_clear` fills the current block with `0x07000020`, `cx=cy=0`; only then `fb_clear` when active.

#### 3.2.3 Per-console color and cursor

- `term_set_color` writes the global `term_color/term_fb_color` and also
  `cons_attr[[space_cur+TCB_CONS]]`. A background program changing color only changes its own block, no front-stage pollution.
- **Before drawing**, recompute `term_fb_color` from `cons_attr` (rather than trusting the global), otherwise one `set_color` from a background program
  makes the foreground's next character use the wrong color. `cons_putc_byte` must also recompute it before drawing printable ASCII
  (it tail-calls `fb_putc` afterwards).
- Every hook first checks `space_cur != 0`: early boot (after `cons_init`, before `sched_init`) BSS is still 0, and a direct
  `[space_cur+TCB_CONS]` would read low memory; in that case only touch the globals and take the old path.
- On console switch: save `cons_cx/cy` (already being written), and on restore
  `fb_cur_x = cx*8`, `fb_cur_y = cy*16`; `term_color = cons_attr`.
- `term_set_cursor` (API 9) only changes **this console's** `cons_cx/cy`; if it's not the active console, that's it,
  otherwise also change `fb_cur_*`.

#### 3.2.4 Pipes

Pipe-captured output **should not** go into the console buffer: it was never drawn on screen in the first place. Existing `term_putc`/`term_print`
check `pipe_capture_on` at the very start and `return`, so as long as the `cons_*` hooks are placed **after** that check,
pipes are automatically unaffected. What needs adding is "which console's pipe":

```asm
pipe_capture_on   dd 0
pipe_owner        dd 0      ; new: console number
```

The capture check in `term_putc`/`term_print` becomes `cmp [pipe_capture_on],0; je .normal`, followed by
`cmp [pipe_owner],[cons]`; if unequal, don't capture and don't draw either (theoretically it can't happen, because pipe chains are serial,
see §3.6).

#### 3.2.5 Who draws: one painter at a time

All existing `fb_*` is global state (`fb_cur_*`, the line buffer `fb_lb_row`, the dirty segment). Phase 2's rules:

- **Only output from the `[sh_active]` console draws to the screen**; the background only writes the buffer.
- Foreground output wraps one "check `id == sh_active` + `fb_putcp` + possibly one
  `fb_newline`" in `pushf; cli`, tens of microseconds, ending with `popf`; the check must be in the same interrupt-disabled section as the draw, otherwise
  "just checked it's foreground, then immediately switched away" makes the old thread add one character to the new screen.
- **No bare `sti`**: printing can happen inside `int 0x30` (API 3, IF=0), and a bare interrupt enable would let the timer in halfway through a system call.
  Everything that "temporarily disables interrupts" is written as `pushf; cli; ...; popf`.
- The redraw thread disables interrupts **per row** (at most 100 characters per row, about 0.3 ms), and preemption is allowed between rows;
  while `cons_repaint_busy` is set, foreground output only writes the buffer and doesn't draw, and the `cons_seq` re-check catches it on the second pass.
- No spin locks: spinning on a single CPU would block the lock holder forever. Short `pushf/cli` critical sections +
  "the background doesn't draw" are enough; long operations (FAT/ATA) use `sched_noswitch` from §3.6.

#### 3.2.6 Cost

- Per character: one `fb_glyph` binary search + `fb_blit` of 128 dwords (8 wide) or 256 (16 wide).
- Per newline: one `fb_flush`; a row's dirty segment is at most 800×16×4 = 51 KB.
- Full-screen redraw: about 3,700 characters, 37 flushes, at most 1.9 MB of MMIO. On QEMU that's on the order of tens of milliseconds,
  faster on real hardware; this number decides whether §3.3 allows it in the interrupt (conclusion: no).

### 3.3 Switching: raise a flag in the interrupt, leave the redraw to a thread

`shell_switch_to` (shell.asm approx. :286) already does three things in interrupt context: back up/restore the line buffer and cwd,
change `sh_active`, set `sh_switch_flag`. Phase 2 adds only **two lines**:

```asm
    mov eax, [sh_target]
    inc eax
    mov [cons_redraw], eax      ; target console number + 1 (0 means none)
    mov byte [ime_switch], 1    ; IME: abandon this composition on switch-away
```

**No `fb_` call**, no `call term_print`, no `hlt`. The only extra cost in the interrupt is two memory writes.

#### 3.3.1 Who consumes `cons_redraw`

Two paths; whoever gets there first draws, and `cons_repaint_busy` keeps two of them from drawing at once:

1. **The shell thread's `.mine`** (shell_main approx. :39): `call cons_service` before printing `--- shell N ---`.
   That way, when switching back to a shell sitting at the prompt, you see its original screen first,
   then the separator line.
2. **A resident `cons` thread**: specifically for "switching to a shell that is running a program in ring 3" — that thread
   won't come back to `.mine`, so only someone else can redraw for it.

```asm
; kernel/cons.asm
kthread_cons:
    cmp dword [cons_redraw], 0
    je .sleep
    call cons_service
.sleep:
    hlt
    jmp kthread_cons
```

Startup order: after `shell_spawn_extra` and before `sched_enable`,
`sched_spawn(kthread_cons, nm_cons)`. But **don't rely on "the first free slot"**: if some shell failed to start for lack of pool pages, `cons` would land in slot 3, and `sh_active=3`
points at TCB 3 — the keyboard would go to `cons`, and shell 4 would never receive a key.

So add `ecx = desired slot (0 = any)` to `sched_spawn`:
`shell_spawn_extra` passes 1/2/3, `cons` passes **4**, and fork scans from **5**.
Slots are therefore fixed as 0–3 shells, 4 cons, 5–11 fork/demo threads. On failure there's one fewer thread: a shell sitting at the prompt can still redraw itself,
but "switching to a shell that's running a program" keeps the old picture until the program's next system call/exit —
write this degradation into known-issues, don't pretend it doesn't exist.

#### 3.3.2 `cons_service`

```asm
cons_service:
    cmp byte [ime_switch], 0     ; collect the IME first: even if no redraw is needed this time, the bar has to go
    je .noime
    mov byte [ime_switch], 0
    cmp dword [fb_bar_active], 0
    je .noime
    call ime_abort
.noime:
    cmp dword [cons_redraw], 0
    je .ret
    mov eax, [cons_redraw]
    dec eax
    cmp eax, [sh_active]
    jne .ret                    ; already switched away again: leave the flag for next time
    mov al, 1
    xchg al, [cons_repaint_busy]  ; set 1; if it was already 1, write 1 back anyway
    test al, al
    jnz .ret                      ; someone is already drawing
    cmp dword [fb_bar_active], 0
    je .nobar
    call ime_abort              ; the overlay sits on top, take it down first (draws two strokes, immediately covered by the full redraw)
.nobar:
    call cons_repaint
    ; we may have been switched away while drawing (an IRQ changed cons_redraw to another target):
    ; clear the flag only if it's still ours, otherwise leave it for next time
    mov eax, [cons_redraw]
    lea ecx, [sh_active]
    mov ecx, [ecx]
    inc ecx
    cmp eax, ecx
    jne .busy_clear
    mov dword [cons_redraw], 0
.busy_clear:
    mov byte [cons_repaint_busy], 0
.ret:
    ret
```

#### 3.3.3 `cons_repaint`

```text
cons_repaint:
  fb_flush                       ; the line buffer may still hold unflushed characters
  pushf; cli
  fb_clear                       ; whole screen black (1.9 MB, once)
  popf
  seq0 = cons_seq[sh_active]
.again:
  for row = 0 .. rows-1:
      if cons_redraw != sh_active+1: return    ; check before starting this row
      pushf; cli
      for col = 0 .. cols-1:
          cell = buf[row*cols+col]
          if cell & CELL_TAIL: continue
          if (cell & 0x1FFFFF) == ' ' and attr background is black: continue
          term_fb_color = fb_color_of(attr)
          fb_putcp_at(cp, row, col)
      popf
      if cons_redraw != sh_active+1: return    ; check again after the row
  if cons_seq[sh_active] != seq0 and retry < 1:
      seq0 = cons_seq[sh_active]
      retry++
      jmp .again                   ; someone wrote while we were drawing: paint once more
  fb_cur_x = cons_cx*8; fb_cur_y = cons_cy*16
  term_color = cons_attr; term_fb_color = fb_color_of(term_color)
```

- Skipping spaces saves most of the work: only a screen full of text comes close to 3,700 characters.
- `fb_clear` is wrapped in `pushf; cli ... popf` (about 1–2 ms), otherwise being switched away halfway through clearing, another screen finishing its redraw,
  and then coming back to continue clearing would wipe out what the other just painted.
- Per row, at most 100 characters + one `fb_flush` inside `cli`, about 0.3 ms; 37 rows total ~10 ms of
  "interrupts-off time", but spread across 37 sections, so the keyboard doesn't lose keys (the interrupt controller buffers at least one).
- **Version check**: `cons_seq` increments per cell written. The redraw records `seq0` at the start and repaints if it changed at the end
  (at most twice); if it still changes, re-raise `cons_redraw` and come back next tick. This way "the foreground printed during the redraw"
  doesn't leave half a screen of stale text.
- **Check `cons_redraw == self+1` at both the start and end of every row**. If we're switched away mid-draw, the new console has already
  redrawn and cleared the flag, and the old redraw must stop immediately, otherwise it smears the new screen.
- `fb_clear` does `fb_lb_forget`, so `fb_flush` before redrawing; after the redraw `fb_lb_row=-1`,
  and the next normal output claims the row again.

#### 3.3.4 Why not draw in the interrupt

- Full screen is 1.9 MB of MMIO; doing that in an interrupt is tens of milliseconds of "the keyboard plays dead"; VirtualBox's MMIO is even slower.
- `fb_*` is all global state; being interrupted by nested interrupts/scheduling halfway through drawing mixes up the line buffer.
- The original design constraint was "only raise a flag in the interrupt, don't redraw in the interrupt"; this only widens "the shell thread" to
  "the shell thread or a dedicated cons thread", which doesn't violate the intent.

#### 3.3.5 Cursor after switching

`shell_switch_to` doesn't touch `fb_cur_*`; when the redraw finishes, `cons_repaint` sets `fb_cur_x/y` from the target console's
`cons_cx/cy`. If output lands in between (theoretically not, since the source thread is still on its way back from the interrupt),
it draws using the old `fb_cur`, and the next redraw corrects it.

#### 3.3.6 On switching back, the half line must not be printed twice

`shell_main`'s `.mine` reprints `shell_buf` via `term_print` when `sh_switch_flag` is set
(the screen is global today, so that's the only way to patch it). In Phase 2 the console buffer already holds that half line, so reprinting would duplicate it.

The approach: record the "input start" and "cursor at switch-away", erase the old half line on switch-back, then print title/prompt/half line:

- `shell_readline`, after painting the prompt and before collecting keys, stores the current `cons_cx/cy` into
  `sh_line_cx[SH_MAX]`/`sh_line_cy[SH_MAX]` (one per shell, plain arrays).
- `shell_switch_to` (IRQ) just stores two more numbers: `sh_ncx[sh_active]=cons_cx[...]`,
  `sh_ncy[...]=cons_cy[...]`; no printing.
- In `.mine`, after `cons_service` and before printing `--- shell N ---`, and **only when `cons_ok && shell_len > 0`**, call
  `cons_erase_input(id, sh_line_cx, sh_line_cy, sh_ncx, sh_ncy)`:
  fill every cell from the input start to the switch-away cursor with `0x07000020`, `cons_seq++`; if `id==sh_active`,
  also erase the old characters on screen with `fb_putcp_at(' ')` (at most 128 cells, ~1 ms).
- Then print title + prompt + `shell_buf` as usual; because the start has already been erased, this copy is the only one;
  after printing, write the new `cons_cx/cy` back to `sh_line_cx/cy`.
- When the half line wraps (over 100 columns), the erase range is "start to end of the first line + whole middle lines + last line up to the cursor";
  `SHELL_LINE_MAX=128`, at most two lines, no need for a general rectangle.

### 3.4 IME overlay: a global overlay, belonging to no buffer

Current state (`kernel/ime.asm`):

- `ime_show` (:208) first `fb_bar_begin`, saves the **pixels** of the screen's last two lines into the 26-page restore buffer,
  then clears them to black and draws the candidates (first line) and the pinyin echo (second line) cell by cell with `term_puts_at`;
  `fb_bar_end` pastes the original pixels back. `fb_bar_active` remembers "the bar is still up".
- It **doesn't wrap and doesn't touch the command line**, so `term_puts_at` isn't wired into the console buffer — characters on the bar
  shouldn't become the shell's history output.

Phase 2 rules:

| Question | Decision |
|---|---|
| Who owns the bar | **Only the active console**. A background thread calling `ime_show` returns immediately (add a `cons == sh_active` check) |
| On switch-away | `shell_switch_to` just sets `ime_switch=1`; `cons_service` calls `ime_abort` before redrawing (collect the bar, clear `ime_*` state) |
| On switch-back | The composition is gone, not restored. This is **intentional**: restoring half a pinyin is more confusing than dropping it |
| Bar pixels | `fb_bar_end` first pastes the old pixels back (the old console's picture), and `cons_repaint` immediately covers the whole screen, so nothing remains |
| "Bars" a program draws itself | Things an editor draws with API 13 `puts_at` don't enter the buffer and are gone after switching away and back; the program must be able to redraw the whole screen itself (EDIT redraws when a key is pressed). Add a `cons == sh_active` check at the `term_puts_at` entry; background program calls return immediately, so it doesn't draw on someone else's screen |

> The code that consumes `ime_switch` is the start of `cons_service` in §3.3.2: collect the bar first, then check the redraw flag.
> Only collecting the bar when `cons_redraw` is non-zero would miss "switch back to a shell sitting at the prompt".

> The overlay is only two lines (9 candidates on the first line, pinyin on the second), `IME_BUF_MAX=12`, no conflict with 100 columns.

### 3.5 Keyboard: one 64-byte ring per console

Current state is one global ring `kbd_buf` (64 B) + `kbd_head/kbd_tail`, with `kbd_push` in IRQ1.

Phase 2:

```asm
KBD_BUF_SIZE  equ 64
kbd_buf       times KBD_BUF_SIZE * SH_MAX db 0   ; 256 B
kbd_head      dd SH_MAX dup(0)
kbd_tail      dd SH_MAX dup(0)
```

| Function | Change |
|---|---|
| `kbd_push(al)` | index = `[sh_active]` (inside the IRQ, sh_active is "who owns the keyboard now"); drop when full, as before |
| `kbd_avail` | index = `[space_cur+TCB_CONS]`; return the number of readable bytes for that console |
| `kbd_consume(ecx)` | same; advance that console's tail |
| `kbd_seq_len` | same; inspect the ESC sequence at the tail of that console's queue |
| `kbd_getkey/kbd_getchar` | read only their own console; if empty / not the active console, `pushfd; sti; hlt; popfd` and wait |

Key points:

1. **IRQ1 pushes keys using `sh_active`; readers use their own `TCB_CONS`**. The two are usually equal; when they're not
   (a background program is reading), it reads no keys at all — all keys go to the active console. That's exactly the desired behavior.
2. A background program's `kbd_getchar` **goes to sleep**, not busy-waits; only when `Ctrl+←/→` makes it active
   does the IRQ deliver keys to it. `ECHO` in the ecosystem won't steal characters in the background.
3. `Ctrl+←/→` is swallowed by `shell_switch_step` in the IRQ and never enters any ring.
4. `shell_wait_key` still checks `sched_cur == sh_active` first and returns 0 otherwise; it also reads the
   `sh_active` ring, equivalent to before.
5. The line buffer doesn't change: `sh_nbuf/sh_nlen/sh_ndir` were already per-shell; a program reading keys doesn't go through
   shell line editing.
6. **`kbd_push(0)` is the wakeup pseudo-key**: `shell_switch_to` uses it to kick a `hlt`ed reader awake, but
   `kbd_getchar` currently returns 0 as an ordinary key — a background `ECHO` prints an extra
   `[0:0x00]`. Phase 2's `kbd_getchar/kbd_getkey` should `jmp .loop` on reading 0
   (key code 0 was never a valid character anyway); or switch to the two-stage "set the wake flag first, then hlt".
   Leave this unfixed and the dual-screen switching tests get polluted by pseudo-keys.

### 3.6 Protecting global buffers: one scheduler-level big lock

#### 3.6.1 The problem

`int 0x30` is an `IF=0` interrupt gate, so **the inside of a system call is naturally non-preemptible**; but when a shell thread itself
calls `fat_*` with `IF=1`, it can be switched away by IRQ0, and another shell thread may enter `fat_read_file` at the same time.
`FAT_BUF` (0x100000), `[fat_dir]`, `ata_*`, `lfn_*` are all single copies, so they're bound to trample each other.

Converting every function to reentrant (one buffer per thread) would mean touching 2,378 lines of FAT code, with risk and payoff out of proportion.
Phase 2 uses one **scheduler-level big lock**:

```asm
; kernel/sched.asm
sched_noswitch  dd 0        ; when >0, sched_pick doesn't switch people

; critical section enter/exit (nestable)
fs_lock:
    inc dword [sched_noswitch]
    ret
fs_unlock:
    dec dword [sched_noswitch]
    ret
```

`sched_pick`, after saving esp/cr3 and bumping the tick:

```asm
    cmp dword [sched_noswitch], 0
    jne .same                   ; return the original esp, don't switch (IRQs still fire, EOI still sent)
```

Why better than `cli`:

- An ATA PIO read of a 384 KiB program takes **tens to hundreds of milliseconds**; a whole-section `cli` would drop keys and slow the clock.
- `sched_noswitch` only prevents "switching threads"; IRQ1/PIT still come in, keyboard bytes enter the ring (64-byte cap,
  enough), `pit_ticks` keeps ticking.
- On a single CPU `inc dword [mem]` is a single instruction, and interrupts only happen between instructions, so no `lock` needed.

#### 3.6.2 What to cover

For these **top-level entries**, `call fs_lock` as the first instruction and `call fs_unlock` as the last
(including failure paths):

| File | Functions |
|---|---|
| kernel/fat.asm | `fat_path`, `fat_stat`, `fat_read_file`, `fat_write_file`, `fat_chdir`, `fat_list`, `fat_mkdir`, `fat_unlink`, `fat_rmdir`, `fat_alloc_cluster`, `fat_set_entry`, `fat_find`, `fat_find_run`, `fat_write_run` |
| kernel/ata.asm | `ata_read_sectors`, `ata_write_sectors` |

Internal helpers (`fat_next_cluster`, `fat_scan_*`, `lfn_*`) **don't take the lock again**; the caller is assumed to hold it;
`fs_lock`/`unlock` use a counter so nesting works.

Things you must **never** do inside a held section: `hlt`, `pit_wait_ticks`, `loader_lock`, waiting for the keyboard.
Today's FAT/ATA paths only poll ports/read sectors, which satisfies this. Typical hold times:
reading one directory sector <1 ms; reading a 384 KiB program about 0.1–0.4 s (QEMU); other shells will "stall for a moment" during that,
but the keyboard, clock, and screen are all still alive — a deliberate trade-off.

#### 3.6.3 `fat_dir` becomes per-thread

`fat.asm` reads `[fat_dir]` directly all over the place; we don't touch that; instead **save/restore a snapshot on thread switch**:

- TCB gets `TCB_CWD` (offset 116). It's called CWD, but it stores the **raw `[fat_dir]` value at the instant of switch-out**,
  not the "logical current directory" — this distinction matters.
- `sched_pick`, every time it really switches:
  before switching out `mov eax,[fat_dir]; mov [old TCB+TCB_CWD],eax`;
  after switching in `mov eax,[new TCB+TCB_CWD]; mov [fat_dir],eax`.
- **Don't write `TCB_CWD` separately in `cmd_cd`**: for one, `shell_execute_plain` restores `fat_dir` from `saved_dir`,
  so a separate write gets overwritten; for another, a shell thread may be switched away inside `fat_path`, and at that moment `fat_dir`
  is a "half in, half out" temporary value — exactly the value needed to restore the scene, while the "logical cwd" is not.
  Storing the raw snapshot solves both cases at once.
- Keep `cmd_run`'s `cmd_saved_dir` (it guards against "fat_path temporarily chdirs during loading").
- Keep `api.asm`'s `api_saved_dir` for the file API too, as belt and braces.

#### 3.6.4 Pipes

`pipe_*` is a single global. Two shells running `A | B` at the same time get crossed. Minimal fix:

```asm
pipe_busy  dd 0
; at the start of shell_pipe_execute:
.retry:
    mov al, 1
    xchg [pipe_busy], al
    test al, al
    jz .got
    hlt
    jmp .retry
.got:
    ; ... the whole chain ...
    mov dword [pipe_busy], 0
```

`hlt` only appears here (the caller is a shell thread, `IF=1`). The second shell waits instead of erroring;
if you don't want to wait, you can also print "another shell is running a pipe" and return — either is fine, but I recommend **waiting**
(pipes usually finish within seconds; an error is more annoying).

#### 3.6.5 Other shared state

| State | Handling |
|---|---|
| `evt_log` ring of 16 | entry `pushf; cli`, `popf`; inside IRQs `IF=0` anyway, nesting-safe |
| `loader_busy`(`loader_lock`) | keep; only used from shell threads, `hlt` while waiting |
| `prog_size/prog_entry/name_buf/PROG_ARG_ADDR` | already covered by `loader_lock`; don't read outside the lock |
| `term_color/term_fb_color` | per-console `cons_attr`, recomputed before drawing; the globals only mean something in the active thread |
| `fb_*` | only the active console draws; wrap every `fb_*` call in `cli` (§3.2.5) |
| `sh_active/sh_switch_flag` | written only by IRQs; read by threads, single byte/dword, naturally atomic |
| `space_cur` | per-thread, maintained by `sched_pick`, already the status quo |
| `sched_kill`'s "check → free stack" | wrapped in `pushf; cli ... popf` in `cmd_kill`, otherwise after the check you might be switched to the target thread and then free its stack out from under it |
| `pmem_free_count/alloced` | only changed with `cli` or inside an `IF=0` syscall; also `cli` before `debug pmem` reads it |

### 3.7 Memory and page budget

| Item | Pages | Notes |
|---|---:|---|
| 4 console buffers | 16 | `cons_init` takes them once, resident |
| `cons` thread kernel stack | 2 | `sched_spawn`'s 8 KiB |
| TCB table | 0 | BSS, 8 × 120 = 960 B |
| Code | ~5 KiB | counted in the kernel image, doesn't use the pool |
| **Total** | **18 pages** | 72 KiB, default pool 30,207 pages |

Add a section to the `layout` line (where `kmain` prints layout):

```text
... pool=0x00400000-0x079ff000 pages=30207 cons=16
```

The tests' `expected_free_pages()` (qemu_test.py:1005) currently subtracts 45; Phase 2 subtracts
`45 + layout_val("cons") + (2 if cons > 0 else 0)` (the cons thread stack), i.e. **63** by default.
Don't hardcode 63, read it from layout: with `-m 8`, `cons=0` and the `cons` thread didn't start either, so only subtract 45.

### 3.8 Test plan (Phase 2)

Two changes to the test harness first:

1. `expected_free_pages()`: subtract `layout_val("cons")` and the cons thread's 2 pages.
2. `ps` assertion: `4 alive / 6 slots` → **`5 alive / 8 slots`**, plus one more `cons` line.

Add a `test_shell_consoles()` to the `--shell` suite in `tests/qemu_test.py`
(right after the existing multi-shell test around :1500), all using **graphics-mode OCR** (`screen_text(shot, glyphs)`),
not reading `0xB8000` — there are no characters there under VBE.

| # | Action | Assertion |
|---:|---|---|
| 1 | boot `shell` | `shells: 4`; `consoles: 4 x 100x37` (or the `cons` command) |
| 2 | shell 1 `echo alpha-only` | screen has `alpha-only` |
| 3 | Ctrl+→ to shell 2 | **no** `alpha-only`; shell 2's own prompt |
| 4 | shell 2 `echo beta-only`; Ctrl+← | `alpha-only` present, `beta-only` **absent**; Ctrl+→ reverses it |
| 5 | shell 1 types `echo half` (no Enter); switch away and back | `half` still there; Enter executes it |
| 6 | shell 1 `run HANG`; Ctrl+→; shell 2 `run ECHO` | `ECHO test: press keys`; proves both shells really run programs simultaneously |
| 7 | type `abc`, `q` in ECHO | echoes `[0:0x61]` etc.; finally `ECHO done.` |
| 8 | Ctrl+← back to shell 1 | `this shell is stuck now` / `still spinning` still there (the buffer held) |
| 9 | wait for `done spinning`; `echo back` | `back`; shell 1 is usable again |
| 10 | `debug pmem` | `free` pages == `expected_free_pages()` |
| 11 | `ps` | `5 alive / 8 slots`, `cons` present |
| 12 | IME: shell 1 `run EDIT`; Shift; type `nihao`; Ctrl+→; Ctrl+←; Esc | no graphical corruption; bar gone; prompt comes back |

**Demo script** (manual demo / for video):

```text
shell 1: run HANG            # red text, starts spinning
Ctrl+Right                    # screen 2: a clean second screen, not HANG's text
shell 2: run ECHO             # two programs running at the same time
         abc q
Ctrl+Left                     # screen 1: HANG's "still spinning" / "done spinning" still there
shell 2: kill 0               # kill HANG's program from the other shell (SP_KILLREQ)
shell 1: echo back            # teardown done, prompt back
```

Small-memory regression: `qemu -m 8` (no page pool) should print `cons: disabled (no page pool)` at boot,
Ctrl+←/→ still only switch the keyboard; all console assertions are skipped.

### 3.9 Code size, risks, checklist

| File | New/changed | Estimated lines |
|---|---|---:|
| kernel/cons.asm (new) | buffers, `cons_putcp/byte`, scrolling, redraw | ~380 |
| kernel/vgafont.asm | `term_print_cp` one `jne` → `call` | 2 |
| kernel/kmain.asm | `cons_init`, hooks, layout, `cons` thread | ~60 |
| kernel/keyboard.asm | per-console rings + wait `sti/hlt` | ~70 |
| kernel/fat.asm / ata.asm | `fs_lock/unlock` calls | ~40 |
| kernel/sched.asm | `TCB_CONS/CWD`, `sched_noswitch`, CWD sync | ~30 |
| kernel/shell.asm | switch flag, `cons_service`, pipe lock (`cd` does **not** write CWD) | ~60 |
| kernel/pipe.asm | `pipe_owner`, `pipe_busy` | ~30 |
| kernel/ime.asm | active-console checks, `ime_switch` | ~20 |
| tests/qemu_test.py | 12 assertions + page-count formula | ~120 |
| **Total** | | **~800 lines, ~5 KiB** |

Main risks:

| Risk | Impact | Mitigation |
|---|---|---|
| Full-screen redraw too slow (VirtualBox MMIO) | switching stalls 0.1–1 s | skip spaces; draw only rows that have text; worst case degrade to "draw only the first 30 rows", configurable |
| Background programs still write to the global `fb_*` | graphical corruption | every output checks `cons == sh_active` first; the background only writes the buffer |
| `kbd_getchar`'s `hlt` not fixed | sleeps forever in the API | P0.1 must be done first |
| Long `fs_lock` sections starve other shells | switching over looks stuck | hold the lock only around real FAT/ATA; no `hlt`; document the worst-case magnitude |
| Console buffers eat the pool (small memory) | won't boot | `cons_ok=0` fallback; `-m 8` assertion |
| IME bar residue | corruption after switching | `ime_abort` + full redraw; no guarantees for bars a program draws itself |
| `SCHED_MAX` changed but 6 hardcoded somewhere | TCB out of bounds / one fewer ps entry | `TCB_OFF` macro; grep the repo for `SCHED_MAX`/`TCB_SIZE` |
| Tests still read VGA as 80×25 | all red | use OCR; `term_size` under VBE is 100×37 |

Phase 2 checklist:

- [ ] P0.1–P0.5
- [ ] `TCB_CONS/TCB_CWD`, `TCB_SIZE=120`, `SCHED_MAX=8`
- [ ] `cons_init`: 16 pages, fill with spaces, layout line
- [ ] `cons_putcp/cons_putc_byte/cons_clear/cons_newline` + hooks
- [ ] per-console keyboard rings + `sti/hlt` waiting
- [ ] `shell_switch_to` sets `cons_redraw/ime_switch`
- [ ] `cons_service/cons_repaint` + `cons` thread
- [ ] `fs_lock/sched_noswitch` + FAT/ATA entries
- [ ] `TCB_CWD` sync (`sched_pick` saves/restores the raw `fat_dir`; `cmd_cd` doesn't write it)
- [ ] `pipe_owner/pipe_busy`
- [ ] 12 tests + `expected_free_pages`
- [ ] README/known-issues sync (delete "only one program runs at a time")

---

## 4. Phase 3: fork and copy-on-write

After Phase 1, every thread already has its own `SP_PD/SP_PT`; what Phase 3 does is:
**copy a page table, but don't copy the physical pages yet** — copy a page only when someone writes to it. The hard part isn't "copying",
it's "knowing how many people are using a page" — which is exactly why the refcount table exists.

### 4.1 ABI: 3 new function numbers

The existing `int 0x30` function numbers are 0–17 (`api_dispatch` in `kernel/api.asm`). The next free one is **18**,
then 19, 20. Phase 3 uses:

| # | Name | Arguments | Returns | Notes |
|---:|---|---|---|---|
| 15 | `exit` | `ebx` = exit code | doesn't return | used to ignore `ebx`; now stores it in `TCB_EXITCODE` |
| **18** | `fork` | none | parent: `eax` = child tid (>0); child: `eax` = 0; failure: `eax` = -1 | duplicates the current process |
| **19** | `wait` | `ebx` = child tid; `0xFFFFFFFF` = any child | `eax` = exit code; no children/error `eax` = -1 | blocks until a child exits |
| **20** | `gettid` | none | `eax` = current tid | for logging/debugging |

Conventions follow the existing `api_stub` (`api.asm:70` onward):

- `eax` = function number, `ebx/ecx/edx/esi/edi` are arguments; **only `eax/ebx/esi` are written back** to the user
  (`[esp+28]/[esp+16]/[esp+4]`), and the user guarantees `ecx/edx/edi/ebp` stay unchanged.
- Entry is the `0xEE` DPL3 interrupt gate (IF=0), so **fork itself is atomic**; the timer can't cut in
  "halfway through copying the page table".
- `fork` returns -1 for three reasons: no free TCB slot, not enough page pool (PD/PT + 2 stack pages),
  or some page's refcount is already 15 (see §4.4).
- `wait` is the only system call that **actively enables interrupts**: a `pushfd; sti; hlt; popfd` rescan loop,
  otherwise `hlt` with IF=0 would never wake up (Phase 2's P0.1 is the same class of bug).

`api_usage` text needs 18/19/20 added; sync `docs/api.md` (if it exists). **`fork+exec` is not implemented**:
the new process runs the same code as its parent; to change programs, `exit` and then `run` from the shell — deliberate scope control.

### 4.2 TCB: 4 more fields, growing to 144 bytes

| Offset | Field | Notes |
|---:|---|---|
| 0–108 | existing (112 B) | ESP/CR3/STATE/…/SP_KILLREQ |
| 112 | `TCB_CONS` | Phase 2: console number |
| 116 | `TCB_CWD` | Phase 2: `fat_dir` snapshot |
| **120** | `TCB_PARENT` | parent tid; `-1` = not created by fork |
| **124** | `TCB_EXITCODE` | exit code stored by `exit(ebx)` |
| **128** | `TCB_PFCOW` | how many pages this process has copied due to COW (stats/tests) |
| **132** | `TCB_FLAGS` | bit0 = forked; bit1 = exiting (tearing down) |
| 136/140 | reserved | align to 144, so adding fields later doesn't shift anything again |

`TCB_SIZE` **120 → 144** (Phase 2 already moved 112 to 116); `SCHED_MAX` **8 → 12**. Why 12:

- 4 shells + 1 `cons` thread = 5;
- fork children need slots — 6 spare;
- 12 × 144 = 1,728 B, the TCB table is still a small patch of BSS.

`sched_spawn` initializes the new fields: `PARENT=-1`, `EXITCODE=0`, `PFCOW=0`, `FLAGS=0`.
Add `ST_ZOMBIE=3` to the state machine (exited, waiting for the parent to collect it); `sched_pick` only picks `ST_ALIVE`,
so zombies are never scheduled. `ps` must show `zombie` and `parent=N`.

> Growing the TCB from Phase 1's 112 to 144 in two steps (Phase 2 goes to 120) touches every use of `TCB_OFF`/`TCB_SIZE`
> (`sched.asm`, `paging.asm`, `shell.asm`, `pit.asm`, `api.asm`). Use macros everywhere; don't hand-write 112.

### 4.3 Copying the page tables: change permissions first, then talk about copying

#### 4.3.1 Order matters

```text
sched_fork:
  1. find a free slot from 5 on (0–4 are shell/cons); if none → eax=-1
  2. pre-allocate: PD 1 page, PT 1 page, child kernel stack 2 pages (4 pages total); failure → back out everything, -1
  3. first scan the **parent** PT: if any present+USER page already has refcount 15 → free the 4 pages from step 2,
     return -1 (4 bits can't hold a 16th sharer)
  4. mark the **parent** PT 0..1023: present && USER →
         pmem_ref_inc(pa); PTE |= PAGE_COW; PTE &= ~PAGE_RW
  5. copy: parent PD whole page 1024 dwords → child PD; parent PT whole page 1024 dwords → child PT
     (the parent PT is already COW/read-only at this point, so the child PT inherits it naturally); then
     `child PD[0] = child PT | P|RW|USER` — fail to fix this and the child keeps using the parent's page table, making fork pointless
  6. flush the parent's TLB: mov eax,cr3; mov cr3,eax   ; otherwise the parent still holds writable stale TLB entries
  7. build the iret frame at the top of the child stack (see §4.3.2); fill in the TCB; TCB_ESP/TCB_SP_RUNESP
     (SP_STAGE_PA/SP_STAGE_PAGES **copied from the parent**, and `pmem_ref_inc` each staging page — parent and child
      share the same image staging area, and neither may pull it away when it exits first; SP_KILLREQ=0, SP_RUNSTAT=0,
      SP_LIVE=1, SP_RUNNING=1; SP_PAGES/SP_IMGBYTES/SP_HEAPPAGES/SP_ARGSVA/
      SP_STACKVA/SP_STACKTOP copied from the parent; SP_PFRUN/PFIMG/PFHEAP/FIRSTPA/SP_FREED=0)
  8. ++sched_live; eax=child tid
```

**Allocate first, mark later** is deliberate: the marking phase only does "inc + or/and" and cannot fail;
that way there's no mess of "half-marked, need to roll back". 4 pages out of a 30,207-page pool is almost impossible to fail,
but still check in step 2 and return what was allocated on failure.

#### 4.3.2 The child thread's first scheduling

The child thread doesn't start from `sched_spawn`'s "kernel thread entry"; it starts **at the instruction after `int 0x30`**,
so an "interrupt return" frame has to be arranged on the stack, so that `irq0_stub`'s tail can `iret` straight into
user mode:

```text
        ┌──────────────┐  ← child stack top (end of the 8 KiB page), TCB_SP_RUNESP
        │ SS3          │
        │ ESP3         │   iret frame (5 dwords, 20 B)
        │ EFLAGS       │
        │ CS3          │
        │ EIP          │
        ├──────────────┤
        │ error code 0 │
        │ vector 0x20  │   irq0_stub's add esp,8 throws these away
        ├──────────────┤
        │ EDI … EAX    │   pushad's 8 dwords (32 B)
        └──────────────┘  ← TCB_ESP = stack top - 60
```

- `EIP/CS3/EFLAGS/ESP3/SS3` are copied from the `api_stub` frame. **Mind the base**: when entering
  `api_dispatch`, `esp` points at gs (after `api_stub` pushed pushad + the four segment registers); record that `esp`
  as `frame` (in `api_dispatch`'s case 18, `lea esi,[esp+4]` skips the `call` return address, then `call sched_fork`), then
  `[frame+48]=EIP`, `[frame+52]=CS`, `[frame+56]=EFLAGS`, `[frame+60]=ESP3`,
  `[frame+64]=SS3`; pushad's eight registers are at `[frame+16..44]`. Inside `sched_fork` use
  `esi` rather than `[esp+48]`, otherwise the return address pushed by `call` throws you off.
- **`EAX` must be set to 0** — the child returns 0 from `fork`; the other registers are copied verbatim (parent and child see the same
  `ebx/ecx/edx/…`, which is fork semantics).
- `TCB_SP_RUNESP = stack top` (not stack top - 60): `sched_pick` writes it into `TSS.esp0`,
  and on ring 3's first interrupt the CPU pushes down from the stack top, consistent with the existing `cmd_run` approach.
- The child thread's `TCB_CR3 = the new PD`; the first time `sched_pick` selects it, `mov cr3` takes effect —
  no need to switch manually inside fork.

#### 4.3.3 Which pages get marked COW

The walk is over **the parent PT's entries 0..1023**, condition `present && PAGE_USER`; after marking, the whole page is copied to the child,
and the child PT naturally inherits the same COW/read-only entries. **Don't only mark the child PT** — the parent's PTEs would still be RW,
the parent's writes wouldn't fault at all, and the child would keep seeing whatever the parent writes later, so COW would leak half its purpose.

| Page | Position in the PT | Marked? |
|---|---|---|
| image window 0x120000–0x17FFFF | 288–383 | only pages already faulted in are present, and get marked |
| heap window 0x180000–0x3AFFFF | 384–943 (560 pages at 128 MiB) | only pages already faulted in are present, and get marked |
| trampoline page 0x17F000 | 383 | marked (it's really the last page of the image window) |
| user stack page | `SP_STACKVA` | marked (mandatory) |
| argument page | `SP_ARGSVA` | marked |
| the kernel identity mapping in this PT | 0–287 (0–0x11FFFF), 944–1023 (0x3B0000–0x3FFFFFF) | **not marked** (no `PAGE_USER`) |

> The two windows are **back to back**: `SPACE_IMG_PAGES=96` is exactly 0x60000 bytes, the image window is
> 0x120000–0x17FFFF, and the heap window starts right at 0x180000. `space_create` clears `96 + SP_HEAPPAGES` entries from PT index 288,
> which is exactly this one contiguous address range. The COW walk uses the
> "present + USER" test and doesn't depend on window boundaries; but when computing PT indices, don't treat the two stretches as unrelated.

- Non-present pages (not yet faulted in) aren't marked: whoever touches one first faults it in, no interaction.
- After marking, `mov cr3` must flush the TLB; otherwise a page the parent just wrote is still RW in the TLB, the write doesn't
  fault, and COW leaks.
- **The staging page (SP_STAGE_PA) is not COW**: it's in kernel space, shared read-only, so just inc_ref and parent and child
  share it; on destruction each decrements, and the last one returns the page.
- **The refcount cap of 15** is a hard 4-bit limit: one physical page can be shared by at most 15 address spaces,
  and the 16th sharer can't join. If any page is already at 15 before a fork, return -1 immediately; the practical meaning is
  "at most 15 address spaces share one page", so a single fork chain is limited to 14 levels of depth (parent page starts at 1, +1 per fork level).

#### 4.3.4 The cost of 4 pages

| Allocation | Pages | Freed by |
|---|---:|---|
| child PD | 1 | `space_destroy_at` |
| child PT | 1 | `space_destroy_at` |
| child kernel stack | 2 | `pmem_free_pages` when `wait` reaps |
| **newly allocated per fork** | **4 pages** | the parent's staging page only gets its refcount bumped, not copied |

Not a single user page is copied — that's why fork is cheap. A 3,700-cell console buffer takes only 4 pages,
so one fork is the same order of magnitude as it.

### 4.4 The refcount table: half a byte per page

#### 4.4.1 Size and location

| Item | Value |
|---|---:|
| max pages in the pool | 64 512 (`PMEM_BITMAP` 8 KiB, one bit per page) |
| count per page | 4 bit (0–15) |
| table size | 64 512 / 2 = **32 256 B = 8 pages** |
| actual pages at default 128 MiB | 30 207 |
| actually used | 30 207 / 2 = **15 104 B ≈ 4 pages** |

Location: **0x3D2000**, right after the page-pool bitmap `0x3D0000–0x3D1FFF`, reserved up to 0x3D9FFF (8 pages).
Verified: 0x3D2000–0x3D9FFF has no users in the current repo (`grep -i 3d2/3d3…` only hits
false positives in `kernel/arm64/`); USB uses up to 0x3C2FFF and PINYIN up to 0x3BFFFF, no conflict.

```asm
PMEM_REF equ 0x3D2000          ; kernel/pmem.asm
```

```text
0x3D0000 ┌──────────────┐ page-pool bitmap 8 KiB (one bit per page)
0x3D2000 ├──────────────┤ refcount table 32 KiB (max 8 pages; 15 104 B used by default)
0x3DA000 └──────────────┘
```

`pmem_init` clears the 8 pages with `rep stosd`. Why not "grow on demand": the table is at a static address, so
`pmem_alloc` can compute it directly from interrupts/system calls without chasing a pointer.

#### 4.4.2 Encoding

```text
byte[pa>>12 / 2]:
   low 4 bits = count for even page numbers
   high 4 bits = count for odd page numbers
```

```asm
; eax = physical address → edi = byte address of this page's nibble, cl = half offset (0 or 4)
pmem_ref_ptr:
    mov edx, eax
    shr edx, 12
    mov ecx, [pmem_start]
    shr ecx, 12
    sub edx, ecx               ; page number (0-based within the pool)
    mov ecx, edx
    shr edx, 1
    and ecx, 1
    shl ecx, 2                 ; 0 or 4
    lea edi, [PMEM_REF + edx]
    ret
```

#### 4.4.3 Three primitives

| Function | In/out | Semantics |
|---|---|---|
| `pmem_ref_get(eax=pa)` | `eax` = count | returns 0 outside the pool / not allocated |
| `pmem_ref_inc(eax=pa)` | `eax` = new count; `CF=1` = overflow (already 15) or page not allocated | on overflow **doesn't modify** the table |
| `pmem_ref_dec(eax=pa)` | `eax` = new count; `CF=1` = it was already 0 | **on reaching 0, clears the bitmap and `--pmem_free_count` along the way** (i.e. really returns the page) |

#### 4.4.4 Wiring into the existing allocator

| Existing function | Now | Phase 3 |
|---|---|---|
| `pmem_alloc` | `bts` then return | after `bts`, `ref=1` |
| `pmem_alloc_pages` | same | `ref=1` per page |
| `pmem_free` | `btr`, decrement count | validate alignment/range/bitmap then call `pmem_ref_dec`; if `ref` was 0 → `CF=1` |
| `pmem_free_pages` | loops `pmem_free` | returns the number of pages "really returned to the pool" (i.e. decs that reached 0) |

**Critical semantics**: `pmem_free` no longer means "must return a page". Calling it on a shared page just means "I'm done with my share";
the bitmap stays set and `pmem_free_count` doesn't change. That way `debug pmem`'s free count is always
"pages that can really be allocated", and the tests' `expected_free_pages` can't be fooled by shared pages.

Double-free still returns `CF=1` (`ref` is already 0 → the caller is wrong), keeping the existing assertion.

### 4.5 Page fault: present + COW + write

The existing `page_fault_try_handle` (`paging.asm:472`) only handles "page not present". Phase 3 adds a section at the very front:

```text
page_fault_try_handle:
    ; idt.asm adds one line before the call: mov ecx,[ebp+36] (error code in the ISR frame)
    mov [pf_err], ecx
    ; new: a present write fault might be COW
    test byte [pf_err], 1       ; error code bit0 = present
    jz .not_present
    test byte [pf_err], 2       ; bit1 = write
    jz .fail                    ; read fault on a present page: not COW, hand back up
    ; fetch the PTE, check PAGE_COW
    ...
    test eax, PAGE_COW
    jz .fail
    ; got here: it definitely is COW
    pmem_alloc_pages(1)
    jz .oom
    memcpy 4 KiB: source = old physical page (identity-mapped), destination = new page
    PTE = new pa | P | RW | USER   ; drop COW
    invlpg [cr2]
    pmem_ref_dec(old pa)
    ++[space_cur+TCB_PFCOW]
    return 1                    ; iret re-executes that write instruction
```

Key points:

1. **Test `present` from error-code bit0; don't guess from `space_live`**. A COW fault's PTE is
   present, and the existing "PTE already present → return 0" path would let it slip through, so this must go **before** that.
2. `CR0.WP` must be set to 1 (`or eax, 0x00010000` in `paging_init`, together with `0x80000000`).
   Otherwise kernel-mode writes to read-only pages don't fault, `copy_to_user`-style paths bypass COW, and parent and child share the same page
   while both believe they own it. Phase 1 currently only does `or 0x80000000`; this is a **hard prerequisite** for Phase 3.
3. Kernel-mode (CPL=0) COW writes must be handled too: a system call writing a user buffer (say `read` reading a file
   into an address the program supplied) happens under the parent's/child's own CR3, and the PTE may already be COW+read-only. The handling is
   the same; don't use "CS&3==3" to reject kernel mode.
4. The old page's `pmem_ref_dec`: on reaching 0 it clears the bitmap and returns the page itself (the current mapping already points at the new page, so the old page may
   really have nobody left). **Don't call `pmem_free` again**, or you'll decrement twice.
5. **OOM**: print `cow: out of memory` and then **return 0** (not 1), handing the decision back to
   `idt.asm`: it already has the "user mode → `prog_kill_from_fault`" path, don't duplicate it in the handler.
   Kernel mode (CS&3==0) keeps going to panic — the kernel has no "kill somebody" semantics.
6. Non-COW present write faults (protection violations) return 0 unchanged and keep going through the existing panic/kill decision;
   don't swallow them.

`invlpg` flushes only the current CR2 page; the parent's TLB was already flushed at fork time, and the child has just loaded CR3,
so it has no stale entries.

### 4.6 Destruction: only decrement refs, don't blindly return pages

`space_destroy_at` (`paging.asm:625`) is currently "present → `pmem_free`". Change it to:

```text
space_free_window:
  for each present PTE:
      pa = PTE & 0xFFFFF000
      PTE = 0
      pmem_ref_dec(pa)
      if dec returned "reached 0" → ++sd_pages   ; really returned to the pool
  finally invlpg or reload cr3

space_destroy_at:
  SP_LIVE=0
  release the image/heap windows (by PT entries, not by window name)
  pmem_free(SP_PT) / pmem_free(SP_PD)   ; private pages, ref must be 1
  for pa = SP_STAGE_PA .. +PAGES: pmem_ref_dec(pa); ++sd_pages only if 0
  return sd_pages
```

- **PD/PT are not shared**: every fork allocates new ones and copies whole pages, so destruction calls `pmem_free` directly (their
  ref is 1). Don't apply dec-ref semantics to them, otherwise the parent's PD gets taken away by a child's mistaken destroy.
- Pages in the image/heap windows, stack pages, the argument page, and the trampoline page may all be shared, so they must go through refcounting.
- `SP_STAGE_PA` is the kernel staging area from loading, **not in the user page table**, so it's never marked COW; after fork, parent and child
  share it, and destruction also dec-refs (every fork inc'd it). You can't `pmem_free` the whole range directly —
  while the parent is still running that would yank the staging area away, and the parent's next image fault would be filled with zero pages.
- When a child exits it calls `space_destroy_at(space_cur)`, and the parent's pages are still alive (ref>0);
  the parent subsequently reading/writing its own pages is unaffected — exactly what COW wants.
- The return value only counts pages "really returned to the pool"; `after_prog`'s printed `address space destroyed N page(s)`
  gets smaller in shared scenarios, and that's correct: those N pages weren't returned anyway.

### 4.7 exit / wait / zombies

#### 4.7.1 Two exit paths

Currently `api_exit` has only one path:

```asm
mov edx, [space_cur]
mov esp, [edx + TCB_SP_RUNESP]
segs = GDT_KDATA
cr3 = PD_ADDR
jmp run_resume_kernel        ; → space_deactivate; sti; popad; jmp cmd_run.after_prog
```

The premise of this path is "this thread entered via `cmd_run`'s `pushad`" — true for shell/cons threads,
**not true for fork children**: their kernel stack only has the §4.3.2 iret frame, no `cmd_run`
`pushad` frame, and `run_resume_kernel`'s `popad` would pop SS3/ESP3 from the iret frame as registers.

So `api_exit` must branch:

```asm
api_exit:
    mov edx, [space_cur]
    test byte [edx+TCB_FLAGS], 1      ; bit0 = forked
    jnz .forked_exit
    ; original path: shell / cons threads
    mov esp, [edx+TCB_SP_RUNESP]
    ...
    jmp run_resume_kernel
.forked_exit:
    mov eax, [edx+TCB_EXITCODE]       ; api_dispatch stored ebx in case 15
    call child_exit                   ; see below
```

#### 4.7.2 `child_exit`: turn yourself into a zombie, then switch away

```asm
; eax = exit code
child_exit:
    mov edx, [space_cur]
    mov [edx+TCB_EXITCODE], eax
    or  dword [edx+TCB_FLAGS], 2      ; exiting
    mov edi, [sched_cur]
    call sched_orphan_children        ; live children go to thread 0, zombie children are reaped on the spot
    mov edx, [space_cur]
    call space_deactivate             ; SP_LIVE=0, cr3=PD_ADDR (can't free the PD while still on the child's CR3)
    mov edi, edx
    call space_destroy_at             ; settle the address space books (clears SP_RUNNING)
    mov edx, [space_cur]              ; destroy may have changed edx, fetch it again
    mov dword [edx+TCB_STATE], ST_ZOMBIE
    mov dword [edx+TCB_SP_RUNNING], 0
    ; can't return: this stack is about to be discarded
    mov dword [sched_save_esp], esp   ; store it anywhere, a zombie is never scheduled again
    call sched_pick                   ; returns the next ALIVE thread's TCB_ESP
    cmp eax, [edx+TCB_ESP]            ; am I the only one left?
    je .lonely
    mov esp, eax
    popad                             ; the target thread's irq0 frame
    add esp, 8                        ; error code + vector
    iret                              ; back to where it was switched away
.lonely:
    cli
    hlt                               ; nobody else to run, stop here
    jmp .lonely
```

Why this works: every **schedulable** thread's `TCB_ESP` either points at the `pushad` block `irq0_stub` saved
(preempted by the timer), or at the same place where it was switched away while `hlt`ing inside `wait`.
`popad; add esp,8; iret` is exactly `irq0_stub`'s tail, so "borrow the next thread's stack to return"
is legal. Precondition: **`wait` must sleep with `sti; hlt`**, not busy-wait — while busy-waiting, `TCB_ESP` is
`api_wait`'s call stack, the wrong shape. `wait` uses `pushfd; sti; hlt; popfd`, compatible with this tail.

#### 4.7.3 Parent waits

```text
api_wait(ebx=pid):
.rescan:
  for tid = 0 .. SCHED_MAX-1:
      if STATE==ST_ZOMBIE and TCB_PARENT==mytid and (pid==-1 or tid==pid):
          status = TCB_EXITCODE
          pmem_free_pages(TCB_STACK, 2)
          clear the TCB slot; --sched_live
          eax = status; ret
  if there is no child with "PARENT==mytid and ALIVE":
      eax = -1; ret
  if [space_cur+TCB_SP_KILLREQ] != 0:      ; killed while sleeping here
      mov eax, 1
      jmp child_exit                       ; doesn't return
  pushfd; sti; hlt; popfd
  jmp .rescan
```

- `pid==-1` waits for any one; `pid>0` waits for the specified one. No children, or the specified tid isn't its child,
  return -1 (no blocking).
- The child's kernel stack (2 pages) is returned at reap time, not at `exit` — the parent may still want to read `TCB_EXITCODE`.
- `wait` is inside `int 0x30`'s IF=0, so the loop must do its own `sti; hlt`, otherwise it never wakes up.
- The two shell threads never call `wait`; their "children" are programs started by `cmd_run`, and program exit
  goes through `run_resume_kernel` → `after_prog`, no wait needed.

#### 4.7.4 Orphans and reaping

| Scenario | Handling |
|---|---|
| parent exits with ALIVE children | change their `TCB_PARENT` to `0` (thread 0's shell) |
| parent exits with ZOMBIE children | reap them on the spot (return stack, clear slot, `--sched_live`), otherwise nobody will ever wait |
| thread 0 idle | call `reap_children(0)` before `shell_wait_key`'s `hlt`, to collect zombies with `PARENT==0` |
| program exits but leaves zombie children | in `after_prog` call `reap_children(current tid)`, to collect zombies with `PARENT==me` |
| program exits but still has ALIVE children | in `after_prog` change their `TCB_PARENT` to `0`, and thread 0 reaps them when idle |
| `cmd_kill` kills a forked child | goes through `child_exit(1)`, doesn't touch `run_resume_kernel` (see §4.7.5) |

`reap_children(tid)` is the "scan + return stack + clear slot" from `wait`, factored out for three call sites;
`sched_orphan_children(tid)` wraps "reparent the ALIVE ones, reap the ZOMBIE ones" for `child_exit`
and `after_prog`.
Does it have to be called with `IF=1`? Not necessarily: scanning the table + `pmem_free_pages` don't sleep,
so `IF=0` works too; just don't call it while holding `fs_lock`.

#### 4.7.5 Killed / crashed forked children

`pit.asm`'s KILLREQ branch currently jumps unconditionally to `run_resume_kernel`, which is wrong for forked children
(same reason as §4.7.1). **`prog_kill_from_fault` (#14 page fault / other exceptions) is the same**: it currently
prints and then does `esp=[run_esp]` and jumps to `run_resume_kernel`, but a forked child's stack has no `cmd_run`
pushad frame. Both places must check `TCB_FLAGS bit0` first:

```asm
; after prog_kill_from_fault finishes printing the crash:
    mov edx, [space_cur]
    test byte [edx+TCB_FLAGS], 1
    jnz .forked_crash
    ; original path: esp=[run_esp]; jmp run_resume_kernel
.forked_crash:
    mov eax, 1
    call child_exit
```

`pit.asm`'s KILLREQ:

```asm
    test byte [edx+TCB_FLAGS], 1
    jnz .kill_forked          ; must be tested before mov esp,[SP_RUNESP]
    ; original logic: esp=[SP_RUNESP]; jmp run_resume_kernel
.kill_forked:
    mov eax, 1                  ; exit code when killed
    call child_exit
```

`cmd_kill` rejects `tid == 4` first (the cons thread); 0–3 are shell threads, for which it only pokes `KILLREQ` at the program they're running;
for **forked children** (5 and up) it should also not go through `sched_kill`: set `SP_KILLREQ=1` and let it go through
`child_exit(1)` to become a zombie (only then does the parent's `wait` get status 1). `sched_kill` is only for
kernel threads that "aren't running a ring 3 program"/as an exception fallback; otherwise the parent's `wait` would see "no such
child" and return -1. The `SP_KILLREQ` path only raises the flag; the actual teardown happens at the interrupt return point.

Known gap: `SP_KILLREQ` is only claimed by `irq0_stub` when **CS's CPL=3**. A forked child
blocked in kernel mode inside `wait`/`kbd_getchar` only sees it after it returns to ring 3; `wait`'s loop
already checks KILLREQ (see §4.7.3), `kbd_getchar` doesn't — it waits until the next key press returns the
system call. Write this into known-issues, don't kill a sleeping key-reading program in a demo.

#### 4.7.6 Limits

| Limit | Value | Notes |
|---|---:|---|
| total slots | 12 | 4 shells + cons + 6 fork margin |
| physical pages per fork | 4 | PD/PT/2 stack pages, 0 user pages copied |
| per-page ref cap | 15 | 4 bits; at most 15 address spaces share one page |
| fork depth | ≤14 | each level adds +1 ref to shared pages, 4-bit cap 15; in practice also limited by "width × depth" |
| zombie slots | 6 | a child that exits without being waited for occupies a slot; `after_prog`/thread 0 reaps as a fallback |
| not done | `fork+exec`, signals, process groups, SMP, FPU context switching | write into known-issues |

> **FPU/SSE is a known gap**: the TCB doesn't save `ST0–ST7`/`XMM`. Once Phase 2 allows several programs to run in parallel,
> two threads using floating point at the same time step on each other. Currently `FPU.BIN`/`FCALC.BIN` are single-program tests and won't collide;
> for real multi-process floating point, `sched_pick` would need `fnsave/frstor` (108 bytes per TCB + 512 bytes of XMM,
> and the TCB would have to grow again). Phase 3 explicitly doesn't do it; list it in known-issues.

### 4.8 Test plan (Phase 3)

Add two C programs under `progs/` (to the `C_PROGS` list; after `make`, `mkfat.py` installs them into `/BIN`).

First add `static inline` wrappers in `include/kkernel.h` (following the `j_getchar` pattern):
`j_fork()` (function 18), `j_wait(pid)` (19, `ebx=pid`), `j_gettid()` (20),
`j_exit_code(code)` (15, `ebx=code`).

> Note that `include/kkernel.h` currently has a `j_exit(const char *msg)` that **no program uses**
> (clears the screen + prints one line, doesn't call API 15). Don't change its signature directly: rename it `j_exit_msg` and add
> `j_exit_code(int code)` separately, with zero changes to existing code.

**`progs/FORK.C`**:

```c
volatile int shared[4] = {1, 2, 3, 4};
j_print("FORK: start\n");
int pid = j_fork();
if (pid == 0) {
    shared[0] = 99;
    printf("child sees %d\n", shared[0]);    /* 99 */
    j_exit_code(7);
}
printf("parent sees %d\n", shared[0]);       /* 1, COW in effect */
int st = j_wait(pid);
printf("child %d exited %d\n", pid, st);     /* 7 */
printf("parent still sees %d\n", shared[0]); /* 1 */
j_print("FORK: done\n");
```

**`progs/FORK2.C`**: `for (i=0;i<3;i++){ if(j_fork()==0) j_exit_code(i); j_wait(-1); }`
then print `FORK2: 3 forks done`; used to check "repeated fork/exit doesn't leak".

**`progs/FORK3.C`** (optional): after the child exits, the parent `sleep`s a while, then `ps` to see the zombie,
then `wait`. Timing assertions are easy to make flaky, so keep it in the manual demo, not the automated tests.

Add a group to the `--shell` suite in `tests/qemu_test.py` (or open a new `--fork` mode, add a switch in `main()`,
and add a line to the `Makefile`'s `test` target):

| # | Action | Assertion |
|---:|---|---|
| 1 | `run FORK.BIN` | `parent sees 1`; `child sees 99`; `child <tid> exited 7`; `parent still sees 1`; `FORK: done` |
| 2 | `run FORK.BIN` again | the same five lines; no `out of memory`/`cow:` |
| 3 | `debug pmem` before; `debug pmem` after | the two `free:` values are the same (PD/PT/stack/COW pages all reclaimed) |
| 4 | `run FORK2.BIN` | `FORK2: 3 forks done`; `debug pmem` still the same |
| 5 | run FORK2 three times in a row | free page count doesn't monotonically decrease (wobble of ±0 allowed) |
| 6 | `ps` | `5 alive / 12 slots` (when there are no zombies) |
| 7 | `kill` a forked child (manual demo) | the child disappears, the parent's `wait` returns 1, `debug pmem` doesn't lose pages |

Phase 3 grows `SCHED_MAX` from 8 to 12, so the `5 alive / 8 slots` assertion in §3.8 must become
`5 alive / 12 slots`.

Page-count assertions use `debug pmem`'s `free:` line, parsed the same way as the existing `expected_free_pages()`;
the refcount table is at 0x3D2000 (a reserved area) and **doesn't enter the page pool**, so `expected_free_pages()` doesn't need changing
(Phase 2's 63 stays). But `ps`'s slot count goes from 8 to 12, so the Phase 2 assertion must change too.

**Manual demo**:

```text
shell 1: run FORK.BIN        # parent and child each print their own; parent sees 1, child sees 99
shell 1: debug pmem          # free is the same before and after
shell 2: run FORK2.BIN       # run at the same time, no interference
shell 1: ps                  # 12 slots, FORK's children appear briefly
```

### 4.9 Code size, risks, checklist

| File | Change | Estimated lines |
|---|---|---:|
| kernel/sched.asm | `sched_fork`, `child_exit`, `reap_children`, TCB field expansion | ~220 |
| kernel/paging.asm | `space_clone`, COW fault branch, `space_destroy` rework | ~170 |
| kernel/pmem.asm | refcount table + 3 primitives + alloc/free wiring | ~130 |
| kernel/api.asm | 18/19/20, case 15 stores the exit code, `api_usage` | ~70 |
| kernel/pit.asm | KILLREQ branch checks for forked | ~10 |
| kernel/shell.asm | `ps` display, `after_prog` reaping, `cmd_kill` | ~40 |
| progs/ | FORK.C, FORK2.C | ~80 |
| tests/qemu_test.py | 7 assertions + `--fork` | ~120 |
| **Total** | | **~840 lines, ~5 KiB** |

The kernel grows from ~85 KiB to ~95 KiB, still < 128 KiB; 0x3D2000 reserves 32 KiB more of static table
(only 15,104 B used by default, not counted in the page pool).

Main risks:

| Risk | Consequence | Mitigation |
|---|---|---|
| forgetting `CR0.WP` | COW never triggers; parent and child share the same page and both think they own it | `or eax,0x00010001` in `paging_init`; the "parent sees 1" test will definitely fail |
| wrong fork iret frame offsets | the child triple-faults / runs off the rails the first time it's scheduled | build the 60 bytes exactly as in §4.3.2; inspect once with QEMU `-d int` |
| `TSS.esp0` points at the parent's stack | the child's first interrupt crushes the parent's stack | `sched_pick` uses `TCB_SP_RUNESP`; fork sets the child stack top |
| marking COW without flushing the TLB | the parent's writes don't fault, COW leaks | reload `mov cr3`; do it before fork returns |
| refcount leaks | the pool slowly shrinks, eventually OOM | assert before/after with `debug pmem`; `space_destroy` decs on every path |
| zombies never reaped | slots exhausted, fork returns -1 | `after_prog`/thread 0 as a fallback; `ps` shows zombies |
| `pmem_free` semantics widened | old call sites assume "must return a page" | grep the repo for `pmem_free`; `space_destroy` counts with the return value |
| 15-ref cap | wide fork trees fail | pre-check; return -1 without crashing; document it |
| FPU state not saved | parallel floating-point programs step on each other | known-issues; not done in Phase 3 |
| `SCHED_MAX` 8→12 missed somewhere | TCB out of bounds / missing ps entries | use the `SCHED_MAX` macro; grep for hardcoded 6/8 |

Phase 3 checklist:

- [ ] P0 wrap-up (§2)
- [ ] `TCB_PARENT/EXITCODE/PFCOW/FLAGS`, `TCB_SIZE=144`, `SCHED_MAX=12`, `ST_ZOMBIE`
- [ ] refcount table at 0x3D2000, `pmem_ref_*`, alloc/free wiring
- [ ] `space_clone`: PD/PT copy + mark COW + flush TLB
- [ ] `sched_fork`: 4-page pre-allocation, 60-byte frame, TCB fields
- [ ] COW fault branch + `CR0.WP`
- [ ] `space_destroy` switched to dec-ref
- [ ] `api 18/19/20`, case 15 exit code, `api_usage`
- [ ] `child_exit` + `wait` + `reap_children` + orphans
- [ ] `pit.asm` KILLREQ checks forked
- [ ] `ps` shows parent/zombie
- [ ] FORK/FORK2 programs + 7 tests
- [ ] known-issues: FPU, fork+exec, SMP

---

## 5. Appendix

### 5.1 Memory map (after Phase 2 + Phase 3)

| Address | Purpose | Change |
|---|---|---|
| 0x1000 | page directory `PD_ADDR` | |
| 0x2000 | `PT_LOW` (0–4 MiB, no USER) | |
| 0x4000 | `PT_LFB` | |
| 0x10000–0x2FFFF | kernel (≤128 KiB) | grows to ~95 KiB |
| 0x90000 | boot stack | |
| 0x100000 | `FAT_BUF` | |
| 0x110000 | `FILE_BUF` | |
| 0x120000–0x17FFFF | program image window (96 pages) | |
| 0x180000–0x3AFFFF | heap window (`SP_HEAPPAGES` pages) | |
| 0x3B0000–0x3BFFFF | PINYIN (IME) | |
| 0x3C0000–0x3C2FFF | USB frame list/QH/TD/BOT | |
| 0x3D0000–0x3D1FFF | page pool bitmap (8 KiB) | |
| **0x3D2000–0x3D9FFF** | **refcount table (32 KiB reserved, 15 104 B used by default; new in Phase 3)** | new |
| 0x3DA000–0x3FFFFF | free | |
| 0x400000–0x079FF000 | page pool (30 207 pages by default) | 18 pages fewer (consoles) |
| 0xFD000000 | VBE LFB | |

### 5.2 Final TCB layout (144 B)

| Offset | Field | Offset | Field |
|---:|---|---:|---|
| 0 | `TCB_ESP` | 76 | `SP_FREED` |
| 4 | `TCB_CR3` | 80 | `SP_HEAPPAGES` |
| 8 | `TCB_STATE` | 84 | `SP_ARGSVA` |
| 12 | `TCB_TICKS` | 88 | `SP_STACKVA` |
| 16 | `TCB_STACK` | 92 | `SP_STACKTOP` |
| 20 | `TCB_NAME` | 96 | `SP_RUNNING` |
| 24 | `TCB_RUNS` | 100 | `SP_STAGE_PA` |
| 28 | `TCB_OWNER` | 104 | `SP_STAGE_PAGES` |
| 32 | `SP_PD` | 108 | `SP_KILLREQ` |
| 36 | `SP_PT` | **112** | **`TCB_CONS`(Phase 2)** |
| 40 | `SP_LIVE` | **116** | **`TCB_CWD`(Phase 2)** |
| 44 | `SP_PAGES` | **120** | **`TCB_PARENT`(Phase 3)** |
| 48 | `SP_IMGBYTES` | **124** | **`TCB_EXITCODE`(Phase 3)** |
| 52 | `SP_PFRUN` | **128** | **`TCB_PFCOW`(Phase 3)** |
| 56 | `SP_PFIMG` | **132** | **`TCB_FLAGS`(Phase 3)** |
| 60 | `SP_PFHEAP` | 136 | reserved |
| 64 | `SP_FIRSTPA` | 140 | reserved |
| 68 | `SP_RUNESP` | | |
| 72 | `SP_RUNSTAT` | | |

### 5.3 New/changed functions at a glance

| File | Function | Phase |
|---|---|---|
| kernel/cons.asm (new) | `cons_init`, `cons_putcp`, `cons_putc_byte`, `cons_newline`, `cons_clear`, `cons_erase_input`, `cons_service`, `cons_repaint`, `kthread_cons` | 2 |
| kernel/vgafont.asm | `term_print_cp` (change one jump) | 2 |
| kernel/kmain.asm | `cons_init` call, `term_*` hooks, `layout`, `sched_spawn(kthread_cons)` | 2 |
| kernel/keyboard.asm | `kbd_push/avail/consume/seq_len/getkey/getchar` (per console), `sti/hlt` waiting | 2 |
| kernel/sched.asm | `sched_noswitch`, `fs_lock/fs_unlock`, `TCB_CONS/CWD`, CWD sync; `sched_fork`, `child_exit`, `reap_children`, `sched_orphan_children`, TCB field expansion | 2/3 |
| kernel/shell.asm | `shell_switch_to` flag, `cons_service`, `shell_pipe_execute` locking, `ps` display, `after_prog` reaping | 2/3 |
| kernel/fat.asm | `fs_lock/unlock` in 14 entries | 2 |
| kernel/ata.asm | `fs_lock/unlock` for read/write sectors | 2 |
| kernel/pipe.asm | `pipe_owner`, `pipe_busy` | 2 |
| kernel/ime.asm | active-console checks, `ime_switch` | 2 |
| kernel/paging.asm | `space_clone`, COW branch (`pf_err`), `space_destroy` dec-ref, `CR0.WP` | 3 |
| kernel/pmem.asm | `pmem_ref_get/inc/dec`, alloc/free wiring, `pmem_init` clears the table | 3 |
| kernel/api.asm | 18/19/20, case 15, `api_usage` | 3 |
| kernel/pit.asm | KILLREQ checks forked | 3 |
| kernel/idt.asm | #14 branch does `mov ecx,[ebp+36]` then calls `page_fault_try_handle` | 3 |
| progs/ | `FORK.C`, `FORK2.C` | 3 |
| tests/qemu_test.py | 12 + 7 assertions, `--fork`, page-count formula | 2/3 |

### 5.4 Acceptance (everything must pass)

- [ ] `make` compiles cleanly, kernel < 128 KiB, boot `layout` line contains `cons=16`
- [ ] 4 shells each `echo` different content, Ctrl+←/→ back and forth, screens don't contaminate each other
- [ ] a half-typed line survives switching away and back, Enter executes it
- [ ] shell 1 `run HANG`, shell 2 `run ECHO` run at the same time; keys on either side don't cross
- [ ] `kill` shell 1's program from shell 2, shell 1 returns to the prompt
- [ ] `ps` = 5 alive / 12 slots; `debug pmem` == `expected_free_pages()`
- [ ] switching shells mid-IME doesn't corrupt the screen or leave the bar
- [ ] `run FORK.BIN`: parent sees 1, child sees 99, `wait` returns 7
- [ ] run `FORK2.BIN` 3 times in a row, the pool's free page count doesn't drop
- [ ] `ps` can show `zombie` (manual demo); it disappears after `wait`
- [ ] with `qemu -m 8` and no page pool, `cons: disabled`, Ctrl+←/→ still switch the keyboard, no crash
- [ ] `make test` all green (fda/hda/div/pgfault/kbd/shell/font/fat32/usb/fork)

### 5.5 What we're not doing

| Not doing | Why |
|---|---|
| `fork+exec` | exec needs a new image and a reset entry, which conflicts with the current "image window + staging area" model; let fork settle first |
| page-table-level copy-on-write (PT sharing) | PD/PT are only 2 pages, so fork copying them directly is simpler and saves a layer of refs |
| signals / process groups / sessions | no demand; `kill` is already "kill by tid" |
| SMP | single CPU; `cli`/`invlpg` are enough, no TLB shootdown |
| FPU/SSE context switching | would need to grow the TCB and add `fnsave/frstor`; explicitly not done in Phase 3, recorded in known-issues |
| kernel thread fork | the API only enters from ring 3; shell/cons threads don't fork |
| console scrollback | the buffer holds only one screen; once it scrolls out it's gone; scrollback would need ring history and double the memory |

---

*Document based on the 2026-11 working tree (the state before Phase 1 was committed). Line numbers drift, function names don't;
when they don't line up, anchor on the function name and find the change with `git log -S`.*
