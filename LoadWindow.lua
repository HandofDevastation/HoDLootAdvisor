-- LoadWindow.lua — where the runner pastes the raid payload
--
-- This is NOT the panel from HoD_LootAddon_Experience.md §3. It is one window
-- with one text box, built because the export has to land somewhere and chat
-- input caps out around 255 characters. The panel is still to come.
--
-- It also answers a question nobody could answer from documentation: how much
-- text a WoW EditBox will actually accept from a paste. It reports the byte
-- count it RECEIVED against the count the website says it SENT, so a silent
-- truncation shows up as a mismatch rather than as mysteriously wrong advice
-- later. Same instrument-what-you-cannot-verify approach as the loot logger.

local ADDON_NAME, ns = ...

local LoadWindow = {}
ns.LoadWindow = LoadWindow

-- Mirrors the site's palette (globals.css) the way Build Barn does — the addon
-- cannot use the CSS layer, so the few colours it needs are restated by hand.
local GOLD  = { 0.953, 0.773, 0.420 }
local GREEN = { 0.125, 0.729, 0.337 }
local RED   = { 1.000, 0.420, 0.420 }
local MUTED = { 0.533, 0.533, 0.600 }

local frame

local function setStatus(text, color)
  if not frame then return end
  frame.status:SetText(text or "")
  frame.status:SetTextColor(unpack(color or MUTED))
end

local function build()
  frame = CreateFrame("Frame", "HoDLootAdvisorLoadFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(560, 340)
  frame:SetPoint("CENTER")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetFrameStrata("DIALOG")
  ns.MakeWindow(frame)
  frame:Hide()

  frame.TitleText:SetText("Loot Advisor — Import Raid Night")

  local help = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  help:SetPoint("TOPLEFT", 16, -34)
  help:SetPoint("TOPRIGHT", -16, -34)
  help:SetJustifyH("LEFT")
  help:SetText("Export from the Loot Advisor page on the website, then paste here (Ctrl-V) and press Load.")
  help:SetTextColor(unpack(MUTED))

  -- A multiline EditBox inside a scroll frame. The box is given an EXPLICIT
  -- width: GetWidth() on the scroll frame returns 0 before the frame has been
  -- shown, which silently produces a zero-size box you cannot type into. That
  -- one has bitten HODLootTracker before.
  local scroll = CreateFrame("ScrollFrame", "$parentScroll", frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 18, -66)
  scroll:SetPoint("BOTTOMRIGHT", -36, 66)

  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetFontObject(ChatFontNormal)
  edit:SetWidth(500)
  edit:SetAutoFocus(false)
  -- Explicitly UNCAPPED. A fresh EditBox carries a default limit, and the
  -- failure mode of hitting it is SILENT TRUNCATION — the payload would decode
  -- to a corrupt table, or worse, a valid one missing raiders.
  edit:SetMaxLetters(0)
  if edit.SetMaxBytes then edit:SetMaxBytes(0) end
  edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  edit:SetScript("OnTextChanged", function(self)
    local n = #(self:GetText() or "")
    if n > 0 then
      setStatus(("%d characters in the box"):format(n), MUTED)
    end
  end)
  scroll:SetScrollChild(edit)
  frame.edit = edit

  frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.status:SetPoint("BOTTOMLEFT", 18, 40)
  frame.status:SetPoint("BOTTOMRIGHT", -18, 40)
  frame.status:SetJustifyH("LEFT")
  frame.status:SetWordWrap(true)

  local load = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  load:SetSize(110, 24)
  load:SetPoint("BOTTOMRIGHT", -18, 12)
  load:SetText("Load")
  load:SetScript("OnClick", function() LoadWindow.Submit() end)

  local clear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  clear:SetSize(110, 24)
  clear:SetPoint("RIGHT", load, "LEFT", -8, 0)
  clear:SetText("Clear")
  clear:SetScript("OnClick", function()
    frame.edit:SetText("")
    setStatus("", MUTED)
  end)

  return frame
end

--- Read the box and load it. Reports what it RECEIVED so a paste that got
--- truncated is visible immediately rather than at the worst possible moment.
function LoadWindow.Submit()
  local text = frame.edit:GetText() or ""
  local received = #text

  local data, err = ns.Payload.Decode(text)
  if not data then
    setStatus(("Failed: %s  (%d characters received)"):format(err, received), RED)
    ns.Warn(("could not load raid data: %s"):format(err))
    -- Recorded so a failed paste on raid night is diagnosable afterwards
    -- WITHOUT the payload itself, which is guild data and does not belong in a
    -- log file: length and error only.
    if ns.Diagnostics then
      ns.Diagnostics.Note("payloadFailed", { received = received, err = err })
    end
    return
  end

  -- The RAW text is kept beside the decoded table so it can be re-broadcast and
  -- whispered to late joiners without re-serializing the roster. PASTING is
  -- what makes you the runner — receiving a payload over comms does not, which
  -- is what stops twenty clients all answering one late joiner's request.
  ns.Payload.Store(data, text)
  if ns.Comms then ns.Comms.SetRunner(true) end
  local s = ns.Payload.Summary()

  -- Reaching here means the self-describing length check in Payload.Decode
  -- already passed, so the paste is provably complete. The character count is
  -- reported anyway: it is the number that tells us what a WoW EditBox will
  -- actually swallow, which is not documented anywhere.
  setStatus(("Loaded %d raiders · %d with standings · %s · %d characters received")
    :format(s.raiders, s.ranked, s.seasonName or "?", received), GREEN)

  -- GEAR age, not export age. These are different numbers and conflating them
  -- is a lie the runner cannot detect.
  ns.Print(("loaded %d raiders (%d ranked) for %s — gear synced %s.")
    :format(s.raiders, s.ranked, s.seasonName or "?", ns.Payload.GearAgeText()))

  if s.raiders > 0 and s.ranked == 0 then
    ns.Warn("nobody has an EPGP standing — priority will be blank in rankings.")
  end

  -- Push it to everyone else running the addon. Reported as a COUNT OF MESSAGES
  -- rather than silently, because the roster is ~60 of them on a throttled
  -- channel and takes a few seconds to go out — a runner who sees nothing
  -- happen has no way to tell that from a failure. Outside a group this is a
  -- no-op with a plain reason, which is the normal case when loading early.
  if ns.Comms then
    local chunks, err = ns.Comms.BroadcastRoster()
    if chunks then
      ns.Print(("broadcasting to the group — %d messages. |cff888888/la comms|r shows who received it.")
        :format(chunks))
    elseif err ~= "not in a group" then
      ns.Warn("could not broadcast raid data: " .. tostring(err))
    end
  end

  if ns.Diagnostics then
    ns.Diagnostics.Note("payloadLoaded", {
      received = received, raiders = s.raiders, ranked = s.ranked, stamp = s.stamp,
    })
  end

  frame.edit:SetText("")
  frame:Hide()
end

function LoadWindow.Toggle()
  if not frame then build() end
  if frame:IsShown() then
    frame:Hide()
    return
  end
  ns.DockBesidePanel(frame, "LEFT")
  frame:Show()
  frame.edit:SetText("")
  frame.edit:SetFocus()

  local s = ns.Payload.Summary()
  if s then
    setStatus(("Currently loaded: %d raiders, %s · exported %s, gear synced %s. Pasting replaces it.")
      :format(s.raiders, s.seasonName or "?", ns.Payload.AgeText(), ns.Payload.GearAgeText()), MUTED)
  else
    setStatus("Nothing loaded yet.", MUTED)
  end
end
