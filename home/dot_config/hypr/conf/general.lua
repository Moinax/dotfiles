-- See https://wiki.hypr.land/Configuring/Basics/Variables/ for more

local tab = require("conf.theme").groupbar

hl.config({
    general = {
        gaps_in     = 4,
        gaps_out    = 8,
        border_size = 4,
        -- Borders deliberately stay on the dark palette in both modes: the
        -- pink/lavender gradient reads well against either kitty theme, and
        -- swapping accents on Mod+N is a visual jolt for no gain. Being
        -- mode-independent, they are set here only — nothing re-applies them
        -- at runtime.
        ["col.active_border"]   = { colors = { "rgba(ff64ff80)", "rgba(9696ffff)" }, angle = 45 },
        ["col.inactive_border"] = "rgba(6464ff4d)",
        layout            = "dwindle",
        resize_on_border  = true,
    },
    group = {
        auto_group              = true,
        ["col.border_active"]   = { colors = { "rgba(ff64ff80)", "rgba(9696ffff)" }, angle = 45 },
        ["col.border_inactive"] = "rgba(6464ff4d)",
        -- Tabs. Hyprland draws a groupbar as two stacked strips per tab: an
        -- `indicator` rect (solid, `col.*`) directly above the window, and a
        -- `height`-tall title band above that, separated by `indicator_gap`.
        -- Only the title band can hold text, and only the indicator can be a
        -- solid fill — the title band has no background of its own, so with the
        -- stock thin indicator the text composites straight onto the wallpaper
        -- and inactive titles are unreadable over anything busy. Overlapping
        -- the two exactly is what puts a backdrop behind the text:
        -- indicator_height == height and indicator_gap == -height. Any other
        -- combination leaves the title off-centre in the fill. `blur` hangs off
        -- that same indicator rect (never the title band), so it does nothing at
        -- all until the two overlap. Left off regardless: a blur pass per tab,
        -- across every tab of every group on ~15 workspaces, to soften a
        -- backdrop the tab already covers ~88% of.
        -- Reserved height = gaps_out * (2 + keep_upper_gap)
        --                 + indicator_height + indicator_gap + height
        --                 = 3 * 2 + 26 - 26 + 26 = 32px here.
        -- The negative indicator_gap is below the option's registered min of 0.
        -- That bound is advisory today, but a release that starts clamping it
        -- would silently flatten the fill back to an underline and take the
        -- text legibility with it, without any config error to point at.
        -- The other fill is `gradients = true`, the only way to get a gradient
        -- tab, but it costs ~155 MiB of GPU memory for good: Hyprland renders
        -- four full-monitor-sized gradient textures (active, inactive, locked
        -- x2) at reload and scales them into the strip. Measured on eDP-1
        -- (3840x2400) via /proc/$(pidof Hyprland)/fdinfo.
        -- `round_only_edges` is off so every tab is a rounded chip. With it on,
        -- the tabs read as one strip, but Hyprland zeroes `rounding` on each tab
        -- and re-adds it only for the group's first and last — and even those
        -- keep just their outer end (the rect is drawn `rounding * 2` wider and
        -- clipped back). The focused tab of a 3-pane group then has no rounding
        -- at all, which is worse than the strip is good. gaps_in must stay above
        -- 0 regardless: nothing separates two adjacent inactive tabs otherwise,
        -- and a 3-pane group then shows one wide block with two titles in it.
        -- Tabs deliberately mirror waybar's #workspaces buttons (style-dark.css
        -- and style-light.css) so a group tab and a workspace pill read as the
        -- same control: 26px tall, 8px radius, 4px between chips, and the
        -- magenta-active / indigo-inactive pair.
        -- The 26px is now stated on both sides rather than sampled: the pill was
        -- letting its font imply its height, which is why this used to have to be
        -- measured off screen, and it drifted the moment the CSS font moved. It
        -- carries an explicit `min-height: 26px` there now, so the two agree by
        -- construction and this number is the one place it is chosen.
        -- The text follows the bar down to 16px. Nothing here forces it — a tab
        -- has no 26px ceiling, and 17px still fits — but the pill had to drop to
        -- 16 to reach 26 (its content box alone is 28px at 17), and two controls
        -- that are meant to read as one cannot differ on the only thing you
        -- actually read. So the CSS is what chose this number, not this file.
        -- Colours are solved in conf/theme.lua, not copied from the CSS:
        -- copying the alphas across drops the 85% bar the pill stands on, which
        -- left inactive titles unreadable over a busy wallpaper and hid the
        -- rounding against a light one.
        groupbar = {
            height            = 26,
            indicator_height  = 26,
            indicator_gap     = -26,
            gaps_in           = 4,
            gaps_out          = 3,
            keep_upper_gap    = false,
            rounding          = 8,
            round_only_edges  = false,
            gradients         = false,
            blur              = false,
            ["col.active"]    = tab.active,
            ["col.inactive"]  = tab.inactive,
            font_size            = 16,
            font_weight_active   = 400,
            font_weight_inactive = 400,
            text_color           = tab.text,
            text_color_inactive  = tab.text_dim,
            text_padding         = 8,
            text_offset          = 0,
        },
    },
})
