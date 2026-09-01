-- Settings.lua — user-configurable behaviour
--
-- Jason's call, Session 242: things like "how many names go in a chat line"
-- belong in settings, not baked into the code. That reframes two of the open
-- questions in HoD_LootAddon_Experience.md §7 — how chatty the chat output is,
-- and whether the panel auto-opens on a drop — from decisions somebody has to
-- make once and defend, into knobs each runner sets for their own raid.
--
-- Defaults are chosen to be QUIET. Nothing this addon does is announced to the
-- raid unless the runner deliberately triggers it: chat lines are posted by a
-- button press, never automatically, and the drops window does not open itself
-- unless asked to. The failure mode of a loot addon nobody wanted is spam, and
-- spam is what gets an addon uninstalled before it proves anything.

local ADDON_NAME, ns = ...

local Settings = {}
ns.Settings = Settings

-- name, default, and a validator/description used by both the slash setter and
-- the config window, so a new setting is added in exactly ONE place.
Settings.SPEC = {
  {
    key = "panelScale", label = "Panel Size", default = 0,
    -- ⚠️ A TRUE SCALE, NOT A PERCENTAGE OF THE CLIENT'S (Jason, Session 263).
    -- It used to be a MULTIPLIER on whatever scale the client handed the window,
    -- which made the readout beneath it useless: it says "a scale of 0.3556
    -- would put one unit on one pixel", and typing 0.3556 into a multiplier
    -- produced 0.3556 x 0.65 and not that at all. The number in the footer is
    -- only worth printing if it can be typed in, so the field IS the scale.
    --
    -- ZERO MEANS "WHATEVER THE CLIENT GIVES", which is what makes an untouched
    -- install identical to before and what Restore Defaults returns to. A real
    -- scale can never be 0, so the sentinel cannot collide with a chosen value.
    kind = "scale", min = 0.20, max = 1.50, step = 0.0001, decimals = 4,
    -- ⚠️ APPLIED ON EVERY STEP, NOT ON RELEASE. This is the one setting whose
    -- effect you can only judge by looking at it, so the window resizes under
    -- the drag. `apply` is a general hook on the spec rather than a special
    -- case in the renderer — the next setting that needs to do something the
    -- moment it changes uses the same door.
    apply = function() if ns.Panel and ns.Panel.ApplyScale then ns.Panel.ApplyScale() end end,
    -- ⚠️ THIS EXISTS BECAUSE WoW UI UNITS ARE NOT DESIGN PIXELS, and nothing
    -- inside the game can convert between them. The panel is drawn to a 740x600
    -- frame; how large that lands on a given screen depends on the client's
    -- resolution, the UI Scale slider, and — on a Mac — the display's own
    -- scaling mode, which WoW cannot see at all.
    --
    -- Two attempts to derive the right number from the outside failed. The
    -- pixel-snapper was rounding 1.667 pixels-per-unit up to 2 and making every
    -- window 20% larger than drawn, which is fixed; the remainder is simply that
    -- the client's own units do not match the design's, and no amount of
    -- arithmetic here can know by how much for a given monitor.
    --
    -- So it is a knob. 100 means whatever the client gives, which is what every
    -- other addon does, and anyone comparing against the design can dial it.
    help = "Scaling for the add-on display",
  },
  {
    key = "names", label = "Names Per Chat Line", default = 3,
    kind = "number", min = 1, max = 10,
    help = "How many raiders to list when you post an item to chat",
  },
  {
    key = "channel", label = "Chat Channel", default = "AUTO",
    kind = "choice", choices = { "AUTO", "RAID", "RAID_WARNING", "PARTY", "SAY" },
    help = "“AUTO” picks Raid, then Party, then Say — whatever you're actually in",
  },
  {
    key = "showGap", label = "Include Scoring Gap From Leader", default = true,
    kind = "toggle",
    help = "Adds the -4 / -7 margin after each badge",
  },
  {
    key = "difficulty", label = "Announcement Content", default = "AUTO",
    -- MPLUS selects CONTENT, not a difficulty: it swaps the Loot tab to the
    -- season's dungeons. Kept on this one setting because it is one control in
    -- the panel — the design has a single dropdown reading "Raid: Heroic".
    kind = "choice", choices = { "AUTO", "NORMAL", "HEROIC", "MYTHIC", "MPLUS" },
    help = "Which loot to show and at what item level. AUTO follows the raid you are in; "
        .. "Dungeons show the season's Mythic+ loot at its fixed drop level",
  },
  {
    key = "vault", label = "Vault / Voidcore Levels", default = false,
    kind = "toggle",
    -- Paired with the Loot tab's Vault/Voidcore checkbox, which is the same
    -- setting. It lives here too so it survives a reload like every other view
    -- choice, and so the one place that lists what the addon can do lists this.
    --
    -- ⚠️ TWO WAYS TO THE SAME ITEM LEVEL, which is why one toggle covers both.
    -- A Nebulous Voidcore bonus roll is rewarded at the equivalent Great Vault
    -- level for that content, so coining a Heroic boss returns Myth track just
    -- as a Heroic vault slot does. Blizzard states it directly ("the power of
    -- items acquired with Nebulous Voidcores is aligned with the equivalent
    -- Great Vault reward for that content"), so this is one number, not two.
    help = "Show each item at the level it would arrive in the Great Vault or from a bonus roll",
  },
  {
    key = "hideMinimap", label = "Hide Minimap Button", default = false,
    kind = "toggle",
    -- The slash command is NAMED here on purpose: this is the one setting that can
    -- take away the only other way in, so the alternative has to be on screen.
    help = "The minimap button is the only way to open the addon without a typed command: |cfff2bdad/la|r",
  },
  {
    key = "autoOpen", label = "Open Panel On A Drop", default = false,
    kind = "toggle",
    help = "Off by default — the window stays out of your way until you manually open it",
  },
  {
    key = "autoPost", label = "Auto-Post Drops To Chat", default = false,
    kind = "toggle",
    help = "The runner's addon posts each drop's shortlist to chat automatically. "
        .. "Only ever fires on a GUILD run — never in LFR or a pug — and only for "
        .. "whomever is running loot",
  },
  {
    key = "minQuality", label = "Record Loot Down To:", default = 4,
    kind = "number", min = 2, max = 5,
    help = "4 = Epic, which is all raid loot. Lower to 3 to record blues",
  },
  {
    -- ⚠️ THE ONE ROW THE MOCK DRAWS THAT THE CODE DID NOT HAVE (Session 258).
    -- The other three the backlog claimed were missing were already here; Jason
    -- caught that. This is the genuine one, and it is the question left open at
    -- the end of Session 256 — apparently settled by being drawn.
    --
    -- WHAT IT DOES, decided here and FLAGGED for Jason rather than stalled on,
    -- per the standing instruction. The roster import and everything downstream
    -- of it is guild machinery: EPGP priority arrives only in the raid-night
    -- export, so for anyone outside this guild the Standings tab, the priority
    -- column and the Import button are all furniture for a thing they will
    -- never have. This turns them off in one press.
    --
    -- ⚠️ IT DOES NOT TOUCH SCORING. The whole upgrade heuristic runs off the
    -- baked payload and the player's own gear, and is exactly as useful to a
    -- stranger as to us — the S256 rule that the ranking needs no export. So
    -- this hides the EPGP half and nothing else.
    key = "noRoster", label = "Disable Roster Import/EPGP System", default = false,
    kind = "toggle",
    help = "Roster data import is only used by HoD guild members. Others should check this box",
    apply = function()
      if ns.Panel and ns.Panel.Refresh then pcall(ns.Panel.Refresh) end
    end,
  },
}


-- Looked up CASE-INSENSITIVELY, and the canonical key is taken from the SPEC
-- rather than from what the user typed.
--
-- /la set lowercased its argument before looking it up, so every setting whose
-- key is not already all-lowercase silently did not exist: showGap, autoOpen and
-- minQuality all answered "unknown setting". Worse, the listing prints the
-- camelCase key, so it was telling people to type the exact string it would then
-- reject. Canonicalising also matters for the WRITE — indexing the saved table
-- with "minquality" would store a second, invisible copy that nothing reads.
local BY_KEY = {}
for _, s in ipairs(Settings.SPEC) do
  BY_KEY[s.key] = s
  BY_KEY[s.key:lower()] = s
end

--- The spec and its canonical key for anything the user might have typed.
local function resolveKey(key)
  local spec = BY_KEY[tostring(key or "")] or BY_KEY[tostring(key or ""):lower()]
  if not spec then return nil, nil end
  return spec, spec.key
end

function Settings.Defaults()
  local out = {}
  for _, s in ipairs(Settings.SPEC) do out[s.key] = s.default end
  return out
end

function Settings.Get(key)
  local db = ns.db and ns.db.settings
  local spec, canonical = resolveKey(key)
  if not spec then return nil end
  local v = db and db[canonical]
  if v == nil then return spec.default end
  return v
end

--- Returns ok, errorMessage. Validates rather than trusting input: a bad value
--- here would not error, it would quietly change what the raid sees.
--- Run a setting's `apply` hook, if it has one. Guarded: a fault in something
--- a setting drives must not stop the setting itself being stored.
local function runApply(spec)
  if spec and spec.apply then pcall(spec.apply) end
end

function Settings.Set(key, value)
  local spec, canonical = resolveKey(key)
  if not spec then return false, "unknown setting: " .. tostring(key) end
  key = canonical
  ns.db.settings = ns.db.settings or Settings.Defaults()

  -- ⚠️ A SLIDER IS A NUMBER THAT IS DRAWN DIFFERENTLY. It validates, clamps and
  -- stores through this same branch, so the range can never disagree between
  -- the control and the slash command that sets the same key.
  -- ⚠️ A SCALE KEEPS ITS DECIMALS. The branch below floors, which is right for a
  -- count of names and destroys the one value this control exists to accept:
  -- 0.3556 would store as 0. Zero is also the sentinel for "use the client's own
  -- scale", so flooring turned every typed scale into "leave it alone" silently.
  if spec.kind == "scale" then
    local n = tonumber(value)
    if not n then return false, ("%s needs a number"):format(spec.label) end
    -- 0 is always allowed: it is how the setting is switched off.
    if n ~= 0 and (n < spec.min or n > spec.max) then
      return false, ("%s must be between %.2f and %.2f, or 0 for your client's own")
        :format(spec.label, spec.min, spec.max)
    end
    ns.db.settings[key] = n
    runApply(spec)
    return true

  elseif spec.kind == "number" or spec.kind == "slider" then
    local n = tonumber(value)
    if not n then return false, ("%s needs a number"):format(spec.label) end
    n = math.floor(n)
    if n < spec.min or n > spec.max then
      return false, ("%s must be between %d and %d"):format(spec.label, spec.min, spec.max)
    end
    ns.db.settings[key] = n
    runApply(spec)
    return true

  elseif spec.kind == "toggle" then
    local s = tostring(value):lower()
    if s == "on" or s == "true" or s == "1" or s == "yes" then
      ns.db.settings[key] = true
    elseif s == "off" or s == "false" or s == "0" or s == "no" then
      ns.db.settings[key] = false
    else
      return false, ("%s is on or off"):format(spec.label)
    end
    runApply(spec)
    return true

  elseif spec.kind == "choice" then
    local want = tostring(value):upper()
    for _, c in ipairs(spec.choices) do
      if c == want then ns.db.settings[key] = c; runApply(spec); return true end
    end
    return false, ("%s must be one of: %s"):format(spec.label, table.concat(spec.choices, ", "))
  end

  return false, "unsupported setting type"
end

function Settings.Reset()
  ns.db.settings = Settings.Defaults()
end

-- ---------------------------------------------------------------------------
-- Slash interface
-- ---------------------------------------------------------------------------

function Settings.Command(rest)
  rest = tostring(rest or "")
  local key, value = rest:match("^(%S+)%s+(.+)$")

  if not key then
    ns.Print("settings:")
    for _, s in ipairs(Settings.SPEC) do
      ns.Line(("|cffF3C56B%s|r = %s  |cff888899%s|r")
        :format(s.key, tostring(Settings.Get(s.key)), s.help))
    end
    ns.Line("Change with |cffF3C56B/la set <key> <value>|r, or open |cffF3C56B/la config|r.")
    return
  end

  if key:lower() == "reset" then
    Settings.Reset()
    ns.Print("settings restored to defaults.")
    return
  end

  local ok, err = Settings.Set(key, value)
  if ok then
    local _, canonical = resolveKey(key)
    ns.Print(("%s = %s"):format(canonical, tostring(Settings.Get(canonical))))
  else
    ns.Warn(err)
  end
end

-- ---------------------------------------------------------------------------
-- Config window
-- ---------------------------------------------------------------------------
-- Built from SPEC, so adding a setting above adds a row here with no extra UI
-- code. Blizzard's addon-settings API is deliberately NOT used: Build Barn does
-- not use it either, and writing against an API this session cannot verify is
-- how the two earlier wrong API assumptions happened.

local frame

-- Geometry is DERIVED from the number of settings, never a fixed height. A
-- hardcoded 420x300 fitted five rows exactly, so adding a sixth (Session 243)
-- pushed the last row's control and help text straight through the footer
-- buttons and out of the frame — WoW frames do not clip their children, the same
-- lesson the panel's row list learned in Session 242. Adding a setting must stay
-- a one-line change to SPEC.
--
-- ROW_H allows TWO lines of help. At 460 wide most help fits on one, but the
-- longest wraps, and a row sized for one line lets the second collide with the
-- next row's control.
-- ── Geometry, read off node 591:2403 (600x760) ─────────────────────────────
--
-- ⚠️ THE ROW PITCH IS NOT CONSTANT. The mock's rows sit at 0, 55, 110, 165,
-- 236, 291, 346, 401, 472 and 527 — a 55 pitch for a row whose help fits one
-- line, and 71 where it wraps to two. A single pitch would either crush the
-- long rows or leave a gap under every short one, so the layout MEASURES which
-- it is rather than assuming.
--
-- ⚠️ RE-READ SESSION 262 (Jason: "the line heights seem wrong as compared to
-- the Figma design"). These were 30 and 44 against a 20 gap, i.e. a 50/64
-- pitch — the numbers in the note above before the mock was revised. Node
-- 591:2402 measures its rows at 35 and 51, so every row in the window was four
-- to seven pixels tight and the whole list crept upward as it went down.
local FRAME_W  = 600
-- The panel's own height. The settings window may be shorter than this and must
-- never be taller.
local FRAME_H_MAX = 600
local HEADER_H = 128            -- the first row's top; lockup and title sit above
-- ⚠️ THE STORED VALUE IS SHOUTED; THE LABEL IS NOT (Session 262). The choices
-- are stored as RAID_WARNING / AUTO / MPLUS and were printed straight onto the
-- control, so the window read as a row of shouting where the mock draws
-- "Raid_Warning" and "Auto". Only the DISPLAY changes — the values these map
-- from are settings keys and are untouched.
local CHOICE_LABEL = { MPLUS = "Dungeons" }
-- The width a fitted control must gain to clear its own caret: the mock's box
-- is the label plus the control's padding plus a 14px gap before the triangle.
local CARET_ALLOW = 14

local function setChoiceLabel(btn, value)
  local shown = CHOICE_LABEL[value]
  if not shown then
    -- Capitalises each word, so an underscore-joined value keeps both halves.
    shown = (tostring(value):lower():gsub("(%a)(%w*)",
      function(a, rest) return a:upper() .. rest end))
  end
  btn:SetText(shown)
  if btn.FitToLabel then
    btn:FitToLabel()
    btn:SetWidth(btn:GetWidth() + CARET_ALLOW)
  end
end

local ROW_H    = 35             -- a one-line row; a wrapping one is ROW_H_TALL
local ROW_H_TALL = 51
local ROW_GAP  = 20
local SET_X    = 40             -- the window's own margin, both sides
local SET_LABEL_Y = 0           -- label at the row's top, help 17 beneath it
local SET_HELP_Y  = 17
-- The controls, each right-aligned to its own edge as the mock places them.
-- ⚠️ MEASURED FROM THE CONTENT COLUMN, NOT THE WINDOW EDGE (Jason, Session
-- 263; node 650:147). The mock's frame starts at x=40 and its controls are
-- placed WITHIN it — the checkbox at 496 of a 522-wide column, so 536 from the
-- window. Read as window offsets they landed 40px too far left, which is the
-- gap between the content and the scrollbar that Jason called too much.
--
-- THE COLUMN'S RIGHT EDGE IS 562 (40 + 522) and every control right-aligns just
-- inside it: checkbox and field to 560, dropdowns to 561.
local SET_COL_W  = 522                       -- node 591:2402
local SET_COL_R  = SET_X + SET_COL_W         -- 562, the column's right edge
local SET_CHECK_X, SET_CHECK_SZ = SET_X + 496, 24
local SET_INPUT_X, SET_INPUT_W, SET_INPUT_H = SET_X + 440, 80, 30
local SET_DROP_W = 131
-- The leftmost edge any control occupies, and the help's right boundary 16
-- short of it. Derived rather than typed, so moving a control moves the text.
-- ⚠️ THE HELP COLUMN IS PER KIND, NOT ONE WIDTH FOR EVERY ROW (node 650:147).
-- The mock's sentences run to 462 beside a checkbox and stop at 390 beside a
-- dropdown, because those controls start in different places. One shared width
-- taken from the narrowest control wrapped every checkbox row far too early —
-- three lines where the design has two.
local SET_DROP_L = SET_COL_R - 1 - SET_DROP_W   -- the wider dropdown's left edge

--- Where a row's leftmost control starts, in content coordinates.
---
--- ⚠️ MEASURED FROM THE CONTROL, NOT ASSUMED FROM ITS KIND. A dropdown sizes
--- itself to its longest choice — ours are 170 wide where the mock's are 131 —
--- so a constant put the help text under them. And a SCALE row's leftmost
--- control is the SLIDER, which begins far left of the field beside it; sizing
--- that help against the field ran the sentence straight through the slider.
local function controlLeft(kind, ctrl)
  local w = (ctrl and ctrl.GetWidth and ctrl:GetWidth()) or 0
  if kind == "toggle" then return SET_CHECK_X end
  if kind == "number" then return SET_INPUT_X end
  if kind == "scale"  then return (SET_INPUT_X - 14) - w end
  if kind == "slider" then return FRAME_W - 60 - w end
  return (SET_COL_R - 1) - (w > 0 and w or SET_DROP_W)
end

local function helpWidthFor(kind, ctrl)
  return math.max(80, controlLeft(kind, ctrl) - SET_X - 16)
end
local SET_CTRL_L = math.min(SET_CHECK_X, SET_INPUT_X, SET_DROP_L)
local SET_HELP_W = SET_CTRL_L - SET_X - 16
local FOOTER_H = 48
-- ⚠️ THE READOUT NEEDS ITS OWN BAND IN THE HEIGHT, and adding it without one is
-- exactly the mistake the note above describes — it drew over the last row's
-- help text, because WoW frames do not clip their children so nothing looked
-- broken, it just overlapped. Three lines of GameFontDisableSmall plus breathing
-- room. If the readout ever gains a fourth line, this number moves with it.
local READOUT_H = 72
-- One wheel notch, in pixels. A row is ~55, so this moves about a third of a
-- row per notch — enough to feel responsive without skipping a setting.
local SCROLL_STEP = 20

--- The window's height, derived rather than fixed. Exposed so the harness can
--- assert every band is accounted for: a region added without a band of its own
--- does not error and does not look broken — WoW frames do not clip children, so
--- it silently draws over whatever was already there. That is how the display
--- readout landed on top of the last setting's help text.
--- How tall a row is: two lines of help wrap, one does not.
---
--- ⚠️ MEASURED FROM THE HELP STRING, not from a per-key table. A table would be
--- a second place to update every time a sentence changes, and the failure is
--- silent — the row simply overlaps the one beneath it.
--- ⚠️ A CHARACTER COUNT IS NOT A HEIGHT (Jason, Session 258 — the rows
--- overlapped). This guessed two lines above 90 characters, which is wrong in
--- both directions once the help column narrows: a 70-character sentence can
--- wrap and a 100-character one may not. The estimate stays as the value used
--- to SIZE the window before anything is drawn; Settings.Layout re-flows from
--- what the font actually reports once the rows exist.
function Settings.RowHeight(spec)
  return (#(spec.help or "") > 70) and ROW_H_TALL or ROW_H
end

--- Re-place every row from the MEASURED height of its help text.
---
--- Runs on Refresh, which runs on show — by which point the fonts have loaded
--- and GetStringHeight answers honestly. Cheap, and it is the only thing that
--- can know how many lines a sentence took at this width.
function Settings.Layout()
  if not (frame and frame.rows) then return end
  local y = 0
  for _, row in ipairs(frame.rows) do
    local h = row.help and row.help:GetStringHeight() or 0
    -- The label sits above the help; the row is whichever is taller than the
    -- one-line minimum.
    -- ⚠️ THE BLOCK'S OWN HEIGHT, WHICH THE NODE GIVES AS 35 AND 51 (Jason,
    -- Session 263: the rows are autolayout with a 20px gap). The help starts 17
    -- down and its line box adds 2 below the last line, so a one-line row is
    -- 17 + 16 + 2 = 35 and a two-line one 51 — the gap between blocks is then
    -- ROW_GAP alone, which is the 20 the autolayout applies.
    local rowH = math.max(ROW_H, SET_HELP_Y + math.ceil(h) + 2)
    row.label:ClearAllPoints()
    row.label:SetPoint("TOPLEFT", SET_X, -(y + SET_LABEL_Y))
    row.help:ClearAllPoints()
    row.help:SetWidth(helpWidthFor(row.spec.kind, row.control))
    row.help:SetPoint("TOPLEFT", SET_X, -(y + SET_HELP_Y))
    -- ⚠️ CONTROLS ARE CENTRED ON THE TEXT BLOCK, NOT PINNED NEAR ITS TOP (Jason,
    -- Session 263 side-by-side). Every control sat at a fixed offset from the
    -- row's top, so a one-line row looked right and a three-line row left the
    -- checkbox floating up beside the label with the sentence running past it.
    -- The mock hand-tunes a different top offset on every single row — 2, 6, 13,
    -- 14, 21 — which is that same centring, measured by eye in Figma. Deriving
    -- it means a row that grows or shrinks keeps its control where it belongs
    -- instead of needing the number retuned.
    local textH = SET_HELP_Y + math.ceil(h)
    local function centred(ctrl, fallbackH)
      local ch = (ctrl and ctrl.GetHeight and ctrl:GetHeight()) or fallbackH
      if not ch or ch <= 0 then ch = fallbackH end
      return y + math.max(0, math.floor((textH - ch) / 2 + 0.5))
    end

    if row.field and row.field.ClearAllPoints then
      row.field:ClearAllPoints()
      row.field:SetPoint("TOPLEFT", SET_INPUT_X, -centred(row.field, SET_INPUT_H))
    end
    if row.control and row.control.ClearAllPoints then
      row.control:ClearAllPoints()
      local kind = row.spec.kind
      if kind == "toggle" then
        row.control:SetPoint("TOPLEFT", SET_CHECK_X, -centred(row.control, SET_CHECK_SZ))
      elseif kind == "number" then
        row.control:SetPoint("TOPLEFT", SET_INPUT_X, -centred(row.control, SET_INPUT_H))
      elseif kind == "scale" then
        -- The slider runs from the text column's right edge to just short of the
        -- field, so the pair reads as one control rather than two.
        row.control:SetPoint("TOPRIGHT", frame.content, "TOPLEFT",
                             SET_INPUT_X - 14, -centred(row.control, 14))
      elseif kind == "slider" then
        row.control:SetPoint("TOPRIGHT", -60, -centred(row.control, 14))
      else
        -- Right-aligned to the column, so the two dropdown widths in the mock
        -- (131 and 81) both finish on the same edge.
        row.control:SetPoint("TOPRIGHT", frame.content, "TOPLEFT", SET_COL_R - 1,
                             -centred(row.control, 30))
      end
    end
    y = y + rowH + ROW_GAP
  end
  if frame.content then frame.content:SetHeight(math.max(1, y)) end
  return y
end

--- How tall the ROWS are, all together.
function Settings.ContentHeight()
  local h = 0
  for _, spec in ipairs(Settings.SPEC) do
    h = h + Settings.RowHeight(spec) + ROW_GAP
  end
  return h
end

--- ⚠️ CAPPED AT THE ADDON WINDOW'S OWN HEIGHT (Jason, Session 258: "the
--- settings page is comically large. It shouldn't be taller than the addon
--- window itself — it needs to scroll. I just built it that height in Figma to
--- show all the pieces").
---
--- The mock is 760 tall because a drawing has to show every row at once; a
--- WINDOW does not, and one taller than the panel it configures is absurd on a
--- laptop. So the natural height is computed and then clamped, and the rows
--- scroll inside whatever is left. Reading the mock's height as a specification
--- was the mistake — it is a canvas, not a constraint.
function Settings.WindowHeight()
  local natural = HEADER_H + Settings.ContentHeight() + READOUT_H + FOOTER_H
  return math.min(natural, FRAME_H_MAX)
end

local function build()
  local height = Settings.WindowHeight()

  -- ⚠️ NO BLIZZARD TEMPLATE (Jason, Session 262). Same reason as the Loot Log:
  -- the template was here for its CloseButton alone and brought the gold rim
  -- and inset with it. Style.CloseButton supplies the design's own X.
  frame = CreateFrame("Frame", "HoDLootAdvisorConfigFrame", UIParent)
  frame:SetSize(FRAME_W, height)
  frame:SetPoint("CENTER")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetFrameStrata("DIALOG")
  ns.MakeWindow(frame)
  frame:Hide()

  local S = ns.Style
  -- The secondary windows' lighter violet, painted OVER what MakeWindow put
  -- down rather than layered on it — Style.PanelGround's own comment records
  -- what happens otherwise.
  if S then
    if frame.bgTex then frame.bgTex:Hide() end
    if frame.headTex then frame.headTex:Hide() end
    if frame.headLine then frame.headLine:Hide() end
    -- No rim: the fill is the window, exactly as on the panel.
    S.Surface(frame, S.COLOR.windowGround, 1)
    S.Lockup(frame, SET_X, 30)
    frame.close = S.CloseButton(frame)
  end

  -- ── The header band ───────────────────────────────────────────────────────
  -- ⚠️ A BAND, NOT A RULE (Jason's mock, Session 263). The lockup and the word
  -- SETTINGS sit on the panel's OWN darker ground, over the window's lighter
  -- violet — so the header is separated by SURFACE, the same idea the Loot
  -- tab's footer already uses, rather than by a line drawn across the window.
  -- It also gives the scrolling rows something to disappear behind.
  if S then
    -- ⚠️ NO HEADER BAND (Jason, Session 263 side-by-side: "there's a dark header
    -- background on addon"). I added one reading a darker rectangle off the top
    -- of the mock, and on screen it reads as a hard seam the design has not got —
    -- the title simply sits on the window's own ground. Only the FOOTER is
    -- banded, which is what closes the scrolling area off at the bottom.
    frame.footBand = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    frame.footBand:SetColorTexture(S.rgb(S.COLOR.ground))
    frame.footBand:SetPoint("BOTTOMLEFT")
    frame.footBand:SetPoint("BOTTOMRIGHT")
    frame.footBand:SetHeight(FOOTER_H + READOUT_H)
  end

  frame.heading = S and S.Text(frame, "light", "title", S.COLOR.white, "LEFT")
    or frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  if S then S.SetFont(frame.heading, S.FONT.light, 18) end
  frame.heading:ClearAllPoints()
  frame.heading:SetPoint("TOPLEFT", SET_X, -86)
  frame.heading:SetText("SETTINGS")

  -- ── The scrolling body ────────────────────────────────────────────────────
  -- The rows live in a scroll child rather than on the window, so the window
  -- can be shorter than its own content. Everything below places rows at
  -- offsets from the CONTENT's top; the scroll frame supplies the rest.
  -- ⚠️ NO TEMPLATE, ON PURPOSE (Jason, Session 263: the scrollbar "looks
  -- awful"). This was UIPanelScrollFrameTemplate, which brings Blizzard's own
  -- parchment track and arrow buttons into a window whose whole design has no
  -- chrome at all. The previous attempt HID that furniture by NAME — and the
  -- names it knew are the old ones, so on current retail the buttons came back
  -- and sat in the corner of the settings window looking like a different addon.
  --
  -- Hiding a template's internals is guessing at something that is explicitly
  -- not contractual and changes between patches. Not inheriting them cannot
  -- fail that way: a bare ScrollFrame has no furniture to hide.
  --
  -- THE WHEEL IS HOW EVERYTHING ELSE HERE SCROLLS — the loot column, the
  -- standings table and the ranking list all do exactly this and none of them
  -- draws a bar. Consistent with the rest of the addon, and with a design that
  -- has no scrollbar drawn in any of its frames.
  frame.scroll = CreateFrame("ScrollFrame", nil, frame)
  frame.scroll:SetPoint("TOPLEFT", 0, -HEADER_H)
  frame.scroll:SetPoint("BOTTOMRIGHT", -26, FOOTER_H + READOUT_H)

  frame.scroll:EnableMouseWheel(true)
  frame.scroll:SetScript("OnMouseWheel", function(self, delta)
    -- Clamped at both ends: WoW does not clamp for you, and scrolling past the
    -- bottom leaves the rows parked off-screen with no way back but the wheel.
    local max = math.max(0, (self:GetScrollChild() and self:GetScrollChild():GetHeight() or 0)
                            - (self:GetHeight() or 0))
    local to = (self:GetVerticalScroll() or 0) - delta * SCROLL_STEP
    if to < 0 then to = 0 elseif to > max then to = max end
    self:SetVerticalScroll(to)
    if frame.UpdateBar then frame.UpdateBar() end
    if frame.NudgeBar then frame.NudgeBar() end
  end)

  -- ── The scrollbar ─────────────────────────────────────────────────────────
  -- ⚠️ OURS, DRAWN FROM THE MOCK: a 5px fully-rounded thumb in the accent
  -- purple at 30%, down the right edge. Blizzard's went out because its
  -- parchment arrows belong to a different addon; this is what the design puts
  -- there instead, and it is a plain texture rather than a Slider so there is
  -- no template chrome to come back.
  --
  -- IT IS AN INDICATOR, NOT A HANDLE. The wheel does the scrolling — everything
  -- in this addon scrolls that way — so this reports position and length and
  -- takes no input, which is also why it needs no hit area or arrows.
  -- Node 649:130: a 5px bar whose right edge sits 10px inside the window.
  local BAR_W, BAR_INSET = 5, 10
  -- ⚠️ THE TRACK STOPS SHORT OF THE FOOTER (Jason, Session 263). Running it to
  -- the full height of the scroll area put the thumb's bottom edge against the
  -- footer band at the end of a scroll, so the two read as touching. The node
  -- has the bar ending well above it; the exact figure is not specified and he
  -- said he did not mind, so this is one named constant to change.
  local BAR_BOTTOM = 20
  frame.bar = frame:CreateTexture(nil, "OVERLAY")
  frame.bar:SetColorTexture(1, 1, 1, 1)
  -- A rounded cap needs a mask; without one this is a 5px rectangle, which the
  -- mock's 100px radius is explicitly not.
  if frame.bar.SetTexture then
    frame.bar:SetTexture("Interface\\Buttons\\WHITE8X8")
  end
  if S then frame.bar:SetVertexColor(S.rgb(S.COLOR.accent)) end
  frame.bar:SetWidth(BAR_W)
  frame.bar:SetAlpha(0.3)
  frame.bar:Hide()

  --- Put the thumb where the scroll offset says, and size it to how much of the
  --- content is on screen. Hidden outright when everything already fits, since a
  --- full-height bar that cannot move is furniture rather than information.
  function frame.UpdateBar()
    local sf, child = frame.scroll, frame.content
    if not (sf and child) then return end
    local view, total = sf:GetHeight() or 0, child:GetHeight() or 0
    if total <= view + 1 then frame.bar:Hide(); return end
    -- The travel available to the thumb, which is the visible height less the
    -- clearance kept at the bottom. The thumb is that same fraction of it, so a
    -- longer list still gives a shorter thumb.
    local track = math.max(1, view - BAR_BOTTOM)
    local thumb = math.max(24, track * (view / total))
    local at = (sf:GetVerticalScroll() or 0) / math.max(1, total - view)
    frame.bar:ClearAllPoints()
    frame.bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -BAR_INSET,
                       -(HEADER_H + at * (track - thumb)))
    frame.bar:SetHeight(thumb)
    frame.bar:Show()
  end

  --- ⚠️ DIM WHEN IT IS NOT IN USE (Jason). Brightens on a wheel notch and fades
  --- back a moment later, so the bar says where you are while you are moving and
  --- stays out of the way when you are reading.
  local fadeAt
  function frame.NudgeBar()
    frame.bar:SetAlpha(0.65)
    fadeAt = GetTime and GetTime() + 1.2 or nil
  end
  frame:HookScript("OnUpdate", function()
    if fadeAt and GetTime and GetTime() >= fadeAt then
      fadeAt = nil
      frame.bar:SetAlpha(0.3)
    end
  end)

  frame.content = CreateFrame("Frame", nil, frame.scroll)
  frame.content:SetSize(FRAME_W - 26, math.max(1, Settings.ContentHeight()))
  frame.scroll:SetScrollChild(frame.content)

  -- ⚠️ A DRAG ENDS WHEN THE WINDOW DOES. Without this the slider keeps
  -- `_dragging` set after the window closes mid-drag — and Settings.Refresh
  -- refuses to write into a slider that thinks it is being dragged, so the
  -- control would silently stop tracking the stored value for the rest of the
  -- session. The scale hold is released alongside it (Core's TrackWindow does
  -- the same from its side; both are cheap and neither is sufficient alone).
  frame:HookScript("OnHide", function()
    for _, row in ipairs(frame.rows or {}) do
      local c = row.control
      if c and c.IsDragging and c:IsDragging() then c._dragging = false end
    end
    if ns.ReleaseWindowScale then ns.ReleaseWindowScale() end
  end)

  frame.rows = {}
  local y = 0

  for _, spec in ipairs(Settings.SPEC) do
    -- ⚠️ UPPERCASE, IN THE HEADING PURPLE — the same treatment every heading in
    -- the redesign takes, from the Standings rail to the Runner's sections.
    local label = S and S.Text(frame.content, "bold", "head", S.COLOR.accent, "LEFT")
      or frame.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:ClearAllPoints()
    label:SetPoint("TOPLEFT", SET_X, -(y + SET_LABEL_Y))
    label:SetText((spec.label or ""):upper())

    local help = S and S.Text(frame.content, "light", "label", S.COLOR.white, "LEFT")
      or frame.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    help:ClearAllPoints()
    help:SetPoint("TOPLEFT", SET_X, -(y + SET_HELP_Y))
    -- Stops short of the control column rather than running the full width, so
    -- a long sentence wraps instead of sliding under a checkbox.
    -- ⚠️ STOPS BEFORE THE NARROWEST CONTROL, NOT THE CHECKBOX (Jason, Session
    -- 258 — the help ran underneath the AUTO and RAID_WARNING buttons). The
    -- checkbox starts at 496 and the DROPDOWN at 403, so sizing the help
    -- against the checkbox let it run 93px into the dropdown's column. One
    -- width for every row, taken from whichever control starts furthest left.
    help:SetWidth(helpWidthFor(spec.kind, control))
    help:SetJustifyH("LEFT")
    help:SetWordWrap(true)
    -- ⚠️ NOT CAPPED (Jason, Session 263: "truncated with no way to actually read
    -- the full description"). This was SetMaxLines(2), so any sentence longer
    -- than two lines ended in an ellipsis and the rest was simply unreachable —
    -- there is no tooltip on these and no way to widen the column. The cap was
    -- there to stop a row growing past the height it had been measured for, but
    -- Settings.Layout re-measures every row from GetStringHeight on show, so the
    -- row grows to fit and nothing overlaps. The cap was defending against a
    -- problem the layout had already solved.
    help:SetText(spec.help)

    local control, field
    if spec.kind == "toggle" then
      -- ⚠️ THE DESIGN'S OWN CHECKBOX, not Blizzard's — a 24px square with the
      -- control's gradient rim and the mock's 10x7 tick, which is what
      -- Style.Check already draws for the Loot tab's Vault control. Passing an
      -- EMPTY label because this row has drawn its own above the help text.
      -- Node 591:2365's own SVG: a #0c0721 fill with a FLAT rule-blush rim at
      -- 30% — not the control-rim gradient the Loot tab's Vault box carries.
      -- The two boxes genuinely differ; see the note on Style.Check.
      control = S and S.Check(frame.content, "", SET_CHECK_SZ,
          { fill = S.COLOR.ground, rim = S.COLOR.rule, rimAlpha = 0.3 })
        or CreateFrame("CheckButton", nil, frame.content)
      control:SetSize(SET_CHECK_SZ, SET_CHECK_SZ)
      control:SetPoint("TOPLEFT", SET_CHECK_X, -(y + 4))
      control:SetScript("OnClick", function(self)
        -- ⚠️ Style.Check DOES NOT TOGGLE ITSELF. It is a plain Button with
        -- SetChecked/GetChecked bolted on, so its state only moves when someone
        -- moves it — unlike a CheckButton, which has already flipped by the time
        -- OnClick runs. Reading GetChecked without flipping first would store
        -- the value it already had, every press, silently.
        local on = self:GetChecked()
        if self._hodStyled then
          on = not on
          self:SetChecked(on)
        end
        Settings.Set(spec.key, on and "on" or "off")
      end)

    elseif spec.kind == "scale" then
      -- ⚠️ TWO CONTROLS ON ONE ROW (Jason's mock, Session 263): the slider to
      -- drag, and a field to type an exact value into. The field is the reason
      -- the readout in the footer is worth printing — "a scale of 0.3556 would
      -- put one unit on one pixel" is only useful if 0.3556 can be entered.
      control = ns.Style and ns.Style.Slider(frame.content, 210, spec.min, spec.max,
                                             spec.step, spec.decimals)
      field = S and S.Input(frame.content, SET_INPUT_W, SET_INPUT_H)
        or CreateFrame("EditBox", nil, frame.content)
      field:SetSize(SET_INPUT_W, SET_INPUT_H)
      field:SetPoint("TOPLEFT", SET_INPUT_X, -(y + 2))
      field:SetAutoFocus(false)
      -- ⚠️ NOT SetNumeric — it refuses the decimal point, so the one format this
      -- field exists to accept could not be typed into it at all.
      field:SetMaxLetters(8)

      local function commitField(self)
        local ok, err = Settings.Set(spec.key, self:GetText())
        if not ok then ns.Warn(err) end
        self:SetText(("%.4f"):format(ns.CurrentWindowScale()))
        self:ClearFocus()
        Settings.Refresh()
      end
      field:SetScript("OnEnterPressed", commitField)
      field:SetScript("OnEditFocusLost", commitField)
      field:SetScript("OnEscapePressed", function(self)
        self:SetText(("%.4f"):format(ns.CurrentWindowScale()))
        self:ClearFocus()
      end)

      if control then
        -- ⚠️ THE SLIDER'S OWN READOUT IS HIDDEN HERE. Style.Slider draws a value
        -- label beside itself, which is right for a lone slider and wrong beside
        -- a field showing the same number — it rendered as a stray "1" wedged
        -- between the two controls, which is exactly how Jason described it.
        if control.value then control.value:Hide() end
        -- Left of the field, on the same line, as the mock draws it.
        control:SetPoint("TOPRIGHT", frame.content, "TOPLEFT",
                         SET_INPUT_X - 14, -(y + 10))
        control:Wire(nil, function(v)
          if v == Settings.Get(spec.key) then return end
          if control:IsDragging() then ns.HoldWindowScale(frame) end
          Settings.Set(spec.key, v)
          if not field:HasFocus() then field:SetText(("%.4f"):format(v)) end
        end,
        function() ns.ReleaseWindowScale() end)
      end

    elseif spec.kind == "slider" then
      control = ns.Style and ns.Style.Slider(frame.content, 150, spec.min, spec.max, spec.step)
      if control then
        control:SetPoint("TOPRIGHT", -60, -y)
        control:Wire(spec.suffix, function(v)
          -- Only write when it actually moved: OnValueChanged fires while the
          -- window is being POPULATED too, and storing there would rewrite the
          -- setting from the widget on every open.
          if v == Settings.Get(spec.key) then return end
          -- ⚠️ THIS WINDOW IS HELD OUT OF THE LIVE RESIZE WHILE THE KNOB IS
          -- HELD. Scaling the window the slider sits on moves the slider under
          -- the cursor, which changes the value, which scales again — the loop
          -- that made this control impossible to use. Every OTHER window still
          -- resizes live, which is the feedback that matters: you are sizing
          -- the panel, and you can see the panel.
          if control:IsDragging() then ns.HoldWindowScale(frame) end
          Settings.Set(spec.key, v)
        end,
        -- On release the held window catches up, in one step, with the knob
        -- already where the user let go of it.
        function() ns.ReleaseWindowScale() end)

      end

    elseif spec.kind == "number" then
      -- ⚠️ THE DESIGN'S FIELD, NOT InputBoxTemplate (Jason, Session 262). See
      -- Style.Input — the template's gold beading was the last piece of game
      -- chrome in this window.
      control = S and S.Input(frame.content, SET_INPUT_W, SET_INPUT_H)
        or CreateFrame("EditBox", nil, frame.content)
      control:SetSize(SET_INPUT_W, SET_INPUT_H)
      control:SetPoint("TOPLEFT", SET_INPUT_X, -(y + 2))
      control:SetAutoFocus(false)
      control:SetNumeric(true)
      -- Committed on ENTER *and* on losing focus. Enter-only is why "Close"
      -- read as "discard": typing 4 and clicking Close threw the 4 away with no
      -- indication, which is exactly the behaviour the button name implied and
      -- the only place in this window where anything could actually be lost.
      local function commit(self)
        local typed = self:GetText()
        if typed ~= tostring(Settings.Get(spec.key)) then
          local ok, err = Settings.Set(spec.key, typed)
          if not ok then ns.Warn(err) end
        end
        self:SetText(tostring(Settings.Get(spec.key)))
      end
      control:SetScript("OnEnterPressed", function(self)
        commit(self)
        self:ClearFocus()
      end)
      control:SetScript("OnEditFocusLost", commit)
      -- Escape is the one deliberate discard, and it reverts rather than commits.
      control:SetScript("OnEscapePressed", function(self)
        self:SetText(tostring(Settings.Get(spec.key)))
        self:ClearFocus()
      end)

    elseif spec.kind == "choice" then
      -- A plain cycling button rather than a dropdown: five values, one click
      -- each, and no UIDropDownMenu boilerplate to get wrong.
      -- The mock draws these as the panel's filled dropdown control, so they
      -- take the same primitive as the Loot tab's difficulty picker rather than
      -- a stock button. Still a CYCLER underneath — five values, one click each.
      control = S and S.Control(frame.content, "", "head")
        or CreateFrame("Button", nil, frame.content, "UIPanelButtonTemplate")
      control:SetHeight(SET_INPUT_H)
      -- ⚠️ RIGHT-ALIGNED AND SIZED TO ITS OWN LABEL (Session 262, node
      -- 591:2346 / 591:2372). It was pinned at a fixed 131 wide and a derived
      -- left edge, so "Auto" sat in a box built for "Raid_Warning" and the two
      -- dropdowns' right edges did not line up with each other or with the
      -- checkboxes above them. The mock draws 131 and 81 ending on the SAME
      -- edge, which is what a fit-to-label control does for free.
      control:SetPoint("TOPRIGHT", frame.content, "TOPRIGHT", -2, -(y + 2))
      if control.SetActive then control:SetActive(true) end
      -- ⚠️ THE CARET IS DRAWN (Session 262). A control that cycles on click
      -- with nothing to say so reads as a label; the mock puts the panel's own
      -- 6px triangle 20 in from the right edge, exactly like the difficulty
      -- picker on the Loot tab.
      if S then
        control.caret = control:CreateTexture(nil, "OVERLAY")
        control.caret:SetSize(6, 6)
        control.caret:SetPoint("RIGHT", -14, 0)
        control.caret:SetTexture("Interface\\AddOns\\HoDLootAdvisor\\Media\\ui\\caret.png")
        -- The control's own text colour, matching both dropdowns on the panel.
        control.caret:SetVertexColor(S.rgb(S.COLOR.controlText))
      end
      control:SetScript("OnClick", function(self)
        local cur = Settings.Get(spec.key)
        local idx = 1
        for i, c in ipairs(spec.choices) do if c == cur then idx = i end end
        local nextChoice = spec.choices[(idx % #spec.choices) + 1]
        Settings.Set(spec.key, nextChoice)
        setChoiceLabel(self, nextChoice)
      end)
    end

    frame.rows[#frame.rows + 1] =
      { spec = spec, control = control, label = label, help = help, field = field }
    y = y + Settings.RowHeight(spec) + ROW_GAP
  end

  -- ⚠️ THE TWO CONTROLS TAKE THE REDESIGN'S BUTTON PRIMITIVE, at the mock's own
  -- widths: RESTORE DEFAULTS 180 on the left margin, DONE 74 on the right.
  local S2 = ns.Style
  local reset = S2 and S2.Control(frame, "RESTORE DEFAULTS")
    or CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  reset:SetSize(180, 26)
  reset:SetPoint("BOTTOMLEFT", SET_X, 27)
  if reset.SetActive then reset:SetActive(false) end
  if reset.Repaint then reset:Repaint() end
  if not S2 then reset:SetText("Restore Defaults") end
  reset:SetScript("OnClick", function()
    Settings.Reset()
    Settings.Refresh()
  end)

  -- "Done", not "Close" and not "Save".
  --
  -- Jason's point stands: Close implies closing WITHOUT saving. But this window
  -- has no unsaved state to save — every control writes through the moment you
  -- change it, and a Save button would be a lie in the other direction, implying
  -- that nothing had happened until you pressed it. Done says the truth, and the
  -- line beside it removes the doubt rather than leaving the button to carry it.
  -- ⚠️ NO HINT LINE. The reasoning above is sound and the design does not carry
  -- it: node 649:129 is the whole footer — a 34-tall text block and a 29-tall
  -- button row, and nothing else. Read from the node rather than argued about.

  -- ── Display readout ────────────────────────────────────────────────────────
  --
  -- Says whether this client is drawing the addon on whole pixels. It exists
  -- because "the panel looks blurry" is otherwise unfalsifiable — it reads as a
  -- matter of taste when it is in fact an arithmetic question with one answer.
  -- ns.DisplayReport does the arithmetic (Core.lua, inside the harness's reach);
  -- this only prints it.
  -- ⚠️ SAIRA, SMALL AND MUTED — NOT GameFontDisableSmall (Jason, Session 262:
  -- "it needs to be a smaller font size and use Saira, rather than whatever
  -- this blizz default font is"). It was the one piece of text in the addon
  -- still set in the game's own face, which is exactly why it read as debug
  -- output rather than as part of the window.
  --
  -- KEPT RATHER THAN DELETED, and this is a judgement call Jason left open. It
  -- is the only thing that answers "why is my window the wrong size": the panel
  -- size is a SETTING precisely because the client cannot see the monitor's own
  -- scaling (Core §1.1, S257), and this readout is the only feedback anyone has
  -- while turning that dial. Say the word and it goes.
  -- ⚠️ TWO STRINGS, BECAUSE ONE FONTSTRING CARRIES ONE FONT. Node 649:123 sets
  -- the date line in Saira BOLD and the display line in Light, both 10px and
  -- both WHITE at full opacity — it was one dim 9px Light string, which is
  -- wrong on weight, size and colour at once. A colour escape can recolour a
  -- run but cannot reweight it, which is the rule the tag lines already follow.
  --
  -- THE GAP IS THE NODE'S OWN: the date line has a 10px line box and the display
  -- line a 14px one, so the 4px difference is the space between them rather than
  -- a number chosen to look right.
  frame.dataLine = S2 and S2.Text(frame, "bold", "label", S2.COLOR.white, "LEFT")
    or frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.dataLine:ClearAllPoints()
  frame.dataLine:SetPoint("BOTTOMLEFT", SET_X, FOOTER_H + READOUT_H - 24)
  frame.dataLine:SetPoint("BOTTOMRIGHT", -SET_X, FOOTER_H + READOUT_H - 24)
  frame.dataLine:SetJustifyH("LEFT")
  frame.dataLine:SetHeight(10)

  frame.display = S2 and S2.Text(frame, "light", "label", S2.COLOR.white, "LEFT")
    or frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.display:ClearAllPoints()
  frame.display:SetPoint("TOPLEFT", frame.dataLine, "BOTTOMLEFT", 0, -4)
  frame.display:SetPoint("TOPRIGHT", frame.dataLine, "BOTTOMRIGHT", 0, -4)
  frame.display:SetJustifyH("LEFT")
  frame.display:SetJustifyV("TOP")
  frame.display:SetHeight(24)
  frame.display:SetWordWrap(true)

  local close = S2 and S2.Control(frame, "DONE")
    or CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  close:SetSize(74, 26)
  close:SetPoint("BOTTOMRIGHT", -SET_X, 27)
  if close.SetActive then close:SetActive(false) end
  if close.Repaint then close:Repaint() end
  if not S2 then close:SetText("Done") end
  close:SetScript("OnClick", function()
    -- Commit anything still being typed before the window goes away.
    for _, row in ipairs(frame.rows) do
      if row.control and row.control.ClearFocus then row.control:ClearFocus() end
    end
    frame:Hide()
  end)
end

--- The display readout's text. Separate from Refresh so the harness can check
--- the WORDING against a known report rather than only the arithmetic.
--- The one useful sentence about this display, and nothing else.
---
--- ⚠️ IT USED TO REPORT THREE NUMBERS AND CONFUSE ALL THREE (Jason, Session
--- 263). It printed the EFFECTIVE scale — the setting multiplied by the game's
--- own UI scale — under the bare word "scale", so it matched neither what was
--- typed into Panel Size nor anything in the game's settings, and it moved
--- whenever the dial moved. Pixels-per-unit and the worst drift were engineering
--- telemetry that answered a question nobody was asking.
---
--- What remains is the only actionable fact: the Panel Size that makes text land
--- on whole pixels here. It is anchored to the window's natural size, so it does
--- not move as the dial does, and it is in the same units as the field above it.
function Settings.DisplayLine(r)
  if not r then return "" end
  local line = ("Display %d x %d  ·  text is sharpest at Panel Size %.4f")
    :format(r.screenWidth, r.screenHeight, r.perfectPanelSize or 1)
  if not r.aligned then
    line = line .. "\nText is currently landing between pixels, which is what reads as blur."
  end
  return line
end


--- When the BIS and loot data this addon carries was generated, as a date.
---
--- ⚠️ THIS IS THE ONE FACT NOBODY COULD SEE (Jason, Session 263). The addon has
--- always known its data's date, but only as a line printed by a typed command,
--- so the question "is my BIS list current?" had no answer inside the window —
--- and the way it surfaced was Jason spotting a trinket that disagreed with Icy
--- Veins, which is the expensive way to find out.
---
--- It matters most for the people this addon reaches through CurseForge, who
--- have no other way to tell whether their copy is behind.
---
--- The date alone, not the timestamp: this answers "how old is this", and an
--- hour and minute invites a precision the weekly refresh does not have.
function Settings.DataLine()
  local meta = (ns.Data() or {}).meta or {}
  local gen = meta.generatedAt
  if type(gen) ~= "string" or gen == "" then
    return "Loot and BIS data: this copy carries no generation date."
  end
  return ("Loot and BIS data generated %s."):format(gen:sub(1, 10))
end

function Settings.Refresh()
  if not frame then return end
  if frame.display and ns.DisplayReport then
    frame.dataLine:SetText(Settings.DataLine())
    frame.display:SetText(Settings.DisplayLine(ns.DisplayReport()))
  end
  -- Re-flow before writing values in: the rows have to be where they belong
  -- before anything is measured against them.
  Settings.Layout()
  -- The bar's length is a fraction of the content height, which Layout has just
  -- recomputed — so it is updated here rather than only on a wheel notch, or it
  -- would describe the list as it was before the last change.
  if frame.UpdateBar then frame.UpdateBar() end

  for _, row in ipairs(frame.rows) do
    local v = Settings.Get(row.spec.key)
    if row.spec.kind == "toggle" then
      row.control:SetChecked(v and true or false)
    elseif row.spec.kind == "slider" then
      -- ⚠️ NEVER WHILE IT IS BEING DRAGGED. Writing the stored value back into
      -- the widget mid-drag fights the drag: the knob jumps to where the value
      -- was rather than where the finger is.
      if not (row.control.IsDragging and row.control:IsDragging()) then
        row.control:SetValue(tonumber(v) or row.spec.default)
      end
    elseif row.spec.kind == "scale" then
      local n = tonumber(v) or 0
      -- 0 means "the client's own", and showing the number it resolves to is
      -- more use than showing a zero nobody typed.
      local shown = (n > 0) and n or (ns.CurrentWindowScale and ns.CurrentWindowScale()) or 0
      if row.control and not (row.control.IsDragging and row.control:IsDragging()) then
        row.control:SetValue(shown)
      end
      if row.field and not row.field:HasFocus() then
        row.field:SetText(("%.4f"):format(shown))
      end
    elseif row.spec.kind == "number" then
      row.control:SetText(tostring(v))
    elseif row.spec.kind == "choice" then
      setChoiceLabel(row.control, v)
    end
  end
end

function Settings.Toggle()
  if not frame then build() end
  if frame:IsShown() then frame:Hide(); return end
  Settings.Refresh()
  -- RIGHT of the panel: the loot log and the paste window take the left, and
  -- settings can be open alongside either of them.
  ns.DockBesidePanel(frame, "RIGHT")
  frame:Show()
end
