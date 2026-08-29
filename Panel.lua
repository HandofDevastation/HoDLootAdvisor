-- Panel.lua — the Loot Advisor panel
--
-- REBUILT IN SESSION 250 to Jason's Figma design. The old panel was six tabs
-- over a horizontal chip strip; this is three tabs over a two-column reading
-- surface:
--
--   [ Loot | Standings | Runner ]                       tabs
--   Boss name                     ( )( )( )( )( )( )    BOSS STRIP — portraits
--   For You: 1 BIS | 2 Targets
--   [Current Drops][Full Loot Table]  ┌──────────────────────────────────┐
--   [Usable Only  ][All Loot       ]  │ Upgrade for You  Standing  EPGP  │
--   ┌────────────────────┐            │ +17 ilvl | -16 behind | BIS      │
--   │ Item name      * ◆ │            │ [icon] Item name      Won By:    │
--   │ MAJOR • Chest,Plate│  <- the    │ RAIDER   UPGRADE  GAIN  PRIORITY │
--   │ Item name          │   SELECTOR │ 1 Corvá  BIS Major  +26   4.122  │
--   └────────────────────┘            └──────────────────────────────────┘
--   Your Gear: LIVE          [Import Raid Night][Loot Log][Settings]
--
-- WHY IT CHANGED SHAPE. The panel is an OUT-OF-COMBAT REFERENCE (Session 249,
-- Jason: "literally NOBODY would ever have this addon open during combat"), so
-- width is nearly free and the layout optimises for READING. The horizontal chip
-- strip existed to fit five drops into a narrow window; with the width available
-- the items become a vertical selector, which holds a full loot table rather
-- than five chips and a pager.
--
-- WHAT DID NOT CHANGE, and must not: the two rankings are still different
-- SHAPES. EPGP priority is one global list of the whole raid, stable through a
-- kill; upgrade magnitude is a different list per item. So the detail pane still
-- orders by upgrade with priority as a COLUMN, and the full ladder still lives
-- on its own tab. That is Arrangement A and it is settled.
--
-- ⚠️ NO LOGIC IN THIS FILE. No harness loads it — anything put here ships having
-- never run. Ordering, banding, the slot line, the ordinal and the counts all
-- live in Core.lua; the winner lookup lives in Record.lua; the runner report
-- lives in Comms.lua. This file builds frames and sets text.
--
-- Nothing here posts to chat on its own — the Post button is the only path.

local ADDON_NAME, ns = ...

local Panel = {}
ns.Panel = Panel

local GOLD  = { 0.953, 0.773, 0.420 }
local WHITE = { 1, 1, 1 }
local MUTED = { 0.533, 0.533, 0.600 }

-- The item-quality tag (text + colour) and the badge ramp live outside this
-- file: the tag is pure logic the tooltip needs too, and the ramp is shared with
-- the detail header, so a single table beats three that drift.
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

-- Runner is LAST and conditional: Experience §3 gives it to whoever loaded the
-- data, and Session 249 made that a rule — the tab renders ONLY for the runner.
local TABS = { "Loot", "Standings", "Runner" }

-- ---------------------------------------------------------------------------
-- Geometry — read straight off the Figma frame, at 1:1
-- ---------------------------------------------------------------------------
--
-- The design is a FIXED-SIZE window (Session 249): everything from the title
-- down to the boss strip is fixed, as is the bottom bar. Only the two middle
-- columns scroll, and they scroll independently.
--
-- Numbers are the mock's own coordinates rather than derived ones, so a value
-- here can be checked against the file by eye. Where a count IS derived
-- (COL_ROWS, RANK_ROWS) it is derived from the space, never picked — WoW frames
-- do not clip their children, so a row count larger than the space available
-- draws straight through whatever is below it instead of scrolling.

local FRAME_W, FRAME_H = 620, 560

local PAD = 20

local TAB_Y, TAB_W, TAB_H, TAB_PITCH = 60, 100, 24, 110

-- Boss strip: 32px portraits, right-aligned to the window's right margin.
local BOSS_Y, BOSS_SIZE, BOSS_PITCH = 102, 32, 42
local BOSS_SLOTS = 9
-- The selection underline, drawn BELOW the tile. Named because two things have
-- to agree about it: the bar's own height and the gap left for it before the
-- overflow line, and they drifted apart the moment one was a literal.
local SEL_H = 4

local CTX_Y = 100          -- boss name + "For You:" block, left of the strip

-- Two 2x2 filter toggles.
local TOG_X, TOG_Y = 20, 150
local TOG_W, TOG_H = 92, 24
local TOG_COL, TOG_ROW = 99, 27

-- The item column: the selector.
local COL_X, COL_W, COL_TOP = 20, 198, 211
local ITEM_H, ITEM_PITCH = 38, 40

-- The detail pane.
local PANE_X, PANE_Y, PANE_W, PANE_H = 220, 149, 380, 360

-- The bottom bar.
local FOOT_Y, FOOT_H = 509, 51

-- ── Standings tab ──────────────────────────────────────────────────────────
--
-- A DIFFERENT TABLE, not the Loot pane's with different headings: five columns
-- against four, different x positions, and it fills the window rather than a
-- 380px pane. It gets its own row set for that reason — recycling one row across
-- two geometries means every render re-points every fontstring, which is how the
-- old panel ended up needing resetRow discipline in the first place.
-- Difficulty dropdown, on the tab row's right (Loot tab only — the Standings
-- design puts the season name in that space instead).
-- WIDER SINCE SESSION 251: the label now names the CONTENT as well as the
-- difficulty ("Raid: Heroic"), which no longer fits 100px.
local DIFF_X, DIFF_Y, DIFF_W, DIFF_H = 460, 60, 140, 24
-- Gap between the Vault/Voidcore checkbox and the difficulty control it sits
-- beside. The control is anchored to the dropdown's LEFT edge and sizes itself
-- from its label, so it grows LEFTWARDS towards the tab row.
--
-- ⚠️ THERE IS A BUDGET AND IT IS NOT LARGE. The last tab ends at
-- PAD + 2*TAB_PITCH + TAB_W = 340, and the control's right edge is DIFF_X minus
-- this gap = 448, so the label has 108px before the two collide — and an overlap
-- would not merely look wrong, it would put two mouse-enabled frames on the same
-- pixels, where only one receives a click. Measured from the bundled font rather
-- than guessed: "Vault/Voidcore" in Khand-Medium at Style.SIZE.head is 69.4px,
-- plus a 14px box and a 6px gap = 89.4px, leaving ~19px clear. A longer label
-- needs re-measuring, not eyeballing.
local VAULT_GAP = 12

-- ── Runner tab (Session 252, from Jason's mock) ─────────────────────────────
-- Panel-relative, read off the Figma frame rather than eyeballed: the mock's
-- origin is (2383, 779) and every number below is a node position minus that.
--
-- A left RAIL of state (are you running it, what is loaded, the two controls)
-- and a right COLUMN of detail, split by a full-height hairline — the same
-- shape the Standings tab uses, which is what makes the two read as one design.
local RN_RAIL_X      = 20
local RN_RAIL_W      = 120
local RN_STATUS_Y    = 117    -- "YOU ARE RUNNING LOOT", wraps to two lines
local RN_SINCE_Y     = 158
local RN_DATA_Y      = 233    -- "TONIGHT'S DATA"
local RN_RAIDERS_Y   = 252
local RN_RANKED_Y    = 272
local RN_IMPORTED_Y  = 296
local RN_SYNCED_Y    = 309
local RN_AUTO_Y      = 428    -- the two rail controls, 119x24 in the mock
local RN_TOGGLE_Y    = 462
local RN_BTN_X, RN_BTN_W, RN_BTN_H = 16, 119, 24

local RN_DIV_X, RN_DIV_Y, RN_DIV_H = 151, 113, 373

local RN_COL_X       = 178
local RN_COL_W       = 406    -- the mock's divider width; the column matches it
local RN_LEAD_Y      = 115
local RN_LEAD_SUB_Y  = 133
local RN_LEAD_SUB_W  = 259    -- narrower on purpose: it is what makes the mock
                              -- wrap this sentence onto two lines
local RN_D1_Y        = 191
local RN_PEERS_Y     = 211
local RN_PEER_TOP    = 237
local RN_PEER_PITCH  = 16
local RN_PEER_ROWS   = 4
-- Name / version / gear state, as three columns off the mock's text nodes.
local RN_PEER_NAME_X = 0
local RN_PEER_VER_X  = 79     -- 2640 - 2561
local RN_PEER_GEAR_X = 186    -- 2747 - 2561
local RN_D2_Y        = 303
local RN_MISS_Y      = 322
local RN_MISS_BODY_Y = 341
local RN_D3_Y        = 377
local RN_SPEC_Y      = 394
local RN_SPEC_BODY_Y = 413
local DIFF_CHOICES = { "AUTO", "NORMAL", "HEROIC", "MYTHIC", "MPLUS" }
local DIFF_LABEL = {
  AUTO = "Auto", NORMAL = "Raid: Normal", HEROIC = "Raid: Heroic",
  MYTHIC = "Raid: Mythic", MPLUS = "Dungeons",
}

local SEASON_R = 583                 -- season label, right-aligned, on the tab row
local RAIL_X = 20                    -- the personal rail down the left
local RAIL_BLOCK_Y = { 117, 213, 299, 395 }   -- Priority · Earned/Spent · Attendance · Last item
-- Which of those carry the big orange figure. Earned/Spent and Last Item Won
-- do NOT, so their text lines start straight under the heading — see
-- buildRailBlock. Keep this in step with renderRail: a block that sets `big`
-- must be false here, or its figure and its first line collide.
local RAIL_BLOCK_COMPACT = { false, true, false, true }
local ST_DIV_X, ST_DIV_Y, ST_DIV_H = 151, 114, 373
local ST_HEAD_Y = 117
local ST_TOP, ST_PITCH = 141, 16
-- Derived from the space the divider encloses, never picked: WoW frames do not
-- clip their children, so a row count larger than the space draws through the
-- footer instead of scrolling.
local ST_ROWS = math.floor(((ST_DIV_Y + ST_DIV_H) - ST_TOP) / ST_PITCH)
-- Name is left-aligned; every number column is right-aligned to its own edge,
-- which is also where the design puts each heading's right edge.
local ST_RANK_R, ST_NAME = 190, 203
local ST_EP_R, ST_GP_R, ST_PR_R, ST_LAST_R = 335, 410, 488, 583

local COL_ROWS = math.floor((FOOT_Y - COL_TOP) / ITEM_PITCH)

-- Detail-pane internals, all absolute in frame space.
local HEAD_Y      = 161     -- the three header blocks
-- ⚠️ CENTRED BY MEASUREMENT, NOT BY EYE (Session 254; the S252 rule about
-- measuring the string rather than eyeballing the layout, applied to a box). The
-- hairlines are 1px, so the band between them runs 206 to 230 — 24 tall — and
-- this line's text box measures 10.94 at the 11px size. Centred is
-- 206 + (24 - 10.94)/2 = 212.5, taken DOWN to 212 because the box carries
-- descender space the glyphs do not fill, so the ink sits high within it. It was
-- 209, which put 3px above the text and 10 below and read as sloppy.
local FACTS_Y     = 212     -- "+17 ilvl | -16 behind | Overall BIS | Targeted"
local ITEM_Y      = 240     -- the selected item's icon + name
local ITEM_ICON   = 32      -- sized to the text beside it; see DIV3_Y below
-- ⚠️ EVERYTHING BELOW THE ITEM ROW MOVED UP 8 WITH IT, so the gaps it sits in are
-- unchanged: div3 to this heading was 12 before and is 12 now. Shifting the line
-- alone would have fixed the icon and opened a hole underneath it.
local RANK_HEAD_Y = 294     -- RAIDER / UPGRADE / GAIN / PRIORITY
local RANK_TOP    = 318
local RANK_PITCH  = 16
local RANK_ROWS   = 9
local MORE_Y      = 464
local NOTE_Y      = 481

local DIV_X, DIV_W = 230, 360   -- the pane's horizontal hairlines
-- ⚠️ DIV3 FOLLOWS THE ICON, WHICH FOLLOWS THE TEXT (Jason, Session 254: shrink
-- the icon to the text rather than moving the text to the icon). The name and
-- sub-line occupy 243 to 268.94; a 32px icon at ITEM_Y spans 240 to 272 and so
-- centres them with 3.0 above and 3.06 below. div2 sits 10 above the block, so
-- div3 sits 10 below it: 272 + 10 = 282, where a 40px icon had forced 290.
local DIV1_Y, DIV2_Y, DIV3_Y = 205, 230, 282

-- Column x positions inside the ranked table. GAIN and PRIORITY are RIGHT
-- edges, because both are numbers and numbers align on their right.
local C_RANK, C_NAME, C_UPGRADE = 231, 246, 352
local C_GAIN_R, C_PRIORITY_R = 499, 591

-- ⚠️ MARKS ARE IMAGES, NEVER CHARACTERS (Session 249, verified against the
-- bundled fonts: General Sans and Khand carry NONE of the star or diamond
-- glyphs, and a missing glyph in a custom font renders as NOTHING rather than
-- falling back). Blizzard's raid-target atlas supplies both shapes in one
-- texture every client already has, so this needs no bundled art and cannot
-- draw blank the way Build Barn's per-tier boss icons can. Desaturated first so
-- the vertex colour lands clean over the atlas's own yellow and purple.
-- ── The gutter marks ────────────────────────────────────────────────────────
-- ⚠️ THESE ARE THE DESIGN'S OWN ARTWORK, NOT BLIZZARD'S RAID MARKERS. They were
-- the raid-targeting icon sheet desaturated and tinted, which is close enough to
-- describe in a sentence and wrong on sight: the design's BIS mark is a faceted
-- GEM drawn in hairlines, not the solid rhombus that sheet carries, and its
-- target is an OUTLINED star rather than a filled one.
--
-- Exported from the Figma file as vectors and rasterised at 64px — the paths
-- themselves, so the shapes are the designed ones rather than an approximation.
-- Drawn WHITE so the existing per-mark tint still applies; the design's colours
-- (target #20BA56, BIS #FFF468) already live in Style.COLOR and are unchanged.
local MARK_TARGET_TEX = "Interface\\AddOns\\HoDLootAdvisor\\Media\\ui\\mark-target.png"
local MARK_BIS_TEX    = "Interface\\AddOns\\HoDLootAdvisor\\Media\\ui\\mark-bis.png"
local MARK_SIZE = 12
-- A fixed-width gutter at the row's right so names align whether or not a row
-- carries marks. Wide enough for BOTH marks plus their inset — an item can be
-- targeted AND best-in-slot, and at 30 the name ran three pixels under the star.
local MARK_GUTTER = 36

--- The badge's label and colour, as two values.
---
--- ⚠️ NOT `local a, b = S and S.Badge(x)`. An `and` expression is ADJUSTED TO ONE
--- VALUE in a multiple assignment, so that form silently drops the colour and
--- every badge in the panel would have drawn in the default text colour. Wrapped
--- here once rather than written out at four call sites, three of which had it
--- wrong.
local function badgeOf(key)
  local S = ns.Style
  if not S then return nil, nil end
  return S.Badge(key)
end

--- A literal pipe, for WoW's escape syntax. A single "|" starts a colour or a
--- link sequence; "||" is how you draw one.
local BAR = "||"

--- Relabel a control, whichever kind it turned out to be.
---
--- Style.Pill keeps its label at `.text`; the Blizzard template fallback keeps
--- its own behind SetText. Style.lua loading is a packaging guarantee rather
--- than a runtime one, and every other helper in this file degrades rather than
--- erroring — a nil index here would take down the whole refresh.
local function setLabel(btn, label)
  if not btn then return end
  if btn.text and btn.text.SetText then btn.text:SetText(label or "")
  elseif btn.SetText then btn:SetText(label or "") end
end

local frame
local state = {
  tab = "Loot",
  sel = 1, bossIndex = 1,
  colScroll = 0, rankScroll = 0,
  -- The two filter toggles. `source` is which list the column shows; `filter`
  -- is whether it hides what this character cannot use.
  source = "drops",     -- "drops" | "table"
  filter = "usable",    -- "usable" | "all"
  -- The Standings tab's provisional sub-view. See renderStandingsTab.
  instIndex = 1, encIndex = 1, targetMode = "browse",
}

-- ---------------------------------------------------------------------------
-- Builders
-- ---------------------------------------------------------------------------

--- Every fontstring goes through here, which is what lets the type system be
--- swapped in one edit. Roles and sizes are the addon's own (Style.lua), not
--- Blizzard template names — the old TEMPLATE_ROLE indirection existed only to
--- avoid touching ~40 call sites during the DS port and every call site is being
--- rewritten anyway.
local function text(parent, role, size, color, justify)
  local S = ns.Style
  if S then return S.Text(parent, role, size, color and S.COLOR[color], justify) end
  -- Style.lua missing is a packaging fault, not a reason to draw nothing.
  local t = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  t:SetJustifyH(justify or "LEFT")
  t:SetWordWrap(false)
  return t
end

--- Write text that MUST repaint, even when the string has not changed.
---
--- ⚠️ THE OLDEST RECURRING COMPLAINT ABOUT THESE ADDONS, FINALLY MEASURED
--- (Session 254): "it only shows up after I close and reopen, or switch view."
--- A line whose FIRST paint did not take stays blank forever, because handing a
--- text object the string it already holds does not redraw it.
---
--- THE EVIDENCE, from two draws logged in the same second on a cold client. The
--- item name and the verdict beneath it are the same font, the same colour, the
--- same row, written four lines apart. Both reported visible, alpha 1, font
--- loaded, a real string width and a resolved rect — IDENTICALLY in the draw
--- that rendered and the draw that did not. The only difference between them:
--- the verdict's string CHANGED between the two draws ("TRINKET" from our
--- payload, then "Trinket" from the journal) and it rendered; the name's string
--- was identical both times ("Wavecaller's Seastone" from either source) and it
--- did not.
---
--- IT ALSO EXPLAINS THE TWO SYMPTOMS NOTHING ELSE COULD. Switching boss repairs
--- a row because the name changes. And Nek'zali's sixth item NEVER repaired at
--- any point, because it is the season's only six-item boss — so that sixth row
--- is the one row whose name has nothing to change to.
---
--- Cheap: nine rows, on a refresh a person triggered.
local function setTextForce(fs, s)
  if not fs then return end
  fs:SetText("")
  fs:SetText(s)
end

--- Place a fontstring by the mock's own coordinates.
local function at(fs, x, y, width, justify)
  fs:ClearAllPoints()
  fs:SetPoint("TOPLEFT", x, -y)
  if width then fs:SetWidth(width) end
  if justify then fs:SetJustifyH(justify) end
  return fs
end

--- Place a right-aligned fontstring by its RIGHT edge, which is how the mock
--- positions the two numeric columns.
local function atRight(fs, right, y, width)
  fs:ClearAllPoints()
  fs:SetPoint("TOPLEFT", right - width, -y)
  fs:SetWidth(width)
  fs:SetJustifyH("RIGHT")
  return fs
end

local function divider(parent, x, y, w)
  local S = ns.Style
  local t
  if S then
    t = S.Divider(parent, S.COLOR.rim, 0.25)
  else
    t = parent:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(1, 1, 1, 0.15)
    t:SetHeight(1)
  end
  t:SetPoint("TOPLEFT", x, -y)
  t:SetWidth(w)
  return t
end

--- Flag or unflag whatever item a control is carrying, and say which happened.
--- Right-click is the gesture everywhere: left-click selects, and nothing else
--- in the addon uses right-click.
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

--- One 12px mark in the item row's gutter.
local function buildMark(parent, texture, colorKey, offsetFromRight)
  local m = parent:CreateTexture(nil, "OVERLAY")
  m:SetSize(MARK_SIZE, MARK_SIZE)
  m:SetPoint("RIGHT", -offsetFromRight, 0)
  m:SetTexture(texture)
  -- No SetTexCoord and no SetDesaturated: each mark is its own file and is
  -- already white, so the tint below is the only colour it ever takes.
  local S = ns.Style
  if S and S.COLOR[colorKey] then
    m:SetVertexColor(S.rgb(S.COLOR[colorKey]))
  end
  m:Hide()
  return m
end

--- One row of the item column: a two-line selector button.
local function buildItemRow(parent, i)
  local row = CreateFrame("Button", nil, parent)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetSize(COL_W, ITEM_H)
  row:SetPoint("TOPLEFT", 0, -(i - 1) * ITEM_PITCH)

  local S = ns.Style
  row.bg = row:CreateTexture(nil, "BACKGROUND")
  row.bg:SetAllPoints()
  if S then
    row.bg:SetColorTexture(S.COLOR.purple.r, S.COLOR.purple.g, S.COLOR.purple.b, 0.1)
  else
    row.bg:SetColorTexture(1, 1, 1, 0.05)
  end

  -- Two lines, as the design draws them: name on top, verdict and slot beneath.
  -- The name gives up the gutter's width so a marked row and an unmarked one
  -- start their text at the same place and truncate at the same place.
  row.name = at(text(row, "body", "small", "text"), 12, 5, COL_W - 12 - MARK_GUTTER)
  row.sub  = at(text(row, "body", "tiny", "text"), 12, 21, COL_W - 12 - MARK_GUTTER)

  -- BIS sits outermost, the target inside it — the pair reads left-to-right as
  -- "you want this" then "it is the best one".
  row.markBis    = buildMark(row, MARK_BIS_TEX, "bis", 6)
  row.markTarget = buildMark(row, MARK_TARGET_TEX, "target", 6 + MARK_SIZE + 3)

  row:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
      if self.itemID then toggleTarget(self.itemID, { name = self.itemName }) end
      return
    end
    if self.entryIndex then
      state.sel = self.entryIndex
      state.rankScroll = 0
      Panel.Refresh()
    end
  end)
  -- ⚠️ NO TOOLTIP ON THESE ROWS (Jason, Session 251). The column is a SELECTOR,
  -- and it is scrolled and clicked through — a full item tooltip firing on every
  -- row the pointer crosses covered the detail pane the column exists to drive,
  -- so reading the thing you just selected meant moving the mouse away first.
  -- The item tooltip now lives on the detail pane's icon and name, which is the
  -- one place you are actually looking at an item rather than choosing between
  -- them. Hovering still highlights the row.
  row:SetScript("OnEnter", function(self)
    if S then self.bg:SetColorTexture(S.COLOR.purple.r, S.COLOR.purple.g, S.COLOR.purple.b, 0.28) end
  end)
  row:SetScript("OnLeave", function(self)
    if S then
      self.bg:SetColorTexture(S.COLOR.purple.r, S.COLOR.purple.g, S.COLOR.purple.b,
        self._selected and 0.2 or 0.1)
    end
  end)
  return row
