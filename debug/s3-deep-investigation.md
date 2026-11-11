# Z790 AORUS MASTER X: S3 entry hang

Last updated: 2026-11-11. All times below are Europe/Brussels (UTC+01:00).

## Current conclusion

**The BIOS configuration fix passed three consecutive real S3 entry/wake cycles**
with the normal NVIDIA driver and graphical session, without the diagnostic
module. The user confirmed that fans stopped and screens returned in the first
successful cycle; kernel logs confirm S3 resume in all three.

The decisive configuration change was disabling **Above 4GB MMIO BIOS assignment**
(`SaSetup[0x7E]`). This removed the above-4G root memory window and moved the I2C
controller BAR from `0x4017002000` to `0x40402000`. Disabling the separate
**Above 4G Decoding** option alone had left that allocation unchanged.

Static F11 analysis finds that its S3 I2C-controller handler truncates this BAR
to 32 bits before accessing it. The measured allocation change and three
successful cycles strongly support this mechanism. The actual bad SMM access
was not captured, so the precise faulting instruction is not established.

The validated combination is **Above 4GB MMIO BIOS assignment Disabled,
Above 4G Decoding Disabled, and ReBAR Disabled**. This does not prove each of
the three is independently necessary. No kernel/driver workaround was added.

## Configuration and earlier working state

- Gigabyte Z790 AORUS MASTER X, BIOS F11, SMBIOS date 2025-12-01.
- Kernel `7.3.3-1-cachyos`, NVIDIA open `620.70.06`, Hyprland `0.57.2`.
- ACPI advertises S3; `/sys/power/mem_sleep` is `s2idle [deep]`. No forced
  `mem_sleep_default` kernel parameter or custom `sleep.conf` override was found.
- RTX 4090 BAR1 is 256 MiB; PCIe root port `00:01.0` and GPU `01:00.0` report
  ASPM disabled. Two Corsair CMT64GX5M2B6600C32 DIMMs run at 4800 MT/s, 1.1 V.
  Read-only comparison of live EFI variables with the actual F11 image's IFR
  confirms XMP, ReBAR, Gigabyte's PEG/PCH/DMI/Native ASPM selectors, and S3 Save
  Mode disabled; ACPI Sleep State is S3.
  ErP and Resume By Alarm are disabled, AC BACK is Always Off, and Power Loading
  is Auto. Variable GUIDs/sizes match. No mismatch was found for these settings;
  this does not establish equality of every possible firmware setting.
  Underlying DMI policy fields (`SaSetup` 0xAC/0xAD, `PchSetup` 0x517) store L1;
  the top-level selector is disabled. Stored policy bytes alone do not prove
  effective link state, which gating applies, or a causal inconsistency.
- NVIDIA's preservation/notifier settings are enabled; VRAM storage is
  `/var/tmp` on disk-backed Btrfs, with 57 GiB free at inspection.
- The user reported on September 20 that disabling ReBAR and XMP had fixed S3,
  before a BIOS reset preceded recurrence despite disabling them again.
  LTS had already failed and s2idle had already worked repeatedly.
- The June PEG ASPM change concerned black screens after **s2idle wake**;
  the June version of [the BIOS guide](bios-suspend-guide.html) did not document
  a successful S3 repair.
- The October 13 DP/RM deadlock account in the
  [older baseline](nvidia-hyprland-idle-suspend-baseline.md) lacked a captured
  stack. Moving VRAM storage to `/var/tmp` was not validated as the hang's fix.
- November 10 at 07:50 updated NVIDIA `615.78.08` to `620.70.06`, kernel `7.3.1`
  to `7.3.3`, and Hyprland `0.57.0` to `0.57.2` together. This cannot by itself
  explain the September onset.

## Controlled results, November 10–11

The first six tests preserved the normal systemd/logind locking path. Runtime
drop-ins restored diagnostic knobs after return. All five staged cycles reached
their checkpoint; `suspend_stats` ended at `success=5`, `fail=0`, one cycle per stage.

