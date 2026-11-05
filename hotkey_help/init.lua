-- hotkey_help/init.lua
-- ─────────────────────────────────────────────────────────────────
-- Shows a dialog listing every active Hammerspoon hotkey.
--
-- The list builds itself: this module wraps hs.hotkey.new / .bind,
-- so every hotkey bound anywhere in the config (after this module is
-- required) is recorded along with the file and line that bound it.
--
-- Description of each hotkey, first match wins:
--   1. the comment line(s) directly above the bind call
--   2. a trailing comment on the bind line itself
--   3. a guess from the body, e.g. launchOrFocus("Sonos") → "Open Sonos"
--   4. "(no description)"
--
-- Require this FIRST in ~/.hammerspoon/init.lua so it sees every bind.
-- ─────────────────────────────────────────────────────────────────

local M = {}

local configDir  = hs.configdir
local thisSource = debug.getinfo(1, "S").source

-- hotkey object → { mods, key, file, line, desc }
local registry = setmetatable({}, { __mode = "k" })
local order    = 0

-- ── source inspection ────────────────────────────────────────────

local fileCache = {}

local function fileLines(path)
    if fileCache[path] then return fileCache[path] end
    local lines = {}
    local f = io.open(path, "r")
    if f then
        for l in f:lines() do table.insert(lines, l) end
        f:close()
    end
    fileCache[path] = lines
    return lines
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

--- A comment's text, or nil for decorative lines like "-- ── x ──".
local function commentText(line)
    local text = line:match("^%s*%-%-+%s?(.*)$")
    if not text then return nil end
    text = trim(text)
    if text == "" or text:find("──") or text:match("^[%-=~#*]+$") then return nil end
    return text
end

local function capitalise(s) return (s:gsub("^%l", string.upper)) end

