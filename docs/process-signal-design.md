[简体中文](zh-CN/process-signal-design.md)

# Process and signals (process / fork / exec / signal) design draft

> Status: design draft. The **goal** of this stage (first cut) is narrow: be able to fork a child,
> exec a new image, wait to reap it, see it in `ps`, kill it, and parse signals into a bitmap.
> It is not a complete POSIX process model.
>
> Reference: `docs/design-multishell-cow.md` (the "reference draft"). Terminology, phase breakdown,
> and the TCB frame format all follow it; this draft only adds the process table / PCB fields /
> exec / wait / signals that it did not cover, and turns its planned-but-never-landed Phase 3
> into concrete, executable steps.
>
> Files involved (at implementation time): new `kernel/process.asm`; changes to `kernel/sched.asm`,
> `kernel/paging.asm`, `kernel/pmem.asm` (mostly done), `kernel/shell.asm`, `kernel/api.asm`,
> `kernel/pit.asm`, `include/kkernel.h`, `Makefile`, `tests/qemu_test.py`.

---

## 0. Scope and terminology

### 0.1 Division of labor across the three phases

| Phase | Topic | Status | Relation to this draft |
| --- | --- | --- | --- |
| Phase 1 | Per-thread address space (`space_create/activate/destroy`, demand paging, trampoline page) | Done | Reused as-is |
| Phase 2 | Multi-shell virtual consoles (`cons.asm`, `SH_MAX=4`, Ctrl+Left/Right, per-shell line-edit buffer) | Done | **Left untouched** in this stage (see §3) |
| Phase 3 | fork + copy-on-write | Reference draft only designed it; this draft turns it into steps | Main body of this draft (§1.4–§1.5) |
| New here | Process table / PCB fields, exec, wait/exit, kill, signal triple skeleton | To implement | §1, §2, §5 |

### 0.2 Terminology (aligned with the reference draft)

| Term | Meaning | Code symbol |
| --- | --- | --- |
| slot | The i-th entry of the scheduling table, `i ∈ [0, SCHED_MAX)` | `TCB_OFF(id)` |
| process / thread | One-to-one in this stage: one TCB slot is one process; the shell itself is a process too | `sched_cur` |
| PCB | Process control block. **This stage does not create a separate struct; it is embedded directly in the TCB** | see §1.2 |
| PID | Externally visible process number, `pid = slot + 1` (derived, occupies no field) | — |
| address space | PD + low-end PT + some user pages + image staging page(s) | `space_*` |
| image staging page | The physical page pointed to by `TCB_SP_STAGE_PA`; not in the address space, demand paging copies from it | `STAGE_PA/STAGE_PAGES` |
| trampoline page | 0x17F000, holds `int 0x30` + the exit path; a program `ret`s back into the kernel | `tramp_code` |
| argument page / user stack page | The last two pages of the heap window, `ARGSVA` / `STACKVA` | `space_user_page` |
| zombie | A process that has exited but still owns its slot, waiting for the parent to wait | `ST_ZOMBIE` |
| reap | wait takes the exit code, returns the kernel stack, clears the slot | `process_wait` |
| frame | The `[pushad 32][vector/error code 8][EIP][CS][EFLAGS][ESP3][SS3]` block on the stack when switched out | `TCB_ESP` |

### 0.3 Differences from the reference draft (this draft wins)

| Item | Reference draft | This draft | Reason |
| --- | --- | --- | --- |
| Process count | `SCHED_MAX=6` | **16** | Need room for 4 shells plus a few children at once |
| TCB size | 112, planned end state 144 | **132** (landed) | Offsets finalized by the user; the five new fields PARENT/EXITCODE/PENDING/BLOCKED/PFCOW total 20 bytes |
| PID source | slot number (from 0) | **slot + 1** (1..16) | 0 is reserved for "no parent"; also distinguishes it from the numbering in the shell prompt |
| API 19 | gettid | **wait** | No threads in this stage, so gettid is useless |
| exec | Listed under "won't do" | Do it (no argv) | Needed to make fork+exec work |
| Kernel-thread fork | Won't do | Still won't do; the shell's `fork` takes two special-case paths (§1.4.4) | Copying a kernel stack context is unreliable |

---

## 1. Process model

### 1.1 Process table: 16 slots, PID = slot + 1

- The table is just the TCB array in `sched.asm`: `SCHED_MAX = 16`, `TCB_SIZE = 132`, `TCB_OFF(id) = id * 132`.
- The whole table statically occupies **16 × 132 = 2112 bytes (0x840)**; `sched_init` zeroes it once.
- **PIDs 1..16 are exactly slots 0..15**, `pid = slot + 1`. PID 1 (slot 0) is shell 0; slots 0..3 are
  the four shell kernel threads (PIDs 1..4); user programs and fork children start at slot 4.
- **Implementation choice: the PCB is embedded directly in the TCB**, no parallel table. Reasons:
  1. One less table and one less "table entry ↔ TCB" synchronization point, one less source of inconsistency;
  2. fork only needs an empty slot, and the PCB fields naturally travel with the TCB (register frame,
     address space, signal bitmap all live in the same block);
  3. `sched_pick`/`sched_kill`/`sched_abandon_current` keep working without a single change;
  4. Design-wise it is still **treated as a 16-entry process table** — `ps` walks slots and derives
     PID from the slot number, so behavior is equivalent to a "separate PCB table".
- PID allocation: `process_alloc_slot` scans linearly from `SH_MAX` for the first `ST_EMPTY`
  (shell slots never participate in fork allocation); returns -1 if none
  (checked up front via `sched_live >= SCHED_MAX`, saving one scan).
- **PIDs are reused**: once a slot is reaped by wait, the next fork can grab it, and the old pid now
  points at a new process. This stage accepts that, and covers it with two rules of discipline:
  (a) `kill`/`signal_send` first verify the target's `STATE != ST_EMPTY`; (b) `wait` only matches
  `TCB_PARENT == me && ST_ZOMBIE`, never the pid itself.

### 1.2 PCB / TCB fields

Offsets are byte offsets; every field is 4 bytes wide (`dd`). `pid` is derived and **occupies no field**.

