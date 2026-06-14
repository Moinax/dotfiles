-- See https://wiki.hypr.land/Configuring/Basics/Window-Rules/ for more

-- Calculator
hl.window_rule({
    match  = { class = "^(org\\.kde\\.kcalc)$" },
    float  = true,
    size   = { 400, 600 },
    center = true,
})

-- btop in kitty: float at 1280x720
hl.window_rule({
    match = { class = "^(kitty)$", title = "^(btop)$" },
    float = true,
    size  = { 1280, 720 },
})

-- Opacity toggles driven by binds (see binds.lua)
hl.window_rule({ match = { tag = "switch_opacity" },      opacity = "1 override" })
hl.window_rule({ match = { tag = "switch_opacity_half" }, opacity = "0.5 override" })
