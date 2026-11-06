-- app_cycle/init.lua
-- ─────────────────────────────────────────────────────────────────
-- launchOrCycle(appID)   – appID is a bundle ID (preferred) or app name
--   • App not running          → launch it.
--   • App running, not in front → focus it (like launchOrFocus).
--   • App already in front      → focus its NEXT window, left to right
--                                 in Mission Control order, wrapping
--                                 around.  Only one window → do nothing.
--
-- Finding windows on other Spaces
-- ───────────────────────────────
-- hs.window can only see windows in other Spaces for some apps
-- (Chrome: yes; Electron apps like VS Code: no).  So windows come from:
--   1. app:allWindows()
--   2. a small cache of windows seen in focus (recorded on app
--      activation and Space changes) – window objects stay usable
--      after they move to another Space
--   3. fallback: the app's "Window" menu, which lists every window on
--      every Space – the item after the checked (current) one is pressed.
--
-- Performance: hs.window.filter is deliberately NOT used – it starts a
-- global Accessibility watcher on every running app, which blocks
-- Hammerspoon for many seconds when Chrome (or any app) answers AX
-- requests slowly.  Every AX call here targets just one app.
-- ─────────────────────────────────────────────────────────────────

local M = {}

-- Set appCycle.debug = true (e.g. in the Hammerspoon console) to log timings.
M.debug = false
local function dbg(fmt, ...)
    if M.debug then hs.console.printStyledtext("[app_cycle] " .. string.format(fmt, ...)) end
end

-- pid → { [windowID] = hs.window }
local seen = {}

local function remember(w)
    local app = w and w:application()
    local id = w and w:id()
    if not (app and id) then return end
    local pid = app:pid()
    seen[pid] = seen[pid] or {}
    seen[pid][id] = w
end

local pendingTimer
local function rememberFocusedSoon()
    -- Let focus settle after a Space switch / activation.
    if pendingTimer then pendingTimer:stop() end
    pendingTimer = hs.timer.doAfter(0.3, function()
        pendingTimer = nil
        local w = hs.window.focusedWindow()
        if w then remember(w) end
    end)
end

M._spaceWatcher = hs.spaces.watcher.new(rememberFocusedSoon)
M._spaceWatcher:start()

M._appWatcher = hs.application.watcher.new(function(_, event, app)
    if event == hs.application.watcher.activated then
        rememberFocusedSoon()
    elseif event == hs.application.watcher.terminated and app then
        local ok, pid = pcall(function() return app:pid() end)
        if ok and pid then seen[pid] = nil end
    end
end)
M._appWatcher:start()

--- Does `app` correspond to the name given to launchOrFocus?
local function appMatches(app, appName)
    if not app then return false end
    if app:name() == appName or app:bundleID() == appName then return true end
    local path = app:path() or ""
    return path:match("/([^/]+)%.app$") == appName
end

--- Position of each Space in Mission Control order (across screens).
local function spacePositions()
    local pos, n = {}, 0
    for _, screen in ipairs(hs.screen.allScreens()) do
        for _, sid in ipairs(hs.spaces.spacesForScreen(screen) or {}) do
            n = n + 1
            pos[sid] = n
        end
    end
    return pos
end

--- All usable windows of the app, sorted left → right by Space.
local function appWindows(app, appName)
    local byId = {}
    local function add(w)
        local id = w and w:id()
        if id and not byId[id] and w:isStandard() and not w:isMinimized() then
            local a = w:application()
            if a and a:pid() == app:pid() then byId[id] = w end
        end
    end
    local t0 = hs.timer.secondsSinceEpoch()
    for _, w in ipairs(app:allWindows()) do add(w); remember(w) end
    dbg("allWindows: %.3fs", hs.timer.secondsSinceEpoch() - t0)
    local cache = seen[app:pid()]
    if cache then
        for id, w in pairs(cache) do
            if byId[id] == nil then
                local ok = pcall(add, w)
                if not ok or not byId[id] then cache[id] = nil end   -- closed / gone
            end
        end
    end
    dbg("with cache: %.3fs", hs.timer.secondsSinceEpoch() - t0)

    local pos = spacePositions()
    local list = {}
    for id, w in pairs(byId) do
        local spaces = hs.spaces.windowSpaces(w) or {}
        local p = math.huge
        for _, sid in ipairs(spaces) do
            if pos[sid] and pos[sid] < p then p = pos[sid] end
        end
        table.insert(list, { win = w, id = id, pos = p, x = w:frame().x })
    end
    table.sort(list, function(a, b)
        if a.pos ~= b.pos then return a.pos < b.pos end
        if a.x ~= b.x then return a.x < b.x end
        return a.id < b.id
    end)
    return list
end

--- Fallback: press the next window entry in the app's Window menu.
local function cycleViaWindowMenu(app)
    local ax = hs.axuielement.applicationElement(app)
    local bar = ax and ax:attributeValue("AXMenuBar")
    if not bar then return false end

    local items
    for _, top in ipairs(bar:attributeValue("AXChildren") or {}) do
        if top:attributeValue("AXTitle") == "Window" then
            local menu = (top:attributeValue("AXChildren") or {})[1]
            items = menu and menu:attributeValue("AXChildren")
            break
        end
    end
    if not items then return false end

    -- Window entries: a titled item with no submenu, in the same
    -- separator-bounded section as the checked (current) window.
    local function isEntry(it)
        local t = it:attributeValue("AXTitle")
        return t and t ~= "" and #(it:attributeValue("AXChildren") or {}) == 0
    end

    local current
    for i, it in ipairs(items) do
        if it:attributeValue("AXMenuItemMarkChar") == "✓" and isEntry(it) then
            current = i
        end
    end
    if not current then return false end

    local first, last = current, current
    while first > 1 and isEntry(items[first - 1]) do first = first - 1 end
    while last < #items and isEntry(items[last + 1]) do last = last + 1 end
    if first == last then return false end

    local nextIdx = (current == last) and first or current + 1
    return items[nextIdx]:performAction("AXPress") ~= nil
end

--- Launch / focus the app, or go to its next window if already in front.
function M.launchOrCycle(appName)
    local front = hs.application.frontmostApplication()
    if not appMatches(front, appName) then
        -- Bundle IDs are unambiguous; names must match the .app file name.
        if hs.application.nameForBundleID(appName) then
            hs.application.launchOrFocusByBundleID(appName)
        else
            hs.application.launchOrFocus(appName)
        end
        return
    end

    local t0 = hs.timer.secondsSinceEpoch()
    local wins = appWindows(front, appName)
    local focused = hs.window.focusedWindow()
    local fid = focused and focused:id()
    dbg("%s: %d windows found in %.3fs", appName, #wins, hs.timer.secondsSinceEpoch() - t0)

    if #wins >= 2 then
        local idx
        for i, e in ipairs(wins) do
            if e.id == fid then idx = i break end
        end
        local target = wins[idx and (idx % #wins) + 1 or 1]
        if target.id ~= fid then
            target.win:focus()
            dbg("focused next window, total %.3fs", hs.timer.secondsSinceEpoch() - t0)
            return
        end
    end

    -- Only one window visible to Hammerspoon – others may be on Spaces
    -- it can't see; ask the Window menu.
    pcall(cycleViaWindowMenu, front)
    dbg("window-menu fallback, total %.3fs", hs.timer.secondsSinceEpoch() - t0)
end

return M