local function describeFromSource(path, lineNo)
    local lines = fileLines(path)
    if #lines == 0 then return nil end

    -- 1. Contiguous comment block directly above the bind.
    local block = {}
    local i = lineNo - 1
    while i >= 1 and lines[i]:match("^%s*%-%-") do
        local t = commentText(lines[i])
        if t then table.insert(block, 1, t) end
        i = i - 1
    end
    if #block > 0 then return capitalise(table.concat(block, " ")) end

    -- 2. Trailing comment on the bind line.
    local trailing = (lines[lineNo] or ""):match("%-%-%s*(.-)%s*$")
    if trailing and trailing ~= "" then return capitalise(trailing) end

    -- 3. Guess from the body (up to the closing "end)").
    for j = lineNo, math.min(lineNo + 15, #lines) do
        local l = lines[j]
        local app = l:match("launchOrFocus%(%s*[\"'](.-)[\"']")
        if app then return "Open " .. app end
        local fn = l:match("^%s*([%w_%.:]+)%(%s*%)%s*$")
        if fn and j > lineNo then
            return capitalise((fn:gsub("^.*[%.:]", ""):gsub("_", " ")
                :gsub("(%l)(%u)", "%1 %2"):lower()))
        end
        if j > lineNo and l:match("^%s*end%s*%)") then break end
    end
    return nil
end

--- First stack frame inside the user's config (not this module and
--- not Hammerspoon's own hs.hotkey code).
local function callerFrame()
    for level = 3, 12 do
        local info = debug.getinfo(level, "Sl")
        if not info then return nil end
        local src = info.source or ""
        if src:sub(1, 1) == "@" and src ~= thisSource
            and src:sub(2, #configDir + 1) == configDir then
            return src:sub(2), info.currentline
        end
    end
    return nil
end

-- ── key formatting ───────────────────────────────────────────────

local modSymbols = {
    ctrl = "⌃", control = "⌃", ["⌃"] = "⌃",
    alt = "⌥", option = "⌥", opt = "⌥", ["⌥"] = "⌥",
    shift = "⇧", ["⇧"] = "⇧",
    cmd = "⌘", command = "⌘", ["⌘"] = "⌘",
    fn = "fn",
}
local modOrder = { "fn", "⌃", "⌥", "⇧", "⌘" }

local keyNames = {
    ["return"] = "↩", space = "Space", escape = "⎋", tab = "⇥",
    delete = "⌫", forwarddelete = "⌦", left = "←", right = "→",
    up = "↑", down = "↓", home = "↖", ["end"] = "↘",
    pageup = "⇞", pagedown = "⇟",
}

local function normaliseMods(mods)
    local list = {}
    if type(mods) == "string" then
        for m in mods:gmatch("[^%s%-%+,]+") do table.insert(list, m) end
        -- Strings like "⌃⌥" have no separators.
        if #list == 1 and not modSymbols[list[1]:lower()] then
            list = {}
            for _, c in utf8.codes(mods) do table.insert(list, utf8.char(c)) end
        end
    elseif type(mods) == "table" then
        list = mods
    end
    local set = {}
    for _, m in ipairs(list) do
        local s = modSymbols[tostring(m):lower()] or modSymbols[tostring(m)]
        if s then set[s] = true end
    end
    local out = {}
    for _, s in ipairs(modOrder) do if set[s] then table.insert(out, s) end end
    return out
end

local function formatKey(key)
    if type(key) == "number" then
        key = hs.keycodes.map[key] or tostring(key)
    end
    key = tostring(key)
    local lower = key:lower()
    if keyNames[lower] then return keyNames[lower] end
    if #key == 1 then return key:upper() end
    return key:upper()  -- F1, PAD1, …
end

-- ── hooks on hs.hotkey ───────────────────────────────────────────

local function record(hk, mods, key, desc)
    if type(hk) ~= "table" or registry[hk] then return end
    local file, line = callerFrame()
    order = order + 1
    registry[hk] = {
        mods  = normaliseMods(mods),
        key   = formatKey(key),
        file  = file,
        line  = line,
        desc  = desc or (file and describeFromSource(file, line)),
        order = order,
    }
end

local origNew  = hs.hotkey.new
local origBind = hs.hotkey.bind

hs.hotkey.new = function(mods, key, ...)
    local hk = origNew(mods, key, ...)
    record(hk, mods, key)
    return hk
end

hs.hotkey.bind = function(mods, key, ...)
    local hk = origBind(mods, key, ...)
    record(hk, mods, key)
    return hk
end

--- Bind a hotkey with an explicit description (overrides comments).
function M.bind(mods, key, desc, fn)
    local hk = origBind(mods, key, fn)
    registry[hk] = nil
    record(hk, mods, key, desc)
    return hk
end

-- ── dialog ───────────────────────────────────────────────────────

local function esc(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function relPath(file)
    if not file then return "Other" end
    if file:sub(1, #configDir + 1) == configDir .. "/" then
        return file:sub(#configDir + 2)
    end
    return file
end

--- Active hotkeys grouped by source file.
local function collect()
    local enabled = {}
    for _, hk in ipairs(hs.hotkey.getHotkeys()) do enabled[hk] = true end

    local groups, groupOrder = {}, {}
    local function add(groupName, item)
        if not groups[groupName] then
            groups[groupName] = {}
            table.insert(groupOrder, groupName)
        end
        table.insert(groups[groupName], item)
    end

    local recorded = {}
    for hk, info in pairs(registry) do
        if enabled[hk] and not info.hidden then
            table.insert(recorded, info)
        end
    end
    table.sort(recorded, function(a, b) return a.order < b.order end)
    for _, info in ipairs(recorded) do
        add(relPath(info.file), {
            keys = table.concat(info.mods) .. info.key,
            desc = info.desc or "(no description)",
            sortKey = info.key,
        })
    end

    -- Hotkeys bound before this module loaded (or by Spoons).
    for hk in pairs(enabled) do
        if not registry[hk] then
            add("Other", { keys = hk.idx or "?", desc = (hk.msg ~= hk.idx and hk.msg) or "(unknown)", sortKey = hk.idx or "" })
        end
    end

    for _, items in pairs(groups) do
        table.sort(items, function(a, b) return a.sortKey < b.sortKey end)
    end
    return groups, groupOrder
end

local function buildHTML(groups, groupOrder)
    local rows = {}
    for _, g in ipairs(groupOrder) do
        table.insert(rows, '<tr class="group"><td colspan="2">' .. esc(g) .. '</td></tr>')
        for _, it in ipairs(groups[g]) do
            table.insert(rows, '<tr><td class="key"><kbd>' .. esc(it.keys) ..
                '</kbd></td><td>' .. esc(it.desc) .. '</td></tr>')
        end
    end
    return [[
<!doctype html><html><head><meta charset="utf-8"><style>
  :root { color-scheme: dark; }
  body { margin: 0; padding: 16px 20px 12px; background: #1e1f22; color: #e6e6e6;
         font: 13px -apple-system, BlinkMacSystemFont, sans-serif; }
  table { width: 100%; border-collapse: collapse; }
  td { padding: 5px 8px; vertical-align: top; }
  tr.group td { padding-top: 14px; color: #8ab4f8; font-weight: 600; font-size: 12px;
                text-transform: uppercase; letter-spacing: .04em;
                border-bottom: 1px solid #3a3b3f; }
  tr.group:first-child td { padding-top: 0; }
  td.key { width: 1%; white-space: nowrap; }
  kbd { display: inline-block; min-width: 2.2em; text-align: center; padding: 2px 7px;
        border-radius: 5px; background: #2d2f33; border: 1px solid #45474c;
        font: 13px "SF Mono", Menlo, monospace; }
  .hint { margin-top: 12px; color: #8a8d93; font-size: 11px; text-align: center; }
</style></head><body>
<table>]] .. table.concat(rows, "\n") .. [[</table>
<div class="hint">Press Esc or ⌃⌥/ to close</div>
<script>
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' || e.key === '/') {
      window.webkit.messageHandlers.hotkeyHelp.postMessage('close');
    }
  });
</script>
</body></html>]], #rows
end

local view, prevWin

function M.hide()
    if view then
        local v = view
        view = nil
        v:delete()
        if prevWin then pcall(function() prevWin:focus() end) end
        prevWin = nil
    end
end

function M.show()
    if view then return end
    prevWin = hs.window.focusedWindow()

    local html, nrows = buildHTML(collect())
    local screen = hs.screen.mainScreen():frame()
    local w = 520
    local h = math.min(screen.h * 0.85, 60 + nrows * 29)
    local rect = { x = screen.x + (screen.w - w) / 2, y = screen.y + (screen.h - h) / 2, w = w, h = h }

    local uc = hs.webview.usercontent.new("hotkeyHelp")
    uc:setCallback(function(msg)
        if msg.body == "close" then M.hide() end
    end)

    local hadFocus = false
    view = hs.webview.new(rect, { developerExtrasEnabled = false }, uc)
        :windowStyle({ "titled", "closable", "utility", "HUD" })
        :windowTitle("Keyboard Shortcuts")
        :allowTextEntry(true)
        :level(hs.drawing.windowLevels.modalPanel)
        :deleteOnClose(true)
        :windowCallback(function(action, _, state)
            if action == "closing" then
                view = nil
            elseif action == "focusChange" then
                if state then
                    hadFocus = true
                elseif hadFocus then
                    M.hide()   -- clicked elsewhere
                end
            end
        end)
        :html(html)
    pcall(function() view:behaviorAsLabels({ "canJoinAllSpaces", "fullScreenAuxiliary" }) end)
    view:show()
    hs.focus()
    view:bringToFront(true)
    pcall(function() view:hswindow():focus() end)
end

function M.toggle()
    if view then M.hide() else M.show() end
end

-- Show / hide this list of keyboard shortcuts
local helpKey = M.bind({ "ctrl", "option" }, "/", "Show / hide this list of keyboard shortcuts", M.toggle)
registry[helpKey].file = configDir .. "/init.lua"

return M
