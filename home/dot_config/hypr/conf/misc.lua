-- See https://wiki.hypr.land/Configuring/Basics/Variables/ for more
hl.config({
    misc = {
        disable_hyprland_logo    = true,
        disable_splash_rendering = true,
        -- Let a fresh locker take over an orphaned session lock after a crash.
        allow_session_lock_restore = true,
        mouse_move_enables_dpms = true,
        key_press_enables_dpms  = true,
    },
    render = {
        -- HDR is toggled by hand (toggle-hdr.sh). The automatic switch on
        -- fullscreen HDR/wide-gamut content modesets an 8-bit panel into a black
        -- screen and a "not in 10-bit mode" warning.
        cm_auto_hdr = 0,
    },
})
