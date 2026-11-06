-- ── Hotkey help (⌃⌥/) ─────────────────────────────────────────────
-- Must be required first: it records every hotkey bound after it.
-- The comment directly above each hs.hotkey.bind() call becomes that
-- hotkey's description in the dialog.
local hotkeyHelp = require("hotkey_help")

-- ── App launch / cycle ────────────────────────────────────────────
-- appCycle.launchOrCycle(bundleID or name): launch or focus the app; if it is
-- already in front, go to its next window (e.g. next full-screen
-- Chrome or VS Code window).
local appCycle = require("app_cycle")

-- ── Spaces Order module ───────────────────────────────────────────
-- Keeps configured apps full-screened in a predictable Mission Control
-- order.  Edit ~/.hammerspoon/spaces_order/config.lua to customise.
local spacesOrder = require("spaces_order")

-- ─────────────────────────────────────────────────────────────────

local function has_value (tab, val)
  for index, value in ipairs(tab) do
      if value == val then
          return index
      end
  end

  return nil
end

local function no_full_screen()
  local allApps = hs.application.runningApplications()
  hs.console.clearConsole()
  for i, app in ipairs(allApps) do
    local main = app:mainWindow()
    -- hs.console.printStyledtext(app:name())
    if main and main:isFullScreen() then
        main:setFullScreen(false)
    end
  end
end

local function go_full_screen()
  hs.console.clearConsole()

  local space = hs.spaces.focusedSpace()
  local focusedWindow = hs.window.focusedWindow()

  local myapps = {"Messenger","Discord","iTerm2","Google Chrome", "Messages", "Home Assistant"}

  local allApps = hs.application.runningApplications()
  for i, app in ipairs(allApps) do
    for i,nm in ipairs(myapps) do
    if app:name() == nm then
      -- hs.console.printStyledtext(app:name())
      local main = app:mainWindow()
      if main and not main:isFullScreen() then
          main:setFullScreen(true)
          hs.spaces.gotoSpace(space)
        end
      end
    end
  end
  hs.spaces.gotoSpace(space)
  focusedWindow:focus()
end

local function focus_app(appname)
  local allApps = hs.application.runningApplications()
  for i, app in ipairs(allApps) do
    if app and app:name() == appname then
      local m = app:mainWindow()
      if m then m:focus() end
    end
  end
end


-- -- Take all apps out of full screen
-- hs.hotkey.bind({"option", "ctrl"}, "f", function()
--   no_full_screen()
-- end)

-- Full-screen my main apps
hs.hotkey.bind({"option", "ctrl"}, "q", function()
  go_full_screen()
end)

-- Toggle full screen: exit on the 40" screen, enter otherwise
hs.hotkey.bind({"option", "ctrl"}, "r", function()
  local uuid = hs.screen.primaryScreen():getUUID()
  if uuid == "F1F3CB48-061A-2605-D519-12079E868634" then
    no_full_screen()
  else
    go_full_screen()
  end
end)

-- App shortcuts.  Use bundle IDs (find one with:
--   defaults read "/Applications/X.app/Contents/Info" CFBundleIdentifier)
-- because launching by name needs the exact .app file name, which often
-- differs from the app's display name (iTerm.app, "Google Chat 1.app"…).

-- Open iTerm2
hs.hotkey.bind({"option", "ctrl"}, "t", function()
  appCycle.launchOrCycle("com.googlecode.iterm2")
end)

-- Open Google Chrome
hs.hotkey.bind({"option", "ctrl"}, "c", function()
  appCycle.launchOrCycle("com.google.Chrome")
end)

-- Open Google Messages (Chrome web app)
hs.hotkey.bind({"option", "ctrl"}, "m", function()
  appCycle.launchOrCycle("com.google.Chrome.app.hpfldicfbfomlpcikngkocigghgafkph")
end)

-- Open Bitwarden
hs.hotkey.bind({"option", "ctrl"}, "b", function()
  appCycle.launchOrCycle("com.bitwarden.desktop")
end)

-- Open Home Assistant
hs.hotkey.bind({"option", "ctrl"}, "h", function()
  appCycle.launchOrCycle("io.robbie.HomeAssistant")
end)

-- Open Sonos
hs.hotkey.bind({"option", "ctrl"}, "s", function()
  appCycle.launchOrCycle("com.sonos.macController2")
end)

-- Open Google Chat (Chrome web app)
hs.hotkey.bind({"option", "ctrl"}, "g", function()
  appCycle.launchOrCycle("com.google.Chrome.app.pommaclcbfghclhalboakcipcmmndhcj")
end)

-- Open VS Code
hs.hotkey.bind({"option", "ctrl"}, "v", function()
  appCycle.launchOrCycle("com.microsoft.VSCode")
end)

-- Open Finder
hs.hotkey.bind({"option", "ctrl"}, "f", function()
  appCycle.launchOrCycle("com.apple.finder")
end)

local screens = hs.screen.allScreens()
-- F1F3CB48-061A-2605-D519-12079E868634  40" big screen
-- 69806ECC-4FDD-525B-1A4D-7D21241799A0  internal display

for i, sc in ipairs(screens) do
  hs.console.printStyledtext("screen count")
  hs.console.printStyledtext(#screens)
  hs.console.printStyledtext(sc:getUUID())
end

