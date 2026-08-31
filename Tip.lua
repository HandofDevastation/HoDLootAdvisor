-- Tip.lua — the addon's own tooltip, in the addon's own type
--
-- ⚠️ WHY THIS EXISTS (Jason, Session 254: "nothing in this addon should be
-- anything other than General Sans or Khand"). Every explanatory tooltip in the
-- panel was drawn on Blizzard's GameTooltip, which renders in the CLIENT's
-- tooltip font — so the one surface the design never reached was the surface
-- that explains the design. Setting a font on GameTooltip was never an option:
-- that frame is shared with the whole UI and every other addon the player runs,
-- and restyling it restyles all of them.
--
-- ⚠️ ITEM TOOLTIPS STAY ON GameTooltip, AND MUST. Hovering an item shows the
-- GAME's item card — stats, sockets, set bonuses, upgrade track — which we could
-- not reproduce and should not try to. Tooltip.lua appends the addon's TARGETED
-- line to that card precisely so the flag reaches bags, vendors, chat links and
-- the Adventure Guide. This widget is for text WE wrote. The two are different
-- jobs and the split is deliberate: the only call sites that keep GameTooltip
-- are the two that call SetHyperlink.
--
-- THE METHOD NAMES MIRROR GameTooltip's on purpose (SetOwner / SetText /
-- AddLine / AddDoubleLine / Show / Hide), so moving a call site is a change of
-- identifier and nothing else. That is what made migrating fourteen of them a
-- mechanical edit rather than fourteen chances to introduce a difference.
--
-- THE ARITHMETIC IS NOT HERE. ns.TipLayout in Core.lua takes measured widths and
-- heights and returns the box — no frames involved, so the harness can test it,
-- per this project's standing rule that logic must not live in a window file.

local ADDON_NAME, ns = ...

local Tip = {}
ns.Tip = Tip

-- The design's own spacing. PAD is the breathing room inside the rim; GAP_COL is
-- the minimum trough between a label and its value, which is what stops "Stat
-- alignment" and "7" from touching on the widest row.
local PAD, LINE_GAP, TITLE_GAP, GAP_COL = 10, 3, 6, 18
-- Wrapped prose gets a measured ceiling rather than growing to the screen.
--
-- ⚠️ 300 WAS A HAIR TOO NARROW AND IT LOOKED SLOPPY (Jason, Session 254). The
-- Import Raid Night tooltip's two sentences measure 297.7px and 295.8px in
-- General Sans at 11 — summed from the bundled TTF, not guessed — so both sat
-- inside the cap by two pixels and wrapped anyway, because the game's text
-- metrics differ slightly from the font's advance widths. The same 0.7px margin
-- that truncated a column header in Session 252.
-- 360 clears both with real room, while genuinely long prose still folds: the
-- Loot Log's line measures 569.5 and the targeting note 437.4.
local MAX_W = 360

local frame, title, rows
local pending = { title = nil, titleColor = nil, lines = {} }

local function color(c, r, g, b)
  if r then return { r, g, b } end
  local S = ns.Style
  return S and { S.COLOR[c].r, S.COLOR[c].g, S.COLOR[c].b } or { 1, 1, 1 }
end

local function build()
  frame = CreateFrame("Frame", "HoDLootAdvisorTip", UIParent)
  frame:SetFrameStrata("TOOLTIP")
  frame:Hide()

  local S = ns.Style
  local bg = frame:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  if S then
    -- The panel's own ground, not the lighter window fill: a tooltip floats
    -- ABOVE the panel and needs to read as separate from it.
    bg:SetColorTexture(S.COLOR.ground.r, S.COLOR.ground.g, S.COLOR.ground.b, 0.96)
    S.Rim(frame, S.COLOR.rim, 0.4)
  else
    bg:SetColorTexture(0, 0, 0, 0.95)
  end

  -- Khand for the title, General Sans for everything under it — the same two
  -- faces and the same roles the panel itself uses.
  title = S and S.Text(frame, "titleMed", "head", S.COLOR.text)
            or frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", PAD, -PAD)
  title:SetJustifyH("LEFT")

  rows = {}
end

--- One row's two fontstrings, created on demand and reused after that.
local function rowAt(i)
  if rows[i] then return rows[i] end
  local S = ns.Style
  local r = {}
  r.left = S and S.Text(frame, "body", "small", S.COLOR.text)
             or frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  r.left:SetJustifyH("LEFT")
  r.right = S and S.Text(frame, "body", "small", S.COLOR.text)
              or frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  r.right:SetJustifyH("RIGHT")
  rows[i] = r
  return r
end

function Tip:SetOwner(owner, anchor)
  if not frame then build() end
  -- ⚠️ THE DEFAULT IS THE CURSOR NOW. A call site that wants the popup pinned
  -- to its own frame still says so; most of them never cared and only ever
  -- wanted "near the thing I am pointing at".
  pending.owner, pending.anchor = owner, anchor or "ANCHOR_CURSOR"
  pending.title, pending.titleColor = nil, nil
  pending.lines = {}
  return self
