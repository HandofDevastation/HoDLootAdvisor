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

--- ⚠️ A NIL COLOUR MEANS "THE STRING COLOURS ITSELF" and is not the same as
--- omitting one. The loaded-summary line carries its own inline escapes, and a
--- fontstring tinted muted grey underneath them would drag every uncoloured run
--- towards grey. White is the neutral the escapes are drawn against.
local function setStatus(text, color)
  if not frame then return end
  frame.status:SetText(text or "")
  if color then
    frame.status:SetTextColor(unpack(color))
  elseif ns.Style then
    frame.status:SetTextColor(ns.Style.rgb(ns.Style.COLOR.white))
  end
end

-- ── Geometry, read off node 591:2308 (600x400) ─────────────────────────────
--
-- ONE TABLE for the same reason Panel.lua groups its constants: file-scope
-- names are what Lua 5.1 counts against its 200-local ceiling, and the smoke
-- harness now measures the margin.
local IW = {
  w = 600, h = 400,
  logoX = 40, logoY = 30,
  titleX = 40, titleY = 86,
  boxX = 40, boxY = 131, boxW = 520, boxH = 120,
  boxPad = 16,
  statusX = 40, statusY = 262,
  -- ⚠️ 40 ON THE LEFT AND 43 ON THE RIGHT. That asymmetry is the mock's, not a
  -- rounding slip on the way in — the button row's right edge lands at 557.
  btnY = 343, btnH = 26,
  discardX = 40, discardW = 180,
  clearX = 369, clearW = 103,
  loadX = 485, loadW = 72,
}

