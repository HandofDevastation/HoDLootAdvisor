-- Style.lua — the Loot Advisor's design layer
--
-- ONE PLACE for every colour, font and surface treatment, so the panel reads as
-- part of hodguild.com rather than as a stock WoW window. Values are the SITE's
-- DS 2.0 tokens (app/globals.css), copied deliberately rather than approximated:
-- if the site retunes a hue, this file is the single place that has to follow.
--
-- The baseline is Gloom's Build Barn, which already solved this for the talent
-- side — same fonts, same hues, same 1px-rim-over-dark-panel treatment. Two
-- addons from the same guild looking like two different products is the thing
-- worth avoiding, and matching an existing solved case beats inventing a second
-- visual language.
--
-- WHY BUNDLED FONTS. WoW does not expose web fonts, so Khand and General Sans —
-- the DS 2.0 type pair — have to ship as TTF alongside the addon. Media/fonts/
-- carries them with OFL.txt and FONT-LICENSES.md, which is not optional: the SIL
-- Open Font License requires the licence to travel with the font software, and
-- General Sans's terms require ITF to be credited by name.
--
-- ⚠️ TTF, NOT OTF. WoW's font renderer is unreliable with OTF — the same lesson
-- Build Barn learned. Every helper here falls back to the game font when a file
-- is missing, so a packaging mistake degrades to "looks stock" rather than to an
-- addon that will not draw.

local ADDON_NAME, ns = ...

local Style = {}
ns.Style = Style

-- ── Fonts ──────────────────────────────────────────────────────────────────

local FONT_DIR = "Interface\\AddOns\\HoDLootAdvisor\\Media\\fonts\\"