end

--- One boss portrait in the strip.
---
--- The selected boss takes a 4px orange underline BENEATH the tile rather than a
--- rim or a fill: a rim on a 32px tile eats the art, and the underline is what
--- the design draws. It sits outside the tile so it covers none of the picture.
local function buildBossTile(parent, i)
  local tile = CreateFrame("Button", nil, parent)
  tile:SetSize(BOSS_SIZE, BOSS_SIZE)
  tile:SetPoint("LEFT", (i - 1) * BOSS_PITCH, 0)

  local S = ns.Style
  tile.art = tile:CreateTexture(nil, "ARTWORK")
  tile.art:SetAllPoints()

  -- THE FALLBACK IS A TILE, NOT NOTHING. Whether this client can supply a boss
  -- portrait at all is unsettled (Journal.EncounterPortrait asks; /la journal
  -- reports). A strip of blank squares reads as "the addon is broken" — Build
  -- Barn taught this the expensive way when a new tier shipped without art — so
  -- an unanswered portrait draws a filled tile carrying the boss's initial.
  tile.fallback = tile:CreateTexture(nil, "BACKGROUND")
  tile.fallback:SetAllPoints()
  if S then
    tile.fallback:SetColorTexture(S.COLOR.elevated.r, S.COLOR.elevated.g, S.COLOR.elevated.b, 1)
  end
  tile.initial = text(tile, "titleMed", "head", "textDim", "CENTER")
  tile.initial:SetPoint("CENTER")

  -- ⚠️ OUTSIDE THE TILE, NOT ON IT (Jason, Session 251). Anchored BOTTOMLEFT/
  -- BOTTOMRIGHT of the tile, the bar sat in the tile's own bottom 4px and painted
  -- over the art — on a 32px tile that is an eighth of the picture, and it read
  -- as the selection eating the icon. Anchoring its TOP to the tile's BOTTOM puts
  -- it entirely below, which is what the design draws.
  tile.sel = tile:CreateTexture(nil, "OVERLAY")
  tile.sel:SetPoint("TOPLEFT", tile, "BOTTOMLEFT", 0, 0)
  tile.sel:SetPoint("TOPRIGHT", tile, "BOTTOMRIGHT", 0, 0)
  tile.sel:SetHeight(SEL_H)
  if S then tile.sel:SetColorTexture(S.rgb(S.COLOR.orange)) end
  tile.sel:Hide()

  tile:SetScript("OnClick", function(self)
    if not self.bossIndex then return end
    state.bossIndex = self.bossIndex
    state.sel, state.colScroll, state.rankScroll = 1, 0, 0
    Panel.Refresh()
  end)
  tile:SetScript("OnEnter", function(self)
    if not self.bossName then return end
    ns.Tip:SetOwner(self, "ANCHOR_BOTTOM")
    ns.Tip:SetText(self.bossName, 1, 1, 1)
    if (self.bossBis or 0) > 0 then
      ns.Tip:AddLine(("%d best-in-slot for you here"):format(self.bossBis), 1, 0.957, 0.408)
    end
    ns.Tip:Show()
  end)
  tile:SetScript("OnLeave", function() ns.Tip:Hide() end)
  return tile
end

