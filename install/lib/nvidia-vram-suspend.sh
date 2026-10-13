#!/bin/bash
# Where the NVIDIA driver parks video memory across a suspend. One modprobe
# option, written where the early-KMS load can see it.
#
# The driver saves every live VRAM allocation to a file on the way into S3 and
# restores it on the way out — that is what `NVreg_PreserveVideoMemoryAllocations=1`
# buys, and it is the baseline this machine wants (debug/nvidia-hyprland-idle-suspend-baseline.md).
# `NVreg_TemporaryFilePath` says where. Left unset it is `/tmp`, which is a tmpfs
# here: the copy never leaves RAM, so the save competes for the memory it is meant
# to be freeing. The NVIDIA driver documentation (powermanagement.html, shipped at
# /usr/share/doc/nvidia/html/) prescribes a path sized for the GPUs' total video
# memory plus 5% of margin — 24 GiB for the 4090 in this box — which a tmpfs of
# half the RAM only appears to satisfy. This is the documented standard, not a
# local workaround: it is what the upstream README the Hyprland wiki defers to
# asks for.
#
# It also pins the preserve flag itself, which until now held only by accident:
# nothing in nvidia-utils sets it. The only file that did was
# /usr/lib/modprobe.d/gsr-nvidia.conf, from gpu-screen-recorder — so uninstalling
# a screen recorder would have silently taken VRAM preservation with it, and the
# baseline note claimed /var/tmp was a package default when no package sets either
# option.
#
# The one privileged step is writing that file and rebuilding the initramfs, so it
# lives here, shared by `dots setup` (which runs it once) and `dots update` (which
# offers it to a machine that is missing it). It cannot live in a chezmoi apply —
# that would put a sudo prompt in every one.
#
# Requires common.sh (print helpers, track_warning) to be sourced.

# Not in /usr/lib/modprobe.d: pacman owns that tree and would overwrite or orphan
# the file. /etc wins for same-named files and accumulates for differently-named
# ones, so this one adds to the vendor set rather than replacing any of it.
NVIDIA_VRAM_SUSPEND_CONF=/etc/modprobe.d/nvidia-vram-suspend.conf

# Deliberately not /tmp (a tmpfs, see the header) and not /run (also one). /var/tmp
# is on the root filesystem here, which is what "persistent" means for the
# duration of a power-management cycle, and it is the value the baseline note has
# always expected to find.
NVIDIA_VRAM_SUSPEND_PATH=/var/tmp

# The file body lives in a function so the writer and the drift check below read
# the same bytes — zram-tuning.sh and dns-encrypted.sh do this for the same
# reason: a detection that can disagree with the write is a step that reports
# success while changing nothing.
nvidia_vram_suspend_body() {
    cat <<EOF
# Written by install/lib/nvidia-vram-suspend.sh — edits here are replaced on the
# next \`dots setup\` or \`dots update\`, which is also where the reasoning lives.
#
# Preserve video memory across suspend, and save it somewhere that is not a
# tmpfs. Unset, NVreg_TemporaryFilePath is /tmp, which is RAM on this machine:
# the copy competes for the memory it exists to free. The preserve flag is
# repeated here on purpose — the only other file setting it belongs to
# gpu-screen-recorder, so the baseline would leave with that package.
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=$NVIDIA_VRAM_SUSPEND_PATH
EOF
}

# Whether there is an NVIDIA driver here to configure at all. Gated on the loaded
# driver and never on the hostname, which is the repo's NVIDIA policy: a machine
# with no NVIDIA module reads no nvidia modprobe option, so it is skipped rather
# than warned about.
nvidia_vram_suspend_supported() {
    [ -e /proc/driver/nvidia ]
}

# True when the option file is missing or has drifted from what we would write.
# Content comparison and not mere existence, so changing the path above reaches a
# machine that already carries the previous value.
#
# Deliberately not driven off /proc/driver/nvidia/params: the live value only
# changes at the next boot, so reading it would make every `dots update` between
# the write and that boot offer the same step again.
nvidia_vram_suspend_needs_setup() {
    nvidia_vram_suspend_supported || return 1
    ! cmp -s <(nvidia_vram_suspend_body) "$NVIDIA_VRAM_SUSPEND_CONF"
}

# The privileged step, headerless so both callers can frame it their own way.
# Idempotent: one file write, one initramfs rebuild.
apply_nvidia_vram_suspend() {
    if ! nvidia_vram_suspend_supported; then
        print_info "No NVIDIA driver loaded here — leaving the suspend VRAM path alone"
        return 0
    fi

    # `install -D` and not `tee`: content, mode and any missing parent directory
    # in one privileged call.
    nvidia_vram_suspend_body | sudo install -D -m 644 /dev/stdin "$NVIDIA_VRAM_SUSPEND_CONF" || {
        track_warning "Could not write $NVIDIA_VRAM_SUSPEND_CONF — suspend keeps saving VRAM to tmpfs"
        return 1
    }

    # The write alone is inert, and that is the trap worth paying for here:
    # nvidia.ko is loaded from the initramfs on this machine (early KMS, the
    # `kms` hook pulls the extramodules), and the `modconf` hook bakes a *copy*
    # of /etc/modprobe.d into the image. The running system's copy is never read
    # at load time, so a machine that only wrote the file would boot with the old
    # option set and report success — the same silent half-apply the repo's
    # installer-only steps are warned about.
    #
    # `limine-mkinitcpio` and not `mkinitcpio -P`, and emphatically not
    # `kernel-install add-all`: limine-mkinitcpio-hook ships
    # /etc/pacman.d/hooks/90-mkinitcpio-install.hook, which *overrides* the stock
    # mkinitcpio one, so the images this machine boots live in
    # /boot/<machine-id>/<pkgbase>/{vmlinuz,initramfs} and /etc/mkinitcpio.d holds
    # no presets for `-P` to walk. `kernel-install add-all` was tried here and
    # reverted: it builds a correct image into its own *kernel-version*-keyed
    # layout (/boot/<machine-id>/<kver>/{linux,initrd} plus loader entries),
    # leaving what limine actually boots untouched — a rebuild that looks
    # successful, costs 240 MB of ESP and changes nothing. Bare `mkinitcpio -P` is
    # the fallback for an Arch derivative without the limine hook, where presets
    # do exist.
    local rebuild=(mkinitcpio -P)
    command_exists limine-mkinitcpio && rebuild=(limine-mkinitcpio)
    if sudo "${rebuild[@]}"; then
        local live
        live=$(sed -n 's/^TemporaryFilePath: "\(.*\)"$/\1/p' /proc/driver/nvidia/params 2>/dev/null)
        if [ "${live:-}" = "$NVIDIA_VRAM_SUSPEND_PATH" ]; then
            print_success "Suspend saves video memory to $NVIDIA_VRAM_SUSPEND_PATH"
        else
            # Not a warning: the file is in place and the next boot reads it.
            # Worth saying out loud, because the alternative is believing a
            # suspend hang is fixed on a machine still running the old value.
            print_info "Wrote the option; the driver still saves to ${live:-/tmp} and lands at the next boot"
        fi
    else
        track_warning "${rebuild[0]} would not rebuild — $NVIDIA_VRAM_SUSPEND_CONF is written but not in the initramfs"
    fi
    return 0
}
