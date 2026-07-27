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
        -- Tabs deliberately mirror waybar's #workspaces buttons (style-dark.css)
        -- so a group tab and a workspace pill read as the same control: 26px
        -- tall, 8px radius, 17px text, 4px between chips, and the same
        -- magenta-active / indigo-inactive pair. The 26px is measured off screen,
        -- not read off the CSS — there a pill's height is implied by font size
        -- plus 2px padding, so it has to be sampled to be matched.
        -- The colours are NOT waybar's literal CSS values. A waybar button is
        -- only 30%/50% opaque, and what makes it readable is everything stacked
        -- under it: `#workspaces` also matches `.module` (another 30% indigo),
        -- over `window#waybar` at rgba(30,30,46,0.85). A groupbar has none of
        -- that, only the wallpaper. So these are waybar's *rendered* pill colours
        -- sampled off screen (#A553B9 active, #504A9A inactive) applied at ~94%
        -- alpha, which is the effective opacity of that stack. Re-sample with
        -- grim rather than recomputing if the waybar palette changes — a
        -- two-layer model undershoots because it misses the module background.
        -- Copying 0x4d/0x80 straight across instead makes inactive titles
        -- unreadable over a busy wallpaper and hides the corner rounding
        -- against a light one.
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
            ["col.active"]    = "rgba(a553b9f2)",
            ["col.inactive"]  = "rgba(504a9aed)",
            font_size            = 17,
            font_weight_active   = 400,
            font_weight_inactive = 400,
            text_color           = "rgba(ffffffff)",
            text_color_inactive  = "rgba(cdd6f4ff)",
            text_padding         = 8,
            text_offset          = 0,
        },
    },
})