| Offset | Symbol | Meaning | Notes |
| --- | --- | --- | --- |
| 0 | `TCB_ESP` | esp saved when switched out, pointing at its frame | stack switching relies on it |
| 4 | `TCB_CR3` | physical address of its page directory | while the program runs it is the program's own |
| 8 | `TCB_STATE` | state, see §1.3 | the only thing the scheduler looks at |
| 12 | `TCB_TICKS` | total ticks accumulated | shown by `ps` |
| 16 | `TCB_STACK` | physical base of the kernel stack (2 pages, 8 KiB) | must go back to the page pool when dead |
| 20 | `TCB_NAME` | name pointer | shown by `ps` |
| 24 | `TCB_RUNS` | how many times it has been scheduled in | shown by `ps` |
| 28 | `TCB_OWNER` | which shell it was born on (0..3) | keyboard/mouse ownership; **reserved attachment point for uid** |
| 32 | `TCB_SP_PD` | physical address of the program page directory (0 = no program running) | |
| 36 | `TCB_SP_PT` | physical address of the private low-end page table | |
| 40 | `TCB_SP_LIVE` | 1 = this address space is in use | demand-fault fill checks it |
| 44 | `TCB_SP_PAGES` | fixed pages the space occupies (PD+PT=2) | |
| 48 | `TCB_SP_IMGBYTES` | image size in bytes for this run (determines .bss start) | |
| 52 | `TCB_SP_PFRUN` | pages faulted in during this run | diagnostic accounting |
| 56 | `TCB_SP_PFIMG` | of which image-window pages | diagnostic accounting |
| 60 | `TCB_SP_PFHEAP` | of which heap-window pages | diagnostic accounting |
| 64 | `TCB_SP_FIRSTPA` | first physical page faulted in | for display |
| 68 | `TCB_SP_RUNESP` | kernel stack top before entering ring3 (= `TSS.esp0`) | landing spot on exit/kill |
| 72 | `TCB_SP_RUNSTAT` | 0 = normal exit, 1 = killed by kernel | |
| 76 | `TCB_SP_FREED` | pages returned at teardown | diagnostic accounting |
| 80 | `TCB_SP_HEAPPAGES` | heap window page count (computed at boot, copied at spawn) | |
| 84 | `TCB_SP_ARGSVA` | argument page virtual address (second-to-last heap window page) | |
| 88 | `TCB_SP_STACKVA` | user stack page virtual address (last heap window page) | |
| 92 | `TCB_SP_STACKTOP` | user stack top | |
| 96 | `TCB_SP_RUNNING` | 1 = currently running a ring3 program | `ps` marker |
| 100 | `TCB_SP_STAGE_PA` | physical address of the image staging area | source for demand paging |
| 104 | `TCB_SP_STAGE_PAGES` | pages occupied by the staging area | |
| 108 | `TCB_SP_KILLREQ` | 1 = another shell asked to kill the program on this thread | keeps original semantics |
| **112** | `TCB_PARENT` | parent pid (0 = shell/orphan) | **new** |
| **116** | `TCB_EXITCODE` | exit code (validity determined by whether STATE is ZOMBIE) | **new** |
| **120** | `TCB_PENDING` | pending-delivery signal bitmap, bit = action number (§2.5) | **new** |
| **124** | `TCB_BLOCKED` | blocked-signal bitmap, bit = action number | **new** |
| **128** | `TCB_PFCOW` | COW pages copied during this run | **new** |

- 132 is a multiple of 4, so `imul` offset computation needs no remainder handling; `sizeof(TCB)` and
  `TCB_SIZE` must be changed together.
- **Where uid would go**: 132 is already full, no holes. The reserved plan is in §4.2 (grow to 140 next
  stage, `TCB_UID=132`/`TCB_GID=136`). This stage **adds no field**; `TCB_OWNER` keeps the
  "birth shell" semantics.

### 1.3 State machine

| State | Value | Who sets it | `sched_pick` | Notes |
| --- | --- | --- | --- | --- |
| `ST_EMPTY` | 0 | boot / after reap / after kill | skipped | available to fork |
| `ST_ALIVE` | 1 | `sched_spawn`, fork, `cont` | **schedulable** | the only state that can be picked |
| `ST_DEAD` | 2 | (reserved) | skipped | legacy from old code, unused this stage |
| `ST_ZOMBIE` | 3 | `process_exit` | skipped | waits for parent to reap; slot + kernel stack still held |
| `ST_STOPPED` | 4 | `stop` signal | skipped | `cont` returns it to ALIVE |

```
EMPTY ──spawn/fork──▶ ALIVE ──stop──▶ STOPPED
                        │               │
                        │               └──cont──▶ ALIVE
                        ├──exit──▶ ZOMBIE ──wait──▶ EMPTY
                        └──kill──▶ EMPTY (reclaimed immediately)
```

- `sched_pick` already picks only `ST_ALIVE`, so STOPPED is skipped automatically **without touching
  the scheduler** (zero cost).
- A ZOMBIE's register frame is dead, but its two `TCB_STACK` pages **must be kept** — they are only
  returned after wait; and (important) `process_exit` must not return the two pages under its own feet
  during teardown; only wait may.

### 1.4 fork: copy-on-write

#### 1.4.1 Page refcount table (4 bits/page)

Already implemented on the pmem side; this section just nails down the contract, since fork depends on it.

| Item | Value |
| --- | --- |
| bitmap base | `PMEM_BITMAP = 0x3D0000`, 8192 bytes (65536 bits, bit = page number) |
| refcount base | `REFCOUNT_BASE = 0x3D2000`, **8 KiB**, `REFCOUNT_DWORDS = 2048` dwords |
| granularity | **4 bits / page**; byte address = `REFCOUNT_BASE + (page >> 1)`, even pages use the **low** 4 bits, odd pages the **high** 4 bits |
| value | 0 = unallocated; 1..15 = referenced by that many address spaces; **15 is a hard limit** |
| coverage | 2048 dwords × 8 nibbles = 16384 pages; this machine has only 1024 pages in 4 MiB, plenty of headroom |
| overflow | `pmem_ref_inc` returns **CF=1** at 15, caller treats it as ENOMEM |

| Primitive | In | Out | Semantics |
| --- | --- | --- | --- |
| `pmem_alloc` / `pmem_alloc_pages` | page count | eax=physical page / CF | sets count to **1** after allocation (existing) |
| `pmem_ref_set1` | eax=physical page | — | zero then set to 1 (used when fork reclaims) |
| `pmem_ref_inc` | eax=physical page | CF=1 means 15 reached | add one reference |
| `pmem_free` / `pmem_free_pages` | eax=physical page | CF / eax=pages actually returned | **semantics change: decrement the refcount, clear the bitmap + adjust `free_count`/`alloced` only at zero** |

- Blast radius of the semantic change: once `pmem_free` degrades to "decrement refcount", **there is no
  longer an entry point for "unconditionally return a page"**. Everywhere that "knows it is the only
  reference left" (boot reserved area, temp pages from a failed load) can still call it, because the
  count is 1 there → behavior unchanged.
- This stage does not add a separate "how many references are left" query: `pmem_free` already fetches
  the nibble, so return it when needed; don't add a `pmem_ref_get` that walks the same bit math a second
  time (the reference draft listed get/inc/dec, but only `set1`/`inc`/`free` actually landed).

#### 1.4.2 fork execution order

Entry: `process_fork` (called by `int 0x30` function 18, `ebx` = `api_stub`'s stack frame base; `eax`
returns child pid / -1).
**The order is deliberate: do everything that can fail first, only then touch the parent's PTEs**, so
any failure can roll back cleanly.

1. **Capacity check**: `sched_live >= SCHED_MAX` → return -1 (ENOMEM/process table full).
2. **Find a slot**: scan from `SH_MAX` for the first `ST_EMPTY`, yielding `child_id`;
   `child_pid = child_id + 1`. None → -1.
3. **Preallocate 4 pages**: child PD, child low-end PT, child kernel stack (2 pages)
   (`pmem_alloc_pages`). If any fails → `pmem_free` everything already allocated and return -1.
4. **Precheck**: walk every present user page in the parent PT; if any nibble is 15 → free the 4 pages
   just allocated and return -1 (`cow: too many shared pages`). Done here so that step 6's
   `pmem_ref_inc` cannot fail midway with CF=1.
5. **Prep before flushing the TLB**: record the parent's `frame` (`[frame+16..47]` is pushad, `+48` EIP,
   `+52` CS, `+56` EFLAGS, `+60` ESP3, `+64` SS3 — reference draft §4.3.2).
6. **Turn parent pages into COW** (walk all 1024 entries of the PT pointed to by parent PD[0], skipping
   kernel pages with `present=0` or `PAGE_USER=0`):
   - `PTE &= ~PAGE_RW`;
   - `PTE |= PAGE_COW` (`PAGE_COW = 0x200`, PTE bit9; bit9 is available to hardware, so it doesn't
     affect paging);
   - `pmem_ref_inc(page physical address)`.
   The argument page and user stack page are also in the heap window and **get covered by this same
   pass**; no special case needed.