-- ⚠️ ONE FAMILY NOW, NOT TWO (Session 257). The redesign is set entirely in
-- MANROPE, so the old Khand-for-display / General-Sans-for-prose split is gone.
-- Only two weights are used and both were read out of the mock rather than
-- chosen: LIGHT carries every label, name and heading, and REGULAR appears in
-- exactly one place — the text inside a FILLED chip, where dark type on a light
-- ground needs the extra weight to hold at 9px.
--
-- ⚠️ MANROPE BECAUSE OF ITS LICENCE, NOT ONLY ITS SHAPES. The redesign was
-- drawn in Excon, which is free to USE and — under Fontshare's terms of
-- 17 Aug 2026 — not free to REDISTRIBUTE in a form anyone can extract, which is
-- exactly what a .ttf loose in an addon zip on a public repo is. Manrope is
-- under the SIL Open Font Licence, which permits bundling outright, and its
-- copyright line names NO Reserved Font Name — so the family may keep its name
-- even in a modified build. Jason changed the Figma file to match.
--
-- ⚠️ WoW CANNOT READ A VARIABLE FONT, and Manrope ships as one. These two files
-- are STATIC INSTANCES cut from it at wght 300 and 400 with fontTools — a
-- Modified Version in the OFL's sense, which the licence permits and which
-- carries the same licence onward (Media/fonts/Manrope-OFL.txt). Regenerating
-- them is a two-line script; the recipe is in FONT-LICENSES.md so nobody has to
-- rediscover which weights or how.
--
-- Style.SetFont falls back to the game font when a file is missing, so a clone
-- without them draws stock rather than not at all.
--
-- The old role NAMES are kept and repointed rather than renamed, because every
-- other file in the addon asks for a role by name; renaming them would be a
-- sweep across seventeen files to say the same thing.
-- ⚠️ SAIRA, AND IT IS THE ONLY FAMILY (Session 262). Manrope, General Sans and
-- Khand all leave with the last window that used them. Saira is SIL OFL and
-- declares no Reserved Font Name, so the cuts keep the name; the recipe and the
-- licence are in Media/fonts/FONT-LICENSES.md.
--
-- ⚠️ SAIRA VARIES ON TWO AXES — wght 100-900 AND wdth 50-125 — so a static must
-- pin BOTH. Instancing weight alone leaves the file carrying fvar, which is
-- still a variable font and which the game will not read. The designs are drawn
-- at width 100.
Style.FONT = {
  title    = FONT_DIR .. "Saira-Medium.ttf",
  titleMed = FONT_DIR .. "Saira-Medium.ttf",
  body     = FONT_DIR .. "Saira-Light.ttf",
  bodyMed  = FONT_DIR .. "Saira-Medium.ttf",
  -- ⚠️ WAS "the filled chip, and nothing else". THE CHIPS ARE GONE (Jason,
  -- Session 262: the outline "takes up too much vertical space and was
  -- distracting"), and what they carried is now colour-coded text in the
  -- heaviest weight. The role keeps its name because every call site asks for it
  -- by name, and it still means the same thing: this is a tag.
  label    = FONT_DIR .. "Saira-Black.ttf",
  -- The true weights, for call sites that should say what they mean rather than
  -- inherit a role name from the old pairing.
  light    = FONT_DIR .. "Saira-Light.ttf",
  regular  = FONT_DIR .. "Saira-Regular.ttf",
  medium   = FONT_DIR .. "Saira-Medium.ttf",
  bold     = FONT_DIR .. "Saira-Bold.ttf",
  black    = FONT_DIR .. "Saira-Black.ttf",
}

-- Type scale — every value read off the mock, all whole numbers.
--
-- The four old keys (head / row / small / tiny) are RETUNED IN PLACE rather than
-- retired, so the windows that have no mock yet move with the redesign instead
-- of staying on the old scale and reading as a different product. The new keys
-- name the roles the mock actually has.
Style.SIZE = {
  title   = 20,   -- window title (the panel's own is an image; see Style.Lockup)
  badge   = 16,   -- the large upgrade badge on the detail header
  rank    = 14,   -- the ranking column's position number
  detail  = 13,   -- detail-pane body
  head    = 12,   -- tabs, buttons, column headers
  row     = 12,   -- ranking rows, the densest text that must stay readable
  name    = 11,   -- boss, raider and item names
  small   = 11,
  label   = 10,   -- field labels, slot lines, the footer, the meta line
  tiny    = 10,
  chip    = 9,    -- both chip kinds
}

-- ── Colour ─────────────────────────────────────────────────────────────────
--
-- Hex, converted once, so these read the same as the values in globals.css and
-- can be diffed against it by eye.

local function hex(s)
  return {
    r = tonumber(s:sub(1, 2), 16) / 255,
    g = tonumber(s:sub(3, 4), 16) / 255,
    b = tonumber(s:sub(5, 6), 16) / 255,
  }
end
Style.hex = hex

Style.COLOR = {
  -- Surfaces (--bg-primary / --bg-secondary / --bg-elevated / --border)
  bg        = hex("0d0d14"),
  bgAlt     = hex("13131f"),
  elevated  = hex("1a1a2e"),
  border    = hex("2a2a45"),

  -- ── The panel's own ground (Session 250, from Jason's Figma) ──────────────
  -- The redesigned panel sits on a DARKER base than the rest of the addon and
  -- is rimmed in a light warm grey rather than the navy hairline. Added as new
  -- tokens rather than by retuning `bg`/`border`, because those two are what
  -- every OTHER window (Import, Loot Log, Settings) is painted with, and this
  -- pass has a mock for the panel only. Repointing them would restyle three
  -- windows nobody has designed yet, sight unseen and with no harness.
  -- ⚠️ RETUNED SESSION 257 from #060714. The redesign's ground is a deep
  -- VIOLET, not a near-black navy, and it is also the text colour inside a
  -- filled chip — so it is one token doing two jobs on purpose, the same way
  -- `rim` and `mutedGrey` are aliased below.
  ground    = hex("0c0721"),   -- panel + footer fill; also filled-chip text
  -- ⚠️ THE SECONDARY WINDOWS SIT ON A LIGHTER VIOLET THAN THE PANEL (Session
  -- 258, from the Import mock 591:2308). Import and Settings are #1c1228 while
  -- the panel is #0c0721 — and the panel's darker ground then reappears INSIDE
  -- them as the fill of the paste box, which is what makes an input read as
  -- recessed rather than as another panel. Two grounds on purpose, not a
  -- mismatch to reconcile.
  windowGround = hex("1c1228"),
  -- ⚠️ THE SAME FIGMA VARIABLE AS `mutedGrey` BELOW ("Muted Grey"), which the
  -- mock uses for BOTH the hairlines and the Runner tab's body copy. Written
  -- once and aliased below rather than as two identical literals, so a retune
  -- cannot move one and leave the other — this file exists to stop exactly that.
  rim       = hex("d9cee2"),   -- hairline, drawn at 0.4 alpha
  -- ⚠️ UNUSED SINCE SESSION 257 and kept only so the Session 250 note above
  -- still parses: the panel's ground is FLAT in the current design. Nothing
  -- reads these two. Delete them with the next tidy-up, not silently now — a
  -- token that vanishes mid-redesign is how a dangling read gets shipped.
  glowAlpha = 0.12,
  glowFrom  = 0.40,

  -- ── Text (Session 251 — READ OUT OF THE FIGMA MOCK, not the website) ──────
  --
  -- ⚠️ THESE WERE THE SITE'S CSS VARIABLES AND THAT WAS THE BUG. The comment at
  -- the top of this file says these are hex "so they read the same as the values
  -- in globals.css" — which is right for the website and wrong for this panel.
  -- --text-primary is #e8e8f0, a cool off-white; the mock is PURE WHITE. Nine
  -- percent darker with a lilac cast reads as "not quite white" on screen, which
  -- is exactly what Jason saw.
  --
  -- Verified against the mock directly, three text nodes plus the footnote:
  --   item name, slot line, column header  -> #ffffff
  --   the "*not on tonight's roster" note  -> rgba(255,255,255,0.5)
  --
  -- ⚠️ DIM IS WHITE AT HALF ALPHA, NOT A DARKER HUE. The old #9090b0 is a
  -- PURPLE, and a purple grey against a purple panel is why the secondary lines
  -- read as muddy rather than quiet. Alpha keeps the hue neutral over whatever
  -- it sits on, which is the property a hue cannot have.
  text      = hex("ffffff"),
  textDim   = { r = 1, g = 1, b = 1, a = 0.5 },
  -- The third step down, for the rail's least important line. No mock value
  -- exists for it, so it stays on the SAME ramp rather than inventing a hue —
  -- a guessed colour is how the first two got here.
  textMuted = { r = 1, g = 1, b = 1, a = 0.3 },

  -- Accent (--gold) — the site's brand accent, used for the title and targets.
  gold      = hex("f3c56b"),

  -- Semantic hues, straight from the site's --hue-* palette.
  green     = hex("20ba56"),   -- Major
  blue      = hex("3382ff"),   -- Moderate
  orange    = hex("ff7729"),   -- Minor, Grade S
  -- "Dark Orange" in the Figma file, read from the mock rather than derived
  -- (Session 252). NOT a shade of the --hue-orange above: it is its own named
  -- variable, and it is what the content control is filled with. Guessing a
  -- darker orange from ff7729 would have landed nowhere near it.
  darkOrange = hex("bb3f22"),
  grey      = hex("606060"),   -- Sidegrade, low grades
  red       = hex("c41e3a"),
  purple    = hex("8031ff"),
  hotPink   = hex("ff0080"),   -- --hue-hot-pink, the BIS colour (Session 245)
  white     = hex("ffffff"),

  -- ── Semantics the redesign introduces (Session 250, REVERSED Session 262) ──
  -- ⚠️ MAJOR IS GREEN AGAIN. Session 250 recorded the opposite in this exact
  -- spot — "MAJOR IS RED HERE, NOT GREEN" — because the 2026 mocks used a heat
  -- scale that cools. The Saira refresh goes back to a good/bad scale, which is
  -- what the pre-2026 panel used and what raiders already read. The old text is
  -- summarised rather than kept verbatim because leaving a sentence that says
  -- the opposite of the value beneath it is how the S253 handoff trap works.
  major     = hex("20ba56"),
  moderate  = hex("3382ff"),
  -- Rust. Aliased to darkOrange above rather than a second literal: one Figma
  -- variable, and two literals is one of them going stale.
  minor     = hex("bb3f22"),
  -- ⚠️ BIS AND THE TARGET SWAPPED ENDS (Session 262). Session 249 settled that
  -- these two must never share a hue and that BIS holds the gold-ish one. The
  -- first half still holds and is what matters; the second is now FALSE — BIS
  -- takes the violet that matches the gem icon, and the target takes the gold
  -- that matches its own new icon. Amended deliberately, not contradicted
  -- quietly.
  bis       = hex("9f50d4"),
  target    = hex("dca75e"),
  -- The tier family: TIER PIECE, TIER TOKEN, CATALYZE TARGET. Same green as
  -- MAJOR by design — see the collision note on Style.BADGE.
  tier      = hex("20ba56"),
  -- Crafted, on the Slots page (Jason, Session 262). Same blue as MODERATE.
  crafted   = hex("3382ff"),
  -- --hue-bright-purple. The Standings rail's section headings, and DISTINCT
  -- from `purple` (--hue-tab-stroke, the control fill) even though the two are
  -- neighbours: one is a surface, the other is type on it.
  railHead  = hex("936bff"),
  -- "Muted Grey" in the Figma file, added Session 252 with the Runner tab mock.
  -- ALIASED to `rim` above: one Figma variable, two roles (hairline and body
  -- copy), and two literals would be one of them going stale.
  --
  -- ⚠️ THIS IS NOT A RETREAT FROM "DIM IS ALPHA, NOT A HUE" above. That rule
  -- rejected #9090b0 — a DARK purple-grey that went muddy against a purple
  -- panel. This one sits near white and is a NAMED token in the mock; the
  -- rule's actual instruction is the one being followed, which is to read the
  -- colour out of Figma rather than derive one. Use it where the mock does;
  -- textDim remains the ramp everywhere else.
  mutedGrey = hex("d9cee2"),

  -- ── The 2026 redesign's palette (Session 257, read out of the Figma file) ──
  --
  -- ⚠️ THIS IS A DIFFERENT PALETTE, NOT A RETUNE OF THE ONE ABOVE. The panel
  -- moves from navy-and-gold to violet-and-blush, so these are new tokens and
  -- the old ones are left alone: the tokens above still paint the Import, Loot
  -- Log and Settings windows until each of those is rebuilt from its own mock.
  -- Repointing the shared ones would restyle three windows sight unseen, which
  -- is the same reasoning the Session 250 note above gives for `ground`.
  --
  -- ONE CONTROL SHAPE SERVES TABS AND BUTTONS ALIKE. The mock draws an inactive
  -- TAB and a FOOTER BUTTON identically — 1px `controlRim`, no fill, label at
  -- half alpha — and an active tab is the same box filled with `control` and
  -- its label at full. So there is one primitive, not two (Style.Control).
  control     = hex("632753"),   -- active tab + dropdown fill
  controlRim  = hex("6f2b57"),   -- the inactive control's 1px border
  controlText = hex("fef5bf"),   -- every tab and button label; 50% when inactive

  -- ⚠️ THE WORKHORSE, AND IT IS NOT WHITE. Boss names, the meta line, the
  -- footer and most chip text are all this warm blush.
  --
  -- ⚠️ WHITE AND BLUSH SWAP ROLES BETWEEN THE TWO ITEM SURFACES, and this is
  -- read out of the file rather than reasoned about. In the LEFT RAIL's cards
  -- the item name is white (11) over a blush slot line (10); in the DETAIL
  -- HEADER the item name is blush (13 Regular) over a WHITE slot line (12
  -- Light). An earlier version of this comment claimed white was "reserved for
  -- item names" — that is a generalisation from one of the two, and it is wrong.
  -- Take the colour from the node being built, never from a rule about which
  -- kind of thing it is.
  body        = hex("f2bdad"),

  -- Headings, and the MODERATE badge. The mock uses one purple for both.
  accent      = hex("9f50d4"),

  -- ⚠️ THE RULE COLOUR IS THE TITLE GRADIENT'S FAR END (#ac7666), and it appears
  -- at three alphas rather than as three colours: 0.3 for a row's bottom rule,
  -- 0.2 for the SELECTED item card's ground, and the same hue is what the
  -- lockup fades into. Written once because it is one colour.
  rule        = hex("ac7666"),
}

-- The badge ramp, in ONE place. Panel rows, the detail header and the item
-- column all read it, so a retune moves every surface at once instead of three
-- tables drifting apart — which is how the strip and the ranking list ended up
-- disagreeing about Moderate before.
-- ⚠️ IT IS A GOOD/BAD SCALE AGAIN (Session 262), AND THAT REVERSES THIS BOX.
-- Session 257 read a HEAT SCALE off the mocks — #ff595b -> #9f50d4 -> #ac7666 ->
-- #606060, red for the biggest upgrade — and recorded that the flip AWAY from
-- good/bad was deliberate and "inverts what a colour MEANS". The refresh flips
-- it back, confirmed by Jason against the new mocks:
--   MAJOR #20ba56 green · MODERATE #3382ff blue · MINOR #bb3f22 rust ·
--   SIDEGRADE #606060 grey, unchanged and the only survivor.
-- The old wording is kept above so nobody re-derives the heat scale from the
-- mocks it was true of. Green now means "biggest upgrade" and red-ish means
-- "least", which is the pre-2026 reading and the one raiders already had.
--
-- ⚠️ GREEN ALSO MARKS THE TIER FAMILY (TIER PIECE / TIER TOKEN / CATALYZE
-- TARGET). The two never share a line today — the Slots page draws no badges and
-- the Loot page draws no tier classification — so this is a latent collision,
-- not a live one. Worth knowing before any surface starts showing both.
Style.BADGE = {
  major     = { label = "Major",     color = "major" },
  moderate  = { label = "Moderate",  color = "moderate" },
  minor     = { label = "Minor",     color = "minor" },
  sidegrade = { label = "Sidegrade", color = "grey" },
}

--- The label and colour for a badge key. Falls back to Sidegrade's greyed
--- treatment rather than to nothing, so an unknown key is visible as a row
--- rather than as a blank cell that reads like a rendering fault.
function Style.Badge(key)
  local b = Style.BADGE[key or ""] or Style.BADGE.sidegrade
  return b.label, Style.COLOR[b.color] or Style.COLOR.grey
end

--- r, g, b for a colour, so call sites stay short at the WoW API boundary.
--- ⚠️ RETURNS FOUR VALUES NOW, NOT THREE. The design dims text by dropping
--- WHITE to 50% alpha rather than by switching to a darker hue, so alpha is part
--- of a colour here. Every SetTextColor call already passes this straight
--- through, so they all gained alpha without a single call site changing —
--- and `a` defaults to 1, so a colour that never had one behaves identically.
function Style.rgb(c)
  c = c or Style.COLOR.text
  return c.r, c.g, c.b, c.a or 1
end

--- "|cffRRGGBB" for inline colouring in a chat line or a tooltip.
---
--- ⚠️ FLATTENS ALPHA, because the escape code HAS none. Since the text ramp
--- became white-at-alpha (Session 251), three inline uses of textDim — the gap
--- column's "tie" and "-16", and the chat post's separator — would have come out
--- PURE WHITE and lost their whole reason for existing, silently and only in the
--- places that build a string rather than colour a fontstring.
---
--- Composited over the panel's own ground, which is what sits behind every
--- inline use of this. A chat frame is not that colour, but a dimmed grey there
--- is still far closer than undimmed white.
function Style.code(c)
  c = c or Style.COLOR.text
  local a = c.a or 1
  local r, g, b = c.r, c.g, c.b
  if a < 1 then
    local bgc = Style.COLOR.ground or { r = 0, g = 0, b = 0 }
    r = r * a + bgc.r * (1 - a)
    g = g * a + bgc.g * (1 - a)
    b = b * a + bgc.b * (1 - a)
  end
  return ("|cff%02x%02x%02x"):format(
    math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- ── Primitives ─────────────────────────────────────────────────────────────

local DEFAULT_FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

--- Apply a bundled font, falling back to the game font if the file is missing.
--- SetFont returns false rather than erroring on a bad path, which is what makes
--- the fallback possible — and why it must be checked rather than assumed.
function Style.SetFont(fs, path, size, flags)
  if not fs then return fs end
  if not fs:SetFont(path or Style.FONT.body, size or Style.SIZE.row, flags or "") then
    fs:SetFont(DEFAULT_FONT, size or Style.SIZE.row, flags or "")
  end
  return fs
end

--- A fontstring in the addon's type system.
--- role is a key of Style.FONT; size a key of Style.SIZE.
function Style.Text(parent, role, size, color, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  Style.SetFont(fs, Style.FONT[role or "body"], Style.SIZE[size or "row"])
  fs:SetTextColor(Style.rgb(color or Style.COLOR.text))
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end

--- A 1px rim around a frame, as four edge textures.
---
--- WoW has no border-radius and no CSS border, so the site's hairline card edge
--- becomes four 1px textures. Returns a handle with SetColor so a frame can
--- recolour its own rim (a selected chip brightens rather than redrawing).
--- A 1px rim around a frame, as four edge textures.
---
--- WoW has no border-radius and no CSS border, so the site's hairline card edge
--- becomes four 1px textures. Returns a handle with SetColor so a frame can
--- recolour its own rim.
---
--- ⚠️ IT CAN BE A GRADIENT, and in this design it IS. Pass `color2` and the rim
--- runs vertically from `color` at the top to `color2` at the bottom. Figma's
--- code output FLATTENS a gradient stroke to a single hex — the tab row reads
--- back as a flat #6f2b57 — so a border that looked solid in the generated CSS
--- is not solid in the file. That flattening is a known trap and it was walked
--- into anyway; the mechanism lives here so correcting the stops is one edit.
---
--- The two horizontal edges take the gradient's endpoints (a 1px strip has no
--- room for a ramp), and the two vertical edges carry the ramp itself. That is
--- the same result a real gradient stroke produces on a rectangle.
function Style.Rim(frame, color, alpha, thickness, color2)
  local c = color or Style.COLOR.border
  local a = alpha or 1
  local th = thickness or 1
  local e = {}
  for _, side in ipairs({ "top", "bottom", "left", "right" }) do
    local tex = frame:CreateTexture(nil, "BORDER")
    tex:SetColorTexture(c.r, c.g, c.b, a)
    e[side] = tex
  end
  e.top:SetPoint("TOPLEFT");     e.top:SetPoint("TOPRIGHT");     e.top:SetHeight(th)
  e.bottom:SetPoint("BOTTOMLEFT"); e.bottom:SetPoint("BOTTOMRIGHT"); e.bottom:SetHeight(th)
  e.left:SetPoint("TOPLEFT");    e.left:SetPoint("BOTTOMLEFT");  e.left:SetWidth(th)
  e.right:SetPoint("TOPRIGHT");  e.right:SetPoint("BOTTOMRIGHT"); e.right:SetWidth(th)

  --- One colour, or two for a vertical ramp. Guarded: CreateColor and
  --- SetGradient are modern-client globals, and a missing one must leave a flat
  --- rim rather than error on the frame that draws everything.
  function e:SetColor(nc, na, nc2)
    na = na or 1
    for _, side in ipairs({ "top", "bottom", "left", "right" }) do
      self[side]:SetColorTexture(nc.r, nc.g, nc.b, na)
    end
    if not nc2 then return end
    if not (CreateColor and self.top.SetGradient) then return end

    -- The two horizontal edges sit at one end of the ramp each, so they take a
    -- flat endpoint colour: a 1px strip has nowhere to put a vertical ramp.
    self.top:SetColorTexture(nc.r, nc.g, nc.b, na)
    self.bottom:SetColorTexture(nc2.r, nc2.g, nc2.b, na)

    -- ⚠️ THE BASE MUST BE WHITE OR THE GRADIENT IS MULTIPLIED INTO IT. This is
    -- the bug Jason screenshotted: the sides were painted #6f2b57 with
    -- SetColorTexture and THEN given a ramp, and WoW multiplies the two — so
    -- they came out a dark muddy constant that varied too little to read as a
    -- ramp at all. The border looked like three flat colours stacked, because
    -- effectively it was.
    --
    -- Style.PanelGround already did this correctly (SetColorTexture(1,1,1,1),
    -- then the gradient) and that precedent was sitting in this same file.
    for _, side in ipairs({ "left", "right" }) do
      self[side]:SetColorTexture(1, 1, 1, na)
      -- VERTICAL puts the FIRST colour at the BOTTOM, so the stops go in
      -- reversed against how the design reads them.
      pcall(self[side].SetGradient, self[side], "VERTICAL",
        CreateColor(nc2.r, nc2.g, nc2.b, na), CreateColor(nc.r, nc.g, nc.b, na))
    end
  end

  e:SetColor(c, a, color2)
  return e
end

--- The panel surface: a dark fill plus a hairline rim.
---
--- This is the addon's stand-in for .hod-glass. The site's card is a blurred
--- translucent pane over a flame background; WoW has no backdrop-filter, so the
--- honest translation is a near-opaque dark fill at the same colour the blur
--- resolves to, rather than a transparency that would show the game world
--- through a data panel and make it unreadable mid-raid.
--- A flat fill, and — only if asked — a border.
---
--- ⚠️ THE RIM IS NOW OPT-IN, AND IT USED TO BE UNCONDITIONAL (Jason, Session
--- 258: "you've randomly added an extra border around it for some reason").
--- Every caller of this got a #2a2a45 border whether the design had one or not,
--- which is where the outline around the Standings rail's four blocks, around
--- the Slots page's OBTAINED BY panel and around all three secondary windows
--- came from. None of those are bordered in Figma — they are FILLS, and the
--- fill is what separates them from the ground.
---
--- A function called Surface should paint a surface. Callers that genuinely
--- want an edge ask for one, and the two that did are unchanged.
function Style.Surface(frame, color, alpha, rimColor, rimAlpha)
  local c = color or Style.COLOR.bg
  local bg = frame:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  -- Opaque by default. This was 0.96, which would have composited 4% of the
  -- game scene into any surface painted without an explicit alpha.
  --
  -- ⚠️ AND IT WAS NOT THE CAUSE OF ANYTHING — recorded because I announced it as
  -- the answer to "why aren't the colours the values I specified" and it is not
  -- (Session 259). EVERY window overpaints this texture with an opaque one of
  -- its own: Style.PanelGround for the panel, and S.Surface(..., 1) in
  -- LoadWindow, RecordWindow and Settings, each hiding frame.bgTex first. The
  -- 0.96 never reached the screen anywhere. THE REVERT-CHECK IS WHAT CAUGHT
  -- THIS: putting 0.96 back changed no assertion, which is the S256 rule
  -- working — a probe that does not bite is telling you something.
  --
  -- Kept at 1 anyway, as a default nobody chose is a trap for the next surface
  -- that forgets an alpha. An explicit value still wins, which is what the
  -- deliberate 10% washes pass.
  bg:SetColorTexture(c.r, c.g, c.b, alpha or 1)
  frame.bgTex = bg
  if rimColor then
    frame.rim = Style.Rim(frame, rimColor, rimAlpha or 1)
  end
  return frame
end

--- A horizontal hairline, for separating a header from its list.
function Style.Divider(parent, color, alpha)
  local c = color or Style.COLOR.border
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetColorTexture(c.r, c.g, c.b, alpha or 1)
  t:SetHeight(1)
  return t
end

--- A solid status tag, the addon's version of .hod-status-tag: coloured fill,
--- white text, tight padding.
---
--- ⚠️ The fill colour must be a SATURATED mid-tone. The site's class hardcodes
--- white text, and shipping --hue-gold as a fill there produced 1.58:1 contrast
--- — unreadable. Same constraint applies here for the same reason.
function Style.Tag(parent, width, height)
  local tag = CreateFrame("Frame", nil, parent)
  tag:SetSize(width or 44, height or 14)
  tag.fill = tag:CreateTexture(nil, "ARTWORK")
  tag.fill:SetAllPoints()
  tag.text = Style.Text(tag, "label", "tiny", Style.COLOR.white, "CENTER")
  tag.text:SetPoint("CENTER")
  tag.text:SetWidth((width or 44) - 4)
  function tag:Set(label, color)
    if not label or label == "" then self:Hide() return end
    self.text:SetText(label)
    local c = color or Style.COLOR.grey
    self.fill:SetColorTexture(c.r, c.g, c.b, 1)
    self:Show()
  end
  return tag
end

--- The redesigned panel's ground: a near-black fill, a warm wash rising from the
--- bottom, and a light hairline rim.
---
--- OPT-IN, not applied by Style.Window. Only the panel has a design; painting
--- the other three windows this way would be inventing three more.
---
--- ⚠️ THE WASH IS A SIZED TEXTURE, NOT A THREE-STOP GRADIENT. WoW's SetGradient
--- takes exactly two colours, so the design's "transparent until 40%, orange at
--- 100%" becomes a texture occupying the BOTTOM 60% that fades in across its own
--- height. That reproduces the stop exactly instead of approximating it with a
--- guessed middle colour.
function Style.PanelGround(frame, height)
  local C = Style.COLOR

  -- ⚠️ REPLACE THE SHARED SURFACE, NEVER LAYER OVER IT. Style.Window has already
  -- painted a fill, a navy hairline rim, a title-bar band and the line beneath
  -- it. Adding a second fill and a second rim on top drew BOTH: a light rim
  -- outside a dark one with a black band across the top, which is what the panel
  -- shipped looking like. Everything the window put down comes off first.
  if frame.bgTex then frame.bgTex:Hide() end
  if frame.headTex then frame.headTex:Hide() end
  if frame.headLine then frame.headLine:Hide() end
  if frame.rim then
    for _, side in ipairs({ "top", "bottom", "left", "right" }) do
      if frame.rim[side] then frame.rim[side]:Hide() end
    end
  end

  local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
  bg:SetAllPoints()
  bg:SetColorTexture(C.ground.r, C.ground.g, C.ground.b, 1)
  frame.bgTex = bg

  -- ⚠️ NO WARM WASH (Session 257). A vertical orange gradient used to rise from
  -- the bottom 60% of the panel, taken from the Session 250 mock. THE CURRENT
  -- DESIGN HAS NO GRADIENT IN ITS GROUND — every frame in the Figma file is a
  -- flat #0c0721 — so the wash was this addon's invention surviving a redesign
  -- that replaced the surface it was painted on. Removed rather than retuned.
  frame.glowTex = nil

  -- ⚠️ NO OUTER BORDER (Jason, Session 258: "some kind of border all the way
  -- around the outside of the addon window that's not part of the design").
  -- Every frame in the Figma file is a flat fill to its own edge — the window
  -- reads as a shape because of its GROUND, not because of a line drawn round
  -- it. This was inherited from the pre-redesign window, where the hairline was
  -- the only thing separating a near-black panel from a near-black screen.
  frame.rim = nil
  return frame
end

--- A purple pill: the one control shape the redesign uses for tabs, the two
--- filter toggles and the footer buttons.
---
--- ⚠️ MARKED _hodStyled SO THE BUTTON SWEEP SKIPS IT. Style.Window hooks OnShow
--- to reskin every text button beneath it into the flat elevated treatment; a
--- pill that did not opt out would be painted purple here and grey a frame
--- later, which is the sort of fault that only appears in game.
---
--- `on` is the selected state: solid purple. Off is the same hue at 30%, which
--- is how the design distinguishes them — never a different colour, so the group
--- still reads as one control.
function Style.Pill(parent, width, height, label, size)
  local btn = CreateFrame("Button", nil, parent)
  btn._hodStyled = true
  btn:SetSize(width, height or 24)

  btn.fill = btn:CreateTexture(nil, "BACKGROUND")
  btn.fill:SetAllPoints()

  -- ⚠️ BUILT THE WAY GLOOM'S BUILD BARN BUILDS ITS BUTTONS, EXACTLY. The first
  -- version of this used Style.Text plus an explicit SetWidth and shipped a row
  -- of purple blocks with NO LABEL ON ANY OF THEM — eleven controls, every one
  -- blank. Three things differed from the recipe that has been drawing fine in
  -- the other addon for months: a fixed width on the fontstring, word wrap
  -- turned off, and no SetFontString wiring. Which of the three did it is not
  -- established, and guessing one is how it comes back; this removes all three
  -- and matches the proven recipe instead.
  --
  -- SetFontString is the one worth keeping regardless of cause: without it
  -- btn:SetText() silently updates nothing, so any future call site that reaches
  -- for the standard Button method gets a label that never changes.
  btn.text = btn:CreateFontString(nil, "OVERLAY")
  Style.SetFont(btn.text, Style.FONT.titleMed, Style.SIZE[size or "head"])
  -- ⚠️ REPOINTED TO THE REDESIGN'S PALETTE (Session 257). This primitive still
  -- draws the filter toggles and the difficulty control, which have no rebuilt
  -- version yet — and left on the old bright purple they sat beside the new
  -- controls looking like a different addon had been pasted into the window.
  -- Moving the COLOURS is not moving the shape: these keep their pill behaviour
  -- until each is rebuilt from its own mock, they just stop clashing meanwhile.
  btn.text:SetTextColor(Style.rgb(Style.COLOR.controlText))
  btn.text:SetJustifyH("CENTER")
  btn.text:SetPoint("CENTER")
  btn:SetFontString(btn.text)
  btn.text:SetText(label or "")

  --- on = selected/active. enabled = false dims the whole pill, for a control
  --- that is present but cannot act yet.
  ---
  --- The state is REMEMBERED on the button, because hover has to restore it: the
  --- fill's alpha is the only thing separating on from off, so a hover that set
  --- it and an OnLeave that reset it to a constant would silently promote every
  --- inactive pill the pointer crossed.
  --- ⚠️ THE COLOUR IS OPAQUE AND THE LEVEL IS SetAlpha — NEVER BOTH. Baking the
  --- alpha into SetColorTexture as well makes the two multiply, and the off
  --- state comes out far brighter than the design's 30%: on screen all four
  --- filter pills read as selected. This is written down in Gloom's Build Barn
  --- for the same reason, and this file did it wrong anyway.
  ---
  --- ⚠️ THE LABEL DIMS ON A TAB AND NOT ON A FILTER TOGGLE, because that is what
  --- the design does and the two are saying different things. An inactive TAB is
  --- a place you are not — the whole control recedes, text included. An inactive
  --- FILTER is a choice still on offer, so its fill dims and its label stays
  --- white and readable. Dimming both everywhere made the four filter pills look
  --- disabled rather than unselected.
  local OFF, ON = 0.3, 1
  btn._dimText = true
  function btn:SetPillState(on, enabled)
    self._on = on and true or false
    self._alpha = self._on and ON or OFF
    self.fill:SetAlpha(self._alpha)
    self.text:SetAlpha((self._dimText == false) and 1 or self._alpha)
    self:SetAlpha((enabled == false) and 0.4 or 1)
    self:EnableMouse(enabled ~= false)
  end
  --- Repaint the fill. Every pill is purple by default because that is what the
  --- tab row and the filter toggles are; the difficulty control is ORANGE in the
  --- design, and it is the only control on the row that selects CONTENT rather
  --- than a view, so it should not read as one more tab.
  ---
  --- ⚠️ OPAQUE HERE, ALPHA VIA SetPillState — never both, for the same reason
  --- the default fill is written that way directly above.
  function btn:SetPillColor(c)
    self.fill:SetColorTexture(c.r, c.g, c.b, 1)
    self.fill:SetAlpha(self._alpha or 1)
  end

  btn.fill:SetColorTexture(Style.rgb(Style.COLOR.control))
  btn:SetPillState(false)

  btn:HookScript("OnEnter", function(s)
    if s._on then return end
    s.fill:SetAlpha(0.55)
    if s._dimText ~= false then s.text:SetAlpha(0.8) end
  end)
  btn:HookScript("OnLeave", function(s)
    if s._on then return end
    s.fill:SetAlpha(s._alpha or OFF)
    if s._dimText ~= false then s.text:SetAlpha(s._alpha or OFF) end
  end)
  return btn
end

-- ── The 2026 redesign's two shared pieces (Session 257) ────────────────────

--- The ONE control shape: a square box with a centred label, sized to its text.
---
--- ⚠️ ONE PRIMITIVE, NOT THREE. The mock draws the tab row, the footer buttons
--- and the difficulty dropdown identically — and an INACTIVE TAB is
--- pixel-for-pixel a FOOTER BUTTON (1px rim, no fill, label at half alpha).
--- Reading them as three controls and building three is how the old panel ended
--- up with a pill that had to be told not to dim its own label depending on
--- which row it was standing in. They are one thing in two states.
---
--- ⚠️ THE WIDTH IS MEASURED, NOT TABULATED. The mock's four tabs are 72 / 78 /
--- 109 / 91 wide, which is exactly each label plus 20px of padding on each side
--- — so the padding is the design and the widths are a consequence. Hardcoding
--- the four numbers would silently truncate the day a label changes, which is
--- the failure the "measure the string" rule was written for. GetStringWidth
--- answers only once the font has loaded, so callers lay out AFTER setting text.
---
--- ⚠️ SQUARE CORNERS, DELIBERATELY (Jason). Four 1px textures, no artwork, any
--- size, recolourable — which is the whole reason the design has no rounding.
local CONTROL_PAD_X, CONTROL_H = 20, 27

-- How far DOWN a control's label is nudged from the geometric centre, in
-- pixels. See the note above btn.text: the client does not place a centred
-- fontstring on the optical centre of its glyphs, and every control label in
-- this addon is uppercase, so the unused descender space reads as a gap
-- underneath. One knob, one place, every button.
local CONTROL_TEXT_Y = 1

-- The gap between a dropdown's label and its caret, and the padding OUTSIDE
-- the caret. Read off the Slots node (590:2050): a 111-wide control with the
-- label at x20 running 57 wide, and the 6px caret at x91 — so 20 left of the
-- text, 14 between text and caret, and 14 beyond it.
-- ⚠️ JASON READS THE OUTER PADDING AS 20 (Session 260) and the node I could
-- reach measures 14; the Figma link had dropped by then, so his number is used
-- and this records the disagreement rather than burying it. If a dropdown now
-- looks too wide, this is why.
local CARET_GAP, CARET_PAD_R = 14, 20

function Style.Control(parent, label, size)
  local btn = CreateFrame("Button", nil, parent)
  btn._hodStyled = true
  btn:SetHeight(CONTROL_H)

  btn.fill = btn:CreateTexture(nil, "BACKGROUND")
  btn.fill:SetAllPoints()
  btn.fill:SetColorTexture(Style.rgb(Style.COLOR.control))
  btn.fill:Hide()

  -- ⚠️ A VERTICAL GRADIENT, #6f2b57 AT THE TOP TO #ac7666 AT THE BOTTOM (Jason,
  -- read out of Figma's Inspect panel — the code output flattens a gradient
  -- stroke to its first stop, which is why this looked like a solid #6f2b57 for
  -- three rounds). Both stops are already tokens: the rim's own colour, and the
  -- SAME #ac7666 the row rules and the MINOR badge are drawn in, which is the
  -- title lockup's far end. One warm colour running through the whole panel.
  btn.rim = Style.Rim(btn, Style.COLOR.controlRim, 1, 1, Style.COLOR.rule)

  -- Built the way Style.Pill is, for the reason recorded there: a fixed width on
  -- the fontstring plus no SetFontString wiring shipped a row of blank controls
  -- once already.
  btn.text = btn:CreateFontString(nil, "OVERLAY")
  Style.SetFont(btn.text, Style.FONT.light, Style.SIZE[size or "head"])
  btn.text:SetTextColor(Style.rgb(Style.COLOR.controlText))
  btn.text:SetJustifyH("CENTER")
  -- ⚠️ CENTRED IN THE BUTTON'S RECT, NOT BY ITS OWN LINE BOX (Jason, Session
  -- 260: every button label sits high, with more space under it than over).
  -- SetPoint("CENTER") on a fontstring with no height centres the LINE BOX,
  -- and a line box is not the text: it reserves descender space below the
  -- baseline whether or not the label has a descender, and every control label
  -- here is uppercase. So the glyphs ride above the middle by half the unused
  -- descent, on every button in the addon.
  --
  -- ⚠️ AND IT IS CORRECTED BY AN OFFSET, NOT BY A RECT. The tidy fix —
  -- SetAllPoints plus JustifyV MIDDLE — cannot be used here: a fontstring with
  -- a fixed WIDTH truncates, and FitToLabel sizes the button FROM
  -- GetStringWidth, so giving the string the button's rect makes the two size
  -- each other in a circle. Height alone changes nothing, because centring a
  -- taller box centres the same line box inside it.
  --
  -- ⚠️ THE MAGNITUDE IS NOT DERIVED AND IS NOT PRETENDING TO BE. Measured from
  -- the bundled TTF, Manrope's line-box centre sits 0.023 em ABOVE its cap
  -- centre, which predicts labels sitting LOW — the opposite of what is on
  -- screen — and at 13px it is a third of a pixel either way. So the client is
  -- not placing this the way the font metrics alone would suggest, and I could
  -- not settle which way from here. CONTROL_TEXT_Y is therefore ONE named knob
  -- with a starting value, in ONE place, feeding every control in the addon.
  -- If the labels still sit wrong, its sign and size are the only thing to
  -- change. Positive moves the label DOWN.
  btn.text:SetPoint("CENTER", 0, -CONTROL_TEXT_Y)
  btn.text:SetJustifyV("MIDDLE")
  btn:SetFontString(btn.text)
  btn._label = label or ""
  btn.text:SetText(btn._label)

  --- ⚠️ FORCE THE STRING TO REDRAW. Handing a fontstring the value it already
  --- holds does not repaint it, so a control whose FIRST paint happened while it
  --- was HIDDEN stays blank for the rest of the session — its string never
  --- changes, so nothing ever redraws it. That is the Session 254 rule, and the
  --- tab row is the second family of widget to hit it: Standings is hidden until
  --- a raid night is imported, so it was built, painted blank, and then shown as
  --- an empty box that had measured its own label correctly all along.
  --- Writing a different string first is what makes the second write a change.
  function btn:Repaint()
    self.text:SetText("")
    self.text:SetText(self._label or "")
    return self
  end

  --- Re-measure and resize to the current label. Safe to call repeatedly.
  function btn:FitToLabel()
    local w = self.text:GetStringWidth() or 0
    -- A zero width means the font has not loaded yet; keep whatever we had
    -- rather than collapsing the control to its padding, which reads as a bug.
    if w > 0 then self:SetWidth(math.floor(w + 0.5) + CONTROL_PAD_X * 2) end
    return self
  end

  --- on = active. An active control is FILLED and its label is at full
  --- strength; an inactive one is an empty box with the label at half. Both
  --- states keep the SAME label colour — the design never swaps the hue, only
  --- the alpha, so the row still reads as one group.
  function btn:SetActive(on)
    self._on = on and true or false
    if self._on then
      -- An ACTIVE control is filled and has no visible border in the mock, so
      -- its rim takes the fill's own colour rather than being hidden — four
      -- edges hidden and re-shown is more state than a repaint.
      self.fill:Show()
      self.rim:SetColor(Style.COLOR.control, 1)
      self.text:SetAlpha(1)
    else
      self.fill:Hide()
      self.rim:SetColor(Style.COLOR.controlRim, 1, Style.COLOR.rule)
      self.text:SetAlpha(0.5)
    end
  end

  function btn:SetLabel(s)
    self._label = s or ""
    self.text:SetText(self._label)
    return self:FitToLabel()
  end

  btn:HookScript("OnEnter", function(s)
    if not s._on then s.text:SetAlpha(0.8) end
  end)
  btn:HookScript("OnLeave", function(s)
    if not s._on then s.text:SetAlpha(0.5) end
  end)

  btn:SetActive(false)
  btn:FitToLabel()
  return btn
end

--- Lay a row of controls out left to right with a fixed gap, returning the
--- total width. Each one has already sized itself to its own label, so the row
--- cannot be described by a pitch — only by a gap.
function Style.LayoutRow(controls, anchorTo, x, y, gap)
  gap = gap or 10
  local cursor = x or 0
  for _, c in ipairs(controls) do
    c:ClearAllPoints()
    c:SetPoint("TOPLEFT", anchorTo, "TOPLEFT", cursor, y or 0)
    cursor = cursor + (c:GetWidth() or 0) + gap
  end
  return cursor - gap - (x or 0)
end

--- Round a texture off to a circle.
---
--- ⚠️ SetMask(path) DID NOT WORK and this is the replacement. Applied to the
--- boss portraits and the detail icon it produced striped noise, then — once
--- the ordering was fixed so an image was in place first — simply no circle at
--- all. The supported modern path is a MaskTexture object added to the texture,
--- not a file path handed to the texture itself.
---
--- Two sources for the mask, tried in order: the CircleMaskScalable ATLAS,
--- which is built to be resized and is what Blizzard's own round frames use,
--- and the old TempPortraitAlphaMask FILE as a fallback for a client that does
--- not carry the atlas. Failing both, the icon stays SQUARE — untidy, and far
--- better than invisible.
---
--- The mask must be anchored to the texture rather than to its parent: the
--- portraits are 28px inside a 200px row, and a mask sized to the row would
--- round the row.
--- The hairline that runs round a circular icon.
---
--- #9F50D4, which is the palette's `accent` — Jason's own value from the mocks
--- (Session 260), not a colour chosen here to look right. It is the same violet
--- the OBTAINED BY heading, the TIER PIECE chip and the MODERATE badge take, so
--- the ring is the design's existing purple rather than a fifth edge colour.
---
--- ⚠️ ONE COLOUR, DELIBERATELY. The mocks use the blush for a SELECTED icon;
--- Jason's call was that the second state is not worth the complexity, so this
--- is a single token and every circular icon takes it. If that changes, it
--- changes here and nowhere else.
Style.ICON_BORDER = { color = "accent", alpha = 1, width = 1 }

--- Give a texture a circular mask. Returns the mask, or nil if the client
--- would not supply one.
local function circleMask(parent, tex)
  if not parent or not tex or not parent.CreateMaskTexture then return end
  local ok, mask = pcall(parent.CreateMaskTexture, parent)
  if not ok or not mask then return end

  -- ⚠️ pcall TELLS YOU THE CALL DID NOT ERROR, NOT THAT IT WORKED (Session 258).
  -- SetAtlas RETURNS A BOOLEAN — Blizzard's own LFGList.lua branches on it
  -- (`if not self.InfoBackground:SetAtlas(...)`) — so an atlas that fails to
  -- resolve returns false without raising, `applied` was set true anyway, and
  -- the texture fallback beneath it NEVER RAN. The failure is silent and total:
  -- no mask, no error, a square icon with its border showing. That is what
  -- Jason was looking at.
  local applied = false
  if mask.SetAtlas then
    local ok, res = pcall(mask.SetAtlas, mask, "CircleMaskScalable")
    applied = ok and res ~= false
  end
  if not applied and mask.SetTexture then
    local ok = pcall(mask.SetTexture, mask,
      "Interface\\CharacterFrame\\TempPortraitAlphaMask")
    applied = ok
  end
  if not applied then return end

  -- The wrap mode Blizzard's own MaskTexture XML pairs with this atlas
  -- (Blizzard_PVPUI.xml, Blizzard_Commentator*). Without it, everything outside
  -- the mask's own bounds clamps to the mask's edge pixel instead of being
  -- masked out, which is the other way a circle mask comes out square.
  if mask.SetHorizTile then pcall(mask.SetHorizTile, mask, false) end
  if mask.SetVertTile then pcall(mask.SetVertTile, mask, false) end

  mask:SetAllPoints(tex)
  if tex.AddMaskTexture then pcall(tex.AddMaskTexture, tex, mask) end
  return mask
end

--- Round a texture, and draw the design's 1px hairline around it.
---
--- ⚠️ THE BORDER IS A SECOND CIRCLE BEHIND THE FIRST, not a stroke — WoW has no
--- stroke on a texture, and the four straight textures Style.Rim uses cannot
--- follow a curve. A disc one pixel larger in the icon's own colour sits one
--- sublevel below it, so exactly the outer pixel shows and the icon covers the
--- rest. It needs its own mask: a MaskTexture is sized to the thing it masks,
--- so sharing the icon's would clip the ring back to the icon's own bounds and
--- draw nothing at all.
---
--- EVERY CIRCULAR ICON IN THE ADDON COMES THROUGH HERE — the Loot detail
--- header, the Slots identity block, every Slots list row, and the boss and
--- dungeon portraits — which is why the border goes here rather than at four
--- call sites that would drift apart.
---
--- Pass opts.noBorder for a circle the design leaves bare.
function Style.Round(parent, tex, opts)
  local mask = circleMask(parent, tex)
  if not mask then return end
  if opts and opts.noBorder then return mask end

  local B = Style.ICON_BORDER
  local col = B and Style.COLOR[B.color]
  if not col then return mask end
  local w = B.width or 1

  -- One sublevel below the icon, on the icon's OWN layer, so the ring cannot
  -- land above it or behind an unrelated background.
  local layer, sub = "ARTWORK", 0
  if tex.GetDrawLayer then
    local l, s = tex:GetDrawLayer()
    layer, sub = l or layer, s or 0
  end
  local ok, ring = pcall(parent.CreateTexture, parent, nil, layer, nil,
    math.max(-8, (sub or 0) - 1))
  if not ok or not ring then return mask end

  ring:SetColorTexture(Style.rgb(col))
  ring:SetAlpha(B.alpha or 1)
  ring:SetPoint("TOPLEFT", tex, "TOPLEFT", -w, w)
  ring:SetPoint("BOTTOMRIGHT", tex, "BOTTOMRIGHT", w, -w)
  circleMask(parent, ring)

  -- ⚠️ THE RING FOLLOWS THE ICON BY CONSTRUCTION, NOT BY CALL SITES REMEMBERING
  -- (Session 260). Hiding a texture does not hide another texture behind it, and
  -- these icons are hidden and shown in five places already — the detail header
  -- on an empty pane, and the boss portrait swapping with its initial-bearing
  -- fallback. Every site that forgot would draw a stray violet circle where an
  -- icon is not, and the sixth site added next month would forget again.
  --
  -- Wrapping the instance's own Show/Hide is the addon-standard way to bind two
  -- regions that WoW gives no parent-child relationship: a texture cannot own
  -- another texture, and a texture has no scripts to hook.
  tex.border = ring
  local show, hide = tex.Show, tex.Hide
  tex.Show = function(self, ...) if self.border then self.border:Show() end return show(self, ...) end
  tex.Hide = function(self, ...) if self.border then self.border:Hide() end return hide(self, ...) end
  tex.SetShown = function(self, v) if v then self:Show() else self:Hide() end end
  -- Matches whatever the icon already is, so a texture built hidden does not
  -- leave its ring on screen alone.
  ring:SetShown(tex:IsShown())
  return mask
end

--- A chip: the small tag that appears beside a raider's row and on an item card.
---
--- ⚠️ TWO KINDS, AND THE KIND CARRIES MEANING. Read off the mock, not invented:
---   FILLED   — a solid #f2bdad box with #0c0721 text in REGULAR. Used for what
---              is TRUE OF THE ITEM regardless of who is looking: O-BIS, R-BIS,
---              TARGET.
---   OUTLINED — no fill, a 1px border of the text colour at 30% ALPHA, text in
---              LIGHT in that same colour. Used for the VERDICT and the gap —
---              MAJOR, MODERATE, -16 — which differ per raider.
--- Both are 15 tall with 6px of padding either side, and both are 9px.
---
--- The outlined kind takes its colour from the badge, so one call site handles
--- every grade: the border is always the text colour at 30%, never a separate
--- value that could drift from it.
local CHIP_H, CHIP_PAD_X = 15, 6

function Style.Chip(parent, kind)
  local c = CreateFrame("Frame", nil, parent)
  c:SetHeight(CHIP_H)
  c._filled = (kind == "filled")

  c.bg = c:CreateTexture(nil, "BACKGROUND")
  c.bg:SetAllPoints()

  c.rim = Style.Rim(c, Style.COLOR.body, 0.3)

  c.text = Style.Text(c, c._filled and "regular" or "light", "chip",
    Style.COLOR.body, "CENTER")
  c.text:SetPoint("CENTER")

  --- label, and (outlined only) the colour the text and border take.
  ---
  --- ⚠️ SHOWN BEFORE THE LABEL IS WRITTEN, AND WRITTEN THROUGH A REPAINT
  --- (Session 260). A chip is created HIDDEN, so writing the label first and
  --- calling Show() at the end is the Session 254 trap exactly: the first paint
  --- happens off screen, and a string that never changes afterwards is never
  --- redrawn. The tell on Jason's screen was a chip of the RIGHT WIDTH with no
  --- glyphs in it — the width is measured from this same string, so the text
  --- object plainly held it. TIER PIECE was blank on every Slots pick.
  function c:Set(label, color)
    if not label or label == "" then self:Hide() return self end
    self:Show()
    self.text:SetText("")
    self.text:SetText(label)
    if self._filled then
      -- ⚠️ A FILLED CHIP HAS TWO GROUNDS, NOT ONE (Session 258, read off the
      -- Slots mock). The blush ground carries a BIS claim — O-BIS / R-BIS /
      -- M-BIS — and takes the panel's own violet as its text. A chip naming
      -- what an item IS (TIER PIECE, TIER TOKEN, CATALYZE TARGET) is filled
      -- with the heading purple and takes WHITE. Both are facts about the item
      -- rather than about the viewer, so both are filled rather than outlined;
      -- the ground is what separates a ranking claim from a classification.
      local fill = color or Style.COLOR.body
      self.bg:SetColorTexture(Style.rgb(fill))
      self.text:SetTextColor(Style.rgb(color and Style.COLOR.white or Style.COLOR.ground))
      self.rim:SetColor(fill, 0)
    else
      local col = color or Style.COLOR.body
      self.bg:SetColorTexture(0, 0, 0, 0)
      self.text:SetTextColor(Style.rgb(col))
      self.rim:SetColor(col, 0.3)
    end
    -- Width follows the label, exactly as the mock's chips do — MAJOR, O-BIS and
    -- TARGET are all different widths for the same padding.
    local w = self.text:GetStringWidth() or 0
    if w > 0 then self:SetWidth(math.floor(w + 0.5) + CHIP_PAD_X * 2) end
    return self
  end

  c:Hide()
  return c
end

--- A two-state switch: a label, a track with a sliding knob, a second label.
---
--- ⚠️ THE KNOB'S POSITION IS THE ONLY STATE INDICATOR, and this was checked on
--- both sides rather than assumed. Every one of the four filter labels is the
--- IDENTICAL 10px Light in #f2bdad — the design does not dim the unselected one,
--- and adding a highlight "so you can tell" would be inventing a signal the
--- design deliberately puts in one place. It replaces four separate pills, which
--- said the same thing four times and took twice the height.
---
--- Geometry straight off the mock's SVG: a 30x16 track with rx 8, and a knob of
--- radius 6 centred at x=8 or x=22. Both are TEXTURES because WoW has no rounded
--- rectangle and no gradient fill on a primitive — the knob's vertical
--- #DCA75E -> #FEF5BE is a real gradient in the design, so it is baked into the
--- art at 2x rather than approximated with a flat colour.
Style.SWITCH = { w = 30, h = 16, knob = 12, knobLeft = 2, knobRight = 16 }

function Style.Switch(parent, leftLabel, rightLabel)
  local SW = Style.SWITCH
  local f = CreateFrame("Button", nil, parent)
  f._hodStyled = true
  f:SetSize(SW.w, SW.h)

  f.track = f:CreateTexture(nil, "ARTWORK")
  f.track:SetAllPoints()
  f.track:SetTexture("Interface\\AddOns\\HoDLootAdvisor\\Media\\ui\\toggle-track.png")

  f.knob = f:CreateTexture(nil, "OVERLAY")
  f.knob:SetSize(SW.knob, SW.knob)
  f.knob:SetTexture("Interface\\AddOns\\HoDLootAdvisor\\Media\\ui\\toggle-knob.png")

  -- The labels are SIBLINGS of the track, not children, because the mock places
  -- each at its own x on the row rather than at a fixed distance from the track
  -- — "FULL LOOT TABLE" and "ALL LOOT" are very different lengths and both rows
  -- still line up.
  f.left  = Style.Text(parent, "light", "label", Style.COLOR.body, "LEFT")
  f.right = Style.Text(parent, "light", "label", Style.COLOR.body, "LEFT")
  f.left:SetText(leftLabel or "")
  f.right:SetText(rightLabel or "")

  --- on = the RIGHT-hand option is selected.
  function f:SetSwitch(on)
    self._on = on and true or false
    self.knob:ClearAllPoints()
    self.knob:SetPoint("LEFT", self._on and SW.knobRight or SW.knobLeft, 0)
  end

  --- Clicking anywhere on the row picks the side you clicked; clicking the track
  --- flips it. A 30x16 track is not a comfortable target on its own, which is
  --- why the labels are click targets too.
  function f:Wire(onPick)
    self:SetScript("OnClick", function(s) onPick(not s._on) end)
    for _, pair in ipairs({ { self.left, false }, { self.right, true } }) do
      local fs, want = pair[1], pair[2]
      local hit = CreateFrame("Button", nil, parent)
      hit:SetAllPoints(fs)
      hit:SetScript("OnClick", function() onPick(want) end)
    end
  end

  f:SetSwitch(false)
  return f
end

--- A slider: a track, a draggable knob, and its current value.
---
--- ⚠️ NO SLIDER EXISTS IN THE MOCK, so this is built from the parts that do.
--- The knob is the SWITCH's knob — the same 12px circle with the same
--- #DCA75E -> #FEF5BE gradient — and the track is the switch's fill colour at
--- full length. That makes the two controls read as one family rather than as a
--- slider borrowed from somewhere else, which is the only defensible way to add
--- a control a design does not contain.
---
--- Square ends, like every other control here: the toggle is the one rounded
--- thing in this design and it is rounded because it is a 16px pill.
---
--- Built on Blizzard's Slider template for the drag behaviour — hit testing,
--- clamping and the click-anywhere-on-the-track behaviour are genuinely fiddly
--- — with its artwork stripped, the same trade Style.Window makes.
function Style.Slider(parent, width, minV, maxV, step)
  local s = CreateFrame("Slider", nil, parent)
  s._hodStyled = true
  s:SetOrientation("HORIZONTAL")
  s:SetSize(width or 160, 16)
  s:SetMinMaxValues(minV or 0, maxV or 100)
  s:SetValueStep(step or 1)
  s:SetObeyStepOnDrag(true)

  s.track = s:CreateTexture(nil, "BACKGROUND")
  s.track:SetHeight(4)
  s.track:SetPoint("LEFT")
  s.track:SetPoint("RIGHT")
  s.track:SetColorTexture(Style.rgb(Style.COLOR.control))

  s.knob = s:CreateTexture(nil, "OVERLAY")
  s.knob:SetSize(12, 12)
  s.knob:SetTexture("Interface\\AddOns\\HoDLootAdvisor\\Media\\ui\\toggle-knob.png")
  s:SetThumbTexture(s.knob)

  -- The value, to the right of the track. A slider with no readout is a control
  -- you can only set by eye, and this one has a number the user cares about.
  s.value = Style.Text(parent, "light", "label", Style.COLOR.body, "LEFT")
  s.value:SetPoint("LEFT", s, "RIGHT", 10, 0)

  --- suffix is appended to the readout ("%" here). onChange fires on every
  --- step, so a caller can apply the value live rather than on release —
  --- dragging a SIZE control you cannot see the effect of is guesswork.
  --- suffix is appended to the readout ("%" here). onChange fires on every
  --- step; onRelease fires once, when the drag ends.
  ---
  --- ⚠️ THE DRAG STATE IS PART OF THE CONTRACT, not an internal detail. A
  --- caller that resizes anything needs to know whether the user still has hold
  --- of the knob — and Settings.Refresh needs it too, because writing a value
  --- into a slider mid-drag fights the drag.
  function s:Wire(suffix, onChange, onRelease)
    self:SetScript("OnValueChanged", function(self2, v)
      v = math.floor(v + 0.5)
      self2.value:SetText(tostring(v) .. (suffix or ""))
      if onChange then onChange(v) end
    end)
    self:SetScript("OnMouseDown", function(self2) self2._dragging = true end)
    self:SetScript("OnMouseUp", function(self2)
      self2._dragging = false
      if onRelease then onRelease(math.floor((self2:GetValue() or 0) + 0.5)) end
    end)
    -- A drag that ends off the control still ends. Without this the hold below
    -- would never be released and the window would stay unscalable.
    self:HookScript("OnHide", function(self2)
      if self2._dragging then
        self2._dragging = false
        if onRelease then onRelease(math.floor((self2:GetValue() or 0) + 0.5)) end
      end
    end)
  end

  function s:IsDragging() return self._dragging and true or false end

  return s
end

--- The header lockup: crest and wordmark as one texture.
---
--- ⚠️ IT HAS TO BE AN IMAGE AND THAT IS SETTLED, NOT A SHORTCUT. The wordmark
--- carries a gradient fill, 2px of letter spacing and a glow, and a WoW
--- FontString supports NONE of the three — there is no tracking API at all.
--- Drawn from the design file, all three are simply real.
---
--- ⚠️ THE EXPORT IS 2x AND CARRIES ITS GLOW AS PADDING. The file is 485x136,
--- of which the artwork is 405x56 inset 40px on every side — measured off the
--- alpha channel, not assumed. So it draws at HALF size, and the caller anchors
--- the ARTWORK rather than the file: BLEED is how much padding to compensate
--- for, and it is what keeps the lockup landing where the mock puts it even
--- though the texture is bigger than the thing you can see.
Style.LOCKUP = {
  file  = "Interface\\AddOns\\HoDLootAdvisor\\Media\\lockup.png",
  w     = 242,  -- 485 / 2, the whole file
  h     = 68,   -- 136 / 2
  bleed = 20,   -- 40 / 2, the transparent margin on each side
  inkW  = 202,  -- what you actually see, for anything laying out beside it
  inkH  = 28,
}

--- Place the lockup so its ARTWORK's top-left lands at (x, -y) inside parent.
function Style.Lockup(parent, x, y)
  local L = Style.LOCKUP
  local tex = parent:CreateTexture(nil, "ARTWORK")
  tex:SetTexture(L.file)
  tex:SetSize(L.w, L.h)
  tex:SetPoint("TOPLEFT", (x or 0) - L.bleed, -((y or 0) - L.bleed))
  return tex
end

--- A checkbox in the panel's own language: a small square with a coloured rim
--- and a coloured tick, plus a white label to its right. The whole thing is one
--- click target, because a 14px box is not a comfortable one.
---
--- ⚠️ NOT UICheckButtonTemplate. Settings.lua uses the Blizzard template and is
--- right to — that window is a plain list. This one sits on the designed panel
--- beside pills that were drawn to a mock, and the gold-riveted default is the
--- single biggest reason a frame reads as "some addon" (see Style.Window).
---
--- ⚠️ THE TICK IS A TEXTURE, NOT A CHARACTER. The bundled fonts carry no ✓ —
--- checked directly, along with ★ ◆ and the rest — and a missing glyph in a
--- custom font renders as NOTHING rather than falling back.
function Style.Check(parent, label, boxSize)
  local btn = CreateFrame("Button", nil, parent)
  btn._hodStyled = true
  local s = boxSize or 16

  -- ⚠️ READ OFF THE NODE (Session 257): a 16px square with a 1px #6f2b57 rim
  -- and NO fill — the same rim as an inactive tab, which is what makes the two
  -- controls in that corner read as one pair. It used to be an ORANGE rim over
  -- the dark surface, a colour this design does not contain.
  btn.box = CreateFrame("Frame", nil, btn)
  btn.box:SetSize(s, s)
  btn.box:SetPoint("LEFT", 0, 0)
  -- The same gradient as a control's rim. Its node reported the same flattened
  -- #6f2b57, and it sits directly above the difficulty control — two borders in
  -- one corner that did not match would be the tell that one of them is wrong.
  btn.box.rim = Style.Rim(btn.box, Style.COLOR.controlRim, 1, 1, Style.COLOR.rule)

  -- ⚠️ THE TICK IS THE DESIGN'S OWN PATH, EXPORTED, NOT BLIZZARD'S CHECKMARK.
  -- It was UI-CheckBox-Check, which is a chunky gold-ish glyph that overhung
  -- its box. The mock draws a 2px round-capped stroke in #f2bdad, 10x7 inside
  -- 4px of padding, which is what Media/ui/check.png is.
  btn.tick = btn.box:CreateTexture(nil, "OVERLAY")
  btn.tick:SetTexture("Interface\\AddOns\\HoDLootAdvisor\\Media\\ui\\check.png")
  btn.tick:SetSize(10, 7)
  btn.tick:SetPoint("CENTER")
  btn.tick:Hide()

  btn.text = btn:CreateFontString(nil, "OVERLAY")
  Style.SetFont(btn.text, Style.FONT.light, Style.SIZE.label)
  btn.text:SetTextColor(Style.rgb(Style.COLOR.body))
  btn.text:SetJustifyH("LEFT")
  -- 22 from the box's left edge: 16 wide plus the mock's 6px gap.
  btn.text:SetPoint("LEFT", btn.box, "LEFT", 22, 0)
  btn:SetFontString(btn.text)
  btn.text:SetText(label or "")

  btn:SetHeight(math.max(s, 16))
  -- Width follows the label, so a caller can place the control without knowing
  -- how long the word is.
  btn:SetWidth(22 + (btn.text:GetStringWidth() or 60))

  function btn:SetChecked(on)
    self._checked = on and true or false
    if self._checked then self.tick:Show() else self.tick:Hide() end
  end
  function btn:GetChecked() return self._checked and true or false end
  btn:SetChecked(false)

  btn:HookScript("OnEnter", function(s2) s2.text:SetAlpha(0.8) end)
  btn:HookScript("OnLeave", function(s2) s2.text:SetAlpha(1) end)
  return btn
end

-- ── Reskinning Blizzard templates ──────────────────────────────────────────
--
-- Every window here is built on BasicFrameTemplateWithInset and every button on
-- UIPanelButtonTemplate, because those give working drag, close and click states
-- for free. What they also give is the gold-riveted parchment look, which is the
-- single biggest reason the addon reads as "some addon" rather than as part of
-- hodguild.com.
--
-- So the templates STAY and their skin comes off. That keeps all the behaviour
-- and replaces only the appearance, which is a far smaller change than
-- hand-rolling frames — and it means a Blizzard template change breaks the look,
-- never the function.
--
-- ⚠️ EVERY REGION LOOKUP IS GUARDED. Template internals differ between game
-- versions and are not contractual; a missing region must leave a plain frame,
-- never an error mid-raid. That is also why this cannot be verified by the
-- headless harness — there are no real frames there — so it is written to fail
-- soft and wants a look in game.

local function hideRegion(r)
  if not r then return end
  -- A NineSlice is a FRAME holding up to nine textures, not a texture — hiding
  -- the container alone left the gold rim drawn in the first pass. So anything
  -- with regions gets emptied, then hidden itself.
  if r.GetRegions then
    for _, sub in ipairs({ r:GetRegions() }) do
      if sub.SetTexture then sub:SetTexture(nil) end
      if sub.SetAtlas then pcall(sub.SetAtlas, sub, nil) end
      if sub.SetAlpha then sub:SetAlpha(0) end
      if sub.Hide then sub:Hide() end
    end
  end
  if r.SetTexture then r:SetTexture(nil) end
  if r.SetAtlas then pcall(r.SetAtlas, r, nil) end
  if r.SetAlpha then r:SetAlpha(0) end
  if r.Hide then r:Hide() end
end

--- Strip a button's artwork textures. SetNormalTexture("") does NOT reliably
--- clear modern templates — the texture object survives and keeps drawing — so
--- the object itself is fetched and emptied.
local function stripButtonArt(btn)
  if not btn then return end
  for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture",
                            "GetHighlightTexture", "GetDisabledTexture" }) do
    if btn[getter] then
      local ok, tex = pcall(btn[getter], btn)
      if ok and tex then hideRegion(tex) end
    end
  end
  for _, key in ipairs({ "Left", "Middle", "Right", "Border", "Background",
                         "TopLeft", "TopRight", "BottomLeft", "BottomRight" }) do
    hideRegion(btn[key])
  end
