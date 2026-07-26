-- For all categories, see https://wiki.hypr.land/Configuring/Basics/Variables/
hl.config({
    input = {
        kb_layout  = "fr",
        kb_variant = "",
        kb_model   = "",
        kb_options = "",
        kb_rules   = "",

        follow_mouse  = 1,
        mouse_refocus = false,

        touchpad = {
            natural_scroll = true,

            -- Tap to click, and let the finger count pick the button (2 = right,
            -- 3 = middle) for taps and for physical clicks alike.
            tap_to_click         = true,
            tap_and_drag         = true,
            clickfinger_behavior = true,
        },

        sensitivity = 0,
    },
})