7. **Staging pages get +1 separately**: `STAGE_PAGES` pages starting at `TCB_SP_STAGE_PA` are
   **not in the address space** (step 6's walk won't see them) and must be explicitly `pmem_ref_inc`ed.
   If you miss this: when the parent exits, `space_destroy` returns the staging pages to the page pool,
   and the child's demand paging reads physical pages now owned by someone else — it **silently reads
   garbage**, the nastiest kind of bug.
8. **Copy the page tables**: `rep movsd` 1024 dwords, parent PD → child PD, parent PT → child PT (whole
   page each); then `childPD[0] = childPT | PAGE_P | PAGE_RW | PAGE_USER` (the child's page-directory
   entry must be writable and user-accessible).
9. **Build the child's iret frame** (on the child kernel stack, at `TCB_STACK + 8192` minus 60 bytes):
   child `TCB_ESP = stack top - 60`. Contents from low to high:

   | Frame offset | Content | Source |
   | --- | --- | --- |
   | +0 .. +27 | the 7 pushad registers other than eax | copy 28 bytes from parent `frame+16` |
   | +28 | **EAX = 0** | the child's `fork()` return value |
   | +32 | vector/error-code placeholder, 2 dwords (8 bytes) | 0 (same layout as the switch frame; `popad; add esp,8` skips it exactly) |
   | +40 | EIP | = parent `[frame+48]`, the instruction after `int 0x30` |
   | +44 | CS | = parent `[frame+52]` (`USER_CS_SEG`) |
   | +48 | EFLAGS | = parent `[frame+56]` |
   | +52 | ESP3 | = parent `[frame+60]` (same user stack virtual address, shared page, COW on first write) |
   | +56 | SS3 | = parent `[frame+64]` (`USER_DATA_SEG`) |

   That's 60 bytes. The pushad store order puts eax at `+28` (consistent with `api_stub`'s `[esp+28]`
   write-back).
