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

-- Scale is real state here: Panel.ApplyScale multiplies onto a remembered
-- baseline, and a stub that answered nil would make that arithmetic untestable
-- — which it was, and the block below died silently for exactly that reason.
function real.SetScale(self, s) self._scale = s end
function real.GetScale(self) return self._scale or 1 end
function real.GetEffectiveScale(self) return self:GetScale() end

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
-- ⚠️ THE SAME STRICTNESS THE BASE STUB HAS. It refuses an event name the client
-- does not define, which is how a typo'd registration gets caught rather than
-- silently never firing. Dropping that check here would make this harness more
-- permissive than the one it sits beside.
function real.RegisterEvent(self, e)
  if stub.KNOWN_EVENTS and not stub.KNOWN_EVENTS[e] then
    error("Attempt to register unknown event '" .. tostring(e) .. "'", 2)
  end
  self.events[e] = true
end
function real.SetFontString(self, fs) self._fontString = fs end
function real.GetFontString(self) return self._fontString end
function real.GetObjectType(self) return self._kind end
function real.GetRegions(self) return table.unpack(self._children) end
function real.GetChildren(self) return table.unpack(self._children) end
function real.GetTexture(self) return self._texture end
-- Recorded rather than invented, so a test can actually READ what a rim was
-- painted. Colour is the one property here worth observing: a gradient with its
-- stops the wrong way round is invisible to every other check and costs a
-- screenshot round-trip to find.
function real.SetColorTexture(self, r, g, b, a) self._color = { r, g, b, a or 1 } end
function real.SetGradient(self, orientation, c1, c2)
  self._gradient = { orientation = orientation, from = c1, to = c2 }
end
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

_G.CreateFrame = function(kind, name, parent)
  local f = newWidget(kind or "Frame", name, parent)
  -- ⚠️ REGISTERED WITH THE BASE STUB'S DISPATCHER. stub.Fire walks stub.frames,
  -- so a widget created here and not added to it can never RECEIVE an event —
  -- which meant ADDON_LOADED never reached Core, ns.db was never set, and every
  -- call into Settings died on a nil field. The frames looked fine; they were
  -- simply not listening.
  stub.frames[#stub.frames + 1] = f
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
-- The minimap button anchors to Minimap and reads its scale; without it the
-- login sequence dies before Settings is ever initialised.
_G.Minimap = newWidget("Frame", "Minimap")
_G.GameTooltip = newWidget("Frame", "GameTooltip")
_G.GameFontNormal = newWidget("Font", "GameFontNormal")
-- CreateColor returns the table SetGradient is handed, so a test can compare
-- the stops it was actually given.
_G.CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 1 } end

-- ── Load everything, windows included ──────────────────────────────────────

local ns = stub.LoadAddon({
  "LootData.lua", "Style.lua", "Scoring.lua", "Core.lua", "Settings.lua", "Payload.lua",
  "Diagnostics.lua", "Comms.lua", "Roster.lua", "Journal.lua", "Targets.lua",
  "Tooltip.lua", "Tip.lua", "Record.lua", "Loot.lua",
  "LoadWindow.lua", "RecordWindow.lua", "Panel.lua", "MinimapButton.lua",
})

-- ⚠️ THE LOGIN SEQUENCE, NOT JUST THE LOAD. Settings keeps its values in the
-- SavedVariables table that ADDON_LOADED creates, so without this every call
-- into it dies on a nil field — which is exactly how the size checks below
-- failed the first time, inside a header with no visible error.
stub.Fire("ADDON_LOADED", "HoDLootAdvisor")
stub.Fire("PLAYER_ENTERING_WORLD", true, false)

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

-- One scroll, because the column is one list: boss rows and the expanded boss's
-- cards share it. Driven well past the end and back, since the clamp has to
-- measure from the end over two different entry heights.
drive("scrolling the column, including past both ends", function()
  for _ = 1, 30 do ns.Panel.ScrollColumn(1) end
  for _ = 1, 60 do ns.Panel.ScrollColumn(-1) end
end)

