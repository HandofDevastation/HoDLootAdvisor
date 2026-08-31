-- RecordWindow.lua — the loot log, readable by a human
--
-- HoDLootTracker's only surface is a box of export codes. That is fine for a
-- machine and useless for the question people actually ask after a raid — "who
-- rolled what on that, and what did I miss?" — which is why this window exists
-- and why it is the reason to have a second recorder at all.
--
-- Three things it has to do, and they are all Jason's (Session 243):
--   1. REVIEW — sessions, their drops, and every roll on each drop, expandable.
--   2. SEPARATE — a Guild/Personal tag per session, so a solo dungeon run is not
--      mixed into guild loot history and a personal history can be kept forever.
--   3. DELETE — one session at a time, so removing a stray run preserves the rest.
--
-- Export is SCOPED rather than compressed: guild-only or one session, which is
-- ~7 KB where the whole accumulated history is hundreds. See Record.Export and
-- rules/HoD_Rules_Loot-Gear.txt on why LibDeflate was declined.

local ADDON_NAME, ns = ...

local RecordWindow = {}
ns.RecordWindow = RecordWindow

local GOLD  = { 0.953, 0.773, 0.420 }
local WHITE = { 0.900, 0.900, 0.920 }
local MUTED = { 0.533, 0.533, 0.600 }
local GREEN = { 0.125, 0.729, 0.337 }
local RED   = { 1.000, 0.420, 0.420 }
local BLUE  = { 0.482, 0.655, 0.788 }   -- the site's pass-fallthrough colour

-- Roll types, coloured the way the site's Raid History colours its cohorts, so
-- the same roll reads the same in both places.
local ROLL_COLOR = {
  need     = GOLD,
  noroll   = GOLD,
  greed    = { 0.55, 0.75, 0.55 },
  transmog = { 0.75, 0.55, 0.80 },
  pass     = MUTED,
  personal = BLUE,
}

-- Geometry. Row counts are DERIVED from the frame height, never picked: WoW
-- frames do not clip their children, so a list longer than its space draws
-- straight over the footer and out through the window. (Panel.lua learned this
-- the hard way in Session 242.)
-- Wide enough for the run column to carry the recording CHARACTER without
-- eating the item list: SavedVariables are account-wide, so a log routinely
-- holds several characters' runs and "which of mine was that" is a question the
-- list has to answer at a glance.
local FRAME_W, FRAME_H = 760, 560
-- The window's own margin, matching Import and Settings.
local LOG_X = 40
-- Filters on the first content line, column headings beneath, lists under those
-- — the same three bands the Standings tab has.
local LOG_FILTER_Y, LOG_HEAD_Y = 128, 168
local LIST_TOP, LIST_BOTTOM = 190, 90
local LIST_H = FRAME_H - LIST_TOP - LIST_BOTTOM
-- The run rail keeps its width: SavedVariables are account-wide, so the column
-- carries the recording CHARACTER too and "which of mine was that" has to be
-- answerable at a glance.
local SESSION_W = 272
local ITEMS_X = LOG_X + SESSION_W + 20
-- 20 is the Standings row pitch, and the item list IS that table with different
-- columns. The run rows stay taller because each carries two lines.
local SESSION_ROW_H, ITEM_ROW_H = 34, 20
local SESSION_ROWS = math.floor(LIST_H / SESSION_ROW_H)
local ITEM_ROWS    = math.floor(LIST_H / ITEM_ROW_H)

local FILTERS = {
  { key = nil,                label = "All" },
  { key = "guild",            label = "Guild" },
  { key = "personal",         label = "Personal" },
}

local frame, exportFrame
local state = {
  filter     = "guild",   -- guild loot is what this is mostly for
  selected   = nil,       -- stored index of the selected session
  sessScroll = 0,
  itemScroll = 0,
  expanded   = {},        -- item key -> true
}

-- ---------------------------------------------------------------------------
-- Small builders
-- ---------------------------------------------------------------------------