--- One row of the ranked raider table in the detail pane.
---
--- Rows are RECYCLED across the Loot ranking, Standings, the personal card, the
--- Runner report and the target browser, each writing only the fields it cares
--- about. EVERY fontstring key is recorded so resetRow() can blank them all
--- without a hand-maintained list — a field added in one view that four others
--- did not know to clear is exactly how a quality tag ended up printed through
--- the middle of the Me tab's sentences.
local function buildRankRow(parent, i)
  local row = CreateFrame("Button", nil, parent)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetHeight(RANK_PITCH)
  row:SetPoint("TOPLEFT", 0, -(i - 1) * RANK_PITCH)
  row:SetPoint("TOPRIGHT", 0, -(i - 1) * RANK_PITCH)

  local S = ns.Style
  row.hl = row:CreateTexture(nil, "BACKGROUND")
  row.hl:SetAllPoints()
  if S then
    row.hl:SetColorTexture(S.COLOR.purple.r, S.COLOR.purple.g, S.COLOR.purple.b, 0.22)
  else
    row.hl:SetColorTexture(1, 1, 1, 0.07)
  end
  row.hl:Hide()

  row.TEXT_KEYS = { "rank", "name", "upgrade", "gap", "gain", "pr", "src" }

  -- Positions are relative to the ROW, which is anchored at the pane's left, so
  -- the mock's absolute x values are offset by the rank column's own origin.
  local o = C_RANK
  row.rank    = at(text(row, "label", "small", "text"), C_RANK - o, 1, 12, "LEFT")
  -- ⚠️ REGULAR WEIGHT, NOT "label" (Jason, Session 252). The name and the verdict
  -- are the two longest strings on a dense row, and Semibold on both made every
  -- row read as emphasised — which is the same as none of it being emphasised.
  -- The rank number keeps its weight: it is one or two characters doing the work
  -- of a column header, and it is what the eye scans down.
  row.name    = at(text(row, "body", "small", "text"), C_NAME - o, 1, 100)
  row.upgrade = at(text(row, "body", "small", "text"), C_UPGRADE - o, 1, 118)
  row.gain    = atRight(text(row, "body", "small", "text"), C_GAIN_R - o, 1, 44)
  row.pr      = atRight(text(row, "body", "small", "text"), C_PRIORITY_R - o, 1, 48)
  -- Gear provenance, in the space between GAIN and PRIORITY. Blank is the common
  -- case and that is deliberate: almost every row is scored from the site
  -- snapshot, so tagging all twenty turns the signal into wallpaper. What is
  -- worth marking is the rows BETTER than the snapshot.
  row.src     = at(text(row, "body", "tiny", "textDim"), C_GAIN_R - o + 6, 2, 36)

  -- The browse view reuses these rows for ITEMS, which need an icon the ranking
  -- rows have no use for. Created once and hidden rather than built per refresh:
  -- rows are recycled, and a texture created on every draw leaks.
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(12, 12)
  row.icon:SetPoint("TOPLEFT", 0, -2)
  row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  row.icon:Hide()

  -- ── The UPGRADE cell's own hover target ───────────────────────────────────
  -- ⚠️ THIS SITS ON THE SCORE, NOT ON THE GAIN, AND THAT WAS A CORRECTION.
  -- It was built on the GAIN column first, which was the wrong column: GAIN is
  -- a subtraction anyone can do once they know the two item levels, while the
  -- number beside the badge is a GAP IN SCORE — a different unit entirely,
  -- sitting one column over. That collision is what actually confuses people:
  -- Jason read a "-12" beside a +35 and a +19 and reasonably asked why the
  -- difference was not 16. It is not item levels at all.
  --
  -- So the breakdown belongs HERE, where the number it explains is.
  --
  -- A separate frame rather than the row's tooltip: the row already explains
  -- the provenance marker and the spec-split marker, and folding a third
  -- explanation into one popup means you get all three wherever you point.
  --
  -- ⚠️ IT MUST RE-SHOW THE ROW HIGHLIGHT. A mouse-enabled child takes the hover,
  -- so the row's OnLeave fires as the pointer crosses into this — leaving the
  -- highlight off while the pointer is still visibly on the row.
  row.scoreHit = CreateFrame("Frame", nil, row)
  row.scoreHit:SetPoint("TOPLEFT", row.upgrade, "TOPLEFT", 0, 3)
  row.scoreHit:SetPoint("BOTTOMRIGHT", row.upgrade, "BOTTOMRIGHT", 0, -3)
  row.scoreHit:EnableMouse(true)
  row.scoreHit:SetScript("OnEnter", function(self)
    local r = row.scoreInfo
    row.hl:Show()
    if not r then return end
    ns.Tip:SetOwner(self, "ANCHOR_RIGHT")
    ns.Tip:AddLine("How this score was reached", 1, 1, 1)

    if not r.factors then
      -- ⚠️ SAY WHY, RATHER THAN SHOW A BLANK. A ranking from the runner carries
      -- the badge and the gap but NOT the arithmetic behind them — everyone
      -- displays the runner's numbers by rule, and the factors were never on
      -- the wire.
      ns.Tip:AddLine(" ")
      ns.Tip:AddLine(
        "The breakdown is not available: this ranking came from the loot runner, "
        .. "which sends each raider's result but not the factors behind it.",
        0.6, 0.6, 0.7, true)
      ns.Tip:Show()
      return
    end

    local f = r.factors
    ns.Tip:AddLine(" ")
    -- ⚠️ THE ITEM-LEVEL FACTOR CAPS, and the cap is the whole reason a big GAIN
    -- can sit beside a small score gap. Saying so is the point of the line.
    local ilvlLine = ("%d"):format(f.ilvl_delta or 0)
    if (f.ilvl_delta or 0) >= 40 then ilvlLine = ilvlLine .. "  (max)" end
    ns.Tip:AddDoubleLine(("Item level  (+%d)"):format(r.gain or 0), ilvlLine,
      0.6, 0.6, 0.7, 1, 1, 1)
    ns.Tip:AddDoubleLine("Track gap", ("%d"):format(f.track_gap or 0),
      0.6, 0.6, 0.7, 1, 1, 1)
    -- ⚠️ ONE QUALITY AXIS. A grade or a BIS listing REPLACES stat alignment
    -- rather than adding to it, so the row is labelled by whichever actually
    -- applied — printing both would imply they were summed, which is the exact
    -- misreading the scoring rule exists to prevent.
    ns.Tip:AddDoubleLine(
      f.is_ranked_override and "Best-in-slot / grade" or "Stat alignment",
      ("%d"):format(f.stat_alignment or 0), 0.6, 0.6, 0.7, 1, 1, 1)
    if (f.tier_bonus or 0) > 0 then
      ns.Tip:AddDoubleLine("Tier set", ("%d"):format(f.tier_bonus),
        0.6, 0.6, 0.7, 1, 1, 1)
    end
    ns.Tip:AddDoubleLine("Total", ("%d"):format(r.score or 0),
      0.953, 0.773, 0.420, 0.953, 0.773, 0.420)

    if r.gap and r.gap > 0 then
      ns.Tip:AddLine(" ")
      ns.Tip:AddLine(
        ("%d behind %s, who leads this item."):format(r.gap, r.leader or "the top row"),
        0.6, 0.6, 0.7, true)
    end
    ns.Tip:Show()
  end)
  row.scoreHit:SetScript("OnLeave", function()
    row.hl:Hide()
    ns.Tip:Hide()
  end)

  row:SetScript("OnClick", function(self, button)
    if not self.itemID then return end
    if button == "RightButton" then toggleTarget(self.itemID, self.meta) end
  end)
  row:SetScript("OnEnter", function(self)
    self.hl:Show()
    -- A ranking row is a RAIDER and carries no itemID, so it never had a tooltip
    -- at all. The provenance marker is four characters wide, which is nowhere
    -- near enough to explain itself — the sentence lives here.
    if not self.itemID then
      if self.srcHelp or self.splitHelp then
        ns.Tip:SetOwner(self, "ANCHOR_RIGHT")
        if self.srcHelp then
          ns.Tip:AddLine(self.srcName or "", 1, 1, 1)
          ns.Tip:AddLine(self.srcHelp, 0.6, 0.6, 0.7, true)
        end
        if self.splitHelp then
          if self.srcHelp then ns.Tip:AddLine(" ") end
          ns.Tip:AddLine(self.splitName or "", 0.953, 0.773, 0.420)
          ns.Tip:AddLine(self.splitHelp, 0.6, 0.6, 0.7, true)
        end
        ns.Tip:Show()
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

--- One row of the Standings table.
local function buildStandingsRow(parent, i)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(ST_PITCH)
  row:SetPoint("TOPLEFT", 0, -(i - 1) * ST_PITCH)
  row:SetPoint("TOPRIGHT", 0, -(i - 1) * ST_PITCH)

  local S = ns.Style
  row.hl = row:CreateTexture(nil, "BACKGROUND")
  row.hl:SetAllPoints()
  if S then
    row.hl:SetColorTexture(S.COLOR.purple.r, S.COLOR.purple.g, S.COLOR.purple.b, 0.22)
  end
  row.hl:Hide()

  -- Positions are relative to the row, which starts at the rank column's left.
  local o = ST_RANK_R - 24
  row.rank = atRight(text(row, "label", "small", "text"), ST_RANK_R - o, 1, 24)
  -- Regular weight, matching the ranking table — see the note in buildRankRow.
  row.name = at(text(row, "body", "small", "text"), ST_NAME - o, 1, 110)
  row.ep   = atRight(text(row, "body", "small", "text"), ST_EP_R - o, 1, 60)
  row.gp   = atRight(text(row, "body", "small", "text"), ST_GP_R - o, 1, 50)
  row.pr   = atRight(text(row, "body", "small", "text"), ST_PR_R - o, 1, 50)
  row.last = atRight(text(row, "body", "small", "text"), ST_LAST_R - o, 1, 60)
  return row
end

--- One block of the personal rail: a purple heading, a large figure, and a line
--- of context beneath it. Three fontstrings so each can take its own type role;
--- the design gives the heading, the figure and the caption three different
--- faces and sizes.
--- `compact` = this block has NO big figure, so its lines start directly under
--- the heading.
---
--- ⚠️ EVERY BLOCK USED THE SAME OFFSETS AND TWO OF THEM HAVE NO FIGURE
--- (Session 253). Earned/Spent and Last Item Won reserved the 34px slot where
--- Priority's "#3" and Attendance's "3/4" sit, so their text hung a full
--- figure's height below its own heading with nothing in between — a gap
--- Jason marked on both blocks against the Figma frame, where the value sits
--- immediately under its label.
local function buildRailBlock(parent, y, compact)
  local b = {}
  b.head = at(text(parent, "titleMed", "head", "railHead"), RAIL_X, y, 130)
  if ns.Style then ns.Style.SetFont(b.head, ns.Style.FONT.titleMed, 16) end
  b.big = at(text(parent, "titleMed", "title", "orange"), RAIL_X, y + 18, 130)
  if ns.Style then ns.Style.SetFont(b.big, ns.Style.FONT.titleMed, 34) end
  -- Sits on the big figure's baseline, for the "/3" in "2/3".
  b.bigSuffix = at(text(parent, "title", "title", "text"), RAIL_X, y + 26, 130)
  if ns.Style then ns.Style.SetFont(b.bigSuffix, ns.Style.FONT.title, 21) end
  -- 20 clears the 16px heading with a hair of breathing room; 54 clears the
  -- heading AND the 34px figure. Line pitch is 16 either way.
  local lineY = compact and 20 or 54
  b.line1 = at(text(parent, "body", "row", "text"), RAIL_X, y + lineY, 130)
  b.line2 = at(text(parent, "body", "row", "text"), RAIL_X, y + lineY + 16, 130)
  b.line3 = at(text(parent, "body", "row", "textMuted"), RAIL_X, y + lineY + 32, 130)
  return b
end

--- Blank every fontstring on a recycled row.
local function resetRow(row)
  if not row or not row.TEXT_KEYS then return end
  for _, key in ipairs(row.TEXT_KEYS) do
    local fsObj = row[key]
    if fsObj and fsObj.SetText then fsObj:SetText("") end
  end
  -- Rows are RECYCLED, so a stale breakdown would explain the previous
  -- occupant's number under the new one — the same trap the TEXT_KEYS sweep
  -- above exists for.
  row.scoreInfo = nil
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function buildChrome()
  -- ⚠️ NO BLIZZARD TEMPLATE. This was BasicFrameTemplateWithInset, and the inset
  -- border kept drawing however many of its regions Style.Window took off — a
  -- second rim around the content that survived three attempts to hide it.
  -- The template was only ever supplying a close button and a title, both of
  -- which are a few lines here, while the artwork it also supplies is artwork
  -- this design spends effort removing. Dragging was already hand-wired below.
  -- A plain frame ends the whole category of "some hidden region is still
  -- painting" rather than hiding one more of them.
  frame = CreateFrame("Frame", "HoDLootAdvisorPanel", UIParent)
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

  -- The design's ground: a near-black fill, a warm wash rising from the bottom
  -- edge, and one light hairline.
  if ns.Style then ns.Style.PanelGround(frame, FRAME_H) end

  -- ⚠️ THE HEADER IS ONE IMAGE, CREST AND WORDMARK TOGETHER (Jason's export,
  -- 223x30, which is exactly the crest's 88px plus the wordmark out to x=239 in
  -- the design). This also settles the one thing the panel could not match: the
  -- wordmark is painted with the site's brand GRADIENT, and a WoW fontstring
  -- takes a colour and nothing else — no SetGradient, no way to clip a gradient
  -- to glyph shapes. Drawn from the design file, the gradient is simply real.
  frame.logo = frame:CreateTexture(nil, "ARTWORK")
  frame.logo:SetSize(223, 30)
  frame.logo:SetPoint("TOPLEFT", 16, -14)
  frame.logo:SetTexture("Interface\\AddOns\\HoDLootAdvisor\\Media\\hodlogotitle.png")

  -- The close button the template used to supply.
  frame.close = CreateFrame("Button", nil, frame)
  frame.close._hodStyled = true
  frame.close:SetSize(20, 20)
  frame.close:SetPoint("TOPRIGHT", -8, -8)
  frame.close.x = text(frame.close, "label", "small", "textDim", "CENTER")
  frame.close.x:SetPoint("CENTER")
  frame.close.x:SetText("X")
  frame.close:SetScript("OnClick", function() frame:Hide() end)
  frame.close:SetScript("OnEnter", function(s)
    if ns.Style then s.x:SetTextColor(ns.Style.rgb(ns.Style.COLOR.orange)) end
  end)
  frame.close:SetScript("OnLeave", function(s)
    if ns.Style then s.x:SetTextColor(ns.Style.rgb(ns.Style.COLOR.textDim)) end
  end)

  -- ── Tabs ──────────────────────────────────────────────────────────────────
  frame.tabs = {}
  for i, name in ipairs(TABS) do
    -- Tabs carry the design's larger label (16); the filter toggles and footer
    -- buttons stay at 13. Same control, two type sizes, exactly as drawn.
    local b = ns.Style and ns.Style.Pill(frame, TAB_W, TAB_H, name, "title")
      or CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetPoint("TOPLEFT", PAD + (i - 1) * TAB_PITCH, -TAB_Y)
    b:SetScript("OnClick", function()
      state.tab = name
      state.rankScroll, state.colScroll = 0, 0
      Panel.Refresh()
    end)
    frame.tabs[name] = b
  end

end

local function buildLootControls()
  -- ── Difficulty, on the tab row's right ────────────────────────────────────
  -- Which difficulty's item levels EVERYTHING is scored against. It was a
  -- cycling button on the old panel, dropped in the rebuild because no design
  -- had it yet; Jason has since drawn it as a dropdown at x=500 on the tab row.
  --
  -- AUTO follows the raid you are standing in, which is right on a raid night
  -- and useless in a city — hence the override. Without this control on screen
  -- there was no way to tell WHICH difficulty a loot table was being shown for,
  -- which is the complaint that brought it back.
  frame.diff = ns.Style and ns.Style.Pill(frame, DIFF_W, DIFF_H, "")
    or CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.diff:SetPoint("TOPLEFT", DIFF_X, -DIFF_Y)
  if frame.diff.SetPillState then frame.diff:SetPillState(true) end
  -- ORANGE, per the mock. It was built purple like every other pill on the row,
  -- but the tabs and filter toggles are VIEWS and this one selects CONTENT —
  -- which is the distinction the colour is drawing.
  if frame.diff.SetPillColor and ns.Style then
    frame.diff:SetPillColor(ns.Style.COLOR.darkOrange)
  end

  -- ── Vault / Voidcore toggle, left of the difficulty control ───────────────
  -- Shows the item level each piece becomes in the WEEKLY CHEST rather than the
  -- one the boss drops — a full track higher in Season 2, so a Heroic kill is
  -- worth a Myth 1/6 vault slot. That is the number that decides whether a
  -- Heroic clear is worth doing, and it lived nowhere in the addon.
  --
  -- ⚠️ ONE TOGGLE, TWO ROUTES TO THE SAME LEVEL. A Nebulous Voidcore bonus roll
  -- pays out at the equivalent Great Vault level for that content, so coining a
  -- Heroic boss returns Myth track exactly as a Heroic vault slot does. The
  -- label says both because the number is the same one — not because the toggle
  -- does two things. See the setting's note in Settings.lua for the source.
  --
  -- ⚠️ ONLY WITH AN EXPLICIT CONTENT CHOICE. On AUTO the panel is following
  -- whatever instance you are standing in, and "the vault level of whatever this
  -- is" is a claim with no stated subject. Pick a difficulty and it appears.
  --
  -- ⚠️ AND ONLY IF THE PAYLOAD KNOWS THE LEVELS. An older payload carries no
  -- vault table; the control stays hidden rather than showing a computed guess,
  -- exactly as the GP price shows nothing without its constants.
  frame.vault = ns.Style and ns.Style.Check(frame, "Vault/Voidcore", 14)
  if frame.vault then
    frame.vault:SetPoint("TOPRIGHT", frame.diff, "TOPLEFT", -VAULT_GAP, -3)
    frame.vault:SetChecked(ns.VaultOn())
    frame.vault:SetScript("OnClick", function(self)
      self:SetChecked(not self:GetChecked())
      if ns.Settings then
        ns.Settings.Set("vault", self:GetChecked() and "on" or "off")
      end
      state.sel, state.colScroll, state.rankScroll = 1, 0, 0
      Panel.Refresh()
    end)
  end

  -- The caret. A dropdown that looks like a button gets clicked once and
  -- abandoned; the design draws the affordance, so it is drawn.
  frame.diffCaret = frame.diff:CreateTexture(nil, "OVERLAY")
  -- 11x11: the design node's own size. The art is drawn into that cell with the
  -- triangle occupying its lower three-quarters, exactly as Figma places it, so
  -- the padding is the design's rather than something added here.
  frame.diffCaret:SetSize(11, 11)
  frame.diffCaret:SetPoint("RIGHT", -8, -1)
  -- The design's own caret, pointing DOWN as a dropdown affordance should. It was
  -- Blizzard's ChatFrameExpandArrow, which points RIGHT — it reads as "expand
  -- sideways", and it is not the shape in the mock.
  frame.diffCaret:SetTexture("Interface\\AddOns\\HoDLootAdvisor\\Media\\ui\\caret.png")
  if ns.Style then frame.diffCaret:SetVertexColor(ns.Style.rgb(ns.Style.COLOR.white)) end

  frame.diffMenu = CreateFrame("Frame", nil, frame)
  -- TOOLTIP strata so nothing the panel draws can land over the open list.
  frame.diffMenu:SetFrameStrata("TOOLTIP")
  frame.diffMenu:SetPoint("TOPLEFT", frame.diff, "BOTTOMLEFT", 0, -2)
  -- Sized from the CHOICE LIST, not a literal: adding Dungeons to a menu whose
  -- height said "4" clipped the new row off the bottom with nothing erroring.
  frame.diffMenu:SetSize(DIFF_W, 4 + #DIFF_CHOICES * 20)
  frame.diffMenu:EnableMouse(true)
  frame.diffMenu:Hide()
  if ns.Style then ns.Style.Surface(frame.diffMenu, ns.Style.COLOR.elevated, 0.98) end

  -- ⚠️ NO FULL-SCREEN CLICK-CATCHER. The old dropdown had one for
  -- click-outside-to-close and it silently ate every selection: only ONE frame
  -- receives a click and a screen-covering button takes it. This closes on a
  -- pick, on re-clicking its own button, and when the tab changes.
  frame.diffItems = {}
  for i, choice in ipairs(DIFF_CHOICES) do
    local b = CreateFrame("Button", nil, frame.diffMenu)
    b._hodStyled = true
    b:SetSize(DIFF_W - 2, 20)
    b:SetPoint("TOPLEFT", 1, -((i - 1) * 20) - 2)
    b.hl = b:CreateTexture(nil, "BACKGROUND")
    b.hl:SetAllPoints()
    if ns.Style then b.hl:SetColorTexture(ns.Style.rgb(ns.Style.COLOR.purple)) end
    b.hl:Hide()
    b.label = at(text(b, "titleMed", "head", "text"), 8, 2, DIFF_W - 16)
    b.label:SetText(DIFF_LABEL[choice] or choice)
    b:SetScript("OnEnter", function(s) s.hl:Show() end)
    b:SetScript("OnLeave", function(s) s.hl:Hide() end)
    b:SetScript("OnClick", function()
      frame.diffMenu:Hide()
      if ns.Settings then ns.Settings.Set("difficulty", choice) end
      state.sel, state.colScroll, state.rankScroll = 1, 0, 0
      Panel.Refresh()
    end)
    frame.diffItems[i] = b
  end

  frame.diff:SetScript("OnClick", function()
    if frame.diffMenu:IsShown() then frame.diffMenu:Hide()
    else frame.diffMenu:Show(); frame.diffMenu:Raise() end
  end)
  -- ⚠️ NO TOOLTIP ON THIS CONTROL, deliberately (Jason, Session 251). It
  -- anchored BELOW the button, which is exactly where the menu opens — so
  -- hovering to click covered the very list you were reaching for. A tooltip
  -- that hides the thing it describes is worse than none, and this control does
  -- not need explaining: every entry names itself.

  -- ── Boss context, left of the strip ───────────────────────────────────────
  frame.bossName = at(text(frame, "label", "head", "orange"), 21, CTX_Y, 200)
  frame.bossSub  = at(text(frame, "body", "small", "text"), 21, CTX_Y + 18, 200)

  -- ── Boss strip ────────────────────────────────────────────────────────────
  -- Right-aligned to the window margin, so a raid with fewer bosses than slots
  -- keeps the last tile against the same edge instead of leaving a ragged gap
  -- under the header.
  frame.strip = CreateFrame("Frame", nil, frame)
  frame.strip:SetSize(BOSS_SLOTS * BOSS_PITCH - (BOSS_PITCH - BOSS_SIZE), BOSS_SIZE)
  frame.strip:SetPoint("TOPRIGHT", -PAD, -BOSS_Y)
  frame.bossTiles = {}
  for i = 1, BOSS_SLOTS do
    frame.bossTiles[i] = buildBossTile(frame.strip, i)
    frame.bossTiles[i]:Hide()
  end
  frame.stripMore = at(text(frame, "body", "tiny", "textDim"), 0,
    BOSS_Y + BOSS_SIZE + SEL_H + 2, 200, "RIGHT")
  frame.stripMore:ClearAllPoints()
  frame.stripMore:SetPoint("TOPRIGHT", -PAD, -(BOSS_Y + BOSS_SIZE + SEL_H + 2))

  -- ── The two filter toggles ────────────────────────────────────────────────
  local function toggle(col, rowIdx, label, onClick)
    local b = ns.Style and ns.Style.Pill(frame, TOG_W, TOG_H, label)
      or CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetPoint("TOPLEFT", TOG_X + col * TOG_COL, -(TOG_Y + rowIdx * TOG_ROW))
    -- A filter that is not selected is still a choice on offer, so its label
    -- stays readable while its fill recedes. Only the TABS dim their text.
    b._dimText = false
    b:SetScript("OnClick", onClick)
    return b
  end
  local function pickSource(which)
    return function()
      state.source = which
      state.sel, state.colScroll, state.rankScroll = 1, 0, 0
      Panel.Refresh()
    end
  end
  local function pickFilter(which)
    return function()
      state.filter = which
      state.sel, state.colScroll, state.rankScroll = 1, 0, 0
      Panel.Refresh()
    end
  end
  frame.togDrops  = toggle(0, 0, "Current Drops",  pickSource("drops"))
  frame.togTable  = toggle(1, 0, "Full Loot Table", pickSource("table"))
  frame.togUsable = toggle(0, 1, "Usable Only",    pickFilter("usable"))
  frame.togAll    = toggle(1, 1, "All Loot",       pickFilter("all"))

  frame.togUsable:SetScript("OnEnter", function(self)
    ns.Tip:SetOwner(self, "ANCHOR_RIGHT")
    ns.Tip:SetText("Usable Only", 1, 1, 1)
    ns.Tip:AddLine("Hides items your class cannot equip.", 0.8, 0.8, 0.8, true)
    ns.Tip:AddLine("Anything you have targeted stays visible either way — "
      .. "hiding something you asked for is worse than showing one you cannot use.",
      0.6, 0.6, 0.7, true)
    ns.Tip:Show()
  end)
  frame.togUsable:SetScript("OnLeave", function() ns.Tip:Hide() end)

  -- ── The item column ───────────────────────────────────────────────────────
  frame.col = CreateFrame("Frame", nil, frame)
  frame.col:SetPoint("TOPLEFT", COL_X, -COL_TOP)
  frame.col:SetSize(COL_W, COL_ROWS * ITEM_PITCH)
  frame.col:EnableMouseWheel(true)
  frame.col:SetScript("OnMouseWheel", function(_, delta) Panel.ScrollColumn(-delta) end)
  frame.itemRows = {}
  for i = 1, COL_ROWS do
    frame.itemRows[i] = buildItemRow(frame.col, i)
    frame.itemRows[i]:Hide()
  end
  frame.colEmpty = at(text(frame, "body", "small", "textDim"), COL_X + 12, COL_TOP + 12, COL_W - 24)
  frame.colMore = at(text(frame, "body", "tiny", "textDim"),
    COL_X, COL_TOP + COL_ROWS * ITEM_PITCH + 2, COL_W)

end

--- The Runner tab's furniture, built once. Rendering fills it in.
---
--- Every fact it shows comes from Comms.RunnerReport(); this builds the widgets
--- and nothing else. See the note on that function for why the data lives there.
local function buildRunnerTab()
  local R = {}
  frame.rn = R

  -- ── Left rail: state, and the two controls that change it ─────────────────
  R.status = at(text(frame, "title", "title", "green"), RN_RAIL_X, RN_STATUS_Y, RN_RAIL_W)
  R.status:SetWordWrap(true)
  R.since  = at(text(frame, "body", "small", "textDim"), RN_RAIL_X, RN_SINCE_Y, RN_RAIL_W)

  R.dataHead = at(text(frame, "label", "tiny", "railHead"), RN_RAIL_X, RN_DATA_Y, RN_RAIL_W)
  R.dataHead:SetText("TONIGHT'S DATA")
  R.raiders  = at(text(frame, "titleMed", "title", "text"), RN_RAIL_X, RN_RAIDERS_Y, RN_RAIL_W)
  R.ranked   = at(text(frame, "titleMed", "title", "text"), RN_RAIL_X, RN_RANKED_Y, RN_RAIL_W)
  R.imported = at(text(frame, "body", "tiny", "textMuted"), RN_RAIL_X, RN_IMPORTED_Y, RN_RAIL_W)
  R.synced   = at(text(frame, "body", "tiny", "textMuted"), RN_RAIL_X, RN_SYNCED_Y, RN_RAIL_W)

  -- ── The hairline between rail and column ──────────────────────────────────
  R.div = frame:CreateTexture(nil, "ARTWORK")
  R.div:SetSize(1, RN_DIV_H)
  R.div:SetPoint("TOPLEFT", RN_DIV_X, -RN_DIV_Y)
  if ns.Style then
    R.div:SetColorTexture(ns.Style.COLOR.rim.r, ns.Style.COLOR.rim.g,
      ns.Style.COLOR.rim.b, 0.25)
  end

  -- ── Right column ──────────────────────────────────────────────────────────
  R.lead    = at(text(frame, "bodyMed", "small", "green"), RN_COL_X, RN_LEAD_Y, RN_COL_W)
  R.leadSub = at(text(frame, "body", "small", "mutedGrey"), RN_COL_X, RN_LEAD_SUB_Y, RN_LEAD_SUB_W)
  R.leadSub:SetWordWrap(true)

  local function hairline(y)
    local t = frame:CreateTexture(nil, "ARTWORK")
    t:SetSize(RN_COL_W, 1)
    t:SetPoint("TOPLEFT", RN_COL_X - 1, -y)
    if ns.Style then
      t:SetColorTexture(ns.Style.COLOR.rim.r, ns.Style.COLOR.rim.g,
        ns.Style.COLOR.rim.b, 0.25)
    end
    return t
  end
  R.d1, R.d2, R.d3 = hairline(RN_D1_Y), hairline(RN_D2_Y), hairline(RN_D3_Y)

  R.peersHead = at(text(frame, "body", "small", "text"), RN_COL_X, RN_PEERS_Y, RN_COL_W)
  R.peers = {}
  for i = 1, RN_PEER_ROWS do
    local y = RN_PEER_TOP + (i - 1) * RN_PEER_PITCH
    R.peers[i] = {
      name = at(text(frame, "body", "small", "text"),
                RN_COL_X + RN_PEER_NAME_X, y, RN_PEER_VER_X - 4),
      ver  = at(text(frame, "body", "small", "textDim"),
                RN_COL_X + RN_PEER_VER_X, y, RN_PEER_GEAR_X - RN_PEER_VER_X - 4),
      gear = at(text(frame, "body", "small", "textDim"),
                RN_COL_X + RN_PEER_GEAR_X, y, 120),
    }
  end

  R.missHead = at(text(frame, "body", "small", "darkOrange"), RN_COL_X, RN_MISS_Y, RN_COL_W)
  R.missBody = at(text(frame, "body", "small", "mutedGrey"), RN_COL_X, RN_MISS_BODY_Y, RN_COL_W)
  R.missBody:SetWordWrap(true)

  R.specHead = at(text(frame, "body", "small", "text"), RN_COL_X, RN_SPEC_Y, RN_COL_W)
  R.specBody = at(text(frame, "body", "small", "mutedGrey"), RN_COL_X, RN_SPEC_BODY_Y, RN_COL_W)
  R.specBody:SetWordWrap(true)

  -- Everything above is hidden until the tab is on screen.
  R.all = { R.status, R.since, R.dataHead, R.raiders, R.ranked, R.imported,
            R.synced, R.lead, R.leadSub, R.peersHead, R.missHead, R.missBody,
            R.specHead, R.specBody, R.div, R.d1, R.d2, R.d3 }
  for _, p in ipairs(R.peers) do
    R.all[#R.all + 1] = p.name; R.all[#R.all + 1] = p.ver; R.all[#R.all + 1] = p.gear
  end
  for _, w in ipairs(R.all) do w:Hide() end
end

local function buildStandingsTab()
  -- ── Standings tab ─────────────────────────────────────────────────────────
  -- The season, on the tab row's right. Only this tab shows it: the Loot design
  -- leaves that space empty, and a label that appears on one tab and not another
  -- is the design's choice to make, not this file's.
  frame.season = text(frame, "titleMed", "title", "orange", "RIGHT")
  if ns.Style then ns.Style.SetFont(frame.season, ns.Style.FONT.titleMed, 16) end
  frame.season:SetPoint("TOPRIGHT", -(FRAME_W - SEASON_R), -62)
  frame.season:SetWidth(220)

  frame.rail = {}
  for i, y in ipairs(RAIL_BLOCK_Y) do
    frame.rail[i] = buildRailBlock(frame, y, RAIL_BLOCK_COMPACT[i])
  end

  frame.stDiv = frame:CreateTexture(nil, "ARTWORK")
  frame.stDiv:SetSize(1, ST_DIV_H)
  frame.stDiv:SetPoint("TOPLEFT", ST_DIV_X, -ST_DIV_Y)
  if ns.Style then
    frame.stDiv:SetColorTexture(ns.Style.COLOR.rim.r, ns.Style.COLOR.rim.g,
      ns.Style.COLOR.rim.b, 0.25)
  end

  frame.stHead = {
    at(text(frame, "label", "tiny", "text"), ST_NAME, ST_HEAD_Y, 80),
    atRight(text(frame, "label", "tiny", "text"), ST_EP_R, ST_HEAD_Y, 40),
    atRight(text(frame, "label", "tiny", "text"), ST_GP_R, ST_HEAD_Y, 40),
    atRight(text(frame, "label", "tiny", "text"), ST_PR_R, ST_HEAD_Y, 60),
    atRight(text(frame, "label", "tiny", "text"), ST_LAST_R, ST_HEAD_Y, 60),
  }
  frame.stHead[1]:SetText("RAIDER")
  frame.stHead[2]:SetText("EP")
  frame.stHead[3]:SetText("GP")
  frame.stHead[4]:SetText("PRIORITY")
  frame.stHead[5]:SetText("LAST ITEM")

  frame.stList = CreateFrame("Frame", nil, frame)
  frame.stList:SetPoint("TOPLEFT", ST_RANK_R - 24, -ST_TOP)
  frame.stList:SetSize(ST_LAST_R - (ST_RANK_R - 24), ST_ROWS * ST_PITCH)
  frame.stList:EnableMouseWheel(true)
  frame.stList:SetScript("OnMouseWheel", function(_, delta) Panel.Scroll(-delta) end)
  frame.stRows = {}
  for i = 1, ST_ROWS do
    frame.stRows[i] = buildStandingsRow(frame.stList, i)
    frame.stRows[i]:Hide()
  end

  frame.stNote = at(text(frame, "body", "small", "textDim"), ST_NAME, ST_TOP + 8, 340)
  frame.stNote:SetWordWrap(true)

end

local function buildDetailPane()
  -- ── The detail pane ───────────────────────────────────────────────────────
  frame.pane = CreateFrame("Frame", nil, frame)
  frame.pane:SetPoint("TOPLEFT", PANE_X, -PANE_Y)
  frame.pane:SetSize(PANE_W, PANE_H)
  if ns.Style then
    local S = ns.Style
    frame.paneBg = frame.pane:CreateTexture(nil, "BACKGROUND")
    frame.paneBg:SetAllPoints()
    frame.paneBg:SetColorTexture(S.COLOR.purple.r, S.COLOR.purple.g, S.COLOR.purple.b, 0.2)
  end

  -- Header block 1: how big an upgrade this is for the viewer.
  frame.hUpgradeLabel = at(text(frame, "titleMed", "row", "text"), 236, HEAD_Y, 130)
  frame.hUpgradeLabel:SetText("Upgrade for You:")
  frame.hUpgrade = at(text(frame, "title", "title", "major"), 236, HEAD_Y + 13, 140)
  if ns.Style then ns.Style.SetFont(frame.hUpgrade, ns.Style.FONT.title, 24) end

  -- Header block 2: where the viewer sits on the global ladder.
  frame.hStandLabel = at(text(frame, "titleMed", "row", "text"), 379, HEAD_Y, 110)
  frame.hStandLabel:SetText("Your Standing:")
  frame.hStand = at(text(frame, "title", "title", "orange"), 379, HEAD_Y + 13, 110)
  if ns.Style then ns.Style.SetFont(frame.hStand, ns.Style.FONT.title, 24) end

  -- Header block 3: the raw EPGP numbers behind it.
  frame.hEpgp = at(text(frame, "body", "tiny", "text"), 500, HEAD_Y + 2, 92)
  frame.hEpgp:SetWordWrap(true)
  frame.hEpgp:SetHeight(36)
  frame.hEpgp:SetJustifyV("TOP")

  frame.div1 = divider(frame, DIV_X, DIV1_Y, DIV_W)
  frame.facts = at(text(frame, "body", "small", "text"), 236, FACTS_Y, DIV_W - 12)
  frame.div2 = divider(frame, DIV_X, DIV2_Y, DIV_W)

  -- The selected item's identity.
  frame.itemIcon = frame:CreateTexture(nil, "ARTWORK")
  frame.itemIcon:SetSize(ITEM_ICON, ITEM_ICON)
  frame.itemIcon:SetPoint("TOPLEFT", 231, -ITEM_Y)
  frame.itemIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

  frame.itemName = at(text(frame, "label", "head", "text"), 281, ITEM_Y + 3, 200)
  frame.itemSub  = at(text(frame, "body", "small", "textDim"), 281, ITEM_Y + 18, 200)

  -- The item name is the biggest representation of the item on screen, so
  -- hovering it should do what hovering an item anywhere else in the game does.
  frame.itemHover = CreateFrame("Frame", nil, frame)
  frame.itemHover:SetPoint("TOPLEFT", 231, -ITEM_Y)
  frame.itemHover:SetSize(250, ITEM_ICON)
  frame.itemHover:EnableMouse(true)
  frame.itemHover:SetScript("OnEnter", function(self)
    local itemID = Panel.CurrentItemID()
    local link = self.link or (itemID and ns.ItemLinkFor(itemID))
    if not link then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:SetHyperlink(link)
    -- ⚠️ THE TARGETING HINT MOVED HERE WITH THE TOOLTIP. It used to ride on the
    -- item column's tooltip, and nothing else in the panel says a row can be
    -- right-clicked — so dropping that tooltip without moving this line would
    -- have quietly removed the only place targeting is explained.
    if itemID then
      GameTooltip:AddLine(ns.Targets and ns.Targets.Has(itemID)
        and "Right-click a row to stop targeting."
        or "Right-click a row to target it.", 0.6, 0.6, 0.7)
    end
    GameTooltip:Show()
  end)
  frame.itemHover:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.wonDiv = frame:CreateTexture(nil, "ARTWORK")
  frame.wonDiv:SetSize(1, 32)
  frame.wonDiv:SetPoint("TOPLEFT", 485, -245)
  if ns.Style then
    frame.wonDiv:SetColorTexture(ns.Style.COLOR.rim.r, ns.Style.COLOR.rim.g,
      ns.Style.COLOR.rim.b, 0.25)
  end
  frame.wonLabel = at(text(frame, "body", "tiny", "text"), 495, 246, 96)
  frame.wonLabel:SetText("Won By:")
  frame.wonBy = at(text(frame, "label", "tiny", "orange"), 495, 258, 96)

  frame.div3 = divider(frame, DIV_X, DIV3_Y, DIV_W)

  -- The ranked table's column headings.
  frame.head = {}
  frame.head[1] = at(text(frame, "label", "tiny", "text"), C_NAME, RANK_HEAD_Y, 90)
  frame.head[2] = at(text(frame, "label", "tiny", "text"), C_UPGRADE, RANK_HEAD_Y, 110)
  frame.head[3] = atRight(text(frame, "label", "tiny", "text"), C_GAIN_R, RANK_HEAD_Y, 44)
  -- ⚠️ 64, NOT 48 — "PRIORITY" MEASURES 47.3px AND WAS TRUNCATING TO "PRIORI…".
  -- The field had been sized to the string with 0.7px to spare, which is not a
  -- margin: the game's own text measurement differs slightly from the font's
  -- advance widths (kerning, hinting, rounding), so it tipped over. Nothing had
  -- to move — the header is right-aligned at C_PRIORITY_R, so widening it grows
  -- LEFTWARDS into empty space, and the GAIN column's right edge is at
  -- C_GAIN_R (499) against this field's new left edge at 527.
  -- Header widths are now sized with real slack. Measured, not eyeballed:
  -- RAIDER 37.3 / UPGRADE 49.2 / GAIN 25.9 / PRIORITY 47.3 at 10px Semibold.
  frame.head[4] = atRight(text(frame, "label", "tiny", "text"), C_PRIORITY_R, RANK_HEAD_Y, 64)

  frame.list = CreateFrame("Frame", nil, frame)
  frame.list:SetPoint("TOPLEFT", C_RANK, -RANK_TOP)
  frame.list:SetSize(C_PRIORITY_R - C_RANK, RANK_ROWS * RANK_PITCH)
  frame.list:EnableMouseWheel(true)
  frame.list:SetScript("OnMouseWheel", function(_, delta) Panel.Scroll(-delta) end)
  frame.rows = {}
  for i = 1, RANK_ROWS do
    frame.rows[i] = buildRankRow(frame.list, i)
    frame.rows[i]:Hide()
  end

  frame.more = at(text(frame, "body", "tiny", "textDim"), C_RANK, MORE_Y, DIV_W)
  frame.note = at(text(frame, "body", "tiny", "textDim"), C_RANK, NOTE_Y, DIV_W)
  frame.note:SetAlpha(0.5)

end

local function buildFooter()
  -- ── The bottom bar ────────────────────────────────────────────────────────
  -- FIXED, and present on EVERY tab. Import Raid Night in particular cannot move
  -- behind the Runner tab: it is how a non-runner BECOMES the runner, so it
  -- cannot live behind the tab that only appears once you already are one
  -- (Session 249).
  frame.foot = CreateFrame("Frame", nil, frame)
  frame.foot:SetPoint("TOPLEFT", 0, -FOOT_Y)
  frame.foot:SetPoint("TOPRIGHT", 0, -FOOT_Y)
  frame.foot:SetHeight(FOOT_H)
  if ns.Style then
    local S = ns.Style
    local bg = frame.foot:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(S.rgb(S.COLOR.ground))
    S.Rim(frame.foot, S.COLOR.rim, 0.4)
  end

  frame.gearLine1 = at(text(frame.foot, "body", "tiny", "text"), PAD, 13, 200)
  frame.gearLine2 = at(text(frame.foot, "body", "tiny", "text"), PAD, 25, 200)

  local function footButton(w, rightOffset, label, onClick)
    local b = ns.Style and ns.Style.Pill(frame.foot, w, 24, label)
      or CreateFrame("Button", nil, frame.foot, "UIPanelButtonTemplate")
    b:SetPoint("TOPRIGHT", -rightOffset, -13)
    b:SetScript("OnClick", onClick)
    if b.SetPillState then b:SetPillState(true) end
    return b
  end

  frame.cfg = footButton(69, PAD, "Settings", function() ns.Settings.Toggle() end)
  frame.log = footButton(69, PAD + 79, "Loot Log", function()
    if ns.RecordWindow then ns.RecordWindow.Toggle() end
  end)
  frame.load = footButton(114, PAD + 79 + 79, "Import Raid Night", function()
    ns.LoadWindow.Toggle()
  end)

  frame.load:SetScript("OnEnter", function(self)
    ns.Tip:SetOwner(self, "ANCHOR_TOP")
    ns.Tip:SetText("Import Raid Night", 1, 1, 1)
    ns.Tip:AddLine("Paste the export from the Loot Advisor page on the website.", 0.8, 0.8, 0.8, true)
    ns.Tip:AddLine("This is what supplies everyone's gear — the rankings need it.", 0.8, 0.8, 0.8, true)
    ns.Tip:Show()
  end)
  frame.load:SetScript("OnLeave", function() ns.Tip:Hide() end)
  frame.log:SetScript("OnEnter", function(self)
    ns.Tip:SetOwner(self, "ANCHOR_TOP")
    ns.Tip:SetText("Loot Log", 1, 1, 1)
    ns.Tip:AddLine("Every drop and every roll, recorded automatically. Review a night, "
      .. "tag a run Guild or Personal, and export for the website.", 0.8, 0.8, 0.8, true)
    local _, items = ns.Record.Counts()
    ns.Tip:AddLine(("%d item%s recorded."):format(items, items == 1 and "" or "s"), 0.6, 0.6, 0.7)
    ns.Tip:Show()
  end)
  frame.log:SetScript("OnLeave", function() ns.Tip:Hide() end)

end

local function buildTabControls()
  -- ── Per-tab controls, in the pane's bottom-right ──────────────────────────
  -- POST IS RUNNER-ONLY (Session 249): two people posting puts two different
  -- lists in raid chat for one item, and chat is the only thing a non-installer
  -- ever sees. It sits inside the pane rather than in the bottom bar because it
  -- acts on the SELECTED ITEM, and the bar is about the window.
  frame.post = ns.Style and ns.Style.Pill(frame, 69, 22, "Post")
    or CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.post:SetPoint("TOPRIGHT", -PAD, -(NOTE_Y - 4))
  if frame.post.SetPillState then frame.post:SetPillState(true) end
  frame.post:SetScript("OnClick", function()
    local id = Panel.CurrentItemID()
    if id then ns.Loot.PostToChat(id) end
  end)
  frame.post:SetScript("OnEnter", function(self)
    local id = Panel.CurrentItemID()
    if not id then return end
    ns.Tip:SetOwner(self, "ANCHOR_LEFT")
    ns.Tip:SetText("Post to chat", 1, 1, 1)
    for _, line in ipairs(ns.Loot.ChatLines(id)) do
      ns.Tip:AddLine(line, 0.8, 0.8, 0.8, true)
    end
    ns.Tip:Show()
  end)
  frame.post:SetScript("OnLeave", function() ns.Tip:Hide() end)

  frame.runToggle = ns.Style and ns.Style.Pill(frame, 150, 22, "Run Loot Tonight")
    or CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  -- ⚠️ ON THE RAIL NOW, NOT THE PANE'S BOTTOM-RIGHT. The mock puts both runner
  -- controls at the foot of the left rail, under the state they change.
  frame.runToggle:SetSize(RN_BTN_W, RN_BTN_H)
  frame.runToggle:SetPoint("TOPLEFT", RN_BTN_X, -RN_TOGGLE_Y)
  if frame.runToggle.SetPillState then frame.runToggle:SetPillState(true) end
  frame.runToggle:Hide()
  frame.runToggle:SetScript("OnClick", function()
    if not ns.Comms then return end
    -- ⚠️ KEYED ON THE CLAIM, NEVER ON IsRunner(). IsRunner is also true for
    -- someone who merely pasted the data, so keying on it made the button read
    -- "Stop Running Loot" while the panel beside it said "Press Run Loot
    -- Tonight" — and the first press then RELEASED the implicit role.
    if ns.Comms.HasExplicitClaim() then
      ns.Comms.ReleaseRunner()
    else
      ns.Comms.ClaimRunner()
    end
    Panel.Refresh()
  end)

  -- Auto-post lives here as well as in Settings because it is a runner's
  -- decision about tonight, not a preference you set once. Same stored value
  -- either way — Settings.SPEC is the single definition.
  frame.autoPost = ns.Style and ns.Style.Pill(frame, 150, 22, "Auto-Post: Off")
    or CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.autoPost:SetSize(RN_BTN_W, RN_BTN_H)
  frame.autoPost:SetPoint("TOPLEFT", RN_BTN_X, -RN_AUTO_Y)
  if frame.autoPost.SetPillState then frame.autoPost:SetPillState(false) end
  frame.autoPost:Hide()
  frame.autoPost:SetScript("OnClick", function()
    if not ns.Settings then return end
    ns.Settings.Set("autoPost", ns.Settings.Get("autoPost") and "off" or "on")
    Panel.Refresh()
  end)
  frame.autoPost:SetScript("OnEnter", function(self)
    ns.Tip:SetOwner(self, "ANCHOR_LEFT")
    ns.Tip:SetText("Auto-Post Drops To Chat", 1, 1, 1)
    ns.Tip:AddLine("Posts each drop's shortlist to chat automatically, "
      .. "so the raid sees it without you pressing anything.", 0.8, 0.8, 0.8, true)
    ns.Tip:AddLine(" ")
    ns.Tip:AddLine("Only ever fires on a GUILD run — never in LFR or a pug — "
      .. "and only for whoever is running loot.", 0.6, 0.6, 0.7, true)
    ns.Tip:Show()
  end)
  frame.autoPost:SetScript("OnLeave", function() ns.Tip:Hide() end)

  -- ⚠️ THE PROVISIONAL SWITCHER IS GONE. It existed only while Standings had no
  -- design; that design has arrived and has no such control, and the personal
  -- card it used to reach is now the rail down the left of that tab.
  --
  -- These three controls belong to the TARGET BROWSER, which still has no door
  -- into it (see renderTargetsView). Built and hidden rather than removed, so
  -- giving it a home is a matter of showing them again.
  frame.standingsView = ns.Style and ns.Style.Pill(frame, 92, 22, "Targets")
    or CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.standingsView:SetPoint("TOPLEFT", TOG_X, -TOG_Y)
  frame.standingsView:Hide()

  frame.instDrop = ns.Style and ns.Style.Pill(frame, 170, 22, "")
    or CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.instDrop:SetPoint("TOPLEFT", TOG_X, -(TOG_Y + TOG_ROW))
  frame.instDrop:Hide()
  frame.instDrop:SetScript("OnClick", function()
    local list = ns.Journal and ns.Journal.CachedInstances() or {}
    if #list == 0 then return end
    state.instIndex = (state.instIndex % #list) + 1
    state.encIndex, state.rankScroll = 1, 0
    Panel.Refresh()
  end)

  frame.encDrop = ns.Style and ns.Style.Pill(frame, 170, 22, "")
    or CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.encDrop:SetPoint("TOPLEFT", TOG_X, -(TOG_Y + TOG_ROW * 2))
  frame.encDrop:Hide()
  frame.encDrop:SetScript("OnClick", function()
    local list = Panel._encounterList and Panel._encounterList() or {}
    if #list == 0 then return end
    state.encIndex = (state.encIndex % #list) + 1
    state.rankScroll = 0
    Panel.Refresh()
  end)
end

-- ⚠️ SPLIT INTO SIX, AND NOT FOR TIDINESS. As ONE function this exceeded
-- LUA 5.1'S LIMIT OF 60 UPVALUES and would not compile in the game at all —
-- the file never loaded and /la reported "panel did not load". Every
-- file-scope constant a function references costs one upvalue, and the
-- redesign added roughly fifty geometry constants to a builder that already
-- closed over dozens.
--
-- ⚠️ luac -p DID NOT CATCH IT, because the luac on this machine is 5.5 and
-- 5.2 raised the limit to 255. Syntax that a modern Lua accepts is not
-- evidence that WoW accepts it. Check window files with a 5.1 parser
-- (luajit -bl) — see the harness note in test/smoke.lua.
--
-- Each part now closes over its own section's constants and nothing else,
-- so adding a control to one of them cannot silently re-break the others.
local function build()
  buildChrome()
  buildLootControls()
  buildStandingsTab()
  buildRunnerTab()
  buildDetailPane()
  buildFooter()
  buildTabControls()
end

-- ---------------------------------------------------------------------------
-- Data
-- ---------------------------------------------------------------------------

-- BIS counting lives in Core.lua as ns.BisCountsByBoss: it is pure payload
-- logic, and Panel.lua is frame construction the headless harness does not load.
-- THE STRIP'S TILES. Raid bosses from our payload, or the season's DUNGEONS
-- from the Adventure Guide — one tile per dungeon, because a Mythic+ run has one
-- chest at the end and listing bosses would show a choice the game never offers.
local function bossList()
  if ns.ContentMode() == "mplus" then
    return ns.DungeonList()
  end
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

--- Attach the viewer's own verdict to one item entry — badge, grade, BIS,
--- whether they can use it at all, and how much item level it would gain them.
---
--- ⚠️ THE VIEWER'S OWN, on every entry, including the ones the ranking below is
--- about somebody else. That is what makes the column answer "is any of this for
--- me" before a single row of the detail pane is read.
local function scoreEntry(e)
  -- A DUNGEON ITEM IS NOT IN OUR LOOT TABLE — we have never imported dungeon
  -- loot — so the scorer is handed a record built from what the Adventure Guide
  -- said: name, slot, and the fixed Mythic+ drop level. What it cannot supply is
  -- a stat block, so such an item scores its item-level gain and track gap in
  -- full and its stat alignment as zero, UNLESS it carries a BIS listing or a
  -- letter grade — those REPLACE stat alignment rather than adding to it, so the
  -- picks that actually matter score completely. See ns.JournalRecord.
  local record
  if ns.ContentMode() == "mplus" then
    -- The usable set is resolved ONCE per refresh, not per item: it costs a
    -- journal read per boss in the dungeon, and doing that inside a loop over
    -- every item would drive the live Adventure Guide dozens of times a frame —
    -- the same cost that made resolving boss portraits per refresh untenable.
    record = ns.JournalRecord(
      { name = e.name, slot = e.slotText, armorType = e.armorType,
        itemID = e.itemID, unusable = e.unusable },
      state.usableSet)
  end
  local scored = ns.Loot.ScoreItem(e.itemID, {
    itemLink = e.link, record = record, catalogue = e.catalogue,
    vault = ns.VaultOn() })
  e.quality = scored.quality
  e.ineligible = scored.ineligible or false
  e.reason = scored.reason
  if scored.result then
    e.badge = scored.result.badge
    e.isUpgrade = scored.result.is_upgrade
    e.gain = (scored.candidateIlvl or 0) - ((scored.equipped or {}).ilvl or 0)
  else
    e.gain = 0
  end
  e.slotText = ns.NonEmpty(e.slotText) or scored.slot
  -- A tier token says so on its own line: its slot alone reads as an ordinary
  -- armour piece, which is the one thing it is not.
  local rec = ((ns.Data() or {}).items or {})[e.itemID]
  e.tokenItem = (rec and rec.slot == "TOKEN") and true or false
  -- Carried so the detail pane's identity line does not score the same item a
  -- SECOND time on every refresh just to learn its track and item level.
  e.candidateTrack = scored.candidateTrack
  e.candidateIlvl = scored.candidateIlvl

  -- ⚠️ THE TOOLTIP IS BUILT FROM THE SCORE, so it cannot say something different
  -- from the line beside it. The Vault toggle shipped without this and put "Myth
  -- · ilvl 318" on the detail line next to a tooltip reading "Hero 3/6, Item
  -- Level 311" — the link was still carrying the DROP's bonus id. Deriving it
  -- here means every future thing that moves the candidate level (vault today,
  -- whatever next) moves the tooltip with it for free.
  --
  -- A CATALOGUE ROW HAS NO REAL LINK TO LOSE, and a real DROP keeps its own:
  -- e.catalogue marks the browse list, and only there is the link ours to
  -- replace. nil means no bonus id exists for that level (the ascended ranks),
  -- and the existing link stands.
  if e.catalogue then
    e.link = ns.TooltipLinkFor(e.itemID, scored.candidateTrack, scored.candidateIlvl)
             or e.link
  end

  e.targeted = ns.Targets and ns.Targets.Has(e.itemID) or false
  return e
end

--- The item column's contents.
---
--- TWO SOURCES, one shape. "Current Drops" reads the RECORDER, not the in-memory
--- roll list: the memory list is wiped by a /reload and never learns a winner,
--- while the recorder's copy survives in SavedVariables and is the only thing
--- that knows who won. "Full Loot Table" reads the game's journal first and our
--- payload second.
local function itemEntries()
  local out, seen = {}, {}

  -- ⚠️ WHO CAN USE WHAT IS THE GAME'S ANSWER, and it is resolved ONCE per
  -- refresh, here, so that BOTH lists get it and a set from a previous tile can
  -- never survive a switch. Per item would drive the live Adventure Guide dozens
  -- of times a frame, which is the cost that made per-refresh portrait lookups
  -- untenable in Session 250.
  --
  -- ⚠️ CLEARED IN RAID MODE, not left behind. Raid items carry their own class
  -- gate from the payload, and a stale dungeon set applied to them would mark
  -- real raid loot unusable — a worse bug than the one being fixed.
  if ns.ContentMode() == "mplus" then
    local tiles = bossList()
    local tile = tiles[state.bossIndex]
    state.usableSet = tile and ns.DungeonUsable(tile.id) or nil
  else
    state.usableSet = nil
  end

  if state.source == "drops" then
    -- SCOPED TO THE SELECTED BOSS. The strip is a selector on both lists, not
    -- just the full table; without this it was inert here and the tab looked
    -- frozen on whichever boss died last.
    local bosses = bossList()
    local boss = bosses[state.bossIndex]
    -- ns.EncounterIdsFor, not boss.id: a dungeon tile is an INSTANCE and drops
    -- are recorded against an ENCOUNTER, so passing the tile id straight through
    -- would filter on the wrong number space and show nothing.
    local wanted = ns.EncounterIdsFor(boss and boss.id)
    for _, d in ipairs(ns.Record and ns.Record.RecentDrops(40, wanted) or {}) do
      if d.itemID and not seen[d.itemID] then
        seen[d.itemID] = true
        -- `or` is not enough here either: a recorded drop can carry an EMPTY
        -- itemName, which would win over d.name and then survive every guard
        -- below it. Normalised to nil so the universal pass can do its job.
        local recorded = d.itemName
        if recorded == "" then recorded = nil end
        local fallback = d.name
        if fallback == "" then fallback = nil end
        out[#out + 1] = {
          itemID = d.itemID, name = recorded or fallback, link = d.itemLink,
          winner = d.winner,
        }
      end
    end
  else
    local bosses = bossList()
    local boss = bosses[state.bossIndex]
    if not boss then return out end

    local data = ns.Data()

    -- THE GAME'S LIST FIRST, not ours (Data Contract §0: the drop list is driven
    -- by what the game reports, never by what our data contains). Listing only
    -- items we had imported made an item we never imported INVISIBLE on the one
    -- screen whose entire job is "everything this boss can drop".
    --
    -- NOT class/spec filtered here: the Usable Only toggle is the viewer's own
    -- decision, and the pane ranks the whole ROSTER per item, so filtering at
    -- the source would hide somebody else's upgrade.
    -- IN DUNGEON MODE THE TILE IS A DUNGEON, so its loot is pooled across every
    -- boss inside it and deduplicated (ns.DungeonLoot). In raid mode the tile is
    -- one boss and the read is per encounter. Same shape either way, so
    -- everything below this is unchanged.
    local journalLoot
    if ns.ContentMode() == "mplus" then
      journalLoot = ns.DungeonLoot(boss.id)
    elseif ns.Journal then
      journalLoot = ns.Journal.CachedLoot(boss.id)
    end

    if journalLoot then
      for _, j in ipairs(journalLoot) do
        -- ⚠️ NOT GEAR, NOT ON THE LIST. The journal enumerates profession
        -- patterns and housing decor alongside the loot, and they arrived here
        -- as UNSCORED rows — the addon truthfully having no opinion about a
        -- leatherworking recipe, which is noise on a list that answers "who is
        -- this for". ns.IsGearItem tests the GAME'S item class, never whether we
        -- happen to recognise it, so an armour piece we never imported still
        -- shows (Data Contract §0) and tier tokens are kept by the payload
        -- clause despite Blizzard calling them Miscellaneous.
        if not seen[j.itemID] and ns.IsGearItem(j.itemID, (data or {}).items
             and data.items[j.itemID]) then
          seen[j.itemID] = true
          -- ⚠️ IN DUNGEON MODE THE GUIDE'S LINK IS REPLACED, not passed on. It
          -- tooltips the item at its BASE level, which contradicted the item
          -- level printed right beneath it. ns.MplusItemLink carries the Hero
          -- 3/6 bonus id so the client renders the version that really drops.
          -- ⚠️ RAID LOOT NEEDS THE SAME TREATMENT, and did not get it until
          -- Session 252. The guide's link is not difficulty-aware, so it
          -- tooltipped one item level whether Heroic or Mythic was selected.
          -- ns.RaidItemLink attaches the SELECTED difficulty's bonus id and
          -- returns nil for an item we never imported, where the guide's link
          -- remains the best answer we have.
          local link = j.link
          if ns.ContentMode() == "mplus" then
            link = ns.MplusItemLink(j.itemID)
          else
            link = ns.RaidItemLink(j.itemID, ns.DifficultyKey()) or link
          end
          out[#out + 1] = {
            itemID = j.itemID, name = j.name, link = link,
            -- ⚠️ THE LINK IS FOR THE TOOLTIP; IT NEVER DECIDES THE ITEM LEVEL
            -- on this list. Even the upgraded link above is only as good as the
            -- client's item cache, and an UNCACHED link answers with the base
            -- level — data-shaped and wrong, the trap the inspection rule
            -- already names. Our payload states the per-difficulty level
            -- outright, needs no cache, and cannot disagree with the site.
            catalogue = true,
            -- ⚠️ "" IS TRUTHY, so an empty answer from the Guide would BEAT our
            -- payload's real one below and draw as nothing (Session 254).
            slotText = ns.NonEmpty(j.slot), armorType = ns.NonEmpty(j.armorType),
            -- Blizzard's per-entry eligibility flag, carried so the verdict does
            -- not need a second read of the journal to find it again.
            unusable = j.unusable,
          }
        end
      end
    end

    -- Anything we hold that the journal did not report is still shown. Where the
    -- two disagree, the union is the degrade-loudly answer and a missing item is
    -- the failure that actually costs somebody an upgrade.
    --
    -- ⚠️ RAID MODE ONLY. Our payload's `boss` field is a RAID encounter id, and a
    -- dungeon tile is an INSTANCE id — different id spaces that would collide by
    -- coincidence and file raid items under a dungeon.
    for id, it in pairs((ns.ContentMode() == "mplus") and {} or ((data or {}).items or {})) do
      if it.boss == boss.id and not seen[id] then
        seen[id] = true
        -- Catalogue too, even with no link of its own: these rows are browsing,
        -- not a drop, so their tooltip is scoreEntry's to build. Without the
        -- flag they fell back to a link carrying the DROP's bonus id and
        -- contradicted the item level printed beside them in vault mode.
        out[#out + 1] = { itemID = id, name = it.name, catalogue = true }
      end
    end

  end

  -- ⚠️ AN EMPTY STRING IS A TRUTHY NAME, AND THAT IS WHY ROWS DREW BLANK
  -- (Session 253). This is the SAME FAMILY as the recorded "ZERO IS TRUTHY IN
  -- LUA" rule: `e.name or fallback` returns "" unchanged, and `if not e.name`
  -- does not fire for "". The old guard sat inside the journal branch, promised
  -- in its own comment to never leave "a blank row, which reads as a bug", and
  -- could not keep that promise for the one value that produces exactly that —
  -- while the recorded-drops branch had no guard at all.
  --
  -- The symptom Jason reported: the item's SECOND line rendered fine, proving
  -- the entry existed and had scored, while the name was simply absent until a
  -- boss switch forced a re-read from a warmer source.
  --
  -- NOW UNIVERSAL AND EMPTINESS-AWARE, after BOTH branches, so no source can
  -- emit a nameless row: our payload's name, then the id placeholder. A visible
  -- "item:270160" is a bad name; a blank row is an invisible one.
  ns.FillItemNames(out)

  -- EVERY SOURCE PASSES THROUGH HERE, WHICH IS THE POINT. Both branches build
  -- `out` — recorded drops and the journal's loot table — and only the journal
  -- one ever asked the client to load a missing name or booked a redraw. So a
  -- drop whose item had not resolved rendered as "item:270160" and stayed that
  -- way until something unrelated forced a redraw.
  ns.WarmItemNames(out)

  for _, e in ipairs(out) do scoreEntry(e) end

  -- USABLE ONLY HIDES WHAT YOU CANNOT EQUIP, EXCEPT WHAT YOU ASKED FOR. Targets
  -- pin to the top regardless of usability (Session 249, Jason, flatly) — a
  -- target is an actively chosen thing, and a Resto Druid may legitimately be
  -- chasing Feral gear. Hiding one behind a filter would be the same silent
  -- omission the pin rule exists to prevent.
  if state.filter == "usable" then
    local kept = {}
    for _, e in ipairs(out) do
      if (not e.ineligible) or e.targeted then kept[#kept + 1] = e end
    end
    out = kept
  end

  return ns.OrderItems(out)
end

local function myEntry()
  if not ns.Payload.Current() then return nil end
  local me = UnitName("player")
  if not me then return nil end
  return ns.Payload.byName and ns.Payload.byName[me:lower()] or nil
end

--- The item the detail pane is currently about.
---
--- Reads the list the LAST REFRESH drew rather than rebuilding it. Rebuilding
--- means scoring every item on the boss again, and this is called from Refresh
--- itself, from the Post button's click and from its tooltip — three full passes
--- per frame to answer a question the render had just answered. The cache is
--- written by renderLoot and cleared whenever the tab changes, so it cannot
--- outlive the list it came from.
function Panel.CurrentItemID()
  if state.tab ~= "Loot" then return nil end
  local e = Panel._entries and Panel._entries[state.sel]
  return e and e.itemID or nil
end

-- ---------------------------------------------------------------------------
-- The parked target browser (provisional — see the note in build())
-- ---------------------------------------------------------------------------

local function currentInstance()
  local list = ns.Journal and ns.Journal.CachedInstances() or {}
  if #list == 0 then return nil end
  if state.instIndex > #list then state.instIndex = 1 end
  return list[state.instIndex]
end

local function encounterList()
  local inst = currentInstance()
  if not inst then return {} end
  return ns.Journal.CachedEncounters(inst.id)
end
Panel._encounterList = encounterList

local function currentEncounter()
  local list = encounterList()
  if #list == 0 then return nil end
  if state.encIndex > #list then state.encIndex = 1 end
  return list[state.encIndex]
end

--- BROWSE goes through Blizzard's OWN class/spec filter rather than our emitted
--- eligibility answers. Not a shortcut — it is the only thing that answers for
--- DUNGEON and WORLD BOSS loot at all, since our payload covers raid items only.
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

  -- A LIST FILTERED WITHOUT A SPEC IS A DIFFERENT LIST, and because the spec is
  -- part of the cache key the list would CHANGE LENGTH once it resolved. Waiting
  -- is honest; showing the wrong list and correcting it later is not.
  if not (classID and char.specId) then
    ns.Journal.ScheduleWarm()
    return {}, true
  end

  local list, warming = ns.Journal.CachedLoot(enc.id, {
    classID = classID, specID = char.specId,
  })

  -- A WARMING READ IS NOT SHOWN: it is wrong in two ways at once — unnamed AND
  -- unfiltered, because Blizzard's filter cannot judge an item the client has
  -- not loaded.
  if warming then return {}, true end

  local inst = currentInstance()
  local out = {}
  for _, e in ipairs(list) do
    out[#out + 1] = {
      itemID = e.itemID,
      name   = e.name or ("item:" .. tostring(e.itemID)),
      icon   = e.icon, link = e.link, slot = e.slot,
      veryRare = e.veryRare, unusable = e.unusable,
      source = ("%s · %s"):format(inst and inst.name or "?", enc.name or "?"),
    }
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function hideRows(from)
  for i = from, RANK_ROWS do frame.rows[i]:Hide() end
end

local function setHeaders(a, b, c, d)
  frame.head[1]:SetText(a or "")
  frame.head[2]:SetText(b or "")
  frame.head[3]:SetText(c or "")
  frame.head[4]:SetText(d or "")
end

--- The purple surface behind the detail pane.
---
--- ⚠️ IT IS ABSENT, NOT EMPTY, WHEN THERE IS NOTHING TO SHOW. Jason's 0-Drops
--- mock has NO pane: the right-hand side is simply the window. The first build
--- drew the full 380x360 purple block with a dash in it and two dividers
--- floating across nothing, which is a large piece of furniture announcing that
--- it has no contents. Between kills that is the NORMAL state, so it is the one
--- worth getting right.
local function showPaneSurface(shown)
  if frame.paneBg then frame.paneBg:SetShown(shown) end
end

--- The Loot tab's own pane furniture: the three header blocks, the facts line,
--- the item identity row, Won By, and the dividers that separate them. Hidden
--- wholesale on the views that do not use them, so nothing is left drawing over
--- a list it has nothing to do with.
local function showLootPaneParts(shown)
  for _, part in ipairs({
    frame.hUpgradeLabel, frame.hUpgrade, frame.hStandLabel, frame.hStand, frame.hEpgp,
    frame.div1, frame.facts, frame.div2, frame.div3,
    frame.itemIcon, frame.itemHover, frame.itemName, frame.itemSub,
    frame.wonDiv, frame.wonLabel, frame.wonBy,
  }) do
    if part then part:SetShown(shown) end
  end
end

--- Blank every part of the detail pane that a view does not own, so nothing one
--- view sets bleeds into the next.
local function clearPane()
  frame.hUpgradeLabel:SetText("")
  frame.hUpgrade:SetText("")
  frame.hStandLabel:SetText("")
  frame.hStand:SetText("")
  frame.hEpgp:SetText("")
  frame.facts:SetText("")
  frame.itemIcon:Hide()
  frame.itemHover:Hide()
  frame.itemName:SetText("")
  frame.itemSub:SetText("")
  frame.wonDiv:Hide()
  frame.wonLabel:Hide()
  frame.wonBy:SetText("")
  frame.more:SetText("")
  frame.note:SetText("")
  setHeaders()
end

local function renderBossStrip()
  local bosses = bossList()
  if state.bossIndex > #bosses then state.bossIndex = 1 end

  -- The strip is fixed at nine slots because the window is fixed. A raid with
  -- more bosses than that is COUNTED rather than silently cut off — nine has
  -- covered every tier so far, and the day it does not, the panel says so.
  local shown = math.min(#bosses, BOSS_SLOTS)
  for i = 1, BOSS_SLOTS do
    local tile, b = frame.bossTiles[i], bosses[i]
    if not b or i > shown then
      tile:Hide()
    else
      tile.bossIndex, tile.bossName, tile.bossBis = i, b.name, b.bis

      -- ⚠️ BUNDLED SQUARE ART, NOT THE GAME'S CREATURE PORTRAIT. Two wrong
      -- answers preceded this one. The Encounter Journal's creature icon is WIDE,
      -- so forcing it into a 32x32 tile squashed every face; asking the client
      -- for a proper portrait instead fixed the aspect and came back ROUND,
      -- because that call renders the circular unit-frame portrait.
      --
      -- The design's tiles are 56x56 squares, and they are the same files
      -- Gloom's Build Barn already bundles — that is where the mock's art came
      -- from. So this addon bundles them too, and the strip is a plain texture
      -- lookup with nothing to distort and nothing to resolve at runtime.
      --
      -- ⚠️ RENAMED TO THE BLIZZARD ENCOUNTER ID. Build Barn keys its copies by
      -- WCL id; this payload's bosses are keyed by BLIZZARD id, and those are
      -- different number spaces (Core §1.1). Renaming at bundle time keeps the
      -- lookup a single index rather than shipping a mapping table that would
      -- need maintaining alongside the art.
      --
      -- ⚠️ NEW TIER = NEW ART, or these draw as initials. Same standing cost
      -- Build Barn carries; it belongs on the season-rollover checklist.
      -- ⚠️ TWO FOLDERS, TWO ID SPACES, AND THEY MUST NOT BE MIXED. Raid tiles are
      -- Blizzard ENCOUNTER ids; dungeon tiles are Blizzard INSTANCE ids. The
      -- ranges overlap by coincidence, so a single folder would eventually put a
      -- raid boss's face on a dungeon with nothing erroring.
      --
      -- Both sets are Build Barn's, renamed. Its Mythic+ section is keyed by
      -- DUNGEON rather than by boss — which is the same shape this strip needs,
      -- since a key drops one chest at the end — so it already ships exactly one
      -- 56x56 icon per dungeon. Renamed from its WarcraftLogs ids to Blizzard's
      -- by matching NAMES, which agree one-to-one across the two sources.
      local folder = (ns.ContentMode() == "mplus") and "dungeons" or "bosses"
      tile.art:SetTexture(("Interface\\AddOns\\HoDLootAdvisor\\Media\\%s\\%d.png")
        :format(folder, b.id))
      local drew = tile.art:GetTexture() ~= nil

      tile.art:SetShown(drew)
      tile.fallback:SetShown(not drew)
      tile.initial:SetText(drew and "" or (b.name or "?"):sub(1, 1):upper())
      tile.sel:SetShown(i == state.bossIndex)
      tile:Show()
    end
  end
  -- Nine slots, and the season has more dungeons than that — so the overflow
  -- line is not a theoretical case here, and it must name the right thing.
  local noun = (ns.ContentMode() == "mplus") and "dungeons" or "bosses"
  frame.stripMore:SetText(#bosses > BOSS_SLOTS
    and ("+%d more %s not shown"):format(#bosses - BOSS_SLOTS, noun) or "")
end

local function renderItemColumn(entries)
  local total = #entries
  local maxScroll = math.max(0, total - COL_ROWS)
  if state.colScroll > maxScroll then state.colScroll = maxScroll end
  if state.sel > total then state.sel = 1 end

  frame.colEmpty:SetShown(total == 0)
  if total == 0 then
    -- The mock's own words, in its own treatment: uppercase and in the Major
    -- red, not a grey sentence. It is a STATE, and the design gives states the
    -- same weight as data.
    frame.colEmpty:SetText(state.source == "drops"
      and "NO DROPS CURRENTLY"
      or "NO ITEMS FOR THIS BOSS")
    if ns.Style then frame.colEmpty:SetTextColor(ns.Style.rgb(ns.Style.COLOR.major)) end
    frame.colMore:SetText("")
    for i = 1, COL_ROWS do frame.itemRows[i]:Hide() end
    return
  end

  local S = ns.Style
  for i = 1, COL_ROWS do
    local row, e = frame.itemRows[i], entries[i + state.colScroll]
    if not e then
      row:Hide()
    else
      local idx = i + state.colScroll
      row.entryIndex, row.itemID, row.itemName, row.link = idx, e.itemID, e.name, e.link

      -- ⚠️ SHOW THE ROW BEFORE WRITING TO IT (Session 254). It was shown at the
      -- END of this branch, so on the first draw after a client restart every
      -- line was written into a row that was still hidden, and that first paint
      -- did not take.
      row:Show()

      -- ⚠️ THE LAST WRITER GUARDS TOO. `e.name or "?"` cannot save a row from
      -- "", and an invisible row is the one failure nobody reports as a bug —
      -- they report "the addon is broken". If this ever substitutes, the screen
      -- says "item:270160", which is a bug report rather than a mystery.
      local shown = e.name
      if type(shown) ~= "string" or shown == "" then
        shown = "item:" .. tostring(e.itemID)
      end
      setTextForce(row.name, shown)

      -- The verdict word, then the slot. "NOT FOR YOU" is deliberately DISTINCT
      -- from "unscored": one is the system working, the other is our data
      -- falling short, and conflating them hides a real gap.
      local verdict, vColor
      if e.ineligible then
        verdict, vColor = "NOT FOR YOU", S and S.COLOR.grey
      elseif e.reason then
        verdict, vColor = "UNSCORED", S and S.COLOR.red
      elseif e.isUpgrade == false then
        verdict, vColor = "NO UPGRADE", S and S.COLOR.grey
      else
        local label, color = badgeOf(e.badge)
        verdict, vColor = (label or ""):upper(), color
      end
      local slotLine = ns.ItemSlotLine(e)
      local sep = (verdict ~= "" and slotLine ~= "") and " • " or ""
      if S then
        -- Each run closes with |r before the next opens. Nesting colour codes
        -- without a reset is accepted by some clients and not others, and the
        -- failure is a whole line taking the first colour.
        row.sub:SetText(
          S.code(vColor or S.COLOR.grey) .. verdict .. "|r"
          .. S.code(S.COLOR.grey) .. sep .. "|r"
          .. slotLine)
      else
        row.sub:SetText(verdict .. sep .. slotLine)
      end

      row.markTarget:SetShown(e.targeted and true or false)
      row.markBis:SetShown((e.quality and e.quality.bis) and true or false)

      local selected = (idx == state.sel)
      row._selected = selected
      if S then
        row.bg:SetColorTexture(S.COLOR.purple.r, S.COLOR.purple.g, S.COLOR.purple.b,
          selected and 0.2 or 0.1)
      end
      -- Shown at the TOP of this branch now, before anything is written into it.
    end
  end

  frame.colMore:SetText(total > COL_ROWS
    and ("%d–%d of %d · scroll"):format(state.colScroll + 1,
      math.min(total, state.colScroll + COL_ROWS), total) or "")
end

--- The pane's three header blocks: the viewer's own verdict, their place on the
--- ladder, and the numbers behind it.
local function renderPaneHeader(entry)
  frame.hUpgradeLabel:SetText("Upgrade for You:")
  local S = ns.Style

  if not entry then
    frame.hUpgrade:SetText("—")
    if S then frame.hUpgrade:SetTextColor(S.rgb(S.COLOR.grey)) end
  elseif entry.ineligible then
    frame.hUpgrade:SetText("Not For You")
    if S then frame.hUpgrade:SetTextColor(S.rgb(S.COLOR.grey)) end
  elseif entry.reason then
    frame.hUpgrade:SetText("Unscored")
    if S then frame.hUpgrade:SetTextColor(S.rgb(S.COLOR.red)) end
  elseif entry.isUpgrade == false then
    frame.hUpgrade:SetText("No Upgrade")
    if S then frame.hUpgrade:SetTextColor(S.rgb(S.COLOR.grey)) end
  else
    local label, color = badgeOf(entry.badge)
    frame.hUpgrade:SetText(label or "?")
    if S and color then frame.hUpgrade:SetTextColor(S.rgb(color)) end
  end

  -- ⚠️ NO STANDING WITHOUT A RAID NIGHT (Jason, Session 254). EPGP arrives only
  -- in the raid-night export, so with nothing imported there is no ladder, no
  -- priority and no rank — and an em-dash under "Your Standing" reads as a
  -- number we failed to find rather than a question that does not apply here.
  -- This is the case for ANYONE outside the guild who installs the addon, for
  -- whom the whole EPGP half is meaningless; the Standings tab hides for the
  -- same reason (layoutTabs). The scoring half still works completely — it runs
  -- off the baked payload and their own gear.
  local loaded = ns.Payload.Current() and true or false
  frame.hStandLabel:SetShown(loaded)
  frame.hStand:SetShown(loaded)
  frame.hEpgp:SetShown(loaded)
  if not loaded then return end

  frame.hStandLabel:SetText("Your Standing:")
  local me = myEntry()
  if me and me.rank then
    local n, suffix = ns.Ordinal(me.rank)
    frame.hStand:SetText((n or "?") .. (suffix or ""))
  else
    frame.hStand:SetText("—")
  end

  if me and me.pr then
    frame.hEpgp:SetText(("Priority: %.2f\nEffort Points: %s\nGear Points: %s")
      :format(me.pr, tostring(me.ep), tostring(me.gp)))
  else
    frame.hEpgp:SetText("No EPGP standing\nyet this season")
  end
end

--- The facts line beneath the header: gain, gap, quality and target state.
---
--- "Cost: 100 GP" appears ONLY when the raid export carried the pricing block,
--- and is silently absent otherwise — an export made before pricing shipped, or
--- a client that has never imported one. Nothing is invented to fill the gap: a
--- fabricated figure under an authoritative label is what Core §7.7 forbids,
--- and it is the reason this segment took a season to arrive.
---
--- The item level priced is candidateIlvl, which is the DIFFICULTY-resolved one
--- the badge was computed against — so the cost always describes the same copy
--- of the item the rest of the line is about.
local function renderFacts(entry, ranked)
  if not entry then frame.facts:SetText("") return end
  local S = ns.Style
  local parts = {}

  if (entry.gain or 0) > 0 and not entry.ineligible then
    parts[#parts + 1] = ("+%d ilvl"):format(entry.gain)
  end

  -- The viewer's own gap from the leader, read off the ranking rather than
  -- recomputed — and ABSENT rather than zero when the sort cannot guarantee
  -- score order, which is what makes a gap meaningful at all.
  local me = (UnitName("player") or ""):lower()
  for i, r in ipairs(ranked or {}) do
    if (r.name or ""):lower() == me then
      if r.gap and i > 1 then
        parts[#parts + 1] = ("%d behind"):format(r.gap)
      elseif i == 1 then
        parts[#parts + 1] = "top of the list"
      end
      break
    end
  end

  local price = ns.Payload.PriceText(entry.itemID, entry.candidateIlvl)
  if price then parts[#parts + 1] = "Cost: " .. price end

  local q = entry.quality
  if q and q.bis and S then
    parts[#parts + 1] = S.code(S.COLOR.bis) .. (ns.BIS_LONG[q.bis] or "BIS") .. "|r"
  elseif q and q.grade and S then
    local tag = qualityTag(q)
    if tag then parts[#parts + 1] = tag .. " grade" end
  end

  if entry.targeted and S then
    parts[#parts + 1] = S.code(S.COLOR.target) .. "Targeted" .. "|r"
  end

  if #parts == 0 then
    frame.facts:SetText(entry.reason or "")
  else
    local sep = S and (S.code(S.COLOR.grey) .. "  " .. BAR .. "  |r") or ("  " .. BAR .. "  ")
    frame.facts:SetText(table.concat(parts, sep))
  end
end

--- The selected item's identity row, and who won it.
local function renderItemIdentity(entry)
  if not entry then
    frame.itemIcon:Hide()
    frame.itemHover:Hide()
    frame.itemName:SetText("")
    frame.itemSub:SetText("")
    frame.wonDiv:Hide()
    frame.wonLabel:Hide()
    frame.wonBy:SetText("")
    return
  end

  local icon = entry.icon
  if not icon and GetItemIcon then icon = GetItemIcon(entry.itemID) end
  frame.itemIcon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
  frame.itemIcon:Show()
  frame.itemHover.link = entry.link
  frame.itemHover:Show()

  frame.itemName:SetText(entry.name or "?")

  -- Slot, armour type, track and the item level this difficulty drops it at —
  -- the facts that say WHICH version of the item this is. All four came off the
  -- scoring pass the column already ran.
  local bits = {}
  local slotLine = ns.ItemSlotLine(entry)
  if slotLine ~= "" then bits[#bits + 1] = slotLine end
  if entry.candidateTrack then bits[#bits + 1] = entry.candidateTrack end
  if (entry.candidateIlvl or 0) > 0 then
    bits[#bits + 1] = ("ilvl %d"):format(entry.candidateIlvl)
  end
  frame.itemSub:SetText(table.concat(bits, " • "))

  -- WON BY, from the RECORDER. nil is a real answer and is shown as one: nothing
  -- in the addon registers that a roll ENDED, only that one started, so "still
  -- open" and "we never found out" are indistinguishable from here. Saying
  -- nothing is honest; a countdown or a "pending" would not be.
  local winner = entry.winner or (ns.Record and ns.Record.WinnerFor(entry.itemID))
  frame.wonDiv:SetShown(winner ~= nil)
  frame.wonLabel:SetShown(winner ~= nil)
  frame.wonBy:SetText(winner or "")
end

local function renderRanking(itemID)
  -- RankingFor, not RankRaiders: when the runner has broadcast a ranking for
  -- this item, theirs is the one everyone shows.
  --
  -- ⚠️ VAULT MODE REACHES ONLY THE LOCAL CALCULATION, and that is the right
  -- place for it. A broadcast ranking belongs to a LIVE DROP, where the question
  -- is who gets the item that just fell — not what it would have been worth in
  -- next week's chest — and the runner's numbers stay authoritative there by
  -- rule. Vault mode is a planning view over the full loot table.
  local ranked, _all, meta, fromRunner =
    ns.Loot.RankingFor(itemID, { vault = ns.VaultOn() })
  setHeaders("RAIDER", "UPGRADE", "GAIN", "PRIORITY")

  if not ranked then
    -- ⚠️ SAY WHAT IS SHOWN, NOT ONLY WHAT IS MISSING. The grades and BIS marks
    -- in the column are the VIEWER'S OWN — scored from their equipped gear
    -- against the addon's baked-in tables, so they are fully correct with no
    -- roster loaded. Reading "nothing imported" beside a full column makes both
    -- halves look broken when neither is.
    setHeaders()
    frame.more:SetText("")
    frame.note:SetText("The column is scored for you from your own gear. "
      .. "Press Import Raid Night to rank the raid for this item.")
    hideRows(1)
    return nil
  end

  local total = #ranked
  local maxScroll = math.max(0, total - RANK_ROWS)
  if state.rankScroll > maxScroll then state.rankScroll = maxScroll end

  if total == 0 then
    frame.more:SetText("")
    frame.note:SetText("Nobody on the roster can use this.")
    hideRows(1)
    return ranked
  end

  local me = (UnitName("player") or ""):lower()
  local shown = math.min(total - state.rankScroll, RANK_ROWS)
  local S = ns.Style
  local sawAdhoc = false

  -- ⚠️ JOINT RANKING ON TIES, COMPUTED OVER THE WHOLE LIST. Two raiders on the
  -- same score share a place and the next one skips — 1, 2, 2, 4 — which is what
  -- the design shows and what a tie MEANS. Numbering them 2 and 3 asserts an
  -- order the scorer did not produce, and the person shown "third" would
  -- reasonably read it as having lost.
  --
  -- The whole list, not the visible rows: a place depends on every row ABOVE it,
  -- so deriving it from the previous VISIBLE row restarts the numbering at the
  -- top of each scroll page, and a tie straddling the boundary comes apart.
  --
  -- A received ranking carries no scores — the wire deliberately never sends
  -- them (Session 249) — so those rows fall through to their ordinal, which is
  -- correct: the runner already resolved the ties when they ranked it.
  local place = {}
  for i = 1, total do
    local r, prev = ranked[i], ranked[i - 1]
    if prev and prev.result and r.result
       and prev.result.raw_score ~= nil
       and prev.result.raw_score == r.result.raw_score then
      place[i] = place[i - 1]
    else
      place[i] = i
    end
  end

  for i = 1, shown do
    local row = frame.rows[i]
    local idx = i + state.rankScroll
    local r = ranked[idx]
    resetRow(row)
    -- Shown BEFORE anything is written into it — see setTextForce (Session 254).
    row:Show()

    row.rank:SetText(tostring(place[idx] or idx))
    row.rank:SetTextColor(unpack(MUTED))

    local displayName = r.name or "?"
    if r.adhoc then
      -- AN AD-HOC RAIDER IS MARKED: somebody the raid-night export has never
      -- heard of, resolved entirely from what we could read off them in game.
      -- "Who is that" is the question a runner has when an unfamiliar name
      -- appears, and the asterisk answers it before they ask.
      displayName = displayName .. "*"
      sawAdhoc = true
    end
    setTextForce(row.name, displayName)
    local cc = CLASS_COLOR[r.class or ""] or WHITE
    row.name:SetTextColor(cc[1], cc[2], cc[3])

    -- The UPGRADE column carries the badge, the grade or BIS mark, and the gap,
    -- in that order — the design's "BIS Major" and "Major −16".
    local upgrade = {}
    local qText, qColor = qualityTag(r.quality)
    if qText and S and qColor then
      upgrade[#upgrade + 1] = ("|cff%02x%02x%02x%s|r"):format(
        qColor[1] * 255, qColor[2] * 255, qColor[3] * 255, qText)
    end
    local label, color = badgeOf(r.result and r.result.badge)
    if label and S and color then
      upgrade[#upgrade + 1] = S.code(color) .. label .. "|r"
    end
    -- Gap is ABSENT, not zero, when the sort cannot guarantee score order.
    if r.gap and idx > 1 then
      if r.gap == 0 then
        upgrade[#upgrade + 1] = (S and S.code(S.COLOR.textDim) or "") .. "tie"
      else
        upgrade[#upgrade + 1] = (S and S.code(S.COLOR.textDim) or "") .. tostring(r.gap)
      end
    end
    row.upgrade:SetText(table.concat(upgrade, " "))

    -- A raider ranked as one spec while standing in another gets a marker, and
    -- the sentence goes in the row tooltip. ns.SpecSplitTag stays quiet unless
    -- the spec change actually changes this item's grade.
    local splitMark, splitName, splitHelp = ns.SpecSplitTag(r)
    row.splitName, row.splitHelp = splitName, splitHelp
    if splitMark then
      row.upgrade:SetText(row.upgrade:GetText() .. (S and S.code(S.COLOR.gold) or "") .. splitMark)
    end

    -- One field on both paths (Loot.RankRaiders sets it, the wire carries it).
    local gain = r.ilvlGain or 0
    row.gain:SetText(gain > 0 and ("+%d"):format(gain) or "")

    -- What the UPGRADE cell's tooltip explains. The FACTORS are present only on
    -- a LOCALLY scored row — a ranking received from the runner carries the
    -- badge and the gap but not the arithmetic — and the tooltip says so rather
    -- than rendering an empty breakdown.
    row.scoreInfo = {
      gain    = gain,
      factors = r.result,
      score   = r.result and r.result.raw_score or nil,
      gap     = (idx > 1) and r.gap or nil,
      leader  = ranked[1] and ranked[1].name or nil,
    }

    if r.pr then
      row.pr:SetText(("%.2f"):format(r.pr))
      row.pr:SetTextColor(unpack(WHITE))
    else
      row.pr:SetText("—")
      row.pr:SetTextColor(unpack(MUTED))
    end

    -- Which TIER this raider's gear came from. Three-tier provenance is only
    -- worth having if it is visible.
    local srcText, srcColor, srcHelp = ns.ProvenanceTag(r.equipped)
    row.src:SetText(srcText or "")
    if srcColor then row.src:SetTextColor(srcColor[1], srcColor[2], srcColor[3]) end
    row.srcHelp, row.srcName = srcHelp, r.name
    if r.adhoc then
      row.srcHelp = (srcHelp and (srcHelp .. "\n\n") or "")
        .. "Not on tonight's raid-night export — read from them in game. "
        .. "No EPGP standing exists for them."
    end

    row.hl:SetShown((r.name or ""):lower() == me)
    row:Show()
  end
  hideRows(shown + 1)

  -- Rows that do not fit are COUNTED, never silently cut off.
  local bits = {}
  -- ⚠️ "CAN USE IT" WAS A MISLABEL. This count is raiders the item is an
  -- UPGRADE for, not raiders who can equip it — the two differ by everyone it
  -- fits and does not improve, which on a well-geared roster is most of them.
  local usable = (meta and meta.usable) or total
  bits[#bits + 1] = (meta and meta.total)
    and ("%d of %d raiders gain from it"):format(usable, meta.total)
    or ("%d raiders gain from it"):format(usable)

  -- ⚠️ SAY WHY YOU ARE NOT IN THE LIST. The table holds only people the item
  -- improves, so a viewer it does not improve simply is not there — which reads
  -- as the addon having lost them rather than as an answer. The header says "No
  -- Upgrade", but nobody connects the two without being told.
  local listed = false
  for _, r in ipairs(ranked) do
    if (r.name or ""):lower() == me then listed = true end
  end
  if not listed and ns.Payload.Current() then
    local S = ns.Style
    bits[#bits + 1] = (S and S.code(S.COLOR.textDim) or "")
      .. "you are not listed — no gain for you" .. "|r"
  end
  if fromRunner then
    -- Named, because "why does my list differ from what I would have worked out"
    -- has exactly one answer and it should not be a mystery.
    bits[#bits + 1] = ("ranked by %s"):format(fromRunner)
  else
    local gear = ns.GearReportingSummary()
    if gear and gear.reporting > 0 then
      bits[#bits + 1] = ("%d of %d reporting live gear"):format(gear.reporting, gear.total)
    end
  end
  if total > RANK_ROWS then
    bits[#bits + 1] = ("showing %d–%d · scroll for more")
      :format(state.rankScroll + 1, state.rankScroll + shown)
  end
  frame.more:SetText(table.concat(bits, "  ·  "))

  frame.note:SetText(sawAdhoc
    and "*  Not on tonight's raid roster | Upgrade score calculated from equipped gear"
    or "")

  return ranked
end

local function renderLoot()
  local entries = itemEntries()
  Panel._entries = entries
  renderBossStrip()

  -- The boss context: which boss, and how much of its table matters to you.
  local bosses = bossList()
  local boss = bosses[state.bossIndex]
  frame.bossName:SetText(boss and boss.name or "No boss data")
  local bis, targets = ns.CountsForItems(entries)
  local S = ns.Style
  if S then
    frame.bossSub:SetText("For You: "
      .. S.code(S.COLOR.bis) .. bis .. " BIS|r"
      .. S.code(S.COLOR.grey) .. " " .. BAR .. " |r"
      .. S.code(S.COLOR.target) .. targets .. " Targets|r")
  else
    frame.bossSub:SetText(("For You: %d BIS %s %d Targets"):format(bis, BAR, targets))
  end

  renderItemColumn(entries)

  local entry = entries[state.sel]

  -- NO SELECTION MEANS NO PANE, exactly as the 0-Drops mock draws it. The whole
  -- right-hand side goes away rather than standing there empty.
  if not entry then
    showPaneSurface(false)
    showLootPaneParts(false)
    setHeaders()
    frame.more:SetText("")
    frame.note:SetText("")
    hideRows(1)
    return
  end

  showPaneSurface(true)
  showLootPaneParts(true)
  renderPaneHeader(entry)
  renderItemIdentity(entry)

  local ranked = renderRanking(entry.itemID)
  renderFacts(entry, ranked)
end

-- ---------------------------------------------------------------------------
-- Standings, and the two views parked behind it
-- ---------------------------------------------------------------------------

--- The personal rail: priority, EP/GP, attendance, last item won.
---
--- This is the old "Me" tab, folded into the Standings design where Jason put
--- it. Nothing is lost by the tab going away — the rail says everything the card
--- did, beside the table it is a position within.
local function renderRail(total)
  local S = ns.Style
  local me = myEntry()
  local blocks = frame.rail

  for _, b in ipairs(blocks) do
    for _, key in ipairs({ "head", "big", "bigSuffix", "line1", "line2", "line3" }) do
      b[key]:SetText("")
    end
  end

  blocks[1].head:SetText("YOUR PRIORITY")
  blocks[2].head:SetText("EARNED / SPENT")
  blocks[3].head:SetText("ATTENDANCE")
  blocks[4].head:SetText("LAST ITEM WON")

  if not me then
    blocks[1].line1:SetText(ns.Payload.Current()
      and "You are not on the exported roster."
      or "Nothing imported yet.")
    return
  end

  if me.rank then
    blocks[1].big:SetText("#" .. tostring(me.rank))
    blocks[1].line1:SetText(("of %d • PR %.2f"):format(total, me.pr or 0))
  else
    blocks[1].big:SetText("—")
    blocks[1].line1:SetText("No standing yet this season")
  end

  if S then
    blocks[2].line1:SetText("EP " .. S.code(S.COLOR.target) .. ns.Commify(me.ep) .. "|r")
    blocks[2].line2:SetText("GP " .. S.code(S.COLOR.major) .. ns.Commify(me.gp) .. "|r")
  else
    blocks[2].line1:SetText("EP " .. ns.Commify(me.ep))
    blocks[2].line2:SetText("GP " .. ns.Commify(me.gp))
  end

  -- NIGHTS PRESENT, never the site's weighted attendance percentage. They answer
  -- different questions and publishing one under the other's label is exactly
  -- how the two come to disagree in front of the raid.
  if me.nightsOf and me.nightsOf > 0 then
    blocks[3].big:SetText(tostring(me.nights or 0))
    -- The suffix hangs off the figure's own width so "12/21" and "2/3" both sit
    -- correctly, rather than at a fixed offset that only suits single digits.
    blocks[3].bigSuffix:ClearAllPoints()
    blocks[3].bigSuffix:SetPoint("BOTTOMLEFT", blocks[3].big, "BOTTOMLEFT",
      blocks[3].big:GetStringWidth() + 1, 3)
    blocks[3].bigSuffix:SetText("/" .. tostring(me.nightsOf))
    -- The first mock's caption here was the PRIORITY block's, duplicated and not
    -- updated ("of 17 • PR 3.9"). Flagged in #250, confirmed an oversight, and
    -- the design now reads "nights present" — which is also exactly what the
    -- figure counts, per the comment above.
    blocks[3].line1:SetText("nights present")
  else
    blocks[3].big:SetText("—")
    blocks[3].line1:SetText("no raid nights recorded yet")
  end

  if me.lastItem then
    -- The design wraps a long item name across two lines rather than truncating
    -- it, which is right: the name is the answer, and half of it is not.
    local name = me.lastItem
    if #name > 20 then
      local cut = name:sub(1, 20):match("^.*%s") or name:sub(1, 20)
      blocks[4].line1:SetText((cut:gsub("%s+$", "")))
      blocks[4].line2:SetText(name:sub(#cut + 1))
    else
      blocks[4].line1:SetText(name)
    end
    blocks[4].line3:SetText(ns.LongAge(me.lastItemDays) or "")
  else
    blocks[4].line1:SetText("Nothing on record")
  end
end

local function renderStandingsList()
  local rows, total = ns.StandingsRows()
  renderRail(total)

  if #rows == 0 then
    frame.stNote:SetText(ns.Payload.Current()
      and "No EPGP standings for this season yet."
      or "Nothing imported yet — press Import Raid Night.")
    for i = 1, ST_ROWS do frame.stRows[i]:Hide() end
    return
  end
  frame.stNote:SetText("")

  local maxScroll = math.max(0, #rows - ST_ROWS)
  if state.rankScroll > maxScroll then state.rankScroll = maxScroll end

  local me = (UnitName("player") or ""):lower()
  for i = 1, ST_ROWS do
    local row, r = frame.stRows[i], rows[i + state.rankScroll]
    if not r then row:Hide() else
      -- Shown BEFORE anything is written into it — see setTextForce (S254).
      row:Show()
      row.rank:SetText(tostring(r.rank))
      row.rank:SetTextColor(unpack(MUTED))

      setTextForce(row.name, r.name or "?")
      local cc = CLASS_COLOR[r.class or ""] or WHITE
      row.name:SetTextColor(cc[1], cc[2], cc[3])

      row.ep:SetText(ns.Commify(r.ep))
      row.gp:SetText(ns.Commify(r.gp))
      row.pr:SetText(r.pr and ("%.2f"):format(r.pr) or "—")
      -- Em-dash for a raider who has never received an item: genuinely absent
      -- data, not a zero (Core §1.1).
      row.last:SetText(ns.ShortAge(r.lastItemDays) or "—")

      -- Not in the mock, kept deliberately: finding yourself in a table of
      -- twenty is the first thing anyone does with it, and the row that says
      -- #6 in the rail should be visible in the list without counting.
      row.hl:SetShown((r.name or ""):lower() == me)
      row:Show()
    end
  end
end

--- The target browser — raids, dungeons and world bosses, filtered to what this
--- character can use, which is the ONLY surface that reaches past tonight's raid.
---
--- ⚠️ NO CALLER, AND THAT IS A GAP, NOT DEAD CODE. It had a tab of its own before
--- the three-tab redesign, and neither the Loot nor the Standings design has a
--- door into it. Right-clicking an item on the Loot tab still targets, so the
--- FLAGGING gesture survives; what has no way in is BROWSING the catalogue for
--- something that has not dropped. Kept intact rather than deleted, because a
--- capability disappearing because a mock did not include it is not a decision
--- this file gets to make. It wants a home in one of the remaining designs.
local function renderTargetsView()
  local browsing = state.targetMode == "browse"
  local inst, enc = currentInstance(), currentEncounter()

  frame.itemName:SetText(browsing and (inst and inst.name or "No catalogue") or "Your Targets")
  frame.itemSub:SetText(browsing and (enc and enc.name or "") or
    ("%d flagged on %s — right-click to remove"):format(
      ns.Targets and ns.Targets.Count() or 0, UnitName("player") or "this character"))

  setHeaders("ITEM", "", "SLOT", "SOURCE")

  local rows, warming = targetRows()
  if #rows == 0 then
    frame.more:SetText("")
    frame.note:SetText(warming and "Loading item data from the client…"
      or (browsing and "" or "Nothing flagged yet. Browse the catalogue and right-click an item."))
    hideRows(1)
    return
  end

  local total = #rows
  local maxScroll = math.max(0, total - RANK_ROWS)
  if state.rankScroll > maxScroll then state.rankScroll = maxScroll end

  for i = 1, RANK_ROWS do
    local row, r = frame.rows[i], rows[i + state.rankScroll]
    if not r then row:Hide() else
      resetRow(row)
      -- Shown BEFORE anything is written into it — see setTextForce (S254).
      row:Show()
      row.itemID, row.link = r.itemID, r.link
      row.meta = { name = r.name, icon = r.icon, slot = r.slot, source = r.source }
      row.icon:SetTexture(r.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
      row.icon:Show()

      local marked = ns.Targets and ns.Targets.Has(r.itemID)
      row.name:SetWidth(150)
      setTextForce(row.name, r.name or "?")
      row.name:SetTextColor(unpack(marked and ns.TARGET_COLOR or WHITE))
      row.upgrade:SetText(r.veryRare and "|cffa335eerare|r" or "")
      row.gain:SetText(r.slot or "")
      row.pr:SetText(r.source or "")
      row.pr:SetTextColor(unpack(MUTED))
      row:Show()
    end
  end

  frame.more:SetText(total > RANK_ROWS
    and ("showing %d–%d of %d · scroll for more"):format(
      state.rankScroll + 1, math.min(total, state.rankScroll + RANK_ROWS), total) or "")
end

local function renderStandingsTab()
  -- ⚠️ NO PANE ON THIS TAB. The design puts the table straight on the window
  -- ground; the purple surface belongs to the Loot tab's detail pane and drawing
  -- it here would box the table in a panel the design does not have.
  showPaneSurface(false)
  showLootPaneParts(false)
  setHeaders()
  frame.more:SetText("")
  frame.note:SetText("")
  hideRows(1)
  renderStandingsList()
end

--- The runner's own view: who is running loot, what is loaded, who is reporting.
---
--- RENDERING ONLY. Every fact here comes from Comms.RunnerReport(), which lives
--- in Comms.lua so the headless harness can test it — this function decides
--- nothing and computes nothing.
--- The runner's own view, built from Jason's mock: a rail of state on the left,
--- the detail that matters on a raid night on the right.
---
--- RENDERING ONLY. Every fact comes from Comms.RunnerReport(), which lives in
--- Comms.lua so the headless harness can test it — this decides nothing.
local function renderRunner()
  setHeaders()
  showPaneSurface(false)
  showLootPaneParts(false)
  frame.itemName:Hide()
  frame.itemSub:Hide()
  hideRows(1)

  local R = frame.rn
  local r = ns.Comms and ns.Comms.RunnerReport()
  for _, w in ipairs(R.all) do w:Show() end

  if not r then
    R.status:SetText("COMMS DID NOT LOAD")
    if ns.Style then R.status:SetTextColor(ns.Style.rgb(ns.Style.COLOR.darkOrange)) end
    for _, w in ipairs(R.all) do if w ~= R.status then w:Hide() end end
    return
  end

  local S = ns.Style

  -- ── Rail: who is running loot ─────────────────────────────────────────────
  -- ⚠️ THREE STATES, NOT TWO. "You", "somebody else", and "nobody has claimed
  -- it" are genuinely different situations wanting different actions, and the
  -- third is the one that reads as broken if it is collapsed into the second.
  if r.runnerIsMe then
    R.status:SetText("YOU ARE RUNNING LOOT")
    if S then R.status:SetTextColor(S.rgb(S.COLOR.green)) end
    -- Only OUR claim has a local start time; see the note on claimAt.
    R.since:SetText(r.claimAt and ("Since %s"):format(date("%I:%M %p", r.claimAt):gsub("^0", ""))
      or "")
  elseif r.runner then
    R.status:SetText(("%s IS RUNNING LOOT"):format(r.runner:upper()))
    if S then R.status:SetTextColor(S.rgb(S.COLOR.text)) end
    R.since:SetText("")
  else
    R.status:SetText("NOBODY IS RUNNING LOOT")
    if S then R.status:SetTextColor(S.rgb(S.COLOR.darkOrange)) end
    R.since:SetText("")
  end

  -- ── Rail: tonight's data ──────────────────────────────────────────────────
  -- ⚠️ IMPORTED AND SYNCED ARE DIFFERENT NUMBERS and are never conflated: the
  -- stamp is when the SITE built the export, the gear age is how old the OLDEST
  -- audit inside it is. An export made seconds ago can be built entirely from
  -- day-old gear, and reporting one as the other is a claim the runner has no
  -- way to check.
  if r.hasPayload then
    R.raiders:SetText(("%d Raiders"):format(r.raiders or 0))
    R.ranked:SetText(("%d Ranked"):format(r.ranked or 0))
    R.imported:SetText(r.importedAge and ("Imported %s"):format(r.importedAge) or "")
    R.synced:SetText(r.gearAge and ("Gear synced %s"):format(r.gearAge) or "")
  else
    R.raiders:SetText("No import")
    R.ranked:SetText("")
    R.imported:SetText("Paste a raid night to rank the roster.")
    R.synced:SetText("")
  end

  -- ── Column: what being the runner means ───────────────────────────────────
  if r.runnerIsMe then
    R.lead:SetText("The raid follows your rankings.")
    if S then R.lead:SetTextColor(S.rgb(S.COLOR.green)) end
    R.leadSub:SetText("Late joiners get the roster from you. To hand over, another "
      .. "officer imports a newer export.")
  elseif r.runner then
    R.lead:SetText(("%s is ranking tonight's loot."):format(r.runner))
    if S then R.lead:SetTextColor(S.rgb(S.COLOR.text)) end
    R.leadSub:SetText("Everyone shows their ranking, so the raid sees one list. Import "
      .. "a newer export to take over.")
  else
    R.lead:SetText("Nobody has claimed loot tonight.")
    if S then R.lead:SetTextColor(S.rgb(S.COLOR.darkOrange)) end
    R.leadSub:SetText("Whoever imported the roster is answering for now. Press Run Loot "
      .. "Tonight to make it explicit.")
  end

  -- ⚠️ THE ONE STATE WHERE EVERY OTHER LINE LOOKS HEALTHY. A payload pasted
  -- before comms loaded cannot be re-sent at all: full roster, correct
  -- rankings, and nothing reaches anybody. It replaces the lead rather than
  -- sitting under it, because it makes the lead untrue.
  if r.rawStatus == "legacy" and r.rawProblem then
    R.lead:SetText("This roster cannot be shared.")
    if S then R.lead:SetTextColor(S.rgb(S.COLOR.darkOrange)) end
    R.leadSub:SetText(r.rawProblem)
  end

  -- ── Column: who else is running the addon ─────────────────────────────────
  local peers = r.peers or {}
  R.peersHead:SetText(#peers > 0 and "Who is running the addon:" or "")
  for i = 1, RN_PEER_ROWS do
    local row, p = R.peers[i], peers[i]
    if not p then
      row.name:SetText(""); row.ver:SetText(""); row.gear:SetText("")
    elseif i == RN_PEER_ROWS and #peers > RN_PEER_ROWS then
      -- The last slot becomes the overflow line rather than silently dropping
      -- the tail.
      row.name:SetText(("and %d more"):format(#peers - RN_PEER_ROWS + 1))
      if S then row.name:SetTextColor(S.rgb(S.COLOR.textDim)) end
      row.ver:SetText(""); row.gear:SetText("")
    else
      setTextForce(row.name, p.name or "?")
      -- Class colour where we know the class. Roster.IdentityFor is the seam
      -- that already answers "who is this" from whatever source has an answer;
      -- an unknown name stays plain white rather than being coloured on a guess.
      local ident = ns.Roster and ns.Roster.IdentityFor and ns.Roster.IdentityFor(p.name)
      local cc = ident and ident.class and CLASS_COLOR[ident.class]
      if cc then row.name:SetTextColor(cc[1], cc[2], cc[3])
      elseif S then row.name:SetTextColor(S.rgb(S.COLOR.text)) end
      row.ver:SetText(tostring(p.version or "?"))
      -- ⚠️ "gear live" IS NOT "they are here". Someone can be running the addon
      -- and still be ranked from the site snapshot; those are different states
      -- with different fixes, so they get different words.
      row.gear:SetText(p.gearLive and "gear live"
        or (p.versionDiffers and "different build" or "no gear yet"))
    end
  end

  -- ── Column: who is NOT reporting ──────────────────────────────────────────
  local missing = r.notReporting or {}
  if #missing > 0 then
    R.missHead:SetText(("Not Reporting: %d of %d"):format(#missing, r.totalGear or #missing))
    local names = {}
    for i = 1, math.min(5, #missing) do names[#names + 1] = missing[i] end
    local text2 = table.concat(names, ", ")
    if #missing > 5 then text2 = text2 .. (" and %d more"):format(#missing - 5) end
    R.missBody:SetText(text2 .. " — ranked from the site snapshot.")
  else
    R.missHead:SetText("Everyone is reporting gear.")
    R.missBody:SetText("")
  end

  -- ── Column: spec disagreements ────────────────────────────────────────────
  -- REPORTED, NEVER ACTED ON. An observed spec must not override the roster's —
  -- that rule exists because a live observation once mis-scored a healer as DPS.
  local mism = r.specMismatches or {}
  if #mism > 0 then
    R.specHead:SetText(("Spec Differs from the Roster: %d"):format(#mism))
    local m = mism[1]
    local line = ("%s — Roster says %s, seen as %s."):format(
      m.name or "?", tostring(m.roster), tostring(m.observed))
    if #mism > 1 then line = line .. (" (+%d more)"):format(#mism - 1) end
    R.specBody:SetText(line .. " Scored as the roster says; fix it on the site.")
  else
    R.specHead:SetText("")
    R.specBody:SetText("")
  end
end

-- ---------------------------------------------------------------------------
-- Interaction
-- ---------------------------------------------------------------------------

function Panel.Scroll(delta)
  state.rankScroll = math.max(0, state.rankScroll + delta)
  Panel.Refresh()
end

function Panel.ScrollColumn(delta)
  state.colScroll = math.max(0, state.colScroll + delta)
  Panel.Refresh()
end

--- Show the tabs that apply right now.
---
--- ⚠️ THE RUNNER TAB RENDERS ONLY FOR THE RUNNER (Session 249). Hiding is
--- HYGIENE, not a gate — the addon's data is a Lua table in the player's own
--- memory — and the real gate is the protocol rule that only a client which
--- IMPORTED the export may hold the role. But a tab that disappears mid-session
--- must SAY who took over and move the viewer to Loot; a silent vanish is the
--- exact failure being fixed everywhere else.
local function layoutTabs()
  local runner = ns.Comms and ns.Comms.IsRunner and ns.Comms.IsRunner()
  -- ⚠️ NO LADDER WITHOUT A RAID NIGHT (Jason, Session 254). Standings IS the
  -- EPGP ladder, which arrives only in the export — so with nothing imported the
  -- tab opens on an empty table and a rail of dashes. That is every install
  -- outside this guild, where the whole EPGP half is meaningless while the
  -- scoring half works in full. Same reason the standing block hides in the
  -- header; the two must agree or one of them is lying about the other.
  local standings = ns.Payload.Current() and true or false
  local visible = {}
  for _, name in ipairs(TABS) do
    local show = true
    if name == "Runner" then show = runner
    elseif name == "Standings" then show = standings end
    if show then visible[#visible + 1] = name else frame.tabs[name]:Hide() end
  end

  -- Follows the Runner tab's rule: a tab that disappears under you must SAY so
  -- and move you somewhere real, never vanish and leave the pane blank.
  if state.tab == "Standings" and not standings then
    state.tab = "Loot"
  end

  if state.tab == "Runner" and not runner then
    local r = ns.Comms and ns.Comms.RunnerReport and ns.Comms.RunnerReport()
    local who = r and r.runner
    ns.Print(who
      and ("%s is running loot now — moved you back to Loot."):format(who)
      or "You are no longer running loot — moved you back to Loot.")
    state.tab = "Loot"
  end

  for i, name in ipairs(visible) do
    local b = frame.tabs[name]
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", PAD + (i - 1) * TAB_PITCH, -TAB_Y)
    if b.SetPillState then b:SetPillState(name == state.tab) end
    b:Show()
  end
end

local function renderFooterGear()
  local S = ns.Style
  local gear = ns.GearReportingSummary()
  local mine = ns.Comms and ns.Comms.gear
    and ns.Comms.gear[ns.Comms.Normalize((UnitName("player") or ""))]
  local live = mine and next(mine) ~= nil

  if S then
    frame.gearLine1:SetText(("Your Gear: %s%s|r"):format(
      S.code(live and S.COLOR.target or S.COLOR.grey), live and "LIVE" or "SNAPSHOT"))
  else
    frame.gearLine1:SetText("Your Gear: " .. (live and "LIVE" or "SNAPSHOT"))
  end
  -- ⚠️ TWO DIFFERENT QUESTIONS ON ONE LINE, deliberately (Jason, Session 253).
  -- "Reporting" is who else is running this addon; it stays 0 among strangers
  -- however well the sweep goes, and was being read as inspection progress
  -- because nothing else showed that. "Inspected" is the sweep — it is the line
  -- that answers "has everyone been read yet", and it goes quiet once there is
  -- nobody left to ask.
  local base = gear
    and ("%d of %d Reporting"):format(gear.reporting, gear.total)
    or "No raid data imported"
  local sweep = ns.InspectionSummary and ns.InspectionSummary()
  if sweep then
    base = base .. ("  ·  %d of %d Inspected"):format(sweep.resolved, sweep.here)
  end
  frame.gearLine2:SetText(base)
end

function Panel.Refresh()
  if not frame or not frame:IsShown() then return end

  layoutTabs()

  -- Rows are RECYCLED across views, so anything one view sets has to be cleared
  -- here or it bleeds into the next. An item icon left on a raider row is the
  -- visible half; a stale itemID is the dangerous half, because it would make
  -- right-click flag whatever the row used to be.
  for i = 1, RANK_ROWS do
    local row = frame.rows[i]
    row.name:SetWidth(100)
    row.icon:Hide()
    row.itemID, row.link, row.meta = nil, nil, nil
    row.splitName, row.splitHelp = nil, nil
    row.srcHelp, row.srcName = nil, nil
  end

  local onLoot = state.tab == "Loot"
  local onRunner = state.tab == "Runner"
  local onStandings = state.tab == "Standings"

  -- The boss strip, the context line and the two filter toggles belong to the
  -- Loot tab: on the others they would offer navigation that changes nothing.
  frame.strip:SetShown(onLoot)
  frame.stripMore:SetShown(onLoot)
  frame.bossName:SetShown(onLoot)
  frame.bossSub:SetShown(onLoot)
  for _, b in ipairs({ frame.togDrops, frame.togTable, frame.togUsable, frame.togAll }) do
    b:SetShown(onLoot)
  end
  frame.col:SetShown(onLoot)
  frame.colEmpty:SetShown(false)
  frame.colMore:SetShown(onLoot)
  if not onLoot then
    for i = 1, COL_ROWS do frame.itemRows[i]:Hide() end
    -- Dropped with the list it describes. A stale cache would let the Post
    -- button act on an item that is no longer on screen.
    Panel._entries = nil
  end

  if onLoot and frame.togDrops.SetPillState then
    frame.togDrops:SetPillState(state.source == "drops")
    frame.togTable:SetPillState(state.source == "table")
    frame.togUsable:SetPillState(state.filter == "usable")
    frame.togAll:SetPillState(state.filter == "all")
  end

  -- The Standings tab's own furniture. The provisional switcher that used to
  -- live here is gone: the design has no such control, and the personal card it
  -- offered is now the rail down the left.
  frame.standingsView:Hide()
  frame.instDrop:Hide()
  frame.encDrop:Hide()

  -- The difficulty control belongs to the Loot tab; the Standings design puts
  -- the season in that space. Closing the menu with it matters — a TOOLTIP-strata
  -- list left open would hang over whichever tab you moved to.
  frame.diff:SetShown(onLoot)
  if not onLoot then frame.diffMenu:Hide() end
  if onLoot then
    local cur = ns.Settings and ns.Settings.Get("difficulty") or "AUTO"
    if cur == "AUTO" then
      -- AUTO SAYS WHAT IT RESOLVED TO. "Auto" alone leaves the actual question
      -- — which difficulty am I looking at — unanswered, which is the complaint
      -- that brought this control back.
      local key = ns.DifficultyKey()
      setLabel(frame.diff, ("Auto: %s"):format(
        ({ n = "Normal", h = "Heroic", m = "Mythic" })[key] or "?"))
    else
      setLabel(frame.diff, DIFF_LABEL[cur] or cur)
    end
    for i, choice in ipairs(DIFF_CHOICES) do
      local item = frame.diffItems[i]
      if ns.Style then
        item.label:SetTextColor(ns.Style.rgb(choice == cur
          and ns.Style.COLOR.orange or ns.Style.COLOR.text))
      end
    end
  end

  -- The Vault toggle rides with the difficulty control, but only once a content
  -- choice has actually been made and only if the payload knows the levels.
  if frame.vault then
    frame.vault:SetShown(onLoot and ns.VaultShown())
    -- Re-read rather than trust the widget: the setting is also reachable from
    -- the Settings window, and the two must never disagree on screen.
    frame.vault:SetChecked(ns.VaultOn())
  end

  -- ⚠️ SHOWN ON RUNNER AS WELL AS STANDINGS (Session 252). The Runner mock puts
  -- the season in the same top-right slot; only the Loot design leaves it empty,
  -- because that is where its content control sits.
  frame.season:SetShown(onStandings or onRunner)
  frame.stDiv:SetShown(onStandings)
  frame.stList:SetShown(onStandings)
  frame.stNote:SetShown(onStandings)
  for _, h in ipairs(frame.stHead) do h:SetShown(onStandings) end
  for _, b in ipairs(frame.rail) do
    for _, key in ipairs({ "head", "big", "bigSuffix", "line1", "line2", "line3" }) do
      b[key]:SetShown(onStandings)
    end
  end
  if not onStandings then
    for i = 1, ST_ROWS do frame.stRows[i]:Hide() end
  end
  if onStandings or onRunner then
    local raid = ns.Payload.Current()
    frame.season:SetText(raid and raid.seasonName or "")
  end

  clearPane()

  if onLoot then
    renderLoot()
  elseif onRunner then
    renderRunner()
  else
    renderStandingsTab()
  end

  -- POST IS RUNNER-ONLY. Two people posting puts two different lists in raid
  -- chat for one item, and chat is the only thing a non-installer ever sees.
  frame.post:SetShown(onLoot and (ns.Comms and ns.Comms.IsRunner and ns.Comms.IsRunner())
    and Panel.CurrentItemID() ~= nil)

  frame.runToggle:SetShown(onRunner)
  frame.autoPost:SetShown(onRunner)
  if not onRunner then
    for _, w in ipairs(frame.rn.all) do w:Hide() end
  end
  if onRunner then
    -- The mock's two fills. Auto-post is a STATE (green when it will fire), the
    -- claim toggle is an ACTION, so they are deliberately not the same colour.
    if ns.Style and frame.autoPost.SetPillColor then
      local auto = ns.Settings and ns.Settings.Get("autoPost")
      frame.autoPost:SetPillColor(auto and ns.Style.COLOR.green or ns.Style.COLOR.elevated)
    end
    if ns.Style and frame.runToggle.SetPillColor then
      frame.runToggle:SetPillColor(ns.Style.COLOR.darkOrange)
    end
    -- Labelled by what pressing it DOES, and keyed on the same fact the panel
    -- text is keyed on so the two can never contradict each other.
    local claimed = ns.Comms and ns.Comms.HasExplicitClaim()
    setLabel(frame.runToggle, claimed and "Stop Running Loot" or "Run Loot Tonight")
    local auto = ns.Settings and ns.Settings.Get("autoPost")
    setLabel(frame.autoPost, auto and "Auto-Post: On" or "Auto-Post: Off")
    if frame.autoPost.SetPillState then frame.autoPost:SetPillState(auto and true or false) end
  end

  renderFooterGear()
end

function Panel.Show()
  if not frame then build() end
  -- ⚠️ THE OPENING LIST DEPENDS ON WHERE YOU ARE STANDING (Jason). Inside a raid
  -- the question is what dropped — and an empty drops list is still information
  -- there, because something is going to arrive. Anywhere else it is what CAN
  -- drop, since nothing ever will. Re-evaluated on every open, so a toggle made
  -- during a session sticks until the panel is closed.
  state.source = ns.DefaultLootSource()
  state.sel, state.colScroll, state.rankScroll = 1, 0, 0
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
