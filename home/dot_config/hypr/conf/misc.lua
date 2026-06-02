-- See https://wiki.hypr.land/Configuring/Basics/Variables/ for more
hl.config({
    misc = {
        disable_hyprland_logo    = true,
        disable_splash_rendering = true,
        -- Let a fresh hyprlock take over an orphaned session lock after the
        -- locker crashes (default off rejects it with "got yeeten"). Without
        -- this, a hyprlock crash wedges the session in a locked-but-no-locker
        -- state recoverable only by restarting Hyprland. See the NVIDIA DPMS
        -- crash this guards against (hypridle-dpms-guard.sh / project memory).
        allow_session_lock_restore = true,
    },
})