-- ⚠️ ONE SEAM RESTYLES THE WHOLE WINDOW (Session 258). Every fontstring in this
-- file already went through fs(), so mapping the Blizzard template names it is
-- called with onto the redesign's roles restyles the Loot Log without touching
-- ninety call sites — and without inventing a second vocabulary for the same
-- three text weights. The template name stays as the CALLER'S way of saying
-- "normal / small / muted", which is what it always meant here.
--
-- THIS WINDOW HAS NO MOCK. Jason asked for a first pass drawn from the pages
-- that do (#257): the Runner's rail-and-detail shape for the list, Standings'
-- column treatment for the rows, the Import window's chrome for the buttons.
-- Anything here that reads as a decision is one of those three, applied.
local FS_ROLE = {
  GameFontNormal        = { "light",   "head", "white" },
  GameFontNormalSmall   = { "light",   "name", "white" },
  GameFontHighlightSmall= { "light",   "name", "white" },
  GameFontDisableSmall  = { "light",   "name", "textDim" },
}

local function fs(parent, template, x, y, width, justify)
  local S = ns.Style
  local role = FS_ROLE[template or "GameFontNormal"]
  local t
  if S and role then
    t = S.Text(parent, role[1], role[2], S.COLOR[role[3]], justify or "LEFT")
  else
    t = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    t:SetJustifyH(justify or "LEFT")
  end
  t:ClearAllPoints()
  if x then t:SetPoint("TOPLEFT", x, y) end
  if width then t:SetWidth(width) end
  t:SetWordWrap(false)
  return t
end

local function monthDay(dateStr)
  -- "2026-08-17" -> "Aug 17". Split on the literal dashes rather than parsed as
  -- a timestamp: this is a pure calendar string written by the client at capture
  -- time, and running it back through a date function would re-open the
  -- timezone trap for no benefit.
  local MONTHS = { "Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec" }
  local _, m, d = tostring(dateStr or ""):match("^(%d+)-(%d+)-(%d+)$")
  if not m then return tostring(dateStr or "?") end
  return ("%s %d"):format(MONTHS[tonumber(m)] or "?", tonumber(d))
end

local function buildSessionRow(parent, i)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(SESSION_ROW_H)
  row:SetPoint("TOPLEFT", 0, -(i - 1) * SESSION_ROW_H)
  row:SetPoint("TOPRIGHT", 0, -(i - 1) * SESSION_ROW_H)

  -- The Slots rail's selected ground: the rule blush at 10%. The old gold wash
  -- is the pre-redesign accent.
  row.hl = row:CreateTexture(nil, "BACKGROUND")
  row.hl:SetAllPoints()
  if ns.Style then
    row.hl:SetColorTexture(ns.Style.COLOR.rule.r, ns.Style.COLOR.rule.g,
      ns.Style.COLOR.rule.b, 0.1)
  else
    row.hl:SetColorTexture(0.95, 0.77, 0.42, 0.16)
  end
  row.hl:Hide()

  row.title = fs(row, "GameFontNormalSmall", 4, -3, SESSION_W - 10)
  row.meta  = fs(row, "GameFontDisableSmall", 4, -17, SESSION_W - 10)

  row:SetScript("OnClick", function(self)
    if not self.storedIndex then return end
    state.selected   = self.storedIndex
    state.itemScroll = 0
    state.expanded   = {}
    RecordWindow.Refresh()
  end)
  return row
end

--- The item's icon, or a question mark. Icons load asynchronously like names do,
--- so this is asked at DRAW time rather than stored on the entry.
local QUESTION_MARK = 134400
local function itemIcon(itemID)
  if not itemID then return QUESTION_MARK end
  local fn = (C_Item and C_Item.GetItemIconByID) or _G.GetItemIcon
  if fn then
    local ok, tex = pcall(fn, itemID)
    if ok and tex then return tex end
  end
  return QUESTION_MARK
end

local function toggleExpand(self)
  local key = self.itemKey or (self:GetParent() and self:GetParent().itemKey)
  if not key then return end
  state.expanded[key] = not state.expanded[key] or nil
  RecordWindow.Refresh()
end

local function buildItemRow(parent, i)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(ITEM_ROW_H)
  row:SetPoint("TOPLEFT", 0, -(i - 1) * ITEM_ROW_H)
  row:SetPoint("TOPRIGHT", 0, -(i - 1) * ITEM_ROW_H)

  -- A HOVER, not a selection, so it is the lighter of the two grounds.
  row.hl = row:CreateTexture(nil, "BACKGROUND")
  row.hl:SetAllPoints()
  if ns.Style then
    row.hl:SetColorTexture(ns.Style.COLOR.rule.r, ns.Style.COLOR.rule.g,
      ns.Style.COLOR.rule.b, 0.06)
  else
    row.hl:SetColorTexture(1, 1, 1, 0.06)
  end
  row.hl:Hide()

  -- Leaving a CHILD of the row is not leaving the row. Every OnLeave in here
  -- routes through this, so crossing from the item button to the delete button
  -- does not flicker the highlight off and snatch the button away mid-reach.
  local function hoverOff(self)
    local r = self:GetParent() or self
    if r.IsMouseOver and r:IsMouseOver() then return end
    r.hl:Hide()
    if r.del then r.del:Hide() end
  end

  -- The expand marker sits on the ROW, not on the item button, so reaching for
  -- it never raises a tooltip.
  row.expand = fs(row, "GameFontNormalSmall", 4, -3, 10)

  -- THE ITEM — icon plus name, and the ONLY thing in the row that raises a
  -- tooltip. Hovering anywhere else (the winner, the roll, the empty space) was
  -- putting a full item comparison on screen every time the mouse crossed the
  -- list, which made the list unusable to scan.
  row.item = CreateFrame("Button", nil, row)
  row.item:SetPoint("TOPLEFT", 16, 0)
  row.item:SetSize(238, ITEM_ROW_H)

  row.item.icon = row.item:CreateTexture(nil, "ARTWORK")
  row.item.icon:SetSize(14, 14)
  row.item.icon:SetPoint("LEFT", 0, 0)
  -- Trim the icon's built-in border, the standard 0.08 inset.
  row.item.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  row.item.name = fs(row.item, "GameFontNormalSmall", 18, -3, 218)

  -- The REAL tooltip from the link that actually dropped, so item level and
  -- bonus IDs come from the client rather than anything we recompute.
  row.item:SetScript("OnEnter", function(self)
    self:GetParent().hl:Show()
    local link = self:GetParent().link
    if not link then return end
    -- ⚠️ THE GAME'S OWN ITEM CARD, DELIBERATELY. Stats, sockets, set bonuses
    -- and the upgrade track are Blizzard's to draw; Tip.lua is for the addon's
    -- own explanatory tooltips. The S254 rule names both halves.
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
    GameTooltip:SetHyperlink(link)
    GameTooltip:Show()
  end)
  row.item:SetScript("OnLeave", function(self)
    GameTooltip:Hide()
    hoverOff(self)
  end)
  -- Clicking the item expands too — the row is one thing, and only the HOVER
  -- behaviour differs across it.
  row.item:SetScript("OnClick", toggleExpand)

  -- Everything to the right of the item: the winner and the roll. Plain text on
  -- the row, no tooltip.
  row.left  = fs(row, "GameFontNormalSmall", 4, -3, 250)   -- roll + note rows
  row.mid   = fs(row, "GameFontNormalSmall", 258, -3, 96)
  row.right = fs(row, "GameFontNormalSmall", 356, -3, 60, "RIGHT")

  -- REMOVE ONE DROP. Revealed on hover rather than drawn on every row: this is
  -- a correction, not part of reading the log, and 25 always-visible × marks
  -- would compete with the loot for attention.
  row.del = CreateFrame("Button", nil, row)
  row.del:SetSize(14, ITEM_ROW_H)
  row.del:SetPoint("TOPRIGHT", -2, 0)
  row.del.x = fs(row.del, "GameFontNormalSmall", 0, -3, 14, "CENTER")
  row.del.x:SetText("x")
  row.del:Hide()

  row.del:SetScript("OnEnter", function(self)
    self.x:SetTextColor(unpack(RED))
    ns.Tip:SetOwner(self, "ANCHOR_CURSOR")
    ns.Tip:SetText("Remove This Drop", 1, 1, 1)
    ns.Tip:AddLine("Deletes only this item. The rest of the run is kept.", 0.8, 0.8, 0.8, true)
    ns.Tip:Show()
  end)
  row.del:SetScript("OnLeave", function(self)
    self.x:SetTextColor(unpack(MUTED))
    ns.Tip:Hide()
    hoverOff(self)
  end)
  row.del:SetScript("OnClick", function(self)
    RecordWindow.ConfirmDeleteItem(self:GetParent().itemKey)
  end)

  row:SetScript("OnClick", toggleExpand)
  row:SetScript("OnEnter", function(self)
    self.hl:Show()
    -- Only a drop can be deleted. A roll line is part of the drop above it.
    if self.itemKey then
      self.del.x:SetTextColor(unpack(MUTED))
      self.del:Show()
    end
  end)
  row:SetScript("OnLeave", hoverOff)
  return row
end

-- ---------------------------------------------------------------------------
-- Flattening a session into rows
-- ---------------------------------------------------------------------------
--
-- Items and their rolls share one scrolling list, so an expanded item pushes the
-- rest down exactly as it looks. Building the flat list first also means the
-- scroll maths never has to know about expansion.

local function rowsFor(s)
  local rows = {}
  if not s then return rows end

  for _, e in ipairs(s.items) do
    local rollCount = 0
    for _ in pairs(e.rolls or {}) do rollCount = rollCount + 1 end
    rows[#rows + 1] = { kind = "item", entry = e, rollCount = rollCount }

    if state.expanded[e.key] then
      local list = {}
      for name, roll in pairs(e.rolls or {}) do
        list[#list + 1] = { name = name, roll = roll }
      end
      -- Winner first, then anyone who actually rolled (highest first), then the
      -- passes and non-rollers. That is the order the question is asked in.
      table.sort(list, function(a, b)
        if a.roll.isWinner ~= b.roll.isWinner then return a.roll.isWinner end
        local av, bv = a.roll.rollValue or 0, b.roll.rollValue or 0
        if av ~= bv then return av > bv end
        return a.name < b.name
      end)
      for _, r in ipairs(list) do
        rows[#rows + 1] = { kind = "roll", name = r.name, roll = r.roll, entry = e }
      end
      if #list == 0 then
        rows[#rows + 1] = { kind = "note", entry = e,
          text = e.isGroupLoot and "no rolls recorded" or "personal loot — no roll" }
      end
    end
  end
  return rows
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function build()
  frame = CreateFrame("Frame", "HoDLootAdvisorLootLog", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(FRAME_W, FRAME_H)
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
  -- The secondary windows' lighter violet, over what MakeWindow put down.
  if S then
    if frame.bgTex then frame.bgTex:Hide() end
    if frame.headTex then frame.headTex:Hide() end
    if frame.headLine then frame.headLine:Hide() end
    -- No rim: the fill is the window, exactly as on the panel.
    S.Surface(frame, S.COLOR.windowGround, 1)
    S.Lockup(frame, LOG_X, 30)
  end

  frame.heading = S and S.Text(frame, "light", "title", S.COLOR.white, "LEFT")
    or frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  if S then S.SetFont(frame.heading, S.FONT.light, 18) end
  frame.heading:ClearAllPoints()
  frame.heading:SetPoint("TOPLEFT", LOG_X, -86)
  frame.heading:SetText("LOOT LOG")

  -- ── Filters ───────────────────────────────────────────────────────────────
  -- The panel's tab treatment: one primitive, the selected one FILLED and the
  -- rest outlined at half strength. These behave as tabs, so they should look
  -- like the ones on the panel rather than like stock buttons.
  frame.filters = {}
  local fx = LOG_X
  for i, f in ipairs(FILTERS) do
    local b = S and S.Control(frame, f.label) or
      CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetHeight(27)
    if b.FitToLabel then b:Repaint():FitToLabel() else b:SetSize(70, 22) end
    b:SetPoint("TOPLEFT", fx, -LOG_FILTER_Y)
    fx = fx + (b:GetWidth() or 70) + 10
    if not S then b:SetText(f.label) end
    b:SetScript("OnClick", function()
      state.filter     = f.key
      state.selected   = nil
      state.sessScroll = 0
      state.itemScroll = 0
      RecordWindow.Refresh()
    end)
    frame.filters[i] = b
  end

  -- Right-aligned on the heading line, where Standings puts its season.
  frame.summary = fs(frame, "GameFontNormalSmall", ITEMS_X, -92,
    FRAME_W - ITEMS_X - LOG_X, "RIGHT")

  -- ⚠️ COLUMN HEADINGS TAKE THE HEADING PURPLE, not the old gold — the same
  -- treatment the Standings table and the Settings rows use. Gold is the
  -- pre-redesign accent and appears nowhere in the new palette.
  frame.sessHead = fs(frame, "GameFontNormal", LOG_X, -LOG_HEAD_Y, SESSION_W)
  frame.itemHead = fs(frame, "GameFontNormal", ITEMS_X, -LOG_HEAD_Y,
    FRAME_W - ITEMS_X - LOG_X)
  if S then
    for _, h in ipairs({ frame.sessHead, frame.itemHead }) do
      S.SetFont(h, S.FONT.bold, S.SIZE.head)
      h:SetTextColor(S.rgb(S.COLOR.accent))
    end
  end
  frame.sessHead:SetText("INSTANCE RUNS")

  -- Session list
  frame.sessList = CreateFrame("Frame", nil, frame)
  frame.sessList:SetPoint("TOPLEFT", LOG_X, -LIST_TOP)
  frame.sessList:SetWidth(SESSION_W)
  frame.sessList:SetHeight(LIST_H)
  frame.sessList:EnableMouseWheel(true)
  frame.sessList:SetScript("OnMouseWheel", function(_, delta)
    RecordWindow.Scroll("sessScroll", -delta)
  end)

  frame.sessRows = {}
  for i = 1, SESSION_ROWS do
    frame.sessRows[i] = buildSessionRow(frame.sessList, i)
    frame.sessRows[i]:Hide()
  end

  -- Item list
  frame.itemList = CreateFrame("Frame", nil, frame)
  frame.itemList:SetPoint("TOPLEFT", ITEMS_X, -LIST_TOP)
  frame.itemList:SetPoint("TOPRIGHT", -14, -LIST_TOP)
  frame.itemList:SetHeight(LIST_H)
  frame.itemList:EnableMouseWheel(true)
  frame.itemList:SetScript("OnMouseWheel", function(_, delta)
    RecordWindow.Scroll("itemScroll", -delta)
  end)

  frame.itemRows = {}
  for i = 1, ITEM_ROWS do
    frame.itemRows[i] = buildItemRow(frame.itemList, i)
    frame.itemRows[i]:Hide()
  end

  frame.empty = fs(frame, "GameFontDisableSmall", ITEMS_X + 6, -LIST_TOP - 6, FRAME_W - ITEMS_X - 24)
  frame.empty:SetWordWrap(true)

  frame.more = fs(frame, "GameFontDisableSmall", nil, nil, 300)
  frame.more:ClearAllPoints()
  frame.more:SetPoint("BOTTOMLEFT", LOG_X, 62)

  -- Footer controls
  -- ⚠️ THE IMPORT WINDOW'S CHROME, per Jason's brief for this page: the
  -- redesign's Control primitive at 26 tall on the window's own 40px margins,
  -- rather than four stock buttons at 22 on a 14px inset.
  frame.tag = S and S.Control(frame, "GUILD / PERSONAL")
    or CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.tag:SetSize(150, 26)
  frame.tag:SetPoint("BOTTOMLEFT", LOG_X, 27)
  if frame.tag.SetActive then frame.tag:SetActive(false) end
  if frame.tag.Repaint then frame.tag:Repaint() end
  frame.tag:SetScript("OnClick", function() RecordWindow.ToggleKind() end)
  frame.tag:SetScript("OnEnter", function(self)
    ns.Tip:SetOwner(self, "ANCHOR_CURSOR")
    ns.Tip:SetText("Guild or Personal", 1, 1, 1)
    ns.Tip:AddLine("Guild runs are what the website's loot history is for. Personal runs stay here, in the addon, and are left out of the bulk export.", 0.8, 0.8, 0.8, true)
    ns.Tip:AddLine("Set automatically — raid group means guild — and always yours to change.", 0.8, 0.8, 0.8, true)
    ns.Tip:Show()
  end)
  frame.tag:SetScript("OnLeave", function() ns.Tip:Hide() end)

  frame.del = S and S.Control(frame, "DELETE RUN")
    or CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.del:SetSize(110, 26)
  frame.del:SetPoint("LEFT", frame.tag, "RIGHT", 10, 0)
  if frame.del.SetActive then frame.del:SetActive(false) end
  if frame.del.Repaint then frame.del:Repaint() end
  if not S then frame.del:SetText("Delete Run") end
  frame.del:SetScript("OnClick", function() RecordWindow.ConfirmDelete() end)
  frame.del:SetScript("OnEnter", function(self)
    ns.Tip:SetOwner(self, "ANCHOR_CURSOR")
    ns.Tip:SetText("Delete Run", 1, 1, 1)
    ns.Tip:AddLine("Removes only the selected instance run. Everything else is kept.", 0.8, 0.8, 0.8, true)
    ns.Tip:Show()
  end)
  frame.del:SetScript("OnLeave", function() ns.Tip:Hide() end)

  frame.expSel = S and S.Control(frame, "EXPORT THIS RUN")
    or CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.expSel:SetSize(140, 26)
  frame.expSel:SetPoint("BOTTOMRIGHT", -(LOG_X + 160), 27)
  if frame.expSel.SetActive then frame.expSel:SetActive(false) end
  if frame.expSel.Repaint then frame.expSel:Repaint() end
  if not S then frame.expSel:SetText("Export This Run") end
  frame.expSel:SetScript("OnClick", function()
    if state.selected then RecordWindow.ShowExport({ index = state.selected }) end
  end)
  frame.expSel:SetScript("OnEnter", function(self)
    ns.Tip:SetOwner(self, "ANCHOR_CURSOR")
    ns.Tip:SetText("Export This Run", 1, 1, 1)
    ns.Tip:AddLine("Just the selected run — a few KB, and the only way a Personal run ever leaves the addon.", 0.8, 0.8, 0.8, true)
    ns.Tip:Show()
  end)
  frame.expSel:SetScript("OnLeave", function() ns.Tip:Hide() end)

  frame.expAll = S and S.Control(frame, "EXPORT GUILD LOOT")
    or CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.expAll:SetSize(150, 26)
  frame.expAll:SetPoint("BOTTOMRIGHT", -LOG_X, 27)
  if frame.expAll.SetActive then frame.expAll:SetActive(false) end
  if frame.expAll.Repaint then frame.expAll:Repaint() end
  if not S then frame.expAll:SetText("Export Guild Loot") end
  frame.expAll:SetScript("OnClick", function()
    RecordWindow.ShowExport({ kind = ns.Record.GUILD })
  end)
  frame.expAll:SetScript("OnEnter", function(self)
    ns.Tip:SetOwner(self, "ANCHOR_CURSOR")
    ns.Tip:SetText("Export Guild Loot", 1, 1, 1)
    ns.Tip:AddLine("Every Guild run, for pasting into the website's loot import. Personal runs are never included here.", 0.8, 0.8, 0.8, true)
    ns.Tip:AddLine("The site de-duplicates, so importing this alongside HoDLootTracker's export is harmless.", 0.8, 0.8, 0.8, true)
    ns.Tip:Show()
  end)
  frame.expAll:SetScript("OnLeave", function() ns.Tip:Hide() end)
end

-- ---------------------------------------------------------------------------
-- Export sub-window
-- ---------------------------------------------------------------------------

local function buildExport()
  exportFrame = CreateFrame("Frame", "HoDLootAdvisorLootExport", UIParent, "BasicFrameTemplateWithInset")
  exportFrame:SetSize(600, 400)
  exportFrame:SetPoint("CENTER", 0, -20)
  exportFrame:SetMovable(true)
  exportFrame:EnableMouse(true)
  exportFrame:RegisterForDrag("LeftButton")
  exportFrame:SetScript("OnDragStart", exportFrame.StartMoving)
  exportFrame:SetScript("OnDragStop", exportFrame.StopMovingOrSizing)
  exportFrame:SetFrameStrata("FULLSCREEN_DIALOG")
  ns.MakeWindow(exportFrame)
  exportFrame:Hide()
  exportFrame.TitleText:SetText("Loot Advisor — Export Loot")

  exportFrame.hint = fs(exportFrame, "GameFontNormalSmall", 16, -32, 560)
  exportFrame.hint:SetWordWrap(true)
  exportFrame.hint:SetTextColor(unpack(MUTED))

  local scroll = CreateFrame("ScrollFrame", "$parentScroll", exportFrame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 18, -68)
  scroll:SetPoint("BOTTOMRIGHT", -36, 46)

  local edit = CreateFrame("EditBox", nil, exportFrame)
  edit:SetMultiLine(true)
  edit:SetFontObject(ChatFontNormal)
  -- Explicit width: the scroll frame reports 0 before it has been shown, which
  -- silently produces a zero-size box and SetText discards everything.
  edit:SetWidth(540)
  edit:SetAutoFocus(false)
  edit:SetMaxLetters(0)
  if edit.SetMaxBytes then edit:SetMaxBytes(0) end
  edit:SetScript("OnEscapePressed", function() exportFrame:Hide() end)
  scroll:SetScrollChild(edit)
  exportFrame.edit = edit
end

--- Build the export for a scope and put it in front of the user.
function RecordWindow.ShowExport(opts)
  if not exportFrame then buildExport() end

  -- One last enumeration, so a kill whose rolls only just resolved is included.
  ns.Record.ScanAll()

  local text, items = ns.Record.Export(opts)
  if not text then
    ns.Warn("nothing to export in that scope.")
    return
  end

  exportFrame.hint:SetText(
    ("%d item%s. Click in the box, Ctrl-A to select all, Ctrl-C to copy — then paste into Raid History on the website."):format(
      items, items == 1 and "" or "s"))
  ns.RestoreWindowPosition(exportFrame)
  exportFrame:Raise()
  exportFrame:Show()
  exportFrame.edit:SetText(text)
  exportFrame.edit:SetCursorPosition(0)
  exportFrame.edit:HighlightText()
  exportFrame.edit:SetFocus()
end

-- ---------------------------------------------------------------------------
-- Destructive actions
-- ---------------------------------------------------------------------------

StaticPopupDialogs["HODLA_LOOT_DELETE"] = {
  text = "%s", button1 = "Delete", button2 = "Cancel",
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  OnAccept = function(self)
    local n = ns.Record.DeleteSession(self.data)
    ns.Print(("deleted that run — %d item%s removed."):format(n, n == 1 and "" or "s"))
    state.selected = nil
    RecordWindow.Refresh()
  end,
}

StaticPopupDialogs["HODLA_LOOT_ITEM_DELETE"] = {
  text = "%s", button1 = "Remove", button2 = "Cancel",
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  OnAccept = function(self)
    local e = ns.Record.DeleteItem(self.data.index, self.data.key)
    if e then
      ns.Print(("removed %s from that run."):format(e.itemName or "that drop"))
    else
      ns.Warn("that drop was already gone.")
    end
    RecordWindow.Refresh()
  end,
}

StaticPopupDialogs["HODLA_LOOT_CLEAR"] = {
  text = "%s", button1 = "Clear", button2 = "Cancel",
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  OnAccept = function(self)
    local n = ns.Record.Clear(self.data)
    ns.Print(("cleared %d recorded item%s."):format(n, n == 1 and "" or "s"))
    state.selected = nil
    RecordWindow.Refresh()
  end,
}

function RecordWindow.ConfirmDelete()
  if not state.selected then
    ns.Warn("select a run on the left first.")
    return
  end
  local db = ns.Record.DB()
  local s = db and db.sessions[state.selected]
  if not s then return end
  local popup = StaticPopup_Show("HODLA_LOOT_DELETE",
    ("Delete this run and its loot?\n\n%s — %s\n%s · %d items\n\nEverything else is kept."):format(
      monthDay(s.date), s.instance or "?", s.difficulty or "?", #s.items))
  if popup then popup.data = state.selected end
end

--- Remove a single drop. The run, and every other drop in it, is kept.
---
--- Exists because `/la loot fake` writes a REAL record on purpose, and until now
--- the only way to undo one was Delete Run — which took the genuine drops
--- recorded alongside it with it.
function RecordWindow.ConfirmDeleteItem(key)
  if not state.selected or not key then return end
  local db = ns.Record.DB()
  local s = db and db.sessions[state.selected]
  if not s then return end

  local entry
  for _, e in ipairs(s.items) do
    if e.key == key then entry = e; break end
  end
  if not entry then return end

  local who = (entry.winner and entry.winner ~= "") and entry.winner or "no winner recorded"
  local popup = StaticPopup_Show("HODLA_LOOT_ITEM_DELETE",
    ("Remove this drop from the run?\n\n%s\n%s · %s\n\nThe rest of the run is kept."):format(
      entry.itemName or "?", entry.boss or "?", who))
  if popup then popup.data = { index = state.selected, key = key } end
end

--- `filter` nil clears everything, or one tag's worth. Called from /la loot clear.
function RecordWindow.ConfirmClear(filter)
  local _, items = ns.Record.Counts(filter)
  if items == 0 then
    ns.Print("nothing recorded to clear.")
    return
  end
  local scope = filter and (filter == ns.Record.PERSONAL and "PERSONAL" or "GUILD") or "ALL"
  local popup = StaticPopup_Show("HODLA_LOOT_CLEAR",
    ("Clear %s recorded loot?\n\n%d item%s will be deleted. This cannot be undone."):format(
      scope, items, items == 1 and "" or "s"))
  if popup then popup.data = filter end
end

function RecordWindow.ToggleKind()
  if not state.selected then
    ns.Warn("select a run on the left first.")
    return
  end
  local db = ns.Record.DB()
  local s = db and db.sessions[state.selected]
  if not s then return end
  local now = (s.kind == ns.Record.PERSONAL) and ns.Record.GUILD or ns.Record.PERSONAL
  ns.Record.SetKind(state.selected, now)
  RecordWindow.Refresh()
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

function RecordWindow.Scroll(key, delta)
  state[key] = math.max(0, (state[key] or 0) + delta)
  RecordWindow.Refresh()
end

local function refreshSessions()
  local list = ns.Record.Sessions(state.filter)

  local maxScroll = math.max(0, #list - SESSION_ROWS)
  if state.sessScroll > maxScroll then state.sessScroll = maxScroll end

  -- Keep a selection pointing at something in view of the current filter.
  if state.selected then
    local stillThere = false
    for _, r in ipairs(list) do
      if r.index == state.selected then stillThere = true break end
    end
    if not stillThere then state.selected = nil end
  end
  if not state.selected and list[1] then state.selected = list[1].index end

  for i = 1, SESSION_ROWS do
    local row = frame.sessRows[i]
    local rec = list[i + state.sessScroll]
    if not rec then
      row:Hide()
    else
      local s = rec.session
      row.storedIndex = rec.index
      row.title:SetText(("%s · %s"):format(monthDay(s.date), s.instance or "?"))
      row.title:SetTextColor(unpack(WHITE))

      local kind = (s.kind == ns.Record.PERSONAL) and "Personal" or "Guild"
      -- The recording character is on the row, not just in a tooltip: the log is
      -- account-wide, so "was that my main or my alt" is asked of every row.
      row.meta:SetText(("%s · %s · %d · %s"):format(
        s.character or "?", s.difficulty or "?", #s.items, kind))
      row.meta:SetTextColor(unpack(s.kind == ns.Record.PERSONAL and BLUE or MUTED))

      row.hl:SetShown(rec.index == state.selected)
      row:Show()
    end
  end

  return list
end

local function refreshItems()
  local db = ns.Record.DB()
  local s = state.selected and db and db.sessions[state.selected]

  frame.itemHead:SetText(s and ("%s · %s"):format(s.instance or "?", s.difficulty or "?") or "")

  local rows = rowsFor(s)
  local maxScroll = math.max(0, #rows - ITEM_ROWS)
  if state.itemScroll > maxScroll then state.itemScroll = maxScroll end

  if #rows == 0 then
    for i = 1, ITEM_ROWS do frame.itemRows[i]:Hide() end
    frame.empty:SetText(s
      and "No loot recorded for this run yet."
      or "No runs recorded yet.\n\nRecording starts on its own when a boss dies in a raid or dungeon — nothing to turn on.")
    frame.empty:Show()
    frame.more:SetText("")
    return
  end
  frame.empty:Hide()

  for i = 1, ITEM_ROWS do
    local row = frame.itemRows[i]
    local r = rows[i + state.itemScroll]
    if not r then
      row:Hide()
    else
      row.itemKey, row.link = nil, nil
      -- Rows are recycled, so a row that showed a drop last refresh may be a
      -- roll line now. Clearing this here is what stops the delete button
      -- lingering over a line that has nothing to delete.
      row.del:Hide()

      if r.kind == "item" then
        local e = r.entry
        row.itemKey = e.key
        -- ItemLinkFor rebuilds a link from the item id when the drop did not
        -- carry one (an injected row), so the tooltip works either way.
        row.link    = e.itemLink or (e.itemID and ns.ItemLinkFor(e.itemID))

        row.expand:SetText(state.expanded[e.key] and "-" or "+")
        row.expand:SetTextColor(unpack(MUTED))
        row.left:SetText("")

        row.item.icon:SetTexture(itemIcon(e.itemID))
        row.item.name:SetText(e.itemName or "?")
        row.item.name:SetTextColor(unpack(WHITE))
        row.item:Show()

        if e.winner and e.winner ~= "" then
          row.mid:SetText(e.winner)
          row.mid:SetTextColor(unpack(GREEN))
        else
          row.mid:SetText("no winner yet")
          row.mid:SetTextColor(unpack(MUTED))
        end

        -- A pass-fallthrough win has a meaningless auto-roll value, so it is
        -- suppressed and labelled instead — the same rule the site's Raid
        -- History follows (Loot-Gear rules, "PASS-FALLTHROUGH WIN HANDLING").
        if e.winRollType == "pass" then
          row.right:SetText("all passed")
          row.right:SetTextColor(unpack(BLUE))
        elseif e.winRollType == "personal" then
          row.right:SetText("personal")
          row.right:SetTextColor(unpack(BLUE))
        elseif (e.winRollValue or 0) > 0 then
          row.right:SetText(tostring(e.winRollValue))
          row.right:SetTextColor(unpack(GOLD))
        else
          row.right:SetText(r.rollCount > 0 and ("%d rolls"):format(r.rollCount) or "")
          row.right:SetTextColor(unpack(MUTED))
        end

      elseif r.kind == "roll" then
        local roll = r.roll
        row.item:Hide()
        row.expand:SetText("")
        row.left:SetText("      " .. r.name)
        row.left:SetTextColor(unpack(roll.isWinner and GREEN or MUTED))
        -- ⚠️ THE RAW STATE RIDES ALONGSIDE THE LABEL, deliberately. Our
        -- ROLL_STATE map is INHERITED from HoDLootTracker and has never been
        -- verified against a real group-loot raid; the first night of evidence
        -- (Session 250) recorded state 0 on 125 rolls that all carried a real
        -- roll VALUE, which "noroll" cannot mean. Transmog never appears at all.
        --
        -- The map is NOT being changed on that — the standing rule is to wait
        -- for evidence rather than guess, and one night does not yet say what 0,
        -- 1 and 2 ARE. What this does is put the number where a human can read
        -- it beside the game's own roll window, so the next raid decodes it
        -- without anyone parsing a SavedVariables file.
        local label = roll.rollType or "?"
        if roll.state ~= nil then label = ("%s [%d]"):format(label, roll.state) end
        row.mid:SetText(label)
        row.mid:SetTextColor(unpack(ROLL_COLOR[roll.rollType or ""] or MUTED))
        -- 0 means "did not roll", which is information, not a zero. Blank it
        -- rather than print a number that reads as a terrible roll.
        row.right:SetText((roll.rollValue or 0) > 0 and tostring(roll.rollValue) or "—")
        row.right:SetTextColor(unpack(roll.isWinner and GREEN or MUTED))

      else
        row.item:Hide()
        row.expand:SetText("")
        row.left:SetText("      " .. (r.text or ""))
        row.left:SetTextColor(unpack(MUTED))
        row.mid:SetText("")
        row.right:SetText("")
      end

      row:Show()
    end
  end

  -- Overflow is COUNTED, never silently cut.
  if #rows > ITEM_ROWS then
    local first = state.itemScroll + 1
    local last  = math.min(#rows, state.itemScroll + ITEM_ROWS)
    frame.more:SetText(("showing %d-%d of %d — scroll to see the rest"):format(first, last, #rows))
  else
    frame.more:SetText("")
  end
end

function RecordWindow.Refresh()
  if not frame or not frame:IsShown() then return end

  -- Item data loads asynchronously, so a drop captured seconds after a kill can
  -- still be a bare "item:270160" the first time the window opens. Re-asking on
  -- every draw turns it into a real name as soon as the client can answer.
  ns.Record.ResolveItemInfo()

  for i, f in ipairs(FILTERS) do
    frame.filters[i]:SetEnabled(state.filter ~= f.key)
  end

  local _, gi = ns.Record.Counts(ns.Record.GUILD)
  local _, pi = ns.Record.Counts(ns.Record.PERSONAL)
  local counts = ("%d guild · %d personal items recorded"):format(gi, pi)

  -- ⚠️ SAY WHICH ROLL-STATE MAP IS IN FORCE. When the client names its own roll
  -- states we read those; when it does not we fall back to the inherited number
  -- map, which is KNOWN WRONG (Session 251 — see Record.lua). A wrong roll label
  -- looks exactly as plausible as a right one, so the fallback being in use has
  -- to be visible somewhere a person actually looks, not only in a log.
  local source, unresolved = nil, nil
  if ns.RollStateSource then source, unresolved = ns.RollStateSource() end
  if source == "inherited" then
    frame.summary:SetText(counts .. "  ·  roll labels UNVERIFIED (no state names from the client)")
  elseif unresolved and #unresolved > 0 then
    -- The COUNT here and the NAMES in the diagnostics. A state the client names
    -- but we do not recognise is the next version of the roll-label bug, and the
    -- person reading this window is the one who would notice a roll labelled
    -- oddly — so the window has to say "there is something to look at" even
    -- though it has no room to say what.
    frame.summary:SetText(counts ..
      ("  ·  %d roll state%s the client names that we do not"):format(
        #unresolved, #unresolved == 1 and "" or "s"))
  else
    frame.summary:SetText(counts)
  end

  refreshSessions()
  refreshItems()

  local db = ns.Record.DB()
  local s = state.selected and db and db.sessions[state.selected]
  frame.tag:SetEnabled(s ~= nil)
  frame.del:SetEnabled(s ~= nil)
  frame.expSel:SetEnabled(s ~= nil)
  -- ⚠️ SET _label, NOT JUST THE STRING. Style.Control remembers its own label
  -- and Repaint() rewrites the fontstring FROM it — so a SetText alone is
  -- undone the next time anything repaints this button, and the label silently
  -- reverts to whatever it was built with. FitToLabel because the two words are
  -- different lengths.
  local tagLabel = (s and s.kind == ns.Record.PERSONAL) and "MARK GUILD" or "MARK PERSONAL"
  frame.tag._label = tagLabel
  frame.tag:SetText(tagLabel)
  if frame.tag.FitToLabel then frame.tag:FitToLabel() end
end

function RecordWindow.Toggle()
  if not frame then build() end
  if frame:IsShown() then
    frame:Hide()
    return
  end
  -- Catch up before showing, so what is on screen is what the client currently
  -- believes rather than what it believed when the last event fired.
  ns.Record.ScanAll()
  ns.DockBesidePanel(frame, "LEFT")
  frame:Show()
  RecordWindow.Refresh()
end