10. **Fill the child TCB**: `STATE=ST_ALIVE`, `CR3=childPD`, `STACK=child stack pa`, `RUNS=0`,
    `OWNER=parent OWNER`, `PARENT=parent pid`, `EXITCODE=0`, `PENDING/BLOCKED/PFCOW=0`,
    `SP_PD=childPD`, `SP_PT=childPT`, `SP_LIVE=0`, copy `SP_PAGES`/`IMGBYTES`/`HEAPPAGES`/`ARGSVA`/
    `STACKVA`/`STACKTOP` from the parent, `SP_STAGE_PA/STAGE_PAGES` same as parent (step 7 already +1'd),
    `SP_RUNESP = child stack top` (mandatory: `TSS.esp0` must point there, otherwise ring3 interrupts
    would write to address 0), `SP_RUNSTAT=0`, `SP_RUNNING=0`, `SP_KILLREQ=0`, `NAME` points at `"child"`.
11. **Flush the TLB (mandatory)**: `mov eax, cr3; mov cr3, eax`. The parent's TLB still holds old
    entries for those pages as "writable, not COW"; without the flush the parent's next write **lands
    directly on the shared page** and COW did nothing.
12. `++sched_live`, return `child_pid`. The parent gets the child pid from API 18; the child, when next
    picked by `sched_pick`, does `popad; add esp,8; iret` back to ring3 with `eax = 0`.

#### 1.4.3 Failures and limits

- Failure points are only steps 1–4 and "no free slot", all before the parent PTEs are touched; rollback
  only needs `pmem_free` of the 4 pages just allocated.
- Refcount limit 15 ⇒ **at most 15 address spaces share a page**, so single-chain fork depth ≤ 14;
  the 15th fork reports ENOMEM. That is a design constraint, not a bug (`fork: too many shared pages`).
- A child killed immediately after creation, or a parent exiting immediately, changes nothing:
  reclaim goes through `space_destroy` (decrement per page) and the counts stay consistent.

#### 1.4.4 The three "fork" entry points

| Entry | Who is running | Which path | Where the child starts |
| --- | --- | --- | --- |
| shell command `fork` | kernel shell thread | `process_spawn_demo`: `sched_spawn` a kernel routine, fill in `PARENT`/`NAME` | the kernel demo routine (prints pid/ppid then `exit(7)`) |
| shell command `fork <prog>` | kernel shell thread | `process_fork_exec`: new slot + new space + load prog + prebuilt iret frame | ring3 `prog_entry` |
| `int 0x30` function 18 | ring3 program | `process_fork` (this doc §1.4.2, the full COW flow) | the parent's next instruction after `int 0x30`, `eax=0` |

- **Kernel threads do not COW-fork**: copying the shell's kernel-stack frame into a child would return
  the child into kernel code that is "halfway through parsing a command", which is useless. So the
  shell's two `fork` commands are special-case paths: one spawns a demo thread, one directly creates a
  "new process with the program already loaded". Real COW only happens when a ring3 program calls
  function 18 itself (that's exactly how FORK.BIN tests it).

### 1.5 COW page-fault handling

On the `idt.asm` side: `isr_common` does `mov ecx, [ebp+36]` before `call page_fault_try_handle`
(the error code; `[ebp+32]` is the vector number), passing the error code as the function argument.

`page_fault_try_handle` (already in `paging.asm`; the contract is finalized here):

1. Only handle it when `err & 3 == 3`: bit0 = present (page is there), bit1 = write (write access).
   Read faults and non-present faults do not enter the COW branch.
2. Fetch the PT entry for the faulting address (`CR2 >> 12` index), require `PAGE_P` and `PAGE_COW`.
3. Allocate a new page (`pmem_alloc_pages(1)`); on failure → print
   `cow: out of memory (page still shared)`, return 0 → upper layer takes the old "program gets torn
   down" path (`prog_kill_from_fault`), **no panic**.
4. `rep movsd` 1024 dwords, full-page copy.
5. PTE = `new pa | PAGE_P | PAGE_RW | PAGE_USER` (clear COW, restore writability).
6. `invlpg` to flush the TLB entry for this page.
7. `pmem_free(old pa)` — under the new semantics this is just **one decrement**; if others still use it,
   only the bitmap count changes.
8. `++[TCB_SP_PFCOW]`, so `ps` can show how many pages were copied during this run.
9. Return **1** → `isr_common` irets back and re-executes the faulting write instruction.

**Mandatory prerequisite: `CR0 |= 0x80010000`** (bit31 PG + **bit16 WP**, write protect).
With `WP=0`, a kernel-mode (CPL0) write to a read-only page **does not fault at all** — any write after
fork that returns to kernel mode silently modifies the shared page. The WP bit is the crux of COW; set
it once in `kmain`/paging init.

### 1.6 exec: swap the image, not the process

Entry `process_exec` (`esi` = filename string, `dl` = whether to run as a fork child, see below).
**It does not create a new process**: PID, slot, and `TCB_PARENT` all stay; what changes is the address
space and "which instruction to start at".

1. Save `[fat_dir]` (current directory) and `loader_lock` (serializes ATA reads, shared with `cmd_run`).
2. Name resolution: append `.BIN`; if `fat_path` fails, retry with a `BIN/` prefix; **reuse the block from
   `cmd_run` and factor it into a common routine `loader_load_image`** (otherwise the two copies will
   drift apart sooner or later).
3. `fat_stat` for the size → `fat_read_file` into `PROG_ADDR = 0x120000`; if it's an ELF, go through
   `elf_load` (yielding `prog_size` / `prog_entry`).
4. Restore cwd, **return the old address space**: if `SP_LIVE`, first `space_deactivate` (switch back to
   the `PD_ADDR` kernel page directory), then `space_destroy_at(old PD)`; old staging pages go through
   `pmem_free_pages` (decrement; others may still share them).
5. Load: allocate new staging pages `pmem_alloc_pages(stage_pages)`, copy from `PROG_ADDR`, write
   `SP_STAGE_PA/STAGE_PAGES`.
6. `space_create` → `space_set_image(prog_size)` → `space_activate` → `space_prepare_user`
   (trampoline page + user stack page, trampoline address on top of the stack).
7. `space_user_page(SP_ARGSVA)`: **write a single 0 byte** at `PROG_ARG_STR` in the argument page
   (empty argv, see §1.6.2).
8. Clear `SP_KILLREQ`, set `SP_RUNSTAT=0`, `SP_RUNNING=1`, `SP_RUNESP = esp`, `TSS.esp0 = esp`.
9. `loader_unlock`; set segment registers to `USER_DATA_SEG`; push 5 dwords (`SS3/ESP3/EFLAGS|IF/CS3/entry`)
   then `iret`.
10. On failure (file missing / bad ELF / not enough pages): `loader_unlock`, restore cwd, **return -1 to
    the caller** — the old address space is already destroyed at this point, so the caller (API 24) must
    `process_exit(-1)` on -1 rather than pretend it can keep running.

#### 1.6.1 fork + exec

- How they combine: the parent `fork()`s and gets a child pid; the child's return value is 0, so the
  child calls `execve` (function 24) in user mode and swaps its image "in place"; the parent `wait()`s
  to reap. That's the standard Unix shape and this design does not change it.
- The shell's `fork <prog>` goes through `process_fork_exec`, a **pre-combined fast path**: it doesn't
  copy the parent space (it would be thrown away anyway), but directly does new slot → new space → load
  → prebuilt iret frame → return pid. Saves one full page copy and one destroy, and avoids the
  "kernel-thread COW fork" trap.

#### 1.6.2 The shape of exec in this stage

- **No argv support**: the argument page's `PROG_ARG_STR` gets a single 0 (`j_arg` reads an empty
  string). argv/envp are the next stage (§6).
- When `process_exec` is called on its own (not via fork) for a program running on a shell slot, it is
  equivalent to `run` — **this stage does not expose exec as API 24 to user mode**, it is only called
  internally from `process_fork_exec`; the API 24 number is reserved now (§5.3).
- exec is optional: without it after `fork`, the child is simply a copy of the parent (COW provides
  isolation).

### 1.7 exit / wait: zombies and reaping

#### 1.7.1 `process_exit(eax = code)` — does not return

1. `edx = TCB_OFF(sched_cur)` (current process).
2. If it has an address space (`SP_LIVE` or `SP_PD != 0`) → `space_deactivate` →
   `space_destroy_at(SP_PD)`, clear `SP_PD/SP_PT/SP_LIVE/STAGE_PA`; staging pages via
   `pmem_free_pages`. **The order must not be reversed**: destroying first would return the page-table
   pages currently in use as garbage.
3. `STATE = ST_ZOMBIE`, `EXITCODE = code`, `SP_RUNNING = 0`.
4. `process_adopt_children(my pid)`: reparent children with `PARENT == me` to `PARENT = 1` (shell 0
   adopts them). Without this those children stay orphans with a dead parent, nobody can ever wait for
   them, and the slots sit there for nothing.
5. `sched_abandon_current`: pick the next `ST_ALIVE` → switch `CR3`, `TSS.esp0 = [other TCB_SP_RUNESP]`
   → `esp = [other TCB_ESP]; popad; add esp,8; iret`.
   **Do not return to the shell**: when a forked child exits it must not go through
   `run_resume_kernel` (that path returns to the shell's `.after_prog`, destroys the wrong space, prints
   the wrong line, and confuses the shell's state machine).
6. If there is no ALIVE process → `sti; hlt` and sleep forever (same as the current behavior of
   `sched_abandon_current`).
- Unified path: `process_exit` also works for kernel threads (the demo child's `exit(7)`); it has no
  address space, so step 2 is skipped; its `TCB_ESP` still points at a valid switch frame, and
  `sched_abandon_current` can switch away just the same.
- API 15 (`api_exit`) vs API 20: 15 is **program return** (the trampoline-page path, not necessarily a
  process exit), 20 is **process exit**. `api_exit` branches on `TCB_PARENT != 0`: has a parent →
  `process_exit`; no parent (a program the shell ran directly) → the old `run_resume_kernel`. Both end
  up tearing down the current space, but the one doing the teardown differs.

#### 1.7.2 `process_wait(eax = pid)` — returns exit code / -1

`pid == -1` means any child. Loop:

1. Scan all 16 slots for `STATE == ST_ZOMBIE && TCB_PARENT == my pid && (pid == -1 || pid == slot+1)`.
2. Found: take `EXITCODE` (save on stack) → `pmem_free_pages(TCB_STACK, 2)` (the kernel stack is
   returned only now) → **zero the whole 132-byte block** (equivalent to `ST_EMPTY`) →
   `--sched_live` → return the exit code.
3. No zombie after the scan:
   - And there is no "my child" at all (i.e. no `TCB_PARENT == me && STATE != ST_EMPTY`) → return **-1**
     (`wait: no child`).
   - There are live children → `pushfd; sti; hlt; popfd`, then go back to step 1 and rescan.
4. **`sti` before `hlt` is mandatory**: with interrupts disabled, `hlt` sleeps until the end of time
   (barring an NMI); wakeup relies on IRQ0 (fires every tick), so it sleeps at most 10 ms before
   rescanning, no semaphore needed.
- Race note: if a child exits between the "check" in step 3 and "sleep" in step 2, the sleep still runs
  until the next tick and then rescans — harmless (just one extra tick of sleep), no extra lock needed.
- A zombie that is not your child (the kind **reclaimed directly by the kill path, see §1.8**) will
  never be seen by anyone; that is intentional.

### 1.8 kill: three paths

`process_kill(eax = pid)` (both the shell's `kill <pid> [sig]` and `int 0x30` function 22 go through it):

1. Map `pid` to a slot; out of range or `STATE == ST_EMPTY` → return -1.
2. `pid == my own pid` → refuse (`kill: cannot kill yourself`; in the shell this is the same as
   `cmd_kill`'s current "cannot kill").
3. **A shell slot (`slot < SH_MAX`) with `SP_RUNNING == 1`**: can only set `TCB_SP_KILLREQ = 1`, and
   IRQ0's `run_resume_kernel` does the teardown (**keeps original semantics**: the reason is we don't
   dare destroy the stack while sitting on someone else's ring3 frame).
4. **Ordinary process**: `space_deactivate` (if LIVE) → `space_destroy_at` → staging pages
   `pmem_free_pages` → `pmem_free_pages(TCB_STACK, 2)` → clear the parent of `TCB_PARENT`? No — first
   `process_adopt_children` → zero the whole block → `--sched_live` → return 0.
   This path **never passes through ST_ZOMBIE**, so the parent's `wait` can't get it — it counts as
   "already reaped", and `wait` will treat it as not being a child (if it was the only child, `wait`
   returns -1).
5. Target already ZOMBIE: clear it per step 4 (reaping it on the side), return 0.

| Target | Result | Can the parent's wait get it? |
| --- | --- | --- |
| program running on a shell slot | set `KILLREQ`, IRQ0 tears down, prints killed | yes (goes through `run_resume_kernel`, same as run) |
| ordinary process (ST_ALIVE/STOPPED) | destroyed immediately, slot cleared | **no** (already reaped) |
| ZOMBIE | slot cleared | no |
| self | refused | — |

---

## 2. Signal model

### 2.1 Triple: permission class : action : level

The canonical form of a signal is `<class>:<action>:<level>`, e.g. `super:kill:0`, `user:term:2`,
`system:stop:1`. The three parts are independent in their values but constrain each other semantically
(level 0 may only be sent by super, level 1 only by super/system, ...).
**This stage does not validate sender permissions**, it only parses, encodes, and stores fields (§2.8).

### 2.2 Permission class

| Value | Name | Aliases | Meaning in this stage |
| --- | --- | --- | --- |
| 0 | `super` | `root`, `SYSTEM` | highest; root and SYSTEM are both just **aliases** for it, same class |
| 1 | `system` | — | system level (kernel/service) |
| 2 | `user` | — | ordinary user |
| 3..15 | reserved | — | parser rejects |

- Aliases exist only in docs and the parser, **no identity system**: no uid, no "who is root" check (§4).
- ⚠ Case trap: `SYSTEM` (all caps) is an alias for `super`, `system` (all lowercase) is class 1. The
  parser is **case-sensitive**; suggestions in the shell prompt should use only `super:kill:0`, don't
  let users type `SYSTEM`.

### 2.3 Action

| Value | Name | Default action | Implementation level in this stage |
| --- | --- | --- | --- |
| 0 | (reserved) | — | parser rejects, bitmap bit0 is always 0 |
| 1 | `kill` | terminate immediately, uncatchable (level 0) | complete |
| 2 | `term` | terminate; catchable by a handler | default action only (no user-mode handler) |
| 3 | `stop` | `ST_ALIVE → ST_STOPPED` | complete |
| 4 | `cont` | `ST_STOPPED → ST_ALIVE` | complete (also delivers stranded pending signals) |
| 5 | `intr` | interrupt the current syscall | **simplified**: only sets pending, does not really interrupt |
| 6 | `usr` | user-defined | **only sets pending**, reserved for the next stage |
| 7..255 | reserved | — | parser rejects |

### 2.4 Level

| Value | Name | Who can send | Affected by blocked | Behavior once in the bitmap |
| --- | --- | --- | --- | --- |
| 0 | highest | super only | no | executed **immediately in place** on send (not deferred to a tick); kill uses this = uncatchable |
| 1 | system | super / system | no | set pending, executed by the pump on the next tick |
| 2 | user | anyone (this stage) | yes | executed as soon as set; if blocked it stays pending until unblocked |
| 3 | advisory | anyone (this stage) | yes | only sets pending; **the kernel takes no action** (usr/intr have no kernel action anyway) |

- Level decides exactly three things: (1) the send gate (not validated in this stage); (2) whether
  blocked is consulted; (3) level 0 executes immediately.
- The bitmap holds only the "action number", no level. **Strictly distinguishing 1/2/3 would require
  pending to carry a level (a triple queue), which belongs to the sigaction stage**; this stage
  sidesteps that gap by "deciding behavior at send time", which is still semantically consistent
  (level 3 with kill is meaningless; with usr it just means "note it down").

### 2.5 `signal_t` 32-bit encoding and parsing

| Bits | Width | Meaning |
| --- | --- | --- |
| 31..24 | 8 | permission class (0..15 valid) |
| 23..16 | 8 | action (1..6 valid) |
| 15..0 | 16 | level (0..3 valid) |

| Text | class | action | level | `signal_t` |
| --- | --- | --- | --- | --- |
| `super:kill:0` | 0 | 1 | 0 | `0x00010000` |
| `system:term:1` | 1 | 2 | 1 | `0x01020001` |
| `user:term:2` | 2 | 2 | 2 | `0x02020002` |
| `system:stop:1` | 1 | 3 | 1 | `0x01030001` |
| `super:cont:1` | 0 | 4 | 1 | `0x00040001` |
| `user:intr:2` | 2 | 5 | 2 | `0x02050002` |
| `user:usr:3` | 2 | 6 | 3 | `0x02060003` |

`process_signal_parse` (`esi` = ASCII string, `eax` = `signal_t`, `CF = 1` means syntax error):

1. Skip leading spaces; empty string → error.
2. Compare class: `super` / `root` → 0; `SYSTEM` → 0 (all caps); `system` → 1; `user` → 2.
   Longest match wins (`super` and `system` don't share a prefix, but for `s...` you must compare by
   length); the class must be followed immediately by `:`.
3. Compare action: `kill`/`term`/`stop`/`cont`/`intr`/`usr` → 1..6, must be followed immediately by `:`
   or end of string.
4. Read level: 1–2 decimal digits, range 0..3; a non-digit or >3 → error.
5. Trailing whitespace allowed; extra characters → error.
6. `eax = class << 24 | action << 16 | level`; `CF = 0`.
- The parser **writes no state** (pure function); in the `kill` command a parse failure falls back to
  the default `super:kill:0` and prints one line.

### 2.6 pending / blocked bitmaps and delivery

- Two 32-bit words, bit = **action number**: bit1 kill, bit2 term, bit3 stop, bit4 cont, bit5 intr,
  bit6 usr; bit0 and bit7..31 are always 0. Valid mask `SIGNAL_ACTIONS = 0x007E`.
- Send: the level decides whether blocked applies (levels 0/1 ignore blocked entirely) → set the
  `PENDING` bit; level 0 executes immediately.
- Delivery points (`process_signal_pump`, **the only place in the kernel that consumes pending**):
  - In `kernel/pit.asm`'s `irq0_stub`, after EOI and before `sched_pick`
    (`call process_signal_pump_current`), execute `PENDING & ~BLOCKED` of the current process bit by
    bit; clear each bit after executing it. **The pump must preserve all registers** (an interrupt path
    must not dirty someone else's frame): `pushad`/`popad`, or touch only the scratch registers the
    calling convention allows.
  - In `process_signal_send`, the in-place execution for level 0 goes through the same code (factored
    out as `process_signal_apply`).
  - After `cont`, and after `signal_block` unmasks, call the pump once each (to catch up on stranded
    signals).
- **"Immediate" for level 0 means terminating the target in the sender's context**: the target is
  always another process (sending to yourself is rejected by §1.8 step 2 on the normal path), so
  clearing the slot is safe; if the target is currently running in ring3, this is still §1.8 step 4
  (destroy directly). The path that kills the current process must **jump away**
  (`jmp sched_abandon_current`), never `ret` — the return address is on a stack about to be discarded.

### 2.7 Action semantics (copied from the user's final spec, mapped one by one to code)

| Action | Semantics | Implementation site |
| --- | --- | --- |
| `kill` | terminate immediately; level 0 is uncatchable, doesn't even look at blocked | `process_kill(pid)`; `ST_ZOMBIE` also counts as "terminated" |
| `term` | catchable by a user-mode handler; **no handlers in this stage → default action = terminate** | same as kill, but leave an empty shell of `process_signal_deliver_user` |
| `stop` | `STATE = ST_STOPPED`; the scheduler (which already picks only ALIVE) skips it automatically | just write the field |
| `cont` | `STATE = ST_ALIVE`, then pump once to deliver stranded pending signals | `sched_live` unchanged |
| `intr` | interrupt the current syscall | simplified: only set pending / clear the bit, don't touch api_dispatch's frame |
| `usr` | user-defined | only set pending, left for the next stage's sigaction |

- `stop` on a shell slot: allowed, but once the shell is stopped nobody reads the keyboard (that whole
  shell freezes). This side effect is **accepted by design**; tests should not send stop to a shell.
- Sending a signal to `ST_ZOMBIE`: only sets pending, no action (zombies are never scheduled again);
  after `wait` the bitmap is cleared along with the slot.

### 2.8 Boundaries of this stage (explicitly out of scope)

- **No permission checks**: the sender's class is not checked, so `user` can also send `super:kill:0`
  (level is used only for encoding and blocked decisions). This is a pit deliberately left for the
  multi-user stage, not an oversight — written down here so it isn't filed as a bug.
- No **queueing** of pending signals (sending the same action twice records it once), no signal numbers
  (the SIGKILL/SIGTERM set), no parent inheritance of the signal mask (blocked is cleared on fork, see
  §1.4.2 step 10).
- No real interruption for `intr` (that would need to unwind from the middle of `api_dispatch` back to
  ring3).

---

## 3. Relationship with multi-shell

**This stage keeps multi-shell for now, without deleting a single line.**

| Item | Current state | This stage |
| --- | --- | --- |
| shell count | `SH_MAX = 4`, four kernel threads in slots 0..3 | kept; PIDs 1..4 |
| switching | `Ctrl+Left/Right`, `sh_active` decides who gets the keyboard | untouched |
| keyboard ownership | `sh_active` | untouched |
| per-shell line-edit buffer | one per thread | untouched |
| shell PID | slot number (0..3) | **1..4** (+1) |
| slot count in `ps` | 6 | 16 |
| killing a program running on a shell | set `KILLREQ`, IRQ0 tears down | kept as-is (§1.8 step 3) |

- Each shell is itself a process (PID 1..4), with `TCB_PARENT = 0` and `TCB_OWNER = itself`.
- Forked children **do not occupy shell slots**: `process_alloc_slot` starts from `SH_MAX`, and shell
  slots are always reserved for shells.
- A child's "terminal" ownership: inherits the parent's `TCB_OWNER`, visible in `ps`; but **output still
  goes to the global cursor/screen** (Phase 2's virtual console only covers the shell's own line editing,
  not child processes). This is a known rough edge, to be handled in the next stage (§6 "shell/console
  simplification"); **this stage does not touch the keyboard or switching logic**.

---

## 4. Relationship with multi-user / permissions

### 4.1 What this stage does and doesn't do

| Item | This stage |
| --- | --- |
| permission class field in `signal_t` | **designed in** (8 bits, 0/1/2 valid) |
| parse/encode/store the permission class | **done** |
| permission check on send (is the sender's class sufficient) | **not done** |
| root / SYSTEM identity mapping | **not done**, only the alias relationship is documented (§2.2) |
| process uid/gid | **not done**, only the field slot is reserved (§4.2) |
| file permission bits, permission meaning of `TCB_OWNER` | **not done**, keeps "birth shell" semantics |

### 4.2 Reserved location for uid fields

The 132 bytes are already full (0..131 are all fields, no holes). The plan for landing multi-user next stage:

| Option | Approach | Cost |
| --- | --- | --- |
| **A (chosen)** | `TCB_SIZE` 132 → **140**, add `TCB_UID = 132`, `TCB_GID = 136` | change one `equ` + the 16×132 static buffer in `sched.asm` (2112 → 2240 bytes); `TCB_OFF` follows automatically, other offsets unchanged |
| B | reuse the high byte of `TCB_OWNER` as a uid hint | no size change, but mixed semantics: `OWNER` would mean both "which shell" and "who" — not acceptable |

- This stage **adds no field**; `TCB_OWNER` stays the 0..3 "birth shell number".
- Mapping between `signal_t`'s class and future uids: uid 0 ↔ class 0 (super), system accounts ↔ class 1,
  ordinary users ↔ class 2. This mapping lives only in the docs for now; the code doesn't check it.

### 4.3 Interface reserved for identity checks

Decide the signature of the future `process_signal_check_sender(sig)` now: `eax = signal_t`, `CF = 1`
means "not allowed to send". This stage the function **does not exist**; a comment in
`process_signal_send` points here, and the next stage just fills in the implementation.

---

## 5. Phased implementation plan

### 5.1 This stage (first cut) checklist

| # | Item | Site | Done when |
| --- | --- | --- | --- |
| 1 | 16-entry process table, five new fields, `pid = slot+1`, state machine | `kernel/sched.asm` (changed) | `ps` prints 16 slots; `sizeof(TCB)=132` |
| 2 | refcount table + `pmem_free` decrement semantics | `kernel/pmem.asm` (changed) | after fork, `debug pmem`'s free count doesn't plummet |
| 3 | `PAGE_COW`, COW faults, `CR0.WP` | `kernel/paging.asm` (changed)/`idt.asm`/`kmain` | FORK.BIN parent and child don't cross pages |
| 4 | `process_fork` (full COW flow) | new `kernel/process.asm` | function 18 returns parent pid / child 0 |
| 5 | `process_exec` (no argv) | same | `fork FORK.BIN` runs |
| 6 | `process_exit` / `process_wait` / orphan adoption | same | child exits → ZOMBIE → wait gets the code |
| 7 | `process_kill` (three paths) | same | after `kill 5` it's gone from ps |
| 8 | signals: parse/encode/send/pending/blocked/pump/stop/cont | same + `pit.asm` | `kill 5 user:term:2` takes effect |
| 9 | shell commands `ps`/`fork`/`fork <prog>`/`wait`/`kill <pid> [sig]` | `kernel/shell.asm` | see §5.2 |
| 10 | APIs 18–23 + `kkernel.h` wrappers | `kernel/api.asm`, `include/kkernel.h` | see §5.3 |

### 5.2 Shell commands

| Command | Behavior | Output convention (strings the tests look for) |
| --- | --- | --- |
| `ps` | walk 16 slots, one line per process | header `N alive / 16 slots`; row `[pid] name ppid=P st=ALIVE ticks=N runs=M` |
| `fork` | built-in demo child (spawn a kernel routine) | `fork: child pid=5 ppid=1`, the child prints `child: pid=5 ppid=1` itself, then `exit(7)` |
| `fork <prog>` | new process + new space + load prog; child starts in ring3 | `fork: pid=5 /prog 已装载` (single line) |
| `wait` | wait for any child, print the exit code | `wait: pid=5 exit=7`; with no children `wait: no child` |
| `kill <pid>` | default signal `super:kill:0` | success `kill: pid=5 killed`; failure `kill: no such process` / `kill: cannot kill yourself` |
| `kill <pid> <class>:<action>:<level>` | `process_signal_parse` first; on failure fall back to the default and warn | `kill: bad signal "..."` |

- The `ps` row format **keeps the `[id] name ticks=N` prefix** (the existing test regex
  `\[(\d)\] (alpha|beta)\s+ticks=(\d+)` depends on it), with `ppid=`/`st=` appended after.
  Only the header `6 slots` changes to `16 slots`.
- `kill`'s pid parsing reuses `cmd_kill`'s existing decimal parsing; `0` counts as "self" → refused.

### 5.3 Syscalls (`int 0x30`) and `kkernel.h`

`api_stub`'s write-back convention is unchanged: only `eax`/`ebx`/`esi` are written back;
`ecx`/`edx`/`edi`/`ebp` are read-only on the user side.

| # | Name | User arguments | Returns (`eax`) | Kernel implementation | Notes |
| --- | --- | --- | --- | --- | --- |
| 0–17 | existing | — | — | — | untouched |
| 18 | `fork` | — | parent: child pid; child: 0; failure -1 | `process_fork` | `ebx` passes the `api_stub` frame base (internal) |
| 19 | `wait` | `ebx = pid` (`-1` = any) | exit code / -1 | `process_wait` | |
| 20 | `exit` | `ebx = code` | does not return | `process_exit` | same implementation as 15; 15 is "program return", 20 is "process exit" |
| 21 | `getpid` | — | pid (1..16) | `process_getpid` | |
| 22 | `signal_send` | `ebx = pid`, `ecx = signal_t` | 0 / -1 | `process_signal_send` | kernel-side convention: `eax=pid, ebx=sig` |
| 23 | `signal_block` | `ebx = bitmap` (bit = action number) | the new `BLOCKED` | `process_signal_block` | simplified: overwrite the bitmap directly, set bit = block; pump once after unblocking |
| 24 | `exec` | `esi = filename` | does not return / -1 | `process_exec` | **this stage only for the kernel's `fork <prog>` path**, not exposed to user mode yet |

`include/kkernel.h` gains `static inline` wrappers:

```
j_fork()            -> eax            0 / child pid / -1
j_wait(pid)         -> eax            exit code / -1
j_exit_code(code)   -> does not return         ← careful! don't call it j_exit
j_getpid()          -> eax
j_signal_send(pid, sig)  -> eax
j_signal_block(mask)     -> eax
```

- **Name collision**: `j_exit(const char *msg)` already exists and means "clear screen + print one
  line", **it does not call API 15**. Process exit must use a different name (`j_exit_code` or
  `j_proc_exit`); otherwise someone changing `j_exit`'s implementation later would turn a bunch of
  programs' return values into 0.
- Follow the `KK_SYSCALL0`/`KK_SYSCALL1` macro style; on the C side `signal_t` is just `uint32_t`, no
  struct introduced.

### 5.4 Suggested implementation order (each step builds and tests on its own)

1. `sched.asm`: confirm 132/16 and the five new fields assemble; `ps` prints 16 slots (shell slots
   0..3 behave normally).
2. `pmem.asm`: confirm that under `pmem_free`'s decrement semantics the boot memory accounting is
   unchanged (`debug pmem` identical before and after).
3. `paging.asm` + `idt.asm`: COW branch + `CR0.WP`; first hand-craft a "parent writes a COW page"
   scenario and watch `PFCOW` increase.
4. `process.asm`: only `process_alloc_slot` / `process_getpid` / `process_exit` / `process_wait`, plus
   the `fork` (demo, spawn path) and `wait` shell commands → first get "spawn a process, reap one exit
   code" working.
5. `process_fork`: the full COW flow + function 18; use FORK.BIN to verify parent/child isolation.
6. `process_kill` + the `kill` command; verify both the shell-slot and ordinary-process paths.
7. signals: parse → encode → `send` (level 0 immediate, level 2 stranded) → `pump` (IRQ0) → `stop/cont`;
   finally `signal_block`.
8. `process_fork_exec` + `fork <prog>`; API 24 called internally.
9. `ps` row format + 16-slot header; `tests/qemu_test.py --proc`; `test-proc` in the `Makefile`.
10. Regression: `make -s test-hda` 20/20, `make test-shell`, `make test-hd-font`.

### 5.5 How to add tests

`tests/qemu_test.py`:

| Item | Content |
| --- | --- |
| switch | `proc_mode = "--proc" in argv`; add `"--proc"` to the `argv` filter list (otherwise it is treated as an image path) |
| placement | after the `hd_mode` (`--fontdisk`) block, as its own `if proc_mode:` block; reuse the `run` / `wait_idle` / `rescan` / `has` helpers (same as the `shell`/`hd` blocks) |
| image | must be **HDIMG** (FORK.BIN is on disk), so pass `--hda --fontdisk` together |

Assertions (all based on screen text, consistent with the existing test style):

| # | Assertion | Expected text |
| --- | --- | --- |
| 1 | fork counters and parent/child relation | FORK.BIN prints `parent: shared=1 wait=7` (the parent's own value) and `child: shared=99` (the child changed its own copy) |
| 2 | COW parent/child page isolation | both lines appear together → proves the parent's write didn't leak to the child and vice versa |
| 3 | `ps` shows parent and child | regex `\[(\d+)\] (FORK|child).*ppid=(\d+)` and the parent row has `ppid=1` |
| 4 | child is a zombie after exit | `st=ZOMBIE` in `ps`; after `wait` that pid is gone from `ps` |
| 5 | wait gets the exit code | `wait: pid=N exit=7` |
| 6 | kill terminates | `kill N` → `kill: pid=N killed` → N is absent from `ps` |
| 7 | signal syntax parsing | `kill N super:kill:0` accepted; `kill N user:term:2` accepted; `kill N bogus:x:0` prints `bad signal` and the process is still there |
| 8 | stop / cont (optional) | after `kill N system:stop:1`, `ps` shows `st=STOPPED`; then `system:cont:1` returns it to `st=ALIVE` |

`Makefile`:

```
test-proc: $(HDIMG)
	$(MAKE) -s -B $(HDIMG)
	python3 -u tests/qemu_test.py $(HDIMG) --hda --fontdisk --font font/full-kkf.bin --proc
```

- Add `test-proc` to `.PHONY`; also chain it into the `test:` target (optional; if it's slow, leave it
  manual for now).
- Use `$(HDIMG)` rather than `$(IMG)`: FORK.BIN must be readable from the FAT disk; `$(MAKE) -s -B` is
  there to repack changes to `progs/FORK.BIN` into the image.
- **`test-hda` must stay 20/20**: it exercises the floppy path and has nothing to do with processes, but
  since the slot count in the `ps` header changed, **any test that hardcodes `6 slots` must change too**
  (`shell` mode's `ps_rows()` contains `"alive / 6 slots"`, plus assertions like `ids == [4, 5]` written
  for the old `SCHED_MAX`).

### 5.6 Known traps (self-check against this list while implementing)

1. After fork you **must flush CR3**, otherwise the parent's TLB keeps stale "writable" PTEs and COW
   silently stops working.
2. **`CR0.WP` (bit16) must be set**, otherwise kernel writes to read-only pages don't fault and COW only
   works for ring3 — half-broken.
3. When the refcount is at 15, fork fails: **do the precheck before modifying PTEs**, otherwise rollback
   has to flip the parent's PTE bits back one by one.
4. **Staging pages need their own `pmem_ref_inc`** — they are not in the address space, so the PT walk
   doesn't see them.
5. `TSS.esp0` must point at the new stack top before switching into ring3 (for a fork child it's
   `stack top`, not `stack top-60`).
6. In `wait`, `sti` before `hlt`, otherwise it sleeps forever (barring NMI); wrap it in
   `pushfd/sti/hlt/popfd`.
7. In `process_exit`, **`space_deactivate` before `space_destroy`**; reverse the order and you reclaim
   page-table pages still in use.
8. `process_exit` must not `ret`: returning onto a stack that wait is about to reclaim is undefined
   behavior; always `jmp sched_abandon_current`.
9. Same for the path that kills the current process (in the signal pump): it must jump away.
10. Kernel threads **do not COW-fork** (§1.4.4); the shell's `fork` takes the special path, don't reuse
    `process_fork` to save effort.
11. `ps`'s existing regex depends on the `[id] name ticks=` prefix; **appending fields is fine, changing
    the prefix breaks the tests**.
12. The name `j_exit` is taken (§5.3); call the new wrapper `j_exit_code`.
13. Orphans must be adopted (`process_adopt_children`), otherwise after the parent exits the children are
    never waited for and their slots leak.
14. A fork child's `TCB_ESP` frame is both the "first time scheduled" entry and the "restore after being
    switched out" frame; the two formats are identical (60 bytes), don't invent a second one.
15. The signal pump runs inside IRQ0, so it **must preserve registers**; its output has no return space.

### 5.7 Follow-up stages

| Stage | Content | Depends on |
| --- | --- | --- |
| 4 | `sigaction`: user-mode handlers, real signal frames (redirect `EIP/ESP` to a user-registered address before entering the handler), catchable `term` | this stage's bitmap and action semantics |
| 4 | real `intr`: unwind from mid-`api_dispatch` back to ring3, syscall returns `EINTR` | needs the api layer to record "interruptible points" |
| 5 | multi-user identity: uid/gid, `TCB_UID/GID`, class validation (`process_signal_check_sender`), file permission bits | this stage's class encoding and reserved slots |
| 5 | `exec` argv/envp: grow the argument page from "one 0 byte" to an `argc/argv[]/envp[]` structure | `process_exec` and `j_arg` |
| 6 | process groups / sessions: session leader, foreground/background process groups, `Ctrl+C` to the foreground group, `TCB_PGID/TSID` | multi-shell and console simplification |
| 6 | shell / console simplification: one foreground process per shell, `wait` and job control, drop the `SH_MAX` four-thread model | Phase 2's virtual console |
| 7 | SMP: per-CPU `sched_cur`, atomic `sched_live`, `loader_lock` becomes a spinlock | everything |
| — | FPU/SSE context save, kernel-thread fork, `ST_DEAD` cleanup | low priority |

---

## 6. Reserved interfaces (not implemented in this stage)

The items below are **designed with a place reserved but explicitly absent from the code**. Don't add
them casually while implementing; if you do, come back and update this section first.

| # | Reserved item | Location | State in this stage | How the next stage hooks in |
| --- | --- | --- | --- | --- |
| P1 | `TCB_UID` / `TCB_GID` fields | after TCB 132 (132/136), `TCB_SIZE` → 140 | no fields | change one `equ` + static buffer size (§4.2) |
| P2 | sender permission check `process_signal_check_sender` | comment in `process_signal_send` | function absent, no check | fill in implementation, `CF=1` rejects |
| P3 | class ↔ identity mapping (root/SYSTEM/user) | §2.2 alias table, §4.3 | documentation mapping only | hook up the uid system, `uid==0 → class 0` |
| P4 | strict distinction of levels 1/2/3 | `TCB_PENDING` holds only action numbers | bitmap only, sidestepped by "behavior decided at send time" | change pending to a triple queue (action + level + source) |
| P5 | `sigaction`: user-mode handlers | `term`'s default action | only "default = terminate", no handlers | user-mode function table, switch user stack and EIP on delivery |
| P6 | real `intr`: interrupt syscalls | `api_dispatch` | only sets pending, no interruption | plant interruptible points at syscall entry, return `EINTR` |
| P7 | user-defined handling of the `usr` action | `process_signal_apply` | only sets pending | merge with P5 |
| P8 | `exec` argv/envp | argument page `PROG_ARG_STR` | only writes one 0 byte | change the argument page to an `argc/argv[]/envp[]` layout, update `j_arg` accordingly |
| P9 | user-mode `exec` API (function 24 opened up) | `api_dispatch` entry 24 | only used by the kernel's `fork <prog>` | allow DPL3 calls + self-terminate semantics on `-1` |
| P10 | process groups / sessions (`TCB_PGID`/`TSID`) | TCB grows another 8 bytes | no fields | grow together with P1, `Ctrl+C` to the foreground group |
| P11 | job control (foreground/background, `SIGTTIN`/`SIGTTOU`) | none | none | depends on P10 + shell simplification |
| P12 | shell/console simplification (`SH_MAX` convergence, one foreground per shell) | `shell.asm`/`cons.asm` | **untouched this stage** (§3) | separate stage, do P10 first |
| P13 | SMP support | `sched.asm` | single-core assumption | per-CPU `sched_cur`, atomic `sched_live` |
| P14 | zombie queue / batch `reap_children` | `process_wait` | linear scan of 16 slots (good enough) | switch to a queue when there are more pids |
| P15 | FPU context, kernel-thread fork, `ST_DEAD` cleanup | — | not done | low priority |

## 7. Why wait state cannot live in globals (Phase D wait-race)

`process_wait2` **sleeps inside a syscall waiting for a child to exit**. During that sleep the thread's
kernel stack is still there (the scheduler switches threads by swapping `TCB_ESP`; kernel stacks are not
reclaimed while sleeping), and another thread can enter the same function at any moment. If "this wait's
arguments / sleep channel / outputs" lived in globals shared across threads (the old implementation's
`pw_pid`/`pw_flags`/`pw_tcb`/`pw_sleeping` plus `proc_wait_status`/`proc_wait_pid`/`proc_wait_code`/
`proc_last_*`), two threads waiting at the same time would overwrite each other:

- the sleep channel gets changed → wakeups are lost / `sched_sleep_cancel` cancels the wrong sleep;
- the reap target gets changed → you reap someone else's child / reap an already-cleared TCB again;
- `proc_wait_*` gets overwritten by the later waiter → the caller gets someone else's exit code and page
  counts.

The fix (current implementation):

1. **Keep the sleep-time frame on this thread's kernel stack**. `process_wait2` does `pushad` on entry
   then `sub esp, PW_FRAME`; the arguments, `PW_SELF` (this thread's TCB pointer, also the sleep channel),
   and `PW_SLEEPING` all live in the frame; `sched_sleep_prepare/commit/cancel` recognize only that
   channel.
2. **Write event outputs into this thread's TCB**. `TCB_SIZE` 200→240, adding
   `TCB_WAIT_STATUS`/`TCB_WAIT_PID`/`TCB_WAIT_CODE` (this wait's event) and
   `TCB_LAST_CHILD`/`LAST_FREED`/`LAST_RUNSTAT`/`LAST_PFRUN`/`LAST_PFIMG`/`LAST_PFHEAP`/`LAST_FIRSTPA`
   (the reap snapshot, used by `cmd_run` to print the job result).
   `process_wait`, `process_wait_status_get`, `process_last_child_get`, `process_last_snapshot` all read
   the current thread's TCB via `process_cur_tcb()`, so there is no wait state shared between threads.
3. **Treat every similar "blocking syscall frame" this way from now on**: this thread's kernel stack frame
   + this thread's TCB; if it doesn't fit, grow `TCB_SIZE` (always go through the `TCB_SIZE` macro /
   `TCB_OFF`, never hardcode).
   `--wait-race` regresses with two concurrent instances each doing 50 fork/wait rounds: two parent
   threads stuck in `process_wait2` at once, so any cross-thread interference shows up in the exit codes
   (it also uses the shell's `jobs` scan to create a third concurrent waiter on the side).

---

---

*The offsets/function names/API numbers in this draft are aligned with `kernel/sched.asm` (SCHED_MAX=16,
TCB_SIZE=240 (after Phase D wait-race)), `kernel/pmem.asm` (REFCOUNT_BASE=0x3D2000), `kernel/paging.asm`
(PAGE_COW=0x200). If implementation changes these constants, change this draft before changing the code.*
