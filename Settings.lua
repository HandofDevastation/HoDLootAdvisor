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
function Settings.Set(key, value)
  local spec, canonical = resolveKey(key)
  if not spec then return false, "unknown setting: " .. tostring(key) end
  key = canonical
  ns.db.settings = ns.db.settings or Settings.Defaults()

  if spec.kind == "number" then
    local n = tonumber(value)
    if not n then return false, ("%s needs a number"):format(spec.label) end
    n = math.floor(n)
    if n < spec.min or n > spec.max then
      return false, ("%s must be between %d and %d"):format(spec.label, spec.min, spec.max)
    end
    ns.db.settings[key] = n
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
    return true

  elseif spec.kind == "choice" then
    local want = tostring(value):upper()
    for _, c in ipairs(spec.choices) do
      if c == want then ns.db.settings[key] = c; return true end
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
local FRAME_W  = 460
local HEADER_H = 40
local ROW_H    = 54
local FOOTER_H = 48

local function build()
  local height = HEADER_H + (#Settings.SPEC * ROW_H) + FOOTER_H

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
  frame.TitleText:SetText("Loot Advisor — Settings")

  frame.rows = {}
  local y = -HEADER_H

  for _, spec in ipairs(Settings.SPEC) do
    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", 18, y)
    label:SetText(spec.label)

    local help = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    help:SetPoint("TOPLEFT", 18, y - 16)
    help:SetWidth(FRAME_W - 36)
    help:SetJustifyH("LEFT")
    help:SetWordWrap(true)
    -- Capped so a long help line cannot grow the row it was measured for.
    if help.SetMaxLines then help:SetMaxLines(2) end
    help:SetText(spec.help)

    local control
    if spec.kind == "toggle" then
      control = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
      control:SetPoint("TOPRIGHT", -20, y + 4)
      control:SetScript("OnClick", function(self)
        Settings.Set(spec.key, self:GetChecked() and "on" or "off")
      end)

    elseif spec.kind == "number" then
      control = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
      control:SetSize(46, 20)
      control:SetPoint("TOPRIGHT", -24, y)
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
      control = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
      control:SetSize(120, 22)
      control:SetPoint("TOPRIGHT", -18, y + 2)
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
    y = y - ROW_H
  end

  local reset = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  reset:SetSize(120, 24)
  reset:SetPoint("BOTTOMLEFT", 18, 12)
  reset:SetText("Restore Defaults")
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

  local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  close:SetSize(100, 24)
  close:SetPoint("BOTTOMRIGHT", -18, 12)
  close:SetText("Done")
  close:SetScript("OnClick", function()
    -- Commit anything still being typed before the window goes away.
    for _, row in ipairs(frame.rows) do
      if row.control and row.control.ClearFocus then row.control:ClearFocus() end
    end
    frame:Hide()
  end)
end

function Settings.Refresh()
  if not frame then return end
  for _, row in ipairs(frame.rows) do
    local v = Settings.Get(row.spec.key)
    if row.spec.kind == "toggle" then
      row.control:SetChecked(v and true or false)
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
