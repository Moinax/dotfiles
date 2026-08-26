-- Keep every layout in one XKB keymap, with AZERTY first. With
-- resolve_binds_by_sym disabled, Hyprland always resolves symbol binds through
-- that first layout, so shortcuts stay on their physical AZERTY positions while
-- applications can use any active group.
local home = assert(os.getenv("HOME"), "HOME not set")
local state_home = os.getenv("XDG_STATE_HOME") or (home .. "/.local/state")
local default_layout = "2_french.lua"
local layout = default_layout

local state = io.open(state_home .. "/hypr/keyboard-layout", "r")
if state then
    local saved = state:read("l")
    state:close()
    if saved and saved:match("^%d+_[%w_-]+%.lua$") then
        layout = saved
    end
end

local layouts_dir = home .. "/.config/hypr/conf/input-layouts/"
local selected = io.open(layouts_dir .. layout, "r")
if selected then
    selected:close()
else
    layout = default_layout
end

local selected_layout_index = dofile(layouts_dir .. layout)
assert(
    selected_layout_index == 0 or selected_layout_index == 1 or selected_layout_index == 2,
    "invalid keyboard layout index: " .. layout
)

hl.config({
    input = {
        kb_layout  = "fr,us,be",
        kb_variant = ",,",
        kb_model   = "",
        kb_options = "",
        kb_rules   = "",

        resolve_binds_by_sym = false,
        follow_mouse         = 1,
        mouse_refocus        = false,

        touchpad = {
            natural_scroll       = true,
            tap_to_click         = true,
            tap_and_drag         = true,
            clickfinger_behavior = true,
        },

        sensitivity = 0,
    },
})

-- A normal reload preserves the active group, but startup begins on group 0.
-- hyprland.start runs after the control socket and keyboards exist; the reload
-- hook also restores persistence after a full config reset. Keep hyprctl async
-- to avoid calling back into Hyprland from inside its own event handler.
local function restore_layout()
    hl.exec_cmd("hyprctl switchxkblayout all " .. selected_layout_index)
end
hl.on("hyprland.start", restore_layout)
hl.on("config.reloaded", restore_layout)
