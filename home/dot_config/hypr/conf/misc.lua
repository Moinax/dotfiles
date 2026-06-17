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
})