end

--- Strip a Blizzard frame template down and apply the addon's surface.
function Style.Window(frame)
  if not frame or frame._hodStyled then return frame end
  frame._hodStyled = true

  -- The parchment: named regions on the template, plus the NineSlice border that
  -- modern templates use instead of individual corner textures.
  for _, key in ipairs({ "Bg", "TitleBg", "portrait", "PortraitFrame", "PortraitContainer",
                         "TopTileStreaks", "TopBorder", "BottomBorder", "LeftBorder",
                         "RightBorder", "Border", "BorderFrame", "TitleContainer",
                         "TopLeftCorner", "TopRightCorner", "BottomLeftCorner",
                         "BottomRightCorner" }) do
    hideRegion(frame[key])
  end
  hideRegion(frame.NineSlice)
  if frame.Inset then
    hideRegion(frame.Inset.Bg)
    if frame.Inset.NineSlice then hideRegion(frame.Inset.NineSlice) end
    hideRegion(frame.Inset)
  end
  -- Some templates keep unnamed background textures; drop anything left in the
  -- BACKGROUND layer that we did not create ourselves.
  if frame.GetRegions then
    for _, r in ipairs({ frame:GetRegions() }) do
      if r ~= frame.bgTex and r.GetObjectType and r:GetObjectType() == "Texture"
         and r.GetDrawLayer and r:GetDrawLayer() == "BACKGROUND" then
        hideRegion(r)
      end
    end
  end

  -- Opaque, matching Style.Surface's default. ⚠️ This is NOT load-bearing and
  -- was briefly mistaken for the cause of a colour mismatch: every window paints
  -- its own opaque ground over this one, so whatever alpha is used here never
  -- reaches the screen. See the note in Style.Surface.
  Style.Surface(frame, Style.COLOR.bg, 1)
  if frame.bgTex then frame.bgTex:SetDrawLayer("BACKGROUND", -8) end

  -- A title bar the same colour as the site's card header, so the window reads
  -- as header-over-body rather than as one flat slab.
  local head = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
  head:SetPoint("TOPLEFT", 1, -1)
  head:SetPoint("TOPRIGHT", -1, -1)
  head:SetHeight(26)
  head:SetColorTexture(Style.rgb(Style.COLOR.bgAlt))
  frame.headTex = head

  -- Kept on the frame so a window that supplies its own ground (Style.PanelGround)
  -- can take it back off. It used to be a local, which is why the redesigned
  -- panel could hide the title band but not the line under it.
  local headLine = Style.Divider(frame, Style.COLOR.border, 1)
  headLine:SetPoint("TOPLEFT", 1, -27)
  headLine:SetPoint("TOPRIGHT", -1, -27)
  frame.headLine = headLine

  if frame.TitleText then
    Style.SetFont(frame.TitleText, Style.FONT.title, Style.SIZE.title)
    frame.TitleText:SetTextColor(Style.rgb(Style.COLOR.gold))
    -- Left-aligned like every card header on the site, not centred like WoW.
    frame.TitleText:ClearAllPoints()
    frame.TitleText:SetPoint("TOPLEFT", 12, -7)
  end

  if frame.CloseButton then
    local cb = frame.CloseButton
    stripButtonArt(cb)
    cb:SetSize(20, 20)
    cb:ClearAllPoints()
    cb:SetPoint("TOPRIGHT", -6, -4)
    cb.hodX = cb.hodX or Style.Text(cb, "label", "small", Style.COLOR.textDim, "CENTER")
    cb.hodX:SetPoint("CENTER")
    cb.hodX:SetText("X")
    cb:SetScript("OnEnter", function(s) s.hodX:SetTextColor(Style.rgb(Style.COLOR.gold)) end)
    cb:SetScript("OnLeave", function(s) s.hodX:SetTextColor(Style.rgb(Style.COLOR.textDim)) end)
  end

  -- BUTTONS ARE SKINNED ON FIRST SHOW, not here. Every window calls MakeWindow
  -- partway through its own build(), so most of its buttons do not exist yet at
  -- this point — skinning now would silently miss them and leave a window half
  -- in each style. OnShow runs after the whole build, and _hodStyled makes the
  -- sweep idempotent, so the cost is one walk the first time a window opens.
  frame:HookScript("OnShow", function(self) Style.SkinChildButtons(self) end)

  return frame
