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
-- ⚠️ SLOTS SITS SECOND, WHERE THE MOCK PUTS IT — between Loot and Standings,
-- not appended at the end. The two planning surfaces (what dropped, what you
-- are chasing) belong beside each other; Standings and Runner are the two that
-- come and go, and a tab that can disappear should not sit between two that
-- cannot. Its rendering lands with the Slots build; until then it draws empty.
local TABS = { "Loot", "Slots", "Standings", "Runner" }

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

-- ⚠️ THE FRAME GREW AGAIN (Session 261): 620x560 -> 740x600 -> 800x600. The left
-- margin stays 40, so the RIGHT EDGE moves 700 -> 760 and every right-aligned
-- constant below moves with it. Every coordinate here is read off the redesign's
-- frame as an OFFSET FROM ITS TOP-LEFT, which is why they can be checked against
-- Figma by subtracting the frame's own origin and nothing else.
local FRAME_W, FRAME_H = 800, 600

local PAD = 40

-- The tab row. There is no PITCH any more and that is the point: each tab is as
-- wide as its own label plus the control's padding, so they are laid out with a
-- GAP between them (Style.LayoutRow). A pitch would have to assume every label
-- is the same length, which is what made STANDINGS the widest tab in the mock.
local TAB_Y, TAB_GAP = 82, 10

-- The header lockup's artwork corner. The texture itself is larger; see
-- Style.Lockup for why the caller anchors the ink rather than the file.
local LOGO_X, LOGO_Y = 40, 30

-- ── The left column (Session 257) ──────────────────────────────────────────
--
-- ⚠️ THE BOSSES ARE A VERTICAL RAIL NOW, NOT A HORIZONTAL PORTRAIT STRIP, and
-- they share ONE 200-wide column with the item cards: bosses at the top, the
-- selected boss's loot beneath them, both scrolling. That is the redesign's
-- defining change to this tab and the reason the old strip's numbers are gone
-- rather than retuned — a right-aligned row of tiles has no counterpart here.
--
-- ⚠️ THE ROW AND ITS ICON BOTH SHRANK (Session 261): 37 -> 29 and 28 -> 20.
-- Jason: the round icons come down "to compress vertical space", and with the
-- chips gone from the item cards this is where the refresh buys its room. The
-- last row is 28 and drops its bottom rule — the same one-pixel tell as before.
-- The column also WIDENS, 200 -> 275.
-- ⚠️ 171, NOT 167 (Session 262). Node 625:202 puts the column's top four below
-- where it was built, which the eye reads as the whole list riding high against
-- the filter row above it.
local BOSS_X, BOSS_TOP, BOSS_W = 40, 171, 275
local BOSS_ROW_H, BOSS_ICON = 29, 20
-- The column's content height, bosses and item cards together.
local COL_AREA_H = 355
-- Icon inset 4, name at 34 (4 + 20 + a 10 gap), and the name is CENTRED in the
-- row now rather than pinned 12 down: a 12-tall line in a 29-tall row sits at 8,
-- and it is given that height explicitly so the client centres it in a known
-- rect rather than in whatever its line box happens to be (Core §1.1, S260).
local BOSS_ICON_X, BOSS_NAME_X, BOSS_TEXT_Y = 4, 34, 8
local BOSS_SLOTS = 9

-- The item cards sit DIRECTLY BENEATH the last boss row, so their top is not a
-- constant — it follows however many bosses the season has. COL_TOP is the
-- fallback for a client with no boss list at all.
local COL_X, COL_W, COL_TOP = BOSS_X, BOSS_W, BOSS_TOP
-- A card is 61 tall with a 2px gap to the next; the SELECTED card measures 62,
-- the same one-pixel tell the rail uses — its own rule is not drawn. Inside: 10
-- of padding either side, the name and slot line as one 29-tall block at y 8,
-- and the chip row at y 39.
-- ⚠️ THE CARD LOST A ROW (Session 261): 61 -> 45, pitch 63 -> 47. The chip row
-- is gone entirely — what it carried is now inline on the slot line as
-- colour-coded text ("Back, Cloth • MAJOR • O-BIS • TARGET"), so a card is two
-- lines instead of two lines plus a row of boxes.
-- It is also INDENTED to the boss name rather than filling the column: 241 wide
-- starting at 34, which lines the cards up under the text they belong to.
local ITEM_H, ITEM_PITCH = 45, 47
-- Grouped for the same 200-locals reason as DET above.
local CARD = {
  -- x/w live IN this table rather than as two more top-level locals: Panel.lua
  -- sits near Lua 5.1's ceiling of 200 (Core §1.1), and that ceiling is what
  -- refused an earlier version of this very change.
  x = 34, w = 241,
  padX = 10, nameY = 8, slotY = 22,
  -- ⚠️ chipY AND chipGap ARE GONE. Kept as a comment rather than a stale key:
  -- a card that still positions a chip row draws an empty band of nothing.
}

-- The filter row, above the column. Each piece carries its own x because the
-- mock places them individually — the two rows have very different label
-- lengths and still line up, which a shared pitch could not reproduce.
local TOG = {
  y = 132, trackY = 131,
  srcL = 40,  srcTrack = 129, srcR = 169,
  filL = 296, filTrack = 372, filR = 412,
}

-- The detail column. NO PANEL BEHIND IT — the mock puts it on the window ground
-- and separates it with hairlines, so these are the bounds of a region rather
-- than of a box that gets drawn.
local PANE_X, PANE_Y, PANE_W, PANE_H = 340, 177, 420, 360

-- The bottom bar. Its own margins are NOT the window's — the mock insets its
-- text 47 from the left and stops the button row 34 from the right, where the
-- body above uses 40 on both sides. Written as read rather than rounded to PAD:
-- these are the file's numbers, and squaring them up is a change to the design
-- rather than a tidy-up of the code.
local FOOT_Y, FOOT_H = 550, 50
local FOOT = {
  -- ⚠️ right IS 40, NOT 34 (Session 262). Re-read on all three Loot frames: the
  -- button row ends at 760 on the 800-wide ones and 764 on the 804 stray, which
  -- is a 40 margin in both — the SAME margin the body uses, not a different one.
  -- The old comment here claimed 34 and that was a misreading, not a design.
  textX = 47, right = 40, gap = 10,
  -- Two 16-tall line boxes stacked inside the node's own 32-tall block.
  line1Y = 10, line2Y = 26,
  -- The button row's own top inset inside the bar (3344 - 3333).
  btnY = 11,
}

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
-- ⚠️ READ OFF THE NODE (Session 257). It was at x 460 on a 620-wide window and
-- never moved when the frame grew; the mock puts it at 577, which is 123 wide
-- ending 40 from the right edge — the same margin as the tab row's left. Its y
-- is 82, the SAME LINE as the tabs, so the row reads as one band of controls.
-- The Vault checkbox sits ABOVE it at 56, left edges flush.
local DIFF_X, DIFF_Y, DIFF_W, DIFF_H = 637, 82, 123, 27
-- The caret: a 6x6 triangle, 14 in from the control's right edge.
local DIFF_CARET, DIFF_CARET_R = 6, 14
-- The checkbox: a 16x16 box at 56, its label 22 across (box plus a 6 gap).
local VAULT_Y, VAULT_BOX, VAULT_LABEL_X = 56, 16, 22
-- Gap between the Vault/Voidcore checkbox and the difficulty control it now sits
-- ABOVE, right edges aligned.
--
-- ⚠️ MOVED IN SESSION 254, AND THE OLD BUDGET IS GONE WITH IT. It used to sit on
-- the TAB ROW, growing leftwards from the dropdown's left edge into 108px of
-- clearance — which the comment here measured carefully and which turned out not
-- to hold: Jason saw it overlapping the Runner tab, two mouse-enabled frames on
-- the same pixels, exactly the failure the measurement was meant to prevent.
-- Rather than re-measure a budget that was already too tight to be worth
-- defending, the control moved above the dropdown, where the width available is
-- the whole panel. THIS IS ALSO WHERE THE FIGMA FRAME PUTS IT (Jason) — the
-- previous position was never the design's.
--
-- A LABEL MAY NOW GROW without threatening anything, which is the real gain: the
-- tab row gains a fourth tab in the mock ("Slots") and would have collided again.
local VAULT_GAP = 10

