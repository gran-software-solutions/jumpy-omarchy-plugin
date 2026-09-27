-- Hop: the Alt+Tab switcher for the Omarchy shell.
--
-- Load it from ~/.config/hypr/bindings.lua:
--
--   dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/de.gransoftware.hop/hop.lua")
--
-- This half owns all state and all keys; Hop.qml only draws what it is told,
-- over `omarchy-shell hop show|hide`.
--
--   Alt+Tab, release        flip to the last window (no list is drawn)
--   hold Alt, tap Tab       walk the list, most recently used first
--   hold Alt, type letters  filter by app name or title
--   Alt+1..9                jump straight to that row
--   Alt+Delete              close the selected window, list stays open
--   Alt+`                   same, but only windows of the current app
--   Alt+Escape              cancel
--
-- While the list is up, Hyprland is in the "hop" submap, whose catchall
-- swallows every key Hop does not bind, so nothing leaks into the window
-- underneath. Three things end the submap so it can never trap the keyboard:
-- the Alt release, a poll that notices Alt is up, and a hard timeout.

local hop = {
  windows = {},   -- frozen snapshot, most recent first (plain tables)
  shown = {},     -- the filtered view of `windows`
  index = 1,
  filter = "",
  mode = "all",   -- all | app
  active = false,
  started = 0,
  alt_down = false,
}

local SUBMAP = "hop"
local ALT_KEYCODES = { [64] = true, [108] = true } -- Alt_L, Alt_R
local TIMEOUT_MS = 20000

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function send(method, argument)
  local command = "omarchy-shell -q hop " .. method
  if argument then command = command .. " " .. shell_quote(argument) end
  hl.exec_cmd(command)
end

local function json_string(value)
  local escaped = tostring(value or "")
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("[%c]", function(c) return string.format("\\u%04x", c:byte()) end)
  return '"' .. escaped .. '"'
end

-- "com.mitchellh.ghostty" -> "ghostty", "brave-browser" stays as is.
local function app_name(class)
  local name = tostring(class or "")
  return (name:match("([^.]+)$") or name):lower()
end

-- Filtering ------------------------------------------------------------------

local function initials(text)
  local out = {}
  for word in text:gmatch("[%w]+") do out[#out + 1] = word:sub(1, 1) end
  return table.concat(out)
end

local function is_subsequence(needle, haystack)
  local at = 1
  for i = 1, #needle do
    at = haystack:find(needle:sub(i, i), at, true)
    if not at then return false end
    at = at + 1
  end
  return true
end

-- Higher is better; nil means no match. The app name wins over the title, and
-- an acronym ("vsc", "gc") counts almost as much as a prefix.
local function score(window, query)
  local app = window.app
  local title = window.title:lower()
  local all = app .. " " .. title

  if app:sub(1, #query) == query then return 5 end
  local acronym = initials(all):find(query, 1, true)
  if acronym == 1 then return 4 end
  -- Titles often lead with a file or page name ("main.go - api - Visual
  -- Studio Code"), so an acronym later in the title still counts.
  if acronym and #query > 1 then return 3 end
  local at = all:find(query, 1, true)
  if at then
    local prev = at > 1 and all:sub(at - 1, at - 1) or " "
    return prev:match("[%w]") and 2 or 3
  end
  if is_subsequence(query, all) then return 1 end
  return nil
end

local function refilter()
  local query = hop.filter:lower()
  if query == "" then
    hop.shown = hop.windows
    return
  end

  local scored = {}
  for order, window in ipairs(hop.windows) do
    local s = score(window, query)
    if s then scored[#scored + 1] = { window = window, score = s, order = order } end
  end
  -- Recency breaks ties, so the window you used last wins among equals.
  table.sort(scored, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.order < b.order
  end)

  hop.shown = {}
  for _, entry in ipairs(scored) do hop.shown[#hop.shown + 1] = entry.window end

  -- You are already on the window you are leaving. Push it to the end, so a
  -- query that matches it and something else lands on the something else.
  if #hop.shown > 1 and hop.shown[1].current then
    table.insert(hop.shown, table.remove(hop.shown, 1))
  end
end

-- Snapshot -------------------------------------------------------------------

local function snapshot(mode)
  local active = hl.get_active_window()
  local active_address = active and active.address
  local active_app = active and app_name(active.class)

  local raw = {}
  for _, window in ipairs(hl.get_windows()) do
    local workspace = window.workspace
    if window.mapped and workspace and not workspace.special then
      raw[#raw + 1] = window
    end
  end
  table.sort(raw, function(a, b) return a.focus_history_id < b.focus_history_id end)

  -- Copy out what we need. Window handles do not survive past the callback,
  -- and reading one later throws inside a key handler, losing the switch.
  local windows = {}
  for _, window in ipairs(raw) do
    local app = app_name(window.class)
    if mode ~= "app" or app == active_app then
      windows[#windows + 1] = {
        address = window.address,
        title = window.title or "",
        class = window.class or "",
        app = app,
        workspace = window.workspace.name or "",
        current = window.address == active_address,
      }
    end
  end
  return windows
end

-- Panel ----------------------------------------------------------------------

local function payload()
  local rows = {}
  for _, w in ipairs(hop.shown) do
    rows[#rows + 1] = string.format(
      '{"title":%s,"appClass":%s,"workspace":%s,"current":%s}',
      json_string(w.title), json_string(w.class), json_string(w.workspace),
      w.current and "true" or "false"
    )
  end
  return string.format(
    '{"windows":[%s],"index":%d,"filter":%s,"mode":%s,"total":%d}',
    table.concat(rows, ","), hop.index - 1, json_string(hop.filter),
    json_string(hop.mode), #hop.windows
  )
end

local function redraw()
  send("show", payload())
end

-- Lifecycle ------------------------------------------------------------------

local poll -- created at the bottom, once the functions it calls exist

local function teardown()
  if not hop.active then return end
  hop.active = false
  hop.windows, hop.shown, hop.filter = {}, {}, ""
  if poll then poll:set_enabled(false) end
  hl.dispatch(hl.dsp.submap("reset"))
  send("hide")
end

local function commit()
  if not hop.active then return end
  local target = hop.shown[hop.index]
  local address = target and target.address
  teardown()

  -- Out of process on purpose: focusing from inside a key callback does not
  -- settle until the next input event, so the switch would look dead.
  if address then
    local focus = string.format('hl.dsp.focus({ window = "address:%s" })', address)
    hl.exec_cmd("hyprctl dispatch " .. shell_quote(focus))
  end
end

local function start(mode, delta)
  local windows = snapshot(mode)
  if #windows < 2 and not (mode == "app" and #windows == 1 and not windows[1].current) then
    return
  end

  hop.windows = windows
  hop.shown = windows
  hop.mode = mode
  hop.filter = ""
  hop.active = true
  hop.alt_down = true -- the bind that got us here needs Alt held
  hop.started = os.time()

  -- Entry 1 is where you are, so one tap lands on entry 2 and one back-tap
  -- wraps to the oldest.
  hop.index = delta % #hop.shown + 1

  hl.dispatch(hl.dsp.submap(SUBMAP))
  if poll then poll:set_enabled(true) end
  redraw()
end

local function step(delta, mode)
  if not hop.active then
    start(mode or "all", delta)
    return
  end
  if #hop.shown == 0 then return end
  hop.index = (hop.index - 1 + delta) % #hop.shown + 1
  redraw()
end

local function set_filter(text)
  hop.filter = text
  refilter()
  -- With no filter the list is back in recency order, where row 1 is the
  -- window you are on; the cursor goes to row 2, as it did at the start.
  hop.index = (text == "" and #hop.shown > 1) and 2 or 1
  redraw()
end

local function type_char(char)
  if hop.active then set_filter(hop.filter .. char) end
end

local function backspace()
  if not hop.active or hop.filter == "" then return end
  set_filter(hop.filter:sub(1, -2))
end

local function jump(row)
  if not hop.active or row > #hop.shown then return end
  hop.index = row
  commit()
end

local function close_selected()
  if not hop.active then return end
  local target = hop.shown[hop.index]
  if not target then return end

  local close = string.format('hl.dsp.window.close({ window = "address:%s" })', target.address)
  hl.exec_cmd("hyprctl dispatch " .. shell_quote(close))

  for i, w in ipairs(hop.windows) do
    if w.address == target.address then table.remove(hop.windows, i) break end
  end
  refilter()
  if #hop.shown == 0 and hop.filter == "" then
    teardown()
    return
  end
  if hop.index > #hop.shown then hop.index = math.max(1, #hop.shown) end
  redraw()
end

-- The panel's own watchdog calls this if it ever outlives a switch.
_G.__hop_cancel = teardown

-- Keys -----------------------------------------------------------------------

hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")
hl.unbind("ALT + ESCAPE")
hl.unbind("ALT + grave")
hl.bind("ALT + TAB", function() step(1) end, { description = "Hop: switch window" })
hl.bind("ALT + SHIFT + TAB", function() step(-1) end, { description = "Hop: switch window (reverse)" })
hl.bind("ALT + grave", function() step(1, "app") end, { description = "Hop: switch window of this app" })

hl.define_submap(SUBMAP, function()
  hl.bind("ALT + TAB", function() step(1) end)
  hl.bind("ALT + SHIFT + TAB", function() step(-1) end)
  hl.bind("ALT + grave", function() step(1) end)
  hl.bind("ALT + SHIFT + grave", function() step(-1) end)
  hl.bind("ALT + DOWN", function() step(1) end, { repeating = true })
  hl.bind("ALT + UP", function() step(-1) end, { repeating = true })
  hl.bind("ALT + RETURN", commit)
  hl.bind("ALT + ESCAPE", teardown)
  hl.bind("ESCAPE", teardown)
  hl.bind("ALT + BACKSPACE", backspace, { repeating = true })
  hl.bind("ALT + DELETE", close_selected)

  for code = string.byte("a"), string.byte("z") do
    local char = string.char(code)
    hl.bind("ALT + " .. char, function() type_char(char) end)
  end
  hl.bind("ALT + space", function() type_char(" ") end)
  hl.bind("ALT + minus", function() type_char("-") end)
  hl.bind("ALT + period", function() type_char(".") end)
  for row = 1, 9 do
    hl.bind("ALT + " .. row, function() jump(row) end)
  end

  -- Everything else is swallowed while the list is up.
  hl.bind("catchall", hl.dsp.no_op())
end)

-- A release bind on a modifier only fires when it is tapped alone, and Tab in
-- between cancels it, so the raw key stream is read instead. This runs for
-- every key on the system: two compares unless a switch is up.
hl.on("input.keyboard.key", function(keycode, _, state)
  if not ALT_KEYCODES[keycode] then return end
  hop.alt_down = state ~= 0
  if state == 0 and hop.active then commit() end
end)

-- Belt and braces: if the release event is ever missed, or the list has been
-- up far too long, end the switch rather than hold the keyboard in the submap.
poll = hl.timer(function()
  if not hop.active then return end
  if not hop.alt_down then
    commit()
  elseif (os.time() - hop.started) * 1000 > TIMEOUT_MS then
    teardown()
  end
end, { timeout = 250, type = "repeat" })
poll:set_enabled(false)
