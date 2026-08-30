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
Style.FONT = {
  title    = FONT_DIR .. "Manrope-Light.ttf",
  titleMed = FONT_DIR .. "Manrope-Light.ttf",
  body     = FONT_DIR .. "Manrope-Light.ttf",
  bodyMed  = FONT_DIR .. "Manrope-Light.ttf",
  -- The filled chip, and nothing else.
  label    = FONT_DIR .. "Manrope-Regular.ttf",
  -- The two true weights, for call sites written after the redesign that should
  -- say what they mean rather than inherit a role name from the old pairing.
  light    = FONT_DIR .. "Manrope-Light.ttf",
  regular  = FONT_DIR .. "Manrope-Regular.ttf",
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
  -- ⚠️ THE SAME FIGMA VARIABLE AS `mutedGrey` BELOW ("Muted Grey"), which the
  -- mock uses for BOTH the hairlines and the Runner tab's body copy. Written
  -- once and aliased below rather than as two identical literals, so a retune
  -- cannot move one and leave the other — this file exists to stop exactly that.
  rim       = hex("d9cee2"),   -- hairline, drawn at 0.4 alpha
  -- The bottom warmth: a vertical wash from transparent to orange over the
  -- lower 60% of the window. WoW gradients have two stops and no midpoint, so
  -- the 40% stop in the design becomes the TEXTURE'S HEIGHT rather than a
  -- third colour — same result, and it cannot drift the way a guessed
  -- mid-colour would.
  glowAlpha = 0.12,
  glowFrom  = 0.40,            -- fraction of the window height the wash starts at

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

  -- ── Semantics the redesign introduces (Session 250) ──────────────────────
  -- MAJOR IS RED HERE, NOT GREEN. The mock's badge ramp reads
  -- major #ff595b -> moderate #ff7729 -> grey, which is a heat scale rather
  -- than the good/bad scale the old panel used (green Major, amber Moderate).
  -- Not a stylistic tweak to fold in quietly: it inverts what a colour MEANS,
  -- so it is a named token and the ramp lives in one table below.
  major     = hex("ff595b"),
  -- BIS OWNS A YELLOW, AND THE TARGET OWNS THE GREEN. Session 249 settled that
  -- these two marks must not share a hue and that BIS holds the gold-ish one;
  -- the mock picks the exact pair. The old code had BIS on the brand gold
  -- (#f3c56b) and the target marker on the SAME gold, which is precisely the
  -- collision that rule forbids.
  bis       = hex("fff468"),
  target    = hex("20ba56"),
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

  -- ⚠️ THE WORKHORSE, AND IT IS NOT WHITE. Boss names, slot lines, the meta
  -- line, the footer and most chip text are all this warm blush. PURE WHITE is
  -- reserved for ITEM NAMES alone, which is what makes an item name read as the
  -- subject of its row rather than as one more label.
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
Style.BADGE = {
  major     = { label = "Major",     color = "major" },
  moderate  = { label = "Moderate",  color = "orange" },
  minor     = { label = "Minor",     color = "textDim" },
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
function Style.Rim(frame, color, alpha, thickness)
  local c = color or Style.COLOR.border
  local a = alpha or 1
  local t = thickness or 1
  local e = {}
  for _, side in ipairs({ "top", "bottom", "left", "right" }) do
    local tex = frame:CreateTexture(nil, "BORDER")
    tex:SetColorTexture(c.r, c.g, c.b, a)
    e[side] = tex
  end
  e.top:SetPoint("TOPLEFT");     e.top:SetPoint("TOPRIGHT");     e.top:SetHeight(t)
  e.bottom:SetPoint("BOTTOMLEFT"); e.bottom:SetPoint("BOTTOMRIGHT"); e.bottom:SetHeight(t)
  e.left:SetPoint("TOPLEFT");    e.left:SetPoint("BOTTOMLEFT");  e.left:SetWidth(t)
  e.right:SetPoint("TOPRIGHT");  e.right:SetPoint("BOTTOMRIGHT"); e.right:SetWidth(t)
  function e:SetColor(nc, na)
    for _, side in ipairs({ "top", "bottom", "left", "right" }) do
      self[side]:SetColorTexture(nc.r, nc.g, nc.b, na or 1)
    end
  end
  return e
end

--- The panel surface: a dark fill plus a hairline rim.
---
--- This is the addon's stand-in for .hod-glass. The site's card is a blurred
--- translucent pane over a flame background; WoW has no backdrop-filter, so the
--- honest translation is a near-opaque dark fill at the same colour the blur
--- resolves to, rather than a transparency that would show the game world
--- through a data panel and make it unreadable mid-raid.
function Style.Surface(frame, color, alpha)
  local c = color or Style.COLOR.bg
  local bg = frame:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(c.r, c.g, c.b, alpha or 0.96)
  frame.bgTex = bg
  frame.rim = Style.Rim(frame, Style.COLOR.border, 1)
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

  local glow = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
  glow:SetPoint("BOTTOMLEFT", 1, 1)
  glow:SetPoint("BOTTOMRIGHT", -1, 1)
  glow:SetHeight(math.floor((height or frame:GetHeight() or 560) * (1 - C.glowFrom)))
  glow:SetColorTexture(1, 1, 1, 1)
  -- CreateColor is guarded: it is a modern-client global, and a missing one must
  -- leave a flat panel rather than error on the frame that draws everything.
  if CreateColor and glow.SetGradient then
    -- VERTICAL puts the FIRST colour at the bottom. The warmth belongs at the
    -- bottom edge, so the opaque end goes first.
    pcall(glow.SetGradient, glow, "VERTICAL",
      CreateColor(C.orange.r, C.orange.g, C.orange.b, C.glowAlpha),
      CreateColor(C.orange.r, C.orange.g, C.orange.b, 0))
  else
    glow:SetColorTexture(C.orange.r, C.orange.g, C.orange.b, C.glowAlpha * 0.5)
  end
  frame.glowTex = glow

  frame.rim = Style.Rim(frame, C.rim, 0.4)
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

function Style.Control(parent, label, size)
  local btn = CreateFrame("Button", nil, parent)
  btn._hodStyled = true
  btn:SetHeight(CONTROL_H)

  btn.fill = btn:CreateTexture(nil, "BACKGROUND")
  btn.fill:SetAllPoints()
  btn.fill:SetColorTexture(Style.rgb(Style.COLOR.control))
  btn.fill:Hide()

  btn.rim = Style.Rim(btn, Style.COLOR.controlRim, 1)

  -- Built the way Style.Pill is, for the reason recorded there: a fixed width on
  -- the fontstring plus no SetFontString wiring shipped a row of blank controls
  -- once already.
  btn.text = btn:CreateFontString(nil, "OVERLAY")
  Style.SetFont(btn.text, Style.FONT.light, Style.SIZE[size or "head"])
  btn.text:SetTextColor(Style.rgb(Style.COLOR.controlText))
  btn.text:SetJustifyH("CENTER")
  btn.text:SetPoint("CENTER")
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
      self.fill:Show()
      self.rim:SetColor(Style.COLOR.control, 1)
      self.text:SetAlpha(1)
    else
      self.fill:Hide()
      self.rim:SetColor(Style.COLOR.controlRim, 1)
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
  local s = boxSize or 14

  btn.box = CreateFrame("Frame", nil, btn)
  btn.box:SetSize(s, s)
  btn.box:SetPoint("LEFT", 0, 0)
  btn.box.bg = btn.box:CreateTexture(nil, "BACKGROUND")
  btn.box.bg:SetAllPoints()
  btn.box.bg:SetColorTexture(Style.rgb(Style.COLOR.bg))
  btn.box.rim = Style.Rim(btn.box, Style.COLOR.orange, 1)

  btn.tick = btn.box:CreateTexture(nil, "OVERLAY")
  btn.tick:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
  btn.tick:SetPoint("CENTER", 0, 0)
  btn.tick:SetSize(s + 6, s + 6)
  btn.tick:SetVertexColor(Style.rgb(Style.COLOR.orange))
  btn.tick:Hide()

  btn.text = btn:CreateFontString(nil, "OVERLAY")
  Style.SetFont(btn.text, Style.FONT.titleMed, Style.SIZE.head)
  btn.text:SetTextColor(Style.rgb(Style.COLOR.white))
  btn.text:SetJustifyH("LEFT")
  btn.text:SetPoint("LEFT", btn.box, "RIGHT", 6, 0)
  btn:SetFontString(btn.text)
  btn.text:SetText(label or "")

  btn:SetHeight(math.max(s, 16))
  -- Width follows the label, so the caller can right-align the control without
  -- knowing how long the word is.
  btn:SetWidth(s + 6 + (btn.text:GetStringWidth() or 30))

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

  Style.Surface(frame, Style.COLOR.bg, 0.96)
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
