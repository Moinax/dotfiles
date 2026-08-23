-- Load the persisted keyboard choice without making the state file part of
-- Hyprland's watched configuration tree. Mod+K updates that state and applies
-- the matching template at runtime through `hyprctl eval`, so switching layout
-- never requires a full config reload.
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
dofile(layouts_dir .. layout)
