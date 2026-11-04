-- spaces_order/init.lua
-- ─────────────────────────────────────────────────────────────────
-- Automatically arranges configured apps into full-screen spaces
-- in a predictable left-to-right Mission Control order, regardless
-- of the order in which the apps were launched.
--
-- Algorithm for reordering
-- ────────────────────────
-- macOS APPENDS each new full-screen space to the right of all
-- existing spaces.  So full-screening in FORWARD config order
-- naturally produces the correct left-to-right result.
--
--   Example: config = {A, B, C}, unmanaged = {X}
--     step 1 – full-screen A  →  [Space1, A-fs]
--     step 2 – full-screen B  →  [Space1, A-fs, B-fs]
--     step 3 – full-screen C  →  [Space1, A-fs, B-fs, C-fs]
--     step 4 – full-screen X  →  [Space1, A-fs, B-fs, C-fs, X-fs]  ✓
--
-- Details
-- ───────
--  • Every full-screen window is considered, not just each app's
--    main window.  Several windows matching the same config entry
--    stay adjacent, in their previous relative order.
--  • Full-screen windows matching no entry go last, in their
--    previous relative order.
--  • Spaces already in the right position at the far left are left
--    alone; only the spaces from the first wrong one onward are rebuilt.
--  • hs.window can only see windows in other Spaces for some apps
--    (Chrome yes, Electron apps like VS Code no).  When a full-screen
--    space's window can't be resolved, that space is visited briefly
--    so its window can be identified.
--  • A single progress dialog stays centred on screen from the start
--    of a reorder until it finishes.
-- ─────────────────────────────────────────────────────────────────

local cfg = require("spaces_order.config")
local sp  = hs.spaces

local M = {}
hs.application.enableSpotlightForNameSearches(true)

-- ── helpers ──────────────────────────────────────────────────────

local function dbg(msg)
    if cfg.debug then
        hs.console.printStyledtext("[spaces_order] " .. msg)
    end
end

-- Keep references to running timers so they are not garbage-collected.
local timers = {}

local function after(sec, fn)
    local t
    t = hs.timer.doAfter(sec, function()
        timers[t] = nil
        fn()
    end)
    timers[t] = true
    return t
end

--- Poll pred() every 0.1s until it is true or `timeout` seconds pass,
--- then call cb(success).
local function waitUntil(pred, timeout, cb)
    local t0 = hs.timer.secondsSinceEpoch()
    local t
    t = hs.timer.doEvery(0.1, function()
        local ok, res = pcall(pred)
        local done = ok and res
        if done or hs.timer.secondsSinceEpoch() - t0 > timeout then
            t:stop()
            timers[t] = nil
            cb(done and true or false)
        end
    end)
    timers[t] = true
end

--- Run step(item, i, next) for each item sequentially, then done().
local function eachSeq(list, step, done)
    local function go(i)
        if i > #list then return done() end
        step(list[i], i, function() go(i + 1) end)
    end
    go(1)
end

local function contains(list, v)
    for _, x in ipairs(list or {}) do
        if x == v then return true end
    end
    return false
end

-- ── config normalisation & matching ──────────────────────────────

local function toList(v)
    if v == nil then return {} end
    if type(v) == "table" then return v end
    return { v }
end

local function keySet(names)
    local set = {}
    for _, n in ipairs(toList(names)) do set[n:lower()] = true end
    return set
end

-- entries[i] = { idx, label, rules = { { apps = set, title = pattern|nil } } }
local entries   = {}
local allAppKeys = {}   -- every app name / bundle ID mentioned in config

for i, e in ipairs(cfg.apps) do
    if type(e) == "string" then e = { app = e } end
    local rules = {}
    if e.match then
        for _, r in ipairs(e.match) do
            table.insert(rules, { apps = keySet(r.app), title = r.title })
        end
    else
        table.insert(rules, { apps = keySet(e.app), title = e.title })
    end
    for _, r in ipairs(rules) do
        for k in pairs(r.apps) do allAppKeys[k] = true end
    end
    entries[i] = {
        idx   = i,
        label = e.name or toList(e.app)[1] or ("entry " .. i),
        rules = rules,
    }
end

local function appKeys(app)
    local n = app:name()
    local b = app:bundleID()
    return n and n:lower(), b and b:lower()
end

local function appIsConfigured(app)
    if not app then return false end
    local n, b = appKeys(app)
    return (n and allAppKeys[n]) or (b and allAppKeys[b]) or false
end

