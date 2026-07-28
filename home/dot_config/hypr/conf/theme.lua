-- Anything in the Hyprland config that has to follow the dark/light mode.
--
-- Loaded two ways, which is why it is a plain data module that returns a table
-- and calls no `hl.*`:
--   * `require`d by conf/general.lua, so a fresh Hyprland parse picks the mode up
--   * `dofile`d by apply-dark-mode.sh through one `hyprctl eval`, so Mod+N
--     repaints the tabs without a whole-config reload. That matters: a reload
--     re-applies the config over the live session, reverting every runtime
--     toggle set through `hyprctl eval` — toggle-monitors, toggle-hdr,
--     toggle-all-opacity and toggle-workspace-scrolling all live only in memory.
--     dofile also sidesteps `require`'s cache, which would hand back the palette
--     from before the flip.
-- (`hyprctl keyword` is not an option either way: Hyprland 0.55+ rejects it on
-- Lua configs, "non-legacy parsers".)
--
-- Hyprland cannot see the xdg portal colour-scheme that waybar keys off, so the
-- mode comes from the state file apply-dark-mode.sh writes.
local function current_mode()
    local f = io.open(os.getenv("HOME") .. "/.local/share/dark-light-mode")
    if not f then return "dark" end
    local mode = f:read("l")
    f:close()
    return mode == "light" and "light" or "dark"
end

-- Group tab colours, solved rather than sampled: these render a tab
-- *pixel-identical* to a waybar workspace pill over the same wallpaper. A pill
-- is `a` of colour C over `window#waybar` (85% of Cb) over the wallpaper W; a
-- tab has no bar under it, only W. Equating the two composites term by term,
--     1 - a' = (1 - a) * (1 - 0.85)      and      a' * C' = a*C + 0.85*(1-a)*Cb
-- so the tab admits the same fraction of wallpaper the pill does and adds the
-- same colour on top. That is also why an exactly-matching tab still lands near
-- 0xe0 opacity off a pill of only 22%/35%: the bar it stands in for is itself
-- 85% opaque. Re-solve (do not eyeball) if the waybar alphas move.
local groupbar = {
    -- a = 0.35 / 0.22 of rgb(255,100,255) / rgb(100,100,255) over rgba(30,30,46,0.85)
    dark = {
        active   = "rgba(75397fe6)",
        inactive = "rgba(2f2f62e1)",
        -- Matches `#workspaces button.active { color: white }` and the `*` rule.
        text     = "rgba(ffffffff)",
        text_dim = "rgba(cdd6f4ff)",
    },
    -- a = 0.45 / 0.22 over rgba(239,241,245,0.85). C for the active state is
    -- rgb(170,40,170) here, not dark's rgb(255,100,255) — see style-light.css
    -- for why that tint had to change rather than just its alpha.
    light = {
        active   = "rgba(cd8ed0ea)",
        inactive = "rgba(cccef7e1)",
        -- Latte: #1e1e2e is style-light.css's active-pill text, #4c4f69 its `*`.
        text     = "rgba(1e1e2eff)",
        text_dim = "rgba(4c4f69ff)",
    },
}

local mode = current_mode()
return { mode = mode, groupbar = groupbar[mode] }