local function build()
  frame = CreateFrame("Frame", "HoDLootAdvisorLoadFrame", UIParent)
  frame:SetSize(IW.w, IW.h)
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

  -- ⚠️ THE WINDOW'S OWN GROUND IS #1c1228, LIGHTER THAN THE PANEL'S. Painted
  -- over whatever MakeWindow put down rather than layered on top of it, which
  -- is the mistake Style.PanelGround's own comment records.
  if S then
    if frame.bgTex then frame.bgTex:Hide() end
    if frame.headTex then frame.headTex:Hide() end
    if frame.headLine then frame.headLine:Hide() end
    -- No rim: the fill is the window, exactly as on the panel.
    S.Surface(frame, S.COLOR.windowGround, 1)
    S.Lockup(frame, IW.logoX, IW.logoY)
  end

  -- The window's own heading. 18 Light white — not a title bar, because the
  -- redesign has no title bars: the lockup is the identity and this names the
  -- task beneath it.
  frame.heading = S and S.Text(frame, "light", "title", S.COLOR.white, "LEFT")
    or frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  if S then S.SetFont(frame.heading, S.FONT.light, 18) end
  frame.heading:ClearAllPoints()
  frame.heading:SetPoint("TOPLEFT", IW.titleX, -IW.titleY)
  frame.heading:SetText("IMPORT ROSTER DATA")

  -- ── The paste box ─────────────────────────────────────────────────────────
  -- The PANEL's darker ground inside the lighter window, with the rule blush at
  -- 30% as its border — the same hairline the Slots rail draws.
  local box = CreateFrame("Frame", nil, frame)
  box:SetSize(IW.boxW, IW.boxH)
  box:SetPoint("TOPLEFT", IW.boxX, -IW.boxY)
  if S then
    S.Surface(box, S.COLOR.ground, 1)
    S.Rim(box, S.COLOR.rule, 0.3)
  end
  frame.box = box

  -- A multiline EditBox inside a scroll frame. The box is given an EXPLICIT
  -- width: GetWidth() on the scroll frame returns 0 before the frame has been
  -- shown, which silently produces a zero-size box you cannot type into. That
  -- one has bitten HODLootTracker before.
  -- ⚠️ NO TEMPLATE, BECAUSE THE TEMPLATE IS THE SCROLL BAR (Jason, Session 262:
  -- "remove the scroll bars in the paste window. They're not necessary, plus
  -- they're using the game's default styling"). UIPanelScrollFrameTemplate
  -- brings Blizzard's own up/down/thumb artwork, which is the one piece of
  -- game chrome left on this window. A bare ScrollFrame still holds the child
  -- and still scrolls — and this box is written INTO, never read out of, so
  -- there is nothing to scroll back through.
  local scroll = CreateFrame("ScrollFrame", nil, box)
  scroll:SetPoint("TOPLEFT", IW.boxPad, -IW.boxPad)
  scroll:SetPoint("BOTTOMRIGHT", -IW.boxPad, IW.boxPad)

  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetFontObject(ChatFontNormal)
  edit:SetWidth(IW.boxW - IW.boxPad * 2)
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
    -- The prompt is what an empty box says; it must go the moment there is text
    -- in it, or it draws underneath what is being pasted.
    if frame.prompt then frame.prompt:SetShown(n == 0) end
  end)
  scroll:SetScrollChild(edit)
  frame.edit = edit

  -- The placeholder. A real fontstring rather than text in the EditBox, because
  -- text in the box would be SUBMITTED — and the whole window exists to submit
  -- exactly what is in the box.
  frame.prompt = S and S.Text(box, "light", "head", { r = 0.949, g = 0.741, b = 0.678, a = 0.5 }, "LEFT")
    or box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.prompt:ClearAllPoints()
  frame.prompt:SetPoint("TOPLEFT", IW.boxPad, -(IW.boxPad - 1))
  frame.prompt:SetWidth(IW.boxW - IW.boxPad * 2)
  frame.prompt:SetText(
    "Export from the Loot Advisor page on the website, then paste here and press LOAD.")

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

  frame.status = S and S.Text(frame, "light", "head", S.COLOR.white, "LEFT")
    or frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.status:ClearAllPoints()
  frame.status:SetPoint("TOPLEFT", IW.statusX, -IW.statusY)
  frame.status:SetWidth(IW.w - IW.statusX * 2)
  frame.status:SetWordWrap(true)

  -- ── The three controls ────────────────────────────────────────────────────
  -- One primitive, three instances, matching every other button in the
  -- redesign: a 1px gradient rim with the label at half strength.
  local function button(label, x, w, onClick)
    local b = S and S.Control(frame, label) or CreateFrame("Button", nil, frame,
      "UIPanelButtonTemplate")
    b:SetSize(w, IW.btnH)
    b:SetPoint("TOPLEFT", x, -IW.btnY)
    if b.SetActive then b:SetActive(false) end
    if b.Repaint then b:Repaint() end
    if not S then b:SetText(label) end
    b:SetScript("OnClick", onClick)
    return b
  end

  frame.load = button("LOAD", IW.loadX, IW.loadW, function() LoadWindow.Submit() end)

  -- ⚠️ "Clear" WAS THE WRONG NAME. Sat beside Load, under a status line reading
  -- "Currently loaded: 17 raiders… Pasting replaces it", it read as "clear the
  -- loaded roster" — which is not what it does and not what anyone wants it to
  -- do by accident. It empties the BOX. The label says which.
  frame.clear = button("CLEAR BOX", IW.clearX, IW.clearW, function()
    frame.edit:SetText("")
    setStatus("", MUTED)
  end)

  -- Discarding the LOADED roster — the thing Clear was mistaken for. Anchored
  -- far left, away from Load and Clear Box, because it is the one destructive
  -- control in this window and should not sit in the row you press by habit.
  frame.discard = button("DISCARD LOADED DATA", IW.discardX, IW.discardW,
    function() LoadWindow.ConfirmDiscard() end)

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

  -- ⚠️ THREE LABELLED FACTS SEPARATED BY BULLETS, per node 591:2306 — labels in
  -- the blush, values in white, the separator in the heading purple. The old
  -- single muted sentence carried the same information and read as a paragraph;
  -- the design makes each fact scannable on its own.
  local s = ns.Payload.Summary()
  if s then
    local S = ns.Style
    local lbl = S and S.code(S.COLOR.body) or ""
    local sep = S and (" " .. S.code(S.COLOR.accent) .. "\226\128\162|r ") or " \226\128\162 "
    local stop = S and "|r" or ""
    setStatus(table.concat({
      lbl .. "Currently Loaded: " .. stop .. ("%d Raiders"):format(s.raiders),
      lbl .. "Previous Import: " .. stop .. ns.Payload.AgeText(),
      lbl .. "Gear Sync: " .. stop .. ns.Payload.GearAgeText(),
    }, sep), nil)
  else
    setStatus("Nothing loaded yet.", MUTED)
  end

  -- Nothing loaded, nothing to discard. Disabled rather than left live to
  -- explain itself after the press — the ConfirmDiscard warning stays as the
  -- backstop for a payload cleared while this window sits open.
  frame.discard:SetEnabled(s ~= nil)
end