--- Return the config entry a window belongs to, or nil.
--- A rule with a matching title pattern beats a plain app rule;
--- ties go to the earliest entry.
local function entryForWindow(win)
    local app = win:application()
    if not app then return nil end
    local n, b = appKeys(app)
    local title = win:title() or ""
    local best, bestScore = nil, 0
    for _, e in ipairs(entries) do
        for _, r in ipairs(e.rules) do
            if (n and r.apps[n]) or (b and r.apps[b]) then
                local score
                if r.title then
                    score = title:find(r.title) and 2 or 0
                else
                    score = 1
                end
                if score > bestScore then
                    best, bestScore = e, score
                end
            end
        end
    end
    return best
end

local function describe(win)
    local app = win:application()
    return string.format("%s [%s] \"%s\"",
        app and app:name() or "?",
        app and tostring(app:bundleID()) or "?",
        win:title() or "")
end

-- ── progress dialog ──────────────────────────────────────────────

local overlay

local function overlayShow(screen, title)
    if overlay then overlay:delete() end
    local f = screen:fullFrame()
    local w, h = 480, 120
    overlay = hs.canvas.new({ x = f.x + (f.w - w) / 2, y = f.y + (f.h - h) / 2, w = w, h = h })
    overlay:level(hs.canvas.windowLevels.overlay)
    overlay:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "fullScreenAuxiliary" })
    overlay[1] = {
        type = "rectangle", action = "fill",
        fillColor = { white = 0.1, alpha = 0.9 },
        roundedRectRadii = { xRadius = 14, yRadius = 14 },
    }
    overlay[2] = {
        type = "text", text = title, textSize = 22,
        textColor = { white = 1 }, textAlignment = "center",
        frame = { x = 10, y = 22, w = w - 20, h = 34 },
    }
    overlay[3] = {
        type = "text", text = "", textSize = 14,
        textColor = { white = 0.8 }, textAlignment = "center",
        frame = { x = 10, y = 68, w = w - 20, h = 40 },
    }
    overlay:show()
end

local function status(msg)
    dbg(msg)
    if overlay then overlay[3].text = msg end
end

local function overlayHide(delay)
    local o = overlay
    overlay = nil
    if o then after(delay or 0, function() o:delete() end) end
end

-- ── snapshot ─────────────────────────────────────────────────────

--- Map of window ID → hs.window for every window hs.window can see.
local function windowIndex()
    local map = {}
    for _, w in ipairs(hs.window.allWindows()) do
        local id = w:id()
        if id then map[id] = w end
    end
    return map
end

--- Standard full-screen windows in a space, left to right.
local function windowsInSpace(sid, map)
    local found = {}
    for _, wid in ipairs(sp.windowsForSpace(sid) or {}) do
        local w = map[wid]
        if w and w:isStandard() and w:isFullScreen() then
            table.insert(found, w)
        end
    end
    table.sort(found, function(a, b) return a:frame().x < b:frame().x end)
    return found
end

local function makeItem(win, fs)
    local e = entryForWindow(win)
    local app = win:application()
    return {
        win   = win,
        id    = win:id(),
        entry = e,
        label = e and e.label or (app and app:name()) or "?",
        fs    = fs,
    }
end

