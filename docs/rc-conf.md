[简体中文](zh-CN/rc-conf.md)

# rc.conf: the services and event config read at boot

KKernel's "service manager" is a single file: **`/SYS/RC.CONF`**, with BSD / OpenRC-style
`key = value` syntax (as the user asked for — **not** systemd's unit sections). The kernel reads it
once at boot and tells you whether the configuration took effect; to change it, `write RC.CONF ...`
and then `rc reload` — no need to rebuild the image.

It does two things:

1. **Run programs according to the config** (services): `service_N` names a program on disk,
   `rc start N` runs it by hand, or `autostart="YES"` makes boot run them through in order;
2. **Keep an event log**: boot, config read, service start/stop, program finished / crashed, thread
   killed, shell switch — each recorded together with its tick in a 16-slot ring buffer, browsable
   with `rc log`.

Implementation: one file [`kernel/rc.asm`](../kernel/rc.asm) (about 700 lines); services borrow the
shell's `run` path — so service programs **also run in ring 3 and also go through demand paging**
(see section 5 of [../../README.zh-CN.md](../README.md)).

---

## 1. Syntax (just three rules)

```
# one key=value per line; blank lines and lines starting with # are ignored
hostname="kkernel"            # values may be double-quoted, # starts a comment
BOOT_MSG=hi from rc.conf    # keys are case-insensitive; quotes are optional
```

* One `key=value` per line; after a `#` at the end of a line comes a comment (there has to be a space
  before the `#`);
* When a value is double-quoted, what's inside the quotes counts verbatim (that's the only way
  something like `"NO   # comment"` gets the `#` into the value);
* Key comparison is **case-insensitive**; `HOSTNAME` and `hostname` are the same thing.

Limits (anything over the limit is ignored, nothing crashes):

| Thing | Limit |
| --- | --- |
| Config file size | 4 KiB (`RC_MAX`) |
| Number of keys | 32 (`RC_KEYS`) |
| Number of services | 8 (`RC_SVCS`, numbered 1~8) |
| Event log | 16 entries (ring buffer, oldest overwritten when full) |

## 2. Recognised keys

