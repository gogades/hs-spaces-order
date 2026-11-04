-- spaces_order/config.lua
-- ─────────────────────────────────────────────────────────────────
-- EDIT THIS FILE to control which apps get full-screened and in
-- what order they appear in Mission Control (left → right).
-- ─────────────────────────────────────────────────────────────────

return {
    -- Entries in the DESIRED left-to-right Mission Control order.
    --
    -- Each entry is either:
    --   • a string: an app name (as app:name() reports it) OR a bundle ID
    --   • a table:
    --       name  = label shown in the progress dialog / logs
    --       app   = app name or bundle ID, or a list of them
    --       title = optional Lua pattern the window title must contain
    --       match = optional list of alternative { app=…, title=… } rules
    --
    -- A rule with a `title` beats a plain rule, so the "Google Chat"
    -- entry wins over "Google Chrome" for Chat windows even though
    -- Chrome is listed first.
    --
    -- With debug = true, every full-screen window's app name, bundle ID
    -- and title is logged to the console, which helps when tuning these.
    apps = {
        "Google Chrome",
        "Home Assistant",
        "Messages",
        "Messenger",
        {
            name  = "Google Chat",
            -- Chrome web apps: the window may belong to the web-app shim
            -- process or to Google Chrome itself, depending on version.
            match = {
                { app = "Google Chat" },
                { app = "Google Chrome", title = "Google Chat" },
            },
        },
        "Claude",
        { name = "VS Code", app = { "Code", "Visual Studio Code", "com.microsoft.VSCode" } },
        "iTerm2",
    },

    -- Automatically full-screen a configured app's main window when it
    -- has no full-screen window yet (on launch / startup check).
    auto_fullscreen = true,

    -- Seconds to wait after an app finishes launching before
    -- attempting to full-screen it.
    launch_delay = 1.8,

    -- Seconds to let macOS full-screen / exit-full-screen animations
    -- settle before issuing the next command.
    animation_delay = 0.9,

    -- Hotkey to manually force a full reorder at any time.
    -- Default: Ctrl+Option+O
    hotkey_mods = { "ctrl", "option" },
    hotkey_key  = "o",

    -- Set to true to print debug messages to the Hammerspoon console.
    debug = true,
}
