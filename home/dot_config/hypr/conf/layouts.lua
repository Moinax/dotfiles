-- See https://wiki.hypr.land/Configuring/Layouts/ for more
hl.config({
    dwindle = {
        preserve_split = true,
        smart_resizing = true,
    },
    scrolling = {
        direction                = "right",
        column_width             = 0.5,
        explicit_column_widths   = "0.333, 0.5, 0.667, 1.0",
        focus_fit_method         = 1,
        follow_focus             = true,
        wrap_focus               = true,
        wrap_swapcol             = true,
        fullscreen_on_one_column = true,
    },
    -- master = {
    --     new_status = "master",
    -- },
})