--- Build a snapshot of the current state of the screen:
---   current    = full-screen window items in Mission Control order
---   adds       = non-full-screen windows of configured apps to full-screen
---   unresolved = number of full-screen spaces whose window is unknown
--- When allowVisit is true, unresolved spaces are visited to identify them.
local function collect(state, allowVisit, cb)
    local spaces = sp.spacesForScreen(state.screen) or {}
    local map = windowIndex()
    local recs, toVisit = {}, {}

    for pos, sid in ipairs(spaces) do
        if sp.spaceType(sid) == "fullscreen" then
            local rec = { sid = sid, pos = pos, wins = windowsInSpace(sid, map) }
            table.insert(recs, rec)
            if #rec.wins == 0 then table.insert(toVisit, rec) end
        end
    end

    local function finishCollect()
        local snap = { current = {}, adds = {}, unresolved = 0 }
        local seen, hasFs = {}, {}

        for _, rec in ipairs(recs) do
            if #rec.wins == 0 then
                snap.unresolved = snap.unresolved + 1
                dbg("space " .. rec.pos .. ": could not identify its window – left in place")
            end
            for _, w in ipairs(rec.wins) do
                local id = w:id()
                if id and not seen[id] then
                    seen[id] = true
                    local it = makeItem(w, true)
                    table.insert(snap.current, it)
                    if it.entry then hasFs[it.entry.idx] = true end
                    dbg(string.format("space %d: %s → %s", rec.pos, describe(w),
                        it.entry and it.entry.label or "(unmanaged)"))
                end
            end
        end

        -- Configured entries with no full-screen window: pick one window
        -- (preferring the app's main window) to full-screen.
        if cfg.auto_fullscreen ~= false then
            local picked = {}
            for _, app in ipairs(hs.application.runningApplications()) do
                if appIsConfigured(app) then
                    local cands = {}
                    local main = app:mainWindow()
                    if main then table.insert(cands, main) end
                    for _, w in ipairs(app:allWindows()) do table.insert(cands, w) end
                    for _, w in ipairs(cands) do
                        local id = w:id()
                        if id and not seen[id] and w:isStandard()
                            and not w:isFullScreen() and not w:isMinimized() then
                            local e = entryForWindow(w)
                            if e and not hasFs[e.idx] and not picked[e.idx] then
                                picked[e.idx] = true
                                seen[id] = true
                                table.insert(snap.adds, makeItem(w, false))
                                dbg("to full-screen: " .. describe(w) .. " → " .. e.label)
                            end
                        end
                    end
                end
            end
        end

        cb(snap)
    end

    if not allowVisit or #toVisit == 0 then return finishCollect() end

    eachSeq(toVisit, function(rec, i, nxt)
        status(string.format("Identifying spaces… (%d/%d)", i, #toVisit))
        local ok = pcall(sp.gotoSpace, rec.sid)
        if not ok then return nxt() end
        after(cfg.animation_delay + 0.3, function()
            rec.wins = windowsInSpace(rec.sid, windowIndex())
            nxt()
        end)
    end, finishCollect)
end

--- Decide the target order and which spaces need rebuilding.
local function buildPlan(snap, force)
    local managed, unmanaged = {}, {}
    for i, it in ipairs(snap.current) do
        it.order = i
        table.insert(it.entry and managed or unmanaged, it)
    end
    for i, it in ipairs(snap.adds) do
        it.order = #snap.current + i
        table.insert(managed, it)
    end
    table.sort(managed, function(a, b)
        if a.entry.idx ~= b.entry.idx then return a.entry.idx < b.entry.idx end
        return a.order < b.order
    end)

    local plan = {}
    for _, it in ipairs(managed)   do table.insert(plan, it) end
    for _, it in ipairs(unmanaged) do table.insert(plan, it) end

    -- Leading spaces already in the right place stay untouched.
    local keep = 0
    if not force then
        while plan[keep + 1] and snap.current[keep + 1]
            and plan[keep + 1].id == snap.current[keep + 1].id do
            keep = keep + 1
        end
    end

    local redo = {}
    for i = keep + 1, #plan do table.insert(redo, plan[i]) end
    return { plan = plan, keep = keep, redo = redo }
end

-- ── core logic ───────────────────────────────────────────────────

--- Return the first (leftmost) normal desktop space on the screen.
local function baseSpaceID(screen)
    local allSpaces = sp.spacesForScreen(screen) or {}
    for _, sid in ipairs(allSpaces) do
        if sp.spaceType(sid) == "user" then return sid end
    end
    return allSpaces[1]
end

local busy, pendingCheck = false, false
local runToken = 0

--- Return to what was on screen when the reorder started: the focused
--- window (wherever it ended up), or the desktop Space if no app
--- window was focused.
local function restoreView(state)
    local w = state.startWin
    local alive = w and pcall(function() return w:id() end) and w:application() ~= nil
    if alive then
        dbg("returning to window: " .. describe(w))
        pcall(function() w:focus() end)
        return
    end
    local sid = state.startSpace
    if sid and contains(sp.spacesForScreen(state.screen), sid) and sp.focusedSpace() ~= sid then
        dbg("returning to space " .. tostring(sid))
        pcall(sp.gotoSpace, sid)
    end
end

local function finish(state, msg)
    if state.token ~= runToken or not busy then return end
    runToken = runToken + 1
    dbg(msg or "done")

    restoreView(state)

    if overlay then
        status(msg or "")
        overlayHide(1.0)
    end

    busy = false
    if pendingCheck then
        pendingCheck = false
        after(1.5, function() M.checkAndFix() end)
    end
end

local function enterFullScreen(it, nxt)
    local w = it.win
    pcall(function() w:focus() end)
    after(0.4, function()
        pcall(function() w:setFullScreen(true) end)
        waitUntil(function() return w:isFullScreen() end, 5, function(ok)
            if ok then
                after(cfg.animation_delay, nxt)
            elseif not it.retried then
                it.retried = true
                dbg("retrying full-screen: " .. it.label)
                enterFullScreen(it, nxt)
            else
                dbg("gave up full-screening: " .. it.label)
                nxt()
            end
        end)
    end)
end

local function execute(state, p)
    if #p.redo == 0 then
        return finish(state, "Spaces already in order ✓")
    end
    dbg(string.format("plan: keep %d, rebuild %d of %d", p.keep, #p.redo, #p.plan))

    local toExit = {}
    for _, it in ipairs(p.redo) do
        if it.fs then table.insert(toExit, it) end
    end

    -- Step 1: exit full-screen, one window at a time.
    eachSeq(toExit, function(it, i, nxt)
        status(string.format("Exiting full screen (%d/%d): %s", i, #toExit, it.label))
        pcall(function() it.win:setFullScreen(false) end)
        waitUntil(function() return not it.win:isFullScreen() end, 5, function(ok)
            if not ok then dbg("timed out exiting full screen: " .. it.label) end
            after(cfg.animation_delay, nxt)
        end)
    end, function()

        -- Step 2: gather windows on the base desktop.
        status("Gathering windows…")
        local base = baseSpaceID(state.screen)
        if base then
            for _, it in ipairs(p.redo) do
                if not contains(sp.windowSpaces(it.win), base) then
                    pcall(sp.moveWindowToSpace, it.win, base)
                end
            end
        end

        after(cfg.animation_delay, function()
            -- Step 3: full-screen in target order (each appends on the right).
            eachSeq(p.redo, function(it, i, nxt)
                status(string.format("Full screen (%d/%d): %s", p.keep + i, #p.plan, it.label))
                enterFullScreen(it, nxt)
            end, function()
                finish(state, "Spaces order applied ✓")
            end)
        end)
    end)
end

--- Check the order and fix it.  force = rebuild every full-screen space.
local function run(force)
    if busy then
        dbg("already running – will re-check afterwards")
        pendingCheck = true
        return
    end
    busy = true
    runToken = runToken + 1

    -- Remember what is on screen so we can return to it afterwards.
    -- A non-standard "window" (e.g. Finder's desktop) counts as the desktop.
    local startWin = hs.window.focusedWindow()
    if startWin and not startWin:isStandard() then startWin = nil end

    local state = {
        token      = runToken,
        screen     = hs.screen.mainScreen(),
        startWin   = startWin,
        startSpace = sp.focusedSpace(),
    }

    -- Watchdog: never leave the dialog up forever.
    after(180, function() finish(state, "Reorder timed out") end)

    local function guarded(fn)
        return function(...)
            local ok, err = pcall(fn, ...)
            if not ok then
                dbg("error: " .. tostring(err))
                finish(state, "Reorder failed – see console")
            end
        end
    end

    -- Quick look first (no space switching) to see if anything is needed.
    collect(state, false, guarded(function(snap)
        local p = buildPlan(snap, force)
        if not force and snap.unresolved == 0 and #p.redo == 0 then
            busy = false
            runToken = runToken + 1
            dbg("order is correct")
            return
        end

        overlayShow(state.screen, "Reordering spaces…")
        status("Scanning spaces…")

        if snap.unresolved > 0 then
            collect(state, true, guarded(function(snap2)
                execute(state, buildPlan(snap2, force))
            end))
        else
            execute(state, p)
        end
    end))
end

-- ── public entry points ──────────────────────────────────────────

--- Force a full reorder right now (hotkey target).
function M.forceReorder()
    run(true)
end

--- Check order and fix only what is wrong.
function M.checkAndFix()
    run(false)
end

-- ── watchers & hotkeys ───────────────────────────────────────────

-- local appWatcher = hs.application.watcher.new(function(name, event, app)
--     if event == hs.application.watcher.launched and appIsConfigured(app) then
--         dbg("app launched: " .. tostring(name))
--         after(cfg.launch_delay, function() M.checkAndFix() end)
--     end
-- end)
-- appWatcher:start()
-- M._appWatcher = appWatcher

hs.hotkey.bind(cfg.hotkey_mods, cfg.hotkey_key, function()
    M.forceReorder()
end)

-- ── initial run on config load ───────────────────────────────────
-- Give apps already open at startup a moment to settle.

-- after(3.0, function()
--     dbg("startup check")
--     M.checkAndFix()
-- end)

dbg("module loaded – watching " .. #entries .. " entries")

return M