-- ── Slots tab (Session 258, from Jason's mocks 591:2198 + 591:2205) ────────
--
-- Every number is a node position minus the frame's own origin (1684, 1435 for
-- the single-item frame; 1684, 2109 for the multi-item one), so any of them can
-- be checked against Figma by subtracting and nothing else.
--
-- ONE TABLE, not thirty file-scope locals, for the reason Session 250 learned
-- the expensive way: build() closes over every constant it names and Lua 5.1
-- refuses a function with more than 60 upvalues. The tab's builder is its own
-- function for the same reason, matching Standings and Runner.
--
-- ⚠️ THE TWO MOCKS ARE ONE PAGE IN TWO STATES, not two designs. The rail, the
-- caption, the dropdown and the footer are identical in both; what differs is
-- only what fills the right-hand region.
local SL = {
  -- The rail. 14 rows, 29 tall, and the LAST is 26 because it drops its bottom
  -- rule — the same one-pixel tell the boss rows and the item cards use.
  -- ⚠️ THE RAIL IS 180 AND THE ROW READS LEFT TO RIGHT (Session 262). It was
  -- 150 wide with the label RIGHT-aligned BEFORE the icon; node 590:1960 puts
  -- the 20px icon first at x 0, a 10 gap, then the label. This change was
  -- catalogued in the Session 261 notes and never built.
  railX = 40, railY = 129, railW = 180, rowH = 29, lastRowH = 26,
  -- Icon, gap, then a left-aligned label 26 tall so it centres in the row.
  iconX = 0, iconSize = 20, labelX = 30, labelH = 26,
  -- ⚠️ TWO CHECKS, RIGHT-ALIGNED, AND THE GREEN ONE IS THE RIGHTMOST (Jason,
  -- Session 262: "un-acquired pieces have grey checkmarks and they turn green
  -- when they've been acquired"). Every row shows one per socket — so Finger
  -- and Trinket show two — and the 10px right padding puts the outer one at
  -- 160..170 with the second 10 to its left. This REPLACES the old single
  -- check drawn at half alpha for the one-of-two case.
  checkX = 160, checkX2 = 140, checkW = 10, checkH = 7,

  -- The caption and the view dropdown, both on the tab row's band.
  capR = 760, capY = 48,
  -- Node 590:2050: 115 wide at 645, not 111 at 646 (Session 262).
  viewX = 645, viewY = 82, viewW = 115, viewH = 27,
  caret = 6, caretR = 14,

  -- The right-hand region, shared origin, two layouts.
  paneX = 250, paneW = 500,

  -- ⚠️ THE ITEM ICON, ADDED SESSION 259 (Jason: "it was oddly confusing without
  -- it"). 32px, the same size the Loot page's selected item dropped to in the
  -- same edit — one item icon, one size, everywhere it appears.
  --
  -- textX IS THE GUTTER IT OPENS. Every text run on both layouts moved right by
  -- 42: the name, the source line and the "Tier Piece" kind line. The chips are
  -- unaffected because they are right-aligned to the pane's far edge.
  itemIcon = 32, textX = 42,

  -- SINGLE-ITEM: an identity line, then the OBTAINED BY panel beneath it.
  --
  -- ⚠️ ONE LINE, NOT TWO (Session 262, node 591:2187). The block is 32 — the
  -- icon's own height — holding a single 19-tall line centred against it at 6.
  -- The second line ("Tier Piece") is GONE: the refresh carries that fact as a
  -- TIER PIECE tag on the line itself, so the kind line was printing the same
  -- thing twice, once as a tag and once as a sentence.
  headY = 141, headBlockH = 32, headNameH = 19, headNameY = 6,

  -- ⚠️ THE OBTAINED BY PANEL IS INDENTED TO THE TEXT COLUMN, NOT THE ICON
  -- (node 590:2055, re-read Session 259). It sits at 272 and is 428 wide, so
  -- its left edge lines up under the item's NAME rather than under its icon,
  -- and its right edge still lands on the pane's. It was drawn full-width from
  -- paneX before the icon existed, which now reads as the panel hanging out
  -- past the block it belongs to.
  -- ⚠️ 294 AND 465 (Session 262, re-read from node 590:2055). It was at 272 and
  -- 428, which was the pre-refresh geometry — the panel's right edge still lands
  -- on the pane's, but its left now sits under the item icon's own gutter.
  panelX = 294, panelW = 465, panelY = 186,
  -- The panel's own box: 14 above the heading, 20 below the last route, and 10
  -- of gap between blocks. A 2-route panel measures 137, which is the mock's.
  panelPadT = 14, panelPadB = 20, panelPadX = 20,
  -- ⚠️ A ROUTE CARRIES ITS OWN ITEM ICON NOW (Session 262, Jason: "note the
  -- addition of the item icons"). 32px, the same icon every other surface
  -- draws, with the same 42 gutter the identity line opens.
  -- ⚠️ THE TWO TEXT LINES CARRY EXPLICIT HEIGHTS AND THE PAIR IS CENTRED
  -- AGAINST THE ICON (Jason, Session 262: "the item icons are not vertically
  -- centered/lined up with the text"). Neither line had a height, so each drew
  -- wherever its own line box landed and "centred against a 32px icon" was
  -- never arithmetic anyone did. Two 14-tall lines stack to 28 inside the
  -- block's 32, so the pair starts at 2 and both centres land on 16.
  headingH = 19, blockGap = 10, blockH = 32,
  routeLineH = 14, routeTextY = 2, routeLineY = 16,

  -- MULTI-ITEM: a flat list of candidates, each 55 tall with a 10px top inset.
  -- The icon sits at 11, one below the text block, on the same centre line.
  --
  -- ⚠️ 131, NOT THE MOCK'S 129 (Session 260, Jason: the icon and the text "move
  -- a few pixels up or down" when the OBTAINED BY box appears and disappears).
  -- THE TWO MOCKS DISAGREE, and the code was faithfully reproducing both. Read
  -- back from the nodes: the single-item block (591:2187) sits at 141 with its
  -- icon at 142 and its second line at 159; the multi-item list (591:2199) puts
  -- the equivalents at 139, 140 and 157. Everything else on the two frames —
  -- rail, tabs, caption, dropdown, footer — is identical to the pixel, which is
  -- what makes this drawing drift between two frames rather than intent. This
  -- box's own header already says the two are ONE PAGE IN TWO STATES.
  --
  -- The LIST moves rather than the block, because every number in the single
  -- layout is load-bearing against its neighbours: the icon is centred in a
  -- 34-tall two-line block and the OBTAINED BY panel is anchored under it at
  -- 186, read from its own node. Shifting that costs four constants and moves
  -- the panel off the position its node states. Shifting the list costs one,
  -- and lands all three elements exactly on the block's: name 141, icon 142,
  -- second line 159. slotNote derives from listY and follows for free.
  -- ⚠️ RE-READ FROM NODE 626:507 (Session 262). The list starts at 141 — the
  -- SAME y as the single-item block, which is what the Session 260 note was
  -- reaching for by shifting it to 131 against a head that has since become one
  -- line. Rows: icon at 1, the name at the row's top, the source 14 under it,
  -- and a 52 pitch (a 32 block with 20 between).
  --
  -- THE TWO LAYOUTS NO LONGER PUT THEIR FIRST LINE ON THE SAME PIXEL, and that
  -- is the design's: the head is ONE line centred in 32, the list row is a TWO
  -- line block starting at its top. What does not move between them is the
  -- ICON, 141 against 142, which is the element the eye tracks.
  -- ⚠️ THE LIST ROW IS THE SAME BLOCK AS AN OBTAINED BY ROUTE (Session 262).
  -- Node 626:482 is `items-center` with a 32 icon and a two-line text block, so
  -- it takes the identical arithmetic: icon at 0, two 14-tall lines starting at
  -- 2, both centres on 16. It had no explicit heights at all, which is the same
  -- fault Jason caught on the routes.
  listY = 141, listPitch = 52, listNameY = 2, listSourceY = 16, listIconY = 0,
  listRows = 7, routeRows = 4,

  chipH = 15, chipGap = 6,
}

-- The separator between two list items, halfway down the space BETWEEN their
-- blocks rather than at the bottom of the row that owns it. A block is the
-- icon's own height, so the gap runs blockH..listPitch and this is its middle.
-- Derived rather than typed: the two numbers it sits between have both moved
-- twice this session.
SL.listRuleY = SL.blockH + math.floor((SL.listPitch - SL.blockH) / 2)

-- ── Runner tab — RE-READ FROM NODE 589:1735 (Session 258) ──────────────────
--
-- ⚠️ EVERY NUMBER MOVED, for the same reason Standings did: this was built
-- against the pre-redesign window and never re-read when the frame grew. The
-- rail was 120 wide at x20 against the mock's 180 at x40, and the column began
-- at 178 against 260. Numbers are node positions minus the frame's origin
-- (2558, 2109).
--
-- ⚠️ THE FULL-HEIGHT HAIRLINE IS GONE, exactly as on Standings: the rail's two
-- blocks are FILLED SURFACES now, so a vertical rule beside them is a second
-- separator doing the first one's job. Its three HORIZONTAL rules stay — those
-- separate sections within the column, which is a different job.
local RN_RAIL_X      = 40
local RN_RAIL_W      = 180
local RN_PAD         = 10
-- Two blocks, 10 apart. The first is 73 and the second 93 — each as tall as its
-- own content, like the Standings rail.
local RN_STATUS_BLOCK_Y, RN_STATUS_BLOCK_H = 129, 73
local RN_DATA_BLOCK_Y,   RN_DATA_BLOCK_H   = 212, 93
-- Inside the status block: two 16px lines of Bold 14, then the "since" line.
local RN_STATUS_Y    = 139    -- "YOU ARE RUNNING LOOT", wraps to two lines
local RN_SINCE_Y     = 171
-- Inside the data block. The two age lines are 9px, which is smaller than
-- anything else in the panel and is what the node says.
local RN_DATA_Y      = 222    -- "TONIGHT'S DATA"
local RN_RAIDERS_Y   = 236
local RN_RANKED_Y    = 254
local RN_IMPORTED_Y  = 270
local RN_SYNCED_Y    = 282
-- The two rail controls are the rail's OWN width now, not an inset 119.
local RN_AUTO_Y      = 456
local RN_TOGGLE_Y    = 493
local RN_BTN_X, RN_BTN_W, RN_BTN_H = RN_RAIL_X, RN_RAIL_W, 26

local RN_COL_X       = 260
local RN_COL_W       = 500
local RN_LEAD_Y      = 133
local RN_LEAD_SUB_Y  = 158
-- ⚠️ THE SUB-LINE IS THE COLUMN'S FULL WIDTH NOW. It used to be deliberately
-- narrowed to 259 to force a two-line wrap; the redesign gives it all 440 and
-- lets it wrap on its own, so narrowing it would break the mock's line breaks
-- rather than reproduce them.
local RN_LEAD_SUB_W  = RN_COL_W
local RN_D1_Y        = 214
local RN_PEERS_Y     = 224
local RN_PEER_TOP    = 253
local RN_PEER_PITCH  = 16
local RN_PEER_ROWS   = 4
-- Name / version / gear state. ⚠️ THE LAST TWO ARE RIGHT-ALIGNED — read off the
-- mock, where a shorter version string and a wider "older build" both end flush
-- with the rows above them. Left-aligning them puts a ragged edge down the
-- middle of the column.
local RN_PEER_NAME_X = 0
local RN_PEER_VER_R  = 191    -- 2451 - 2260
local RN_PEER_GEAR_R = 317    -- 2577 - 2260
local RN_D2_Y        = 316
local RN_MISS_Y      = 327
local RN_MISS_BODY_Y = 351
local RN_D3_Y        = 386
local RN_SPEC_Y      = 396
local RN_SPEC_BODY_Y = 420
local DIFF_CHOICES = { "AUTO", "NORMAL", "HEROIC", "MYTHIC", "MPLUS" }
local DIFF_LABEL = {
  -- ⚠️ THE PREFIX IS UPPERCASE AND THE DIFFICULTY IS NOT — "RAID: Heroic" is
  -- the node's own string on all three Loot frames (Session 262).
  AUTO = "Auto", NORMAL = "RAID: Normal", HEROIC = "RAID: Heroic",
  MYTHIC = "RAID: Mythic", MPLUS = "Dungeons",
}

-- ── Standings tab — RE-READ FROM NODE 588:1668 (Session 258) ───────────────
--
-- ⚠️ EVERY NUMBER BELOW MOVED. The tab was built against the pre-redesign
-- window and then never re-read when the frame grew to 740x600, so the rail sat
-- at x20 against the mock's 40, the table began at 203 against 231, and the row
-- pitch was 16 against 20. Restyling it from memory would have kept all of
-- that; these are node positions minus the frame's origin (2558, 1435).
--
-- ⚠️ THE VERTICAL DIVIDER IS GONE. The redesign separates the rail from the
-- table by making the rail's four blocks FILLED SURFACES — the same rule blush
-- at 10% the Slots page uses — so a hairline between them is a second
-- separator doing the first one's job.
local SEASON_R, SEASON_Y = 760, 89   -- season label, right-aligned, on the tab row
-- ⚠️ ONE TABLE, NOT EIGHT LOCALS, AND THIS IS LOAD-BEARING RATHER THAN TIDY.
-- Panel.lua sits at Lua 5.1's ceiling of 200 top-level locals — measured, with
-- luajit, at ZERO headroom — and every file-scope name added here is one the
-- GAME counts while lua5.4 does not. Grouping is how the geometry blocks below
-- (SL, TOG, CARD, FOOT) already stay affordable. Core §1.1's S250/S254 box.
local RAIL = {
  x = 40, w = 150, pad = 10,
  -- Four blocks, 18 apart, each as tall as its own content. Earned/Spent is 78
  -- because it has no 34px figure; the other three are 86.
  y = { 129, 233, 329, 433 },   -- Priority · Earned/Spent · Attendance · Last item
  h = { 86, 78, 86, 86 },
  -- Which of those carry the big 34px figure. Earned/Spent and Last Item Won
  -- do NOT, so their text lines start straight under the heading — see
  -- buildRailBlock. Keep this in step with renderRail: a block that sets `big`
  -- must be false here, or its figure and its first line collide.
  compact = { false, true, false, true },
  -- ⚠️ THE TWO BIG FIGURES ARE DIFFERENT COLOURS, easy to miss and read straight
  -- off the node: "#6" inherits the block's white, while the attendance "2" sits
  -- inside a blush run that also carries its "of 3" suffix.
  bigColor = { "white", nil, "body", nil },

  -- ⚠️ EVERY LINE'S OFFSET IS THE NODE'S OWN LEADING, NOT A DERIVED PITCH
  -- (Jason, Session 258: "the spacing is eye-watering"). The four blocks do not
  -- share a rhythm — Earned/Spent stacks two 14px figures at 21px leading while
  -- Last Item Won stacks three 11px lines at 16.5 — so one `lineY + 16` ladder
  -- spread one block out and crushed another. Offsets are from the top of the
  -- block's own box; the mock centres a content box of exactly box height minus
  -- 20, which is why every block starts at 10.
  layout = {
    { head = 10, big = 22, lines = { 56 },         lineSize = 11 },
    { head = 10,           lines = { 24, 45 },     lineSize = 14 },
    { head = 10, big = 22, lines = { 56 },         lineSize = 11 },
    { head = 10,           lines = { 24, 40, 56 }, lineSize = 11 },
  },
}
local ST_HEAD_Y = 132
local ST_TOP, ST_PITCH = 157, 20
-- ⚠️ THE MOCK DRAWS 12 ROWS AND THAT IS ILLUSTRATION, NOT A CAP — a real ladder
-- is 17 to 24 people, and stopping at 12 would leave 120px of empty window and
-- force scrolling past a screen that had room. Derived from the space the RAIL
-- occupies instead, so the table and the rail end together: WoW frames do not
-- clip their children, so a count larger than the space draws through the
-- footer rather than scrolling. FLAGGED for Jason — if 12 was deliberate, this
-- is the line to change.
local ST_ROWS = math.floor(((RAIL.y[4] + RAIL.h[4]) - ST_TOP) / ST_PITCH)
-- Name is left-aligned; every number column is right-aligned to its own edge,
-- which is also where the design puts each heading's right edge.
local ST_RANK_R, ST_NAME = 247, 271
local ST_EP_R, ST_GP_R, ST_PR_R, ST_LAST_R = 475, 549, 655, 760

-- The MOST item rows the column could ever need — when the rail is empty and
-- the cards have the whole area. How many actually DRAW is decided per refresh
-- from the space the rail leaves; building for the maximum means the answer can
-- change without anything being created mid-draw.
local COL_ROWS = math.floor(COL_AREA_H / ITEM_PITCH)

-- ── The detail column, all absolute in frame space ─────────────────────────
--
-- Every number below is a Figma node position minus the frame's own origin
-- (814, 2783), so any one of them can be checked against the file by
-- subtracting. NOTHING here is derived by eye.
--
-- ⚠️ THE HEADER IS THE ITEM NOW, NOT THREE STAT BLOCKS. The old build opened
-- with "Upgrade for You / Your Standing / Priority-EP-GP"; the mock opens with
-- the item itself — icon, name, slot line — and puts the viewer's own verdict in
-- ONE badge on the right. The standing figures moved to the Standings tab and
-- the rail, which is where a question about the ladder belongs.
-- ⚠️ A TABLE, NOT TWENTY LOCALS, AND THAT IS A HARD REQUIREMENT. Lua 5.1 — the
-- version the game runs — allows 200 local variables per chunk, and this file
-- crossed it while these were being added. The limit is per CHUNK, so grouping
-- related numbers into one table is the fix that also reads better; see the
-- Core rule about checking against the runtime's language, not the one on this
-- machine, and note that luac on this Mac accepts what the game refuses.
local DET = {
  headY   = 179,                      -- the header block, 34 tall (node 582:983)
  -- ⚠️ 32, NOT 40 (Jason, Session 259, re-read from node 577:878). It came down
  -- to match the item icon the Slots page gained in the same edit — one item
  -- icon, one size, on every surface that draws one. The name column came left
  -- with it, 313 -> 306, keeping the gutter beside a narrower icon.
  --
  -- The centring arithmetic below needs no change and that is worth noting: at
  -- 32 against a 34-tall block it resolves to -1, so the block now sits ONE
  -- ABOVE the icon's top rather than three below it, which is what the node
  -- draws (block 177..211, icon 178..210).
  iconX   = 343, iconY = 179, icon = 32,
  -- ⚠️ THE TWO-LINE BLOCK IS CENTRED ON THE ICON, NOT TOP-ALIGNED WITH IT
  -- (Jason, Session 258). Node 577:880 is 34 tall beside a 40 icon, so it sits
  -- 3 down from the icon's top and 3 up from its bottom. It was pinned to the
  -- header's top instead, which put both lines high against the artwork.
  --
  -- Heights are EXPLICIT and both lines top-justify, for the same reason the
  -- Standings rail needed it: a fontstring anchored TOPLEFT with no height
  -- draws wherever its own line box lands, so "centred" cannot be arithmetic
  -- on the anchor alone.
  -- ⚠️ RE-READ FROM THE NODE (Session 262, and all three were wrong). The name
  -- is 14 MEDIUM, not 13 Regular; the slot line is 11 Light, not 12; and each
  -- line's box is 14, not 18 over 16. The extra four pixels of leading are what
  -- Jason saw as the name block sitting loose beside its own icon — 28 of type
  -- against a 32 icon centres; 34 does not fit inside it at all.
  nameX   = 386,                      -- name (14 Medium) over slot line (11 Light)
  nameH   = 14, line2H = 14,          -- 28 together, the node's own leading
  -- The verdict badge: a 10%-blush box with the grade over the word "Upgrade".
  badgeX  = 692, badgeY = 179, badgeW = 68, badgeH = 34,
  -- ⚠️ 19, NOT 13 (Jason: "there's not enough space between MAJOR and
  -- Upgrade"). MAJOR is 16px Bold, whose line box is about 19 tall — so a 13px
  -- step put the word inside the grade's own descender space. The pair now runs
  -- 8..39 inside a 40-tall box.
  -- ⚠️ THE PAIR IS CENTRED, SO THERE IS NO TOP OFFSET ANY MORE (Session 260).
  -- badgeTop/badgeLine2 are gone: a top pin plus a line-box-sized step is what
  -- put eight pixels above the words and one below, and opened a gap between
  -- them that the design does not have. These are the VISIBLE heights of the
  -- two lines — 16px Bold and 10px Light at Manrope's 0.72 cap ratio, measured
  -- from the bundled TTF — plus the gap the design puts between them.
  -- ⚠️ THE NODE'S TWO LINES ARE BOTH 10 LEADING (Session 262), stacking to 20
  -- inside the 34 box rather than 22 — and the type is 14 Bold over 9 Light,
  -- where this was drawing 16 over 10.
  badgePadX = 10, badgeLine1H = 11, badgeLine2H = 9, badgeGap = 0,
  -- The meta band between the two rules. factsR is the RIGHT edge the facts
  -- line ends on — see the note beside DIV1_Y — and inset is how far the band
  -- is held off each rule's own end.
  factsR = 760, factsInset = 20,
}

-- TWO hairlines, not three. The mock separates header / meta / table and
-- nothing else; the old third rule under the item row has no counterpart
-- because the item row IS the header now.
-- ⚠️ RE-READ FROM NODE 627:524 (Session 262). EVERY VERTICAL BELOW THE HEADER
-- WAS TOO LOW, and by a growing amount — the rules by 9 and 12, the table by a
-- full 20 — which is what Jason saw as "too much room under the item icon/name
-- and upgrade label". The horizontals were all correct and are unchanged.
local DIV_X, DIV_W = 340, 420
local DIV1_Y, DIV2_Y = 229, 257
-- ⚠️ THE FACTS LINE IS RIGHT-ALIGNED TO THE RULES' RIGHT EDGE, not inset from
-- their left. The node sits at 420 and is 340 wide, ending at 760 — the same
-- edge the badge, the PRIORITY column and the button row all stop at. Written
-- as a right edge so the line grows LEFTWARD as it gains tags, which is what
-- the mock's longest state ("… • OVERALL BIS • TARGETED") does.
-- Grouped into DET rather than added as top-level locals: Panel.lua sits within
-- a handful of names of Lua 5.1's 200-per-chunk ceiling and the smoke harness
-- fails the moment that shrinks further (Core §1.1).

-- The ranked table.
local RANK_HEAD_Y = 279     -- RAIDER / UPGRADE / ILVL GAIN / PRIORITY
local RANK_TOP    = 300
local RANK_PITCH  = 20
local RANK_ROWS   = 9
-- Under the last row. 300 + 9 * 20 = 480, then the mock's own gap.
local MORE_Y      = 485
local NOTE_Y      = 501

-- Column x positions inside the ranked table. GAIN and PRIORITY are RIGHT
-- edges, because both are numbers and numbers align on their right — confirmed
-- against the mock, where the header and its values share an edge rather than a
-- left margin (GAIN 560+56 = 616; PRIORITY 636+54 = 690).
local C_RANK, C_NAME, C_UPGRADE = 350, 368, 472
local C_GAIN_R, C_PRIORITY_R = 676, 760

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
-- Shared with the difficulty control, which had this path inline. One string,
-- because two copies of an asset path is one of them going stale at a rename.
local CARET_TEX       = "Interface\\AddOns\\HoDLootAdvisor\\Media\\ui\\caret.png"
-- The Slots rail's tick, and the same file Style.Check already draws.
local SLOT_CHECK_TEX  = "Interface\\AddOns\\HoDLootAdvisor\\Media\\ui\\check.png"
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
-- The refresh's one separator, everywhere a run of facts or tags is joined.
-- The same U+2022 buildTagLine draws between tags, named once so the two cannot
-- drift apart.
local DOT = "\226\128\162"

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
  -- ⚠️ NIL MEANS NOTHING IS EXPANDED, and that is the OPENING state (Jason).
  -- The accordion's whole point is seeing the boss list; starting with the first
  -- boss open costs four rows of it to answer a question nobody asked yet.
  sel = 1, bossIndex = nil,
  colScroll = 0, rankScroll = 0,
  -- The two filter toggles. `source` is which list the column shows; `filter`
  -- is whether it hides what this character cannot use.
  source = "drops",     -- "drops" | "table"
  filter = "usable",    -- "usable" | "all"
  -- The Standings tab's provisional sub-view. See renderStandingsTab.
  instIndex = 1, encIndex = 1, targetMode = "browse",
  -- ── Slots tab (Session 258) ───────────────────────────────────────────────
  -- Which rail row is open, and which of the three BIS lists is being read.
  --
  -- ⚠️ SESSION-SCOPED, NOT A SETTING, and this is a decision rather than an
  -- oversight: the mock draws the dropdown and says nothing about whether the
  -- choice survives a reload. It sits beside `source` and `filter`, which are
  -- the other two view controls on this window and are session-scoped for the
  -- same reason. Promote it to Settings if Jason wants it remembered.
  slotIndex = 1, slotsView = "overall",
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

--- A horizontal rule.
---
--- ⚠️ #AC7666 AT 30%, WHICH IS `rule` (Jason, Session 258). It was the RIM
--- colour at 25% — #d9cee2, a cool lilac — and the design's rules are the warm
--- blush the title gradient ends in. Two greys that are easy to mistake for one
--- another on screen and are not the same value; the mock names the second, and
--- it is the same colour the row rules, the MINOR badge and the footer wash all
--- take. One warm colour running through the whole panel.
local function divider(parent, x, y, w)
  local S = ns.Style
  local t
  if S then
    t = S.Divider(parent, S.COLOR.rule, 0.3)
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

--- A tag line: a body run, then up to `maxTags` colour-coded tags separated by
--- a bullet — "Back, Cloth • MAJOR • O-BIS • TARGET".
---
--- ⚠️ THIS REPLACES THE CHIPS (Session 261). Jason: the outline "takes up too
--- much vertical space and was distracting", so what an outlined or filled chip
--- carried is now text. The distinction the two chip KINDS used to make — a
--- claim about this raider versus a fact about the item — is carried by COLOUR
--- alone now, which is a deliberate loss of a signal and is recorded as such in
--- rules/HoD_Rules_Loot-Gear.txt.
---
--- ⚠️ SEPARATE RUNS, BECAUSE ONE FONTSTRING HAS ONE FONT. The body is Saira
--- Light and a tag is Saira Black; a colour escape inside a single string would
--- recolour it but could not reweight it, which is the exact mistake Session 258
--- caught on the source line ("colour is not a substitute for weight"). Same
--- build-time left-to-right anchoring as buildSourceLine, so nothing measures a
--- string the client has not drawn yet.
--- `anchorTo` makes the line FLOW after another widget instead of starting at
--- an absolute x — which is what the Slots page needs, where the tags follow the
--- item's name on the same line rather than sitting in a column of their own.
--- The anchored widget must size to its own string, or its right edge is its
--- declared width and the tags start in the middle of nowhere.
local function buildTagLine(parent, x, y, maxTags, anchorTo, height)
  local g = { tags = {}, seps = {} }
  -- ⚠️ THE LEAD IS WHITE (Session 262, Jason: the card's second line "is
  -- supposed to be white, like in Figma"). Node 625:247 paints "Back, Cloth"
  -- white and reserves #606060 for the "•" separators alone — the blush this
  -- used to draw was never in the design.
  g.lead = at(text(parent, "light", "label", "white"), x, y)
  -- ⚠️ THE WHOLE LINE IS PLACED BY THE LEAD'S RECT. Every separator and tag
  -- anchors LEFT to the run before it, so all of them inherit the LEAD's
  -- vertical centre; with no height that rect IS the lead's own line box and
  -- lands wherever the font puts it (Core §1.1, S260). A caller that aligns the
  -- line against other cells in a row passes THAT ROW'S height, and the client
  -- then centres the run in a KNOWN rect. Without it the UPGRADE column sat
  -- half a row above the raider name it belongs to, while rank / name / gain /
  -- priority — the four cells that DID get a height — centred correctly.
  if height then
    g.lead:SetHeight(height)
    g.lead:SetJustifyV("MIDDLE")
  end
  if anchorTo then
    g.lead:ClearAllPoints()
    g.lead:SetPoint("LEFT", anchorTo, "RIGHT", x or 0, 0)
  end
  local prev = g.lead
  for i = 1, (maxTags or 4) do
    -- The bullet is Light and Trash Grey on every line it appears (Jason,
    -- Session 261) — never the tag's own colour, which would read as a fifth tag.
    local sep = text(parent, "light", "label", "grey")
    sep:ClearAllPoints(); sep:SetPoint("LEFT", prev, "RIGHT", 0, 0)
    local tag = text(parent, "black", "label", "white")
    tag:ClearAllPoints(); tag:SetPoint("LEFT", sep, "RIGHT", 0, 0)
    g.seps[i], g.tags[i] = sep, tag
    prev = tag
  end

  --- `lead` is the plain half; `tags` is a list of { text, color } where color
  --- is a Style.COLOR key. Written through a forced repaint for the same reason
  --- the source line is: these are recycled rows, and an unchanged string is
  --- never redrawn (Core §1.1, S254).
  function g:Set(lead, tags)
    setTextForce(self.lead, lead or "")
    local S = ns.Style
    -- ⚠️ THE BULLET IS A SEPARATOR, NOT A PREFIX. The ranking column has no lead
    -- text — it is tags alone — so emitting one before every tag would open the
    -- column with a floating "• ". Track whether anything actually precedes.
    local anything = (lead or "") ~= ""
    for i, tagFs in ipairs(self.tags) do
      local t = tags and tags[i]
      if t and t.text and t.text ~= "" then
        setTextForce(self.seps[i], anything and " • " or "")
        anything = true
        setTextForce(tagFs, t.text)
        -- A colour may arrive as a Style.COLOR KEY or as the table itself:
        -- badgeOf and the verdict branches already hold resolved tables, and
        -- making every call site look up a key it does not have would be busywork
        -- with a nil-colour failure at the end of it.
        local c = t.color
        if type(c) == "string" then c = S and (S.COLOR[c] or S.COLOR.white) end
        if type(c) == "table" and c.r then tagFs:SetTextColor(c.r, c.g, c.b) end
        self.seps[i]:Show(); tagFs:Show()
      else
        -- ⚠️ HIDDEN, NOT BLANKED. An empty run still occupies its anchor, so a
        -- blanked separator leaves the next tag anchored to nothing visible and
        -- the line develops a gap where a tag used to be.
        setTextForce(self.seps[i], ""); setTextForce(tagFs, "")
        self.seps[i]:Hide(); tagFs:Hide()
      end
    end
  end

  --- The last run the line actually drew, for anything that has to sit AFTER
  --- the whole thing. Falls back to the lead when no tag is shown.
  ---
  --- ⚠️ WITHOUT THIS A TRAILING MARK LANDS ON TOP OF THE FIRST TAG (Session
  --- 262). The Slots list row anchored its owned-tick 6px past the NAME — the
  --- same anchor the tag run starts from — so the tick and the first tag drew
  --- on the same pixels. Node 626:497 puts that tick after the tags.
  function g:Tail()
    for i = #self.tags, 1, -1 do
      if self.tags[i]:IsShown() and (self.tags[i]:GetText() or "") ~= "" then
        return self.tags[i]
      end
    end
    return self.lead
  end

  function g:SetShown(on)
    self.lead:SetShown(on)
    for i = 1, #self.tags do
      self.seps[i]:SetShown(on and self.seps[i]:GetText() ~= "")
      self.tags[i]:SetShown(on and self.tags[i]:GetText() ~= "")
    end
  end
  return g
end

--- One row of the item column: a two-line selector button.
local function buildItemRow(parent, i)
  local row = CreateFrame("Button", nil, parent)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetSize(CARD.w, ITEM_H)
  -- Indented to the boss NAME, not the column edge: the cards line up under the
  -- text they belong to rather than under the icons (Session 261).
  row:SetPoint("TOPLEFT", CARD.x, -(i - 1) * ITEM_PITCH)

  local S = ns.Style
  -- ⚠️ TWO GROUNDS, AND THEY ARE DIFFERENT COLOURS. The mock fills the SELECTED
  -- card with the rule blush at 20% and every other card with the control violet
  -- at 20% — not one colour at two alphas. Selection is a change of hue here,
  -- which is why it reads at a glance in a column of otherwise identical cards.
  row.bg = row:CreateTexture(nil, "BACKGROUND")
  row.bg:SetAllPoints()
  if S then
    row.bg:SetColorTexture(S.COLOR.control.r, S.COLOR.control.g, S.COLOR.control.b, 0.2)
  else
    row.bg:SetColorTexture(1, 1, 1, 0.05)
  end

  -- ⚠️ WHITE NAME OVER A BLUSH SLOT LINE — the opposite of the detail header,
  -- and read off the node. 11 over 10, both Light.
  -- ⚠️ THE NAME IS MEDIUM NOW (Session 261), not Light. The refresh sets every
  -- item and raider name in Saira Medium against Light body copy, which is what
  -- separates a name from the line beneath it once the chips are gone and the
  -- card is only two lines tall.
  row.name = at(text(row, "medium", "name", "white"), CARD.padX, CARD.nameY,
    CARD.w - CARD.padX * 2 - MARK_GUTTER)

  -- ⚠️ THE SLOT LINE CARRIES THE TAGS NOW. It was a plain blush line with a row
  -- of chips beneath it; it is "Back, Cloth • MAJOR • O-BIS • TARGET" on one
  -- line, which is the whole of the card's vertical saving (61 -> 45).
  -- Three tags is the maximum a card shows: a verdict, a BIS listing, a target.
  row.tagLine = buildTagLine(row, CARD.padX, CARD.slotY, 3)

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
  --- Paint the card's ground for its current state. One place, because hover has
  --- to be able to put it back — and selected and unselected are different HUES,
  --- so a hover that reset to a constant would silently deselect a card visually.
  function row:PaintGround(hover)
    if not S then return end
    local c = self._selected and S.COLOR.rule or S.COLOR.control
    self.bg:SetColorTexture(c.r, c.g, c.b, hover and 0.3 or 0.2)
  end
  row:SetScript("OnEnter", function(self) self:PaintGround(true) end)
  row:SetScript("OnLeave", function(self) self:PaintGround(false) end)
  return row
end

--- One boss portrait in the strip.
---
--- The selected boss takes a 4px orange underline BENEATH the tile rather than a
--- rim or a fill: a rim on a 32px tile eats the art, and the underline is what
--- the design draws. It sits outside the tile so it covers none of the picture.
local function buildBossTile(parent, i)
  local tile = CreateFrame("Button", nil, parent)
  tile:SetSize(BOSS_W, BOSS_ROW_H)
  tile:SetPoint("TOPLEFT", 0, -(i - 1) * BOSS_ROW_H)

  local S = ns.Style
  tile.art = tile:CreateTexture(nil, "ARTWORK")
  tile.art:SetSize(BOSS_ICON, BOSS_ICON)
  tile.art:SetPoint("LEFT", BOSS_ICON_X, 0)
  -- ⚠️ A MaskTexture, ADDED ONCE AT BUILD — not SetMask in the renderer, which
  -- was the previous attempt and still did not round anything. A mask object
  -- persists across SetTexture calls, so it does not care that the image
  -- arrives later; that was the whole reason the ordering looked load-bearing.
  if ns.Style then ns.Style.Round(tile, tile.art) end

  -- The boss's name, which the portrait strip had no room for — the single
  -- biggest thing the rail buys. Truncation is left to the fontstring's own
  -- width rather than to a character count: the names vary from "Vashnik" to
  -- "Tidebound Sorceress's Reliquary" and any count is wrong for one of them.
  -- ⚠️ CENTRED IN THE ROW, NOT PINNED BY ITS TOP (Jason, Session 260: the boss
  -- and dungeon names "aren't vertically centered within each line"). Anchored
  -- TOPLEFT at a fixed y, a fontstring draws wherever its own line box lands —
  -- so the name sat at whatever height the font's ascent happened to put it,
  -- and the 28px icon beside it is centred on the row, so the two disagreed.
  -- An explicit height equal to the ROW plus JustifyV MIDDLE centres it against
  -- the row and therefore against the icon, with no arithmetic to keep in step
  -- if either changes. The S258 rule, applied where it had not been.
  -- ⚠️ NO EXPLICIT WIDTH ANY MORE (Session 261). The refresh puts the BIS and
  -- target counts immediately after the name rather than at the row's right
  -- edge, so the name has to size to its own string for anything to anchor to
  -- it. That is the same reason buildSourceLine gives its three runs no width —
  -- and it means the CLIENT does the measuring, never us, which is what keeps
  -- this clear of the cold-draw GetStringWidth trap (Session 260).
  tile.name = text(tile, "medium", "name", "white")
  tile.name:SetPoint("LEFT", BOSS_NAME_X, 0)
  tile.name:SetHeight(BOSS_ROW_H)
  tile.name:SetJustifyV("MIDDLE")

  -- The best-in-slot diamond, right-aligned in the row. Sized and placed from
  -- the mock's own node (15x12, at the row's right edge).
  -- ⚠️ THE MOCK'S OWN DIAMOND, IN THE MOCK'S OWN COLOUR. It was the item list's
  -- mark-bis.png tinted #fff468 — a different SHAPE and a yellow this design
  -- does not contain. Media/ui/diamond.png is the faceted gem exported straight
  -- from the node's path, rendered WHITE so it can be tinted from the palette
  -- rather than needing a re-export when a colour moves.
  -- ⚠️ IT FOLLOWS THE NAME NOW, RIGHT-ALIGNED NO LONGER (Session 261). The mock
  -- puts "Nymrissa Wavecaller  ◆ x2  ⊚ x1" as one flowing line.
  tile.bis = tile:CreateTexture(nil, "OVERLAY")
  tile.bis:SetSize(15, 12)
  tile.bis:SetPoint("LEFT", tile.name, "RIGHT", 10, 0)
  tile.bis:SetTexture("Interface\\AddOns\\HoDLootAdvisor\\Media\\ui\\diamond.png")
  if S and S.COLOR.accent then tile.bis:SetVertexColor(S.rgb(S.COLOR.accent)) end
  tile.bis:Hide()

  -- The diamond's own hover target (Jason, Session 260). A texture cannot take
  -- scripts, so the count needs a frame sitting exactly on it.
  --
  -- ⚠️ IT FORWARDS THE CLICK, EXPLICITLY. Two mouse-enabled frames on the same
  -- pixels means only one receives the press (the S252 rule), and this one sits
  -- on top — so without forwarding, clicking the diamond would silently fail to
  -- expand the boss. SetPropagateMouseClicks is a PROTECTED function and is not
  -- ours to rely on; calling the same handler is, and it is visible here rather
  -- than depending on what the client permits.
  --
  -- Sized to the diamond and no larger, so it never covers the boss's name.
  -- ⚠️ THE COUNTS ARE NEW DATA, NOT DECORATION (Session 261). "x2" beside the
  -- diamond is how many of this boss's drops are best-in-slot for you; "x1"
  -- beside the target is how many you have flagged. Nothing counted either
  -- before — see ns.BossItemCounts, which also explains why a zero HIDES the
  -- whole group rather than drawing "x0".
  tile.bisN = text(tile, "light", "label", "body")
  tile.bisN:SetPoint("LEFT", tile.bis, "RIGHT", 2, 0)
  tile.bisN:SetHeight(BOSS_ROW_H)
  tile.bisN:SetJustifyV("MIDDLE")
  tile.bisN:Hide()

  tile.tgt = tile:CreateTexture(nil, "OVERLAY")
  tile.tgt:SetSize(15, 15)
  tile.tgt:SetPoint("LEFT", tile.bisN, "RIGHT", 10, 0)
  -- The mock's own target mark, exported at 2x like every other icon here and
  -- rendered WHITE so it can be tinted from the palette — a gold export would
  -- multiply into the gold tint and come out darker than it was drawn.
  tile.tgt:SetTexture("Interface\\AddOns\\HoDLootAdvisor\\Media\\ui\\target.png")
  if S and S.COLOR.target then tile.tgt:SetVertexColor(S.rgb(S.COLOR.target)) end
  tile.tgt:Hide()

  tile.tgtN = text(tile, "light", "label", "body")
  tile.tgtN:SetPoint("LEFT", tile.tgt, "RIGHT", 2, 0)
  tile.tgtN:SetHeight(BOSS_ROW_H)
  tile.tgtN:SetJustifyV("MIDDLE")
  tile.tgtN:Hide()

  tile.bisHit = CreateFrame("Button", nil, tile)
  tile.bisHit:SetAllPoints(tile.bis)
  tile.bisHit:EnableMouse(true)
  tile.bisHit:Hide()

  -- The row rule. DROPPED ON THE SELECTED ROW, which is how the mock joins a
  -- boss to the loot listed beneath it — and why its expanded row measures one
  -- pixel shorter than the others.
  tile.rule = tile:CreateTexture(nil, "ARTWORK")
  tile.rule:SetPoint("BOTTOMLEFT", BOSS_ICON_X, 0)
  tile.rule:SetPoint("BOTTOMRIGHT", -10, 0)
  tile.rule:SetHeight(1)
  if S then
    tile.rule:SetColorTexture(S.COLOR.rule.r, S.COLOR.rule.g, S.COLOR.rule.b, 0.3)
  end

  -- THE FALLBACK IS A TILE, NOT NOTHING. Whether this client can supply a boss
  -- portrait at all is unsettled (Journal.EncounterPortrait asks; /la journal
  -- reports). A strip of blank squares reads as "the addon is broken" — Build
  -- Barn taught this the expensive way when a new tier shipped without art — so
  -- an unanswered portrait draws a filled tile carrying the boss's initial.
  -- ⚠️ THE FALLBACK IS NOW THE ICON'S SIZE, NOT THE ROW'S. It used to fill the
  -- whole tile, which was right when the tile WAS the portrait; on a full-width
  -- row that would paint a grey slab behind the boss's name.
  tile.fallback = tile:CreateTexture(nil, "BACKGROUND")
  tile.fallback:SetSize(BOSS_ICON, BOSS_ICON)
  tile.fallback:SetPoint("LEFT", BOSS_ICON_X, 0)
  if S then
    tile.fallback:SetColorTexture(S.COLOR.elevated.r, S.COLOR.elevated.g, S.COLOR.elevated.b, 1)
  end
  if ns.Style then ns.Style.Round(tile, tile.fallback) end
  tile.initial = text(tile, "titleMed", "head", "textDim", "CENTER")
  tile.initial:SetPoint("CENTER", tile.fallback, "CENTER")

  -- ⚠️ AN EXPANDED BOSS ROW HAS NO FILL AT ALL (Jason). It carried a blush tint
  -- for one round, invented on the reasoning that a selected thing ought to look
  -- selected. The mock's boss rows have no background in ANY state — only the
  -- item CARDS are filled — and the row says it is open by DROPPING ITS RULE,
  -- which joins it to the loot listed beneath it. That is the whole signal, and
  -- it is enough because the loot appearing underneath is the other half of it.
  --
  -- This also retires the Session 251 selection underline for good: that existed
  -- because a 32px portrait had no free edge to mark, and the question does not
  -- arise on a full-width row in an accordion.

  -- ONE HANDLER, TWO PRESSES. The diamond's hit frame calls this too, so the
  -- row and the mark cannot come to disagree about what a click does.
  local function toggleBoss(self)
    if not self.bossIndex then return end
    -- ⚠️ A SECOND CLICK COLLAPSES. Without it there is no way BACK to the full
    -- list once you have opened anything, and the state Jason asked for would
    -- be reachable only by closing the window.
    if state.bossIndex == self.bossIndex then
      state.bossIndex = nil
    else
      state.bossIndex = self.bossIndex
    end
    -- ⚠️ NIL, NOT 1 (Session 262, Jason: "clicking a boss should just show that
    -- boss's loot table, NOT select the first item"). Opening a boss was
    -- selecting its first card and filling the detail pane with an item nobody
    -- picked — which also made the "Choose an Item to View Details" empty state
    -- unreachable, though it has been written and drawn all along.
    state.sel, state.colScroll, state.rankScroll = nil, 0, 0
    Panel.Refresh()
  end

  tile:SetScript("OnClick", toggleBoss)
  tile.bisHit:SetScript("OnClick", function() toggleBoss(tile) end)

  -- ⚠️ NO TOOLTIP ON THE ROW ITSELF (Jason, Session 260: it "serves no purpose
  -- but to be in the way"). It repeated the boss's name, which is already
  -- printed an inch to the left in a larger face — a tooltip that restates what
  -- it covers is worse than none, because it hides the neighbouring rows while
  -- telling you nothing.
  --
  -- The count moves to the DIAMOND, which is the one thing on the row that does
  -- NOT explain itself. Nothing else is added: the mark says "there is
  -- best-in-slot here", and the only question it leaves open is how much.
  tile.bisHit:SetScript("OnEnter", function(self)
    local n = tile.bossBis or 0
    if n <= 0 then return end
    ns.Tip:SetOwner(self, "ANCHOR_CURSOR")
    ns.Tip:SetText(("%d BIS ITEM%s"):format(n, n == 1 and "" or "S"), 1, 1, 1)
    ns.Tip:Show()
  end)
  tile.bisHit:SetScript("OnLeave", function() ns.Tip:Hide() end)
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
    row.hl:SetColorTexture(S.COLOR.control.r, S.COLOR.control.g, S.COLOR.control.b, 0.5)
  else
    row.hl:SetColorTexture(1, 1, 1, 0.07)
  end
  row.hl:Hide()

  row.TEXT_KEYS = { "rank", "name", "upgrade", "gap", "gain", "pr", "src" }

  -- Positions are relative to the ROW, which is anchored at the pane's left, so
  -- the mock's absolute x values are offset by the rank column's own origin.
  local o = C_RANK
  -- ⚠️ THE RANK IS 14 AND EVERYTHING ELSE ON THE ROW IS 11 — the mock's one
  -- deliberate size jump inside the table. It is what the eye scans down.
  -- ⚠️ BOLD, AND THE ONLY BOLD IN THE TABLE. The node is 14px Bold in #f2bdad
  -- — not the muted grey it used to be. It is what the eye scans down, and the
  -- design gives it weight rather than a second colour to do that job.
  row.rank    = at(text(row, "bold", "rank", "body"), C_RANK - o, 0, 20, "LEFT")
  -- ⚠️ CLASS-COLOURED, AND THE ASTERISK IS NOT. The mock paints each name in its
  -- class colour and leaves the ad-hoc "*" white, so the marker stays legible on
  -- a dark class and does not read as part of the name.
  row.name    = at(text(row, "medium", "name", "white"), C_NAME - o, 0, 90)
  row.gain    = atRight(text(row, "light", "small", "white"), C_GAIN_R - o, 0, 44)
  row.pr      = atRight(text(row, "light", "small", "white"), C_PRIORITY_R - o, 0, 48)

  -- ⚠️ EVERY CELL IS THE ROW'S FULL HEIGHT AND CENTRES IN IT (Jason, Session
  -- 259: "the name isn't vertically aligned with the other elements in the
  -- row"). These were anchored TOPLEFT at y=1 with NO height, so each one drew
  -- wherever its own line box landed — and the box differs by font and size, so
  -- the 14px Bold rank, the 11px Light name and the 12px chips all settled on
  -- different lines. The chips were the only elements that were ever centred,
  -- being anchored LEFT, which is why the hover highlight made it obvious.
  --
  -- The node agrees: its name column is leading-[20px] inside a 20px row, which
  -- IS a centred line box. Same rule as the Slots identity block — type needs an
  -- explicit height wherever it is being aligned against anything else.
  for _, fs in ipairs({ row.rank, row.name, row.gain, row.pr }) do
    fs:SetHeight(RANK_PITCH)
    fs:SetJustifyV("MIDDLE")
  end
  -- ⚠️ AND THE UPGRADE COLUMN IS THE FIFTH CELL, WHICH THIS LOOP DID NOT COVER
  -- (Session 262). It is a tag line rather than a plain fontstring, so it was
  -- skipped — and it drew half a row ABOVE the raider name it belongs to, on
  -- every row, while the four cells above centred correctly. The height goes to
  -- buildTagLine, which places the whole run off its lead's rect.

  -- ⚠️ THE UPGRADE COLUMN WAS CHIPS AND IS NOW TEXT (Session 261). It read
  -- "MAJOR  O-BIS  -16" as three bordered boxes; it reads "MAJOR • O-BIS • -16"
  -- as colour-coded runs. Four tags at most: the verdict, the BIS listing, an
  -- ALT SPEC marker and the gap.
  --
  -- ⚠️ WHAT IS LOST, RECORDED RATHER THAN GLOSSED. The chip KINDS encoded a real
  -- distinction — outlined meant "a claim about THIS RAIDER" (the badge, the
  -- gap) and filled meant "a fact about the ITEM" (O-BIS, TARGET) — so that
  -- best-in-slot could not read as one person's opinion. With the boxes gone
  -- that distinction survives only as colour, which is weaker. Jason's call:
  -- the outline "takes up too much vertical space and was distracting".
  row.tagLine = buildTagLine(row, C_UPGRADE - o, 0, 4, nil, RANK_PITCH)
  -- Gear provenance, in the space between GAIN and PRIORITY. Blank is the common
  -- case and that is deliberate: almost every row is scored from the site
  -- snapshot, so tagging all twenty turns the signal into wallpaper. What is
  -- worth marking is the rows BETTER than the snapshot.
  -- Centred with the rest of the row for the same reason: it sits directly
  -- beside the GAIN figure and was drawing a couple of pixels below it.
  row.src     = at(text(row, "body", "tiny", "textDim"), C_GAIN_R - o + 6, 0, 36)
  row.src:SetHeight(RANK_PITCH)
  row.src:SetJustifyV("MIDDLE")

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
  --- ⚠️ THE HIT AREA FOLLOWS THE BADGE, NOT THE OLD `upgrade` FONTSTRING
  --- (Session 258). It was anchored to row.upgrade — which the redesign BLANKS,
  --- and which is built with an explicit width of 0 — so the frame collapsed to
  --- nothing and the breakdown tooltip became unreachable. It was still built,
  --- still correct, and could not be pointed at; Jason reported it as gone.
  ---
  --- The badge moved into a CHIP when the panel was rebuilt, and nothing
  --- re-pointed this at it. Re-anchored after every layout, because a chip's
  --- width is its own label's and is only known once it is Set.
  row.scoreHit = CreateFrame("Frame", nil, row)
  row.scoreHit:EnableMouse(true)

  function row:AnchorScoreHit()
    -- The verdict run, which is the first tag and the widest thing in the
    -- column. It was a chip until Session 261 and the fontstring before that;
    -- both times the hit area was left pointing at the old widget and the
    -- breakdown tooltip silently became unreachable, so this follows the tag.
    local target = self.tagLine and self.tagLine.tags[1]
    self.scoreHit:ClearAllPoints()
    if target then
      self.scoreHit:SetPoint("TOPLEFT", target, "TOPLEFT", 0, 3)
      self.scoreHit:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", 0, -3)
    end
    -- A zero-width target can still be pointed at nowhere; hide the hit frame
    -- rather than leaving an invisible 0x20 catcher on the row.
    self.scoreHit:SetShown(target ~= nil and (target:GetWidth() or 0) > 0)
  end
  row.scoreHit:SetScript("OnEnter", function(self)
    local r = row.scoreInfo
    row.hl:Show()
    if not r then return end
    ns.Tip:SetOwner(self, "ANCHOR_CURSOR")

    -- A CONDITIONAL EXPLAINS THE CONDITION, NOT AN ARITHMETIC IT DOES NOT HAVE.
    -- Its item-level factor is deliberately zero and there is no gain figure at
    -- all, so a breakdown here would show a row of numbers that answer a
    -- question the verdict has already declined to answer.
    if r.pairing then
      ns.Tip:AddLine("Why this needs a pairing", 1, 1, 1)
      ns.Tip:AddLine(
        r.pairing == "main_hand"
          and "They are using a two-handed weapon, so their off-hand slot is "
              .. "empty. This is a real upgrade only if they also get a "
              .. "one-hander — and we cannot see anyone's bags, so there is no "
              .. "honest gain to show."
          or  "They are using a two-handed weapon. Equipping this leaves their "
              .. "off-hand empty, so it is a real upgrade only if they also get "
              .. "an off-hand — and we cannot see anyone's bags, so there is no "
              .. "honest gain to show.",
        0.6, 0.6, 0.7, true)
      ns.Tip:Show()
      return
    end

    ns.Tip:AddLine("How this score was reached", 1, 1, 1)

    if not r.factors then
      -- ⚠️ SAY WHY, RATHER THAN SHOW A BLANK. A ranking from the runner carries
      -- the badge and the gap but NOT the arithmetic behind them — everyone
      -- displays the runner's numbers by rule, and the factors were never on
      -- the wire.
      ns.Tip:AddLine(
        "The breakdown is not available: this ranking came from the loot runner, "
        .. "which sends each raider's result but not the factors behind it.",
        0.6, 0.6, 0.7, true)
      ns.Tip:Show()
      return
    end

    local f = r.factors
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
    -- ⚠️ A RAIDER ROW HAS NO TOOLTIP (Jason, Session 259: "seems to serve no
    -- real purpose"). It used to explain the provenance marker, the ad-hoc
    -- asterisk and the alt-spec chip; hovering your own name in a ranking list
    -- popped a sentence over the table for no decision anyone was making.
    --
    -- ⚠️ IT WAS ALSO THE STICKY ONE, and that is the same bug rather than a
    -- second one: this handler opened ns.Tip while OnLeave below hid only
    -- GameTooltip, so nothing took it down until the cursor reached a surface
    -- that happened to call Tip:Hide — which is why it survived until you left
    -- the addon entirely. OnLeave now hides both, so a tooltip opened here can
    -- never outlive the row again.
    --
    -- The MARKERS all stay on screen; only the sentences are gone. Provenance
    -- is still visible, which is what the three-tier rule actually requires.
    if not self.itemID then return end
    local link = self.link or ns.ItemLinkFor(self.itemID)
    if not link then return end
    -- The other half of the exclusion in Tip:Show — whichever opens last wins,
    -- and neither is ever left behind the other.
    ns.Tip:Hide()
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
    GameTooltip:SetHyperlink(link)
    GameTooltip:AddLine(ns.Targets and ns.Targets.Has(self.itemID)
      and "Right-click to stop targeting." or "Right-click to target.", 0.6, 0.6, 0.7)
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function(self)
    self.hl:Hide()
    -- ⚠️ BOTH, ALWAYS. Hiding only the one this handler happens to open today is
    -- how the raider tooltip came to outlive its row: OnEnter could raise EITHER
    -- surface and OnLeave took down one of them. A leave handler that does not
    -- close everything its enter handler can open is the bug, not the symptom.
    GameTooltip:Hide()
    if ns.Tip then ns.Tip:Hide() end
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
    row.hl:SetColorTexture(S.COLOR.control.r, S.COLOR.control.g, S.COLOR.control.b, 0.5)
  end
  row.hl:Hide()

  -- Positions are relative to the row, which starts at the rank column's left.
  -- ⚠️ THE RANK IS THE ONLY BOLD CELL AND THE ONLY BLUSH ONE (node 587:1650):
  -- 14 Bold in #f2bdad against every other column's 11 Light white. It is the
  -- column you scan down, so it is the one the design gives weight to.
  local o = ST_RANK_R - 24
  row.rank = atRight(text(row, "bold", "rank", "body"), ST_RANK_R - o, 1, 24)
  -- The name is the one cell that takes a colour from the DATA rather than from
  -- the design — the mock's six sample rows are six real class colours.
  row.name = at(text(row, "medium", "name", "white"), ST_NAME - o, 3, 110)
  row.ep   = atRight(text(row, "light", "small", "white"), ST_EP_R - o, 3, 60)
  row.gp   = atRight(text(row, "light", "small", "white"), ST_GP_R - o, 3, 50)
  row.pr   = atRight(text(row, "light", "small", "white"), ST_PR_R - o, 3, 50)
  row.last = atRight(text(row, "light", "small", "white"), ST_LAST_R - o, 3, 60)
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
--- One block of the personal rail, from node 588:1666.
---
--- ⚠️ A FILLED SURFACE, NOT FOUR LOOSE LINES. The redesign gives each block the
--- rule blush at 10% with 10px of padding — the same ground the Slots page's
--- OBTAINED BY panel and its selected rail row use, which is what makes the two
--- tabs read as one window.
---
--- THE HEADING IS THE HEADING PURPLE (#9f50d4), NOT `railHead` (#936bff). Those
--- are neighbours and easy to mistake for each other; the mock names the first,
--- which is the same purple the table's column headers take.
--- Pin a fontstring's box so a TOPLEFT anchor means what it says.
---
--- ⚠️ WITHOUT THIS A 34px STRING DRAWS WHEREVER ITS LINE BOX PUTS IT, which is
--- most of what made the rail's spacing wrong: the anchor was right and the
--- glyphs sat well below it, so every gap read as far larger than the design's.
local function pinLine(f, y, w, h)
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", RAIL.pad, -y)
  f:SetWidth(w)
  f:SetHeight(h)
  f:SetJustifyV("TOP")
  return f
end

local function buildRailBlock(parent, y, index, h)
  local b = {}
  local L = RAIL.layout[index]

  b.box = CreateFrame("Frame", nil, parent)
  b.box:SetSize(RAIL.w, h or 86)
  b.box:SetPoint("TOPLEFT", RAIL.x, -y)
  -- A FILL, no border — the design separates the rail from the table with this
  -- wash rather than with an edge.
  if ns.Style then ns.Style.Surface(b.box, ns.Style.COLOR.rule, 0.1) end

  local innerW = RAIL.w - RAIL.pad * 2
  b.head = pinLine(text(b.box, "bold", "head", "accent"), L.head, innerW, 14)

  -- 34px, and there is no token for it: it appears twice on this one tab and
  -- nowhere else, so it is fed per instance rather than added to the scale.
  b.big = text(b.box, "bold", "title", "white")
  if ns.Style then ns.Style.SetFont(b.big, ns.Style.FONT.bold, 34) end
  pinLine(b.big, L.big or L.head, innerW, 36)
  b.big:SetShown(L.big ~= nil)
  -- Rides on the figure's own baseline, for the "of 3" in "2 of 3".
  b.bigSuffix = text(b.box, "light", "rank", "body")
  b.bigSuffix:ClearAllPoints()
  b.bigSuffix:SetPoint("BOTTOMLEFT", b.big, "BOTTOMLEFT", 0, 4)

  local lines = {}
  for i, ly in ipairs(L.lines) do
    -- The third line is the flat grey the mock names for the age — the least
    -- important line on the tab and the only one given its own hue.
    local colour = (i == 3) and "grey" or "white"
    lines[i] = pinLine(text(b.box, "light", "small", colour), ly, innerW,
      L.lineSize + 5)
    if ns.Style then ns.Style.SetFont(lines[i], ns.Style.FONT.light, L.lineSize) end
  end
  -- Blocks have two or three lines; the absent one is a real fontstring parked
  -- off the layout so every call site can write to it without checking.
  for i = #lines + 1, 3 do
    lines[i] = pinLine(text(b.box, "light", "small", "white"), 0, innerW, 1)
    lines[i]:Hide()
  end
  b.line1, b.line2, b.line3 = lines[1], lines[2], lines[3]
  return b
end

--- Blank every fontstring on a recycled row.
local function resetRow(row)
  if not row or not row.TEXT_KEYS then return end
  for _, key in ipairs(row.TEXT_KEYS) do
    local fsObj = row[key]
    if fsObj and fsObj.SetText then fsObj:SetText("") end
  end
  -- ⚠️ CHIPS ARE PART OF THE ROW'S STATE. They are frames rather than
  -- fontstrings, so the TEXT_KEYS sweep above cannot reach them — and a chip
  -- left behind is a claim about the previous occupant of the row, which is
  -- exactly the failure that sweep exists to prevent.
  if row.ClearChips then row:ClearChips() end
  -- ⚠️ AND SO IS A TAG LINE, FOR THE SAME REASON (Session 261). Its runs are
  -- fontstrings but they are held inside a table, so TEXT_KEYS cannot see them
  -- either; a stale tag is the same wrong claim a stale chip was.
  if row.tagLine then row.tagLine:Set("", nil) end
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
  Panel.ApplyScale()
  frame:Hide()

  -- The design's ground: a near-black fill, a warm wash rising from the bottom
  -- edge, and one light hairline.
  if ns.Style then ns.Style.PanelGround(frame, FRAME_H) end

  -- The header lockup: crest and wordmark as one texture, because the wordmark's
  -- gradient, letter spacing and glow are three things a FontString cannot do.
  -- Style.Lockup owns the arithmetic that compensates for the export's padding.
  frame.logo = ns.Style and ns.Style.Lockup(frame, LOGO_X, LOGO_Y)

  -- The close button the template used to supply.
  -- ⚠️ VIOLET AT HALF ALPHA, NOT NEAR-WHITE (Session 262, node 626:519). It was
  -- drawn in textDim, which reads as a bright Blizzard-ish X against a design
  -- whose every other mark is in the palette. Shared with the secondary windows
  -- now, which is what let them drop their Blizzard frame templates.
  frame.close = ns.Style and ns.Style.CloseButton(frame)

  -- ── Tabs ──────────────────────────────────────────────────────────────────
  --
  -- ⚠️ THE ROW IS LAID OUT AFTER EVERY TAB EXISTS, not as each one is made,
  -- because a tab's width is not known until its label has been measured and
  -- each tab's position depends on the width of the one before it.
  frame.tabs = {}
  local row = {}
  for _, name in ipairs(TABS) do
    -- ⚠️ UPPERCASED FOR DISPLAY ONLY. The entries in TABS are the identity the
    -- rest of the file compares state.tab against; uppercasing the table itself
    -- would mean touching every one of those comparisons to change a letterform.
    local b = ns.Style and ns.Style.Control(frame, name:upper(), "head")
      or CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetScript("OnClick", function()
      state.tab = name
      state.rankScroll, state.colScroll = 0, 0
      Panel.Refresh()
    end)
    frame.tabs[name] = b
    row[#row + 1] = b
  end
  if ns.Style then ns.Style.LayoutRow(row, frame, PAD, -TAB_Y, TAB_GAP) end
  frame.tabRow = row

  -- ⚠️ A TAB THAT DRAWS NOTHING READS AS A BROKEN ADDON, which is this file's
  -- oldest lesson and the reason a declined drop is counted rather than
  -- swallowed. Slots is wired into the row before it has a renderer, so it says
  -- what it is instead of showing an empty violet rectangle.
  frame.tabEmpty = text(frame, "body", "detail", "body", "CENTER")
  frame.tabEmpty:SetPoint("CENTER", frame, "CENTER", 0, 0)
  frame.tabEmpty:Hide()

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
  -- Node 582:1127 left-aligns the label at 20 and puts the caret in the space
  -- that leaves; see Style.LeftLabel (Session 262).
  if ns.Style then ns.Style.LeftLabel(frame.diff) end
  if frame.diff.SetPillState then frame.diff:SetPillState(true) end
  -- ORANGE, per the mock. It was built purple like every other pill on the row,
  -- but the tabs and filter toggles are VIEWS and this one selects CONTENT —
  -- which is the distinction the colour is drawing.
  -- ⚠️ NO LONGER ORANGE (Session 257). Session 251 made it orange to say "this
  -- selects CONTENT, not a view" — a real distinction, drawn from the mock of
  -- the time. The redesign draws it in the same violet as an active tab, so the
  -- distinction is now carried by where it sits rather than by hue.
  if frame.diff.SetPillColor and ns.Style then
    frame.diff:SetPillColor(ns.Style.COLOR.control)
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
  frame.vault = ns.Style and ns.Style.Check(frame, "VAULT/VOIDCORE", VAULT_BOX)
  if frame.vault then
    -- ⚠️ LEFT edges flush with the dropdown, not right. The mock aligns the two
    -- controls down their left side at x 577; the label runs off to the right
    -- and is shorter than the dropdown, so a right-edge anchor put the box in
    -- the middle of nowhere.
    frame.vault:SetPoint("TOPLEFT", DIFF_X, -VAULT_Y)
    frame.vault:SetChecked(ns.VaultOn())
    frame.vault:SetScript("OnClick", function(self)
      self:SetChecked(not self:GetChecked())
      if ns.Settings then
        ns.Settings.Set("vault", self:GetChecked() and "on" or "off")
      end
      state.sel, state.colScroll, state.rankScroll = nil, 0, 0
      Panel.Refresh()
    end)
  end

  -- The caret. A dropdown that looks like a button gets clicked once and
  -- abandoned; the design draws the affordance, so it is drawn.
  frame.diffCaret = frame.diff:CreateTexture(nil, "OVERLAY")
  -- 11x11: the design node's own size. The art is drawn into that cell with the
  -- triangle occupying its lower three-quarters, exactly as Figma places it, so
  -- the padding is the design's rather than something added here.
  frame.diffCaret:SetSize(DIFF_CARET, DIFF_CARET)
  frame.diffCaret:SetPoint("RIGHT", -DIFF_CARET_R, 0)
  -- The design's own caret, pointing DOWN as a dropdown affordance should. It was
  -- Blizzard's ChatFrameExpandArrow, which points RIGHT — it reads as "expand
  -- sideways", and it is not the shape in the mock.
  frame.diffCaret:SetTexture("Interface\\AddOns\\HoDLootAdvisor\\Media\\ui\\caret.png")
  -- ⚠️ THE CONTROL'S OWN TEXT COLOUR, NOT WHITE (Jason, Session 260). The caret
  -- is part of the label, not a separate mark, and the Slots page's dropdown
  -- has always drawn it in controlText — so the two dropdowns disagreed and
  -- this one was the odd match out.
  if ns.Style then frame.diffCaret:SetVertexColor(ns.Style.rgb(ns.Style.COLOR.controlText)) end

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
      state.sel, state.colScroll, state.rankScroll = nil, 0, 0
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
  -- ⚠️ THE CONTEXT LINE IS RETIRED, NOT MOVED (Session 257). "Nymrissa
  -- Wavecaller / For You: 1 BIS | 0 Targets" sat above the portrait strip
  -- because the strip could not name its own bosses. The rail does — each row
  -- carries its name, and the diamond marks the ones holding something
  -- best-in-slot for you — so the line has no job left and the mock has no such
  -- element. Kept as hidden fontstrings rather than deleted, because several
  -- render paths still write to them and blanking a write is cheaper to reason
  -- about than removing writes from five places at once.
  frame.bossName = at(text(frame, "label", "head", "accent"), BOSS_X, BOSS_TOP, 200)
  frame.bossSub  = at(text(frame, "body", "small", "body"), BOSS_X, BOSS_TOP + 18, 200)
  frame.bossName:Hide()
  frame.bossSub:Hide()

  -- ── Boss strip ────────────────────────────────────────────────────────────
  -- Right-aligned to the window margin, so a raid with fewer bosses than slots
  -- keeps the last tile against the same edge instead of leaving a ragged gap
  -- under the header.
  -- ⚠️ ONE CONTAINER FOR BOTH, because the accordion is ONE list: boss rows and
  -- the expanded boss's item cards are siblings in the same column under one
  -- scroll offset. The old split — a rail frame with its own wheel above a
  -- separate item frame with another — is what produced two independent scrolls
  -- and a "+5 more bosses" line that belongs to neither design.
  frame.col = CreateFrame("Frame", nil, frame)
  frame.col:SetSize(BOSS_W, COL_AREA_H)
  frame.col:SetPoint("TOPLEFT", BOSS_X, -BOSS_TOP)
  frame.col:EnableMouseWheel(true)
  frame.col:SetScript("OnMouseWheel", function(_, delta) Panel.ScrollColumn(-delta) end)
  frame.bossTiles = {}
  for i = 1, BOSS_SLOTS do
    frame.bossTiles[i] = buildBossTile(frame.col, i)
    frame.bossTiles[i]:Hide()
  end
  -- The overflow note now belongs under the LAST DRAWN ROW, whose position
  -- depends on how many bosses the season has, so it is placed at render time
  -- rather than pinned to a constant that assumed nine.

  -- ── The two filter toggles ────────────────────────────────────────────────
  -- ⚠️ TWO SWITCHES, NOT FOUR BUTTONS (Session 257). The mock draws each filter
  -- as one labelled switch — "CURRENT DROPS (o—) FULL LOOT TABLE" — where the
  -- knob's position is the entire state indication and both labels stay the
  -- same weight and colour. Four pills said it four times, in two stacked rows.
  --
  -- Positions are the mock's own, per element rather than per group, because the
  -- labels differ in length and the design still lines both rows up.
  local function pick(field, which)
    return function()
      state[field] = which
      state.sel, state.colScroll, state.rankScroll = nil, 0, 0
      Panel.Refresh()
    end
  end

  local function switchAt(leftLabel, rightLabel, leftX, trackX, rightX, onPick)
    if not ns.Style then return nil end
    local s = ns.Style.Switch(frame, leftLabel, rightLabel)
    s:SetPoint("TOPLEFT", trackX, -TOG.trackY)
    -- ⚠️ THE SAME y AS THE TRACK, NOT ONE BELOW IT (Session 262). Both labels
    -- carry the track's height now, so anchoring them on its own line is what
    -- centres all three — and the node puts the text and the toggle on the
    -- same y regardless.
    s.left:ClearAllPoints()
    s.left:SetPoint("TOPLEFT", leftX, -TOG.trackY)
    s.right:ClearAllPoints()
    s.right:SetPoint("TOPLEFT", rightX, -TOG.trackY)
    s:Wire(onPick)
    return s
  end

  frame.swSource = switchAt("CURRENT DROPS", "FULL LOOT TABLE",
    TOG.srcL, TOG.srcTrack, TOG.srcR,
    function(right) pick("source", right and "table" or "drops")() end)

  frame.swFilter = switchAt("USABLE ONLY", "ALL LOOT",
    TOG.filL, TOG.filTrack, TOG.filR,
    function(right) pick("filter", right and "all" or "usable")() end)

  -- The one filter that needs explaining keeps its tooltip, moved onto the
  -- switch itself now that the pill it hung from is gone.
  if frame.swFilter then
    frame.swFilter:SetScript("OnEnter", function(self)
      ns.Tip:SetOwner(self, "ANCHOR_CURSOR")
      ns.Tip:SetText("Usable Only", 1, 1, 1)
      ns.Tip:AddLine("Hides items your class cannot equip.", 0.8, 0.8, 0.8, true)
      ns.Tip:AddLine("Anything you have targeted stays visible either way — "
        .. "hiding something you asked for is worse than showing one you cannot use.",
        0.6, 0.6, 0.7, true)
      ns.Tip:Show()
    end)
    frame.swFilter:SetScript("OnLeave", function() ns.Tip:Hide() end)
  end

  -- ── The item cards ────────────────────────────────────────────────────────
  -- Same container as the boss rows; see the note where it is created.
  frame.itemRows = {}
  for i = 1, COL_ROWS do
    frame.itemRows[i] = buildItemRow(frame.col, i)
    frame.itemRows[i]:Hide()
  end
  -- Both of these sit relative to the COLUMN rather than to the window, because
  -- the column moves with the rail. Anchoring them to constants is how they
  -- ended up describing a list that was no longer underneath them.
  frame.colEmpty = at(text(frame.col, "body", "small", "body"), 12, 12, COL_W - 24)
  frame.colMore = at(text(frame, "body", "label", "body"), 0, 2, COL_W)
  frame.colMore:ClearAllPoints()
  frame.colMore:SetPoint("TOPLEFT", frame.col, "BOTTOMLEFT", 0, -2)

end

--- The Runner tab's furniture, built once. Rendering fills it in.
---
--- Every fact it shows comes from Comms.RunnerReport(); this builds the widgets
--- and nothing else. See the note on that function for why the data lives there.
local function buildRunnerTab()
  local R = {}
  frame.rn = R

  -- ── Left rail: state, and the two controls that change it ─────────────────
  -- Two filled blocks on the rule blush at 10%, matching Standings. The
  -- fontstrings are parented to the WINDOW rather than to the boxes so every
  -- existing position stays panel-relative; the boxes sit behind them.
  local function railBox(y, h)
    local box = CreateFrame("Frame", nil, frame)
    box:SetSize(RN_RAIL_W, h)
    box:SetPoint("TOPLEFT", RN_RAIL_X, -y)
    if ns.Style then ns.Style.Surface(box, ns.Style.COLOR.rule, 0.1) end
    return box
  end
  R.statusBox = railBox(RN_STATUS_BLOCK_Y, RN_STATUS_BLOCK_H)
  R.dataBox   = railBox(RN_DATA_BLOCK_Y, RN_DATA_BLOCK_H)

  local innerX, innerW = RN_RAIL_X + RN_PAD, RN_RAIL_W - RN_PAD * 2
  -- Bold 14 in the green, wrapping to two lines — not the 20px title it was.
  R.status = at(text(frame, "bold", "rank", "green"), innerX, RN_STATUS_Y, innerW)
  R.status:SetWordWrap(true)
  R.since  = at(text(frame, "light", "small", "white"), innerX, RN_SINCE_Y, innerW)

  -- The heading purple, same as every other block heading in the redesign.
  R.dataHead = at(text(frame, "bold", "head", "accent"), innerX, RN_DATA_Y, innerW)
  R.dataHead:SetText("TONIGHT'S DATA")
  R.raiders  = at(text(frame, "light", "head", "white"), innerX, RN_RAIDERS_Y, innerW)
  R.ranked   = at(text(frame, "light", "head", "white"), innerX, RN_RANKED_Y, innerW)
  -- ⚠️ 9px, AND IN THE HEADING PURPLE — the smallest type in the panel and the
  -- only place it appears. Read off the node; these were muted white at 10.
  R.imported = at(text(frame, "light", "chip", "accent"), innerX, RN_IMPORTED_Y, innerW)
  R.synced   = at(text(frame, "light", "chip", "accent"), innerX, RN_SYNCED_Y, innerW)

  -- ── Right column ──────────────────────────────────────────────────────────
  -- ⚠️ THE LEAD IS WHITE AT 16, NOT GREEN AT 11. Green is the status block's
  -- colour and means "you are running loot"; reusing it on a sentence that
  -- merely describes what that implies spends the signal twice.
  R.lead    = at(text(frame, "regular", "badge", "white"), RN_COL_X, RN_LEAD_Y, RN_COL_W)
  R.leadSub = at(text(frame, "light", "small", "white"), RN_COL_X, RN_LEAD_SUB_Y, RN_LEAD_SUB_W)
  R.leadSub:SetWordWrap(true)

  local function hairline(y)
    local t = frame:CreateTexture(nil, "ARTWORK")
    t:SetSize(RN_COL_W, 1)
    t:SetPoint("TOPLEFT", RN_COL_X - 1, -y)
    -- The same #AC7666 at 30% every other rule in the design uses.
    if ns.Style then
      t:SetColorTexture(ns.Style.COLOR.rule.r, ns.Style.COLOR.rule.g,
        ns.Style.COLOR.rule.b, 0.3)
    end
    return t
  end
  R.d1, R.d2, R.d3 = hairline(RN_D1_Y), hairline(RN_D2_Y), hairline(RN_D3_Y)

  -- Every section heading on this column is 16 Regular; what varies is only
  -- which half is the heading purple. See renderRunner.
  R.peersHead = at(text(frame, "regular", "badge", "white"), RN_COL_X, RN_PEERS_Y, RN_COL_W)
  R.peers = {}
  for i = 1, RN_PEER_ROWS do
    local y = RN_PEER_TOP + (i - 1) * RN_PEER_PITCH
    R.peers[i] = {
      name = at(text(frame, "light", "small", "white"),
                RN_COL_X + RN_PEER_NAME_X, y, 90),
      ver  = atRight(text(frame, "light", "small", "white"),
                RN_COL_X + RN_PEER_VER_R, y, 110),
      gear = atRight(text(frame, "light", "small", "white"),
                RN_COL_X + RN_PEER_GEAR_R, y, 110),
    }
  end

  R.missHead = at(text(frame, "regular", "badge", "white"), RN_COL_X, RN_MISS_Y, RN_COL_W)
  R.missBody = at(text(frame, "light", "small", "white"), RN_COL_X, RN_MISS_BODY_Y, RN_COL_W)
  R.missBody:SetWordWrap(true)

  R.specHead = at(text(frame, "regular", "badge", "white"), RN_COL_X, RN_SPEC_Y, RN_COL_W)
  R.specBody = at(text(frame, "light", "small", "white"), RN_COL_X, RN_SPEC_BODY_Y, RN_COL_W)
  R.specBody:SetWordWrap(true)

  -- Everything above is hidden until the tab is on screen.
  -- R.div is gone with the redesign — the filled rail blocks are the separator.
  R.all = { R.status, R.since, R.dataHead, R.raiders, R.ranked, R.imported,
            R.synced, R.lead, R.leadSub, R.peersHead, R.missHead, R.missBody,
            R.specHead, R.specBody, R.d1, R.d2, R.d3,
            R.statusBox, R.dataBox }
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
  -- 14 Bold in the blush, right-aligned to the window's own margin (node
  -- 588:1667) — not the 16px orange it was, which predates the redesign.
  frame.season = text(frame, "bold", "rank", "body", "RIGHT")
  frame.season:ClearAllPoints()
  frame.season:SetPoint("TOPRIGHT", frame, "TOPLEFT", SEASON_R, -SEASON_Y)
  frame.season:SetWidth(220)

  frame.rail = {}
  for i, y in ipairs(RAIL.y) do
    local b = buildRailBlock(frame, y, i, RAIL.h[i])
    local S = ns.Style
    if S and RAIL.bigColor[i] then
      b.big:SetTextColor(S.rgb(S.COLOR[RAIL.bigColor[i]]))
    end
    frame.rail[i] = b
  end

  -- The column headers are the SAME purple, weight and size as the rail's block
  -- headings — one heading treatment across the tab, which is what the mock
  -- draws and what the old 10px white version did not.
  frame.stHead = {
    at(text(frame, "bold", "head", "accent"), ST_NAME, ST_HEAD_Y, 80),
    atRight(text(frame, "bold", "head", "accent"), ST_EP_R, ST_HEAD_Y, 40),
    atRight(text(frame, "bold", "head", "accent"), ST_GP_R, ST_HEAD_Y, 40),
    atRight(text(frame, "bold", "head", "accent"), ST_PR_R, ST_HEAD_Y, 80),
    -- 90, not 60: "LAST ITEM" in Bold 12 does not fit 60 and was rendering as
    -- "LAST IT…". Measured against the bundled face rather than nudged.
    atRight(text(frame, "bold", "head", "accent"), ST_LAST_R, ST_HEAD_Y, 90),
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

--- The three fontstrings a source line is made of: "From ", the BOSS, and the
--- rest. Built as a group because the mock changes WEIGHT mid-line and a single
--- fontstring cannot.
---
--- ⚠️ COLOUR IS NOT A SUBSTITUTE FOR WEIGHT, and treating it as one is what
--- shipped first (Jason, Session 258: "you didn't honor the font weight I had
--- applied to the location of the drop"). The mock sets the boss in Manrope
--- BOLD white against Light blush; the first version kept one Light fontstring
--- and only recoloured the boss, which loses the emphasis the design is
--- actually made of. Three strings chained left-to-right costs two extra
--- widgets and reproduces it exactly.
--- Panel-local helpers for an item's identity — its icon, and its name's hover
--- target — shared by the Loot detail header and both Slots layouts.
---
--- ⚠️ ONE TABLE, NOT FOUR NAMES, AND THAT IS A HARD CONSTRAINT rather than a
--- style choice (Core §1.1, the Lua-5.1 limits box). Panel.lua sits near 5.1's
--- ceiling of 200 top-level locals: these went in as four locals first, took the
--- file's headroom from 7 to 3, and smoke.lua refused it — which is the S254
--- trap exactly, since 5.4 and 5.5 compiled it happily and only the runtime the
--- game uses would have said no. Group new helpers into a table.
local ITEM = {}

--- The item icon, drawn the way the design draws it everywhere it appears: a
--- 32px square, cropped to shed the border baked into every WoW icon, then
--- masked to a circle.
---
--- ⚠️ BOTH, AND THE CROP IS NOT REDUNDANT. A circle inscribed in a square still
--- touches all four edges at their midpoints — exactly where the border is —
--- so the mask alone leaves four bright nicks. Blizzard's own UI puts a mask
--- and a texcoord on one texture.
---
--- ONE BUILDER FOR THREE SURFACES (Session 259): the Loot detail header, the
--- Slots identity block and every Slots list row. Three copies of a crop, a
--- mask and a fallback texture is three chances for one of them to drift into
--- being a square while the other two are round.
function ITEM.BuildIcon(parent, size)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetSize(size, size)
  t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  if ns.Style then ns.Style.Round(parent, t) end
  return t
end

--- The link a CATALOGUE row should tooltip with — the level the item actually
--- drops at, never the level a bare item string reports.
---
--- ⚠️ A BARE LINK IS NOT "THE HONEST ANSWER", IT IS A WRONG NUMBER (Jason,
--- Session 259, and this shipped for an hour with a comment claiming the
--- opposite). Ethereal Netherwrap is the Destruction Warlock's M+ BIS waist and
--- tooltipped at ITEM LEVEL 28 with 4 armour beside an equipped 311 — because it
--- is one of the BIS picks with no record in our payload, so ItemLinkFor fell
--- back to "item:251222" and the client rendered the item's BASE level. The BIS
--- data was correct throughout; only the link was wrong. It read as the whole
--- page being untrustworthy, which is exactly what Core §7.7 forbids and what
--- the S251/S252 catalogue-link rules already say twice.
---
--- THE DISCRIMINATOR IS THE ONE THE ROW ALREADY USES. A pick with a payload
--- record is raid loot and draws a "From <boss>, <instance>" line from that same
--- record; one without is dungeon loot, which drops at a FIXED Hero 3/6 at every
--- key level from +10 up. Keying the link on the same fact means the tooltip and
--- the source line beneath it cannot disagree.
---
--- ⚠️ RAID LOOT FOLLOWS THE LOOT TAB'S CONTENT CONTROL (Jason, Session 259:
--- "there's no item level control on the Slots page itself, I thought it would
--- stand to reason that the one on the Loot page would carry over"). It was
--- hardcoded to Mythic for a day, on the reasoning that the control is
--- location-derived and this page's answer must not change as you walk around.
--- That reasoning was half right and the conclusion was wrong: the control is a
--- SETTING FIRST and only falls back to detection on AUTO, so an explicit
--- "Raid: Mythic" is a stated preference, not a fact about where you stand.
--- One control, both pages.
---
--- ⚠️ DUNGEON LOOT IGNORES IT, AND MUST. A key drops Hero 3/6 at every level
--- from +10 up, so "Raid: Mythic" has nothing to say about a dungeon item —
--- applying it would put a raid item level on loot that cannot drop at one.
--- This is why the two branches exist at all.
function ITEM.CatalogueLink(itemID)
  if not itemID then return nil end

  -- ⚠️ THE SOURCE'S OWN IDS FIRST, ALWAYS. When the guide states what the pick
  -- should be, that beats anything derived here — it is the only answer that is
  -- right for a crafted piece, and it needs no branch to be right for the other
  -- two. The branches below remain for picks the source names no ids for.
  local char = ns.ResolveCharacter and ns.ResolveCharacter()
  if char then
    local stated = ns.BisItemLink(itemID, char.className, char.specName, char.heroTree)
    if stated then return stated end
  end

  local data = ns.Data()
  local rec = data and (data.items or {})[itemID]
  if rec then
    local key = ns.DifficultyKey()
    return ns.RaidItemLink(itemID, key) or ns.ItemLinkFor(itemID, key)
  end
  return ns.MplusItemLink(itemID)
end

--- Point an icon at an item. The question mark matters: without it a recycled
--- row keeps the PREVIOUS item's art, which reads as the right icon for the
--- wrong item rather than as a missing one.
function ITEM.SetIcon(tex, itemID, icon)
  if not tex then return end
  if not icon and itemID and GetItemIcon then icon = GetItemIcon(itemID) end
  tex:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
end

--- height (optional): give the line a KNOWN rect instead of its own line box.
--- The boss and instance runs anchor to `pre`'s RIGHT, so they inherit whatever
--- vertical centre it has — which with no height is wherever the font puts it
--- (Core §1.1, S260). A caller aligning this line against anything passes the
--- leading it laid out with.
local function buildSourceLine(parent, x, y, width, height)
  local g = {}
  -- NO EXPLICIT WIDTH ON ANY RUN: each sizes itself to its own string, which is
  -- what makes the RIGHT-edge anchoring below exact.
  -- ⚠️ ALL THREE RUNS ARE WHITE, AND THE WEIGHTS ARE REGULAR / BLACK / REGULAR
  -- (Session 262, node 590:2008). It was Light blush around a Bold boss name —
  -- so the line was doing its emphasis with COLOUR as well as weight, where the
  -- design does it with weight alone and paints the whole line white.
  g.pre  = at(text(parent, "regular", "label", "white"), x, y)
  if height then g.pre:SetHeight(height); g.pre:SetJustifyV("MIDDLE") end
  g.boss = text(parent, "black", "label", "white")
  g.rest = text(parent, "regular", "label", "white")

  -- ⚠️ ANCHORED TO EACH OTHER'S RIGHT EDGE, ONCE, AT BUILD TIME (Session 260).
  -- These three runs used to be positioned by reading GetStringWidth in the very
  -- call that set the string — a measurement the client has not taken yet on a
  -- cold or first draw, the same trap Gloom's Build Barn hit in Session 246.
  -- On the first route Jason opened it came out short by about the width of a
  -- comma, so the instance run landed on top of its own ", " and the line read
  -- "The Twin FangsThe Venomous Abyss" — while the identical code one row below
  -- rendered correctly, which is exactly how a stale measurement looks.
  -- There is no measurement left here to be stale.
  g.boss:ClearAllPoints()
  g.boss:SetPoint("LEFT", g.pre, "RIGHT", 0, 0)
  g.rest:ClearAllPoints()
  g.rest:SetPoint("LEFT", g.boss, "RIGHT", 0, 0)
  g.width = width

  --- Write the three runs. Position is fixed at build time, so this only sets
  --- strings — and sets them through a forced repaint, because a source line is
  --- identity text on a RECYCLED row: the same boss can be written into the same
  --- row twice, and the second write would not redraw (Session 254).
  function g:Set(src)
    if not src or not src.boss then
      setTextForce(self.pre, "")
      setTextForce(self.boss, "")
      setTextForce(self.rest, "")
      return
    end
    setTextForce(self.pre, "From ")
    setTextForce(self.boss, src.boss)
    setTextForce(self.rest, src.instance and (", " .. src.instance) or "")
  end

  function g:SetShown(on)
    self.pre:SetShown(on); self.boss:SetShown(on); self.rest:SetShown(on)
  end
  return g
end

--- A right-aligned chip row: chips are laid out from the RIGHT edge inwards,
--- which is how the mock places them on both the identity header and every list
--- row. Shared by the two so they cannot drift apart.
local function layoutChipsRight(chips, owner, rightX, y)
  local x = rightX
  for i = #chips, 1, -1 do
    local ch = chips[i]
    if ch and ch:IsShown() then
      ch:ClearAllPoints()
      ch:SetPoint("TOPRIGHT", owner, "TOPLEFT", x, -y)
      x = x - ch:GetWidth() - SL.chipGap
    end
  end
end

--- One candidate row on the multi-item layout: a name that may carry a check,
--- a right-aligned chip row, and a source line beneath.
--- Hovering an item's NAME opens the game's own item card, which is what
--- hovering an item anywhere else in WoW does (Jason, Session 259).
---
--- ⚠️ THE TARGET IS THE STRING, NOT THE ROW. A Slots row is 55 tall and carries
--- a source line and up to four chips as well, so a row-wide hit area would open
--- an item tooltip over things that are not the item. It therefore has to be
--- RE-MEASURED on every draw — the string it covers changes with the slot.
---
--- ⚠️ NO TARGETING HINT HERE, unlike the two Loot-tab tooltips. Those rows carry
--- an OnClick that targets; a Slots row has none, and a tooltip offering an
--- interaction the surface does not have is worse than one that says nothing.
function ITEM.AttachTip(hit)
  hit:EnableMouse(true)
  hit:SetScript("OnEnter", function(self)
    if not self.itemID then return end
    local link = ITEM.CatalogueLink(self.itemID)
    if not link then return end
    -- The other half of the exclusion in Tip:Show — whichever opens last wins,
    -- and neither is ever left behind the other.
    ns.Tip:Hide()
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
    GameTooltip:SetHyperlink(link)
    GameTooltip:Show()
  end)
  hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return hit
end

--- Lay a name's hover target over the glyphs it actually drew.
---
--- ⚠️ MEASURED FROM THE STRING, NEVER FROM THE FONTSTRING'S WIDTH. Every name on
--- this page is given a 300px ceiling to wrap against, so reading GetWidth would
--- arm the tooltip across half a row of empty space — the item card would open
--- with the cursor nowhere near the item.
--- ⚠️ h IS NOT JUST THE HOVER TARGET'S HEIGHT — IT PLACES THE TAGS (Jason,
--- Session 262: "the tag list isn't lined up with the item name … the tags are
--- weirdly LOWER"). Every tag run anchors LEFT to this frame's RIGHT, which is
--- its vertical CENTRE, so a hit frame taller than the name's own rect drops
--- the whole tag line by half the difference. The OBTAINED BY routes passed 19
--- against a 14-tall name and the tags sat two and a half pixels low.
---
--- The safe value is the height the NAME was laid out with. Passing nil now
--- reads it off the fontstring rather than guessing, so the two cannot disagree.
function ITEM.FitTip(hit, fs, itemID, h)
  if not hit then return end
  hit.itemID = itemID
  local w = itemID and (fs:GetStringWidth() or 0) or 0
  if w <= 0 then hit:Hide() return end
  hit:SetSize(w, h or fs:GetHeight())
  hit:Show()
end

local function buildSlotListRow(parent, i)
  local row = CreateFrame("Frame", nil, parent)
  row:SetSize(SL.paneW, SL.listPitch)
  row:SetPoint("TOPLEFT", 0, -(i - 1) * SL.listPitch)

  -- The item's own icon, left of the two-line block and centred against it.
  row.icon = ITEM.BuildIcon(row, SL.itemIcon)
  row.icon:SetPoint("TOPLEFT", 0, -SL.listIconY)

  -- 13 Regular in the blush, exactly as the detail header's item name is — this
  -- IS that surface, one row per candidate instead of one item.
  -- ⚠️ 12 MEDIUM WHITE, NOT 13 REGULAR BLUSH (Session 262, node 626:487). This
  -- was the last surface still drawing the pre-refresh item name; the identity
  -- header and the routes were corrected earlier in the same pass, which would
  -- have left three names on one page in two treatments.
  row.name = at(text(row, "medium", "row", "white"), SL.textX, SL.listNameY, 300)
  row.name:SetHeight(SL.routeLineH)
  row.name:SetJustifyV("MIDDLE")

  -- Anchored to the fontstring rather than to the row's own geometry, so the
  -- target follows the name if the name ever moves and there is no second copy
  -- of the layout to keep in step.
  row.nameHit = ITEM.AttachTip(CreateFrame("Frame", nil, row))
  row.nameHit:SetPoint("TOPLEFT", row.name, "TOPLEFT", 0, 0)
  row.nameHit:Hide()

  -- ⚠️ THE CHECK FOLLOWS THE NAME, IT IS NOT RIGHT-ALIGNED. The mock puts it 6px
  -- past the end of the string (name w134, check at x140), so it reads as part
  -- of the name rather than as a column.
  row.check = row:CreateTexture(nil, "OVERLAY")
  row.check:SetSize(SL.checkW, SL.checkH)
  row.check:SetTexture(SLOT_CHECK_TEX)
  row.check:Hide()

  -- ⚠️ THE TAGS FLOW AFTER THE NAME (Session 261), they are not a right-aligned
  -- column any more. Anchored to nameHit rather than to the name fontstring:
  -- FitTip sizes the hit target to the STRING, while the fontstring carries a
  -- declared width, so anchoring to the latter would start the tags at a fixed
  -- x that has nothing to do with where the name ends.
  row.tagLine = buildTagLine(row, 6, 0, 4, row.nameHit)

  -- 10px, "From " light blush, the BOSS bold white, then the instance.
  row.source = buildSourceLine(row, SL.textX, SL.listSourceY, SL.paneW - SL.textX,
    SL.routeLineH)

  -- ⚠️ CENTRED IN THE GAP, NOT PINNED TO THE ROW'S BOTTOM EDGE (Jason, Session
  -- 262: "the separator line should be centered equally between the items …
  -- it's smashed against the lower item"). It sat at pitch-1 = 51, but a row's
  -- visible block is only the icon's 32 tall and the next block starts at 52 —
  -- so the rule had 19 above it and 1 below. Derived from the two numbers it
  -- sits between, so it follows if either moves.
  row.rule = divider(row, 0, SL.listRuleY, SL.paneW)

  row:Hide()
  return row
end

--- One route inside the OBTAINED BY panel.
local function buildSlotRoute(parent, i)
  local r = CreateFrame("Frame", nil, parent)
  -- Sized off panelW, not paneW: the OBTAINED BY panel narrowed to 428 when it
  -- moved in under the text column, so a route measured from the pane's full
  -- width would run 42px past the panel it sits inside.
  r:SetSize(SL.panelW - SL.panelPadX * 2, SL.blockH)

  -- ⚠️ ITS OWN ITEM ICON (Session 262, node 626:354). A route is the same
  -- shape as the identity line above it — 32px round icon, the same 42 gutter,
  -- then two lines — and it was drawing text alone.
  r.icon = ITEM.BuildIcon(r, SL.itemIcon)
  r.icon:SetPoint("TOPLEFT", 0, 0)

  r.name = at(text(r, "medium", "row", "white"), SL.textX, SL.routeTextY, 300)
  r.name:SetHeight(SL.routeLineH)
  r.name:SetJustifyV("MIDDLE")
  -- ⚠️ ANCHORED TO A FITTED HIT FRAME, NOT TO THE FONTSTRING (Session 262).
  -- r.name carries a 300px wrapping ceiling, so hanging the tags off its RIGHT
  -- edge started them at a fixed 306 — which is why the route kinds read as a
  -- right-hand column rather than flowing after the name the way the identity
  -- line and the list rows already do. FitTip measures the STRING.
  r.nameHit = ITEM.AttachTip(CreateFrame("Frame", nil, r))
  r.nameHit:SetPoint("TOPLEFT", r.name, "TOPLEFT", 0, 0)
  r.nameHit:Hide()
  r.tagLine = buildTagLine(r, 6, 0, 4, r.nameHit)
  r.source = buildSourceLine(r, SL.textX, SL.routeLineY,
    SL.panelW - SL.panelPadX * 2 - SL.textX, SL.routeLineH)

  r:Hide()
  return r
end

local function buildSlotsTab()
  -- ── The rail ──────────────────────────────────────────────────────────────
  -- Fourteen rows, built once. The icons come from the CLIENT rather than from
  -- bundled art, so unlike the boss portraits this never needs anything copied
  -- in at a new tier.
  frame.slotRail = CreateFrame("Frame", nil, frame)
  frame.slotRail:SetPoint("TOPLEFT", SL.railX, -SL.railY)
  frame.slotRail:SetSize(SL.railW, SL.rowH * 13 + SL.lastRowH)

  frame.slotRows = {}
  local y = 0
  for i, def in ipairs(ns.SLOT_ROWS or {}) do
    local last = (i == #ns.SLOT_ROWS)
    local h = last and SL.lastRowH or SL.rowH
    local row = CreateFrame("Button", nil, frame.slotRail)
    row:SetSize(SL.railW, h)
    row:SetPoint("TOPLEFT", 0, -y)
    row._index = i

    -- Only the SELECTED row is filled, at the rule blush's 10%. Every other
    -- state is bare — the rail carries no hover ground in the mock.
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    if ns.Style then
      row.bg:SetColorTexture(ns.Style.COLOR.rule.r, ns.Style.COLOR.rule.g,
        ns.Style.COLOR.rule.b, 0.1)
    end
    row.bg:Hide()

    -- ⚠️ CENTRED IN THE ROW, NOT ANCHORED TO ITS TOP (Jason, Session 258:
    -- "the gear slot names aren't vertically centered"). The mock's rows are
    -- 29 tall with a 26-tall text box in them, so the label sits on the row's
    -- middle beside a 20px icon that is itself centred. A TOPLEFT anchor at
    -- y=1 put the text above the icon's centre line on every row.
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(SL.iconSize, SL.iconSize)
    -- Centred rather than top-inset: the last row is 26 tall and the rest 29,
    -- so one constant top inset cannot centre the icon in both.
    row.icon:SetPoint("LEFT", row, "LEFT", SL.iconX, 0)
    local tex = ns.SlotIcon and ns.SlotIcon(def)
    if tex then row.icon:SetTexture(tex) end

    -- ⚠️ AFTER THE ICON AND LEFT-ALIGNED (Session 262). It was right-aligned to
    -- x 91, i.e. BEFORE the icon, which is the pre-refresh rail. 13 Medium
    -- white in a 26-tall box, so it centres against the icon beside it.
    row.label = text(row, "medium", "detail", "white", "LEFT")
    row.label:ClearAllPoints()
    row.label:SetPoint("LEFT", row, "LEFT", SL.labelX, 0)
    row.label:SetWidth(SL.checkX2 - SL.labelX)
    row.label:SetHeight(SL.labelH)
    row.label:SetJustifyV("MIDDLE")

    -- ONE PER SOCKET, outermost first. checks[1] is the rightmost and is the
    -- first to turn green, which is what the node draws on Trinket — grey at
    -- 140, green at 160 — and what puts a single-socket row's only check in the
    -- same place as a paired row's outer one.
    row.checks = {}
    for c, cx in ipairs({ SL.checkX, SL.checkX2 }) do
      local chk = row:CreateTexture(nil, "OVERLAY")
      chk:SetSize(SL.checkW, SL.checkH)
      chk:SetPoint("LEFT", row, "LEFT", cx, 0)
      chk:SetTexture(SLOT_CHECK_TEX)
      chk:Hide()
      row.checks[c] = chk
    end

    -- The last row drops its rule, which is the whole of why it measures 26.
    if not last then row.rule = divider(row, 0, h - 1, SL.railW) end

    row:SetScript("OnClick", function(self)
      state.slotIndex = self._index
      Panel.Refresh()
    end)

    frame.slotRows[i] = row
    y = y + h
  end

  -- ── The caption ───────────────────────────────────────────────────────────
  -- "Destruction Warlock BIS": the spec in Bold blush, the word BIS in Light
  -- white. Two fontstrings because one cannot carry two weights, anchored to
  -- each other so the pair stays glued as the spec name changes length.
  frame.slotBis = text(frame, "light", "rank", "white", "RIGHT")
  frame.slotBis:ClearAllPoints()
  frame.slotBis:SetPoint("TOPRIGHT", frame, "TOPLEFT", SL.capR, -SL.capY)
  frame.slotBis:SetText("BIS")

  frame.slotSpec = text(frame, "bold", "rank", "body", "RIGHT")
  frame.slotSpec:ClearAllPoints()
  frame.slotSpec:SetPoint("RIGHT", frame.slotBis, "LEFT", -4, 0)

  -- ── The view dropdown ─────────────────────────────────────────────────────
  frame.slotView = ns.Style and ns.Style.Control(frame, "Overall BIS")
  if frame.slotView then
    frame.slotView:SetSize(SL.viewW, SL.viewH)
    frame.slotView:SetPoint("TOPLEFT", SL.viewX, -SL.viewY)
    -- The page's other dropdown, same treatment (node 590:2051).
    ns.Style.LeftLabel(frame.slotView)
    frame.slotView:SetActive(true)
    frame.slotView.caret = frame.slotView:CreateTexture(nil, "OVERLAY")
    frame.slotView.caret:SetSize(SL.caret, SL.caret)
    frame.slotView.caret:SetPoint("RIGHT", -SL.caretR + SL.caret, 0)
    frame.slotView.caret:SetTexture(CARET_TEX)
    if ns.Style then
      frame.slotView.caret:SetVertexColor(ns.Style.rgb(ns.Style.COLOR.controlText))
    end
    frame.slotView:SetScript("OnClick", function()
      frame.slotMenu:SetShown(not frame.slotMenu:IsShown())
    end)
  end

  frame.slotMenu = CreateFrame("Frame", nil, frame)
  frame.slotMenu:SetFrameStrata("TOOLTIP")
  frame.slotMenu:SetSize(SL.viewW, #(ns.SLOT_VIEWS or {}) * SL.viewH)
  frame.slotMenu:SetPoint("TOPLEFT", SL.viewX, -(SL.viewY + SL.viewH))
  if ns.Style then ns.Style.Surface(frame.slotMenu, ns.Style.COLOR.control, 1) end
  frame.slotMenuItems = {}
  for i, choice in ipairs(ns.SLOT_VIEWS or {}) do
    local item = CreateFrame("Button", nil, frame.slotMenu)
    item:SetSize(SL.viewW, SL.viewH)
    item:SetPoint("TOPLEFT", 0, -(i - 1) * SL.viewH)
    item.label = at(text(item, "light", "head", "controlText"), 10, 6, SL.viewW - 20)
    item.label:SetText(choice.label)
    item:SetScript("OnClick", function()
      state.slotsView = choice.key
      state.slotIndex = state.slotIndex or 1
      frame.slotMenu:Hide()
      Panel.Refresh()
    end)
    frame.slotMenuItems[i] = item
  end
  frame.slotMenu:Hide()

  -- ── The single-item layout ────────────────────────────────────────────────
  frame.slotHead = CreateFrame("Frame", nil, frame)
  frame.slotHead:SetPoint("TOPLEFT", SL.paneX, -SL.headY)
  -- 32 — the icon's own height. The block is ONE line now, centred against it.
  frame.slotHead:SetSize(SL.paneW, SL.headBlockH)

  frame.slotHead.icon = ITEM.BuildIcon(frame.slotHead, SL.itemIcon)
  frame.slotHead.icon:SetPoint("TOPLEFT", 0, 0)

  -- ⚠️ 12 MEDIUM WHITE, ON ONE LINE (Session 262, node 591:2189). It was 13 in
  -- the blush over a second "Tier Piece" line; the refresh puts the name and its
  -- tags on a single 19-tall run sitting 6 down, which centres it against the
  -- 32px icon beside it.
  frame.slotHead.name = at(text(frame.slotHead, "medium", "row", "white"),
    SL.textX, SL.headNameY, 300)
  frame.slotHead.name:SetHeight(SL.headNameH)
  frame.slotHead.name:SetJustifyV("MIDDLE")
  frame.slotHead.nameHit = ITEM.AttachTip(CreateFrame("Frame", nil, frame.slotHead))
  frame.slotHead.nameHit:SetPoint("TOPLEFT", frame.slotHead.name, "TOPLEFT", 0, 0)
  frame.slotHead.nameHit:Hide()
  -- ⚠️ FOUR, NOT THREE (Jason, Session 258). Three BIS contexts can all apply
  -- at once, and the classification chip (TIER PIECE) comes AFTER them — so on
  -- a three-context item the purple chip was written into chips[4], which did
  -- not exist, and silently vanished. The mock shows both kinds together.
  -- FOUR SLOTS STILL, because three BIS contexts can apply before the
  -- classification (Session 258) — the count did not change, the widget did.
  frame.slotHead.tagLine = buildTagLine(frame.slotHead, 6, 0, 4, frame.slotHead.nameHit)

  frame.slotPanel = CreateFrame("Frame", nil, frame)
  frame.slotPanel:SetPoint("TOPLEFT", SL.panelX, -SL.panelY)
  frame.slotPanel:SetSize(SL.panelW, 131)
  if ns.Style then
    ns.Style.Surface(frame.slotPanel, ns.Style.COLOR.rule, 0.1)
  end
  frame.slotPanel.heading = at(text(frame.slotPanel, "bold", "head", "accent"),
    SL.panelPadX, SL.panelPadT, SL.panelW - SL.panelPadX * 2)
  frame.slotPanel.heading:SetText("OBTAINED BY:")
  frame.slotRoutes = {}
  for i = 1, SL.routeRows do
    frame.slotRoutes[i] = buildSlotRoute(frame.slotPanel, i)
  end

  -- ── The multi-item layout ─────────────────────────────────────────────────
  frame.slotList = CreateFrame("Frame", nil, frame)
  frame.slotList:SetPoint("TOPLEFT", SL.paneX, -SL.listY)
  frame.slotList:SetSize(SL.paneW, SL.listRows * SL.listPitch)
  frame.slotListRows = {}
  for i = 1, SL.listRows do
    frame.slotListRows[i] = buildSlotListRow(frame.slotList, i)
  end

  -- The one line that says why a slot is empty. Kept distinct from the shared
  -- tabEmpty, which is a whole-tab message rather than a per-slot one.
  -- Aligned to the TEXT column, because it stands in for the list of names and
  -- would otherwise be the only run on the page starting at the icon's edge.
  -- No node draws this state; the alignment follows what it replaces.
  frame.slotNote = at(text(frame, "light", "head", "textDim"),
    SL.paneX + SL.textX, SL.listY + SL.listNameY, SL.paneW - SL.textX)
  frame.slotNote:Hide()
end

local function buildDetailPane()
  -- ── The detail pane ───────────────────────────────────────────────────────
  frame.pane = CreateFrame("Frame", nil, frame)
  frame.pane:SetPoint("TOPLEFT", PANE_X, -PANE_Y)
  frame.pane:SetSize(PANE_W, PANE_H)
  -- ⚠️ NO PANEL BEHIND THE DETAIL COLUMN (Session 257). The old build filled it
  -- with a purple slab; the mock puts the detail straight onto the window ground
  -- and separates it with two hairlines instead. The slab was the single largest
  -- reason the right half read as a different design from the left.

  -- ── The header: the ITEM, and one verdict badge ──────────────────────────
  --
  -- ⚠️ THE ICON IS CIRCULAR AND 40px, matching the boss rail. Masked with the
  -- client's own portrait mask, so there is nothing to bundle.
  frame.itemIcon = ITEM.BuildIcon(frame, DET.icon)
  frame.itemIcon:SetPoint("TOPLEFT", DET.iconX, -DET.iconY)
  -- ⚠️ CIRCULAR, AND CROPPED. I got this wrong once and the correction is worth
  -- keeping (Jason, Session 258: "what the fuck do you mean it was never meant
  -- to be circular? It's circular in the Figma design").
  --
  -- WHY I GOT IT WRONG: the node metadata calls it a "rounded-rectangle", which
  -- is what Figma's exporter says for a rect with a 50% corner radius — a
  -- circle. I read the WORD and never looked at the render, on a page I had
  -- already been sent a screenshot of. Metadata describes the primitive, not
  -- the shape.
  --
  -- WHY THE BORDER SHOWED ANYWAY: Style.Round was failing silently — see the
  -- pcall note there. So the icon really was square on screen; the fix is to
  -- make the mask work, not to abandon it.
  --
  -- ⚠️ BOTH, WHICH DEVIATES FROM THE S257 NOTE saying never to combine a mask
  -- with SetTexCoord. That note's stated reason is "the mask already hides the
  -- icon border the crop was for", and that is FALSE for a circle inscribed in
  -- a square: the circle touches all four edges at their midpoints, which is
  -- exactly where the border is. Blizzard's own UI uses both on one texture.
  -- The crop trims 2.6px per edge at 32px, then the mask rounds what is left.
  -- Both live in buildItemIcon now, shared with the two Slots surfaces.

  -- ⚠️ BOTH LINES ARE WHITE (Session 262, corrected from the node). The earlier
  -- note here said the name was BLUSH and read it as a deliberate inversion of
  -- the left rail; node 577:880 paints the whole block white and colours only
  -- the "•" separators (#606060). What separates the two lines is WEIGHT AND
  -- SIZE — 14 Medium over 11 Light — not colour.
  -- Centred against the icon: the icon spans iconY..iconY+32 and the block is
  -- 28, so the block's top is iconY + 2.
  local blockTop = DET.iconY + math.floor((DET.icon - (DET.nameH + DET.line2H)) / 2)
  frame.itemName = at(text(frame, "medium", "item", "white"), DET.nameX, blockTop, 300)
  frame.itemName:SetHeight(DET.nameH)
  frame.itemName:SetJustifyV("TOP")
  frame.itemSub  = at(text(frame, "light", "small", "white"), DET.nameX,
    blockTop + DET.nameH, 300)
  frame.itemSub:SetHeight(DET.line2H)
  frame.itemSub:SetJustifyV("TOP")

  -- The verdict badge. Its ground is the blush at 10%, and the grade sits over
  -- the word "Upgrade" in two tight 10px lines — which is why both are anchored
  -- to the box rather than flowed.
  -- ⚠️ IT GROWS LEFTWARDS FROM A PINNED RIGHT EDGE, and that is not a
  -- refinement — the fixed 75 from the mock TRUNCATED ITS OWN EXAMPLE. Measured
  -- from the bundled TTF: "MAJOR" at 16 Bold is 55.0px against an inner width of
  -- exactly 55.0, which is the Session 252 trap word for word ("sized to its own
  -- string with 0.7px to spare... the game's text metrics differ slightly from
  -- the font's advance widths, so it tipped over"). It rendered "MAJ…".
  --
  -- And MAJOR is the SHORT one. The same 16px Bold measures MODERATE 86.6,
  -- SIDEGRADE 89.1 and "NOT FOR YOU" 103.8 — so no fixed width drawn for one
  -- word could have held the set. The right edge is what the mock actually
  -- fixes (623 + 75 = 698); the width follows the word.
  frame.badgeBox = CreateFrame("Frame", nil, frame)
  frame.badgeBox:SetSize(DET.badgeW, DET.badgeH)
  frame.badgeBox:SetPoint("TOPRIGHT", frame, "TOPLEFT",
    DET.badgeX + DET.badgeW, -DET.badgeY)
  if ns.Style then
    local S = ns.Style
    frame.badgeBg = frame.badgeBox:CreateTexture(nil, "BACKGROUND")
    frame.badgeBg:SetAllPoints()
    frame.badgeBg:SetColorTexture(S.COLOR.body.r, S.COLOR.body.g, S.COLOR.body.b, 0.1)
  end
  -- ⚠️ BOLD, AND IT IS THE ONLY BOLD IN THE PANEL. The mock sets the grade at
  -- 16 Bold and everything else Light or Regular, so this is the one place the
  -- third weight is bundled for.
  -- No SetWidth on either line: a fontstring with a fixed width TRUNCATES, and
  -- the box is what resizes here. They anchor to its right edge instead.
  -- ⚠️ THE PAIR IS CENTRED IN THE BOX, AND THE GAP IS THE GAP (Jason, Session
  -- 260: too much space between the two words, and the pair sits too close to
  -- the bottom edge). Both were the same cause. The lines were pinned from the
  -- box's TOP at 8, then stepped by 19 — a step chosen to clear the 16px Bold
  -- line box — so the visible pair ran 8..39 in a 40-tall box: eight pixels of
  -- air above and one below. And because the step had to clear a LINE BOX
  -- rather than the letters, it opened a gap the design does not have.
  --
  -- Both lines now carry an explicit height and centre their own line box
  -- inside it, so the step is between the TEXT rather than around its
  -- descender space. The stack is then centred in the box by arithmetic, which
  -- means changing either line's size cannot decentre the pair.
  local stackH = DET.badgeLine1H + DET.badgeGap + DET.badgeLine2H
  local stackTop = math.floor((DET.badgeH - stackH) / 2 + 0.5)

  frame.hUpgrade = text(frame.badgeBox, "bold", "item", "major", "RIGHT")
  frame.hUpgrade:SetPoint("TOPRIGHT", -DET.badgePadX, -stackTop)
  frame.hUpgrade:SetHeight(DET.badgeLine1H)
  frame.hUpgrade:SetJustifyV("MIDDLE")
  frame.hUpgradeWord = text(frame.badgeBox, "light", "chip", "white", "RIGHT")
  frame.hUpgradeWord:SetPoint("TOPRIGHT", -DET.badgePadX,
    -(stackTop + DET.badgeLine1H + DET.badgeGap))
  frame.hUpgradeWord:SetHeight(DET.badgeLine2H)
  frame.hUpgradeWord:SetJustifyV("MIDDLE")
  frame.hUpgradeWord:SetText("Upgrade")

  --- Resize the box around whichever verdict it is currently showing, never
  --- below the mock's own 75 so a short word still reads as the drawn block.
  function frame.badgeBox:FitToLabel()
    local w = math.max((frame.hUpgrade:GetStringWidth() or 0),
                       (frame.hUpgradeWord:GetStringWidth() or 0))
    if w > 0 then
      self:SetWidth(math.max(DET.badgeW, math.floor(w + 0.5) + DET.badgePadX * 2))
    end
  end

  -- The item name is the biggest representation of the item on screen, so
  -- hovering it should do what hovering an item anywhere else in the game does.
  frame.itemHover = CreateFrame("Frame", nil, frame)
  frame.itemHover:SetPoint("TOPLEFT", DET.iconX, -DET.iconY)
  -- Sized to the two-line BLOCK, not to the icon: the icon came down to 32 and
  -- the block is 34, so keying the hit area to the icon would leave the last
  -- 2px of the slot line unhoverable.
  frame.itemHover:SetSize(DET.badgeX - DET.iconX - 10, DET.nameH + DET.line2H)
  frame.itemHover:EnableMouse(true)
  frame.itemHover:SetScript("OnEnter", function(self)
    local itemID = Panel.CurrentItemID()
    local link = self.link or (itemID and ns.ItemLinkFor(itemID))
    if not link then return end
    -- The other half of the exclusion in Tip:Show — whichever opens last wins,
    -- and neither is ever left behind the other.
    ns.Tip:Hide()
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
    GameTooltip:SetHyperlink(link)
    -- ⚠️ THE TARGETING HINT RIDES HERE. Nothing else in the panel says a row can
    -- be right-clicked, so this is the only place targeting is explained.
    if itemID then
      GameTooltip:AddLine(ns.Targets and ns.Targets.Has(itemID)
        and "Right-click a row to stop targeting."
        or "Right-click a row to target it.", 0.6, 0.6, 0.7)
    end
    GameTooltip:Show()
  end)
  frame.itemHover:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- ── The meta line, between two hairlines ─────────────────────────────────
  --
  -- ⚠️ TWO FONTSTRINGS, BECAUSE A COLOUR ESCAPE CANNOT CHANGE WEIGHT. The mock
  -- writes this as one run: the facts in Light white, the separators in the
  -- accent purple, and the trailing tags — OVERALL BIS, TARGETED — in BOLD
  -- blush. WoW's |cff escape changes colour only, so the tags are a second
  -- string placed after the first is measured. The separators, being a colour
  -- change alone, stay inline.
  frame.div1 = divider(frame, DIV_X, DIV1_Y, DIV_W)
  -- ⚠️ CENTRED BETWEEN THE TWO RULES (Jason, Session 260: this line "isn't
  -- vertically centered between the two horizontal lines, and it looks
  -- sloppy"). It was anchored by its TOP at a y picked to look right, which
  -- makes the spacing a coincidence of the font's ascent rather than a
  -- statement — and it drifts the moment a size or a rule moves. Given the
  -- height of the band it lives in and JustifyV MIDDLE, the client centres it
  -- and the two dividers are the only numbers that decide where it sits.
  -- ⚠️ THE TAGS ARE THE ANCHOR NOW, NOT THE PLAIN HALF (Session 262). The line
  -- is RIGHT-aligned to the rules' own right edge, so the pair has to grow
  -- LEFTWARD: the tag run is pinned to that edge and the plain run hangs off its
  -- left. Anchored once here rather than at fill time, so the three fill sites
  -- that write only one half cannot leave the other pointing at a stale x.
  -- ⚠️ NO DECLARED WIDTH ON EITHER RUN, and this is load-bearing rather than
  -- tidy — buildSourceLine's own comment says the same thing for the same
  -- reason. A fontstring's TOPLEFT is the edge of its DECLARED RECT, not of the
  -- string it drew. Giving both runs a fixed 380 and hanging the plain half off
  -- the tags' TOPLEFT therefore pinned it to a constant x=380 whatever the tags
  -- said, and a right-aligned run ending there grows LEFT — straight across the
  -- boss column and through the item card names (Jason, Session 262: the line
  -- is "way over to the left, and is colliding with the item list name").
  --
  -- With no width each rect hugs its own string, so the pair chains right to
  -- left from the rules' right edge and cannot reach past its own text.
  local FACTS_BAND = DIV2_Y - DIV1_Y
  frame.factTags = text(frame, "bold", "label", "body", "RIGHT")
  frame.factTags:SetPoint("TOPRIGHT", frame, "TOPLEFT", DET.factsR, -DIV1_Y)
  frame.factTags:SetHeight(FACTS_BAND)
  frame.factTags:SetJustifyV("MIDDLE")
  frame.facts = text(frame, "light", "label", "white", "RIGHT")
  frame.facts:SetPoint("TOPRIGHT", frame.factTags, "TOPLEFT", 0, 0)
  frame.facts:SetHeight(FACTS_BAND)
  frame.facts:SetJustifyV("MIDDLE")
  frame.div2 = divider(frame, DIV_X, DIV2_Y, DIV_W)

  -- ⚠️ UPPERCASE, 11px LIGHT, BLUSH — the node's own treatment, not a grey
  -- sentence. Centred across the detail column at the y both empty-state frames
  -- put it (314 in one, 319 in the other; they are the same line to the eye).
  frame.paneEmpty = text(frame, "light", "small", "body", "CENTER")
  frame.paneEmpty:SetPoint("TOP", frame, "TOPLEFT", DIV_X + DIV_W / 2, -314)
  frame.paneEmpty:Hide()

  -- ⚠️ WON BY IS NOT IN THE MOCK and is kept anyway, moved onto the meta row's
  -- right end where nothing else sits. It states who actually received a drop,
  -- which the panel is the only surface to show during a raid; deleting a fact
  -- because a mock did not draw it is a scope decision, not a styling one.
  -- ⚠️ IT MOVED TO THE BAND'S LEFT END (Session 262). It used to sit right-
  -- aligned at 760 while the facts line ran from the left; the facts line is
  -- right-aligned to that same 760 now, so the two would have drawn through
  -- each other. The left half of the band is the space the refresh freed.
  frame.wonLabel = at(text(frame, "light", "label", "body", "LEFT"),
    DIV_X + DET.factsInset, DIV1_Y, 150)
  frame.wonLabel:SetHeight(DIV2_Y - DIV1_Y)
  frame.wonLabel:SetJustifyV("MIDDLE")
  frame.wonBy = frame.wonLabel

  -- The ranked table's column headings.
  frame.head = {}
  -- ⚠️ THE HEADERS ARE 12 AND IN THE ACCENT PURPLE, not 10 white — the mock
  -- treats them as headings rather than as labels, which is the same purple it
  -- uses for the Standings rail's section titles.
  --
  -- ⚠️ AND THEY ARE BOLD (Jason, Session 259: "everything just looks a bit
  -- off"). Node 577:907 is font-bold #9f50d4 12px, and these were drawn Light —
  -- which is why the table read as thinner and flatter than the mock while
  -- every position on it was correct. THE STANDINGS TABLE WAS ALREADY BOLD, so
  -- this was inconsistent with the addon's own other table as well as with the
  -- design.
  --
  -- CONFIRMED BY MEASUREMENT, not by reading the word "bold": Manrope-Bold at
  -- 12 sums to RAIDER 42.7 / UPGRADE 56.5 / ILVL GAIN 55.1 / PRIORITY 53.8
  -- against the node's own 44 / 56 / 56 / 54. Light sums 3-5px short of every
  -- one of them, which is the tell. test/measure-text.py does this.
  frame.head[1] = at(text(frame, "bold", "head", "accent"), C_NAME, RANK_HEAD_Y, 90)
  frame.head[2] = at(text(frame, "bold", "head", "accent"), C_UPGRADE, RANK_HEAD_Y, 110)
  -- 70, NOT 60: bold widened "ILVL GAIN" from 50.7 to 55.1 against a 60 field,
  -- which is 4.9px of slack — the S252 trap's own margin. It grows LEFTWARDS
  -- from its right edge into empty space, so nothing else had to move.
  frame.head[3] = atRight(text(frame, "bold", "head", "accent"), C_GAIN_R, RANK_HEAD_Y, 70)
  -- ⚠️ 64, NOT 48 — "PRIORITY" MEASURES 47.3px AND WAS TRUNCATING TO "PRIORI…".
  -- The field had been sized to the string with 0.7px to spare, which is not a
  -- margin: the game's own text measurement differs slightly from the font's
  -- advance widths (kerning, hinting, rounding), so it tipped over. Nothing had
  -- to move — the header is right-aligned at C_PRIORITY_R, so widening it grows
  -- LEFTWARDS into empty space, and the GAIN column's right edge is at
  -- C_GAIN_R (616, corrected in place Session 259 — this said 499, which was a
  -- pre-redesign value and made the clearance argument unverifiable) against
  -- this field's new left edge at 620.
  -- Header widths are now sized with real slack. Measured, not eyeballed:
  -- RAIDER 37.3 / UPGRADE 49.2 / GAIN 25.9 / PRIORITY 47.3 at 10px Semibold.
  frame.head[4] = atRight(text(frame, "bold", "head", "accent"), C_PRIORITY_R, RANK_HEAD_Y, 70)

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
    -- ⚠️ #AC7666 AT 10%, AND NO BORDER (Jason, Session 258). Read out of the
    -- footer's own SVG — `fill="#AC7666" fill-opacity="0.1"` — which is the
    -- SAME treatment as the Standings rail's blocks and the Slots page's
    -- OBTAINED BY panel: one lightening wash used everywhere the design wants a
    -- band to sit above the ground. What was here instead painted the footer
    -- the SAME colour as the window and then drew a rim on top, which is the
    -- separation done backwards — a line where the design has a surface.
    local bg = frame.foot:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(S.COLOR.rule.r, S.COLOR.rule.g, S.COLOR.rule.b, 0.1)
  end

  frame.gearLine1 = at(text(frame.foot, "body", "label", "body"), FOOT.textX, FOOT.line1Y, 240)
  frame.gearLine2 = at(text(frame.foot, "body", "label", "body"), FOOT.textX, FOOT.line2Y, 240)

  -- ⚠️ THE ROW IS RIGHT-ALIGNED AND ITS BUTTONS SIZE THEMSELVES, so the row's
  -- total width is only known once all three have measured their labels. Laying
  -- out from the left with a computed start is the same arithmetic either way,
  -- and it keeps ONE layout function rather than a mirrored second one.
  local function footButton(label, onClick)
    local b = ns.Style and ns.Style.Control(frame.foot, label, "head")
      or CreateFrame("Button", nil, frame.foot, "UIPanelButtonTemplate")
    b:SetScript("OnClick", onClick)
    return b
  end

  -- ⚠️ "IMPORT ROSTER DATA", NOT "IMPORT RAID NIGHT" (the mock's wording). The
  -- old label named the thing being imported FROM; this one names what arrives,
  -- which is what somebody looking for the button is actually thinking about.
  frame.load = footButton("IMPORT ROSTER DATA", function() ns.LoadWindow.Toggle() end)
  frame.log  = footButton("LOOT LOG", function()
    if ns.RecordWindow then ns.RecordWindow.Toggle() end
  end)
  frame.cfg  = footButton("SETTINGS", function() ns.Settings.Toggle() end)

  local btns = { frame.load, frame.log, frame.cfg }
  local total = 0
  for i, b in ipairs(btns) do
    total = total + (b:GetWidth() or 0) + (i > 1 and FOOT.gap or 0)
  end
  if ns.Style then
    ns.Style.LayoutRow(btns, frame.foot,
      FRAME_W - FOOT.right - total, -FOOT.btnY, FOOT.gap)
  end

  frame.load:SetScript("OnEnter", function(self)
    ns.Tip:SetOwner(self, "ANCHOR_CURSOR")
    ns.Tip:SetText("Import Raid Night", 1, 1, 1)
    ns.Tip:AddLine("Paste the export from the Loot Advisor page on the website.", 0.8, 0.8, 0.8, true)
    ns.Tip:AddLine("This is what supplies everyone's gear — the rankings need it.", 0.8, 0.8, 0.8, true)
    ns.Tip:Show()
  end)
  frame.load:SetScript("OnLeave", function() ns.Tip:Hide() end)
  frame.log:SetScript("OnEnter", function(self)
    ns.Tip:SetOwner(self, "ANCHOR_CURSOR")
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
    ns.Tip:SetOwner(self, "ANCHOR_CURSOR")
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
    ns.Tip:SetOwner(self, "ANCHOR_CURSOR")
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
  frame.standingsView:SetPoint("TOPLEFT", TOG.srcL, -TOG.y)
  frame.standingsView:Hide()

  frame.instDrop = ns.Style and ns.Style.Pill(frame, 170, 22, "")
    or CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.instDrop:SetPoint("TOPLEFT", TOG.srcL, -(TOG.y + 26))
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
  frame.encDrop:SetPoint("TOPLEFT", TOG.srcL, -(TOG.y + 52))
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
  buildSlotsTab()
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
  -- ⚠️ THE ORDER IS ns.SortedBosses' AND IS NOT RE-DERIVED HERE. It used to be,
  -- and then ns.BossIndexForEncounter needed the same order to answer "which
  -- row is this drop" — two copies of one ordering, with the copy that decides
  -- what you see living in a file no harness loads.
  local counts = ns.BisCountsByBoss()
  local targets = ns.TargetCountsByBoss()
  local out = {}
  for i, b in ipairs(ns.SortedBosses()) do
    out[i] = { id = b.id, name = b.name, order = b.order,
               bis = counts[b.id] or 0, targeted = targets[b.id] or 0 }
  end
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
    e.pairing = scored.result.pairing_required
    -- ⚠️ NIL, NOT ZERO, FOR A CONDITIONAL — and this arithmetic is exactly why.
    -- Your off-hand slot reads 0 because a two-hander leaves it EMPTY, so the
    -- subtraction returns the whole candidate item level as a "gain". That is
    -- the number the verdict exists to withhold, and it reached the header
    -- badge as MAJOR while the ranking row beside it already said NEEDS
    -- PAIRING: one panel, one item, two answers.
    -- From scoreIlvl, the UPGRADED level the badge was computed against — the
    -- website's gain column is measured the same way. e.candidateIlvl stays the
    -- dropped level, for the item line and the GP price.
    e.gain = (not e.pairing)
      and ((scored.scoreIlvl or scored.candidateIlvl or 0)
           - ((scored.equipped or {}).ilvl or 0)) or nil
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
  local e = state.sel and Panel._entries and Panel._entries[state.sel]
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
    frame.badgeBox, frame.div1, frame.facts, frame.factTags, frame.div2,
    -- paneEmpty is NOT here: it is the absence of the pane, so showing it with
    -- the rest would put "choose a boss" beside a fully drawn item.

    frame.itemIcon, frame.itemHover, frame.itemName, frame.itemSub,
    frame.wonLabel,
  }) do
    if part then part:SetShown(shown) end
  end
end

--- Blank every part of the detail pane that a view does not own, so nothing one
--- view sets bleeds into the next.
local function clearPane()
  frame.hUpgrade:SetText("")
  frame.badgeBox:Hide()
  frame.facts:SetText("")
  frame.factTags:SetText("")
  frame.itemIcon:Hide()
  frame.itemHover:Hide()
  frame.itemName:SetText("")
  frame.itemSub:SetText("")
  frame.wonLabel:Hide()
  frame.wonLabel:SetText("")
  frame.more:SetText("")
  frame.note:SetText("")
  setHeaders()
end

-- ⚠️ DECLARED BEFORE renderColumn CALLS THEM. A `local function` defined later
-- in the file is not in scope above its own declaration, so the call would
-- silently resolve to a nil GLOBAL — the same shape as the deleted-constant bug
-- the window harness now guards against.
local fillBossTile, fillItemRow

--- The left column: every boss, with the SELECTED boss's loot expanded inline
--- directly beneath its own row, and the remaining bosses continuing below that.
--- One list, one scroll.
---
--- ⚠️ THIS IS AN ACCORDION, NOT TWO STACKED LISTS, and getting that wrong is
--- what produced the "+5 more bosses — scroll" line Jason quite rightly called
--- nonsense. Reading the mock again says so plainly: the row above the item
--- cards is VASHNIK, the FOURTH boss, and it measures 36 where the three above
--- it measure 37 — it has dropped its bottom rule because its own loot is
--- joined to it. Bosses five through nine are not missing; they are below the
--- cards, off the bottom, reachable by scrolling the whole column.
---
--- The consequence for the code is that boss rows and item cards share ONE
--- ordered list and ONE scroll offset, and a row's y is the sum of everything
--- above it rather than its index times a pitch.
local function columnEntries(items)
  local out = {}
  local bosses = bossList()
  for i, b in ipairs(bosses) do
    out[#out + 1] = { kind = "boss", boss = b, index = i,
                      expanded = (i == state.bossIndex) }
    if i == state.bossIndex then
      for j, e in ipairs(items or {}) do
        out[#out + 1] = { kind = "item", entry = e, index = j }
      end
    end
  end
  return out
end

--- The height one entry occupies, INCLUDING the gap that follows it. An
--- expanded boss row is one pixel shorter because its rule is not drawn.
local function entryHeight(en)
  if en.kind == "boss" then
    return en.expanded and (BOSS_ROW_H - 1) or BOSS_ROW_H
  end
  return ITEM_PITCH
end

local function renderColumn(items)
  local list = columnEntries(items)
  local bosses = bossList()
  -- A boss list that shrank under a selection collapses rather than jumping to
  -- the first boss, which would silently expand something nobody chose.
  if state.bossIndex and state.bossIndex > #bosses then state.bossIndex = nil end

  -- ⚠️ THE SCROLL OFFSET IS AN ENTRY INDEX, and it is clamped by MEASURING from
  -- the end rather than by counting rows: entries are two different heights, so
  -- "the last N fit" is not a number that can be worked out from the count.
  local total = #list
  local maxScroll, acc = 0, 0
  for i = total, 1, -1 do
    acc = acc + entryHeight(list[i])
    if acc > COL_AREA_H then maxScroll = i; break end
  end
  if state.colScroll > maxScroll then state.colScroll = maxScroll end
  if state.colScroll < 0 then state.colScroll = 0 end

  local nextBoss, nextItem = 1, 1
  local y = 0
  for i = state.colScroll + 1, total do
    local en = list[i]
    local h = entryHeight(en)
    if y + h > COL_AREA_H then break end

    if en.kind == "boss" then
      local tile = frame.bossTiles[nextBoss]
      if not tile then break end
      nextBoss = nextBoss + 1
      fillBossTile(tile, en)
      tile:ClearAllPoints()
      tile:SetPoint("TOPLEFT", frame.col, "TOPLEFT", 0, -y)
      tile:SetHeight(h)
    else
      local row = frame.itemRows[nextItem]
      if not row then break end
      nextItem = nextItem + 1
      fillItemRow(row, en.entry, en.index)
      row:ClearAllPoints()
      -- ⚠️ CARD.x, NOT 0 (Session 262, Jason: "the loot items box inset isn't
      -- here"). The builder anchors each card at the indent and this loop's
      -- ClearAllPoints throws that away — so the cards filled the column from
      -- its own left edge, under the boss ICONS, instead of lining up under the
      -- boss NAME they belong to. The indent has to be re-stated here because
      -- the accordion re-anchors every row on every refresh.
      row:SetPoint("TOPLEFT", frame.col, "TOPLEFT", CARD.x, -y)
    end
    y = y + h
  end

  for i = nextBoss, BOSS_SLOTS do frame.bossTiles[i]:Hide() end
  for i = nextItem, COL_ROWS do frame.itemRows[i]:Hide() end

  -- ⚠️ NO "+N MORE" LINE ANYWHERE. The mock has none, the column simply
  -- continues past the bottom edge, and inventing one both cost a card's worth
  -- of height and printed through the first item's name.
  frame.colMore:SetText(total > 0 and maxScroll > 0
    and ("%d of %d · scroll"):format(
      math.min(total, state.colScroll + 1), total) or "")
end

--- Fill ONE boss row. Positioning is the column's job; this only writes.
function fillBossTile(tile, en)
  local b = en.boss
  tile.bossIndex, tile.bossName, tile.bossBis = en.index, b.name, b.bis

  -- ⚠️ BUNDLED SQUARE ART, MASKED TO A CIRCLE. Two wrong answers preceded it:
  -- the Encounter Journal's creature icon is WIDE, so a square tile squashed
  -- every face, and the client's portrait call returns a ROUND unit-frame
  -- portrait. These are Gloom's Build Barn's files, renamed from its WCL ids to
  -- the BLIZZARD encounter ids this payload is keyed by.
  -- ⚠️ TWO FOLDERS, TWO ID SPACES. Raid tiles are encounter ids, dungeon tiles
  -- are instance ids, and the ranges overlap by coincidence — one folder would
  -- eventually put a raid boss's face on a dungeon with nothing erroring.
  -- ⚠️ A NEW TIER NEEDS THE ART COPIED IN, or these fall back to initials.
  local folder = (ns.ContentMode() == "mplus") and "dungeons" or "bosses"
  tile.art:SetTexture(("Interface\\AddOns\\HoDLootAdvisor\\Media\\%s\\%d.png")
    :format(folder, b.id))
  local drew = tile.art:GetTexture() ~= nil
  -- Both of these are round and exactly one is ever shown, so each carries its
  -- own 1px ring — which follows it automatically; see Style.Round.
  tile.art:SetShown(drew)
  tile.fallback:SetShown(not drew)
  tile.initial:SetText(drew and "" or (b.name or "?"):sub(1, 1):upper())

  -- Shown BEFORE the name is written, then written through a forced repaint:
  -- a recycled row painted while hidden keeps its first blank forever, and a
  -- boss whose name matches the row's previous occupant would never redraw.
  tile:Show()
  setTextForce(tile.name, b.name or "")

  -- ⚠️ THE DIAMOND IS THE MOCK'S OWN, and it was missing entirely. It marks a
  -- boss holding something best-in-slot FOR YOU, which is the whole reason to
  -- scan the list — the count used to live in the retired context line, where
  -- it told you a number without telling you which boss it belonged to.
  -- The hit frame tracks the mark: no diamond, nothing to hover, and no
  -- invisible target sitting on the row's right edge swallowing clicks.
  tile.bis:SetShown((b.bis or 0) > 0)
  tile.bisHit:SetShown((b.bis or 0) > 0)

  -- ⚠️ THE COUNTS THEMSELVES (Session 261). `b.bis` has always been a number and
  -- only ever gated a diamond's visibility; the refresh prints it. The target
  -- count is new end to end — ns.BossItemCounts computes both.
  --
  -- Each group HIDES at zero rather than drawing "x0": a boss with nothing for
  -- you shows a bare name, which is what the mock draws and what keeps the list
  -- scannable. And a hidden icon means the next group's LEFT anchor collapses
  -- onto it, so the two close up rather than leaving a hole.
  local nBis, nTgt = b.bis or 0, b.targeted or 0
  setTextForce(tile.bisN, nBis > 0 and ("x" .. nBis) or "")
  tile.bisN:SetShown(nBis > 0)
  tile.tgt:SetShown(nTgt > 0)
  setTextForce(tile.tgtN, nTgt > 0 and ("x" .. nTgt) or "")
  tile.tgtN:SetShown(nTgt > 0)

  -- The rule is DROPPED on the expanded row, which is what joins a boss to the
  -- loot listed beneath it — and is why the mock's expanded row measures one
  -- pixel shorter than the others.
  tile.rule:SetShown(not en.expanded)
end

--- Fill ONE item card. Positioning is the column's job; this only writes.
function fillItemRow(row, e, idx)
  local S = ns.Style
  row.entryIndex, row.itemID, row.itemName, row.link = idx, e.itemID, e.name, e.link

  -- ⚠️ SHOW THE ROW BEFORE WRITING TO IT (Session 254). Written into a hidden
  -- row, a first paint does not take, and an unchanged string is never repainted.
  row:Show()

  -- ⚠️ THE LAST WRITER GUARDS TOO. `e.name or "?"` cannot save a row from "",
  -- and an invisible row is the one failure nobody reports as a bug — they
  -- report "the addon is broken". If this substitutes, the screen says
  -- "item:270160", which is a bug report rather than a mystery.
  local shown = e.name
  if type(shown) ~= "string" or shown == "" then
    shown = "item:" .. tostring(e.itemID)
  end
  setTextForce(row.name, shown)

  -- "NOT FOR YOU" stays deliberately DISTINCT from "UNSCORED": one is the
  -- system working, the other is our data falling short.
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

  -- ⚠️ ONE LINE, THREE TAGS, NO CHIPS (Session 261). The verdict leads because
  -- it is what you scan the column for; BIS and TARGET follow because they are
  -- facts about the item rather than claims about this raider. That ordering is
  -- what the chip KINDS used to encode, and with the boxes gone it is all that
  -- is left of the distinction — see buildTagLine.
  local tags = { { text = verdict, color = vColor } }
  local q = e.quality
  if q and q.bis then
    tags[#tags + 1] = { text = ns.BIS_SHORT[q.bis] or "BIS", color = "bis" }
  end
  if e.targeted then tags[#tags + 1] = { text = "TARGET", color = "target" } end
  row.tagLine:Set(ns.ItemSlotLine(e), tags)

  row.markTarget:Hide()
  row.markBis:Hide()

  row._selected = (idx == state.sel)
  row:PaintGround(false)
end

--- The header's verdict badge: the viewer's own answer for this item.
---
--- ⚠️ THE STANDING BLOCKS ARE GONE FROM HERE (Session 257). "Your Standing" and
--- the Priority / EP / GP figures used to sit beside this; the mock moves that
--- question to the Standings tab and its rail, and leaves the Loot header to
--- describe the ITEM. The Session 254 rule that the standing block and the
--- Standings tab must hide together is satisfied trivially now — there is no
--- standing block on this tab to disagree with anything.
local function renderPaneHeader(entry)
  local S = ns.Style
  frame.badgeBox:Show()

  -- Two lines, always: the grade and the word under it. The word is constant, so
  -- only the grade and its colour change.
  local label, color
  if not entry then
    label, color = "—", S and S.COLOR.grey
  elseif entry.ineligible then
    label, color = "NOT FOR YOU", S and S.COLOR.grey
  elseif entry.reason then
    label, color = "UNSCORED", S and S.COLOR.red
  elseif entry.pairing then
    -- BEFORE the is_upgrade test: a conditional IS an upgrade, and before the
    -- badge fallthrough, so it can never be dressed as a magnitude.
    label, color = "NEEDS PAIRING", S and S.COLOR.conditional
  elseif entry.isUpgrade == false then
    label, color = "NO UPGRADE", S and S.COLOR.grey
  else
    local l, c = badgeOf(entry.badge)
    label, color = (l or "?"):upper(), c
  end
  frame.hUpgrade:SetText(label)
  if S and color then frame.hUpgrade:SetTextColor(S.rgb(color)) end
  frame.badgeBox:FitToLabel()
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
  if not entry then
    frame.facts:SetText("")
    frame.factTags:SetText("")
    return
  end
  local S = ns.Style
  local parts = {}

  -- ⚠️ "ITEM LEVELS", NOT "ILVL" (the mock's own wording). This line is the one
  -- place the panel spells the measurement out; the abbreviation belongs in the
  -- table's column heading, where the space is genuinely tight.
  if entry.pairing and not entry.ineligible then
    -- NO NUMBER. The size of this upgrade depends on an item nobody can see.
    parts[#parts + 1] = ns.PAIRING_LABEL[entry.pairing] or "Needs a weapon pairing"
  elseif (entry.gain or 0) > 0 and not entry.ineligible then
    parts[#parts + 1] = ("+%d Item Levels"):format(entry.gain)
  end

  -- The viewer's own gap from the leader, read off the ranking rather than
  -- recomputed — and ABSENT rather than zero when the sort cannot guarantee
  -- score order, which is what makes a gap meaningful at all.
  local me = (UnitName("player") or ""):lower()
  for i, r in ipairs(ranked or {}) do
    if (r.name or ""):lower() == me then
      if r.gap and i > 1 then
        -- ⚠️ THE GAP IS ALREADY NEGATIVE. It is stored as
        -- `row.result.raw_score - top`, so a "-%d" format printed "--32 Behind"
        -- on screen. %d carries the sign the value already has.
        parts[#parts + 1] = ("%d Behind"):format(r.gap)
      elseif i == 1 then
        parts[#parts + 1] = "Top of the list"
      end
      break
    end
  end

  local price = ns.Payload.PriceText(entry.itemID, entry.candidateIlvl)
  if price then parts[#parts + 1] = "Cost: " .. price end

  -- ⚠️ THE TAGS ARE A SECOND FONTSTRING, IN BOLD, AND UPPERCASE. The mock sets
  -- OVERALL BIS and TARGETED in Manrope Bold #f2bdad while the facts either side
  -- are Light white — and a colour escape cannot change WEIGHT, only colour. So
  -- the facts run in one string and the tags in another, placed after the first
  -- has measured itself. They were previously inline, in the BIS yellow, which
  -- is a colour this line does not use anywhere.
  local tags = {}
  local q = entry.quality
  if q and q.bis then
    tags[#tags + 1] = (ns.BIS_LONG[q.bis] or "BIS"):upper()
  elseif q and q.grade then
    local tag = qualityTag(q)
    if tag then tags[#tags + 1] = (tag .. " GRADE"):upper() end
  end
  if entry.targeted then tags[#tags + 1] = "TARGETED" end

  -- ⚠️ "•" IN TRASH GREY, NOT A PIPE IN THE ACCENT (Session 262). This line was
  -- still drawing the pre-refresh separator while every other tag line in the
  -- panel had moved to the bullet — node 577:890 uses the same "•" at #606060
  -- the item cards and the ranking column do. One separator, one colour.
  local sepPlain = " " .. DOT .. " "
  local sep = S and (S.code(S.COLOR.grey) .. sepPlain .. "|r") or sepPlain

  if #parts == 0 and #tags == 0 then
    frame.facts:SetText(entry.reason or "")
    frame.factTags:SetText("")
    return
  end

  local left = table.concat(parts, sep)
  local right = table.concat(tags, sep)

  -- ⚠️ THE JOIN BETWEEN THE TWO STRINGS CANNOT BE A SPACE, and that is why the
  -- gap before the bold tag came out different from every other one. Leading
  -- and trailing whitespace is not reliably included in GetStringWidth, so a
  -- separator built from spaces at the boundary measures as narrower than the
  -- identical separator drawn INSIDE a string.
  --
  -- So the boundary is drawn as a real offset instead: the light run is
  -- measured, then one space's advance is added, and the bold run STARTS with
  -- the pipe. 2.00px is the space's own advance at 10px, summed from the
  -- bundled TTF rather than guessed.
  local SPACE_ADV = 2
  if left ~= "" and right ~= "" then
    right = (S and (S.code(S.COLOR.grey) .. DOT .. "|r") or DOT) .. " " .. right
  end

  frame.facts:SetText(left)
  frame.factTags:SetText(right)
  -- Only the GAP moves at fill time; the anchor itself is set once in build().
  frame.facts:SetPoint("TOPRIGHT", frame.factTags, "TOPLEFT",
    -((left ~= "" and right ~= "") and SPACE_ADV or 0), 0)
end

--- The selected item's identity row, and who won it.
local function renderItemIdentity(entry)
  if not entry then
    frame.itemIcon:Hide()
    frame.itemHover:Hide()
    frame.itemName:SetText("")
    frame.itemSub:SetText("")
    frame.wonLabel:Hide()
    frame.wonLabel:SetText("")
    return
  end

  ITEM.SetIcon(frame.itemIcon, entry.itemID, entry.icon)
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
  -- "Item Level 305", the mock's wording. The abbreviation belongs in the
  -- table's column heading, where the space is genuinely tight.
  if (entry.candidateIlvl or 0) > 0 then
    bits[#bits + 1] = ("Item Level %d"):format(entry.candidateIlvl)
  end
  -- ⚠️ THE BULLETS ARE #632753, NOT THE TEXT COLOUR. The mock colours the two
  -- separators in this line differently from the words either side of them, and
  -- a colour change is exactly what an inline escape CAN do — so this is one
  -- fontstring rather than five.
  local sep = ns.Style
    and (ns.Style.code(ns.Style.COLOR.control) .. " • |r")
    or " • "
  frame.itemSub:SetText(table.concat(bits, sep))

  -- WON BY, from the RECORDER. nil is a real answer and is shown as one: nothing
  -- in the addon registers that a roll ENDED, only that one started, so "still
  -- open" and "we never found out" are indistinguishable from here. Saying
  -- nothing is honest; a countdown or a "pending" would not be.
  local winner = entry.winner or (ns.Record and ns.Record.WinnerFor(entry.itemID))
  frame.wonLabel:SetShown(winner ~= nil)
  frame.wonLabel:SetText(winner and ("Won by " .. winner) or "")
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
  -- PRIORITY only when something can fill it — see the meta field's own note in
  -- Loot.RankRaiders. A heading over a column of em-dashes is a number we failed
  -- to find; no heading is a question that does not apply.
  -- "ILVL GAIN" is the mock's wording. "GAIN" alone left it ambiguous with the
  -- score gap sitting one column to its left, which is the exact confusion the
  -- Session 254 breakdown tooltip was added to settle.
  setHeaders("RAIDER", "UPGRADE", "ILVL GAIN", (meta and meta.priority) and "PRIORITY" or nil)

  if not ranked then
    -- ⚠️ SAY WHAT IS SHOWN, NOT ONLY WHAT IS MISSING. The grades and BIS marks
    -- in the column are the VIEWER'S OWN — scored from their equipped gear
    -- against the addon's baked-in tables, so they are fully correct with no
    -- roster loaded. Reading "nothing imported" beside a full column makes both
    -- halves look broken when neither is.
    --
    -- ⚠️ AND IT NO LONGER MEANS "NOTHING IMPORTED" (Session 256). Ranking works
    -- with no export now, off the group and the inspect pass, so the only way
    -- here is an item this season's table cannot describe — a dungeon drop, or
    -- loot from a tier we never imported. Telling someone to import a raid night
    -- would send them after a fix for a different problem.
    setHeaders()
    frame.more:SetText("")
    frame.note:SetText("The column is scored for you from your own gear. "
      .. "This item is not in the season's loot table, so it cannot be ranked "
      .. "across the group.")
    hideRows(1)
    return nil
  end

  local total = #ranked
  local maxScroll = math.max(0, total - RANK_ROWS)
  if state.rankScroll > maxScroll then state.rankScroll = maxScroll end

  if total == 0 then
    -- ⚠️ TWO DIFFERENT ANSWERS WERE BEING GIVEN ONE SENTENCE. This list holds
    -- people the item is an UPGRADE for, so an empty one usually means "nobody
    -- gains" — while the text claimed nobody could USE it, which is a statement
    -- about armour type and is often false. The distinction was invisible on a
    -- guild night and is the common case for one person browsing alone.
    local anyEligible = false
    for _, row in ipairs(_all or {}) do
      if row.eligible then anyEligible = true; break end
    end
    -- "Here" once the group is the roster, "on the roster" once an export is.
    local who = ns.Payload.Current() and "on the roster" or "here"
    frame.more:SetText("")
    frame.note:SetText(anyEligible
      and ("Not an upgrade for anyone %s."):format(who)
      or  ("Nobody %s can use this."):format(who))
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

    local displayName = r.name or "?"
    -- Only where an export exists to be off — see meta.roster. With none loaded
    -- every name here would carry the mark and the footnote would explain a
    -- roster that does not exist.
    if r.adhoc and meta and meta.roster then
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

    -- ── The UPGRADE column: chips, in the mock's own order ────────────────
    --
    -- ⚠️ THE VERDICT IS OUTLINED, THE LISTING IS FILLED, and the difference is
    -- meaning rather than decoration. An outlined chip is a claim about THIS
    -- RAIDER (their badge, their gap); a filled one is a fact about the ITEM
    -- that is true whoever is looking (O-BIS, R-BIS, TARGET). Mixing them would
    -- make "best in slot" look like one person's opinion.
    local tags = {}
    local label, color = badgeOf(r.result and r.result.badge)
    if label then tags[#tags + 1] = { text = label:upper(), color = color } end

    local qText = qualityTag(r.quality)
    if qText then tags[#tags + 1] = { text = qText:upper(), color = "bis" } end

    -- A raider ranked as one spec while standing in another gets a marker, and
    -- the sentence goes in the row tooltip. ns.SpecSplitTag stays quiet unless
    -- the spec change actually changes this item's grade.
    local splitMark, splitName, splitHelp = ns.SpecSplitTag(r)
    row.splitName, row.splitHelp = splitName, splitHelp
    if splitMark then tags[#tags + 1] = { text = "ALT SPEC", color = "accent" } end

    -- Gap is ABSENT, not zero, when the sort cannot guarantee score order — and
    -- it is always last, as the mock draws it.
    if r.gap and idx > 1 then
      tags[#tags + 1] = { text = r.gap == 0 and "tie" or tostring(r.gap), color = "body" }
    end
    row.tagLine:Set("", tags)
    row:AnchorScoreHit()

    -- One field on both paths (Loot.RankRaiders sets it, the wire carries it).
    --
    -- ⚠️ NIL, NOT ZERO, FOR A CONDITIONAL — the row is telling the reader that
    -- no honest gain exists, so the cell carries the CONDITION instead of a
    -- number. Reading it as 0 would blank the cell and lose the whole verdict.
    local gain = r.ilvlGain
    if r.result and r.result.pairing_required then
      row.gain:SetText(r.result.pairing_required == "main_hand" and "+1H" or "+OH")
      row.gain:SetTextColor(Style.rgb(Style.COLOR.conditional))
    else
      gain = gain or 0
      row.gain:SetText(gain > 0 and ("+%d"):format(gain) or "")
      row.gain:SetTextColor(unpack(WHITE))
    end

    -- What the UPGRADE cell's tooltip explains. The FACTORS are present only on
    -- a LOCALLY scored row — a ranking received from the runner carries the
    -- badge and the gap but not the arithmetic — and the tooltip says so rather
    -- than rendering an empty breakdown.
    row.scoreInfo = {
      gain    = gain,
      pairing = r.result and r.result.pairing_required or nil,
      factors = r.result,
      score   = r.result and r.result.raw_score or nil,
      gap     = (idx > 1) and r.gap or nil,
      leader  = ranked[1] and ranked[1].name or nil,
    }

    -- An em-dash here means "this person has no standing" and is right on a
    -- guild night, where the column exists and one ad-hoc raider is missing from
    -- it. With NO export there is no column at all — the heading is gone — so a
    -- dash in every row would be furniture for a question nobody asked.
    if r.pr then
      row.pr:SetText(("%.2f"):format(r.pr))
      row.pr:SetTextColor(unpack(WHITE))
    elseif meta and meta.priority then
      row.pr:SetText("—")
      row.pr:SetTextColor(unpack(MUTED))
    else
      row.pr:SetText("")
    end

    -- Which TIER this raider's gear came from. Three-tier provenance is only
    -- worth having if it is visible.
    local srcText, srcColor, srcHelp = ns.ProvenanceTag(r.equipped)
    row.src:SetText(srcText or "")
    if srcColor then row.src:SetTextColor(srcColor[1], srcColor[2], srcColor[3]) end
    row.srcHelp, row.srcName = srcHelp, r.name
    if r.adhoc and meta and meta.roster then
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

  renderColumn(entries)

  -- state.sel is nil until a card is clicked (Session 262), so this is guarded
  -- rather than leaning on Lua answering nil for a nil key.
  local entry = state.sel and entries[state.sel]

  -- NO SELECTION MEANS NO PANE, exactly as the empty-state mocks draw it. The
  -- whole right-hand side goes away rather than standing there empty.
  --
  -- ⚠️ TWO DIFFERENT EMPTIES, AND THE MOCK GIVES THEM DIFFERENT WORDS. "Choose
  -- a Boss to View Loot" is what you see with nothing expanded — the opening
  -- state — and "Choose an Item to View Details" once a boss is open but no
  -- card is picked. Collapsing both into one message would answer the wrong
  -- question in whichever state it was not written for.
  if not entry then
    showPaneSurface(false)
    showLootPaneParts(false)
    setHeaders()
    frame.more:SetText("")
    frame.note:SetText("")
    hideRows(1)
    frame.paneEmpty:SetText(state.bossIndex
      and "CHOOSE AN ITEM TO VIEW DETAILS"
      or  "CHOOSE A BOSS TO VIEW LOOT")
    frame.paneEmpty:Show()
    return
  end
  frame.paneEmpty:Hide()

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

  -- ⚠️ THE FIGURES ARE WHITE, NOT GREEN AND RED, and the LABEL is the blush one
  -- (node 587:1658). The old green-EP / red-GP pair was inventing a good/bad
  -- reading the design does not make: GP is what you have spent, not a warning.
  if S then
    local lbl = S.code(S.COLOR.body)
    blocks[2].line1:SetText(lbl .. "EP |r" .. ns.Commify(me.ep))
    blocks[2].line2:SetText(lbl .. "GP |r" .. ns.Commify(me.gp))
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
    -- "of 3", which is what the node says. "/3" was the pre-redesign wording.
    blocks[3].bigSuffix:SetText("of " .. tostring(me.nightsOf))
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
      -- ⚠️ BLUSH, NOT MUTED (Jason, Session 258: "the rank numbers aren't
      -- colored or weighted properly"). The row was BUILT bold-14-blush from
      -- node 587:1650 and then repainted grey here on every render — the build
      -- was right and the render undid it, which is why reading either one
      -- alone looked correct. It is the column you scan down, and the design
      -- gives it the only weight in the table.
      if ns.Style then row.rank:SetTextColor(ns.Style.rgb(ns.Style.COLOR.body)) end

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
      -- ⚠️ THIS WROTE TO row.upgrade, WHICH SESSION 262 DELETED, and no harness
      -- exercises the browse view — so it would have thrown on the first render
      -- in game and nothing here would have said so. Same seam as every other
      -- row now: one tag, in the rare colour.
      row.tagLine:Set("", r.veryRare and { { text = "RARE", color = "accent" } } or nil)
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


--- The chips one pick carries, in the mock's order: the BIS contexts first,
--- then what the item IS.
--- The tags a BIS pick carries: every context that lists it, then its
--- classification. Returns the list buildTagLine wants.
---
--- ⚠️ WAS fillPickChips (Session 261). Four chip slots became four text runs;
--- the SLOT COUNT is unchanged and still four, because three BIS contexts can
--- apply before the classification (Session 258).
---
--- ⚠️ THE CLASSIFICATION TAKES THE TIER GREEN, NOT THE HEADING PURPLE. The
--- refresh gives TIER PIECE / TIER TOKEN / CATALYZE TARGET the same green as
--- MAJOR, and Crafted the same blue as MODERATE (Jason, Session 261).
local function pickTags(pick)
  local tags = {}
  for _, view in ipairs(ns.SLOT_VIEWS or {}) do
    if pick.contexts and pick.contexts[view.key] then
      tags[#tags + 1] = { text = ns.BIS_CHIP[view.key], color = "bis" }
    end
  end
  -- kindTag lets an OBTAINED BY route reuse this whole function: its trailing
  -- tag is TIER TOKEN or CATALYZE TARGET rather than TIER PIECE, and everything
  -- before it is identical (Session 262).
  if pick.kindTag then
    tags[#tags + 1] = { text = pick.kindTag, color = "tier" }
  elseif pick.tierPiece then
    tags[#tags + 1] = { text = "TIER PIECE", color = "tier" }
  elseif pick.crafted then
    tags[#tags + 1] = { text = "CRAFTED", color = "crafted" }
  end
  return tags
end

local function renderSlots()
  -- ⚠️ TAKE THE LOOT TAB'S FURNITURE DOWN FIRST (Jason, Session 258). The
  -- Standings and Runner renderers both open with these four calls and this one
  -- did not, so the ranking table, its column headers and the two dividers went
  -- on drawing straight through the Slots page — a list of raiders with badges
  -- and priorities under a BIS item, which is not a thing this page has.
  --
  -- WoW frames do not clip their children and nothing errors, so a view that
  -- forgets to hide another view's widgets looks exactly like a half-built one.
  -- That is why this is four calls rather than a comment telling the next person
  -- to remember.
  showPaneSurface(false)
  showLootPaneParts(false)
  setHeaders()
  hideRows(1)
  frame.more:SetText("")
  frame.note:SetText("")

  local report = ns.SlotsReport and ns.SlotsReport(state.slotsView)
  if not report then return end

  -- ⚠️ EVERY IDENTITY STRING ON THIS PAGE GOES THROUGH setTextForce (Session
  -- 260). This whole screen was built after the Session 254 fix and inherited
  -- none of it: it wrote plain SetText into rows it had not shown yet, so on a
  -- FIRST draw the item name, the OBTAINED BY heading and the classification
  -- chip were all blank — permanently, since none of those strings changes
  -- again while the same slot stays selected. Jason found three of them on the
  -- first screen he opened.
  setTextForce(frame.slotSpec, report.specLabel or "")
  for _, v in ipairs(ns.SLOT_VIEWS or {}) do
    if v.key == state.slotsView and frame.slotView then
      setLabel(frame.slotView, v.label)
    end
  end

  -- Clamp rather than reset: a slot index left over from a previous view is
  -- still a valid row, and snapping back to Head every time the list changes
  -- would lose the reader's place for no reason.
  local nRows = #report.rows
  if nRows > 0 then
    if not state.slotIndex or state.slotIndex > nRows then state.slotIndex = 1 end
  end

  for i, row in ipairs(frame.slotRows) do
    local data = report.rows[i]
    row.bg:SetShown(i == state.slotIndex)
    setTextForce(row.label, data and data.label or "")
    -- ⚠️ A CHECK PER SOCKET, ALWAYS DRAWN (Session 262). Every row shows its
    -- sockets whether or not anything is owned — grey for an empty one, green
    -- once it is filled — so the rail reads as a checklist rather than as a
    -- sparse set of marks. This REPLACES the single violet check that was
    -- hidden at "none" and drawn at 0.4 alpha for the one-of-two case.
    local sockets = (data and data.sockets) or 1
    local owned   = (data and data.owned) or 0
    for c, chk in ipairs(row.checks) do
      if data and c <= sockets then
        chk:Show()
        -- Filled from the OUTSIDE in, so checks[1] — the rightmost — is the
        -- one that turns green first.
        local got = c <= owned
        chk:SetAlpha(got and 1 or 0.5)
        if ns.Style then
          chk:SetVertexColor(ns.Style.rgb(got and ns.Style.COLOR.green
                                              or ns.Style.COLOR.grey))
        end
      else
        chk:Hide()
      end
    end
  end

  local sel = report.rows[state.slotIndex]
  local picks = sel and sel.picks or {}

  -- Names arrive asynchronously for the 232 BIS items that are not in our loot
  -- table, so ask for them and come back — both halves, per the standing rule.
  ns.FillItemNames(picks)
  ns.WarmItemNames(picks)

  -- ⚠️ ROUTES DECIDE THE LAYOUT, NOT THE COUNT. A tier piece is the one thing
  -- that cannot simply be listed with a source line, because it does not drop —
  -- it is made, by a token or by the catalyst — so it gets the identity header
  -- and the OBTAINED BY panel the mock draws for it. Everything else is a list,
  -- including a slot with exactly one ordinary pick.
  local single = picks[1]
  local routes = {}
  if single and single.tierPiece and #picks == 1 then
    local char = ns.ResolveCharacter and ns.ResolveCharacter()
    routes = ns.ObtainRoutes(single.itemID, sel.key, char) or {}
  end
  if #routes > 0 then
    ns.FillItemNames(routes)
    ns.WarmItemNames(routes)
  end
  local useSingle = (#routes > 0)

  frame.slotHead:SetShown(useSingle)
  frame.slotPanel:SetShown(useSingle)
  frame.slotList:SetShown(not useSingle)

  if useSingle then
    -- The heading is written HERE rather than once at build time. Built, it was
    -- set into a panel that is hidden until a tier slot is selected, so its
    -- first paint never took — and "OBTAINED BY:" never changes, so nothing
    -- could ever redraw it. It was blank on every client, forever.
    setTextForce(frame.slotPanel.heading, "OBTAINED BY:")
    setTextForce(frame.slotHead.name, ns.NonEmpty(single.name) or ns.LOADING_NAME)
    ITEM.SetIcon(frame.slotHead.icon, single.itemID, single.icon)
    ITEM.FitTip(frame.slotHead.nameHit, frame.slotHead.name, single.itemID,
      SL.headNameH)
    -- ⚠️ THE KIND LINE IS GONE (Session 262). It read "Tier Piece" under the
    -- name while the tag run beside the name already said TIER PIECE — the same
    -- fact printed twice, once as a tag and once as a sentence. The node draws
    -- one line.
    frame.slotHead.tagLine:Set("", pickTags(single))

    local shown = 0
    for i, r in ipairs(frame.slotRoutes) do
      local route = routes[i]
      if route then
        shown = shown + 1
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", SL.panelPadX,
          -(SL.panelPadT + SL.headingH + SL.blockGap
            + (i - 1) * (SL.blockH + SL.blockGap)))
        -- Shown BEFORE anything is written into it — see setTextForce (S254).
        r:Show()
        setTextForce(r.name, ns.NonEmpty(route.name) or ns.LOADING_NAME)
        ITEM.SetIcon(r.icon, route.itemID, route.icon)
        ITEM.FitTip(r.nameHit, r.name, route.itemID, SL.routeLineH)
        -- ⚠️ THE ROUTE'S KIND FLOWS AFTER ITS NAME NOW, not right-aligned in
        -- the panel. The mock reads "Venomwoven Idol • O-BIS • M-BIS • TIER
        -- TOKEN" on one line, so the kind is the last tag rather than a box
        -- pinned to the far edge.
        --
        -- ⚠️ AND THE BIS CONTEXTS COME FIRST (Session 262). The kind was the
        -- only tag a route drew; the node draws the item's BIS listings ahead
        -- of it, in the same order pickTags uses for an ordinary pick, so a
        -- route and a pick read identically. See ns.ObtainRoutes for the rule
        -- this reverses.
        r.tagLine:Set("", pickTags({ contexts = route.contexts,
                                     kindTag = route.kind }))
        r.source:Set(route.source)
      else
        r:Hide()
      end
    end
    -- The panel is exactly as tall as the routes it holds, which is what makes
    -- a one-route slot read as finished rather than as a half-filled box.
    frame.slotPanel:SetHeight(SL.panelPadT + SL.headingH + SL.blockGap
      + shown * SL.blockH + math.max(0, shown - 1) * SL.blockGap + SL.panelPadB)
    frame.slotNote:Hide()
  else
    for i, row in ipairs(frame.slotListRows) do
      local pick = picks[i]
      if pick then
        -- Shown BEFORE anything is written into it — see setTextForce (S254).
        -- This is the row Jason opened on: the Head pick drew its source line
        -- and its icon with NO NAME at all, because the name was written while
        -- the row was still hidden and never changed afterwards.
        row:Show()
        setTextForce(row.name, ns.NonEmpty(pick.name) or ns.LOADING_NAME)
        ITEM.SetIcon(row.icon, pick.itemID, pick.icon)
        -- 16, not the row's 55: the name is one line of 13 Regular, and the
        -- source line 18px below it is a different item's worth of nothing.
        ITEM.FitTip(row.nameHit, row.name, pick.itemID, SL.routeLineH)
        -- The tags have to be written BEFORE the tick is placed: the tick
        -- anchors to whichever run the line ended on.
        row.tagLine:Set("", pickTags(pick))
        row.check:SetShown(pick.owned)
        if pick.owned then
          row.check:ClearAllPoints()
          -- 6px past the end of the string, so it travels with the name.
          --
          -- ⚠️ ANCHORED TO THE TOOLTIP TARGET, NOT TO A SECOND MEASUREMENT
          -- (Session 260). This read GetStringWidth itself, one line after the
          -- name was written — the same in-frame measurement that put the
          -- source line's comma underneath its own boss name. FitTip has
          -- ALREADY measured that string to size the hit area directly above,
          -- so the tick now rides that one result. One measurement, and the
          -- tick cannot drift away from the region the tooltip covers.
          -- ⚠️ AFTER THE TAGS, NOT AFTER THE NAME (Session 262). Both used to
          -- anchor 6px past nameHit, so the tick drew through the first tag.
          row.check:SetPoint("LEFT", row.tagLine:Tail(), "RIGHT", 10, 0)
          if ns.Style then
            -- Green, like the rail's: the refresh makes green mean acquired.
            row.check:SetVertexColor(ns.Style.rgb(ns.Style.COLOR.green))
          end
        end
        row.source:Set(pick.source)
        -- Last visible row drops its rule, the same tell the rail uses.
        if row.rule then row.rule:SetShown(picks[i + 1] ~= nil) end
      else
        row:Hide()
      end
    end

    if #picks == 0 then
      frame.slotNote:Show()
      frame.slotNote:SetText(report.ready
        and ("No " .. (ns.BIS_CHIP[state.slotsView] or "BIS")
             .. " pick for " .. (sel and sel.label or "this slot") .. ".")
        or "No BIS data yet.")
    else
      frame.slotNote:Hide()
    end
  end
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
    -- WHITE, not green: the green belongs to the status block, which has
    -- already said you are running loot. See buildRunnerTab.
    if S then R.lead:SetTextColor(S.rgb(S.COLOR.white)) end
    R.leadSub:SetText("Late joiners get the roster from you. To hand over, another "
      .. "officer imports a newer export.")
  elseif r.runner then
    R.lead:SetText(("%s is ranking tonight's loot."):format(r.runner))
    if S then R.lead:SetTextColor(S.rgb(S.COLOR.white)) end
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
    -- ⚠️ TWO-TONE, per node 589:1732: the LABEL is the heading purple and the
    -- FIGURE is white. Every section heading on this column works this way, so
    -- the fontstring is white and the label carries an inline colour.
    R.missHead:SetText(ns.HeadingTwoTone("Not Reporting: ",
      ("%d of %d"):format(#missing, r.totalGear or #missing)))
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
    R.specHead:SetText(ns.HeadingTwoTone("Spec Differs from the Roster: ",
      tostring(#mism)))
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
  --
  -- ⚠️ AND THE SAME IS TRUE BY CHOICE (Session 258). "Disable Roster Import/EPGP
  -- System" is the mock's own row for somebody outside this guild who will never
  -- have an export: it turns the EPGP half off permanently rather than leaving
  -- them to notice it never populates. Scoring is untouched — that runs off the
  -- baked payload and their own gear and is exactly as useful to them.
  local noRoster = ns.Settings and ns.Settings.Get("noRoster") or false
  local standings = (not noRoster) and (ns.Payload.Current() and true or false)
  local visible = {}
  for _, name in ipairs(TABS) do
    local show = true
    if name == "Runner" then show = runner and not noRoster
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

  -- Re-laid out on every refresh rather than once at build, because a hidden
  -- tab must not leave a gap in the row — and with widths that follow their
  -- labels, closing a gap means re-running the whole row, not shifting an index.
  local row = {}
  for _, name in ipairs(visible) do
    local b = frame.tabs[name]
    -- ⚠️ SHOW FIRST, THEN WRITE (Session 254's rule, and the tab row is the
    -- second family of widget to need it). A control painted while hidden never
    -- repaints, because handing a fontstring its own string is not a change —
    -- which is exactly how Standings drew as a correctly-sized empty box after
    -- a raid night was imported.
    b:Show()
    if b.Repaint then b:Repaint():FitToLabel() end
    if b.SetActive then b:SetActive(name == state.tab) end
    row[#row + 1] = b
  end
  if ns.Style then ns.Style.LayoutRow(row, frame, PAD, -TAB_Y, TAB_GAP) end
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
  -- ⚠️ "N OF M REPORTING" IS GONE FROM HERE (Session 257, Jason's call on the
  -- new mock) and this REPLACES the Session 253 decision to show both. The
  -- figure was right and its home was wrong: it counts who else is running the
  -- addon, which is the Runner tab's whole subject, and on an ordinary night
  -- with one installer it sits at "0 of 24" in the corner of every screen
  -- reading like an alarm. What belongs here is the sweep — "has everyone
  -- present been read yet" — which is about THIS client's own data.
  local sweep = ns.InspectionSummary and ns.InspectionSummary()
  if sweep then
    frame.gearLine2:SetText(("%d of %d Inspected"):format(sweep.resolved, sweep.here))
  elseif not gear then
    -- Outside a group there is nobody to inspect and nothing to say, but a
    -- blank line under a live one reads as a value that failed to load.
    frame.gearLine2:SetText("No raid data imported")
  else
    frame.gearLine2:SetText("")
  end
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
  local onSlots = state.tab == "Slots"

  -- Nothing needs the whole-tab message any more: every tab renders.
  if frame.tabEmpty then frame.tabEmpty:Hide() end

  -- The Slots tab's own furniture, hidden as a group so nothing it owns can
  -- draw through another tab.
  frame.slotRail:SetShown(onSlots)
  frame.slotSpec:SetShown(onSlots)
  frame.slotBis:SetShown(onSlots)
  if frame.slotView then frame.slotView:SetShown(onSlots) end
  if not onSlots then
    frame.slotMenu:Hide()
    frame.slotHead:Hide()
    frame.slotPanel:Hide()
    frame.slotList:Hide()
    frame.slotNote:Hide()
  end

  -- The boss strip, the context line and the two filter toggles belong to the
  -- Loot tab: on the others they would offer navigation that changes nothing.
  -- ⚠️ NOT bossName / bossSub. They are RETIRED — the rail names its own bosses
  -- now — and this line was switching them back on for the Loot tab, so the
  -- boss name and "For You: 1 BIS | 0 Targets" drew straight through the first
  -- rail row. Hiding something at build is not enough if a refresh shows it.

  for _, s in ipairs({ frame.swSource, frame.swFilter }) do
    if s then
      s:SetShown(onLoot)
      s.left:SetShown(onLoot)
      s.right:SetShown(onLoot)
    end
  end
  frame.col:SetShown(onLoot)
  if frame.paneEmpty and not onLoot then frame.paneEmpty:Hide() end
  frame.colEmpty:SetShown(false)
  frame.colMore:SetShown(onLoot)
  if not onLoot then
    for i = 1, COL_ROWS do frame.itemRows[i]:Hide() end
    -- Dropped with the list it describes. A stale cache would let the Post
    -- button act on an item that is no longer on screen.
    Panel._entries = nil
  end

  if onLoot then
    -- Right-hand option selected = the knob sits right, which is the whole of
    -- the state the design shows.
    if frame.swSource then frame.swSource:SetSwitch(state.source == "table") end
    if frame.swFilter then frame.swFilter:SetSwitch(state.filter == "all") end
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
    -- ⚠️ NO LONGER HIDDEN ON AUTO, and that REVERSES the Session 252 gate. That
    -- rule said "the vault level of whatever this is" was a claim with no
    -- stated subject — which was true when AUTO showed only the word "Auto".
    -- It now reads "Auto: Heroic", so the subject IS stated and the reason has
    -- lapsed. What remains is the honest half: no checkbox if the payload
    -- carries no vault table, because then there is no number to compute.
    frame.vault:SetShown(onLoot and ns.VaultLevelsKnown())
    -- Re-read rather than trust the widget: the setting is also reachable from
    -- the Settings window, and the two must never disagree on screen.
    frame.vault:SetChecked(ns.VaultOn())
  end

  -- ⚠️ SHOWN ON RUNNER AS WELL AS STANDINGS (Session 252). The Runner mock puts
  -- the season in the same top-right slot; only the Loot design leaves it empty,
  -- because that is where its content control sits.
  -- ⚠️ THE IMPORT BUTTON GOES WITH THE REST OF THE EPGP MACHINERY, and the row
  -- is RE-LAID rather than left with a hole in it — LayoutRow places from the
  -- right, so hiding a button without re-running it leaves a gap where the
  -- button was rather than closing up.
  if frame.load then
    local hideLoad = ns.Settings and ns.Settings.Get("noRoster") or false
    frame.load:SetShown(not hideLoad)
    local btns, total = {}, 0
    for _, b in ipairs({ frame.load, frame.log, frame.cfg }) do
      if b:IsShown() then
        btns[#btns + 1] = b
        total = total + (b:GetWidth() or 0) + (#btns > 1 and FOOT.gap or 0)
      end
    end
    if ns.Style then
      ns.Style.LayoutRow(btns, frame.foot,
        FRAME_W - FOOT.right - total, -FOOT.btnY, FOOT.gap)
    end
  end

  frame.season:SetShown(onStandings or onRunner)
  frame.stList:SetShown(onStandings)
  frame.stNote:SetShown(onStandings)
  for _, h in ipairs(frame.stHead) do h:SetShown(onStandings) end
  -- The block's BOX carries every line now, so showing and hiding the group is
  -- one call rather than six per block — and a line can no longer be left
  -- visible over another tab because its key was missed off the list.
  for _, b in ipairs(frame.rail) do b.box:SetShown(onStandings) end
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
  elseif onSlots then
    renderSlots()
  else
    renderStandingsTab()
  end

  -- POST IS RUNNER-ONLY. Two people posting puts two different lists in raid
  -- chat for one item, and chat is the only thing a non-installer ever sees.
  -- ⚠️ CURRENT DROPS ONLY (Jason, Session 258). Post writes a shortlist for an
  -- item that JUST DROPPED into raid chat; on the Full Loot Table it would
  -- announce something nobody has won and nobody is rolling on — a list for a
  -- decision that is not being made. The runner and item-selected conditions
  -- were already right; the view was never checked at all.
  frame.post:SetShown(onLoot and state.source == "drops"
    and (ns.Comms and ns.Comms.IsRunner and ns.Comms.IsRunner())
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

--- Apply the user's Panel Size on top of whatever MakeWindow settled on.
---
--- ⚠️ MULTIPLIED ONTO THE CLIENT'S SCALE, NOT SUBSTITUTED FOR IT. MakeWindow may
--- have snapped the window onto whole pixels, and replacing that outright would
--- undo the crispness it bought. The baseline is remembered on first call so
--- repeated changes compound from the same place rather than from each other.
--- ⚠️ NOW A THIN WRAPPER OVER ns.ApplyWindowScale, WHICH DOES ALL FOUR WINDOWS.
--- This used to scale the panel and nothing else, so the setting appeared to do
--- nothing from inside the Settings window it was being changed in. Kept as a
--- name because Settings' apply hook and two call sites here use it.
function Panel.ApplyScale()
  ns.ApplyWindowScale()
end

function Panel.Show()
  if not frame then build() end
  -- ⚠️ THE OPENING LIST DEPENDS ON WHERE YOU ARE STANDING (Jason). Inside a raid
  -- the question is what dropped — and an empty drops list is still information
  -- there, because something is going to arrive. Anywhere else it is what CAN
  -- drop, since nothing ever will. Re-evaluated on every open, so a toggle made
  -- during a session sticks until the panel is closed.
  state.source = ns.DefaultLootSource()
  state.sel, state.colScroll, state.rankScroll = nil, 0, 0
  -- Collapsed on every open, for the same reason the source is re-evaluated
  -- here: the panel should present the same starting state each time rather
  -- than resuming a selection made before whatever just happened.
  state.bossIndex = nil
  -- The panel is the one window with no dock to fall back on — its build-time
  -- CENTER+260 IS the default — so it restores here rather than in
  -- DockBesidePanel.
  -- Re-read on every open: the size is also reachable from the Settings window,
  -- and the two must never disagree about how big this one is.
  Panel.ApplyScale()
  ns.RestoreWindowPosition(frame)
  frame:Raise()
  frame:Show()
  Panel.Refresh()
end

--- Open on a drop that has just been recorded, with its boss already expanded.
---
--- ⚠️ A COLLAPSED ACCORDION IS THE WRONG ANSWER TO "WHAT DROPPED" (Jason,
--- Session 263). Panel.Show deliberately opens with nothing expanded, which is
--- right when a person opened it themselves and has not said what they want to
--- look at. A DROP has said: an LFR kill opened the panel onto the full list of
--- the season's bosses and none of their loot, so the one screen the setting
--- exists to produce was the one it could not produce.
---
--- FALLS BACK TO THE PLAIN OPEN. An encounter we cannot place — a boss missing
--- from the payload, a drop seen without an ENCOUNTER_END whose loot-history id
--- matches nothing — leaves the collapsed list rather than expanding a boss
--- nobody killed.
---
--- ⚠️ AND IT SELECTS THE PIECE, because a kill is not a browsing session. Left
--- on "CHOOSE AN ITEM TO VIEW DETAILS" the raider has the drop on screen and
--- still has to click it to learn the one thing they opened it for, which is
--- who it is for. Selecting is what makes the ranking the FIRST thing drawn.
---
--- ⚠️ THE SELECTION IS AN INDEX INTO A LIST THAT DOES NOT EXIST YET, which is
--- why this refreshes twice. The column is built, ordered and filtered by
--- Refresh; only afterwards is there a position to point at. Cheap, and once
--- per new drop.
function Panel.ShowForDrop(encounterID, itemID)
  Panel.Show()

  -- ⚠️ A KILL SHOWS EVERYTHING THAT DROPPED, NOT JUST WHAT YOU CAN WEAR (Jason,
  -- Session 263). Usable Only is the right default for BROWSING — it is the
  -- viewer's own question — and it is the wrong one at the moment a boss dies,
  -- because the pane ranks the WHOLE RAID for each item and the person reading
  -- it is deciding who gets what. Filtering to the reader's own armour type
  -- removes precisely the items being decided, and does it silently: the list
  -- looks complete. A boss that drops nothing for your class showed an empty
  -- column under an expanded boss row.
  --
  -- IT IS RELAXED, NEVER RE-IMPOSED. The switch is on screen showing ALL LOOT,
  -- so this is visible state rather than a hidden override, and flipping it
  -- back holds until the next kill.
  state.filter = "all"

  -- ⚠️ AND THE LIST IS THE DROPS, ASSERTED RATHER THAN INHERITED. Panel.Show
  -- picks the opening list from where you are standing, which is right for a
  -- person opening the panel and wrong here: the rescan ladder runs FOUR
  -- MINUTES past a kill (Session 243) and a brand-new drop can land after you
  -- have stepped out of the instance — at which point "where you stand" answers
  -- Full Loot Table and the panel opens on a catalogue in response to a drop.
  state.source = "drops"

  local index = ns.BossIndexForEncounter and ns.BossIndexForEncounter(encounterID)
  if not index then return false end
  state.bossIndex = index
  -- The column scroll is an ENTRY index into a list whose length just changed,
  -- so it is reset with the selection rather than left pointing into the middle
  -- of the boss that was expanded before.
  state.sel, state.colScroll = nil, 0
  Panel.Refresh()

  -- ⚠️ IT CAN STILL FIND NOTHING and must then leave the pane empty rather than
  -- pointing at a row that is not drawn. Relaxing the filter above means an
  -- ordinary drop is always on the column, so what is left is the genuine
  -- absence: a drop the ordering dropped, or an item the boss list cannot place.
  if itemID then
    for i, e in ipairs(Panel._entries or {}) do
      if e.itemID == itemID then state.sel = i; break end
    end
    if state.sel then Panel.Refresh() end
  end
  return true
end

function Panel.Toggle()
  if not frame then build() end
  if frame:IsShown() then frame:Hide(); return end
  Panel.Show()
end
