-- See https://wiki.hypr.land/Configuring/Basics/Variables/ for more
hl.config({
    decoration = {
        rounding         = 10,
        active_opacity   = 0.99,
        inactive_opacity = 0.90,
        blur = {
            enabled = true,
            size    = 3,
            passes  = 3,
        },
        shadow = {
            enabled      = true,
            range        = 4,
            render_power = 3,
            color        = "rgba(1a1a1aee)",
        },
    },
})
