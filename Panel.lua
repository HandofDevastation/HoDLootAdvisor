-- Panel.lua — the Loot Advisor panel (Arrangement A)
--
-- Layout is HoD_LootAddon_Experience.md §3 and §6:
--
--   [ Drops | Boss | Me | Standings ]        tabs
--   ( chip )( chip )( chip )                 STRIP — one per item, YOUR badge
--   ────────────────────────────────────
--   1. Name      Major   -4   +42 ilvl  PR   DETAIL — one item, ranked
--   2. Name      Major   -7   +38 ilvl  PR
--   ────────────────────────────────────
--   You: 3rd of 18 · EP 1240 · GP 310        FOOTER — always your own row
--
-- WHY THE STRIP EXISTS: the two rankings are different SHAPES. EPGP priority is
-- one global list of the whole raid, stable through a kill. Upgrade magnitude is
-- a different list per item — five drops means five orderings. The strip answers
-- "is any of this for me" before a row is read.
--
-- WHY PRIORITY IS A COLUMN AND NOT THE SORT: during a roll what matters is the
-- priority of the people contesting THIS item, which is the rightmost column.
-- The full ladder is a tab, not something competing for space mid-decision.
--
-- The strip is the SAME control on both Drops and Boss — a list of items, each
-- carrying the viewer's own badge, one selected. Drops fills it from what has
-- dropped; Boss fills it from everything that boss can drop. That is why the
-- anticipatory view needs no separate interaction to learn.
--
-- Nothing here posts to chat on its own — the Post button is the only path.

local ADDON_NAME, ns = ...

local Panel = {}
ns.Panel = Panel

local GOLD  = { 0.953, 0.773, 0.420 }
local WHITE = { 1, 1, 1 }
local MUTED = { 0.533, 0.533, 0.600 }

local BADGE_COLOR = {
  major     = { 1.000, 0.420, 0.420 },
  moderate  = { 0.784, 0.588, 0.180 },
  minor     = { 0.627, 0.627, 0.690 },
  sidegrade = { 0.533, 0.533, 0.600 },
}
local BADGE_LABEL = {
  major = "Major", moderate = "Moderate", minor = "Minor", sidegrade = "Sidegrade",
}

-- The item-quality tag (text + colour) lives in Core.lua: it is pure logic that
-- the tooltip needs too, and Panel.lua is frame construction the headless test
-- harness deliberately does not load.
local qualityTag = ns.QualityTag


local CLASS_COLOR = {
  ["Death Knight"] = { 0.77, 0.12, 0.23 }, ["Demon Hunter"] = { 0.64, 0.19, 0.79 },
  ["Druid"] = { 1.00, 0.49, 0.04 },        ["Evoker"] = { 0.20, 0.58, 0.50 },
  ["Hunter"] = { 0.67, 0.83, 0.45 },       ["Mage"] = { 0.25, 0.78, 0.92 },
  ["Monk"] = { 0.00, 1.00, 0.60 },         ["Paladin"] = { 0.96, 0.55, 0.73 },
  ["Priest"] = { 1.00, 1.00, 1.00 },       ["Rogue"] = { 1.00, 0.96, 0.41 },
  ["Shaman"] = { 0.00, 0.44, 0.87 },       ["Warlock"] = { 0.53, 0.53, 0.93 },
  ["Warrior"] = { 0.78, 0.61, 0.43 },
}

local TABS = { "Drops", "Boss", "Me", "Standings", "Targets" }

-- The target marker. One glyph, used everywhere an item can appear, so it reads
-- the same on a chip, in a browse row and on the selected-item line.
local TARGET_MARK = "|cffF3C56B*|r"

-- Geometry. VISIBLE_ROWS is DERIVED from the frame height rather than picked:
-- WoW frames do not clip their children, so a row count larger than the space
-- available does not scroll or truncate — it draws straight over the footer and
-- out through the bottom of the window, which is exactly what happened.
local FRAME_W, FRAME_H = 500, 560
-- LIST_TOP must clear the column-header row, which sits at -154 and is 12 tall.
-- At 152 the list started ABOVE its own header and row 1 painted over it.
local LIST_TOP, LIST_BOTTOM = 170, 74
local ROW_H = 20
local VISIBLE_ROWS = math.floor((FRAME_H - LIST_TOP - LIST_BOTTOM) / ROW_H)
local CHIPS_PER_PAGE = 5

