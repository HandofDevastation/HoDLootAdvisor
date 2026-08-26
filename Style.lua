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

Style.FONT = {
  -- Khand: the display face. Condensed, so it holds a boss name or an item name
  -- in a narrow column where General Sans would truncate.
  title    = FONT_DIR .. "Khand-SemiBold.ttf",
  titleMed = FONT_DIR .. "Khand-Medium.ttf",
  -- General Sans: everything read as prose or data.
  body     = FONT_DIR .. "GeneralSans-Regular.ttf",
  bodyMed  = FONT_DIR .. "GeneralSans-Medium.ttf",
  label    = FONT_DIR .. "GeneralSans-Semibold.ttf",
}

-- Type scale, mirroring the site's roles rather than inventing sizes. WoW pixel
-- sizes are not CSS pixels, so these are matched by eye against the site at a
-- typical UI scale, then kept as named roles so a future tweak moves everything
-- that shares a role.
Style.SIZE = {
  title   = 16,   -- window title
  head    = 13,   -- section / column headers
  row     = 12,   -- ranking rows, the densest text that must stay readable
  small   = 11,   -- chips, secondary data
  tiny    = 10,   -- tags, footnotes
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

  -- Text (--text-primary / --text-secondary / --text-muted)
  text      = hex("e8e8f0"),
  textDim   = hex("9090b0"),
  textMuted = hex("606080"),

  -- Accent (--gold) — the site's brand accent, used for the title and targets.
  gold      = hex("f3c56b"),

  -- Semantic hues, straight from the site's --hue-* palette.
  green     = hex("20ba56"),   -- Major
  blue      = hex("3382ff"),   -- Moderate
  orange    = hex("ff7729"),   -- Minor, Grade S
  grey      = hex("606060"),   -- Sidegrade, low grades
  red       = hex("c41e3a"),
  purple    = hex("8031ff"),
  hotPink   = hex("ff0080"),   -- --hue-hot-pink, the BIS colour (Session 245)
  white     = hex("ffffff"),
}

--- r, g, b for a colour, so call sites stay short at the WoW API boundary.
function Style.rgb(c)
  c = c or Style.COLOR.text
  return c.r, c.g, c.b
end

--- "|cffRRGGBB" for inline colouring in a chat line or a tooltip.
function Style.code(c)
  c = c or Style.COLOR.text
  return ("|cff%02x%02x%02x"):format(
    math.floor(c.r * 255 + 0.5), math.floor(c.g * 255 + 0.5), math.floor(c.b * 255 + 0.5))
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

  local headLine = Style.Divider(frame, Style.COLOR.border, 1)
  headLine:SetPoint("TOPLEFT", 1, -27)
  headLine:SetPoint("TOPRIGHT", -1, -27)

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