end

--- Skin every text button under a frame, once.
---
--- Deliberately narrow about what it touches: a button with no font string is an
--- icon or a scroll control, and reskinning those would strip artwork this addon
--- does not supply a replacement for. The close button is skinned by Style.Window
--- itself and is skipped here.
function Style.SkinChildButtons(frame, depth)
  if not frame or not frame.GetChildren then return end
  if (depth or 0) > 4 then return end
  for _, child in ipairs({ frame:GetChildren() }) do
    if child ~= frame.CloseButton
       and child.GetObjectType and child:GetObjectType() == "Button"
       and not child._hodStyled
       and child.GetFontString and child:GetFontString() then
      Style.SkinButton(child)
    end
    Style.SkinChildButtons(child, (depth or 0) + 1)
  end
end

--- Reskin a UIPanelButtonTemplate button as a flat DS control.
---
--- accent tints the fill and the text; nil is the neutral secondary button. The
--- site's buttons are gradient-filled, which WoW cannot do on a plain texture
--- without an artwork file, so this is the honest flat translation.
function Style.SkinButton(btn, accent, size)
  if not btn or btn._hodStyled then return btn end
  btn._hodStyled = true

  stripButtonArt(btn)

  local c = accent or Style.COLOR.elevated
  btn.fill = btn:CreateTexture(nil, "BACKGROUND")
  btn.fill:SetAllPoints()
  btn.fill:SetColorTexture(c.r, c.g, c.b, accent and 0.85 or 1)
  btn.rim = Style.Rim(btn, accent or Style.COLOR.border, accent and 0.9 or 1)

  local label = btn:GetFontString()
  if label then
    Style.SetFont(label, Style.FONT.label, Style.SIZE[size or "small"])
    label:SetTextColor(Style.rgb(Style.COLOR.text))
  end

  btn:HookScript("OnEnter", function(s) if s.fill then s.fill:SetAlpha(1) end end)
  btn:HookScript("OnLeave", function(s) if s.fill then s.fill:SetAlpha(accent and 0.85 or 1) end end)
  return btn
end

return Style