| Local date and time | Attempt | Observed result |
| --- | --- | --- |
| Nov 10, 23:59:27–23:59:36 | `freezer` | Returned after task freezing/checkpoint. |
| Nov 11, 00:00:56–00:01:06 | `devices` | Device suspend/checkpoint completed; returned. |
| Nov 11, 00:01:41–00:01:53 | `platform` | Late/noirq suspend, ACPI preparation and NVS save completed; returned. |
| Nov 11, 00:02:35–00:02:46 | `processors` | CPUs 31–1 offlined and restored; returned. |
| Nov 11, 00:03:10–00:03:20 | `core` | Syscore suspend/checkpoint completed; returned without entering S3. |
| Nov 11, 00:04:58 | Real S3, RTC wake at 00:05:29 | Hung; motherboard displayed `03`; next boot at 00:07:04. |
| Nov 11, 00:12:52–00:12:54 | Close desktop, unload NVIDIA, real S3; RTC wake at 00:13:25 | Hung; next boot at 00:16:13. |
| Nov 11, 00:28:29 | Real S3 after complete AC removal (G3), unchanged BIOS variables | Hung; next boot at 00:30:22. |
| Nov 11, 00:39:05 | Real S3 with POST-marker instrumentation, RTC wake at 00:39:35 | User confirmed `E4`; failed to return; next boot at 00:42:29. |
| Nov 11, 00:58:48–00:59:23 | Test 10: real S3 with low BAR, normal desktop/NVIDIA, no probe | S3 resume at 00:59:22; user confirmed fans stopped and screens returned. |
| Nov 11, 01:00:36–01:01:06 | Test 11: same configuration | S3 resume at 01:01:05; successful return. |
| Nov 11, 01:01:43–01:02:09 | Test 12: same configuration | S3 resume at 01:02:08; successful return. |

The 00:12 attempt verified `nvidia`, `nvidia_modeset`, `nvidia_drm`, and
`nvidia_uvm` absent, and `lspci` showed no driver bound to the RTX 4090. Thus
an executing NVIDIA suspend callback or running compositor is not necessary
for this reproduced hang. The GPU remained installed; prior hardware state
and other kernel drivers were not excluded.

`spd5118` resume `-6` (`ENXIO`) errors occurred in staged tests and persisted in
all three successful real cycles; they did not prevent entry/wake. The boot
reports SPD write protection. Display flip timeouts and NVIDIA/ath12k warnings
also did not establish the entry cause. The sensor-driver unload test was never run.

After the first two failed real cycles, diagnostic drop-ins were absent, `pm_test=none`,
`pm_trace`, `pm_print_times`, and `pm_debug_messages` were zero, and RTC alarm
was empty. At that stage no lasting driver, service, firmware, or boot setting
had been changed; the later manual BIOS changes are recorded below.

## What motherboard code 03 actually means here

- `_PTS` (line 8082) calls `RPTS(Arg0)` during sleep preparation.
- `RPTS` (line 30857) unconditionally calls `D8XH(0, Arg0)` and `D8XH(1, 0)`.
- `D8XH` (lines 30810–30829) writes the combined value to SystemIO port `0x80`.
  For S3, `Arg0=3`: **03 is a preparation marker**, not a decoded CPU/DIMM fault
  or proof that the machine reached powered-down S3.