| key | Meaning |
| --- | --- |
| `hostname` | Host name (shown in the `rc` summary; doesn't affect the command prompt) |
| `osname` | System display name (default `KKernel`; boot prints `os: <name>`) |
| `style` | Prompt style: `kao` (kaomoji, default) / `plain` / `moe` / `dos` / `c64` (see "Prompt styles" in [architecture.md](architecture.md); omit it and you get `kao`) |
| `boot_msg` | Print one line at boot (`boot_msg: ...`) — visible proof the config took effect |
| `autostart` | `YES` = at boot, run the "enabled services" in numeric order; default `NO` (otherwise boot would get stuck inside a service) |
| `on_crash` | What to do after a program crashes (killed by a page fault in ring 3): `log` = just record it (default), `reboot` = reboot the machine |
| `service_N` | Name of the program service N should run (`.BIN` appended if missing) |
| `service_N_enable` | `YES` / `yes` / `1` all mean "enabled"; only enabled services are run by autostart |
| `service_N_args` | Arguments passed to the service (through the same argument channel as `run`) |

N is 1~8. If `service_N` is set but `service_N_enable` isn't, `rc list` shows it as `disabled`
(manual `rc start N` still works).

## 3. The `rc` command

```
rc            summary: which file was read, how many keys, hostname, autostart / on_crash, how many services
rc list       list all registered services (number, program, enabled state, args)
rc get <key>  get the value of a key (case-insensitive)
rc start <n>  run service n as a program (via the run path)
rc log        event log (the most recent 16 entries, with ticks)
rc reload     re-read and re-parse RC.CONF from disk (changes take effect immediately)
```

Real output (none of it needs `run`; it's all typed at the shell):

```
> rc
rc.conf  : RC.CONF
  keys     : 9  services : 2 (0)
  hostname  : kkernel
  autostart: NO
  on_crash : log
rc list / rc get KEY / rc start N / rc log / rc reload
> rc list
services in RC.CONF:
[1] HELLO.BIN disabled  args: hi-from-rc-conf
[2] COUNT.BIN disabled
rc start N 就能跑;enabled 只影响开机 autostart
> rc start 1
running HELLO.BIN
address space: CR3 = 0x00406000  (own page directory + demand paging)
Hello from HELLO.BIN - I was loaded from the FAT16 disk!
...
program returned to the shell
address space destroyed: 6 page(s) back to the pool
demand paging: 1 page(s) faulted in (image 1 + heap 0), first page 0x0040B000
> rc log
event log (tick = 100 Hz PIT 心跳):
  t=2  boot  arg=0x00000000
  t=2  rc.conf  arg=0x00000000
  t=2134  service start  arg=0x00000001
  t=2159  program exit  arg=0x00000001
  t=2159  service ok  arg=0x00000001
```

*(Chinese output shown as-is.)*

The two boot lines look like this (the first is what `RC.CONF` gave us, the second is `boot_msg`):

```
rc.conf: RC.CONF, 9 keys, hostname kkernel, services 2 (0)
boot_msg: hello from rc.conf (this line came off the disk)
```

With `autostart="YES"` and `service_1_enable="YES"`, boot prints one extra line before the shell
comes up, `rc.conf: autostart=YES, starting enabled services...`, and then the service program runs
itself to completion:

```
event log (tick = 100 Hz PIT 心跳):
  t=2  boot  arg=0x00000000
  t=2  rc.conf  arg=0x00000000
  t=6  service start  arg=0x00000001     ← boot had HELLO running 60 ms in
  t=11  program exit  arg=0x00000001
  t=11  service ok  arg=0x00000001
```

## 4. The event log: what gets recorded

| Event name | When it's recorded | Attached number (arg) |
| --- | --- | --- |
| `boot` | when the kernel comes up | 0 |
| `rc.conf` | after reading / re-reading the config | 0 |
| `service start` | a service is about to start | service number |
| `service ok` | service finished normally | service number |
| `service failed` | service was killed (crashed / killed) | service number |
| `program exit` | any program returned to the shell normally (`run` counts too) | how many pages were faulted in this time |
| `program crash` | program was killed by an exception in ring 3 | EIP at the fault |
| `thread killed` | `kill <id>` killed a thread | thread number |
| `shell switch` | Ctrl+←/→ or `shell n` changed focus | new shell number |

Events are recorded by `evt_log`: a 16-slot ring buffer, each slot holding "event number + tick +
attached number". The tick is the 100 Hz PIT heartbeat, so the difference in ticks between two
events = the difference in 10 ms units.

## 5. How a service "runs"

`rc start N` is not a separate mechanism: it **temporarily replaces `[cmd_arg]` with a composed
`program args` string and then calls the shell's `cmd_run`** — exactly the same path as typing
`run HELLO.BIN hi` at the command line:

* build its own page directory + demand paging (fault in whichever page is touched);
* `iret` to **CPL=3**; it can't touch kernel memory;
* on return to the shell the address space is torn down and the pages go back to the physical page
  pool.

It can still only **run one program at a time** (the guard on `run`: refuse if someone else is
running, suggesting Ctrl+←/→ or kill), so "services" currently run **sequentially**, not
concurrently — which is exactly what will change once `space_*` hangs off threads (see section 11 of
the README).

## 6. What's missing (limits)

* **No dependencies**: no `after=` / `requires=`, just one numeric run order;
* **No stop**: a service is a "run once and exit" program, not a resident process, so there's no `rc stop`;
* **No restart/retry**: a crashed service is only recorded (`on_crash="log"`) or the whole machine reboots (`"reboot"`);
* **No environment variables / users / permissions**: toy OS, no concept of users, everyone is ring 3;
* **The config file is only `/SYS/RC.CONF`**: no `/etc/`-style paths (and certainly no layering of several configs);
* `hostname` is display-only right now; it doesn't change the command prompt.

For details and the pitfalls we hit, see sections 6.22 ~ 6.24 of
[../../README.zh-CN.md](../README.md) (the config-reading buffer sitting inside the FAT
sector buffer, unbalanced `push`/`pop` leading to `EIP=0x00000007`, small utility functions
clobbering registers, and `strip_name` turning the first space into 0).
