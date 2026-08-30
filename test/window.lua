-- test/window.lua — build and drive the PANEL with no game.
--
--   lua test/window.lua
--
-- ⚠️ WHY THIS EXISTS. Every other harness deliberately skips the window files,
-- on the reasoning that "stubbing enough of WoW's widget API would test the stub
-- rather than the addon". That reasoning holds for whether a pixel lands in the
-- right place — and it is exactly wrong for the failure that actually keeps
-- reaching the screen, which is a RUNTIME ERROR partway through a refresh. An
-- error inside Panel.Refresh aborts it silently: everything the refresh was
-- going to set stays blank, everything created at build time keeps drawing, and
-- the result is a window that looks half-designed rather than broken. That is
-- indistinguishable, at a glance, from an unfinished migration — which is how
-- one shipped to Jason twice.
--
-- So this stub is not trying to be a renderer. It answers one question: does the
-- panel BUILD and REFRESH without erroring, on every tab, in the states that
-- matter (no payload, payload loaded, no boss list). Anything it reports is a
-- real error in real code; anything it cannot see is a layout question, which is
-- what looking at the game is for.
--
-- ⚠️ IT MUST NOT SILENTLY SWALLOW A MISSING METHOD. A permissive stub that
-- returns a no-op for anything would answer "no error" to a panel calling
-- methods that do not exist in the client either. Unknown methods are RECORDED
-- and printed, so the run says what it had to invent.

package.path = "./?.lua;./test/?.lua;" .. package.path

local stub = require("wow-stub")
stub.Install()

-- ── A widget that answers like a frame ─────────────────────────────────────

local invented = {}      -- method name -> how many times the panel asked for it
local widgetMeta = {}

local function newWidget(kind, name, parent)
  local w = {
    _kind = kind, _name = name, _parent = parent,
    _shown = true, _text = nil, _children = {}, _points = {},
    _width = 100, _height = 20, _alpha = 1,
    events = {}, scripts = {},
  }
  return setmetatable(w, widgetMeta)
end

-- The methods with REAL behaviour, because the panel's own logic reads them
-- back: a width that is always 0 would make every measured control collapse,
-- and an IsShown that always answered true would hide the state machine this
-- harness exists to exercise.
local real = {}

