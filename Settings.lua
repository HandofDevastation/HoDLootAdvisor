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
    key = "names", label = "Names Per Chat Line", default = 3,
    kind = "number", min = 1, max = 10,
    help = "How many raiders to list when you post an item to chat.",
  },
  {
    key = "channel", label = "Chat Channel", default = "AUTO",
    kind = "choice", choices = { "AUTO", "RAID", "RAID_WARNING", "PARTY", "SAY" },
    help = "AUTO picks raid, then party, then say — whatever you are actually in.",
  },
  {
    key = "showGap", label = "Include Gap From Leader", default = true,
    kind = "toggle",
    help = "Adds the -4 / -7 margin after each badge.",
  },
  {
    key = "difficulty", label = "Content", default = "AUTO",
    -- MPLUS selects CONTENT, not a difficulty: it swaps the Loot tab to the
    -- season's dungeons. Kept on this one setting because it is one control in
    -- the panel — the design has a single dropdown reading "Raid: Heroic".
    kind = "choice", choices = { "AUTO", "NORMAL", "HEROIC", "MYTHIC", "MPLUS" },
    help = "Which loot to show, and at what item level. AUTO follows the raid you are in; "
        .. "Dungeons shows the season's Mythic+ loot at its fixed drop level.",
  },
  {
    key = "panelScale", label = "Panel Size (%)", default = 100,
    kind = "slider", min = 50, max = 200, step = 1, suffix = "%",
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
    help = "How large the Loot Advisor window draws. 100 is the size your client gives it; "
        .. "lower it if the window is bigger than you want on your monitor.",
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
    help = "Show each item at the level it would arrive at from the WEEKLY CHEST or a "
        .. "Voidcore bonus roll rather than the level the boss drops — a full track "
        .. "higher, so a Heroic kill is worth Myth 1/6 either way. Only offered once "
        .. "a difficulty is chosen.",
  },
  {
    key = "hideMinimap", label = "Hide Minimap Button", default = false,
    kind = "toggle",
    help = "The button is the only way in that is not a typed command, so it is "
        .. "shown by default.",
  },
  {
    key = "autoOpen", label = "Open Panel On A Drop", default = false,
    kind = "toggle",
    help = "Off by default — the window stays out of your way until you open it.",
  },
  {
    key = "autoPost", label = "Auto-Post Drops To Chat", default = false,
    kind = "toggle",
    help = "The runner's addon posts each drop's shortlist to chat automatically. "
        .. "Only ever fires on a GUILD run — never in LFR or a pug — and only for "
        .. "whoever is running loot. Off by default; the Post button is unaffected.",
  },
  {
    key = "minQuality", label = "Record Loot Down To", default = 4,
    kind = "number", min = 2, max = 5,
    help = "4 = Epic, which is all raid loot. Lower to 3 to record blues — how "
        .. "you test the recorder in a follower dungeon.",
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
    help = "Roster data import is only used by HoD guild members. Others should "
        .. "check this box.",
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
  if spec.kind == "number" or spec.kind == "slider" then
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
-- ⚠️ THE ROW PITCH IS NOT CONSTANT. The mock's rows sit at 0, 50, 100, 150,
-- 214, 264, 314, 364, 428 and 478 — a 50 pitch for a row whose help fits one
-- line, and 64 where it wraps to two. A single pitch would either crush the
-- long rows or leave a gap under every short one, so the layout MEASURES which
-- it is rather than assuming.
local FRAME_W  = 600
local HEADER_H = 128            -- the first row's top; lockup and title sit above
local ROW_H    = 30             -- a one-line row; a wrapping one is ROW_H_TALL
local ROW_H_TALL = 44
local ROW_GAP  = 20
local SET_X    = 40             -- the window's own margin, both sides
local SET_LABEL_Y = 0           -- label at the row's top, help 16 beneath it
local SET_HELP_Y  = 16
-- The controls, each right-aligned to its own edge as the mock places them.
local SET_CHECK_X, SET_CHECK_SZ = 496, 24
local SET_INPUT_X, SET_INPUT_W, SET_INPUT_H = 440, 80, 30
local SET_DROP_W = 131
local FOOTER_H = 48
-- ⚠️ THE READOUT NEEDS ITS OWN BAND IN THE HEIGHT, and adding it without one is
-- exactly the mistake the note above describes — it drew over the last row's
-- help text, because WoW frames do not clip their children so nothing looked
-- broken, it just overlapped. Three lines of GameFontDisableSmall plus breathing
-- room. If the readout ever gains a fourth line, this number moves with it.
local READOUT_H = 58

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
function Settings.RowHeight(spec)
  return (#(spec.help or "") > 90) and ROW_H_TALL or ROW_H
end

function Settings.WindowHeight()
  local h = HEADER_H
  for _, spec in ipairs(Settings.SPEC) do
    h = h + Settings.RowHeight(spec) + ROW_GAP
  end
  return h + READOUT_H + FOOTER_H
end

local function build()
  local height = Settings.WindowHeight()

  frame = CreateFrame("Frame", "HoDLootAdvisorConfigFrame", UIParent, "BasicFrameTemplateWithInset")
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
    S.Surface(frame, S.COLOR.windowGround, 1)
    S.Rim(frame, S.COLOR.rim, 0.4)
    S.Lockup(frame, SET_X, 30)
  end

  frame.heading = S and S.Text(frame, "light", "title", S.COLOR.white, "LEFT")
    or frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  if S then S.SetFont(frame.heading, S.FONT.light, 18) end
  frame.heading:ClearAllPoints()
  frame.heading:SetPoint("TOPLEFT", SET_X, -86)
  frame.heading:SetText("SETTINGS")

  frame.rows = {}
  local y = -HEADER_H

  for _, spec in ipairs(Settings.SPEC) do
    -- ⚠️ UPPERCASE, IN THE HEADING PURPLE — the same treatment every heading in
    -- the redesign takes, from the Standings rail to the Runner's sections.
    local label = S and S.Text(frame, "bold", "head", S.COLOR.accent, "LEFT")
      or frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:ClearAllPoints()
    label:SetPoint("TOPLEFT", SET_X, y + SET_LABEL_Y)
    label:SetText((spec.label or ""):upper())

    local help = S and S.Text(frame, "light", "name", S.COLOR.white, "LEFT")
      or frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    help:ClearAllPoints()
    help:SetPoint("TOPLEFT", SET_X, y - SET_HELP_Y)
    -- Stops short of the control column rather than running the full width, so
    -- a long sentence wraps instead of sliding under a checkbox.
    help:SetWidth(SET_CHECK_X - SET_X - 16)
    help:SetJustifyH("LEFT")
    help:SetWordWrap(true)
    -- Capped so a long help line cannot grow the row it was measured for.
    if help.SetMaxLines then help:SetMaxLines(2) end
    help:SetText(spec.help)

    local control
    if spec.kind == "toggle" then
      -- ⚠️ THE DESIGN'S OWN CHECKBOX, not Blizzard's — a 24px square with the
      -- control's gradient rim and the mock's 10x7 tick, which is what
      -- Style.Check already draws for the Loot tab's Vault control. Passing an
      -- EMPTY label because this row has drawn its own above the help text.
      control = S and S.Check(frame, "", SET_CHECK_SZ)
        or CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
      control:SetSize(SET_CHECK_SZ, SET_CHECK_SZ)
      control:SetPoint("TOPLEFT", SET_CHECK_X, y + 4)
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

    elseif spec.kind == "slider" then
      control = ns.Style and ns.Style.Slider(frame, 150, spec.min, spec.max, spec.step)
      if control then
        control:SetPoint("TOPRIGHT", -60, y)
        control:Wire(spec.suffix, function(v)
          -- Only write when it actually moved: OnValueChanged fires while the
          -- window is being POPULATED too, and storing there would rewrite the
          -- setting from the widget on every open.
          if v ~= Settings.Get(spec.key) then Settings.Set(spec.key, v) end
        end)
      end

    elseif spec.kind == "number" then
      control = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
      control:SetSize(SET_INPUT_W, SET_INPUT_H)
      control:SetPoint("TOPLEFT", SET_INPUT_X, y)
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
      control = S and S.Control(frame, "", "head")
        or CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
      control:SetSize(SET_DROP_W, SET_INPUT_H)
      control:SetPoint("TOPLEFT", FRAME_W - SET_X - SET_DROP_W, y)
      if control.SetActive then control:SetActive(true) end
      control:SetScript("OnClick", function(self)
        local cur = Settings.Get(spec.key)
        local idx = 1
        for i, c in ipairs(spec.choices) do if c == cur then idx = i end end
        local nextChoice = spec.choices[(idx % #spec.choices) + 1]
        Settings.Set(spec.key, nextChoice)
        self:SetText(nextChoice)
      end)
    end

    frame.rows[#frame.rows + 1] = { spec = spec, control = control }
    y = y - (Settings.RowHeight(spec) + ROW_GAP)
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
  local note = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("BOTTOM", 0, 19)
  note:SetText("Changes apply as you make them.")

  -- ── Display readout ────────────────────────────────────────────────────────
  --
  -- Says whether this client is drawing the addon on whole pixels. It exists
  -- because "the panel looks blurry" is otherwise unfalsifiable — it reads as a
  -- matter of taste when it is in fact an arithmetic question with one answer.
  -- ns.DisplayReport does the arithmetic (Core.lua, inside the harness's reach);
  -- this only prints it.
  frame.display = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.display:SetPoint("BOTTOMLEFT", 18, FOOTER_H)
  frame.display:SetPoint("BOTTOMRIGHT", -18, FOOTER_H)
  frame.display:SetHeight(READOUT_H - 10)
  frame.display:SetJustifyH("LEFT")
  frame.display:SetJustifyV("TOP")
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
function Settings.DisplayLine(r)
  if not r then return "Display: this client did not report a screen size." end
  local head = ("Display: %d x %d  ·  scale %.4f  ·  1 unit = %.2f px")
    :format(r.screenWidth, r.screenHeight, r.scale, r.pixelsPerUnit)
  if r.aligned then
    return head .. "\nText is landing on whole pixels — this is as sharp as it gets."
  end
  local worstPx = 0
  for _, s in ipairs(r.sizes) do
    if s.drift > worstPx then worstPx = s.drift end
  end
  return head .. ("\nText is landing BETWEEN pixels (worst size is %.2f px off), which is what")
    :format(worstPx)
    .. ("\nreads as blur. A scale of %.4f would put one unit on one pixel.")
    :format(r.perfectScale)
end

function Settings.Refresh()
  if not frame then return end
  if frame.display and ns.DisplayReport then
    frame.display:SetText(Settings.DisplayLine(ns.DisplayReport()))
  end
  for _, row in ipairs(frame.rows) do
    local v = Settings.Get(row.spec.key)
    if row.spec.kind == "toggle" then
      row.control:SetChecked(v and true or false)
    elseif row.spec.kind == "slider" then
      row.control:SetValue(tonumber(v) or row.spec.default)
    elseif row.spec.kind == "number" then
      row.control:SetText(tostring(v))
    elseif row.spec.kind == "choice" then
      row.control:SetText(tostring(v))
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
