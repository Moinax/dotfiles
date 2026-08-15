-- See https://wiki.hypr.land/Configuring/Basics/Window-Rules/ for more

-- Calculator
hl.window_rule({
    match  = { class = "^(org\\.kde\\.kcalc)$" },
    float  = true,
    size   = { 400, 600 },
    center = true,
})

-- btop in kitty (the waybar performance module's on-click): float at 1280x720.
--
-- `center` is not redundant. A native-Wayland floating window has no position of
-- its own, so Hyprland centers it and the rule never needed to say so. kitty runs
-- on XWayland on the desktop (see kitty/display-server.conf.tmpl), and an X11
-- client maps with a requested geometry that Hyprland honours — which put the
-- popup at the monitor's top-left corner instead.
hl.window_rule({
    match  = { class = "^(kitty)$", title = "^(btop)$" },
    float  = true,
    size   = { 1280, 720 },
    center = true,
})

-- Bitwarden: width-constrained Electron window tiles awkwardly; float it centered
hl.window_rule({
    match  = { class = "^(Bitwarden)$" },
    float  = true,
    size   = { 1000, 700 },
    center = true,
})

-- Bitwarden browser-extension popout (chrome-<extension id>-<profile>): float it centered.
-- Content is a portrait-shaped centered card; size the window to fit it (avoids empty margins).
hl.window_rule({
    match  = { class = "^(chrome-nngceckbapebfimnlniiiahkandclblb-.*)$" },
    float  = true,
    size   = { 480, 800 },
    center = true,
})

-- Opacity toggles driven by binds (see binds.lua)
hl.window_rule({ match = { tag = "switch_opacity" },      opacity = "1 override" })
hl.window_rule({ match = { tag = "switch_opacity_half" }, opacity = "0.5 override" })

-- ── Layer rules ───────────────────────────────────────────────────
-- vicinae draws itself as a layer surface, not a window, so window_rule never
-- matches it — these are the layer equivalents.
--
-- Blur makes a translucent launcher background read as glass instead of as a
-- grey wash; ignore_alpha = 0 tells it to cover the whole surface rather than
-- only the fully opaque pixels.
--
-- It only does anything for a theme whose background carries an alpha byte.
-- The Catppuccin themes currently in use do not — they set a flat #1E1E2E /
-- #EFF1F5 — so this rule is inert as things stand. It is kept because it costs
-- nothing and becomes correct again the moment a translucent theme is picked;
-- vicinae's own default palette is one.
hl.layer_rule({
    match       = { namespace = "vicinae" },
    name        = "vicinae-blur",
    blur        = true,
    ignore_alpha = 0,
})

-- No open/close animation. A launcher is summoned and dismissed dozens of
-- times an hour and the animation is pure latency at that rate — rofi had none
-- either, so this is what keeps the two comparable on feel.
hl.layer_rule({
    match  = { namespace = "vicinae" },
    name   = "vicinae-no-animation",
    no_anim = true,
})
