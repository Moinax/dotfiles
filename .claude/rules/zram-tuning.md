---
description: Why one swappiness value needs a privileged step of its own — the CachyOS defaults that contradict each other, the two override mechanisms that silently do nothing, and the size cap that was tried and reverted.
paths:
  - install/lib/zram-tuning.sh
---

# The freeze that reads as a CPU spike

Under a parallel Bazel build this desktop (32 cores, 62 GiB, zram the only swap)
froze whole — cursor included — at an apparent load average of 25. The CPU was
**83% idle**. Nothing was computing; everything was waiting on its own memory.

What the counters said, and why they name the cause rather than the symptom:

| Reading | Value | What it means |
| --- | ---: | --- |
| `user.slice` `memory.peak` | 47 GiB | real pressure, and `memory.events` `low/high/max` all 0, so no cgroup limit was involved |
| `workingset_refault_anon` | 3,222,898 | pages still in the working set, evicted and immediately faulted back |
| `allocstall_normal` + `_movable` | 14,040 | direct reclaim: the allocating task does the work itself, blocked |
| `pswpout` / `pswpin` | 27.7 / 11.7 GiB | sustained churn, not a one-off eviction |

Every one of those refaults is a synchronous zstd decompression charged to
whoever touched the page. Hyprland is one of those, which is why a memory
problem presents as a dead cursor.

## The cause is a default, and CachyOS sets it twice

`vm.swappiness=150`. The reasoning behind it is sound for the machine it targets
— decompressing from zram is cheap, so prefer evicting anonymous pages over
dropping page cache you would have to re-read from disk. That holds when
anonymous pages go cold. Here they do not: they are live JVM and pytest heaps,
retouched immediately. So "compress it, it's cheap" becomes a treadmill, while
tens of GiB of re-readable Bazel page cache sits there as the cheaper thing to
drop.

`cachyos-settings` ships **both** values and contradicts itself:

- `/usr/lib/sysctl.d/70-cachyos-settings.conf` → `vm.swappiness = 100`
- `/usr/lib/udev/rules.d/30-zram.rules` → `SYSCTL{vm.swappiness}="150"`

The boot order decides it. `systemd-sysctl` finished at 10:14:49.866 and zram0
appeared at 10:14:50.008, so the udev rule writes last and wins every boot. The
100 in that sysctl file, and anything `sysctl --system` reports from it, describe
a value nothing is running on.

## Two overrides that silently do nothing

**A drop-in in `/etc/sysctl.d/` loses the same race.** It is applied before zram
initialises, then overwritten. It reads as correct in every file and in
`systemd-analyze cat-config sysctl.d`, and changes nothing at runtime. This is
the trap to re-check first if the value is ever wrong again.

**A file named `30-zram.rules` under `/etc/udev/rules.d` replaces the vendor
rule, it does not amend it.** udev(7): rules files are sorted across all
directories, "files with identical filenames replace each other", and `/etc` has
the highest priority. That shape works and was the first version here, but it
freezes a hand-copy of the vendor rule — a later `cachyos-settings` release that
adds a line to its own file upgrades silently while `/etc` keeps replacing the
whole thing, and pacman never reports a conflict because it owns nothing under
`/etc/udev/rules.d`. There is no `.pacnew` to notice.

So the override is **`90-zram-swappiness.rules`**: a higher number, sorted after
the vendor rule, applying only the one assignment. udev applies every matching
rule in order, so the later value wins while the rest of the vendor rule — the
zswap disable — stays in force and stays free to change with its package.

## The size cap was tried and reverted

`zram-size` is overridable the same way, through a
`/etc/systemd/zram-generator.conf.d/*.conf` drop-in — the main config file has
the *lowest* precedence, per zram-generator.conf(5), so a copy of
`/usr/lib/systemd/zram-generator.conf` would be the wrong mechanism. CachyOS sets
`zram-size = ram` (62.5 GiB here) where zram-generator's own default is
`min(ram / 2, 4096)`, i.e. 4 GiB.

It was dropped anyway, for two reasons worth keeping written down:

- **It does not address a refault storm.** A smaller device does not stop hot
  pages being evicted and faulted back; it only lowers how many can be out at
  once. The swappiness inversion is the measured fix.
- **Every cap small enough to matter is below live demand.** Measured steady
  state on this host is 19.2 GiB of data in zram and 20.7 GiB of swap in use. A
  `ram / 4` cap is 15.6 GiB — under that, so the machine could not reach its
  own working state. With zram the only swap and `systemd-oomd` inactive, the
  result is a kernel OOM kill instead of the stall it was meant to replace.

If zram's own resident footprint ever becomes the problem rather than the
thrashing, `zram-resident-limit` is the knob for that, and it is a different
concern from this one.

## What this does not buy

`transparent_hugepage` is a second, independent source of stalls here —
`compact_stall` sat at 2,983, and every allocation wanting 2 MiB contiguous
stalls in compaction when memory is fragmented. It is deliberately not touched:
`CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y` is compiled into the CachyOS kernel (Arch's
own ships `MADVISE`), so changing it needs a kernel command line or a boot-time
sysfs write — a third mechanism, for evidence three orders of magnitude weaker
than the refault count.

And this is a net, not a fix: the load that triggered the freeze was one Bazel
server fanning a test phase out across 32 cores with a per-server resource
budget, on a checkout with 39 worktrees. Capping that belongs in the project,
not here.
