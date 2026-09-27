-- Jumpy: the Alt+Tab switcher for the Omarchy shell.
--
-- Load it from ~/.config/hypr/bindings.lua:
--
--   dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/de.gransoftware.jumpy/jumpy.lua")
--
-- This half owns all state and all keys; Jumpy.qml only draws what it is told,
-- over `omarchy-shell jumpy show|hide`.
--
--   Alt+Tab, release        flip to the last window (no list is drawn)
--   hold Alt, tap Tab       walk the list, most recently used first
--   hold Alt, type letters  fuzzy filter by app name or title
--   Alt+Ctrl+J / Alt+Ctrl+K move down / up (letters alone are the filter)
--   Alt+Ctrl+H              delete a letter (as does Alt+Backspace)
--   Alt+Ctrl+U              clear the filter
--   Alt+Delete, Alt+Ctrl+W  close the selected window, list stays open
--   Alt+`                   same, but only windows of the current app
--   Alt+Escape              cancel
--
-- While the list is up, Hyprland is in the "jumpy" submap, whose catchall
-- swallows every key Jumpy does not bind, so nothing leaks into the window
-- underneath. Three things end the submap so it can never trap the keyboard:
-- the Alt release, a poll that notices Alt is up, and a hard timeout.

local jumpy = {
  windows = {},   -- frozen snapshot, most recent first (plain tables)
  shown = {},     -- the filtered view of `windows`
  index = 1,
  filter = "",
  mode = "all",   -- all | app
  active = false,
  started = 0,
  alt_down = false,
}

local SUBMAP = "jumpy"
local ALT_KEYCODES = { [64] = true, [108] = true } -- Alt_L, Alt_R
local TIMEOUT_MS = 20000

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function send(method, argument)
  local command = "omarchy-shell -q jumpy " .. method
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
  local query = jumpy.filter:lower()
  if query == "" then
    jumpy.shown = jumpy.windows
    return
  end

  local scored = {}
  for order, window in ipairs(jumpy.windows) do
    local s = score(window, query)
    if s then scored[#scored + 1] = { window = window, score = s, order = order } end
  end
  -- Recency breaks ties, so the window you used last wins among equals.
  table.sort(scored, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.order < b.order
  end)

  jumpy.shown = {}
  for _, entry in ipairs(scored) do jumpy.shown[#jumpy.shown + 1] = entry.window end

  -- You are already on the window you are leaving. Push it to the end, so a
  -- query that matches it and something else lands on the something else.
  if #jumpy.shown > 1 and jumpy.shown[1].current then
    table.insert(jumpy.shown, table.remove(jumpy.shown, 1))
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
  for _, w in ipairs(jumpy.shown) do
    rows[#rows + 1] = string.format(
      '{"title":%s,"appClass":%s,"workspace":%s,"current":%s}',
      json_string(w.title), json_string(w.class), json_string(w.workspace),
      w.current and "true" or "false"
    )
  end
  return string.format(
    '{"windows":[%s],"index":%d,"filter":%s,"mode":%s,"total":%d}',
    table.concat(rows, ","), jumpy.index - 1, json_string(jumpy.filter),
    json_string(jumpy.mode), #jumpy.windows
  )
end

local function redraw()
  send("show", payload())
end

-- Lifecycle ------------------------------------------------------------------

local poll -- created at the bottom, once the functions it calls exist

local function teardown()
  if not jumpy.active then return end
  jumpy.active = false
  jumpy.windows, jumpy.shown, jumpy.filter = {}, {}, ""
  if poll then poll:set_enabled(false) end
  hl.dispatch(hl.dsp.submap("reset"))
  send("hide")
end

local function commit()
  if not jumpy.active then return end
  local target = jumpy.shown[jumpy.index]
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

  jumpy.windows = windows
  jumpy.shown = windows
  jumpy.mode = mode
  jumpy.filter = ""
  jumpy.active = true
  jumpy.alt_down = true -- the bind that got us here needs Alt held
  jumpy.started = os.time()

  -- Entry 1 is where you are, so one tap lands on entry 2 and one back-tap
  -- wraps to the oldest.
  -- Entry 1 is where you are, so one tap lands on entry 2 and one back-tap
  -- wraps to the oldest.
  jumpy.index = delta % #jumpy.shown + 1

  hl.dispatch(hl.dsp.submap(SUBMAP))
  if poll then poll:set_enabled(true) end
  redraw()
end

local function step(delta, mode)
  if not jumpy.active then
    start(mode or "all", delta)
    return
  end
  if #jumpy.shown == 0 then return end
  jumpy.index = (jumpy.index - 1 + delta) % #jumpy.shown + 1
  redraw()
end

local function set_filter(text)
  jumpy.filter = text
  refilter()
  -- With no filter the list is back in recency order, where row 1 is the
  -- window you are on; the cursor goes to row 2, as it did at the start.
  jumpy.index = (text == "" and #jumpy.shown > 1) and 2 or 1
  redraw()
end

local function type_char(char)
  if jumpy.active then set_filter(jumpy.filter .. char) end
end

local function backspace()
  if not jumpy.active or jumpy.filter == "" then return end
  set_filter(jumpy.filter:sub(1, -2))
end

local function clear_filter()
  if jumpy.active and jumpy.filter ~= "" then set_filter("") end
end

local function close_selected()
  if not jumpy.active then return end
  local target = jumpy.shown[jumpy.index]
  if not target then return end

  local close = string.format('hl.dsp.window.close({ window = "address:%s" })', target.address)
  hl.exec_cmd("hyprctl dispatch " .. shell_quote(close))

  for i, w in ipairs(jumpy.windows) do
    if w.address == target.address then table.remove(jumpy.windows, i) break end
  end
  refilter()
  if #jumpy.shown == 0 and jumpy.filter == "" then
    teardown()
    return
  end
  if jumpy.index > #jumpy.shown then jumpy.index = math.max(1, #jumpy.shown) end
  redraw()
end

-- The panel's own watchdog calls this if it ever outlives a switch.
_G.__jumpy_cancel = teardown

-- The pointer, from the panel. Rows arrive zero-based. Hovering moves the
-- cursor (the panel has already drawn it, so there is nothing to send back);
-- a click switches to that window.
_G.__jumpy_point = function(row)
  if jumpy.active and row >= 0 and row < #jumpy.shown then jumpy.index = row + 1 end
end

_G.__jumpy_pick = function(row)
  if not jumpy.active or row < 0 or row >= #jumpy.shown then return end
  jumpy.index = row + 1
  commit()
end

-- Keys -----------------------------------------------------------------------

hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")
hl.unbind("ALT + ESCAPE")
hl.unbind("ALT + grave")
hl.bind("ALT + TAB", function() step(1) end, { description = "Jumpy: switch window" })
hl.bind("ALT + SHIFT + TAB", function() step(-1) end, { description = "Jumpy: switch window (reverse)" })
hl.bind("ALT + grave", function() step(1, "app") end, { description = "Jumpy: switch window of this app" })

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
  hl.bind("ALT + CTRL + j", function() step(1) end, { repeating = true })
  hl.bind("ALT + CTRL + k", function() step(-1) end, { repeating = true })
  hl.bind("ALT + CTRL + h", backspace, { repeating = true })
  hl.bind("ALT + CTRL + u", clear_filter)
  hl.bind("ALT + DELETE", close_selected)
  hl.bind("ALT + CTRL + w", close_selected)

  for code = string.byte("a"), string.byte("z") do
    local char = string.char(code)
    hl.bind("ALT + " .. char, function() type_char(char) end)
  end
  hl.bind("ALT + space", function() type_char(" ") end)
  hl.bind("ALT + minus", function() type_char("-") end)
  hl.bind("ALT + period", function() type_char(".") end)

  -- Everything else is swallowed while the list is up.
  hl.bind("catchall", hl.dsp.no_op())
end)

-- A release bind on a modifier only fires when it is tapped alone, and Tab in
-- between cancels it, so the raw key stream is read instead. This runs for
-- every key on the system: two compares unless a switch is up.
hl.on("input.keyboard.key", function(keycode, _, state)
  if not ALT_KEYCODES[keycode] then return end
  jumpy.alt_down = state ~= 0
  if state == 0 and jumpy.active then commit() end
end)

-- Belt and braces: if the release event is ever missed, or the list has been
-- up far too long, end the switch rather than hold the keyboard in the submap.
poll = hl.timer(function()
  if not jumpy.active then return end
  if not jumpy.alt_down then
    commit()
  elseif (os.time() - jumpy.started) * 1000 > TIMEOUT_MS then
    teardown()
  end
end, { timeout = 250, type = "repeat" })
poll:set_enabled(false)