- `_PTS` also calls `LPCB.LPTS` (line 7052), which sets `SLPE`; `LWAK` clears it.
  `SLPE` maps to bit 4 at `SMCR=0x1830`, the PCH `SMI_ON_SLP_EN` bit.
  The [Intel 600/700 PCH datasheet, volume 2, revision 005, p.133](https://cdrdv2-public.intel.com/680836/680836_005.pdf)
  specifies that this traps a sleep-enable write into SMM before actual sleep;
  firmware must clear the trap and reissue sleep-enable.

This identifies a concrete final firmware path skipped by `pm_test=core`.
It does **not** demonstrate that its SMM handler is faulty. Do not bypass this
handler with ad-hoc port writes or infer a failed component from code 03.

## Evidence limits and earlier exclusions

[Kernel PM debugging documentation](https://docs.kernel.org/power/basic-pm-debugging.html)
explains why passing staged tests leaves final platform entry untested. A pass
in another cycle also cannot exclude intermittent earlier failures. Journals
did not capture the final kernel callback: journald stops persisting when frozen
or when storage is suspended. Its last line is not a stack trace. Test 9 adds
a directly observed milestone in the failed cycle, described below, but does
not identify the stopping instruction. Pstore and its systemd archive were empty.

`nvidia-suspend.service` success is not proof of a completed GPU suspend: on
this notifier-based setup, `/proc/driver/nvidia/suspend` was absent and the
packaged hook exits immediately. The notifier path is documented in the
[NVIDIA 620.70.06 power-management README](https://download.nvidia.com/XFree86/Linux-x86_64/620.70.06/README/powermanagement.html).

Before test 8, recovery had used only power-button restarts/reboots. The user
then performed complete AC removal (G3) before boot
`3c11a23f74e34fb1a4e10c47377e9d54`. All five captured EFI variable buffers
(`Setup`, `CpuSetup`, `SaSetup`, `PchSetup`, `SioSetupData`) were byte-identical
to the pre-G3 copies. Real S3 at 00:28:29 still hung; recovery boot
`355d161b92364c3e8479cfd24301abfb` began at 00:30:22. This establishes that
the simple AC reset was insufficient; it does not exclude physical state or
state recreated during boot as a contributor.

The four failed real cycles included one without NVIDIA and one after G3.
They narrowed the investigation but did not independently prove a BIOS defect.
The later configuration change has its own successful real-cycle validation.

## Test 9: final write-helper entry observed

A temporary module, loaded with explicit user approval at 00:37:47 in boot
`355d161b92364c3e8479cfd24301abfb`, registered six function-entry kprobes that
emit POST markers without writing power-control registers. At 00:39:05 the
instrumented real S3 attempt started with RTC wake armed for 00:39:35. The user
confirmed observing **E4** on the display; recovery boot
`9119200e11764e39b46dff003d5ab575` began at 00:42:29.

In `post-probe/s3_post_probe.c`, E4 is emitted on entry to `acpi_os_write_port`
for port `0x1804`, a value containing `SLP_EN` (`0x2000`), and width 16.
The probe requires the same suspend task and the preceding E1/E2/E3 markers.
This failing cycle therefore reached the final write helper after preparation;
that conclusion no longer depends only on separate successful `pm_test` cycles.
It does **not** prove that the actual OUT instruction completed, that SMM was
entered or caused the hang, or that later code never ran: firmware can overwrite
the physical POST display. The user separately confirmed that the fans kept
running without interruption in this cycle, supporting an entry failure rather
than an observed power-down followed by a failed wake.

After reboot the probe module and diagnostic drop-in were absent, diagnostic
knobs had their default values, and the RTC alarm was empty. This test located
a milestone; the subsequent firmware analysis and configuration trials supplied
the mechanism and validated fix. The probe itself was not a fix.

## Mechanism strongly supported by the configuration trials

Two independent readings of the official F11 `GbtSleepSmi` PE32+ image
(FFS GUID `C93AAABC-4D41-4AE5-A5A2-0ABBFCAA4813`) found:

- The module registers RVA `0x1618` as an S3-entry callback through
  SxDispatch2 (context type 3, phase 0).
- It reads only the low DWORD of BAR0 for PCI `0000:00:15.2` at ECAM
  `0xC00AA010` into EDX (RVA `0x163D`), masking it to a 32-bit base.
- If PMCSR indicates D3hot, it accesses that truncated base at RVA
  `0x166E` and `0x1671`–`0x1677`. No upper-DWORD read or remap occurs first
  within this callback. A later helper handles the upper DWORD too late
  to protect these initial accesses.
- The actual controller is Intel `8086:7A4E`, driver `intel-lpss`, child
  `i2c_designware.2`. Its BAR0 before the fix was `0x4017002000`, with D3hot observed.
  With that state, the early firmware accesses would instead target
  `0x17002000`, which the boot memory map places in System RAM.
- The failed test's kernel log records initial BAR0 `0xFE0FB000`, rejection
  with `can't claim; no compatible bridge window`, then reassignment to
  `0x4017002000`. The above-4G address is therefore evidenced in the failed
  boot as well as the recovery boot.

The F11 IFR identifies **Above 4G Decoding** as Setup offset `0x114D` and
**ReBAR** as offset `0x114E`; initially captured values were **Enabled** and **Disabled**
respectively. Disabling ReBAR alone does not disable above-4G allocation.

This is a concrete code/state mismatch, not a captured SMM fault. Another
firmware callback could change the BAR or device power state first, and its
actual execution order is unknown. E4 alone cannot prove the bad access ran.
Source extraction, disassembly, and detailed bounds are preserved under
`.scratch/suspend-2026-11-10/firmware-f11/sleep-analysis/`.

The three successful cycles after lowering the BAR strongly support this
mechanism; changing a global resource-allocation option cannot by itself
identify one faulting instruction.

### Above 4G Decoding disabled: BAR still high, no S3 attempt

The user disabled Above 4G Decoding and returned in boot
`4a10f321074842d4b7a6c380867e3368` at 00:51:25. A privileged read-only EFI
capture at 00:53:06 confirms exactly one changed byte across all five saved
variables: Setup `0x114D`, from 1 to 0. ReBAR remains disabled. This proves the
requested change was saved; no other captured settings changed.

Nevertheless BAR0 remained `0x4017002000`, controller D3hot. The kernel still
rejected initial `0xFE0FB000` as outside the root bridge window and reallocated
it above 4 GiB. Root windows remained `0x40400000`–`0xBFFFFFFF` and
`0x4000000000`–`0x7FFFFFFFFF`. DSDT and MCFG are byte-identical to the earlier
captures; `_SB.PC00._CRS` uses SANV M32/M64 fields for its resource windows.
**No S3 was attempted in this configuration**, because the targeted address
condition did not change. The probe module and sleep drop-in were absent.

There is a distinct firmware option **Above 4GB MMIO BIOS assignment** at
`SaSetup[0x7E]`, which was still **Enabled** (1). The IFR exposes it as question
`0x7CA` in Chipset and `0x87B` in System Agent Configuration. Aperture Size
was 256 MiB, not the 2048 MiB value documented as automatically enabling it.
This motivated disabling the second option alone while preserving the already
disabled Above 4G Decoding and ReBAR, then checking saved settings, root windows,
and BAR0 before considering S3. The result of that configuration change follows;
no raw EFI/PCI writes were used.

Evidence: `.scratch/suspend-2026-11-10/after-above4g-disabled/capture.json`,
the corresponding EFI/ACPI copies, and `after-above4g-disabled-boot-kernel.log`.

### Above 4GB MMIO BIOS assignment disabled: allocation changed

The user disabled the second option and returned in boot
`1f1d458f81c945c28df7cafdb5220604` at 00:57:07. The capture at 00:58:29 confirms
Above 4G Decoding (`Setup[0x114D]`), ReBAR (`Setup[0x114E]`), and Above 4GB MMIO
BIOS assignment (`SaSetup[0x7E]`) all equal 0. Comparing all five saved EFI
variables with the immediately preceding boot shows exactly one changed byte:
`SaSetup[0x7E]`, from 1 to 0. The capture JSON also lists the earlier Above 4G
Decoding change because its comparison baseline predates both manual changes.

The boot journal no longer advertises the root memory window
`0x4000000000`–`0x7FFFFFFFFF`; the `0x40400000`–`0xBFFFFFFF` window remains.
Linux still rejects initial controller BAR0 `0xFE0FB000` as outside a compatible
window, but now assigns `0x40402000`–`0x40402FFF`, below 4 GiB. The live resource
matches, and controller power state is D3hot. Thus this second setting changed
the allocation condition implicated by the static firmware analysis.

Evidence: `.scratch/suspend-2026-11-10/after-mmio-disabled/capture.json`, its EFI
copies compared with `after-above4g-disabled/`, and the kernel journal for boot
`1f1d458f81c945c28df7cafdb5220604` at 00:57:07.

### Tests 10–12: three real S3 cycles passed

All three cycles ran in that same boot through the normal desktop suspend path,
with NVIDIA loaded and no diagnostic probe. Each log contains `suspend entry
(deep)`, `Low-level resume complete`, `Waking up from system sleep state S3`,
and `suspend exit`; systemd completed suspend successfully. The counter reached
`success=3`, `fail=0`. After the first cycle the user confirmed fans stopped and
screens returned; the GPU responded, all three monitors had DPMS active, and
no systemd service was failed.

Thirty-second RTC alarms were armed for 00:59:19, 01:01:07, and 01:02:14.
Resume timestamps for cycles 2 and 3 precede their alarms, so RTC is not a
proven wake source for those cycles. This does not change the recorded S3
entry/wake success. The existing `spd5118` resume errors persisted without
preventing these cycles.

After validation, the runtime diagnostic drop-in was removed and systemd
reloaded; `pm_test=none`, `pm_debug_messages=0`, `pm_print_times=0`, the RTC alarm
was empty, and the probe was absent. No automatic workaround or permanent
diagnostic service was installed. Evidence is in `test-mmio-disabled-state.json`
and `test-mmio-disabled-{1,2,3}-{all,kernel}.log` under the scratch directory.

## Recheck after a BIOS reset or firmware update

Preserve the validated combination, checking the two similarly named options
separately; a disabled ReBAR selector does not establish either MMIO setting:

| BIOS selector | Validated value | F11 EFI field |
| --- | --- | --- |
| Above 4GB MMIO BIOS assignment | Disabled | `SaSetup[0x7E]` |
| Above 4G Decoding | Disabled | `Setup[0x114D]` |
| Re-Size BAR Support | Disabled | `Setup[0x114E]` |

After boot, read the controller resource and selected sleep mode:

```sh
head -n 1 /sys/bus/pci/devices/0000:00:15.2/resource
cat /sys/power/mem_sleep
```

The first resource line gives start and end addresses; both should be below
`0x100000000` (4 GiB). The validated range was `0x40402000`–`0x40402FFF`;
the earlier problematic base was `0x4017002000`. Sleep mode should show
`s2idle [deep]`. Verify actual state rather than writing EFI variables or PCI
registers, forcing a driver workaround, or inferring success from `pm_test`.
If settings or allocation change, confirm real S3 entry and wake with work saved.

## Earlier alternatives, not needed for this validation

Read-only inspection found an existing Windows installation and boot entry.
An independent Windows S3 comparison was considered but not performed; it was
not required to validate the successful Linux configuration change.

Power Loading remained Auto during all three successful cycles. The older BIOS
guide's Enabled recommendation was not necessary for this observed fix.

## Local evidence inventory

Artifacts are under `.scratch/suspend-2026-11-10/` (ignored by Git). This
maintained note preserves conclusions; raw logs contain local identifiers.

- `investigation.md`, `failed-suspend.log`, `previous-kernel.log`, `pacman.log`.
- `test-{freezer,devices,platform,processors,core}-{kernel,services}.log`.
- `test-real-all.log`: first controlled real failure.
- `test-without-nvidia.log`, `test-without-nvidia-{all,kernel}.log`, and the
  corresponding `.sh`: unloaded-driver attempt.
- `test-after-ac-*.log`: third real failure, after the G3 power cycle.
- `test-post-probe-{all,kernel}.log`, `post-probe/s3_post_probe.c`: fourth real
  failure and the exact definition of the E4 milestone.
- `after-above4g-disabled/capture.json`, `after-mmio-disabled/capture.json`:
  saved BIOS changes and their comparison with the original EFI capture.
- `test-mmio-disabled-state.json`, `test-mmio-disabled-{1,2,3}-{all,kernel}.log`:
  three successful real cycles and diagnostic cleanup.
- `acpi-tables.tar`, `acpi/DSDT.dsl`, `acpi/SSDT1.dsl`, `acpi/SSDT14.dsl`:
  read-only firmware extraction; line references above use this DSDT output.
- `efi-settings/`: read-only setup-variable copies for comparison with the
  [official F11 image](https://download.gigabyte.com/FileList/BIOS/mb_bios_z790-aorus-master-x_8arpt702_f11.zip).
- `firmware-f11/live-settings.json`: mapping captured at 00:21:00 on November 11,
  with variable GUIDs, offsets, values, image hash, and IFR line references.
  Its `ifr_path` identifies the complete extracted setup definitions.
