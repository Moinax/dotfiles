-- See https://wiki.hypr.land/Configuring/Basics/Variables/ for more

-- Blur variant picked from vicinae (Mod+Alt+W, scripts/blur-variant.sh), which
-- validates the name before writing it; kawase is Hyprland's plain blur.
local home = assert(os.getenv("HOME"), "HOME not set")
local state_home = os.getenv("XDG_STATE_HOME") or (home .. "/.local/state")
local blur_variant = "kawase"

local state = io.open(state_home .. "/hypr/blur-variant", "r")
if state then
    blur_variant = state:read("l") or blur_variant
    state:close()
end

hl.config({
    decoration = {
        rounding         = 10,
        active_opacity   = 0.92,
        inactive_opacity = 0.85,
        blur = {
            enabled = true,
            size    = 3,
            passes  = 3,
            variant = blur_variant,
        },
        shadow = {
            enabled      = true,
            range        = 4,
            render_power = 3,
            color        = "rgba(1a1a1aee)",
        },
    },
})
