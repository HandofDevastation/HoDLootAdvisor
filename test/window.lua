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

-- Every fontstring ever created, so a check can sweep what is ON SCREEN without
-- walking the frame tree — CreateFrame does not record children, and the string
-- that goes unpainted is exactly the one nobody thought to look at.
local allText = {}

local function newWidget(kind, name, parent)
  local w = {
    _kind = kind, _name = name, _parent = parent,
    _shown = true, _text = nil, _children = {}, _points = {},
    _width = 100, _height = 20, _alpha = 1,
    events = {}, scripts = {},
  }
  setmetatable(w, widgetMeta)
  if kind == "FontString" then allText[#allText + 1] = w end
  return w
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

--- Is this region actually on screen — it AND every ancestor shown?
local function visibleChain(w)
  local n = w
  while n do
    if not n._shown then return false end
    n = n._parent
  end
  return true
end


-- ⚠️ THE STUB NOW MODELS WHETHER A STRING ACTUALLY PAINTED (Session 260), and
-- until it did, this harness could not see the single most common defect in
-- either of these addons.
--
-- The client's rule, measured in Session 254 and written up in Core §1.1: a
-- fontstring redraws only when the string it is handed DIFFERS from the one it
-- holds, and a draw that happens while the region is off screen does not take.
-- Together those mean a first paint into a hidden widget is PERMANENT — the
-- string is stored, every getter reports it correctly, and nothing is rendered.
--
-- The old double stored the string and answered every question about it
-- happily, so it was quieter than the runtime in exactly the S257 sense: it
-- reported green on code the client draws blank. Jason opened the Slots page
-- and found three blanks that 118 passing checks had nothing to say about.
--
-- ⚠️ IT RECORDS THE CONDITIONS OF THE WRITE, NOT A THEORY OF THE RENDERER.
-- A first attempt had SetText decide whether the string would PAINT, and swept
-- every label in the panel. It indicted the footer buttons, the close X and the
-- header's "BIS" — all of which Jason's own screenshots show rendering
-- perfectly. Five contradictions out of six hits means the rule as stated was
-- wrong, not that the addon had five more bugs (Core §1.1: an implausible
-- result is evidence of a misreading). Narrowing it by "was this widget ever
-- hidden" did not help either, because CLOSING the panel hides the root and so
-- marks every descendant.
--
-- So this stub claims nothing about what the client draws. It records two
-- facts — was the region on screen when the string was written, and did the
-- string CHANGE — and the assertion below applies them only to the recycled
-- rows of the Slots page, named explicitly. Those two conditions are the whole
-- content of the Session 254 rule, and they are what the fix has to satisfy.
function real.SetText(self, s)
  local v = (s ~= nil) and tostring(s) or nil
  self._writeChanged = (v ~= self._text)
  self._writeVisible = visibleChain(self)
  self._text = v
end
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
-- ⚠️ RECORDED, NOT SWALLOWED (Session 262). This was answering as a no-op, so
-- the suite could read a fontstring's SIZE and WEIGHT but never its COLOUR —
-- and colour is half of what the refresh changed. A blush name where the node
-- says white passed 250 checks.
function real.SetTextColor(self, r, g, b, a) self._textColor = { r, g, b, a or 1 } end

-- ⚠️ WRAPPING IS MODELLED, BECAUSE THE ADDON LAYS OUT FROM IT (Session 258).
-- The Settings window re-flows its rows from GetStringHeight, and a stub that
-- answered nil made every row one line tall — so the overlap check written to
-- catch rows colliding measured nothing and passed with the fix reverted.
--
-- The arithmetic is deliberately crude and only has to be MONOTONIC: a longer
-- sentence in a narrower column must come back taller. Line height is the font
-- size plus leading, matching how the real client stacks wrapped lines closely
-- enough for a layout assertion.
function real.GetStringHeight(self)
  local s = self._text
  if not s or s == "" then return 0 end
  local size = self._size or 12
  local lineH = size + 4
  local w = self:GetWidth() or 0
  if w <= 0 or not self._wordWrap then return lineH end
  local textW = self:GetStringWidth()
  return math.max(1, math.ceil(textW / w)) * lineH
end
function real.SetWordWrap(self, on) self._wordWrap = on and true or false end

-- ⚠️ Show AND Hide FIRE THEIR SCRIPTS, BECAUSE THE CLIENT'S DO (Session 258).
-- Without this the stub is quieter than the runtime in a way that hides real
-- behaviour rather than real errors: ns.TrackWindow hooks OnShow/OnHide to keep
-- the window stack that Escape walks, so every window opened in the harness was
-- invisible to it and the stack was permanently empty. The addon was correct;
-- the double simply never told it anything had opened.
--
-- Guarded against re-entry: a handler that hides its own frame would otherwise
-- recurse, and OnHide legitimately does that in a couple of places.
local function fire(self, which)
  local fn = self.scripts and self.scripts[which]
  if not fn or self._firing then return end
  self._firing = true
  local ok, err = pcall(fn, self)
  self._firing = false
  if not ok then error(err, 0) end
end

function real.Show(self)
  local was = self._shown
  self._shown = true
  if not was then fire(self, "OnShow") end
end
function real.Hide(self)
  local was = self._shown
  self._shown = false
  -- Marks this widget as RECYCLED — see the _painted note above SetText for why
  -- the paint assertion is scoped to recycled widgets and not to every label.
  self._everHidden = true
  if was then fire(self, "OnHide") end
end
function real.SetShown(self, v)
  if v then real.Show(self) else real.Hide(self) end
end
function real.IsShown(self) return self._shown end
function real.IsVisible(self) return self._shown end

function real.SetWidth(self, w) self._width = w end
-- ⚠️ RECORDS THAT IT WAS CALLED, NOT JUST THE VALUE (Session 259). Widgets
-- default to _height = 20, which happens to equal the ranking row's pitch — so a
-- check reading GetHeight() == 20 passed whether the addon set a height or not,
-- and the revert-check for a real alignment fix came back green. A default that
-- collides with a value under test makes the test unfalsifiable.
function real.SetHeight(self, h) self._height = h; self._heightSet = true end
-- Recorded rather than invented: vertical justification is half of what makes a
-- cell centre in its row, and a no-op here cannot tell the two apart.
function real.SetJustifyV(self, v) self._justifyV = v end
-- Both were no-ops, for the same reason SetTextColor was: the suite could see
-- where a thing sat but not what colour it was or which way it read.
function real.SetJustifyH(self, h) self._justifyH = h end
function real.SetVertexColor(self, r, g, b, a) self._vertex = { r, g, b, a or 1 } end
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
function real.GetPoint(self) local p = self._points[1]; if p then return (table.unpack or unpack)(p) end end

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
function real.GetRegions(self) return (table.unpack or unpack)(self._children) end
function real.GetChildren(self) return (table.unpack or unpack)(self._children) end
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
-- Recorded rather than invented: the item icon's crop is what hides the border
-- baked into every WoW icon, and a no-op here would make a test for it pass
-- whether the call happened or not.
function real.SetTexCoord(self, l, r, t, b) self._texCoord = { l, r, t, b } end
function real.AddMaskTexture(self, m) self._masks = (self._masks or 0) + 1 end
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
-- ⚠️ RECORDING, NOT INVENTED (Session 259). SetHyperlink fell through to the
-- invented-method path, so it answered a no-op and a hover test could only ever
-- prove that nothing ERRORED — which is the exact claim Core §1.1's "A GREEN
-- HARNESS IS NOT A LIKENESS" says is not the job. These four are methods the
-- client really has; recording what they were HANDED is what lets a check assert
-- that the tooltip opened on the right item.
_G.GameTooltip = newWidget("Frame", "GameTooltip")
_G.GameTooltip.calls = { owner = nil, link = nil, lines = {}, shown = false }
function _G.GameTooltip:SetOwner(o, anchor)
  self.calls.owner, self.calls.anchor = o, anchor
  self.calls.link, self.calls.lines = nil, {}
end
function _G.GameTooltip:SetHyperlink(link) self.calls.link = link end
function _G.GameTooltip:AddLine(t) self.calls.lines[#self.calls.lines + 1] = t end
function _G.GameTooltip:Show() self.calls.shown = true; real.Show(self) end
function _G.GameTooltip:Hide() self.calls.shown = false; real.Hide(self) end
_G.GameFontNormal = newWidget("Font", "GameFontNormal")
-- ⚠️ DECLARED, BECAUSE ITS ABSENCE WAS INVISIBLE (Session 259). The icon fill
-- falls back to a question mark when the client cannot answer, so with no
-- GetItemIcon at all the harness took the FALLBACK path on every row and a
-- check reading "the icon was given a texture" passed without once exercising
-- the real one. A stub quieter than the client reports green on code it never
-- ran. The client has this; so does the double, and the checks now assert the
-- texture is NOT the fallback.
_G.GetItemIcon = function(itemID)
  if not itemID then return nil end
  return ("Interface\\Icons\\stub_%d"):format(itemID)
end
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
    -- ⚠️ THE NODE'S ARITHMETIC, NOT ">= SOMETHING" (Session 259). The old form
    -- was ">= 101", which passed for a panel of any height above a floor — so
    -- the 20px block gap being wrong by half went unseen. Node 590:2055 is 137
    -- tall for two routes: 14 above the heading, a 19 heading, 10, then 32-per
    -- route with 10 between, then 20 below. (A route is 32 rather than 30
    -- because it carries a 32px item icon now — Session 262.)
    local shown = 0
    for _, r in ipairs(panel.slotRoutes or {}) do if r:IsShown() then shown = shown + 1 end end
    local wantH = 14 + 19 + 10 + shown * 32 + math.max(0, shown - 1) * 10 + 20
    check("...and the panel is exactly as tall as the routes it holds",
          panel.slotPanel:GetHeight() == wantH,
          ("%s routes: got %s, node says %s"):format(shown,
            panel.slotPanel:GetHeight(), wantH))
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

  -- ── Hovering a BIS name opens the game's item card (Session 259) ─────────
  --
  -- ⚠️ ASSERT THE VALUE, NOT THE ABSENCE OF AN ERROR. Firing OnEnter and
  -- checking it did not throw would pass with SetHyperlink never called at all,
  -- which is the whole of Core §1.1's "A GREEN HARNESS IS NOT A LIKENESS". So
  -- these read back WHICH link the tooltip was handed and WHERE the hit area
  -- actually sits.
  -- The link a catalogue row is expected to tooltip with. Mirrors
  -- ITEM.CatalogueLink, which is panel-local: raid loot at Mythic, everything
  -- else at the fixed M+ drop. Derived from the payload rather than hardcoded,
  -- so it cannot go stale against a new season's data.
  local function catalogueLink(itemID)
    -- ⚠️ THE SOURCE'S STATED IDS COME FIRST, and this mirror has to say so. It
    -- did not, and both hover checks went red the moment the payload started
    -- carrying them — the TEST was stale, not the panel. Worth keeping as a
    -- note: a mirror of production logic is a second implementation, and it
    -- drifts exactly like any other.
    local me = ns.ResolveCharacter()
    local stated = me and ns.BisItemLink(itemID, me.className, me.specName, me.heroTree)
    if stated then return stated end
    local data = ns.Data()
    if data and (data.items or {})[itemID] then
      return ns.RaidItemLink(itemID, "m") or ns.ItemLinkFor(itemID, "m")
    end
    return ns.MplusItemLink(itemID)
  end

  do
    -- Land on a slot that draws the LIST, since that is the common case.
    local listRow
    for i = 1, #(panel.slotRows or {}) do
      panel.slotRows[i].scripts.OnClick(panel.slotRows[i])
      if panel.slotList:IsShown() and panel.slotListRows[1]:IsShown() then
        listRow = panel.slotListRows[1]
        break
      end
    end
    check("a slot draws the candidate list, to hover a name in", listRow ~= nil)

    if listRow then
      -- Geometry is asserted further down; this is the RENDER half — that the
      -- row was actually pointed at an item's artwork rather than left holding
      -- the previous item's, or nothing at all.
      check("a drawn row's icon shows the ITEM's art, not the question mark",
            listRow.icon and listRow.icon._texture ~= nil
              and not listRow.icon._texture:match("QuestionMark"),
            listRow.icon and listRow.icon._texture)

      local hit, fs = listRow.nameHit, listRow.name
      check("the BIS name carries a hover target", hit ~= nil and hit:IsShown())
      check("...that knows which item it is over",
            hit and type(hit.itemID) == "number", hit and hit.itemID)

      -- ⚠️ THE REVERT-CHECK FOR THIS ONE IS THE WIDTH. Every name here is given
      -- a 300px wrapping ceiling, so a hit area measured with GetWidth instead
      -- of GetStringWidth would arm the tooltip across half an empty row and
      -- pass every other check in this block.
      local strW = fs:GetStringWidth()
      check("...sized to the string, not to the 300px wrapping ceiling",
            hit and strW > 0 and hit:GetWidth() == strW and hit:GetWidth() < 300,
            ("hit %s vs string %s"):format(tostring(hit and hit:GetWidth()), tostring(strW)))
      -- ⚠️ 14 — THE NAME'S OWN LEADING, AND NOT AN ARBITRARY HOVER SIZE
      -- (Session 262). Every tag run anchors LEFT to this frame's RIGHT, which
      -- is its vertical CENTRE, so a hit frame taller than the name it covers
      -- drops the whole tag line by half the difference. It was 16 against a
      -- 14-tall name here and 19 on the OBTAINED BY routes, which is what
      -- Jason saw as "the tags are weirdly LOWER than the item name".
      check("...and exactly the name's own line height, which places the tags",
            hit and hit:GetHeight() == 14, hit and hit:GetHeight())

      GameTooltip.calls = { lines = {} }
      drive("hovering a BIS name", function() hit.scripts.OnEnter(hit) end)
      check("...opens the game's item card on that item",
            GameTooltip.calls.link == catalogueLink(hit.itemID)
              and GameTooltip.calls.link ~= nil,
            GameTooltip.calls.link)
      -- ⚠️ THE CHECK THAT WOULD HAVE CAUGHT SESSION 259's ilvl-28 REPORT. A bare
      -- "item:251222" is a perfectly valid link and tooltips at the item's BASE
      -- level — 28, beside an equipped 311 — so every other assertion here
      -- passed while the panel showed a number that made the whole page look
      -- wrong. A catalogue row must never hand the client a link with no bonus
      -- ids on it.
      check("...never a bare item string, which tooltips at BASE level",
            GameTooltip.calls.link and not GameTooltip.calls.link:match("^item:%d+$"),
            GameTooltip.calls.link)
      check("...anchored to the cursor", GameTooltip.calls.anchor == "ANCHOR_CURSOR",
            GameTooltip.calls.anchor)
      check("...and shown", GameTooltip.calls.shown == true)
      -- The Slots rows have no OnClick, so a targeting hint here would promise
      -- an interaction the page does not have.
      check("...with no right-click hint, which this page cannot honour",
            #GameTooltip.calls.lines == 0, #GameTooltip.calls.lines)

      drive("leaving a BIS name", function() hit.scripts.OnLeave(hit) end)
      check("...closes it again", GameTooltip.calls.shown == false)
    end

    -- The tier-piece header is the other place a BIS item's name is drawn.
    if staged then
      drive("returning to the single-item layout", function()
        for i, r in ipairs(ns.SLOT_ROWS) do
          if r.key == stagedSlot then panel.slotRows[i].scripts.OnClick(panel.slotRows[i]) end
        end
      end)
      local hit = panel.slotHead.nameHit
      check("the tier piece's name carries one too",
            hit and hit:IsShown() and type(hit.itemID) == "number", hit and hit.itemID)
      GameTooltip.calls = { lines = {} }
      drive("hovering the tier piece's name", function() hit.scripts.OnEnter(hit) end)
      check("...and opens the item card on the tier piece",
            GameTooltip.calls.link == catalogueLink(hit.itemID)
              and GameTooltip.calls.link ~= nil,
            GameTooltip.calls.link)
      check("...also at a real drop level, not the base one",
            GameTooltip.calls.link and not GameTooltip.calls.link:match("^item:%d+$"),
            GameTooltip.calls.link)
    end
  end

  -- Leaving the tab must take the page's furniture with it.
  local loot = panel.tabs and panel.tabs.Loot
  if loot then
    drive("leaving Slots", function() loot.scripts.OnClick(loot) end)
    check("the rail does not draw over another tab", not panel.slotRail:IsShown())
    check("neither Slots layout draws over another tab",
          not panel.slotPanel:IsShown() and not panel.slotList:IsShown())
  end
end


header("The item icon and the gutter it opens (Session 259)")

-- ⚠️ THESE READ NUMBERS BACK OFF THE WIDGETS, which is the only kind of check
-- that can see a layout change. Every assertion here is a value from a Figma
-- node — 591:2187 and 608:77 (the Slots identity block), 591:2178 and 608:82
-- (a Slots list row), 590:2055 (OBTAINED BY) and 577:878 (the Loot header).
do
  local function pointOf(w)
    local p, x, y = w:GetPoint()
    return p, x, y
  end

  -- ── One icon, one size, on all three surfaces ──────────────────────────
  local icons = {
    { "the Loot detail header", panel.itemIcon },
    { "the Slots identity block", panel.slotHead and panel.slotHead.icon },
    { "a Slots list row", panel.slotListRows and panel.slotListRows[1].icon },
  }
  for _, e in ipairs(icons) do
    local label, tex = e[1], e[2]
    check(("%s draws an item icon"):format(label), tex ~= nil)
    if tex then
      check(("...at 32, the size every one of them shares"):format(label),
            tex:GetWidth() == 32 and tex:GetHeight() == 32,
            ("%sx%s"):format(tex:GetWidth(), tex:GetHeight()))
      -- The S258 pair: a mask alone leaves the four points where a circle
      -- touches its square, which is exactly where WoW bakes the icon border.
      check("...cropped to shed the baked-in border",
            tex._texCoord ~= nil and tex._texCoord[1] == 0.08, tex._texCoord and tex._texCoord[1])
      check("...and masked to a circle", (tex._masks or 0) > 0, tex._masks)

      -- ⚠️ THE 1px HAIRLINE (Jason, Session 260 — it is in the mocks). WoW has
      -- no stroke on a texture and Style.Rim's four straight edges cannot
      -- follow a curve, so the border is a second disc one pixel larger
      -- sitting behind the icon. It needs its OWN mask: a MaskTexture is sized
      -- to what it masks, so reusing the icon's would clip the ring back to
      -- the icon's bounds and draw nothing — which would look exactly like a
      -- border that was never added.
      local ring = tex.border
      check("...and carries a 1px border", ring ~= nil)
      if ring then
        check("......masked to a circle of its own", (ring._masks or 0) > 0, ring._masks)
        local tl = ring._points and ring._points[1]
        check("......inset one pixel outside the icon",
              tl and tl[4] == -1 and tl[5] == 1,
              tl and ("%s,%s"):format(tostring(tl[4]), tostring(tl[5])))
        -- Compared against the TOKEN, not a literal: the point is that the ring
        -- takes the palette's accent, so a check written as #9f50d4 would pass
        -- while quietly no longer being the same colour the chips and the
        -- OBTAINED BY heading use.
        local want = ns.Style.COLOR[ns.Style.ICON_BORDER.color]
        local got = ring._color
        check("......in the design's accent, the same token the chips take",
              got ~= nil and math.abs(got[1] - want.r) < 0.01
                and math.abs(got[2] - want.g) < 0.01
                and math.abs(got[3] - want.b) < 0.01,
              got and ("%.3f,%.3f,%.3f"):format(got[1], got[2], got[3]))

        -- ⚠️ AND IT FOLLOWS THE ICON. Hiding a texture does not hide another
        -- behind it, and these icons are hidden in five places — a ring left
        -- alone draws a violet circle where no icon is. Bound in Style.Round
        -- rather than at the call sites, so this is the check that the binding
        -- actually holds.
        tex:Hide()
        check("......and disappears with the icon", not ring:IsShown())
        tex:Show()
        check("......and comes back with it", ring:IsShown())
      end
    end
  end

  -- ── The gutter every text run moved into ──────────────────────────────
  if panel.slotHead then
    -- ⚠️ ONE LINE, NOT TWO (Session 262, node 591:2187). The identity block is
    -- the icon's own 32 tall holding a single 19-tall run at 6, and the "Tier
    -- Piece" kind line is gone — the tag beside the name already said it.
    local _, x, y = pointOf(panel.slotHead.icon)
    check("the Slots icon sits at the block's top", x == 0 and y == 0,
          ("%s,%s"):format(x, y))
    local _, nx, ny = pointOf(panel.slotHead.name)
    check("...with the item name 42 to its right", nx == 42, nx)
    check("...and the block is the icon's 32, not a two-line 34",
          panel.slotHead:GetHeight() == 32, panel.slotHead:GetHeight())
    check("...holding ONE 19-tall line, centred against the icon",
          panel.slotHead.name:GetHeight() == 19 and -ny == 6,
          ("h=%s y=%s"):format(panel.slotHead.name:GetHeight(), -ny))
    check("...and the kind line is gone entirely", panel.slotHead.slot == nil)
  end

  local lr = panel.slotListRows and panel.slotListRows[1]
  if lr then
    -- ⚠️ THE ICON AND THE TEXT PAIR SHARE A CENTRE, BY ARITHMETIC (Session 262,
    -- node 626:482 is `items-center`). Two 14-tall lines stack to 28 inside the
    -- 32 icon, so the text starts at 2 and both centres land on 16. Nothing in
    -- this block had an explicit height before, which is why "centred" was
    -- emergent — and wrong.
    local _, ix, iy = pointOf(lr.icon)
    check("a list row's icon sits at the block's top", ix == 0 and iy == 0,
          ("%s,%s"):format(ix, iy))
    local _, nx, ny = pointOf(lr.name)
    check("...its name is in the gutter at 42, dropped 2 to centre the pair",
          nx == 42 and ny == -2, ("%s,%s"):format(nx, ny))
    local _, px, py = pointOf(lr.source.pre)
    check("...and its source line 14 under that, on the same left edge",
          px == 42 and py == -16, ("%s,%s"):format(px, py))
    check("...both lines carrying the leading they were laid out with",
          lr.name._heightSet and lr.name:GetHeight() == 14
            and lr.source.pre._heightSet and lr.source.pre:GetHeight() == 14,
          ("name %s/%s source %s/%s"):format(tostring(lr.name._heightSet),
            lr.name:GetHeight(), tostring(lr.source.pre._heightSet),
            lr.source.pre:GetHeight()))
    -- ⚠️ COMPUTED FROM THE WIDGETS, NOT FROM THE CONSTANTS. Written first as
    -- arithmetic on literals, which is a check that cannot fail (S259) — it
    -- would have passed with every offset above reverted.
    local iconTop, iconH = -iy, lr.icon:GetHeight()
    local textTop = -ny
    local textH   = lr.name:GetHeight() + lr.source.pre:GetHeight()
    check("...so the icon's centre and the text pair's centre agree",
          math.abs((iconTop + iconH / 2) - (textTop + textH / 2)) <= 1,
          ("icon %d..%d, text %d..%d"):format(iconTop, iconTop + iconH,
            textTop, textTop + textH))
  end

  -- ── THE RAIL READS LEFT TO RIGHT NOW (Session 262) ────────────────────
  --
  -- ⚠️ THIS CHANGE WAS CATALOGUED IN SESSION 261 AND NEVER BUILT. The rail was
  -- still 150 wide with the label RIGHT-aligned at 91, i.e. BEFORE the icon;
  -- node 590:1960 is 180 wide with the 20px icon first and the label after it.
  do
    local rr = panel.slotRows and panel.slotRows[1]
    if rr then
      check("the rail is the node's 180 wide", rr:GetWidth() == 180, rr:GetWidth())
      -- Both anchor with the five-argument SetPoint, so the x is the
      -- second-to-last stored value rather than pointOf's second return.
      local function xOf(w)
        local p = w._points and w._points[1]
        return p and p[#p - 1]
      end
      local ix, lx = xOf(rr.icon), xOf(rr.label)
      check("...with the slot icon first, at 0", ix == 0, ix)
      check("...and the label AFTER it at 30", lx == 30, lx)
      check("...left-aligned, not right", rr.label._justifyH ~= "RIGHT",
            tostring(rr.label._justifyH))
      check("...13 Medium white, 26 tall so it centres in the row",
            rr.label._size == 13 and (rr.label._font or ""):match("Saira%-Medium")
              and rr.label:GetHeight() == 26,
            ("%s %s h%s"):format(rr.label._size, rr.label._font or "?",
              rr.label:GetHeight()))

      -- ⚠️ TWO CHECKS PER PAIRED SLOT, GREEN FOR ACQUIRED (Jason, Session 262).
      -- The old rail drew ONE violet check and dimmed it to 0.4 for the
      -- one-of-two case, so a ring you owned looked like a ring you half-owned.
      check("a rail row carries two check slots", rr.checks and #rr.checks == 2,
            rr.checks and #rr.checks)
      local S = ns.Style
      local shownChecks, greens, greys = 0, 0, 0
      for _, row in ipairs(panel.slotRows) do
        for _, chk in ipairs(row.checks or {}) do
          if chk:IsShown() then
            shownChecks = shownChecks + 1
            local c = chk._vertex
            if c and math.abs(c[1] - S.COLOR.green.r) < 0.01
                 and math.abs(c[2] - S.COLOR.green.g) < 0.01 then greens = greens + 1
            elseif c and math.abs(c[1] - S.COLOR.grey.r) < 0.01 then greys = greys + 1 end
          end
        end
      end
      -- 14 rows, two of them paired, so 16 sockets are always drawn.
      check("every socket in the rail draws a check", shownChecks == 16, shownChecks)
      check("...and each is either acquired-green or unacquired-grey",
            greens + greys == shownChecks,
            ("green %d + grey %d of %d"):format(greens, greys, shownChecks))
    end
  end

  -- ── OBTAINED BY moved out to the node's own 294/465 ───────────────────
  -- ⚠️ 294 AND 465, NOT 272 AND 428 (Session 262, node 590:2055). The right
  -- edge still lands on the pane's — 294 + 465 = 759 against a pane running
  -- 250..750 — but the panel's left now clears the item icon's gutter.
  if panel.slotPanel then
    local _, px = pointOf(panel.slotPanel)
    check("OBTAINED BY sits at the node's 294", px == 294, px)
    check("...and is the node's 465 wide", panel.slotPanel:GetWidth() == 465,
          panel.slotPanel:GetWidth())
    local r = panel.slotRoutes and panel.slotRoutes[1]
    check("...and a route inside it is 425, the panel less its padding",
          r and r:GetWidth() == 425, r and r:GetWidth())
    -- ⚠️ A ROUTE CARRIES ITS OWN ITEM ICON (Session 262). It drew text alone.
    check("...and a route draws a 32px item icon at its top left",
          r and r.icon and r.icon:GetWidth() == 32,
          r and r.icon and r.icon:GetWidth())
    check("...with its name in the same 42 gutter the icon opens",
          r and select(2, pointOf(r.name)) == 42,
          r and select(2, pointOf(r.name)))
    -- The same centring the list rows get, and for the same reason: neither
    -- line had a height, so the icon and the text were never aligned by
    -- anything (Jason, Session 262).
    if r then
      local _, _, riy = pointOf(r.icon)
      local _, _, rny = pointOf(r.name)
      local rTextH = r.name:GetHeight() + r.source.pre:GetHeight()
      check("...and its icon and text pair share a centre",
            math.abs(((-riy) + r.icon:GetHeight() / 2) - ((-rny) + rTextH / 2)) <= 1,
            ("icon %s+%s, text %s+%s"):format(-riy, r.icon:GetHeight(), -rny, rTextH))
      check("...both route lines carrying an explicit 14 leading",
            r.name._heightSet and r.name:GetHeight() == 14
              and r.source.pre._heightSet and r.source.pre:GetHeight() == 14,
            ("name %s source %s"):format(r.name:GetHeight(), r.source.pre:GetHeight()))
      check("...and the tag run hanging off a hit frame the name's own height",
            r.nameHit:GetHeight() == r.name:GetHeight(),
            ("hit %s vs name %s"):format(r.nameHit:GetHeight(), r.name:GetHeight()))
    end
  end

  -- ── The Loot header came down with it ─────────────────────────────────
  do
    local _, nx = pointOf(panel.itemName)
    -- 386, not 306: same 80px pane shift as above (Session 261).
    check("the Loot header's name column sits beside the icon",
          nx == 386, nx)
    -- Asserting the CENTRES agree is what survives a size change — which the
    -- previous version claimed to do while hard-coding 17 and 16, so it failed
    -- the moment the block came down to the node's 28 (Session 262).
    local _, _, iy = pointOf(panel.itemIcon)
    local _, _, by = pointOf(panel.itemName)
    local blockH = panel.itemName:GetHeight() + panel.itemSub:GetHeight()
    local iconH  = panel.itemIcon:GetHeight()
    check("...and the block and the icon still share a centre line",
          math.abs(((-by) + blockH / 2) - ((-iy) + iconH / 2)) <= 1,
          ("block %s+%s, icon %s+%s"):format(-by, blockH, -iy, iconH))
  end
end


header("Every window's ground is OPAQUE (Session 259)")

-- A translucent ground would mean no colour on it is the specified one: it would
-- be the value plus a share of the game scene, which changes as the world does.
--
-- ⚠️ THESE PASS TODAY AND ALWAYS DID. The shared surface defaulted to 0.96 and
-- that looked like the answer to "why are the colours wrong" — but every window
-- overpaints it with an opaque ground of its own, so the default never reached
-- the screen. Putting 0.96 back changes NOTHING here, which is how that was
-- caught. Kept as a REGRESSION guard on the property that matters, not as
-- evidence of a bug that was fixed: if any window ever stops laying its own
-- ground, this is what notices.
--
-- The stub records what SetColorTexture was handed, so the alpha is readable.
do
  local function groundAlpha(f)
    local t = f and f.bgTex
    return t and t._color and t._color[4]
  end

  -- ⚠️ BUILD THEM FIRST, AND NAME THEM BY THE GLOBAL THE ADDON ACTUALLY SETS.
  -- The first version of this reached for ns.RecordWindow.Frame() and friends,
  -- which do not exist — so three of the four rows were nil, the loop skipped
  -- them, and the block passed having checked ONLY the panel. A check that goes
  -- quiet about the cases it was written for is the S249 trap.
  ns.LoadWindow.Toggle(); ns.RecordWindow.Toggle(); ns.Settings.Toggle()
  local windows = {
    { "the panel", panel },
    { "the Loot Log", _G.HoDLootAdvisorLootLog },
    { "the Import window", _G.HoDLootAdvisorLoadFrame },
    { "the Settings window", _G.HoDLootAdvisorConfigFrame },
  }
  for _, e in ipairs(windows) do
    local label, f = e[1], e[2]
    check(("%s exists, so the next check means something"):format(label), f ~= nil)
    local a = groundAlpha(f)
    check(("%s's ground is fully opaque"):format(label), a == 1,
          ("alpha %s"):format(tostring(a)))

  end
  -- ⚠️ "NO BLIZZARD FRAME TEMPLATE" CANNOT BE CHECKED HERE, and the attempt is
  -- worth recording: this stub answers ANY unknown key with a function, so
  -- `f.NineSlice == nil` is false for every frame whether or not it has one —
  -- the exact S257 trap the rules already name. That assertion lives in
  -- smoke.lua, against the SOURCE, where "CreateFrame(... , template)" is a
  -- string that either appears or does not.

  -- ⚠️ AND THE COLOUR, WHICH IS THE THING ACTUALLY BEING ASKED ABOUT. Asserting
  -- the alpha alone passes for a ground painted fully opaque in the WRONG hue —
  -- and #0d0d14 (the shared window fill) against #0c0721 (the panel's) is
  -- exactly that: both near-black, one bluish-grey and one violet, and only a
  -- side-by-side shows it. Read the value back and compare it to the token.
  local function hexOf(f)
    local c = f and f.bgTex and f.bgTex._color
    if not c then return "none" end
    return ("%02x%02x%02x"):format(
      math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
  end
  check("the panel's ground is the design's #0c0721", hexOf(panel) == "0c0721", hexOf(panel))
  check("...and NOT the shared window fill #0d0d14", hexOf(panel) ~= "0d0d14", hexOf(panel))
  check("the secondary windows use their own #1c1228",
        hexOf(_G.HoDLootAdvisorLootLog) == "1c1228", hexOf(_G.HoDLootAdvisorLootLog))
  for i = #ns.windowStack, 1, -1 do ns.EscapeTop() end
  ns.Panel.Show()

  -- The deliberate washes are UNAFFECTED — they pass an explicit alpha, and
  -- asserting that is what stops a future "make it all opaque" flattening them.
  check("a deliberate 10% wash still reads 0.1",
        panel.slotPanel and panel.slotPanel.bgTex and panel.slotPanel.bgTex._color
          and math.abs(panel.slotPanel.bgTex._color[4] - 0.1) < 0.001,
        panel.slotPanel and panel.slotPanel.bgTex and panel.slotPanel.bgTex._color
          and panel.slotPanel.bgTex._color[4])
end


header("A ranking row's cells share one centre line (Session 259)")

-- ⚠️ THE HOVER HIGHLIGHT IS WHAT EXPOSED THIS, not any check in this file. Every
-- text cell was anchored TOPLEFT with no height, so each drew wherever its own
-- line box landed — and that differs by font and size, so the 14px Bold rank,
-- the 11px Light name and the 12px chips settled on three different lines. The
-- chips were the only elements ever centred, being anchored LEFT.
--
-- Geometry checks passed throughout, because every cell was at the x it should
-- be. Alignment is a property BETWEEN cells, so it has to be asserted that way.
do
  local r = panel.rows and panel.rows[1]
  if r then
    -- ⚠️ THE UPGRADE COLUMN IS IN THIS LIST NOW (Session 262). It is the fifth
    -- cell and the only one that is a TAG LINE rather than a plain fontstring,
    -- so it was left out of the height pass and drew half a row above the
    -- raider name on every row — while these four checks stayed green
    -- throughout. Its whole run hangs off the lead's rect, so the lead is the
    -- thing that has to carry the height.
    for _, e in ipairs({ { "rank", r.rank }, { "name", r.name },
                         { "gain", r.gain }, { "priority", r.pr }, { "source", r.src },
                         { "upgrade", r.tagLine and r.tagLine.lead } }) do
      local label, fs = e[1], e[2]
      -- _heightSet, not GetHeight(): the stub's default height is 20 and so is
      -- the row pitch, so comparing the value alone cannot fail.
      check(("the %s cell is GIVEN the row's height"):format(label),
            fs and fs._heightSet and fs:GetHeight() == 20,
            fs and ("set=%s h=%s"):format(tostring(fs._heightSet), tostring(fs:GetHeight())))
      check(("...and centres vertically inside it"):format(label),
            fs and fs._justifyV == "MIDDLE", fs and tostring(fs._justifyV))
      local _, _, y = fs:GetPoint()
      check(("...anchored at the row's top, not inset"):format(label), y == 0, y)
    end
    -- The property that actually matters: they all resolve to the same centre.
    -- A cell 20 tall anchored at 0 centres at 10 whatever font it carries.
    local centres = {}
    for _, fs in ipairs({ r.rank, r.name, r.gain, r.pr, r.src,
                          r.tagLine and r.tagLine.lead }) do
      local _, _, y = fs:GetPoint()
      centres[#centres + 1] = (-(y or 0)) + (fs:GetHeight() or 0) / 2
    end
    local same = true
    for i = 2, #centres do if centres[i] ~= centres[1] then same = false end end
    check("every cell in the row shares one centre line", same, table.concat(centres, ", "))
  end
end


header("The identity line (Session 262 — it is ONE line now)")

-- ⚠️ THE TWO-LINE BLOCK IS GONE. It was a 13 Regular name over a 12 Light
-- "Tier Piece", separated by weight and colour rather than size; node 591:2189
-- is a SINGLE 12 Medium white run carrying its own tags, and the kind it used
-- to spell out is one of those tags.
do
  local function fontOf(fs) return fs and fs._font or "" end

  local n = panel.slotHead and panel.slotHead.name
  check("the Slots item name is the node's 12", n and n._size == 12, n and n._size)
  check("...and Medium, not Light", fontOf(n):match("Saira%-Medium") ~= nil, fontOf(n))
  local nc = n and n._textColor
  check("...in white, not the blush it used to draw",
        nc and nc[1] > 0.9 and nc[2] > 0.9 and nc[3] > 0.9,
        nc and ("%.2f,%.2f,%.2f"):format(nc[1], nc[2], nc[3]) or "never set")
  check("...on ONE 19-tall line", n and n:GetHeight() == 19, n and n:GetHeight())

  -- ⚠️ THE LOOT HEADER IS 14 OVER 14, NOT 18 OVER 16 (Session 262, node
  -- 577:880: both lines lead at 14). These two surfaces do NOT share a block
  -- height, which is why the old "so the two cannot drift apart" pairing was
  -- asserting the Slots numbers on the Loot header.
  check("the Loot header's name line box is the node's 14",
        panel.itemName:GetHeight() == 14, panel.itemName:GetHeight())
  check("...and its second line 14 too", panel.itemSub:GetHeight() == 14, panel.itemSub:GetHeight())
end


header("Table headers are BOLD, on both tables (Session 259)")

-- ⚠️ A WEIGHT IS A VALUE AND CAN BE ASSERTED. The Loot table's four headers were
-- drawn Light against a node that is font-bold, which made the whole table read
-- as thinner and flatter than the mock while every POSITION on it was correct —
-- so every geometry check in this file passed throughout. The stub records the
-- font path SetFont was handed; that is the thing to read back.
do
  local function fontOf(fs) return fs and fs._font or "" end

  for i, name in ipairs({ "RAIDER", "UPGRADE", "ILVL GAIN", "PRIORITY" }) do
    local fs = panel.head and panel.head[i]
    check(("the Loot table's %s header is Bold"):format(name),
          fontOf(fs):match("Saira%-Bold") ~= nil, fontOf(fs))
  end
  -- The other table in the same panel, so the two cannot drift apart again.
  for i = 1, 5 do
    local fs = panel.stHead and panel.stHead[i]
    if fs then
      check(("the Standings table's header %d is Bold too"):format(i),
            fontOf(fs):match("Saira%-Bold") ~= nil, fontOf(fs))
    end
  end

  -- And the cells around them are NOT, which is what makes the headers read as
  -- headings. Asserting only the bold half would pass on a table set entirely
  -- in one weight.
  local r1 = panel.rows and panel.rows[1]
  if r1 then
    check("a raider name is Medium, not Bold",
          fontOf(r1.name):match("Saira%-Medium") ~= nil, fontOf(r1.name))
    check("...and the rank is the one Bold cell in the table",
          fontOf(r1.rank):match("Saira%-Bold") ~= nil, fontOf(r1.rank))
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

header("The three secondary windows (Session 258)")

-- ⚠️ NOTHING BUILT THESE BEFORE. This file drove the PANEL and left Import,
-- Settings and the Loot Log to a static scan that only reads them — so all
-- three could be rewritten, pass every check, and error on first open. They
-- were rewritten in this session, which is exactly when that gap matters.
do
  drive("the Import window builds and opens", function() ns.LoadWindow.Toggle() end)
  drive("...and closes", function() ns.LoadWindow.Toggle() end)

  drive("the Settings window builds and opens", function() ns.Settings.Toggle() end)
  drive("...and refreshes", function() ns.Settings.Refresh() end)
  drive("...and closes", function() ns.Settings.Toggle() end)

  drive("the Loot Log builds and opens", function() ns.RecordWindow.Toggle() end)
  drive("...and refreshes", function() ns.RecordWindow.Refresh() end)
  drive("...and closes", function() ns.RecordWindow.Toggle() end)

  -- Settings is SPEC-driven, so a row that gained a control kind nothing
  -- renders would leave a labelled gap rather than erroring.
  local cfg = _G.HoDLootAdvisorConfigFrame
  check("every setting drew a control",
        cfg and cfg.rows and #cfg.rows == #ns.Settings.SPEC,
        cfg and cfg.rows and ("%d rows for %d settings"):format(#cfg.rows, #ns.Settings.SPEC))
  if cfg and cfg.rows then
    local missing = {}
    for _, row in ipairs(cfg.rows) do
      if not row.control then missing[#missing + 1] = row.spec.key end
    end
    check("...and none of them is a label with nothing beside it",
          #missing == 0, table.concat(missing, ", "))
  end
end


header("What the design actually says (Session 258)")

-- ⚠️ THIS BLOCK EXISTS BECAUSE THE SUITE COULD NOT SEE A SINGLE ONE OF THESE.
-- Every check below is something Jason had to find by opening the addon and
-- comparing it to Figma himself, while 78 green checks said the panel was fine.
-- "No runtime error" is not "matches the design", and the gap between those two
-- was the whole of this session's failure. These pin the VALUES.
do
  local function hex(c)
    if not c then return "nil" end
    return string.format("#%02x%02x%02x@%.2f", math.floor((c[1] or 0) * 255 + 0.5),
      math.floor((c[2] or 0) * 255 + 0.5), math.floor((c[3] or 0) * 255 + 0.5), c[4] or 1)
  end

  -- The window ground, and the border that should not exist.
  check("the panel's ground is #0c0721",
        hex(panel.bgTex and panel.bgTex._color) == "#0c0721@1.00",
        hex(panel.bgTex and panel.bgTex._color))
  check("the panel has NO outer border", panel.rim == nil)

  -- The footer is a wash, not a rule. Read from the footer's own SVG:
  -- fill="#AC7666" fill-opacity="0.1".
  local footBg
  for _, r in ipairs({ panel.foot:GetRegions() }) do
    if r._color then footBg = r._color end
  end
  check("the footer is #ac7666 at 10%, a fill rather than a border",
        hex(footBg) == "#ac7666@0.10", hex(footBg))

  -- Every rule in the design is the same warm blush at 30%.
  local rules, wrong = 0, nil
  for _, r in ipairs({ panel:GetRegions() }) do
    local c = r._color
    if c and (c[4] or 1) < 1 and c[4] > 0.2 and c[4] < 0.4 then
      rules = rules + 1
      if hex(c) ~= "#ac7666@0.30" then wrong = hex(c) end
    end
  end
  check("every separator is #ac7666 at 30%", rules > 0 and wrong == nil,
        wrong or "no rules found")

  -- The rail blocks are fills. Style.Surface used to rim everything it touched.
  check("a Standings rail block has no border", panel.rail[1].box.rim == nil)
  check("the Slots OBTAINED BY panel has no border", panel.slotPanel.rim == nil)

  -- Four tag slots: three BIS contexts can apply at once, and the
  -- classification follows them. The WIDGET changed in Session 261 — chips
  -- became colour-coded text — but the count did not, and it is the count this
  -- has always been guarding.
  check("the Slots header has four tag slots", #panel.slotHead.tagLine.tags == 4)
  -- ⚠️ AND THEY ARE THE HEAVIEST WEIGHT. A tag that renders in body text is
  -- indistinguishable from the line it sits on, which is the whole reason the
  -- chips could be dropped at all.
  check("...set in Saira Black", (panel.slotHead.tagLine.tags[1]._font or ""):match("Saira%-Black") ~= nil,
        panel.slotHead.tagLine.tags[1]._font)
  -- ⚠️ AND THE SEPARATOR IS NOT (Jason, Session 261: Trash Grey, Saira Light).
  -- A bullet in the tag's own weight and colour reads as a fifth tag.
  check("...with Light separators between them",
        (panel.slotHead.tagLine.seps[1]._font or ""):match("Saira%-Light") ~= nil,
        panel.slotHead.tagLine.seps[1]._font)

  -- ⚠️ NEVER AN ITEM ID ON SCREEN. This is what the whole Slots page rendered.
  do
    local slots = panel.tabs.Slots
    slots.scripts.OnClick(slots)
    local bad
    for i = 1, #panel.slotRows do
      panel.slotRows[i].scripts.OnClick(panel.slotRows[i])
      for _, r in ipairs(panel.slotListRows) do
        local t = r:IsShown() and r.name._text or nil
        if t and t:match("^item:%d+$") then bad = t end
      end
      if panel.slotHead:IsShown() then
        local t = panel.slotHead.name._text
        if t and t:match("^item:%d+$") then bad = t end
      end
    end
    check("no row on the Slots page shows a raw item id", bad == nil, bad)
  end

  -- ⚠️ HOW THE STRING WAS WRITTEN, NOT WHAT THE OBJECT HOLDS (Session 260).
  -- Every other text assertion in this file reads _text — what the addon WROTE
  -- — and all three blanks Jason found had a perfectly correct _text. The
  -- writes landed while the widget was still hidden, so nothing drew, and the
  -- string never changed afterwards to force a redraw. 118 checks had nothing
  -- to say about any of it.
  --
  -- Two conditions, which together are the whole of the Session 254 rule:
  -- a recycled row must be SHOWN before it is written into, and identity text
  -- must be written through a forced repaint so an unchanged string still
  -- redraws. setTextForce satisfies the second by writing "" first.
  --
  -- SCOPED TO THE NAMED SLOTS CONTAINERS. This makes no claim about what the
  -- client does with build-once labels elsewhere in the panel — see the note
  -- above SetText for the five false positives that taught that lesson.
  --
  -- Swept after EVERY slot, because the two layouts are different code paths:
  -- an ordinary slot draws the list rows, a tier slot draws the identity header
  -- and the OBTAINED BY panel whose heading was blank on every client since the
  -- page was built.
  do
    local slots = panel.tabs.Slots
    slots.scripts.OnClick(slots)

    --- Every fontstring a container owns, including the ones inside its chips.
    local function labelsOf(c, out)
      if not c then return out end
      for _, ch in ipairs(c._children or {}) do
        if ch._kind == "FontString" then out[#out + 1] = ch end
      end
      for _, chip in ipairs(c.chips or {}) do
        if chip and chip.text then out[#out + 1] = chip.text end
      end
      if c.chip and c.chip.text then out[#out + 1] = c.chip.text end
      return out
    end

    local bad, seen = {}, {}
    for i = 1, #panel.slotRows do
      panel.slotRows[i].scripts.OnClick(panel.slotRows[i])

      local watched = { panel.slotHead, panel.slotPanel }
      for _, r in ipairs(panel.slotListRows) do watched[#watched + 1] = r end
      for _, r in ipairs(panel.slotRoutes) do watched[#watched + 1] = r end

      for _, c in ipairs(watched) do
        if c:IsShown() then
          for _, fs in ipairs(labelsOf(c, {})) do
            local t = fs._text or ""
            -- A visible, non-empty label must have been written while on
            -- screen, and must have been written as a CHANGE.
            if t ~= "" and not (fs._writeVisible and fs._writeChanged)
              and not seen[t] then
              seen[t] = true
              bad[#bad + 1] = t
            end
          end
        end
      end
    end
    table.sort(bad)
    local sample = {}
    for i = 1, math.min(#bad, 6) do sample[i] = bad[i] end
    check("every Slots label is written into a shown row, as a change",
          #bad == 0, ("%d bad: %s"):format(#bad, table.concat(sample, " | ")))
  end

  -- ⚠️ THE SOURCE LINE HOLDS NO IN-FRAME MEASUREMENT (Session 260). Its three
  -- runs used to be positioned by reading GetStringWidth in the same call that
  -- set the string. On the first route Jason opened, the measurement came back
  -- about a comma too short and the instance ran over its own ", " — the line
  -- read "The Twin FangsThe Venomous Abyss" while the identical code one row
  -- below rendered correctly, which is exactly what a stale measurement does.
  -- Anchoring each run to the previous run's RIGHT EDGE leaves nothing to be
  -- stale, and this asserts the anchor rather than the rendered result.
  do
    local slots = panel.tabs.Slots
    slots.scripts.OnClick(slots)
    -- Walk the slots until one actually draws a list row with a source on it.
    -- Whichever slot the previous block left selected need not have one, and a
    -- probe that silently inspects nothing is worse than no probe (S256).
    local g
    for i = 1, #panel.slotRows do
      panel.slotRows[i].scripts.OnClick(panel.slotRows[i])
      for _, r in ipairs(panel.slotListRows) do
        if r:IsShown() and r.source and (r.source.boss._text or "") ~= "" then
          g = r.source
          break
        end
      end
      if g then break end
    end
    check("a drawn Slots source line was found to inspect", g ~= nil)

    -- ⚠️ THE ITEM MUST NOT JUMP WHEN THE LAYOUT CHANGES (Session 260, Jason:
    -- it moves "a few pixels up or down" depending on whether there is an
    -- OBTAINED BY box). A tier slot draws the identity block, an ordinary slot
    -- draws the list, and the two mocks put their first item 2px apart — so
    -- walking the rail nudged the icon and the name every time the layout
    -- flipped. Both frames were re-read to confirm the difference is drawing
    -- drift and not intent; see the SL.listY note.
    --
    -- Sums the anchor offsets up to the panel, so it asserts the POSITION a
    -- viewer sees rather than the constant a developer typed.
    local function topOf(w)
      local y, n = 0, w
      while n and n ~= panel do
        local p = n._points and n._points[1]
        if not p then break end
        local toSibling = (type(p[2]) == "table")
        y = y + ((toSibling and p[5] or p[3]) or 0)
        n = toSibling and p[2] or n._parent
      end
      return -y
    end
    local row1 = panel.slotListRows[1]
    -- ⚠️ THE ICON IS WHAT MUST NOT JUMP, and only the icon (Session 262). This
    -- used to pin the name and the second line too, which was reachable while
    -- both layouts drew a two-line block. They no longer do: the head is one
    -- line CENTRED in 32 and a list row is a two-line block starting at its
    -- top, so their first lines genuinely differ in the design. Jason's S260
    -- complaint was about the pair moving between states — the icon is the
    -- element the eye tracks, and it stays within a pixel.
    check("the item icon lands at the same height in both layouts",
          math.abs(topOf(panel.slotHead.icon) - topOf(row1.icon)) <= 1,
          ("single=%s list=%s"):format(topOf(panel.slotHead.icon), topOf(row1.icon)))
    if g then
      local b, t = g.boss._points[1] or {}, g.rest._points[1] or {}
      check("the boss name is anchored to the RIGHT of \"From \"",
            b[1] == "LEFT" and b[2] == g.pre and b[3] == "RIGHT" and (b[4] or 0) == 0,
            ("rel=%s x=%s"):format(tostring(b[3]), tostring(b[4])))
      check("the instance is anchored to the RIGHT of the boss name",
            t[1] == "LEFT" and t[2] == g.boss and t[3] == "RIGHT" and (t[4] or 0) == 0,
            ("rel=%s x=%s"):format(tostring(t[3]), tostring(t[4])))
    end
  end

  -- Post belongs to Current Drops only.
  do
    local loot = panel.tabs.Loot
    loot.scripts.OnClick(loot)
    -- Driven through the switch a person actually clicks, not a setter.
    panel.swSource.scripts.OnClick(panel.swSource)
    ns.Panel.Refresh()
    check("Post is hidden on the Full Loot Table", not panel.post:IsShown())
  end

  -- ⚠️ THE ROW'S TOOLTIP IS GONE; THE DIAMOND'S IS NOT (Jason, Session 260:
  -- the row tooltip "serves no purpose but to be in the way"). It restated the
  -- boss's name, which is already printed larger an inch to the left, while
  -- covering the neighbouring rows. The count moves to the diamond, which is
  -- the one thing on that row that does not explain itself.
  do
    local loot = panel.tabs.Loot
    loot.scripts.OnClick(loot)
    local tile = panel.bossTiles[1]
    check("a boss row has no tooltip of its own", tile.scripts.OnEnter == nil)
    check("...and the diamond carries its own hover target", tile.bisHit ~= nil)

    -- ── OPENING A BOSS SELECTS NOTHING (Session 262) ──────────────────────
    --
    -- Jason: "clicking a boss should just show that boss's loot table, NOT
    -- select the first item". It was setting the selection to 1, which filled
    -- the detail pane with an item nobody had picked and made the panel's own
    -- "Choose an Item to View Details" state unreachable — a message that has
    -- been written, drawn and dead since the accordion was built.
    --
    -- ⚠️ ASSERTS THE EMPTY STATE'S OWN WORDS, not merely that the pane is
    -- blank: the two empty states differ only in their text, and the one this
    -- change makes reachable is the second of them.
    do
      local opened
      for _, t in ipairs(panel.bossTiles) do
        if t.bossIndex and t.scripts.OnClick then
          t.scripts.OnClick(t)
          if panel.itemRows[1] and panel.itemRows[1]:IsShown() then opened = t break end
          t.scripts.OnClick(t)   -- collapse again and try the next boss
        end
      end
      check("a boss with loot expands its cards", opened ~= nil)
      if opened then
        check("...and NO item is selected by the click",
              panel.itemName:GetText() == "" or panel.itemName:GetText() == nil,
              tostring(panel.itemName:GetText()))
        check("...so the pane asks for an item, not for a boss",
              panel.paneEmpty:IsShown()
                and panel.paneEmpty:GetText() == "CHOOSE AN ITEM TO VIEW DETAILS",
              ("shown=%s text=%s"):format(tostring(panel.paneEmpty:IsShown()),
                tostring(panel.paneEmpty:GetText())))

        -- ── THE CARDS ARE INDENTED TO THE BOSS NAME (Session 262) ─────────
        --
        -- Jason: "the loot items box inset isn't here". buildItemRow anchors
        -- each card at the indent and renderColumn's ClearAllPoints threw it
        -- away, re-anchoring at x 0 — so the cards ran from the column's own
        -- left edge, under the boss ICONS. Node 625:244 puts them at 34, which
        -- is where the boss NAME starts.
        --
        -- ⚠️ 34 IS NOT A DEFAULT ANYWHERE, so this can fail: reverting the
        -- re-anchor to 0 fails it immediately.
        -- The x is the second-to-last stored value whether the anchor was set
        -- with the three-argument form or the five-argument one.
        local function xOf(w)
          local p = w._points and w._points[1]
          return p and p[#p - 1]
        end
        local rx = xOf(panel.itemRows[1])
        check("an expanded item card is indented to the boss name",
              rx == 34, tostring(rx))
        check("...which is where the boss name column starts",
              rx == xOf(tile.name), ("card %s, name %s"):format(tostring(rx), tostring(xOf(tile.name))))
      end
      -- Leave the column collapsed for whatever runs next.
      if opened then opened.scripts.OnClick(opened) end
    end

    -- ── THE COUNTS REACH THE ROW (Session 261) ────────────────────────────
    --
    -- ⚠️ ASSERTS THE VALUE, NOT THE WIDGET'S EXISTENCE. A count that is never
    -- written leaves these fontstrings present, empty and hidden — which passes
    -- any "is it there" check and is exactly the state the refresh is adding
    -- them to escape. Staged through the real fill so the number has to travel.
    do
      local data = ns.Data()
      local itemID, bossID
      for id, rec in pairs((data or {}).items or {}) do
        if rec.boss then itemID, bossID = id, rec.boss break end
      end
      if itemID and ns.Targets then
        ns.Targets.Add(itemID, { name = "staged" })
        ns.Panel.Refresh()
        local marked
        for _, t in ipairs(panel.bossTiles) do
          if t.bossIndex and t.tgtN and t.tgtN:IsShown() then marked = t end
        end
        check("a targeted item makes its boss row show a target count",
              marked ~= nil, "no boss row showed one")
        if marked then
          check("...printed as a count, not a bare icon",
                (marked.tgtN._text or ""):match("^x%d+$") ~= nil, marked.tgtN._text)
        end
        ns.Targets.Remove(itemID)
        ns.Panel.Refresh()
        local still
        for _, t in ipairs(panel.bossTiles) do
          if t.tgtN and t.tgtN:IsShown() then still = t.tgtN._text end
        end
        check("...and it goes away again when the target is cleared",
              still == nil, tostring(still))
      end
    end

    local said
    local realSet, realShow, realOwner =
      ns.Tip.SetText, ns.Tip.Show, ns.Tip.SetOwner
    ns.Tip.SetText = function(_, s) said = s end
    ns.Tip.Show, ns.Tip.SetOwner = function() end, function() end

    tile.bossBis = 1
    tile.bisHit.scripts.OnEnter(tile.bisHit)
    check("hovering the diamond gives the count, singular", said == "1 BIS ITEM", said)
    tile.bossBis = 3
    tile.bisHit.scripts.OnEnter(tile.bisHit)
    check("...and plural above one", said == "3 BIS ITEMS", said)
    said = nil
    tile.bossBis = 0
    tile.bisHit.scripts.OnEnter(tile.bisHit)
    check("...and says nothing when the boss has none", said == nil, said)

    ns.Tip.SetText, ns.Tip.Show, ns.Tip.SetOwner = realSet, realShow, realOwner

    -- ⚠️ THE HIT FRAME SITS ON TOP OF THE ROW, so only IT receives the press.
    -- Without the explicit forward, clicking the diamond would look dead —
    -- the S252 rule about two mouse-enabled frames on one set of pixels.
    -- Asserted through the pane's own empty message, which is what a viewer
    -- would see change.
    --
    -- Asserted as EQUIVALENCE rather than against a known screen: press the
    -- row, record what the pane becomes, collapse, then press the diamond and
    -- require the same. A first attempt read the pane's empty message and
    -- failed for the wrong reason — expanding a boss also selects its first
    -- item, so that message is never rewritten. Comparing the two presses needs
    -- no theory about what expansion looks like.
    local COLLAPSED = "true|CHOOSE A BOSS TO VIEW LOOT"
    local function sig()
      return tostring(panel.paneEmpty:IsShown()) .. "|" .. tostring(panel.paneEmpty._text)
    end
    for _ = 1, 3 do
      if sig() == COLLAPSED then break end
      tile.scripts.OnClick(tile)
    end
    check("the boss list starts collapsed, so the presses below mean something",
          sig() == COLLAPSED, sig())

    tile.scripts.OnClick(tile)
    local viaRow = sig()
    check("...and pressing the row opens something", viaRow ~= COLLAPSED, viaRow)

    tile.scripts.OnClick(tile)
    tile.bisHit.scripts.OnClick(tile.bisHit)
    check("clicking the diamond opens the boss, exactly as the row does",
          sig() == viaRow, ("row=%s diamond=%s"):format(viaRow, sig()))
    tile.scripts.OnClick(tile)   -- collapse again for whatever runs next
  end

  -- Escape closes ONE window, the most recent.
  do
    for i = #ns.windowStack, 1, -1 do ns.EscapeTop() end
    ns.Panel.Show()
    ns.LoadWindow.Toggle()
    ns.RecordWindow.Toggle()
    ns.Settings.Toggle()
    local depth = #ns.windowStack
    check("all four windows are on the stack", depth == 4, depth)
    local first = ns.EscapeTop()
    check("Escape closes Settings first, not everything",
          first == _G.HoDLootAdvisorConfigFrame and #ns.windowStack == 3,
          ("closed %s, %d left"):format(tostring(first and first:GetName()), #ns.windowStack))
    check("...then the Loot Log", ns.EscapeTop() == _G.HoDLootAdvisorLootLog)
    check("...then the Import window", ns.EscapeTop() == _G.HoDLootAdvisorLoadFrame)
    check("...then the panel", ns.EscapeTop() == panel)
  end

  -- The size setting governs every window, not just the panel.
  do
    check("all four windows are registered for scaling",
          #ns.scaledWindows >= 4, #ns.scaledWindows)
    ns.Settings.Set("panelScale", 80)
    ns.ApplyWindowScale()
    local missed = {}
    for _, f in ipairs(ns.scaledWindows) do
      local want = (f._baseScale or 1) * 0.8
      if math.abs((f:GetScale() or 1) - want) > 0.001 then
        missed[#missed + 1] = tostring(f:GetName())
      end
    end
    check("...and every one of them took the new size", #missed == 0,
          table.concat(missed, ", "))
    ns.Settings.Set("panelScale", 100)
    ns.ApplyWindowScale()
  end

  -- ── Nothing from one tab draws on another ─────────────────────────────────
  --
  -- ⚠️ THE CHECK THAT WOULD HAVE CAUGHT THE WORST BUG OF THIS SESSION. The
  -- Slots renderer never took the Loot tab's furniture down, so its ranking
  -- table, column headers and dividers went on drawing straight through the
  -- Slots page — a list of raiders with badges and priorities under a BIS item.
  -- WoW frames do not clip their children and nothing errors, so it looked like
  -- a half-built page rather than a fault.
  --
  -- Every previous check here asked "is what this tab owns visible". None asked
  -- "is anything ELSE visible", which is the question that fails loudly.
  do
    local owned = {
      -- panel.col is a bare CONTAINER — its item rows are what paint, and they
      -- are listed separately. A shown container with hidden children draws
      -- nothing, so flagging it would be a false positive.
      Loot = function()
        local t = { panel.badgeBox, panel.itemIcon, panel.div1, panel.div2 }
        for _, h in ipairs(panel.head) do t[#t + 1] = h end
        for i = 1, 3 do t[#t + 1] = panel.rows[i] end
        for i = 1, 3 do t[#t + 1] = panel.itemRows[i] end
        return t
      end,
      Slots = function()
        return { panel.slotRail, panel.slotPanel, panel.slotList, panel.slotSpec }
      end,
      Standings = function()
        local t = { panel.stList }
        for _, b in ipairs(panel.rail) do t[#t + 1] = b.box end
        for _, h in ipairs(panel.stHead) do t[#t + 1] = h end
        return t
      end,
      Runner = function() return { panel.rn.statusBox, panel.rn.dataBox, panel.rn.lead } end,
    }

    -- ⚠️ THE LOOT TAB HAS TO BE DRAWN FIRST OR THIS PROVES NOTHING. Its ranking
    -- rows only exist once a boss and an item have been selected; reaching
    -- Slots from a cold panel finds them already hidden, so the check passed
    -- with the fix reverted. Staged, then ASSERTED — if the staging ever stops
    -- producing a visible row, the guard below has gone quiet and says so.
    -- ⚠️ STAGED DIRECTLY, NOT INHERITED. Driving the panel into a state with a
    -- real ranking needs a group, an inspected roster and a selected drop —
    -- none of which this harness has, so the first version of this staging
    -- produced nothing and the guard passed with the fix reverted. The
    -- condition under test is "does switching tab put the Loot furniture
    -- away", so the furniture is simply SHOWN and then the tab is switched.
    -- That is the S254 rule: a test for the absent case stages the absence
    -- itself rather than inheriting it from whatever the data happens to be.
    local function stageLoot()
      -- ⚠️ THE PANEL MUST BE OPEN. Panel.Refresh returns immediately on a
      -- hidden frame, so a tab click does nothing — and an earlier block in
      -- this file closes every window to test Escape. Without this the guard
      -- reports stale visibility from before that.
      ns.Panel.Show()
      local loot = panel.tabs.Loot
      loot.scripts.OnClick(loot)
      for i = 1, 3 do panel.rows[i]:Show() end
      panel.badgeBox:Show()
      panel.itemIcon:Show()
      panel.div1:Show()
      panel.div2:Show()
      panel.head[1]:SetText("RAIDER")
      panel.head[1]:Show()
      return panel.rows[1]:IsShown() and panel.head[1]:IsShown()
    end
    check("the Loot furniture can be staged, so the guard below can bite",
          stageLoot(), "nothing could be shown — the checks below prove nothing")

    for _, tab in ipairs({ "Loot", "Slots", "Standings", "Runner" }) do
      local b = panel.tabs[tab]
      if b and b:IsShown() then
        stageLoot()
        b.scripts.OnClick(b)
        local strays = {}
        for other, list in pairs(owned) do
          if other ~= tab then
            for i, w in ipairs(list()) do
              -- ⚠️ AN EMPTY FONTSTRING IS SHOWN AND DRAWS NOTHING. Several
              -- views blank their headers rather than hiding them, which is
              -- fine — so "shown" alone would report a page as dirty when
              -- nothing is on it.
              local paints = w and w.IsShown and w:IsShown()
                and not (w._kind == "FontString" and (w._text or "") == "")
              if paints then
                strays[#strays + 1] = ("%s[%d]"):format(other, i)
              end
            end
          end
        end
        check(("the %s tab draws nothing belonging to another tab"):format(tab),
              #strays == 0, table.concat(strays, ", "))
      end
    end
  end

  -- ── The Loot tab's detail header (node 582:983) ───────────────────────────
  do
    -- The icon is cropped rather than masked: node 577:878 is a rounded
    -- RECTANGLE, and the 8% inset is what removes the border baked into every
    -- WoW item icon.
    local tc = panel.itemIcon._texCoord
    check("the item icon is cropped to hide its baked border",
          tc ~= nil and tc[1] > 0 and tc[2] < 1, tc and table.concat(tc, ",") or "no crop")
    -- ⚠️ AND MASKED TOO. The icon is a CIRCLE in the design; the crop removes
    -- the baked border that a circle inscribed in a square still touches at
    -- four points. Both, not either.
    check("...and is masked to a circle as well",
          (panel.itemIcon._masks or 0) > 0, panel.itemIcon._masks)

    -- ⚠️ THE BLOCK IS CENTRED ON THE ICON, not aligned to the header's top.
    -- Both are anchored TOPLEFT with explicit heights, so this is arithmetic
    -- on values the frame actually holds rather than an eyeball.
    -- ⚠️ SetPoint HAS TWO SHAPES and the offsets are not in a fixed position:
    -- ("TOPLEFT", x, y) and ("TOPLEFT", rel, "TOPLEFT", x, y). Reading select(5)
    -- blindly gives nil for the short form, which is what every `at()` call in
    -- this file uses. Take the last two numbers instead.
    local function offsetY(f)
      local pt = { f:GetPoint(1) }
      for i = #pt, 1, -1 do
        if type(pt[i]) == "number" then return pt[i] end
      end
    end
    local iconY = offsetY(panel.itemIcon)
    local nameY = offsetY(panel.itemName)
    local subY  = offsetY(panel.itemSub)
    local blockTop, blockH = -nameY, panel.itemName:GetHeight() + panel.itemSub:GetHeight()
    local iconTop, iconH = -iconY, panel.itemIcon:GetHeight()
    check("the two-line block is 28 tall, as the node is", blockH == 28, blockH)
    check("...and its centre is the icon's centre",
          math.abs((blockTop + blockH / 2) - (iconTop + iconH / 2)) <= 1,
          ("block %d..%d, icon %d..%d"):format(blockTop, blockTop + blockH,
            iconTop, iconTop + iconH))
    check("...with the second line directly under the first",
          -subY == blockTop + panel.itemName:GetHeight(),
          ("%d vs %d"):format(-subY, blockTop + panel.itemName:GetHeight()))

    -- The badge's two lines must not sit inside each other's line box. MAJOR is
    -- 16px Bold, whose box is about 19 tall.
    local gradeY = offsetY(panel.hUpgrade)
    local wordY  = offsetY(panel.hUpgradeWord)
    -- ⚠️ REWRITTEN FOR WHAT THE BADGE NOW CLAIMS (Session 260). The old check
    -- required a 17px step because the lines were stacked around the 16px
    -- Bold's LINE BOX — and that step is exactly the gap Jason called too big.
    -- Both lines carry explicit visible heights now and centre their own text
    -- inside them, so the assertion is the one that actually matters: the two
    -- do not overlap, and the PAIR is centred in the box. A step-size floor
    -- would just re-encode the defect.
    local gradeH, wordH = panel.hUpgrade:GetHeight(), panel.hUpgradeWord:GetHeight()
    check("the badge's two lines do not overlap",
          (-wordY) >= (-gradeY) + gradeH,
          ("word at %d, grade ends %d"):format(-wordY, (-gradeY) + gradeH))
    local pairTop, pairBottom = -gradeY, (-wordY) + wordH
    local boxH = panel.badgeBox:GetHeight()
    check("...and both still fit inside the badge", pairBottom <= boxH,
          ("%d in %d"):format(pairBottom, boxH))
    -- The whole point of the change: equal air above and below.
    check("...and the pair is centred in the box, not pinned to its top",
          math.abs(pairTop - (boxH - pairBottom)) <= 1,
          ("%d above, %d below"):format(pairTop, boxH - pairBottom))
  end

  -- ── The size slider ───────────────────────────────────────────────────────
  -- ⚠️ IT WAS IMPOSSIBLE TO USE, and neither failure was visible to a test.
  do
    local cfg = _G.HoDLootAdvisorConfigFrame
    local slider
    for _, row in ipairs(cfg.rows) do
      if row.spec.kind == "slider" then slider = row.control end
    end
    check("the size setting has a slider", slider ~= nil)

    -- (a) APPLYING REPEATEDLY MUST NOT COMPOUND. A baseline captured after a
    -- scale had already been applied would multiply on every call, which is one
    -- way to get "flickers in and out at a HUGE size".
    ns.Settings.Set("panelScale", 80)
    local base = panel._baseScale or 1
    for _ = 1, 10 do ns.ApplyWindowScale() end
    check("applying the scale ten times lands where applying it once does",
          math.abs(panel:GetScale() - base * 0.8) < 0.0001,
          ("%.4f vs %.4f"):format(panel:GetScale(), base * 0.8))

    -- (b) THE WINDOW HOLDING THE KNOB IS HELD OUT OF THE LIVE RESIZE. Resizing
    -- it moves the slider under the cursor, which changes the value, which
    -- resizes it again — the loop that made this control unusable.
    if slider then
      ns.Settings.Set("panelScale", 100)
      ns.ApplyWindowScale()
      local settingsScaleBefore = cfg:GetScale()
      slider.scripts.OnMouseDown(slider)
      check("the slider reports itself as being dragged", slider:IsDragging())
      slider.scripts.OnValueChanged(slider, 60)
      check("...the panel resizes live while it is dragged",
            math.abs(panel:GetScale() - (panel._baseScale or 1) * 0.6) < 0.0001,
            panel:GetScale())
      check("...and the window holding the slider does NOT",
            math.abs(cfg:GetScale() - settingsScaleBefore) < 0.0001,
            ("%.4f vs %.4f"):format(cfg:GetScale(), settingsScaleBefore))

      slider.scripts.OnMouseUp(slider)
      check("...until the knob is released", not slider:IsDragging())
      check("...when it catches up in one step",
            math.abs(cfg:GetScale() - (cfg._baseScale or 1) * 0.6) < 0.0001,
            cfg:GetScale())

      -- A drag that ends because the window closed still ends, or the hold
      -- would never lift and the window could never be scaled again.
      -- ⚠️ SHOWN FIRST, DELIBERATELY. Hide() on an already-hidden frame fires no
      -- OnHide — in the client or here — so without this the check passes or
      -- fails for a reason unrelated to the code it is testing.
      cfg:Show()
      slider.scripts.OnMouseDown(slider)
      cfg:Hide()
      check("a drag interrupted by the window closing still releases",
            not slider:IsDragging() and ns.scaleHeld == nil)
      ns.Settings.Set("panelScale", 100)
      ns.ApplyWindowScale()
    end
  end

  -- ── The Settings window's own layout ──────────────────────────────────────
  do
    local cfg = _G.HoDLootAdvisorConfigFrame
    ns.Settings.Toggle()          -- open, so Refresh has run and rows are placed
    if not cfg:IsShown() then ns.Settings.Toggle() end

    -- ⚠️ NO ROW MAY OVERLAP THE ONE BELOW IT. The height was guessed from a
    -- character count, which is wrong in both directions once the help column
    -- narrows — a short sentence can wrap and a long one may not.
    local function topOf(f)
      local pt = { f:GetPoint(1) }
      for i = #pt, 1, -1 do if type(pt[i]) == "number" then return -pt[i] end end
    end
    local overlaps = {}
    for i = 1, #cfg.rows - 1 do
      local thisHelp = cfg.rows[i].help
      local nextLabel = cfg.rows[i + 1].label
      local bottom = topOf(thisHelp) + (thisHelp:GetStringHeight() or 0)
      if topOf(nextLabel) < bottom then
        overlaps[#overlaps + 1] = cfg.rows[i].spec.key
      end
    end
    check("no settings row overlaps the next", #overlaps == 0,
          table.concat(overlaps, ", "))

    -- ⚠️ AND NO HELP TEXT MAY RUN UNDER A CONTROL. It was sized against the
    -- CHECKBOX at x496 while the dropdown starts at 403, so it ran 93px into
    -- the dropdown's column on every row that has one.
    local widest = 0
    for _, row in ipairs(cfg.rows) do
      widest = math.max(widest, row.help:GetWidth() or 0)
    end
    check("help text stops before the leftmost control", 40 + widest <= 403,
          ("help reaches %d, control starts at 403"):format(40 + widest))
  end

  -- The settings window may not be taller than the addon window.
  check("the Settings window is no taller than the panel",
        ns.Settings.WindowHeight() <= 600, ns.Settings.WindowHeight())
  check("...and its rows scroll", _G.HoDLootAdvisorConfigFrame.scroll ~= nil)
  check("...because its content is genuinely taller than it fits",
        ns.Settings.ContentHeight() > ns.Settings.WindowHeight() - 234,
        ns.Settings.ContentHeight())
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