end

function Tip:SetText(text, r, g, b)
  pending.title, pending.titleColor = text, color("text", r, g, b)
  return self
end

--- Mirrors GameTooltip: the FIRST line of an empty tooltip is the heading, which
--- is why several call sites open with AddLine rather than SetText and still get
--- a title. Reproduced rather than corrected — the alternative is auditing every
--- caller for a distinction none of them meant to draw.
function Tip:AddLine(text, r, g, b, wrap)
  if not pending.title and #pending.lines == 0 then
    return self:SetText(text, r, g, b)
  end
  -- ⚠️ A SPACER DIRECTLY UNDER THE TITLE IS REDUNDANT HERE (Jason, Session 254:
  -- "why is there so much room under the header text line?"). Callers open with
  -- a blank line because GameTooltip's heading sits tight against its body and
  -- needed one; ours already carries titleGap, so the two stack into ~20px of
  -- nothing. Dropped at the widget rather than at each call site, so the next
  -- tooltip written from muscle memory cannot reintroduce it. Spacers BETWEEN
  -- sections are untouched and still separate.
  if (text == nil or text == "" or text == " ") and #pending.lines == 0 then
    return self
  end
  pending.lines[#pending.lines + 1] =
    { left = text or "", color = color("text", r, g, b), wrap = wrap and true or false }
  return self
end

--- ⚠️ wrap IS EXPLICITLY FALSE, NEVER ABSENT (Session 254). Leaving it nil sent
--- nil into SetWordWrap, which THROWS — and an error inside OnEnter aborts the
--- handler, so nothing drew at all. The tell was which tooltips survived: every
--- one whose lines pass `true` explicitly worked, and the only one built from
--- double lines did not. A two-column row cannot wrap anyway; the flag is here
--- so no value reaching a setter is ever nil.
function Tip:AddDoubleLine(left, right, lr, lg, lb, rr, rg, rb)
  pending.lines[#pending.lines + 1] = {
    left = left or "", right = right or "", wrap = false,
    color = color("text", lr, lg, lb), rightColor = color("text", rr, rg, rb),
  }
  return self
end

--- Where the box goes, given the anchor the caller asked for. Clamped to the
--- screen afterwards, because a tooltip that explains something off the edge
--- explains nothing.
-- How far the cursor-anchored box sits from the pointer. Right and slightly
-- above, which is where the game's own tooltips sit and therefore where the eye
-- already looks.
local CURSOR_DX, CURSOR_DY = 16, -8

local function place(owner, anchor, w, h)
  frame:ClearAllPoints()

  -- ⚠️ AT THE CURSOR BY DEFAULT (Jason, Session 258: "they're not spawning at
  -- the cursor location"). Every anchor below pins the tooltip to a FRAME, which
  -- is what GameTooltip's ANCHOR_* names mean — and on a dense list that puts
  -- the popup at the row's edge rather than where the pointer is, so it reads as
  -- belonging to nothing in particular and can land half a window away from what
  -- you are pointing at.
  --
  -- GetCursorPosition returns coordinates in the CURRENT UI scale, so both are
  -- divided by UIParent's effective scale before being used as offsets from its
  -- bottom-left. Forgetting that is the classic version of this bug: the
  -- tooltip tracks the cursor at 100% UI scale and drifts at any other.
  if anchor == "ANCHOR_CURSOR" or anchor == nil then
    local ui = UIParent
    local cx, cy = GetCursorPosition()
    local scale = (ui and ui.GetEffectiveScale and ui:GetEffectiveScale()) or 1
    if cx and cy and scale > 0 then
      frame:SetPoint("BOTTOMLEFT", ui, "BOTTOMLEFT",
        (cx / scale) + CURSOR_DX, (cy / scale) + CURSOR_DY)
    else
      frame:SetPoint("TOPLEFT", owner, "TOPRIGHT", 8, 0)
    end
  elseif anchor == "ANCHOR_LEFT" then
    frame:SetPoint("TOPRIGHT", owner, "TOPLEFT", -8, 0)
  elseif anchor == "ANCHOR_TOP" then
    frame:SetPoint("BOTTOM", owner, "TOP", 0, 8)
  elseif anchor == "ANCHOR_BOTTOM" then
    frame:SetPoint("TOP", owner, "BOTTOM", 0, -8)
  elseif anchor == "ANCHOR_BOTTOMRIGHT" then
    frame:SetPoint("TOPLEFT", owner, "BOTTOMRIGHT", 0, 0)
  else
    frame:SetPoint("TOPLEFT", owner, "TOPRIGHT", 8, 0)
  end

  local ui = UIParent
  if not (ui and frame:GetLeft()) then return end
  local dx, dy = 0, 0
  local right, left = frame:GetRight(), frame:GetLeft()
  local top, bottom = frame:GetTop(), frame:GetBottom()
  if right and right > ui:GetRight() then dx = ui:GetRight() - right - 4 end
  if left and left + dx < 0 then dx = -left + 4 end
  if top and top > ui:GetTop() then dy = ui:GetTop() - top - 4 end
  if bottom and bottom + dy < 0 then dy = -bottom + 4 end
  if dx ~= 0 or dy ~= 0 then
    local point, rel, relPoint, x, y = frame:GetPoint(1)
    frame:ClearAllPoints()
    frame:SetPoint(point, rel, relPoint, x + dx, y + dy)
  end
end

function Tip:Show()
  if not frame or not pending.owner then return end

  -- ⚠️ NEVER BOTH AT ONCE (Jason, Session 258: "the equipment tooltip coincides
  -- with the addon's custom tooltips"). Ours and the game's item card are two
  -- boxes answering two different questions, and with both anchored to the
  -- cursor they land on the same pixels. If ours is opening, the pointer is over
  -- one of our frames — so a GameTooltip still up belongs to the hover we are
  -- replacing, and closing it is right rather than rude.
  if GameTooltip and GameTooltip.IsShown and GameTooltip:IsShown() then
    GameTooltip:Hide()
  end

  -- MEASURE FIRST, LAY OUT SECOND. Every width below is what the font actually
  -- reports for that string, never an estimate — the rule this project wrote
  -- after a column header truncated with 0.7px to spare.
  local measured = {}
  title:SetText(pending.title or "")
  local c = pending.titleColor or { 1, 1, 1 }
  title:SetTextColor(c[1], c[2], c[3])
  local titleW = (pending.title and title:GetStringWidth()) or 0
  local titleH = (pending.title and title:GetHeight()) or 0

  for i, line in ipairs(pending.lines) do
    local r = rowAt(i)
    -- Coerced at the setter as well as at the source: this is the call that
    -- threw, and it should not be able to throw again whatever a caller passes.
    r.left:SetWordWrap(line.wrap and true or false)
    r.right:SetWordWrap(false)
    r.left:SetWidth(0)
    r.left:SetText(line.left)
    r.left:SetTextColor(line.color[1], line.color[2], line.color[3])
    r.right:SetText(line.right or "")
    if line.rightColor then
      r.right:SetTextColor(line.rightColor[1], line.rightColor[2], line.rightColor[3])
    end
    measured[i] = {
      leftW = r.left:GetStringWidth(),
      rightW = line.right and r.right:GetStringWidth() or 0,
      h = r.left:GetHeight(),
      wrap = line.wrap,
    }
  end

  local box = ns.TipLayout(measured, {
    pad = PAD, lineGap = LINE_GAP, titleGap = TITLE_GAP, colGap = GAP_COL,
    maxW = MAX_W, titleW = titleW, titleH = titleH,
  })

  -- A wrapped line only knows its height once it knows its width, so the wrapped
  -- ones are re-measured against the settled content width and the box grows to
  -- fit. One extra pass, and only when prose is present.
  local grew = 0
  for i, line in ipairs(pending.lines) do
    local r = rows[i]
    if line.wrap then
      r.left:SetWidth(box.contentW)
      local h = r.left:GetStringHeight()
      if h and h > measured[i].h then
        grew = grew + (h - measured[i].h)
        measured[i].h = h
      end
    end
  end
  if grew > 0 then
    box = ns.TipLayout(measured, {
      pad = PAD, lineGap = LINE_GAP, titleGap = TITLE_GAP, colGap = GAP_COL,
      maxW = MAX_W, titleW = titleW, titleH = titleH,
    })
  end

  for i = 1, #pending.lines do
    local r, y = rows[i], box.y[i]
    r.left:ClearAllPoints()
    r.left:SetPoint("TOPLEFT", PAD, -y)
    if not pending.lines[i].wrap then r.left:SetWidth(0) end
    r.left:Show()
    if pending.lines[i].right and pending.lines[i].right ~= "" then
      r.right:ClearAllPoints()
      r.right:SetPoint("TOPRIGHT", -PAD, -y)
      r.right:Show()
    else
      r.right:Hide()
    end
  end
  for i = #pending.lines + 1, #rows do
    rows[i].left:Hide()
    rows[i].right:Hide()
  end

  frame:SetSize(box.w, box.h)
  place(pending.owner, pending.anchor, box.w, box.h)
  frame:Show()
end

function Tip:Hide()
  if frame then frame:Hide() end
end

--- Whether the tooltip is up. Used by nothing yet; here because "is it showing"
--- is the first thing anyone asks of a tooltip and answering it costs a line.
function Tip:IsShown()
  return frame and frame:IsShown() or false
end
