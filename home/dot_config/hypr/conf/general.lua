-- See https://wiki.hypr.land/Configuring/Basics/Variables/ for more
hl.config({
    general = {
        gaps_in     = 4,
        gaps_out    = 8,
        border_size = 4,
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
        -- all until the two overlap — and once col.* alpha is this high it is
        -- still a no-op: measured max 12/255 per-pixel difference on/off, so it
        -- stays off rather than costing a blur pass per tab for nothing.
        -- Reserved height = gaps_out * (2 + keep_upper_gap)
        --                 + indicator_height + indicator_gap + height
        --                 = 3 * 2 + 24 - 24 + 24 = 30px here.
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
        -- at all, which is worse than the strip is good. gaps_in stays at 1
        -- rather than 0: nothing separates two adjacent inactive tabs otherwise,
        -- and a 3-pane group then shows one wide block with two titles in it.
        groupbar = {
            height            = 24,
            indicator_height  = 24,
            indicator_gap     = -24,
            gaps_in           = 1,
            gaps_out          = 3,
            keep_upper_gap    = false,
            rounding          = 6,
            round_only_edges  = false,
            gradients         = false,
            blur              = false,
            -- Alpha carries the corner, not just the tint: at 0x80 over a light
            -- wallpaper the antialiased rounding blends into the background at
            -- nearly equal luminance and the corner reads square, while the
            -- darker col.inactive shows the same curve clearly. Verified by
            -- forcing col.active to col.inactive — the geometry is identical.
            ["col.active"]    = "rgba(ff64ffcc)",
            ["col.inactive"]  = "rgba(28284bb3)",
            font_size            = 15,
            font_weight_active   = 500,
            font_weight_inactive = 400,
            text_color           = "rgba(ffffffff)",
            text_color_inactive  = "rgba(c8c8e6c0)",
            text_padding         = 8,
            text_offset          = 0,
        },
    },
})