-- ⚠️ THE OPENING STATE IS COLLAPSED (Jason). Asserted rather than assumed,
-- because the panel used to expand the first boss and that cost four rows of
-- the list it exists to show.
do
  local panel = _G.HoDLootAdvisorPanel
  ns.Panel.Show()
  -- ⚠️ READ FROM THE RULE, NOT A FILL. An expanded boss row has NO background
  -- in the mock — the row says it is open by DROPPING its bottom rule, which is
  -- what joins it to the loot beneath. A fill was invented here for one round
  -- and this check was written against it, so the check has to move with it.
  local function isExpanded(tile)
    return tile:IsShown() and tile.rule and not tile.rule:IsShown()
  end

  local expanded = 0
  for _, tile in ipairs(panel.bossTiles or {}) do
    if isExpanded(tile) then expanded = expanded + 1 end
  end
  check("the panel opens with no boss expanded", expanded == 0, expanded)

  -- And a second click on the open boss closes it again, or the collapsed state
  -- is reachable only by shutting the window.
  local first = panel.bossTiles and panel.bossTiles[1]
  if first and first.scripts.OnClick then
    first.scripts.OnClick(first)
    local opened = isExpanded(first)
    first.scripts.OnClick(first)
    local closed = not isExpanded(first)
    check("clicking a boss expands it", opened == true)
    check("...and clicking it again collapses it", closed == true)
    -- And no boss row is ever filled, in either state.
    local filled = false
    for _, tile in ipairs(panel.bossTiles or {}) do
      if tile.sel then filled = true end
    end
    check("no boss row carries a background fill in any state", filled == false)
  end
end

drive("selecting each boss in turn expands its loot without erroring", function()
  local panel = _G.HoDLootAdvisorPanel
  for _, tile in ipairs(panel.bossTiles or {}) do
    if tile.scripts.OnClick and tile.bossIndex then tile.scripts.OnClick(tile) end
  end
end)

header("The control rim is the gradient the design asks for")

-- ⚠️ ORIENTATION IS THE WHOLE RISK HERE. WoW's SetGradient puts its FIRST
-- colour at the BOTTOM, which is the opposite of how the design reads
-- ("#6f2b57 on top, #ac7666 on bottom") — so a faithful-looking call can be
-- upside down and nothing but a screenshot would say so.
do
  local S = ns.Style
  local host = _G.CreateFrame("Frame")
  local rim = S.Rim(host, S.COLOR.controlRim, 1, 1, S.COLOR.rule)

  local function near(c, want)
    return c and math.abs(c[1] - want.r) < 0.01 and math.abs(c[2] - want.g) < 0.01
  end
  check("the top edge takes the TOP stop", near(rim.top._color, S.COLOR.controlRim),
        rim.top._color and table.concat(rim.top._color, ","))
  check("the bottom edge takes the BOTTOM stop", near(rim.bottom._color, S.COLOR.rule),
        rim.bottom._color and table.concat(rim.bottom._color, ","))

  -- ⚠️ THE BASE UNDER A RAMP MUST BE WHITE. WoW MULTIPLIES a gradient into the
  -- texture's own colour, so a side painted its own hex and then given a ramp
  -- comes out a dark constant — which is what shipped, and what made the border
  -- read as three flat colours instead of one transition.
  local base = rim.left._color
  check("a gradient side is painted WHITE before the ramp, never its own colour",
        base and base[1] == 1 and base[2] == 1 and base[3] == 1,
        base and table.concat(base, ","))

  local g = rim.left._gradient
  check("the side edges carry a vertical ramp", g ~= nil and g.orientation == "VERTICAL")
  check("...whose first stop is the BOTTOM colour, as WoW orders them",
        g and g.from and math.abs(g.from.r - S.COLOR.rule.r) < 0.01,
        g and g.from and ("%.2f"):format(g.from.r))
  check("...and whose second is the TOP colour",
        g and g.to and math.abs(g.to.r - S.COLOR.controlRim.r) < 0.01)

  -- A flat rim must stay flat: an ACTIVE tab is filled and borderless in the
  -- mock, and a gradient left on it would outline the one control that has none.
  local flat = S.Rim(_G.CreateFrame("Frame"), S.COLOR.control, 1)
  check("a rim asked for one colour draws no ramp", flat.left._gradient == nil)
end

header("Panel size is a knob, and it compounds from one baseline")

