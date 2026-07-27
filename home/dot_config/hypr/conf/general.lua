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
        -- solid fill, so a filled tab means overlapping the two exactly:
        -- indicator_height == height and indicator_gap == -height. Any other
        -- combination leaves the title off-centre in the fill.
        -- Reserved height = gaps_out * (2 + keep_upper_gap)
        --                 + indicator_height + indicator_gap + height
        --                 = 3 * 2 + 24 - 24 + 24 = 30px here.
        -- The alternative fill is `gradients = true`, which is the only way to
        -- get a gradient tab, but it costs ~155 MiB of GPU memory for good:
        -- Hyprland renders four full-monitor-sized gradient textures (active,
        -- inactive, locked ×2) at reload and scales them into the 24px strip.
        -- Measured on eDP-1 (3840x2400) via /proc/$(pidof Hyprland)/fdinfo.
        -- `round_only_edges` rounds the two ends of the bar and leaves the inner
        -- corners square, so the tabs read as one strip. gaps_in stays at 1
        -- rather than 0: nothing separates two adjacent inactive tabs otherwise,
        -- and a 3-pane group then shows one wide block with two titles in it.
        groupbar = {
            height            = 24,
            indicator_height  = 24,
            indicator_gap     = -24,
            gaps_in           = 1,
            gaps_out          = 3,
            keep_upper_gap    = false,
            rounding          = 10,
            round_only_edges  = true,
            gradients         = false,
            blur              = true,
            ["col.active"]    = "rgba(ff64ff80)",
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
