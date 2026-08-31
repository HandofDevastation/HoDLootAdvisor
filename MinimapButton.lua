-- MinimapButton.lua — the button that opens the panel.
--
-- WHY IT EXISTS. Until now the ONLY way to open this addon was a slash command.
-- Everything else it does has a button somewhere, and an action with no way in
-- but typing is a gap: people who install an addon and cannot find it conclude
-- it is broken, which is the same failure mode as a silent decline.
--
-- SELF-CONTAINED, NO LIBRARIES. Gloom's Build Barn registers with LibDBIcon so
-- button-collector addons adopt it, and its packager fetches four libs at
-- release time. That is a real benefit and a real cost — four vendored files in
-- a public repo, present in a release and absent in local dev, so the button you
-- test is not the button that ships. This one is ~90 lines with no dependency,
-- and the drag/persist behaviour it needs is the part Build Barn's own fallback
-- already implements. If a collector ever matters, the LibDBIcon path can be
-- added beside this exactly as Build Barn did.
--
-- ⚠️ THE ARTWORK IS A FULL-BLEED SQUARE, so it is MASKED to a circle at draw
-- time rather than being re-cut. Build Barn's crest carries its own transparent
-- badge shape; this icon does not — its corners are opaque dark — and a square
-- sitting inside the round tracking ring reads as a mistake. SetMask does the
-- job with no art change. See the guard below for what happens if it is absent.

local ADDON_NAME, ns = ...

local MinimapButton = {}
ns.MinimapButton = MinimapButton

local MEDIA = "Interface\\AddOns\\HoDLootAdvisor\\Media\\"

-- The standard circular alpha mask Blizzard ships and every round-portrait
-- surface in the UI uses. Named here rather than inline so the fallback below
-- is obviously about THIS file being missing, not about our own art.
local CIRCLE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

-- Geometry. The icon is drawn LARGER than Build Barn's 22px because that number
-- was chosen for a badge-shaped crest with transparent margins; a full-bleed
-- square masked to a circle has to fill the ring or it reads as a small picture
-- floating in a big border.
local BUTTON_SIZE = 31
local ICON_SIZE   = 25
local BORDER_SIZE = 53
local DEFAULT_ANGLE = 200

local btn

-- ---------------------------------------------------------------------------
-- Position
-- ---------------------------------------------------------------------------

--- Place the button on the minimap's rim at `angle` degrees.
local function position(angle)
  if not btn then return end
  local rad = math.rad(angle or DEFAULT_ANGLE)
  local r = (Minimap:GetWidth() / 2) + 5
  btn:ClearAllPoints()
  btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * r, math.sin(rad) * r)
end

--- Follow the cursor around the rim while dragging, and remember where it was
--- let go. Stored as an ANGLE rather than a screen point so it stays on the rim
--- when the minimap moves, resizes, or the UI scale changes.
local function onDragUpdate()
  local mx, my = Minimap:GetCenter()
  if not mx then return end
  local scale = Minimap:GetEffectiveScale()
  local px, py = GetCursorPosition()
  px, py = px / scale, py / scale
  local angle = math.deg(math.atan2(py - my, px - mx))
  position(angle)
  if ns.db then
    ns.db.minimap = ns.db.minimap or {}
    ns.db.minimap.angle = angle
  end
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function build()
  btn = CreateFrame("Button", "HoDLootAdvisorMinimapButton", Minimap)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(8)
  btn:SetSize(BUTTON_SIZE, BUTTON_SIZE)
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:RegisterForDrag("LeftButton")

  local icon = btn:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(MEDIA .. "minimap.png")
  icon:SetSize(ICON_SIZE, ICON_SIZE)
  icon:SetPoint("CENTER", 0, 0)

  -- ⚠️ GUARDED, AND IT DEGRADES TO A SQUARE RATHER THAN TO NOTHING. SetMask is
  -- present on modern clients, but if the call or the mask file ever fails the
  -- icon must still draw — a square icon is untidy, an invisible one is the
  -- addon looking uninstalled.
  if icon.SetMask then pcall(icon.SetMask, icon, CIRCLE_MASK) end

  local border = btn:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(BORDER_SIZE, BORDER_SIZE)
  border:SetPoint("TOPLEFT")

  btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  btn:SetScript("OnClick", function(_, mouseButton)
    if mouseButton == "RightButton" then
      if ns.RecordWindow and ns.RecordWindow.Toggle then ns.RecordWindow.Toggle() end
    elseif ns.Panel and ns.Panel.Toggle then
      ns.Panel.Toggle()
    end
  end)

  btn:SetScript("OnDragStart", function() btn:SetScript("OnUpdate", onDragUpdate) end)
  btn:SetScript("OnDragStop", function() btn:SetScript("OnUpdate", nil) end)

  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
    GameTooltip:SetText("Loot Advisor", 1, 1, 1)
    GameTooltip:AddLine("Left-click: open", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Right-click: loot log", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Drag: move around the minimap", 0.55, 0.55, 0.55)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  position(ns.db and ns.db.minimap and ns.db.minimap.angle or DEFAULT_ANGLE)
end

-- ---------------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------------

--- Create the button at login unless the setting hides it.
function MinimapButton.Init()
  local hidden = ns.Settings and ns.Settings.Get("hideMinimap")
  if hidden then return end
  if not btn then build() end
  btn:Show()
end

--- Show or hide it. Returns whether it is now shown, so the caller can say.
function MinimapButton.SetShown(shown)
  if shown then
    if not btn then build() end
    btn:Show()
  elseif btn then
    btn:Hide()
  end
  return shown and true or false
end

--- Whether the button currently exists and is visible.
function MinimapButton.IsShown()
  return btn ~= nil and btn:IsShown()
end