-- Five tabs now have to share the row with the difficulty button, which sits at
-- the right edge. DERIVED rather than picked, for the same reason VISIBLE_ROWS
-- is: WoW frames do not clip, so tabs that overrun simply draw through whatever
-- is beside them instead of announcing the problem.
local TAB_GAP = math.floor((FRAME_W - 24 - 100 - 12) / #TABS)
local TAB_W = TAB_GAP - 2

local frame
local state = {
  tab = "Drops", sel = 1, bossIndex = 1, scroll = 0, chipPage = 0,
  -- Targets tab: which instance and encounter are being browsed, and whether we
  -- are browsing the catalogue or looking at what has been flagged.
  instIndex = 1, encIndex = 1, targetMode = "browse",
}

-- ---------------------------------------------------------------------------
-- Builders
-- ---------------------------------------------------------------------------

-- Every fontstring in the panel goes through here, which is what lets the type
-- system be swapped in one edit. The Blizzard template names are kept as the
-- ARGUMENT so the ~40 call sites did not all have to change at once; they map
-- onto the addon's own roles, and a template this does not know falls back to
-- body text at row size rather than erroring.
local TEMPLATE_ROLE = {
  GameFontNormal       = { role = "body",  size = "row",   color = "text" },
  GameFontNormalSmall  = { role = "body",  size = "small", color = "text" },
  GameFontDisableSmall = { role = "body",  size = "small", color = "textDim" },
  GameFontHighlight    = { role = "bodyMed", size = "row", color = "text" },
}

local function fs(parent, template, x, y, width, justify)
  local S = ns.Style
  local t
  if S then
    local m = TEMPLATE_ROLE[template or ""] or { role = "body", size = "row", color = "text" }
    t = S.Text(parent, m.role, m.size, S.COLOR[m.color], justify)
  else
    -- Style.lua missing is a packaging fault, not a reason to draw nothing.
    t = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    t:SetJustifyH(justify or "LEFT")
    t:SetWordWrap(false)
  end
  if x then t:SetPoint("TOPLEFT", x, y) end
  if width then t:SetWidth(width) end
  return t
end

--- Flag or unflag whatever item a control is carrying, and say which happened.
--- Right-click is the gesture everywhere: left-click already selects a strip
--- chip, and nothing else in the addon uses right-click.
local function toggleTarget(itemID, meta)
  if not itemID or not ns.Targets then return end
  local now = ns.Targets.Toggle(itemID, meta)
  local label = (meta and meta.name) or (ns.Targets.DB().items[itemID] or {}).name
    or ("item:" .. tostring(itemID))
  if now then
    ns.Print(("targeting |cffF3C56B%s|r."):format(label))
  else
    ns.Print(("no longer targeting %s."):format(label))
  end
  Panel.Refresh()
end

--- Blank every fontstring on a recycled row, so a view only has to set what it
--- actually wants to show.
local function resetRow(row)
  if not row or not row.TEXT_KEYS then return end
  for _, key in ipairs(row.TEXT_KEYS) do
    local fsObj = row[key]
    if fsObj and fsObj.SetText then fsObj:SetText("") end
  end
end

--- A dropdown: a button that opens a list of choices below it.
---
--- Built once and used for all three pickers, so the Boss tab's fix is not a
--- one-off and the next selector gets it free. Arrows made you step through a
--- list to find out what was on each entry, which is the wrong shape whenever
--- choosing is a COMPARISON rather than a walk — true of bosses, and just as
--- true of instances and encounters on the planning tab.
---
--- ⚠️ NO FULL-SCREEN CLICK-CATCHER, deliberately. The first version had one for
--- click-outside-to-close and it silently ate every selection: only ONE frame
--- receives a click, and a screen-covering button takes it. Two reloads and an
--- empty diagnostic log established that. The menu closes on a pick, on
--- re-clicking its button, and when its tab goes away.
---
--- Hand-rolled rather than UIDropDownMenu: Blizzard's is heavily skinned, awkward
--- to restyle, and cannot colour its rows, which is the whole point here.
local function makeDropdown(parent, width, onSelect)
  local ROW = 20

  local dd = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  dd:SetSize(width, 22)
  dd:SetText("")
  dd.label = fs(dd, "GameFontNormal", 8, -4, width - 40)
  dd.arrow = fs(dd, "GameFontNormalSmall", width - 24, -4, 16, "RIGHT")
  dd.arrow:SetText("v")

  local menu = CreateFrame("Frame", nil, parent)
  -- TOOLTIP so nothing the panel draws can end up over the open list.
  menu:SetFrameStrata("TOOLTIP")
  menu:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -2)
  menu:SetWidth(width)
  -- Swallows clicks that land on the menu but miss an item, rather than letting
  -- them fall through to the list underneath.
  menu:EnableMouse(true)
  menu:Hide()
  if ns.Style then ns.Style.Surface(menu, ns.Style.COLOR.bgAlt, 0.98) end
  menu.items = {}
  dd.menu = menu

  dd:SetScript("OnClick", function()
    if menu:IsShown() then menu:Hide() else dd:Open() end
  end)

  --- entries = { { label = "...", current = bool }, ... }
  function dd:SetEntries(entries, currentIndex, currentLabel)
    dd.entries = entries or {}
    dd.currentIndex = currentIndex
    dd.label:SetText(currentLabel or "")
  end

  function dd:Open()
    local entries = dd.entries or {}
    for _, b in ipairs(menu.items) do b:Hide() end

    for i, e in ipairs(entries) do
      local btn = menu.items[i]
      if not btn then
        btn = CreateFrame("Button", nil, menu)
        btn:EnableMouse(true)
        btn:RegisterForClicks("LeftButtonUp")
        btn:SetSize(width - 2, ROW)
        btn:SetPoint("TOPLEFT", 1, -((i - 1) * ROW) - 1)
        btn.hl = btn:CreateTexture(nil, "BACKGROUND")
        btn.hl:SetAllPoints()
        if ns.Style then btn.hl:SetColorTexture(ns.Style.rgb(ns.Style.COLOR.elevated)) end
        btn.hl:Hide()
        btn.text = fs(btn, "GameFontNormalSmall", 8, -3, width - 18)
        btn:SetScript("OnEnter", function(sf) sf.hl:Show() end)
        btn:SetScript("OnLeave", function(sf) sf.hl:Hide() end)
        menu.items[i] = btn
      end
      btn.text:SetText(e.label or "?")
      -- The current entry is gold, so the open list also says where you are.
      btn.text:SetTextColor(unpack(i == dd.currentIndex and GOLD or WHITE))
      btn:SetScript("OnClick", function()
        menu:Hide()
        if onSelect then onSelect(i) end
      end)
      btn:Show()
    end

    menu:SetHeight(math.max(1, #entries) * ROW + 2)
    menu:Show()
    menu:Raise()
  end

  function dd:Close() menu:Hide() end
  function dd:SetShownAll(shown)
    dd:SetShown(shown)
    if not shown then menu:Hide() end
  end

  return dd
end

local function buildRow(parent, i)
  -- A Button rather than a Frame, so a browse row can be right-clicked. The
  -- ranking rows built from this are RAIDERS, not items, and simply carry no
  -- itemID — which is what makes the gesture a no-op there rather than a
  -- surprise.
  local row = CreateFrame("Button", nil, parent)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetHeight(ROW_H)
  row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
  row:SetPoint("TOPRIGHT", 0, -(i - 1) * ROW_H)

  row.hl = row:CreateTexture(nil, "BACKGROUND")
  row.hl:SetAllPoints()
  if ns.Style then
    row.hl:SetColorTexture(ns.Style.rgb(ns.Style.COLOR.elevated))
  else
    row.hl:SetColorTexture(1, 1, 1, 0.07)
  end
  row.hl:Hide()

  -- EVERY fontstring key on a row is recorded, so resetRow() can blank them all
  -- without a hand-maintained list. Rows are RECYCLED across five different
  -- views, each of which writes only the fields it cares about — so anything a
  -- previous view left behind draws on top of the current one. That is exactly
  -- how the quality tag ended up printed through the middle of the Me tab's
  -- sentences: a field added in one view that four other views did not know to
  -- clear. A list that maintains itself is the only version of this that stays
  -- correct when the next field is added.
  row.TEXT_KEYS = { "rank", "name", "quality", "badge", "gap", "ilvl", "pr", "src" }

  row.rank  = fs(row, "GameFontNormalSmall", 4, -4, 22)
  row.name  = fs(row, "GameFontNormal", 28, -3, 112)
  -- Sits in the space between the name and the badge. Per-RAIDER, not per-item:
  -- a grade belongs to a spec, so two raiders contesting one trinket can hold
  -- different letters, and that is exactly what explains their order.
  row.quality = fs(row, "GameFontNormalSmall", 142, -4, 28, "RIGHT")
  row.badge = fs(row, "GameFontNormalSmall", 172, -4, 70)
  row.gap   = fs(row, "GameFontNormalSmall", 240, -4, 36, "RIGHT")
  row.ilvl  = fs(row, "GameFontNormalSmall", 282, -4, 66, "RIGHT")
  row.pr    = fs(row, "GameFontNormalSmall", 354, -4, 78, "RIGHT")
  -- GEAR PROVENANCE, at the right edge. The columns above end at 432 and the
  -- list is 472 wide, so this fits in space that was already there rather than
  -- squeezing an existing column — which matters because WoW frames do not clip
  -- their children, so an overrun draws straight through its neighbour instead
  -- of announcing itself.
  --
  -- BLANK IS THE COMMON CASE AND THAT IS DELIBERATE. Almost every row is scored
  -- from the site snapshot; tagging all twenty of them turns the signal into
  -- wallpaper. What is worth marking is the rows that are BETTER than the
  -- snapshot, not the ordinary ones.
  row.src   = fs(row, "GameFontNormalSmall", 436, -4, 36, "RIGHT")

  -- The browse list reuses these rows for ITEMS, which need an icon the ranking
  -- rows have no use for. Created once and simply hidden rather than built per
  -- refresh: rows are recycled, and a texture created on every draw leaks.
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(14, 14)
  row.icon:SetPoint("TOPLEFT", 6, -3)
  row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  row.icon:Hide()

  row:SetScript("OnClick", function(self, button)
    if not self.itemID then return end
    if button == "RightButton" then
      toggleTarget(self.itemID, self.meta)
    end
  end)
  row:SetScript("OnEnter", function(self)
    self.hl:Show()
    -- A ranking row is a RAIDER and carries no itemID, so it never had a
    -- tooltip at all. The provenance marker is four characters wide, which is
    -- nowhere near enough to explain itself — the sentence lives here.
    if not self.itemID then
      if self.srcHelp then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(self.srcName or "", 1, 1, 1)
        GameTooltip:AddLine(self.srcHelp, 0.6, 0.6, 0.7, true)
        GameTooltip:Show()
      end
      return
    end
    local link = self.link or ns.ItemLinkFor(self.itemID)
    if not link then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(link)
    GameTooltip:AddLine(ns.Targets and ns.Targets.Has(self.itemID)
      and "Right-click to stop targeting." or "Right-click to target.", 0.6, 0.6, 0.7)
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function(self)
    self.hl:Hide()
    GameTooltip:Hide()
  end)
  return row
end

local function buildChip(parent, i)
  local chip = CreateFrame("Button", nil, parent)
  chip:SetSize(88, 36)
  chip:SetPoint("LEFT", (i - 1) * 91, 0)

  -- The site's item chip: an elevated surface with a hairline rim, the rim
  -- going gold when selected rather than a translucent wash over the fill.
  -- A wash lightens the text with it; a rim does not.
  local S = ns.Style
  chip.bg = chip:CreateTexture(nil, "BACKGROUND")
  chip.bg:SetAllPoints()
  if S then
    chip.bg:SetColorTexture(S.rgb(S.COLOR.elevated))
    chip.rim = S.Rim(chip, S.COLOR.border, 1)
  else
    chip.bg:SetColorTexture(1, 1, 1, 0.05)
  end

  chip.sel = chip:CreateTexture(nil, "BORDER")
  chip.sel:SetAllPoints()
  chip.sel:SetColorTexture(0.95, 0.77, 0.42, 0.10)
  chip.sel:Hide()

  chip.name  = fs(chip, "GameFontNormalSmall", 4, -3, 80)
  -- The badge gives up its right-hand third to the quality tag rather than the
  -- two sharing a span and overlapping on the long labels ("Sidegrade").
  chip.badge   = fs(chip, "GameFontNormalSmall", 4, -19, 52)
  chip.quality = fs(chip, "GameFontNormalSmall", 56, -19, 28, "RIGHT")

  chip:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  chip:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
      toggleTarget(self.itemID, { name = self.itemName })
      return
    end
    if self.entryIndex then
      state.sel = self.entryIndex
      state.scroll = 0
      Panel.Refresh()
    end
  end)
  -- A REAL game tooltip, so item level, stats and effects come from the client
  -- rather than from anything we compute. The dropped item's own link is used
  -- when we have one (it is the authoritative version that actually dropped);
  -- otherwise one is built for the selected difficulty.
  chip:SetScript("OnEnter", function(self)
    local link = self.link or ns.ItemLinkFor(self.itemID)
    if not link then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetHyperlink(link)
    GameTooltip:AddLine(ns.Targets and ns.Targets.Has(self.itemID)
      and "Right-click to stop targeting." or "Right-click to target.", 0.6, 0.6, 0.7)
    GameTooltip:Show()
  end)
  chip:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return chip
end

local function build()
  frame = CreateFrame("Frame", "HoDLootAdvisorPanel", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(FRAME_W, FRAME_H)
  frame:SetPoint("CENTER", 260, 0)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetFrameStrata("DIALOG")
  ns.MakeWindow(frame)
  frame:Hide()
  frame.TitleText:SetText("Loot Advisor")

  frame.tabs = {}
  for i, name in ipairs(TABS) do
    local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetSize(TAB_W, 22)
    b:SetPoint("TOPLEFT", 12 + (i - 1) * TAB_GAP, -28)
    b:SetText(name)
    b:SetScript("OnClick", function()
      state.tab = name
      state.sel, state.scroll, state.chipPage = 1, 0, 0
      Panel.Refresh()
    end)
    frame.tabs[name] = b
  end

  -- Boss selector (Boss tab only).
  frame.bossDrop = makeDropdown(frame, 300, function(i)
    state.bossIndex = i
    state.sel, state.scroll, state.chipPage = 1, 0, 0
    Panel.Refresh()
  end)
  frame.bossDrop:SetPoint("TOPLEFT", 14, -56)

  frame.bossName = fs(frame, "GameFontNormal", 322, -59, 200)
  frame.bossName:SetTextColor(unpack(WHITE))

  -- Instance and encounter pickers (Targets browse): instance on the boss row,
  -- encounter on the row below it, which is free on this tab because the strip
  -- is hidden. Same control as the boss picker — the question there is also
  -- "which of these is worth my time", which a list answers and four arrows do
  -- not: arrows make you visit every entry to find out what is on it.
  frame.instDrop = makeDropdown(frame, 300, function(i)
    state.instIndex = i
    -- A new instance means the old encounter index means nothing.
    state.encIndex, state.scroll = 1, 0
    Panel.Refresh()
  end)
  frame.instDrop:SetPoint("TOPLEFT", 14, -56)

  frame.encDrop = makeDropdown(frame, 300, function(i)
    state.encIndex = i
    state.scroll = 0
    Panel.Refresh()
  end)
  frame.encDrop:SetPoint("TOPLEFT", 14, -80)

  frame.encName = fs(frame, "GameFontNormalSmall", 70, -83, 240)
  frame.encName:SetTextColor(unpack(MUTED))

  -- Browse <-> your flagged list. One tab, two views: the flag and the list want
  -- to be a click apart so you can watch what you just flagged land.
  frame.targetMode = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.targetMode:SetSize(130, 20)
  frame.targetMode:SetPoint("TOPRIGHT", -14, -80)
  frame.targetMode:SetScript("OnClick", function()
    state.targetMode = (state.targetMode == "browse") and "flagged" or "browse"
    state.scroll = 0
    Panel.Refresh()
  end)

  -- Strip
  frame.strip = CreateFrame("Frame", nil, frame)
  frame.strip:SetPoint("TOPLEFT", 14, -80)
  frame.strip:SetPoint("TOPRIGHT", -60, -80)
  frame.strip:SetHeight(36)
  frame.strip:EnableMouseWheel(true)
  frame.strip:SetScript("OnMouseWheel", function(_, delta) Panel.PageChips(-delta) end)

  frame.chips = {}
  for i = 1, CHIPS_PER_PAGE do
    frame.chips[i] = buildChip(frame.strip, i)
    frame.chips[i]:Hide()
  end

  -- Page indicator PLUS arrows. The wheel alone was not an affordance — "1/3"
  -- announced there were more pages while offering no visible way to reach them.
  frame.chipMore = fs(frame, "GameFontDisableSmall", nil, nil, 46, "RIGHT")
  frame.chipMore:SetPoint("TOPRIGHT", -14, -84)

  frame.chipPrev = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.chipPrev:SetSize(22, 18)
  frame.chipPrev:SetPoint("TOPRIGHT", -38, -98)
  frame.chipPrev:SetText("<")
  frame.chipPrev:SetScript("OnClick", function() Panel.PageChips(-1) end)

  frame.chipNext = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.chipNext:SetSize(22, 18)
  frame.chipNext:SetPoint("TOPRIGHT", -14, -98)
  frame.chipNext:SetText(">")
  frame.chipNext:SetScript("OnClick", function() Panel.PageChips(1) end)

  -- Difficulty, on the tab row's right. Cycles AUTO -> Normal -> Heroic ->
  -- Mythic; AUTO follows the raid you are in, which is right in a raid and
  -- useless in a city, hence the override.
  frame.diff = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.diff:SetSize(96, 22)
  frame.diff:SetPoint("TOPRIGHT", -12, -28)
  frame.diff:SetScript("OnClick", function()
    local spec
    for _, s in ipairs(ns.Settings.SPEC) do if s.key == "difficulty" then spec = s end end
    local cur, idx = ns.Settings.Get("difficulty"), 1
    for i, c in ipairs(spec.choices) do if c == cur then idx = i end end
    ns.Settings.Set("difficulty", spec.choices[(idx % #spec.choices) + 1])
    Panel.Refresh()
  end)
  frame.diff:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Difficulty", 1, 1, 1)
    GameTooltip:AddLine("Which difficulty's item levels everything is scored against.", 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("AUTO follows the raid you are currently in.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  frame.diff:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.context = fs(frame, "GameFontNormal", 16, -122, 400)
  frame.context:SetTextColor(unpack(GOLD))

  -- The selected item's name is also a tooltip target — it is the biggest
  -- representation of the item on screen, so hovering it should do what
  -- hovering an item anywhere else in the game does.
  frame.contextHover = CreateFrame("Frame", nil, frame)
  frame.contextHover:SetPoint("TOPLEFT", 16, -120)
  frame.contextHover:SetSize(400, 18)
  frame.contextHover:EnableMouse(true)
  frame.contextHover:SetScript("OnEnter", function(self)
    local link = self.link or ns.ItemLinkFor(Panel.CurrentItemID())
    if not link then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:SetHyperlink(link)
    GameTooltip:Show()
  end)
  frame.contextHover:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.sub = fs(frame, "GameFontNormalSmall", 16, -138, 400)
  frame.sub:SetTextColor(unpack(MUTED))

  frame.head = CreateFrame("Frame", nil, frame)
  frame.head:SetPoint("TOPLEFT", 14, -154)
  frame.head:SetPoint("TOPRIGHT", -14, -154)
  frame.head:SetHeight(12)
  frame.headText = {
    fs(frame.head, "GameFontDisableSmall", 28, 0, 140),
    fs(frame.head, "GameFontDisableSmall", 172, 0, 70),
    fs(frame.head, "GameFontDisableSmall", 282, 0, 66, "RIGHT"),
    fs(frame.head, "GameFontDisableSmall", 354, 0, 78, "RIGHT"),
  }

  frame.list = CreateFrame("Frame", nil, frame)
  frame.list:SetPoint("TOPLEFT", 14, -LIST_TOP)
  frame.list:SetPoint("BOTTOMRIGHT", -14, LIST_BOTTOM)
  frame.list:EnableMouseWheel(true)
  frame.list:SetScript("OnMouseWheel", function(_, delta) Panel.Scroll(-delta) end)

  frame.rows = {}
  for i = 1, VISIBLE_ROWS do
    frame.rows[i] = buildRow(frame.list, i)
    frame.rows[i]:Hide()
  end

  frame.more = fs(frame, "GameFontDisableSmall", 16, 0, 300)
  frame.more:ClearAllPoints()
  frame.more:SetPoint("BOTTOMLEFT", 16, 58)

  frame.footer = fs(frame, "GameFontNormalSmall", 16, 0, 320)
  frame.footer:ClearAllPoints()
  frame.footer:SetPoint("BOTTOMLEFT", 16, 40)
  frame.footer:SetTextColor(unpack(GOLD))

  frame.post = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.post:SetSize(90, 22)
  frame.post:SetPoint("BOTTOMRIGHT", -14, 38)
  frame.post:SetText("Post")
  frame.post:SetScript("OnClick", function()
    local id = Panel.CurrentItemID()
    if id then ns.Loot.PostToChat(id) end
  end)
  frame.post:SetScript("OnEnter", function(self)
    local id = Panel.CurrentItemID()
    if not id then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Post to chat", 1, 1, 1)
    for _, line in ipairs(ns.Loot.ChatLines(id)) do
      GameTooltip:AddLine(line, 0.8, 0.8, 0.8, true)
    end
    GameTooltip:Show()
  end)
  frame.post:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- "Load Raid Data" is what the design doc calls this and what the runner is
  -- actually doing. "Load Data" read as generic enough that it was not
  -- recognisable as the paste step at all.
  frame.load = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.load:SetSize(130, 22)
  frame.load:SetPoint("BOTTOMLEFT", 14, 12)
  frame.load:SetText("Import Raid Night")
  frame.load:SetScript("OnClick", function() ns.LoadWindow.Toggle() end)
  frame.load:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Import Raid Night", 1, 1, 1)
    GameTooltip:AddLine("Paste the export from the Loot Advisor page on the website.", 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("This is what supplies everyone's gear — the rankings need it.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  frame.load:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local cfg = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  cfg:SetSize(90, 22)
  cfg:SetPoint("BOTTOMRIGHT", -14, 12)
  cfg:SetText("Settings")
  cfg:SetScript("OnClick", function() ns.Settings.Toggle() end)

  -- The recorder runs whether or not anyone opens this, but a log nobody can
  -- find is one nobody reviews — and reviewing it is the point (Session 243).
  local log = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  log:SetSize(90, 22)
  log:SetPoint("RIGHT", cfg, "LEFT", -8, 0)
  log:SetText("Loot Log")
  log:SetScript("OnClick", function()
    if ns.RecordWindow then ns.RecordWindow.Toggle() end
  end)
  log:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Loot Log", 1, 1, 1)
    GameTooltip:AddLine("Every drop and every roll, recorded automatically. Review a night, tag a run Guild or Personal, and export for the website.", 0.8, 0.8, 0.8, true)
    local _, items = ns.Record.Counts()
    GameTooltip:AddLine(("%d item%s recorded."):format(items, items == 1 and "" or "s"), 0.6, 0.6, 0.7)
    GameTooltip:Show()
  end)
  log:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- ---------------------------------------------------------------------------
-- Data
-- ---------------------------------------------------------------------------

-- bossBisCount lives in Core.lua as ns.BisCountForBoss: it is pure payload
-- logic, and Panel.lua is frame construction the headless harness does not load.
-- Writing it here made it untestable, which is the SECOND time that happened
-- today — the quality tag had to be moved for the same reason.
local function bossList()
  local data = ns.Data()
  local counts = ns.BisCountsByBoss()
  local out = {}
  for id, b in pairs((data or {}).bosses or {}) do
    out[#out + 1] = { id = id, name = b.name, order = b.order or 99, bis = counts[id] or 0 }
  end
  table.sort(out, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return (a.name or "") < (b.name or "")
  end)
  return out
end

--- A picker label: the thing's name, plus how many of its drops are BIS for you.
--- Silent at zero rather than showing "0 BIS" down most of the list — the count
--- is there to draw the eye, and a column of zeroes does the opposite. Zero is
--- the NORMAL answer on the browse pickers, whose catalogue spans dungeons and
--- world bosses our payload does not cover at all.
---
--- One formatter for all three pickers so they cannot drift apart in wording or
--- colour, and so the count always means the same thing wherever it appears.
local function pickerLabel(name, bis)
  if (bis or 0) > 0 then
    return ("%s   |cffff0080%d BIS|r"):format(name or "?", bis)
  end
  return name or "?"
end

local function bossLabel(b)
  if not b then return "" end
  return pickerLabel(b.name, b.bis)
end

--- The strip's contents for the current tab: a list of items, each with the
--- VIEWER'S OWN badge. Same shape for Drops and Boss, which is what lets one
--- control serve both.
local function stripEntries()
  if state.tab == "Drops" then
    local drops, out = ns.Loot.recent or {}, {}
    for i = #drops, 1, -1 do          -- newest first
      local d = drops[i]
      out[#out + 1] = {
        itemID = d.itemID, name = d.name, link = d.link,
        badge = d.badge, reason = d.reason,
      }
    end
    return out
  end

  local bosses = bossList()
  local boss = bosses[state.bossIndex]
  if not boss then return {} end

  local data = ns.Data()
  local out, seen = {}, {}

  -- THE GAME'S LIST FIRST, not ours (Data Contract §0: the drop list is driven
  -- by what the game reports, never by what our data contains). This tab used to
  -- list only items we had imported, so an item we never imported was INVISIBLE
  -- on the one screen whose entire job is "everything this boss can drop" —
  -- quietly the same failure §0 exists to prevent, one surface removed.
  --
  -- NOT class/spec filtered, deliberately: this tab ranks the whole ROSTER per
  -- item, so filtering to the viewer would hide items that are somebody else's
  -- upgrade. The Targets tab filters, because that one is personal.
  --
  -- data.bosses is keyed by BLIZZARD encounter id and so are journal
  -- encounters — the same id space, which is what makes this a drop-in.
  if ns.Journal then
    for _, e in ipairs(ns.Journal.CachedLoot(boss.id)) do
      if not seen[e.itemID] then
        seen[e.itemID] = true
        out[#out + 1] = { itemID = e.itemID, name = e.name, journal = true }
      end
    end
  end

  -- Anything we hold that the journal did not report is still shown. The two
  -- lists should agree; where they do not, showing the union is the degrade-
  -- loudly answer and a missing item is the failure that actually costs someone
  -- an upgrade.
  for id, it in pairs((data or {}).items or {}) do
    if it.boss == boss.id and not seen[id] then
      seen[id] = true
      out[#out + 1] = { itemID = id, name = it.name }
    end
  end

  -- A journal entry read from a cold cache has no name yet. Fall back to ours,
  -- then to the id — never to a blank row, which reads as a bug.
  for _, e in ipairs(out) do
    if not e.name then
      local rec = (data or {}).items and data.items[e.itemID]
      e.name = (rec and rec.name) or ("item:" .. tostring(e.itemID))
    end
  end

  table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)

  -- The viewer's own badge per item — the whole point of the strip. Scoring 13
  -- items is a handful of table lookups, so this is cheap enough to do on every
  -- refresh rather than cache and risk staleness.
  for _, e in ipairs(out) do
    local scored = ns.Loot.ScoreItem(e.itemID)
    e.quality = scored.quality
    if scored.reason then e.reason = scored.reason
    else e.badge = scored.result and scored.result.badge end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Targets browsing
-- ---------------------------------------------------------------------------
--
-- This is the ONE surface that reaches past tonight's raid: raids, dungeons and
-- world bosses, the whole tier, filtered to what this character can actually
-- use. That reach is what makes targets worth having outside a raid night — the
-- Boss tab answers "who should we prioritise on this boss", and this one answers
-- "what am I going after", which is a different question with a different scope.

local function instanceList()
  if not ns.Journal then return {} end
  return ns.Journal.CachedInstances()
end

local function currentInstance()
  local list = instanceList()
  if #list == 0 then return nil end
  if state.instIndex > #list then state.instIndex = 1 end
  return list[state.instIndex]
end

local function encounterList()
  local inst = currentInstance()
  if not inst then return {} end
  return ns.Journal.CachedEncounters(inst.id)
end

local function currentEncounter()
  local list = encounterList()
  if #list == 0 then return nil end
  if state.encIndex > #list then state.encIndex = 1 end
  return list[state.encIndex]
end

--- The rows for the Targets tab, in whichever mode it is in.
---
--- BROWSE goes through Blizzard's OWN class/spec filter rather than our emitted
--- eligibility answers. That is not a shortcut — it is the only thing that
--- answers for DUNGEON and WORLD BOSS loot at all, since our payload covers raid
--- items only. It is also why this needed no site work.
local function targetRows()
  if state.targetMode == "flagged" then
    local out = {}
    for _, t in ipairs(ns.Targets and ns.Targets.List() or {}) do
      out[#out + 1] = {
        itemID = t.itemID, name = t.name or ("item:" .. t.itemID),
        icon = t.icon, slot = t.slot, source = t.source,
      }
    end
    return out
  end

  local enc = currentEncounter()
  if not enc then return {} end

  local char = ns.ResolveCharacter()
  local classID = select(3, UnitClass("player"))

  -- A LIST FILTERED WITHOUT A SPEC IS A DIFFERENT LIST. If the character's spec
  -- has not resolved yet, filtering by class alone returns more items than the
  -- viewer can use — and because the spec is part of the cache key, the list
  -- would then CHANGE LENGTH once it resolved, which is one of the two things
  -- reported. Waiting is honest; showing the wrong list and correcting it later
  -- is not. This is a guard against the SYMPTOM, and it holds whether or not the
  -- item-cache explanation turns out to be the cause.
  if not (classID and char.specId) then
    ns.Journal.ScheduleWarm()
    return {}, true
  end

  local list, warming = ns.Journal.CachedLoot(enc.id, {
    classID = classID, specID = char.specId,
  })

  -- A WARMING READ IS NOT SHOWN. It is wrong in two ways at once — unnamed AND
  -- unfiltered, because Blizzard's filter cannot judge an item the client has
  -- not loaded — so painting it puts a list of raw item ids on screen that then
  -- silently changes length underneath the user. Journal re-reads and refreshes
  -- on its own when the client answers, so this resolves within a moment.
  if warming then return {}, true end

  local inst = currentInstance()
  local out = {}
  for _, e in ipairs(list) do
    out[#out + 1] = {
      itemID = e.itemID,
      name   = e.name or ("item:" .. tostring(e.itemID)),
      icon   = e.icon,
      link   = e.link,
      slot   = e.slot,
      veryRare = e.veryRare,
      unusable = e.unusable,
      source = ("%s · %s"):format(inst and inst.name or "?", enc.name or "?"),
    }
  end
  return out
end

local function myEntry()
  if not ns.Payload.Current() then return nil end
  local me = UnitName("player")
  if not me then return nil end
  return ns.Payload.byName and ns.Payload.byName[me:lower()] or nil
end

function Panel.CurrentItemID()
  if state.tab ~= "Drops" and state.tab ~= "Boss" then return nil end
  local entries = stripEntries()
  local e = entries[state.sel]
  return e and e.itemID or nil
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function hideRows(from)
  for i = from, VISIBLE_ROWS do frame.rows[i]:Hide() end
end

local function setHeaders(a, b, c, d)
  frame.headText[1]:SetText(a or "")
  frame.headText[2]:SetText(b or "")
  frame.headText[3]:SetText(c or "")
  frame.headText[4]:SetText(d or "")
end

local function renderStrip(entries)
  local total = #entries
  local pages = math.max(1, math.ceil(total / CHIPS_PER_PAGE))
  if state.chipPage >= pages then state.chipPage = pages - 1 end
  if state.chipPage < 0 then state.chipPage = 0 end

  local base = state.chipPage * CHIPS_PER_PAGE
  for i = 1, CHIPS_PER_PAGE do
    local chip = frame.chips[i]
    local e = entries[base + i]
    if not e then
      chip:Hide()
    else
      chip.entryIndex = base + i
      chip.link = e.link
      chip.itemID = e.itemID
      chip.itemName = e.name
      local marked = ns.Targets and ns.Targets.Has(e.itemID)
      chip.name:SetText((marked and (TARGET_MARK .. " ") or "") .. (e.name or "?"))
      chip.name:SetTextColor(unpack(WHITE))
      if e.reason then
        chip.badge:SetText("not for you")
        chip.badge:SetTextColor(unpack(MUTED))
      else
        chip.badge:SetText(BADGE_LABEL[e.badge or "sidegrade"] or "")
        local bc = BADGE_COLOR[e.badge or "sidegrade"] or MUTED
        chip.badge:SetTextColor(bc[1], bc[2], bc[3])
      end
      -- Shown even when the item is "not for you": that verdict is about armour
      -- type, and a grade is still the truth about the item.
      local qText, qColor = qualityTag(e.quality)
      chip.quality:SetText(qText or "")
      if qColor then chip.quality:SetTextColor(qColor[1], qColor[2], qColor[3]) end
      local isSel = (base + i == state.sel)
      chip.sel:SetShown(isSel)
      -- The rim carries the selection; the fill stays put so the text on it does
      -- not shift brightness between states.
      if chip.rim and ns.Style then
        chip.rim:SetColor(isSel and ns.Style.COLOR.gold or ns.Style.COLOR.border, isSel and 1 or 1)
      end
      chip:Show()
    end
  end

  local paged = total > CHIPS_PER_PAGE
  frame.chipMore:SetText(paged and ("%d/%d"):format(state.chipPage + 1, pages) or "")
  frame.chipPrev:SetShown(paged)
  frame.chipNext:SetShown(paged)
  if paged then
    frame.chipPrev:SetEnabled(state.chipPage > 0)
    frame.chipNext:SetEnabled(state.chipPage < pages - 1)
  end
end

local function renderRanking(itemID)
  local ranked, all, meta = ns.Loot.RankRaiders(itemID)
  setHeaders("Raider", "Upgrade", "Gain", "Priority")

  if not ranked then
    frame.sub:SetText("Nothing imported yet — press Import Raid Night and paste tonight's export.")
    frame.more:SetText("")
    hideRows(1)
    return
  end

  -- The reporting gap is named on the line that already describes the list.
  -- A raider who is not reporting is still ranked, from the snapshot, and is
  -- never silently dropped — but the runner is the person who needs to know how
  -- much of this list is live and how much is a snapshot.
  local sub = ("%d of %d raiders can use it"):format(#ranked, #all)
  local gear = ns.GearReportingSummary()
  if gear and gear.reporting > 0 then
    sub = sub .. ("  ·  %d of %d reporting live gear"):format(gear.reporting, gear.total)
  end
  frame.sub:SetText(sub)

  local total = #ranked
  local maxScroll = math.max(0, total - VISIBLE_ROWS)
  if state.scroll > maxScroll then state.scroll = maxScroll end

  if total == 0 then
    frame.more:SetText("")
    hideRows(1)
    return
  end

  local me = (UnitName("player") or ""):lower()
  local shown = math.min(total - state.scroll, VISIBLE_ROWS)

  for i = 1, shown do
    local row = frame.rows[i]
    local r = ranked[i + state.scroll]
    resetRow(row)

    row.rank:SetText(tostring(i + state.scroll))
    row.rank:SetTextColor(unpack(MUTED))

    row.name:SetText(r.name or "?")
    local cc = CLASS_COLOR[r.class or ""] or WHITE
    row.name:SetTextColor(cc[1], cc[2], cc[3])

    row.badge:SetText(BADGE_LABEL[r.result.badge] or "")
    local bc = BADGE_COLOR[r.result.badge] or MUTED
    row.badge:SetTextColor(bc[1], bc[2], bc[3])

    -- Per-raider, because a grade belongs to a SPEC: two people contesting one
    -- trinket can hold different letters, and that is what explains their order.
    local qText, qColor = qualityTag(r.quality)
    row.quality:SetText(qText or "")
    if qColor then row.quality:SetTextColor(qColor[1], qColor[2], qColor[3]) end

    -- Gap is ABSENT, not zero, when the sort cannot guarantee score order.
    if r.gap == nil or (i + state.scroll) == 1 then
      row.gap:SetText("")
    elseif r.gap == 0 then
      row.gap:SetText("tie")
    else
      row.gap:SetText(tostring(r.gap))
    end
    row.gap:SetTextColor(unpack(MUTED))

    local gain = (meta.ilvl or 0) - (r.equipped and r.equipped.ilvl or 0)
    row.ilvl:SetText(gain > 0 and ("+%d ilvl"):format(gain) or "")
    row.ilvl:SetTextColor(unpack(MUTED))

    if r.pr then
      row.pr:SetText(("PR %.2f"):format(r.pr))
      row.pr:SetTextColor(unpack(WHITE))
    else
      row.pr:SetText("—")
      row.pr:SetTextColor(unpack(MUTED))
    end

    -- Which TIER this raider's gear came from. Three-tier provenance is only
    -- worth having if it is visible: "ranked from what they are wearing right
    -- now" and "ranked from a snapshot that may be hours old" are different
    -- claims about the same row.
    local srcText, srcColor, srcHelp = ns.ProvenanceTag(r.equipped)
    row.src:SetText(srcText or "")
    if srcColor then
      row.src:SetTextColor(srcColor[1], srcColor[2], srcColor[3])
    end
    row.srcHelp = srcHelp
    row.srcName = r.name

    -- ⚠️ AN AD-HOC RAIDER IS MARKED. They are somebody the raid-night export
    -- has never heard of — an alt, a trial, a pug — resolved entirely from what
    -- we could read off them in game. Everything about their row is a degree
    -- less certain than the rest of the list, and, more practically, "who is
    -- that" is the question a runner has when an unfamiliar name appears in a
    -- ranking. The asterisk answers it before they have to ask.
    if r.adhoc then
      row.name:SetText((r.name or "?") .. "|cff888899*|r")
      row.srcHelp = (srcHelp and (srcHelp .. "\n\n") or "")
        .. "Not on tonight's raid-night export — read from them in game. "
        .. "No EPGP standing exists for them."
    end

    row.hl:SetShown((r.name or ""):lower() == me)
    row:Show()
  end
  hideRows(shown + 1)

  -- Rows that do not fit are COUNTED, never silently cut off.
  if total > VISIBLE_ROWS then
    frame.more:SetText(("showing %d–%d of %d · scroll for more")
      :format(state.scroll + 1, state.scroll + shown, total))
  else
    frame.more:SetText("")
  end
end

local function renderItemList()
  local entries = stripEntries()
  frame.strip:Show()
  renderStrip(entries)

  if #entries == 0 then
    frame.context:SetText(state.tab == "Drops" and "Waiting for loot" or "No items for this boss")
    frame.sub:SetText(state.tab == "Drops"
      and "Rolls appear here as they happen. /la test <itemID> fakes one."
      or "")
    setHeaders()
    frame.more:SetText("")
    hideRows(1)
    return
  end

  if state.sel > #entries then state.sel = 1 end
  local sel = entries[state.sel]

  frame.context:SetText(("%s   |cff888888(%d of %d)|r")
    :format(sel.name or "?", state.sel, #entries))
  frame.contextHover.link = sel.link
  frame.contextHover:Show()
  renderRanking(sel.itemID)
end

local function renderTargets()
  frame.strip:Hide()
  for i = 1, CHIPS_PER_PAGE do frame.chips[i]:Hide() end
  frame.chipMore:SetText("")
  frame.chipPrev:Hide()
  frame.chipNext:Hide()

  local browsing = state.targetMode == "browse"
  local count = ns.Targets and ns.Targets.Count() or 0

  if browsing then
    local inst, enc = currentInstance(), currentEncounter()
    frame.context:SetText(inst and inst.name or "No catalogue")
    frame.sub:SetText(enc and enc.name
      or "The Adventure Guide had nothing to enumerate here.")
  else
    frame.context:SetText("Your Targets")
    frame.sub:SetText(("%d flagged on %s — right-click to remove"):format(
      count, UnitName("player") or "this character"))
  end

  -- Item names are long, so the name column takes the badge column's space and
  -- the remaining facts move right. Set per render because the ranking rows want
  -- the narrow name back.
  setHeaders("Item", "", "Slot", "Source")

  local rows, warming = targetRows()
  if #rows == 0 then
    frame.more:SetText("")
    hideRows(1)
    if warming then
      frame.sub:SetText("Loading item data from the client…")
    elseif not browsing then
      frame.sub:SetText("Nothing flagged yet. Browse the catalogue and right-click an item.")
    end
    return
  end

  local total = #rows
  if state.scroll > math.max(0, total - VISIBLE_ROWS) then
    state.scroll = math.max(0, total - VISIBLE_ROWS)
  end

  for i = 1, VISIBLE_ROWS do
    local row = frame.rows[i]
    local r = rows[i + state.scroll]
    if not r then
      row:Hide()
    else
      resetRow(row)
      row.itemID, row.link = r.itemID, r.link
      row.meta = { name = r.name, icon = r.icon, slot = r.slot, source = r.source }

      row.icon:SetTexture(r.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
      row.icon:Show()

      row.rank:SetText("")
      -- The marker sits with the NAME rather than in its own column so it reads
      -- identically here and on a chip, where there is no room for a column.
      local marked = ns.Targets and ns.Targets.Has(r.itemID)
      row.name:SetWidth(200)
      row.name:SetText((marked and (TARGET_MARK .. " ") or "") .. (r.name or "?"))
      row.name:SetTextColor(unpack(marked and GOLD or WHITE))

      row.badge:SetText("")

      -- Blizzard's own "very rare" flag — the same signal that decides whether a
      -- piece can reach Myth 9 in the vault. Worth surfacing on a planning
      -- screen: it is exactly the item you would target.
      row.gap:SetText(r.veryRare and "|cffa335eerare|r" or "")
      row.ilvl:SetText(r.slot or "")
      row.ilvl:SetTextColor(unpack(MUTED))
      row.pr:SetText(r.source or "")
      row.pr:SetTextColor(unpack(MUTED))
      row:Show()
    end
  end

  if total > VISIBLE_ROWS then
    frame.more:SetText(("showing %d-%d of %d — scroll for the rest"):format(
      state.scroll + 1, math.min(total, state.scroll + VISIBLE_ROWS), total))
  else
    frame.more:SetText("")
  end
end

local function renderMe()
  frame.strip:Hide()
  for i = 1, CHIPS_PER_PAGE do frame.chips[i]:Hide() end
  frame.chipMore:SetText("")
  setHeaders()
  frame.more:SetText("")

  local char = ns.ResolveCharacter()
  frame.context:SetText(UnitName("player") or "You")
  frame.sub:SetText(("%s %s%s"):format(
    tostring(char.className), tostring(char.specName),
    char.heroTree and (" · " .. char.heroTree) or ""))

  local me, raid = myEntry(), ns.Payload.Current()
  local lines = {}

  if not raid then
    lines[#lines + 1] = "Nothing imported yet — press Import Raid Night."
  elseif not me then
    lines[#lines + 1] = "You are not on the exported roster."
    lines[#lines + 1] = "Rankings still work; your own row just will not appear."
  else
    if me.pr then
      lines[#lines + 1] = ("Priority:  %s of %d")
        :format(me.rank and ("#" .. me.rank) or "unranked", raid.ladder and #raid.ladder or 0)
      lines[#lines + 1] = ("EP %s · GP %s · PR %.2f")
        :format(tostring(me.ep), tostring(me.gp), me.pr)
    else
      lines[#lines + 1] = "No EPGP standing yet this season."
      lines[#lines + 1] = "Rankings order by upgrade size until the ledger fills."
    end

    -- Nights present, NOT the site's weighted attendance percentage. Different
    -- question, deliberately a different number.
    if me.nightsOf and me.nightsOf > 0 then
      lines[#lines + 1] = ("Attendance:  %d of %d raid nights"):format(me.nights or 0, me.nightsOf)
    elseif me.nightsOf == 0 then
      lines[#lines + 1] = "Attendance:  no raid nights recorded this season yet"
    end

    if me.lastItem then
      local when = (me.lastItemDays or 0) == 0 and "today"
        or (me.lastItemDays == 1 and "yesterday")
        or (me.lastItemDays < 14 and ("%d days ago"):format(me.lastItemDays))
        or (me.lastItemDays < 60 and ("%d weeks ago"):format(math.floor(me.lastItemDays / 7)))
        or ("%d months ago"):format(math.floor(me.lastItemDays / 30))
      lines[#lines + 1] = ("Last item:   %s, %s"):format(me.lastItem, when)
    else
      lines[#lines + 1] = "Last item:   nothing on record"
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = ("Gear snapshot: %s"):format(ns.Payload.GearAgeText())
  end

  for i = 1, VISIBLE_ROWS do
    local row, text = frame.rows[i], lines[i]
    if not text then row:Hide() else
      resetRow(row)
      row.name:SetWidth(400)
      row.name:SetText(text)
      row.name:SetTextColor(unpack(WHITE))
      row.hl:Hide()
      row:Show()
    end
  end
end

local function renderStandings()
  frame.strip:Hide()
  for i = 1, CHIPS_PER_PAGE do frame.chips[i]:Hide() end
  frame.chipMore:SetText("")
  setHeaders("Raider", "", "EP / GP", "Priority")

  local raid = ns.Payload.Current()
  frame.context:SetText("Standings")

  local ladder = raid and raid.ladder or nil
  if not ladder or #ladder == 0 then
    frame.sub:SetText(raid and "No EPGP standings for this season yet."
                           or "Nothing imported yet — press Import Raid Night.")
    frame.more:SetText("")
    hideRows(1)
    return
  end

  local total = #ladder
  local maxScroll = math.max(0, total - VISIBLE_ROWS)
  if state.scroll > maxScroll then state.scroll = maxScroll end

  frame.sub:SetText(("%d ranked"):format(total))
  local me = (UnitName("player") or ""):lower()
  local shown = math.min(total - state.scroll, VISIBLE_ROWS)

  for i = 1, shown do
    local row, s = frame.rows[i], ladder[i + state.scroll]
    resetRow(row)
    row.rank:SetText(tostring(s.rank or (i + state.scroll)))
    row.rank:SetTextColor(unpack(MUTED))
    row.name:SetText(s.n or "?"); row.name:SetTextColor(unpack(WHITE))
    row.ilvl:SetText(("%s / %s"):format(tostring(s.ep), tostring(s.gp)))
    row.ilvl:SetTextColor(unpack(MUTED))
    row.pr:SetText(("%.2f"):format(s.pr or 0)); row.pr:SetTextColor(unpack(WHITE))
    row.hl:SetShown((s.n or ""):lower() == me)
    row:Show()
  end
  hideRows(shown + 1)

  if total > VISIBLE_ROWS then
    frame.more:SetText(("showing %d–%d of %d · scroll for more")
      :format(state.scroll + 1, state.scroll + shown, total))
  else
    frame.more:SetText("")
  end
end

-- ---------------------------------------------------------------------------
-- Interaction
-- ---------------------------------------------------------------------------

function Panel.Scroll(delta)
  state.scroll = math.max(0, state.scroll + delta)
  Panel.Refresh()
end

function Panel.PageChips(delta)
  state.chipPage = math.max(0, state.chipPage + delta)
  Panel.Refresh()
end

-- Panel.CycleBoss / CycleInstance / CycleEncounter and Panel.OpenBossMenu are
-- gone. The arrow pairs that called the cyclers were replaced by the dropdowns,
-- which left three public functions with no caller anywhere in the addon — an
-- invitation to bind a key to a control that no longer exists. The shared
-- makeDropdown owns opening and filling all three pickers now, so there is one
-- implementation to be right rather than three to keep in step.

function Panel.Refresh()
  if not frame or not frame:IsShown() then return end

  for name, b in pairs(frame.tabs) do b:SetEnabled(name ~= state.tab) end

  -- Rows are RECYCLED across tabs, so anything one tab sets has to be cleared
  -- here or it bleeds into the next. An item icon left behind on a raider row is
  -- the visible half; a stale itemID is the dangerous half, because it would
  -- make right-click flag whatever the row used to be.
  for i = 1, VISIBLE_ROWS do
    local row = frame.rows[i]
    row.name:SetWidth(140)
    row.icon:Hide()
    row.itemID, row.link, row.meta = nil, nil, nil
  end

  local diff = ns.Settings.Get("difficulty")
  local key = ns.DifficultyKey()
  frame.diff:SetText(diff == "AUTO"
    and ("Auto: %s"):format(({ n = "Normal", h = "Heroic", m = "Mythic" })[key] or "?")
    or diff:sub(1, 1) .. diff:sub(2):lower())

  -- Item hover only means something where an item is selected.
  frame.contextHover:SetShown(state.tab == "Drops" or state.tab == "Boss")

  local onBoss = state.tab == "Boss"
  local onTargets = state.tab == "Targets"
  local browsing = onTargets and state.targetMode == "browse"

  frame.bossDrop:SetShownAll(onBoss)
  frame.bossName:SetShown(onBoss)
  if onBoss then
    local bosses = bossList()
    if state.bossIndex > #bosses then state.bossIndex = 1 end
    local boss = bosses[state.bossIndex]
    local entries = {}
    for _, b in ipairs(bosses) do entries[#entries + 1] = { label = bossLabel(b) } end
    frame.bossDrop:SetEntries(entries, state.bossIndex,
      boss and bossLabel(boss) or "No boss data")
    -- The name beside the control is now the raid, not a repeat of the boss:
    -- the dropdown already says which boss, and this is the context it sits in.
    local total = 0
    for _, b in ipairs(bosses) do total = total + (b.bis or 0) end
    frame.bossName:SetText(total > 0
      and ("|cffff0080%d BIS|r across %d bosses"):format(total, #bosses)
      or ("%d bosses"):format(#bosses))
  end

  -- The instance/encounter selectors belong to BROWSING, not to the tab: on the
  -- flagged view they would offer navigation that changes nothing on screen.
  frame.instDrop:SetShownAll(browsing)
  frame.encDrop:SetShownAll(browsing)
  frame.encName:SetShown(browsing)
  frame.targetMode:SetShown(onTargets)
  if onTargets then
    local count = ns.Targets and ns.Targets.Count() or 0
    frame.targetMode:SetText(browsing
      and ("My Targets (%d)"):format(count)
      or "Browse Catalogue")
    if browsing then
      -- Both pickers carry a BIS count for the same reason the boss one does:
      -- on a planning tab, "which of these is worth my time" is the whole
      -- question, and a bare list of names cannot answer it.
      --
      -- Each map is built ONCE here and read per entry. Asking per entry instead
      -- would re-walk the payload for every line in both lists.
      local instCounts = ns.BisCountsByInstance()
      local bossCounts = ns.BisCountsByBoss()

      local insts = instanceList()
      if state.instIndex > #insts then state.instIndex = 1 end
      local instEntries = {}
      for _, i in ipairs(insts) do
        instEntries[#instEntries + 1] = { label = pickerLabel(i.name, instCounts[i.id]) }
      end
      local inst = insts[state.instIndex]
      frame.instDrop:SetEntries(instEntries, state.instIndex,
        inst and pickerLabel(inst.name, instCounts[inst.id]) or "no instances")

      local encs = encounterList()
      if state.encIndex > #encs then state.encIndex = 1 end
      local encEntries = {}
      for _, e in ipairs(encs) do
        encEntries[#encEntries + 1] = { label = pickerLabel(e.name, bossCounts[e.id]) }
      end
      local enc = encs[state.encIndex]
      frame.encDrop:SetEntries(encEntries, state.encIndex,
        enc and pickerLabel(enc.name, bossCounts[enc.id]) or "no encounters")
      frame.encName:SetText("")
    end
  end

  if onTargets then renderTargets()
  elseif state.tab == "Drops" or onBoss then renderItemList()
  elseif state.tab == "Me" then renderMe()
  else renderStandings() end

  frame.post:SetShown(Panel.CurrentItemID() ~= nil)

  local me = myEntry()
  if me and me.pr then
    frame.footer:SetText(("You: #%s · EP %s · GP %s · PR %.2f")
      :format(tostring(me.rank or "?"), tostring(me.ep), tostring(me.gp), me.pr))
  elseif me then
    frame.footer:SetText("You: no EPGP standing yet this season")
  else
    frame.footer:SetText("")
  end
end

function Panel.Show()
  if not frame then build() end
  -- The panel is the one window with no dock to fall back on — its build-time
  -- CENTER+260 IS the default — so it restores here rather than in
  -- DockBesidePanel.
  ns.RestoreWindowPosition(frame)
  frame:Raise()
  frame:Show()
  Panel.Refresh()
end

function Panel.Toggle()
  if not frame then build() end
  if frame:IsShown() then frame:Hide(); return end
  Panel.Show()
end