function real.CreateTexture(self) local t = newWidget("Texture", nil, self)
  self._children[#self._children + 1] = t; return t end
function real.CreateFontString(self) local t = newWidget("FontString", nil, self)
  self._children[#self._children + 1] = t; return t end
function real.CreateMaskTexture(self) return real.CreateTexture(self) end

function real.SetText(self, s) self._text = (s ~= nil) and tostring(s) or nil end
function real.GetText(self) return self._text end
-- Roughly 6px per character at the sizes this panel uses. The exact number does
-- not matter; being NON-ZERO does, because FitToLabel and the chips size
-- themselves from it and treat 0 as "the font has not loaded yet".
function real.GetStringWidth(self)
  local s = self._text
  if not s or s == "" then return 0 end
  return #(s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) * 6
end
function real.SetFont(self, path, size) self._font, self._size = path, size; return true end

function real.Show(self) self._shown = true end
function real.Hide(self) self._shown = false end
function real.SetShown(self, v) self._shown = v and true or false end
function real.IsShown(self) return self._shown end
function real.IsVisible(self) return self._shown end

function real.SetWidth(self, w) self._width = w end
function real.SetHeight(self, h) self._height = h end
function real.SetSize(self, w, h) self._width, self._height = w, h end
function real.GetWidth(self) return self._width end
function real.GetHeight(self) return self._height end

function real.SetAlpha(self, a) self._alpha = a end
function real.GetAlpha(self) return self._alpha end

function real.SetPoint(self, ...) self._points[#self._points + 1] = { ... } end
function real.ClearAllPoints(self) self._points = {} end
function real.GetPoint(self) local p = self._points[1]; if p then return table.unpack(p) end end

function real.SetScript(self, which, fn) self.scripts[which] = fn end
function real.GetScript(self, which) return self.scripts[which] end
function real.HookScript(self, which, fn)
  local prev = self.scripts[which]
  self.scripts[which] = function(...) if prev then prev(...) end return fn(...) end
end
function real.RegisterEvent(self, e) self.events[e] = true end
function real.SetFontString(self, fs) self._fontString = fs end
function real.GetFontString(self) return self._fontString end
function real.GetObjectType(self) return self._kind end
function real.GetRegions(self) return table.unpack(self._children) end
function real.GetChildren(self) return table.unpack(self._children) end
function real.GetTexture(self) return self._texture end
function real.SetTexture(self, t) self._texture = t end
function real.GetName(self) return self._name end

widgetMeta.__index = function(self, key)
  local fn = real[key]
  if fn then return fn end
  -- ⚠️ ONLY METHOD-SHAPED NAMES ARE INVENTED, AND THIS IS LOAD-BEARING. A stub
  -- that answers EVERY unknown key with a function makes `if frame.bgTex then`
  -- true — so every guard the addon uses to ask "did I already paint this?"
  -- takes the wrong branch, and the harness reports a failure in code that is
  -- perfectly correct in the client. WoW's widget methods are CamelCase and the
  -- addon's own fields are lowercase, which is the line drawn here: an unknown
  -- FIELD answers nil, exactly as a real frame's would.
  if key:match("^%u") then
    invented[key] = (invented[key] or 0) + 1
    return function() end
  end
  return nil
end

local realCreateFrame = _G.CreateFrame
_G.CreateFrame = function(kind, name, parent)
  local f = newWidget(kind or "Frame", name, parent)
  if name then _G[name] = f end
  return f
end
_G.UIParent = newWidget("Frame", "UIParent")
-- Globals the window files reach for directly. Declared rather than invented on
-- demand, because a nil INDEX errors where a missing METHOD would not.
_G.StaticPopupDialogs = {}
_G.StaticPopup_Show = function() end
_G.StaticPopup_Hide = function() end
_G.ChatFontNormal = newWidget("Font", "ChatFontNormal")
_G.NORMAL_FONT_COLOR = { r = 1, g = 0.82, b = 0 }
_G.GameTooltip = newWidget("Frame", "GameTooltip")
_G.GameFontNormal = newWidget("Font", "GameFontNormal")

-- ── Load everything, windows included ──────────────────────────────────────

local ns = stub.LoadAddon({
  "LootData.lua", "Style.lua", "Scoring.lua", "Core.lua", "Settings.lua", "Payload.lua",
  "Diagnostics.lua", "Comms.lua", "Roster.lua", "Journal.lua", "Targets.lua",
  "Tooltip.lua", "Tip.lua", "Record.lua", "Loot.lua",
  "LoadWindow.lua", "RecordWindow.lua", "Panel.lua", "MinimapButton.lua",
})

local failures, checks = {}, 0
local function check(label, ok, detail)
  checks = checks + 1
  if not ok then failures[#failures + 1] = label .. (detail and ("  — " .. tostring(detail)) or "") end
  io.write(ok and "  ok   " or "  FAIL ", label, "\n")
  if not ok and detail then io.write("       ", tostring(detail), "\n") end
end

local function header(text)
  io.write("\n", ("─"):rep(72), "\n", text, "\n", ("─"):rep(72), "\n")
end

--- Run something that touches the panel and report the ERROR TEXT rather than
--- a boolean. "Refresh failed" is not a finding; the traceback is.
local function drive(label, fn)
  local ok, err = xpcall(fn, function(e)
    return tostring(e) .. "\n" .. debug.traceback("", 3)
  end)
  check(label, ok, not ok and err or nil)
  return ok
end

header("The panel builds and opens")

drive("Panel.Show() builds and refreshes without erroring", function()
  ns.Panel.Show()
end)

drive("a second refresh is clean", function() ns.Panel.Refresh() end)

header("Every tab refreshes")

-- Driven through the tab BUTTON's own click handler rather than a setter,
-- because there is no setter — and clicking is what a person does, so this
-- exercises the same path rather than a convenience door built for the test.
local panel = _G.HoDLootAdvisorPanel
check("the panel registered its global name", panel ~= nil)

for _, tab in ipairs({ "Loot", "Slots", "Standings", "Runner" }) do
  drive(("the %s tab refreshes"):format(tab), function()
    local b = panel and panel.tabs and panel.tabs[tab]
    if not b then error("no such tab: " .. tab) end
    b.scripts.OnClick(b)
  end)
end

header("The states that differ")

drive("scrolling the boss rail", function()
  ns.Panel.ScrollBosses(1); ns.Panel.ScrollBosses(-1)
end)
drive("scrolling the item column", function()
  ns.Panel.ScrollColumn(1); ns.Panel.ScrollColumn(-1)
end)

header("No window file reads a constant that was deleted")

-- ⚠️ THE CLASS OF BUG THIS HARNESS WAS WRITTEN FOR. Deleting a `local FOO`
-- while a use of FOO survives is not a syntax error and not a load error: the
-- surviving read silently becomes a GLOBAL, globals are nil, and nil only
-- complains when something does arithmetic on it — which may be one branch
-- nobody takes for weeks. Session 257 shipped exactly this (TOG_ROW, removed
-- with the filter pills, still read three times), and it aborted the panel's
-- build partway through: everything above the line drew, everything below it
-- never existed, and the window looked like an unfinished redesign rather than
-- a crash.
--
-- SCREAMING_CASE only, deliberately. Those are this project's geometry and
-- table constants — always file-locals, never legitimately global — so a read
-- of one that the file does not declare is always this bug. Lowercase globals
-- are the WoW API and the addon's own namespace, which are supposed to be
-- global, and flagging them would drown the signal.
local WOW_GLOBALS = {
  GameTooltip = true, UIParent = true, GameFontNormal = true,
  NORMAL_FONT_COLOR = true, StaticPopupDialogs = true, ChatFontNormal = true,
}

--- Every identifier a chunk READS as a bare global, in SCREAMING_CASE.
--- Three things are deliberately NOT reads and are skipped, because each would
--- otherwise drown the signal:
---   · a FIELD  (`Style.COLOR`, `row.TEXT_KEYS`) — preceded by . or :
---   · a KEY or an ASSIGNMENT (`AUTO = "Auto"`) — followed by a single =
---   · anything declared `local` anywhere in the file
local function undeclaredConstants(src)
  -- Comments and strings first, so a constant NAMED in prose is not a use.
  local code = src:gsub("%-%-%[%[.-%]%]", " "):gsub("%-%-[^\n]*", " ")
                  :gsub('"[^"\n]*"', '""'):gsub("'[^'\n]*'", "''")

  local declared = {}
  for names in code:gmatch("local%s+([^=\n]+)=") do
    for name in names:gmatch("[%a_][%w_]*") do declared[name] = true end
  end
  for names in code:gmatch("for%s+([^=\n]+)=") do
    for name in names:gmatch("[%a_][%w_]*") do declared[name] = true end
  end
  for names in code:gmatch("function%s*%b()") do
    for name in names:gmatch("[%a_][%w_]*") do declared[name] = true end
  end

  local out, seen = {}, {}
  local pos = 1
  while true do
    local s, e, name = code:find("([%a_][%w_]*)", pos)
    if not s then break end
    pos = e + 1
    local isConst = #name >= 3 and name == name:upper() and name:match("^[%u_]")
    if isConst and not declared[name] and not WOW_GLOBALS[name] and not seen[name] then
      local before = code:sub(math.max(1, s - 1), s - 1)
      local after = code:sub(e + 1):match("^%s*(=?=?)")
      local isField = (before == "." or before == ":")
      local isAssign = (after == "=")          -- a lone = ; == is a comparison
      if not isField and not isAssign then
        seen[name] = true
        out[#out + 1] = name
      end
    end
  end
  return out
end

for _, file in ipairs({ "Panel.lua", "LoadWindow.lua", "RecordWindow.lua",
                        "Settings.lua", "Tip.lua", "MinimapButton.lua" }) do
  local src = assert(io.open(file)):read("a")
  local missing = undeclaredConstants(src)
  check(("%s reads no constant it does not declare"):format(file),
        #missing == 0, #missing > 0 and table.concat(missing, ", ") or nil)
end

-- ── Report ─────────────────────────────────────────────────────────────────

local names = {}
for k, v in pairs(invented) do names[#names + 1] = ("%s (%d)"):format(k, v) end
table.sort(names)
if #names > 0 then
  header("Widget methods this stub had to invent")
  io.write("  ", table.concat(names, ", "), "\n")
  io.write("\n  These answered as no-ops. Any one of them could be hiding a\n")
  io.write("  real call the client would refuse — check a new name before\n")
  io.write("  trusting a pass that depends on it.\n")
end

io.write("\n", ("═"):rep(72), "\n")
if #failures == 0 then
  io.write(("PASS — %d checks\n"):format(checks))
else
  io.write(("FAIL — %d of %d checks\n\n"):format(#failures, checks))
  for _, f in ipairs(failures) do io.write("  · ", f, "\n") end
  os.exit(1)
end
