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

  -- ⚠️ A MULTILINE EditBox IS ONLY AS TALL AS ITS TEXT. Empty, it is ONE LINE
  -- tall, so the only spot in this large window that would take a click was the
  -- top line — and the normal flow loses focus on the way to the website to
  -- copy the export. Clicking back into the obvious middle of the box did
  -- nothing, with no cursor and no explanation.
  --
  -- The catch goes on the SCROLL FRAME rather than on a fixed EditBox height:
  -- an 11 KB payload is far taller than this window, and pinning the child's
  -- height would clip it with nothing able to scroll.
  scroll:EnableMouse(true)
  scroll:SetScript("OnMouseDown", function() edit:SetFocus() end)

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

  -- ⚠️ "Clear" WAS THE WRONG NAME. Sat beside Load, under a status line reading
  -- "Currently loaded: 17 raiders… Pasting replaces it", it read as "clear the
  -- loaded roster" — which is not what it does and not what anyone wants it to
  -- do by accident. It empties the BOX. The label now says which.
  local clear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  clear:SetSize(110, 24)
  clear:SetPoint("RIGHT", load, "LEFT", -8, 0)
  clear:SetText("Clear Box")
  clear:SetScript("OnClick", function()
    frame.edit:SetText("")
    setStatus("", MUTED)
  end)

  -- Discarding the LOADED roster — the thing Clear was mistaken for. Anchored
  -- far left, away from Load and Clear Box, because it is the one destructive
  -- control in this window and should not sit in the row you press by habit.
  frame.discard = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.discard:SetSize(160, 24)
  frame.discard:SetPoint("BOTTOMLEFT", 18, 12)
  frame.discard:SetText("Discard Loaded Data")
  frame.discard:SetScript("OnClick", function() LoadWindow.ConfirmDiscard() end)

  return frame
end

--- ⚠️ CONFIRMED, AND THE PROMPT NAMES WHAT ELSE GOES. Payload.Clear drops the
--- roster, the raw copy AND the runner flag together — deliberately, since a
--- runner flag with nothing to send would answer every request with silence.
--- Mid-raid that is a bad accident, so the prompt says so rather than asking
--- "are you sure?" about a consequence it has not mentioned.
StaticPopupDialogs["HODLA_RAID_DISCARD"] = {
  text = "%s", button1 = "Discard", button2 = "Cancel",
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  OnAccept = function()
    ns.Payload.Clear()
    setStatus("Nothing loaded yet.", MUTED)
    ns.Print("tonight's raid data discarded.")
  end,
}

function LoadWindow.ConfirmDiscard()
  local s = ns.Payload.Summary()
  if not s then
    ns.Warn("there is no raid data loaded to discard.")
    return
  end

  local warning = ""
  if ns.Comms and ns.Comms.IsRunner() then
    warning = "\n\n|cffF3C56BYou are running loot tonight.|r Discarding stands you down, "
      .. "and nobody will be answering requests for the roster."
  end

  StaticPopup_Show("HODLA_RAID_DISCARD",
    ("Discard the loaded raid data?\n\n%d raiders, %s\nexported %s%s\n\n"):format(
      s.raiders, s.seasonName or "?", ns.Payload.AgeText(), warning)
    .. "Recorded loot is kept. Import again to get it back.")
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
  -- ...UNLESS somebody has explicitly claimed the role from the Runner tab, in
  -- which case pasting gives you the data without taking their job. Loading a
  -- fresher export is a normal thing for a second officer to do and must not
  -- silently reassign who the raid is listening to.
  local claimed, holder = true, nil
  if ns.Comms then claimed, holder = ns.Comms.AssumeRunner() end
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

  -- Said plainly rather than left to be discovered: this client will broadcast
  -- the roster below, but will NOT be the one whose rankings the raid follows.
  if not claimed then
    ns.Print(("%s is running loot tonight, so this stays their call — you have the data. "):format(
      tostring(holder)) .. "|cff888888Runner tab → Run Loot Tonight|r to take over.")
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

  -- Nothing loaded, nothing to discard. Disabled rather than left live to
  -- explain itself after the press — the ConfirmDiscard warning stays as the
  -- backstop for a payload cleared while this window sits open.
  frame.discard:SetEnabled(s ~= nil)
end