drive("the panel size knob behaves", function()
  local panel = _G.HoDLootAdvisorPanel
  local base = panel._baseScale or 1
  ns.Settings.Set("panelScale", 80)
  ns.Panel.ApplyScale()
  local at80 = panel:GetScale()
  ns.Settings.Set("panelScale", 120)
  ns.Panel.ApplyScale()
  local at120 = panel:GetScale()
  ns.Settings.Set("panelScale", 100)
  ns.Panel.ApplyScale()
  local at100 = panel:GetScale()

  check("80% is smaller than 100%", at80 < at100, ("%.3f vs %.3f"):format(at80, at100))
  check("120% is larger than 100%", at120 > at100)
  -- ⚠️ THE BASELINE MUST NOT DRIFT. Applying 80 then 120 then 100 has to land
  -- back exactly where it started; multiplying each change onto the CURRENT
  -- scale rather than a remembered baseline would compound and shrink the
  -- window a little every time the setting was touched.
  check("returning to 100% lands exactly back on the baseline",
        math.abs(at100 - base) < 1e-9, ("%.6f vs %.6f"):format(at100, base))

  -- ⚠️ THE APPLY HOOK IS WHAT MAKES THE SLIDER LIVE. Settings.Set runs it, so a
  -- value stored by ANY route — the slider, a slash command, a restored
  -- SavedVariable — resizes the window. Without it the setting would take
  -- effect only on the next open, which is unusable for a control you judge by
  -- looking at the thing it changes.
  ns.Settings.Set("panelScale", 70)
  check("setting the size applies it immediately, without reopening",
        math.abs(panel:GetScale() - base * 0.7) < 1e-9,
        ("%.4f vs %.4f"):format(panel:GetScale(), base * 0.7))

  -- Out-of-range values are clamped rather than obeyed: a 0 would make the
  -- window disappear with no way to reach the setting that did it.
  ns.Settings.Set("panelScale", 0)
  ns.Panel.ApplyScale()
  check("a nonsense size is clamped, never applied", panel:GetScale() >= base * 0.5 - 1e-9)
  ns.Settings.Set("panelScale", 100)
  ns.Panel.ApplyScale()
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

header("The Slots page (Session 258)")

-- Everything here drives the REAL widgets, because the whole reason this
-- harness exists is that a runtime error inside a renderer reaches the game
-- otherwise. The pure logic behind it is asserted in smoke.lua instead.
do
  local slots = panel and panel.tabs and panel.tabs.Slots
  if slots then drive("opening Slots", function() slots.scripts.OnClick(slots) end) end

  local rows = panel and panel.slotRows
  check("the rail has a row for every loot-bearing slot", rows and #rows == 14,
        rows and #rows or "no rail")

  -- Read off the mock, in its order. A rail that silently reorders itself is
  -- the kind of thing only a person notices, and only much later.
  if rows then
    local want = { "Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands",
                   "Waist", "Legs", "Feet", "Finger", "Trinket", "Main Hand", "Off Hand" }
    local bad
    for i, label in ipairs(want) do
      local got = rows[i] and rows[i].label and rows[i].label._text
      if got ~= label then bad = ("row %d: %s, wanted %s"):format(i, tostring(got), label) end
    end
    check("the rail's rows are the mock's, in the mock's order", bad == nil, bad)

    -- ⚠️ THE LAST ROW MEASURES 26 BECAUSE IT DROPS ITS RULE, which is the same
    -- one-pixel tell the boss rows and the item cards use. Asserting the height
    -- alone would pass with the rule still drawn.
    local h = rows[14] and rows[14]:GetHeight()
    check("the last row is 26 and has no rule", h == 26 and rows[14].rule == nil,
          ("height %s, rule %s"):format(tostring(h), tostring(rows[14] and rows[14].rule)))
    check("every other row is 29 with a rule",
          rows[1]:GetHeight() == 29 and rows[1].rule ~= nil)
  end

  -- Selecting a row is what the page is FOR, and it is the path that re-renders
  -- the whole right-hand region — so it is driven through the click handler.
  drive("clicking every rail row renders that slot", function()
    for i = 1, #(panel.slotRows or {}) do
      panel.slotRows[i].scripts.OnClick(panel.slotRows[i])
    end
  end)

  check("the selected row is the one that is filled",
        panel.slotRows and panel.slotRows[14].bg:IsShown()
          and not panel.slotRows[1].bg:IsShown())

  -- All three views, through the menu items a person actually clicks.
  drive("switching to each of the three BIS views", function()
    for i = 1, #(panel.slotMenuItems or {}) do
      panel.slotMenuItems[i].scripts.OnClick(panel.slotMenuItems[i])
    end
  end)

  -- ⚠️ THE SINGLE-ITEM LAYOUT HAS TO BE STAGED, AND FINDING THAT OUT IS WHY
  -- THIS BLOCK EXISTS (Session 258). The first version of these checks passed
  -- with the OBTAINED BY panel never once drawn: 232 BIS items are absent from
  -- our payload, so their slot comes from the client, and the stub answered
  -- nothing — every tier piece was dropped before it reached a row. The
  -- "never both layouts" check below was therefore only ever testing the list.
  --
  -- So the tier piece is DERIVED from the payload rather than hardcoded: find
  -- an item that catalyses into something, and that something is a piece which
  -- does not drop. Staging its equip location is what the real client would
  -- answer, and is the one thing the harness cannot know on its own.
  local staged, stagedSlot
  do
    local data = ns.Data()
    local char = ns.ResolveCharacter()
    if data and data.rankings and char then
      for srcID in pairs(data.rankings) do
        local q = ns.Scoring.resolveQuality(data.rankings, srcID,
          char.className, char.specName, char.heroTree, nil)
        if q and q.catalysesInto and not staged then
          staged = q.catalysesInto
          -- Hands, because that is the slot the mock draws this state for.
          stagedSlot = "HANDS"
          stub.itemEquipLoc[staged] = "INVTYPE_HAND"
        end
      end
    end
  end
  check("the payload carries a catalyse pointer to stage the tier-piece case",
        staged ~= nil, "no ranking for this character names a catalyse target")

  if staged then
    drive("the single-item layout renders", function()
      ns.Panel.Refresh()
      for i, r in ipairs(ns.SLOT_ROWS) do
        if r.key == stagedSlot then
          panel.slotRows[i].scripts.OnClick(panel.slotRows[i])
        end
      end
    end)
    check("...and it is the OBTAINED BY panel, not the list",
          panel.slotPanel:IsShown() and not panel.slotList:IsShown(),
          ("panel=%s list=%s"):format(tostring(panel.slotPanel:IsShown()),
                                      tostring(panel.slotList:IsShown())))
    -- A panel with a heading and no routes is the half-drawn box the whole
    -- layout choice exists to avoid.
    check("...with at least one route drawn",
          panel.slotRoutes and panel.slotRoutes[1]:IsShown())
    check("...and the panel is as tall as the routes it holds",
          panel.slotPanel:GetHeight() >= 101,
          panel.slotPanel:GetHeight())
  end

  -- ⚠️ EXACTLY ONE LAYOUT IS EVER ON SCREEN. Both being shown would draw the
  -- OBTAINED BY panel straight through the candidate list, which is precisely
  -- the class of fault this file was added to catch. Only meaningful now that
  -- both branches are reachable — see the staging above.
  local bothOff, bothOn, sawSingle = false, false, false
  for i = 1, #(panel.slotRows or {}) do
    panel.slotRows[i].scripts.OnClick(panel.slotRows[i])
    local single, list = panel.slotPanel:IsShown(), panel.slotList:IsShown()
    if single and list then bothOn = true end
    if not single and not list then bothOff = true end
    if single then sawSingle = true end
  end
  check("never both layouts at once, and never neither", not bothOn and not bothOff,
        ("bothOn=%s bothOff=%s"):format(tostring(bothOn), tostring(bothOff)))
  -- The guard against this check going quiet again: if no slot takes the single
  -- branch, the line above proves only half of what it claims.
  check("...and the sweep actually reached both layouts", sawSingle)

  -- Leaving the tab must take the page's furniture with it.
  local loot = panel.tabs and panel.tabs.Loot
  if loot then
    drive("leaving Slots", function() loot.scripts.OnClick(loot) end)
    check("the rail does not draw over another tab", not panel.slotRail:IsShown())
    check("neither Slots layout draws over another tab",
          not panel.slotPanel:IsShown() and not panel.slotList:IsShown())
  end
end


header("The Standings page, re-read from its node (Session 258)")

-- ⚠️ THESE ARE GEOMETRY ASSERTIONS AND THAT IS DELIBERATE. This tab was built
-- against the pre-redesign window and never re-read when the frame grew, so
-- every position was quietly wrong while the tab "worked". Pinning the node's
-- own numbers is what turns that from something only a screenshot can catch
-- into something the suite catches.
do
  local st = panel and panel.tabs and panel.tabs.Standings
  if st then drive("opening Standings", function() st.scripts.OnClick(st) end) end

  check("the rail has four blocks", panel.rail and #panel.rail == 4)
  if panel.rail then
    -- Each block is a FILLED surface now, not four loose lines on the ground.
    local box = panel.rail[1].box
    check("a rail block is a 150-wide surface at the window's own margin",
          box and box:GetWidth() == 150, box and box:GetWidth())
    check("the blocks are 86 / 78 / 86 / 86 tall",
          panel.rail[1].box:GetHeight() == 86 and panel.rail[2].box:GetHeight() == 78
            and panel.rail[3].box:GetHeight() == 86 and panel.rail[4].box:GetHeight() == 86)
    -- The whole block hides as one, which is what stops a stray line drawing
    -- over another tab when someone adds a fifth fontstring.
    check("hiding the rail is one call per block", panel.rail[1].box.SetShown ~= nil)
  end

  -- The vertical hairline is gone; the filled blocks are the separator.
  check("there is no rail divider any more", panel.stDiv == nil)

  check("the table shows more rows than the mock's twelve sample rows",
        panel.stRows and #panel.stRows >= 17, panel.stRows and #panel.stRows)

  drive("the standings table renders", function() ns.Panel.Refresh() end)

  local loot = panel.tabs and panel.tabs.Loot
  if loot then
    drive("leaving Standings", function() loot.scripts.OnClick(loot) end)
    check("no rail block draws over another tab",
          panel.rail and not panel.rail[1].box:IsShown())
  end
end

header("Disable Roster Import / EPGP System (Session 258)")

-- The one row the Settings mock draws that the code did not have. Everything it
-- switches off is EPGP machinery; the scoring half must be untouched, which is
-- what the last check here is for.
do
  check("the setting exists", ns.Settings.Get("noRoster") == false)

  -- ⚠️ A PAYLOAD HAS TO BE LOADED FOR THE STANDINGS HALF TO MEAN ANYTHING, and
  -- finding that out is why this staging exists. Standings already hides when
  -- nothing is imported (the S254 rule), so without a payload the check
  -- "Standings is hidden" passes whether the new gate is there or not — it did,
  -- on the first revert-check, while the footer half correctly went red.
  local loaded = false
  do
    local fh = io.open("test/payload.txt", "r")
    if fh then
      local encoded = (fh:read("a") or ""):gsub("%s+$", "")
      fh:close()
      local data = ns.Payload.Decode(encoded)
      if data then
        ns.Payload.Store(data, encoded, "test")
        loaded = ns.Payload.Current() ~= nil
      end
    end
  end
  check("a raid payload is loaded, so the Standings gate is testable", loaded,
        "without one, Standings hides anyway and the gate below proves nothing")

  -- With it OFF, the Import button is part of the footer.
  ns.Settings.Set("noRoster", "off")
  ns.Panel.Refresh()
  check("Import Roster Data is shown by default", panel.load:IsShown())
  check("...and Standings is available with a payload loaded",
        panel.tabs.Standings:IsShown())

  ns.Settings.Set("noRoster", "on")
  ns.Panel.Refresh()
  check("...and hidden once the box is checked", not panel.load:IsShown())
  check("...as is the Standings tab", not panel.tabs.Standings:IsShown())

  -- ⚠️ THE POINT OF THE SETTING IS THAT SCORING SURVIVES IT. If this ever goes
  -- red, the switch has grown past what it was for.
  local rep = ns.SlotsReport("overall")
  check("...but BIS scoring still answers", rep.ready == true)

  -- Put it back, so nothing downstream inherits a switched-off addon.
  ns.Settings.Set("noRoster", "off")
  ns.Panel.Refresh()
  check("...and turning it off restores the footer", panel.load:IsShown())
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
