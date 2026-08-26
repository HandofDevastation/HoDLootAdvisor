-- test/comms.lua — two clients, one Lua process, no game.
--
--   cd loot-advisor-addon
--   lua test/comms.lua
--
-- WHY THIS IS A SEPARATE HARNESS. smoke.lua boots ONE character and proves the
-- addon's wiring end to end. A protocol cannot be proved that way: every
-- interesting failure in comms is a disagreement BETWEEN two clients, and a
-- single client talking to itself would agree with itself about anything,
-- including a bug.
--
-- So this loads the addon TWICE, as two characters with their own frames, saved
-- variables and equipped gear, and wires one's outbound addon messages into the
-- other's CHAT_MSG_ADDON handler. Everything below the wire is the REAL code:
-- the real send queue, the real 255-byte limit, the real envelope, the real
-- reassembly, the real handlers.
--
-- ⚠️ WHAT THIS CANNOT PROVE, and no stub can:
--   • Blizzard's actual throttle curve. The queue's backoff is exercised here
--     by forcing throttle results, which proves the CODE reacts — not that the
--     pacing numbers are right for a real 12 KB roster on a raid night.
--   • Whether the prefix registration is accepted by a live client.
--   • Whether INSTANCE_CHAT is genuinely required in LFR.
-- Those three are what `/la comms` (solo, in game) and the first instrumented
-- raid night are for. This harness deliberately does not pretend otherwise.
--
-- Exit status is 0 only when every check passes.

package.path = "./?.lua;./test/?.lua;" .. package.path

local stub = require("wow-stub")

local failures, checks = {}, 0
local function check(label, ok, detail)
  checks = checks + 1
  if not ok then
    failures[#failures + 1] = label .. (detail and ("  — " .. tostring(detail)) or "")
  end
  io.write(ok and "  ok   " or "  FAIL ", label, "\n")
  if not ok and detail then io.write("       ", tostring(detail), "\n") end
end

local function header(text)
  io.write("\n", ("─"):rep(72), "\n", text, "\n", ("─"):rep(72), "\n")
end

-- Quiet: two clients narrating a 60-message roster broadcast buries the checks.
local FILES = {
  "LootData.lua", "Style.lua", "Scoring.lua", "Core.lua", "Settings.lua",
  "Payload.lua", "Diagnostics.lua", "Comms.lua", "Journal.lua", "Targets.lua",
  "Tooltip.lua", "Record.lua", "Loot.lua",
}

stub.Install()

-- Muting suppresses the OUTPUT, never the RECORD. The addon's own warnings are
-- part of what is under test (a protocol mismatch must warn exactly once), and
-- a mute that also swallowed stub.printed would make those checks pass
-- vacuously — a test that cannot see the thing it asserts about.
local realPrint = _G.print
local muted = true
_G.print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  local line = table.concat(parts, " ")
  stub.printed[#stub.printed + 1] = line
  if not muted then
    realPrint((line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")))
  end
end

-- ── Two characters ──────────────────────────────────────────────────────────
--
-- Vörnix is not decoration. Her name is 7 BYTES and 6 CHARACTERS, and every
-- length that crosses a boundary in this system is measured in bytes — the same
-- trap that made an early raid-payload check reject every real export while
-- passing on an ASCII test roster.

local function character(name, realm)
  return {
    name = name, realm = realm or "Stormrage",
    classToken = "HUNTER", className = "Hunter",
    specId = 254, specName = "Marksmanship", heroTree = "Dark Ranger",
    equipped = {},
  }
end

local A = stub.NewClient(character("Gloomrift"))   -- the runner
local B = stub.NewClient(character("Vörnix"))      -- an ordinary installer

local nsA, nsB

stub.Use(A)
_G.HoDLootAdvisorDB = nil
nsA = stub.LoadAddon(FILES)
stub.Fire("ADDON_LOADED", "HoDLootAdvisor")
A.db = _G.HoDLootAdvisorDB

stub.Use(B)
_G.HoDLootAdvisorDB = nil
nsB = stub.LoadAddon(FILES)
stub.Fire("ADDON_LOADED", "HoDLootAdvisor")
B.db = _G.HoDLootAdvisorDB

-- ── The wire ────────────────────────────────────────────────────────────────
--
-- The real client ECHOES your own broadcasts back to you, which is why the
-- addon has to drop self-messages at all. The wire reproduces that rather than
-- quietly sparing the addon the case.

local clients = { [A] = nsA, [B] = nsB }
local wireLog = {}

-- ⚠️ LOGGED PER MESSAGE SENT, NOT PER RECIPIENT. A broadcast is delivered to
-- every client, so counting deliveries makes one broadcast look like two — and
-- "did the runner re-broadcast or answer one person" is exactly the question
-- this log exists to answer.
local function wire(msg)
  wireLog[#wireLog + 1] = { channel = msg.channel, target = msg.target, bytes = #msg.text }
  if msg.channel == "WHISPER" then
    -- Addressed to exactly one player. NOT a chat whisper: addon messages ride
    -- a hidden channel and raise CHAT_MSG_ADDON, never CHAT_MSG_WHISPER.
    for client in pairs(clients) do
      if client.player.name == msg.target then stub.Deliver(msg, client) end
    end
    return
  end
  for client in pairs(clients) do stub.Deliver(msg, client) end  -- includes the sender
end

stub.wire = wire

--- Run one client's queued timers until it has nothing left to do.
--- Bounded, so a drain that reschedules itself forever fails the test rather
--- than hanging it.
local function pump(client, rounds, maxDelay)
  local previous = stub.active
  stub.Use(client)
  local ran = 0
  for _ = 1, rounds or 400 do
    local n = stub.RunTimers(maxDelay)
    if n == 0 then break end
    ran = ran + n
  end
  stub.Use(previous)
  return ran
end

-- Both are in the same raid.
stub.inRaid, stub.inGroup = true, false

-- ═══════════════════════════════════════════════════════════════════════════
header("the envelope")
-- ═══════════════════════════════════════════════════════════════════════════

local Comms = nsA.Comms

do
  local text = Comms.Encode("ROSTER", 3, 7, "body-goes-here")
  check("an envelope round-trips", (function()
    local v, t, seq, total, body = Comms.Decode(text)
    return v == Comms.PROTOCOL and t == "ROSTER" and seq == 3 and total == 7
       and body == "body-goes-here"
  end)(), text)

  -- ⚠️ THE PAYLOAD IS THE LAST FIELD SO A PIPE INSIDE IT CANNOT BREAK PARSING.
  -- WoW item links are made of pipes, and one will end up in a body eventually.
  local piped = Comms.Encode("DROPS", 1, 1, "|cffa335ee|Hitem:270160|h[Thing]|h|r")
  local _, _, _, _, body = Comms.Decode(piped)
  check("a pipe inside the payload survives, because the payload is last",
        body == "|cffa335ee|Hitem:270160|h[Thing]|h|r", body)

  check("a malformed envelope is refused, not guessed at",
        (Comms.Decode("not an envelope")) == nil)

  -- ⚠️ ZERO IS TRUTHY IN LUA. A guard written as `if seq then` accepts 0 and
  -- allocates a buffer that can never complete. Both halves are pinned.
  check("seq 0 is refused (zero is truthy in Lua)",
        (Comms.Decode("1|HELLO|0|1|x")) == nil)
  check("total 0 is refused", (Comms.Decode("1|HELLO|1|0|x")) == nil)
  check("seq beyond total is refused", (Comms.Decode("1|HELLO|3|2|x")) == nil)
end

-- ═══════════════════════════════════════════════════════════════════════════
header("chunking — measured in bytes, against the real 255 limit")
-- ═══════════════════════════════════════════════════════════════════════════

do
  stub.addonSent = {}
  A.addonSent = {}
  stub.wire = nil  -- measure the sends without delivering them

  stub.Use(A)
  -- Accented text on purpose: 500 characters of "ä" is 1000 BYTES. Chunking by
  -- character count would produce messages that pass every ASCII test and are
  -- rejected outright by a real client.
  local body = ("ä"):rep(500)
  local total = Comms.Send("ROSTER", body, "RAID")
  pump(A)

  check("a multi-byte body chunks by bytes, not characters", total ~= nil and total > 1, total)

  local sentBodies, allUnder = {}, true
  for _, m in ipairs(A.addonSent) do
    if #m.text > 255 then allUnder = false end
    local _, _, seq, _, chunk = Comms.Decode(m.text)
    sentBodies[seq] = chunk
  end
  -- The stub ERRORS above 255 rather than truncating, matching the client, so
  -- reaching this line at all is half the proof; the check pins the other half.
  check("every chunk fits inside the 255-byte limit", allUnder)

  local rebuilt = {}
  for i = 1, total do rebuilt[#rebuilt + 1] = sentBodies[i] end
  check("the chunks reassemble to exactly the original bytes",
        table.concat(rebuilt) == body,
        ("%d bytes vs %d"):format(#table.concat(rebuilt), #body))

  A.addonSent = {}
  local big = ("x"):rep(220 * 1200)
  local bigTotal = Comms.Send("ROSTER", big, "RAID")
  pump(A, 5000)
  local worst = 0
  for _, m in ipairs(A.addonSent) do worst = math.max(worst, #m.text) end
  check("a twelve-hundred-chunk message still fits, chunk for chunk",
        bigTotal > 999 and worst <= 255, ("%d chunks, longest %d bytes"):format(bigTotal or 0, worst))

  -- ⚠️ THE ARITHMETIC IS PINNED DIRECTLY, not through the check above, because
  -- the check above CANNOT SEE THIS BUG: the safety margin is wider than the
  -- six bytes a four-digit sequence number adds, so sizing chunks against a
  -- one-digit header still squeaks under 255 and every end-to-end check passes.
  -- Reverting the fix left that check green, which makes it not a test of this.
  -- The property is that the budget accounts for the LONGEST header the message
  -- can carry, and the only honest way to assert it is on the number itself.
  check("the chunk budget is measured against the worst-case header",
        Comms.ChunkBytes("ROSTER")
          == (Comms.MESSAGE_LIMIT - Comms.SAFETY_MARGIN) - #Comms.HeaderFor("ROSTER", 9999, 9999),
        Comms.ChunkBytes("ROSTER"))
  check("...which is strictly smaller than a one-digit header would allow",
        Comms.ChunkBytes("ROSTER")
          < (Comms.MESSAGE_LIMIT - Comms.SAFETY_MARGIN) - #Comms.HeaderFor("ROSTER", 1, 1))

  A.addonSent = {}
  stub.addonSent = {}
end

-- ═══════════════════════════════════════════════════════════════════════════
header("reassembly")
-- ═══════════════════════════════════════════════════════════════════════════

do
  stub.Use(B)
  local C = nsB.Comms

  local parts = { "one-", "two-", "three" }
  -- OUT OF ORDER on purpose. Chunks are indexed by seq rather than appended, so
  -- arrival order must not matter.
  local body = C.Receive(C.Encode("GEAR", 2, 3, parts[2]), "RAID", "Someone")
  check("an incomplete message yields nothing", body == nil)
  body = C.Receive(C.Encode("GEAR", 3, 3, parts[3]), "RAID", "Someone")
  check("still nothing on the second of three", body == nil)
  body = C.Receive(C.Encode("GEAR", 1, 3, parts[1]), "RAID", "Someone")
  check("the last chunk to arrive completes it, whatever the order",
        body == "one-two-three", body)

  -- ⚠️ THE SAME TYPE FROM THE SAME SENDER ON TWO CHANNELS IS TWO MESSAGES.
  -- The runner answers a late joiner directly while broadcasting to the raid;
  -- keyed on sender+type alone those interleave into one buffer that still
  -- decodes to something plausible. Channel is part of the key for this reason.
  C.Receive(C.Encode("ROSTER", 1, 2, "AAAA"), "RAID", "Runner")
  C.Receive(C.Encode("ROSTER", 1, 2, "BBBB"), "WHISPER", "Runner")
  local raidBody = C.Receive(C.Encode("ROSTER", 2, 2, "aaaa"), "RAID", "Runner")
  local directBody = C.Receive(C.Encode("ROSTER", 2, 2, "bbbb"), "WHISPER", "Runner")
  check("two channels do not interleave into one corrupt buffer",
        raidBody == "AAAAaaaa" and directBody == "BBBBbbbb",
        tostring(raidBody) .. " / " .. tostring(directBody))

  -- A protocol mismatch is refused LOUDLY and exactly once, not on every chunk
  -- of a 60-chunk payload.
  local before = #stub.printed
  for i = 1, 5 do
    C.Receive(("9|HELLO|1|1|whatever%d"):format(i), "RAID", "Drifter")
  end
  local warnings = 0
  for i = before + 1, #stub.printed do
    if stub.printed[i]:find("different Loot Advisor protocol") then warnings = warnings + 1 end
  end
  check("a protocol mismatch warns once per sender, not once per message",
        warnings == 1, warnings)

  check("a reserved type is refused by name rather than silently ignored",
        select(2, C.Receive(C.Encode("BID_CAST", 1, 1, "x"), "RAID", "Someone"))
          == "BID_CAST is reserved in this build")
end

-- ═══════════════════════════════════════════════════════════════════════════
header("throttling — the queue reacts to what the client actually says")
-- ═══════════════════════════════════════════════════════════════════════════

do
  stub.Use(A)
  A.addonSent = {}
  stub.wire = nil
  local before = Comms.stats.throttled

  stub.throttleNext = 4
  Comms.Send("HELLO", "throttle-me", "RAID")
  pump(A)

  check("a throttled send is retried, not dropped",
        Comms.stats.throttled >= before + 1 and stub.throttleNext == 0,
        ("throttled %d times"):format(Comms.stats.throttled - before))

  local delivered = false
  for _, m in ipairs(A.addonSent) do
    if m.text:find("throttle%-me") then delivered = true end
  end
  check("...and the message still goes out afterwards", delivered)

  -- ⚠️ SUCCESS IS ZERO. `if result then` reports success for a throttle, a
  -- refusal and everything else. Pinned directly against the real enum values.
  local E = _G.Enum.SendAddonMessageResult
  local okSuccess = Comms.SendResult(E.Success)
  local okThrottle, wasThrottled = Comms.SendResult(E.AddonMessageThrottle)
  local okRefused = Comms.SendResult(E.NotInGroup)
  check("result 0 (Success) reads as success even though 0 is truthy", okSuccess == true)
  check("a throttle reads as not-sent AND as throttled",
        okThrottle == false and wasThrottled == true)
  check("a hard refusal reads as not-sent and not throttled", okRefused == false)
end

-- ═══════════════════════════════════════════════════════════════════════════
header("channel — INSTANCE_CHAT is not interchangeable with RAID")
-- ═══════════════════════════════════════════════════════════════════════════

do
  stub.Use(A)
  stub.inRaid, stub.inGroup, stub.instanceGroup = true, false, false
  check("a normal raid uses RAID", Comms.Channel() == "RAID", Comms.Channel())

  stub.instanceGroup = true
  -- In an LFG/LFR group, RAID and PARTY are not the group's channel and a
  -- message sent to them goes nowhere, with no error — in exactly the content
  -- that is most available for testing.
  check("an instance group uses INSTANCE_CHAT",
        Comms.Channel() == "INSTANCE_CHAT", Comms.Channel())

  stub.instanceGroup, stub.inRaid, stub.inGroup = false, false, true
  check("a party uses PARTY", Comms.Channel() == "PARTY", Comms.Channel())

  stub.inGroup = false
  check("solo has no channel at all", Comms.Channel() == nil)
  check("...and sending solo fails with a plain reason, rather than pretending",
        select(2, Comms.Send("HELLO", "x")) == "not in a group")

  stub.inRaid = true  -- back in the raid for everything below
end

-- ═══════════════════════════════════════════════════════════════════════════
header("loopback — the runner pastes, the other client receives")
-- ═══════════════════════════════════════════════════════════════════════════

local encoded
do
  local fh = io.open("test/payload.txt", "r")
  encoded = fh and fh:read("*a") or nil
  if fh then fh:close() end
  if not encoded then
    io.stderr:write("test/payload.txt missing — regenerate it:\n")
    io.stderr:write("  npx tsx loot-advisor-addon/test/make-payload.ts > loot-advisor-addon/test/payload.txt\n")
    os.exit(2)
  end
end

do
  stub.wire = wire

  -- A pastes tonight's export, exactly as LoadWindow does.
  stub.Use(A)
  local data, err = nsA.Payload.Decode(encoded)
  check("the runner's paste decodes", data ~= nil, err)
  nsA.Payload.Store(data, encoded)
  nsA.Comms.SetRunner(true)

  check("pasting makes you the runner", nsA.Comms.IsRunner() == true)
  check("...and B, who pasted nothing, is not", nsB.Comms.IsRunner() == false)

  check("B has no raid data before the broadcast", nsB.Payload.Current() == nil)

  A.addonSent = {}
  local chunks = nsA.Comms.BroadcastRoster()
  check("the roster is a genuinely multi-message payload", (chunks or 0) > 40, chunks)
  pump(A, 5000)

  local bSummary = nsB.Payload.Summary()
  check("B reassembled the whole roster from the wire",
        bSummary ~= nil and bSummary.raiders == 24,
        bSummary and bSummary.raiders)
  check("...with the season name intact, so it is the real payload",
        bSummary and bSummary.seasonName == "Midnight: Season 2",
        bSummary and bSummary.seasonName)

  -- REVERT-PROOF: this is only meaningful because the payload's own
  -- self-describing length check would reject a truncated reassembly. A single
  -- dropped chunk must not decode into a plausible short roster.
  check("receiving a payload does NOT make B the runner",
        nsB.Comms.IsRunner() == false)

  -- The echo of A's own broadcast must not be re-decoded as an inbound payload.
  check("A ignored the echo of its own broadcast",
        nsA.db.raidFrom == nil, tostring(nsA.db.raidFrom))
end

-- ═══════════════════════════════════════════════════════════════════════════
header("loopback — a late joiner asks, and only the runner answers")
-- ═══════════════════════════════════════════════════════════════════════════

do
  -- B reloads: payload gone.
  stub.Use(B)
  nsB.Payload.Clear()
  check("B starts with nothing again", nsB.Payload.Current() == nil)

  A.addonSent, B.addonSent = {}, {}
  wireLog = {}

  nsB.Comms.RequestPayload()
  pump(B)          -- B's WANT goes out
  pump(A, 5000)    -- A answers and drains the reply

  local direct, broadcast = 0, 0
  for _, w in ipairs(wireLog) do
    if w.channel == "WHISPER" then direct = direct + 1
    elseif w.channel == "RAID" then broadcast = broadcast + 1 end
  end

  check("B got the payload back", (nsB.Payload.Summary() or {}).raiders == 24)
  -- One person reloading must not cost the whole raid another 60 messages.
  -- Exactly ONE broadcast is expected and it is B's own WANT going out.
  check("the answer was addressed to B alone, not re-broadcast to the raid",
        direct > 40 and broadcast == 1, ("%d direct, %d broadcast"):format(direct, broadcast))

  -- THE RUNNER GATE. If B — who now holds a full payload but pasted nothing —
  -- also answered, a raid of twenty installers would answer one request twenty
  -- times over, on a channel that is already throttled.
  --
  -- ⚠️ THE REQUEST CARRIES STAMP 0 DELIBERATELY. A WANT from someone who
  -- already has tonight's data is refused by the STALENESS check long before
  -- the runner gate is reached, so a test built that way passes with the gate
  -- removed — it did, on the first attempt, and proved nothing. Stamp 0 means
  -- "I have nothing", which is the only request that reaches the gate at all.
  B.addonSent = {}
  stub.Use(B)
  nsB.Comms.Handle(nsB.Comms.Encode("WANT", 1, 1, "0"), "RAID", "Latecomer")
  pump(B, 5000)
  local bReplies = 0
  for _, m in ipairs(B.addonSent) do
    if m.text:find("|ROSTER|") then bReplies = bReplies + 1 end
  end
  check("a non-runner never answers a request for the payload", bReplies == 0, bReplies)

  -- ⚠️ THE REQUEST IS RATE-LIMITED, and the reason is the ANSWER's cost.
  -- GROUP_ROSTER_UPDATE fires on every join, leave and role change — dozens of
  -- times in a raid's first minutes — and each unlimited request pulls a
  -- ~60-message reply out of the runner. The client with nothing is the one
  -- worst placed to be flooding the raid.
  B.addonSent = {}
  stub.Use(B)
  nsB.Payload.Clear()
  -- Forced, to establish a known "just asked" state: B already asked once
  -- earlier in this section, and the whole harness runs inside one second.
  local first = nsB.Comms.RequestPayload(true)
  local second, whySecond = nsB.Comms.RequestPayload()
  check("a repeated request is refused, not sent again",
        first ~= nil and second == nil and whySecond == "too soon",
        tostring(first) .. " / " .. tostring(whySecond))
  check("...but a deliberate /la comms want is not rate-limited",
        nsB.Comms.RequestPayload(true) ~= nil)
  pump(B, 5000)
  pump(A, 5000)

  -- ...and the same request DOES reach the runner, so the check above is about
  -- the gate rather than about the message never arriving.
  A.addonSent = {}
  stub.Use(A)
  nsA.Comms.Handle(nsA.Comms.Encode("WANT", 1, 1, "0"), "RAID", "Latecomer")
  pump(A, 5000)
  local aReplies = 0
  for _, m in ipairs(A.addonSent) do
    if m.text:find("|ROSTER|") then aReplies = aReplies + 1 end
  end
  check("...but the runner does answer it", aReplies > 40, aReplies)
end

-- ═══════════════════════════════════════════════════════════════════════════
header("loopback — live gear beats the site snapshot")
-- ═══════════════════════════════════════════════════════════════════════════

do
  local raid = nsA.Payload.Current()

  -- Find a raider who is actually in the payload and whose CHEST the snapshot
  -- has an item level for, chosen FROM THE DATA so this survives a re-export.
  local subject, snapshot
  for _, r in ipairs(raid.roster) do
    local st = nsA.Payload.SlotState(r, "CHEST")
    if st and st.ilvl > 0 then subject, snapshot = r, st break end
  end
  check("the fixture has a raider with a snapshot CHEST to improve on",
        subject ~= nil, subject and subject.n)

  check("before any self-report, the state is the snapshot",
        snapshot.source == "snapshot", snapshot.source)

  -- That raider's own client now reports something different. Fed through the
  -- REAL receive path from a sender named as them, rather than poked into the
  -- table, so the sender normalization is part of what is being tested.
  stub.Use(A)
  local better = snapshot.ilvl + 13
  nsA.Comms.Handle(
    nsA.Comms.Encode("GEAR", 1, 1, ("CHEST,%d,Myth"):format(better)),
    "RAID", subject.n)

  local live = nsA.Payload.SlotState(subject, "CHEST")
  check("a self-report replaces the snapshot for that slot",
        live.ilvl == better and live.source == "live",
        ("%d / %s"):format(live.ilvl, tostring(live.source)))

  local other = nsA.Payload.SlotState(subject, "HEAD")
  check("...and only for that slot — HEAD is still the snapshot",
        other ~= nil and other.source == "snapshot", other and other.source)

  -- A NON-REPORTING RAIDER IS NEVER SILENTLY MISSING. This is the property that
  -- lets one installer be a working system, so it is pinned rather than assumed.
  local absent = nil
  for _, r in ipairs(raid.roster) do
    if r.n ~= subject.n then absent = r break end
  end
  local absentState = nsA.Payload.SlotState(absent, "CHEST")
  check("a raider who reports nothing still resolves, from the snapshot",
        absentState ~= nil and absentState.source == "snapshot")

  -- Provenance is reported to the panel from CORE, not from Panel.lua — pure
  -- logic in Panel is untestable here, which this project has got wrong before.
  check("live gear carries a provenance tag", (nsA.ProvenanceTag(live)) == "live")
  check("the snapshot deliberately carries none — tagging every row is wallpaper",
        nsA.ProvenanceTag(absentState) == nil)

  -- THE REPORTING GAP IS VISIBLE. A non-reporting raider is still ranked, from
  -- the snapshot — but "ranked from what they are wearing now" and "ranked from
  -- a snapshot that may be hours old" are different claims, and the runner is
  -- the person who needs to know which is which.
  local gear = nsA.GearReportingSummary()
  check("the reporting gap is countable", gear ~= nil and gear.total == 24,
        gear and gear.total)
  check("...with exactly the one self-reporter counted", gear.reporting == 1, gear.reporting)
  check("...and everyone else NAMED as missing, not just totalled",
        #gear.missing == 23, #gear.missing)
  local named = false
  for _, n in ipairs(gear.missing) do if n == subject.n then named = true end end
  check("the raider who DID report is absent from the missing list", named == false)

  -- Round-trip the encoder against the decoder, since both halves are ours and
  -- agreeing with myself twice is the failure mode.
  -- An item level is REQUIRED here, and its absence is not a fixture detail:
  -- EncodeGear refuses to report a slot whose level has not resolved, because
  -- claiming ilvl 0 would override a good snapshot with nothing.
  stub.player.equipped[_G.INVSLOT_CHEST] = { itemID = 270160, name = "Test Chest", ilvl = 308 }
  local encodedGear = nsA.Comms.EncodeGear()
  local decodedGear = nsA.Comms.DecodeGear(encodedGear)
  check("gear encode/decode round-trips through the real slot names",
        decodedGear.CHEST ~= nil, encodedGear)
  check("gear names its slots rather than relying on a shared order",
        encodedGear:find("CHEST,") ~= nil, encodedGear)
end

-- ═══════════════════════════════════════════════════════════════════════════
header("in-night correction — a winner drops off future lists")
-- ═══════════════════════════════════════════════════════════════════════════

do
  stub.Use(A)
  nsA.Comms.ClearCorrections()

  local data = _G.HoDLootAdvisorData
  local raid = nsA.Payload.Current()

  -- A real CHEST from the emitted payload, picked from the data.
  local chestId, chest
  for id, it in pairs(data.items) do
    if it.slot == "CHEST" and it.ilvl and it.ilvl.h and it.ilvl.h > 0 then
      chestId, chest = id, it
      break
    end
  end
  check("the payload has a chest to award", chestId ~= nil)

  local subject
  for _, r in ipairs(raid.roster) do
    local st = nsA.Payload.SlotState(r, "CHEST")
    if st and st.source == "snapshot" and st.ilvl > 0 and st.ilvl < chest.ilvl.h then
      subject = r break
    end
  end
  check("...and a raider it would be an upgrade for", subject ~= nil, subject and subject.n)

  local before = nsA.Payload.SlotState(subject, "CHEST")
  local ok, slot = nsA.Comms.NoteWin(subject.n, chestId, { difficulty = "h" })
  check("a win is recorded against the item's own slot", ok == true and slot == "CHEST", slot)

  local after = nsA.Payload.SlotState(subject, "CHEST")
  check("the winner's slot is patched upward",
        after.ilvl == chest.ilvl.h and after.ilvl > before.ilvl,
        ("%d -> %d"):format(before.ilvl, after.ilvl))
  check("...and is marked as corrected rather than passed off as live",
        after.source == "corrected", after.source)
  check("the panel gets a distinct tag for it",
        (nsA.ProvenanceTag(after)) == "won")

  -- Never DOWNGRADE on a correction: winning a Normal piece does not undo the
  -- Heroic one from an hour ago, and the snapshot holds the WORST piece in the
  -- slot, so a lower value would wrongly reopen them as a candidate.
  local ok2, why = nsA.Comms.NoteWin(subject.n, chestId, { difficulty = "n" })
  check("a later, worse win does not undo a better one", ok2 == false, why)
  check("...and the slot still reads the better item level",
        nsA.Payload.SlotState(subject, "CHEST").ilvl == chest.ilvl.h)

  -- An omni-token has no single slot, so there is nothing to correct. It must
  -- refuse by name rather than corrupt a slot chosen at random.
  local omniId
  for id, it in pairs(data.items) do
    if it.slot == "TOKEN" and it.tokenSlot == nil then omniId = id break end
  end
  if omniId then
    local okOmni, whyOmni = nsA.Comms.NoteWin(subject.n, omniId)
    check("an omni-token win is refused with a reason, not filed somewhere",
          okOmni == false and whyOmni == "item has no single slot", whyOmni)
  end

  local okUnknown, whyUnknown = nsA.Comms.NoteWin(subject.n, 1)
  check("an item we do not have is refused by name",
        okUnknown == false and whyUnknown == "item not in our table", whyUnknown)

  -- ⚠️ THE CORRECTION IS DERIVED LOCALLY AND SENDS NOTHING. Every client in the
  -- group reads the same C_LootHistory, which is exactly why this also covers
  -- raiders who never installed the addon. A message would only add a way for
  -- two clients to disagree about a fact both can already see.
  A.addonSent = {}
  nsA.Comms.NoteWin(subject.n, chestId, { difficulty = "m" })
  pump(A)
  check("recording a win broadcasts nothing at all", #A.addonSent == 0, #A.addonSent)
end

-- ═══════════════════════════════════════════════════════════════════════════
header("loopback — the runner's ranking is the authoritative one")
-- ═══════════════════════════════════════════════════════════════════════════

do
  stub.Use(A)
  local data = _G.HoDLootAdvisorData
  local chestId
  for id, it in pairs(data.items) do
    if it.slot == "CHEST" then chestId = id break end
  end

  local ranked = nsA.Loot.RankRaiders(chestId, { difficulty = "h" })
  check("the runner can rank the roster for an item", ranked ~= nil and #ranked > 0,
        ranked and #ranked)

  A.addonSent = {}
  local chunks = nsA.Comms.BroadcastDrops(chestId, ranked)
  check("the runner broadcasts it", chunks ~= nil, chunks)
  pump(A, 2000)

  local rows, from = nsB.Comms.AuthoritativeRanking(chestId)
  check("B received the runner's ranking", rows ~= nil and #rows == #ranked,
        rows and (#rows .. " vs " .. #ranked))
  check("...attributed to the runner", from == "gloomrift", tostring(from))
  check("...with the leader's name intact through the encoding",
        rows and rows[1] and rows[1].name == ranked[1].name,
        rows and rows[1] and rows[1].name)

  -- REVERT-PROOF: any installer being able to reorder everyone's panel is the
  -- failure this gate exists for.
  local fakeItem = chestId
  nsB.Comms.rankings[fakeItem] = nil
  stub.Use(B)
  nsB.Comms.Handle(
    nsB.Comms.Encode("DROPS", 1, 1, ("%d;Impostor,Major,0,99,9.9"):format(fakeItem)),
    "RAID", "Someguy")
  check("a ranking from someone who is not the runner is ignored",
        nsB.Comms.AuthoritativeRanking(fakeItem) == nil)

  -- A non-runner must not be able to broadcast one either.
  check("a non-runner cannot broadcast a ranking",
        select(2, nsB.Comms.BroadcastDrops(chestId, ranked)) == "not the runner")
end

-- ═══════════════════════════════════════════════════════════════════════════
header("the solo volume self-test")
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The in-game command that measures the one thing no stub can: whether the
-- client silently drops chunks under load. Tested here for its LOGIC — that it
-- arms, sends the real payload through the real queue, captures its own
-- messages instead of dropping them, and compares byte for byte. What it
-- reports in game is a fact about Blizzard, not about this code.

do
  stub.Use(A)
  local raw = nsA.Comms.CurrentRaw()
  check("the runner still holds the raw payload to test with", raw ~= nil and #raw > 10000,
        raw and #raw)

  local before = #stub.printed
  nsA.Comms.SelfTest("volume")

  -- Drain the queue WITHOUT letting the verdict fire. A scheduler that ignores
  -- delay judges the send before it happens; the ceiling has to sit between the
  -- drain's own interval (0.15s) and the verdict poll's (1s), so only drains
  -- run here and the verdict is inspected deliberately below.
  pump(A, 5000, 0.5)

  local st = nsA.Comms.selfTest
  check("the payload came back to itself, byte for byte",
        st ~= nil and st.heard == true and st.body == raw,
        st and st.body and ("%d of %d bytes"):format(#st.body, #raw))
  check("...having arrived as many messages, not one",
        st and (st.chunksIn or 0) > 40, st and st.chunksIn)

  -- ⚠️ THE ELAPSED FIGURE MUST BE THE SEND, NOT THE TIMEOUT. The first live run
  -- reported "30s" for a send that took about two, because the only clock read
  -- was the verdict timer's own delay — a measurement that always returns its
  -- own timeout is not a measurement.
  check("the send is timed from when it started to when it arrived",
        st ~= nil and st.startedAt ~= nil and st.doneAt ~= nil
          and st.doneAt > st.startedAt,
        st and ("%s -> %s"):format(tostring(st.startedAt), tostring(st.doneAt)))
  local measured = st.doneAt - st.startedAt
  check("...and is nowhere near the 30-second giving-up point",
        measured < 20, ("%.1fs"):format(measured))

  -- Now the verdict. It polls, so it lands as soon as the payload is whole
  -- rather than making the runner sit through the full deadline every time.
  pump(A, 10)
  local verdict = (#stub.printed > before)
    and table.concat(stub.printed, "\n", before + 1, #stub.printed) or "(nothing printed)"
  check("the verdict reports a pass", verdict:find("PASSED") ~= nil)
  check("...and disarms itself, so later self-messages are dropped normally again",
        nsA.Comms.selfTest == nil)

  -- ⚠️ THE ARM MUST EXPIRE ON A CLOCK TOO. If the verdict timer never fires —
  -- an error mid-callback, a disconnect — a permanently armed test would eat
  -- every one of our own messages from then on, silently. That is the exact
  -- class of invisible failure this whole file is built to avoid, so the escape
  -- hatch is pinned rather than trusted.
  nsA.Comms.selfTest = { mode = "loop", sentAt = 1, heard = false }
  nsA.Comms.Handle(nsA.Comms.Encode("HELLO", 1, 1, "x"), "RAID", "Gloomrift")
  check("an abandoned self-test expires instead of swallowing traffic forever",
        nsA.Comms.selfTest == nil)

  -- ⚠️ A PAYLOAD PASTED BEFORE THIS BUILD HAS NO RAW COPY, and this is the
  -- state where every OTHER signal looks healthy: a full roster on screen,
  -- rankings computed correctly, and no ability to send any of it. Caught in
  -- game on the first run, where it reported "no raid data loaded" while
  -- holding seventeen raiders — sending the runner after the wrong problem.
  local saved = nsA.db.raidRaw
  nsA.db.raidRaw = nil
  check("a roster with no raw copy is 'legacy', NOT 'none'",
        nsA.Comms.RawStatus() == "legacy", nsA.Comms.RawStatus())
  local problem = nsA.Comms.RawProblem()
  check("...and the message says the roster is THERE, not missing",
        problem:find("older build") ~= nil and problem:find("24%-raider") ~= nil, problem)
  check("...and names the fix", problem:find("/la load") ~= nil)
  check("a runner in that state cannot claim to be one",
        nsA.Comms.IsRunner() == false)
  check("...and broadcasting refuses with the SAME explanation, not a generic one",
        select(2, nsA.Comms.BroadcastRoster()) == problem)

  before = #stub.printed
  nsA.Comms.SelfTest("volume")
  local refused = (#stub.printed > before)
    and table.concat(stub.printed, "\n", before + 1, #stub.printed) or "(nothing printed)"
  check("the volume test refuses rather than passing vacuously",
        refused:find("older build") ~= nil and nsA.Comms.selfTest == nil)
  nsA.db.raidRaw = saved

  -- With no payload at all it is a genuinely different sentence.
  local savedRaid = nsA.db.raid
  nsA.db.raidRaw, nsA.db.raid = nil, nil
  check("with nothing loaded at all it is 'none'", nsA.Comms.RawStatus() == "none")
  check("...and says so plainly", nsA.Comms.RawProblem():find("no raid data loaded") ~= nil)
  nsA.db.raidRaw, nsA.db.raid = saved, savedRaid
  check("and with both back, it is ok again", nsA.Comms.RawStatus() == "ok")
end

-- ═══════════════════════════════════════════════════════════════════════════
header("presence, and what the runner can actually see")
-- ═══════════════════════════════════════════════════════════════════════════

do
  stub.Use(B)
  nsB.Comms.Announce(true)
  pump(B)

  local peers = nsA.Comms.PeerList()
  local sawB = false
  -- Lowercased, because that is the key comms normalizes a sender to. Derived
  -- from the client's own name rather than written out, so renaming a fixture
  -- cannot leave a stale literal here that silently stops matching.
  local bKey = nsB.Comms.Normalize(B.player.name)
  for _, p in ipairs(peers) do if p.name == bKey then sawB = true end end
  check("the runner can see who else is running it", sawB,
        (#peers) .. " peers")

  -- The runner counting themselves would make "6 addons received it" a lie.
  local sawSelf = false
  local aKey = nsA.Comms.Normalize(A.player.name)
  for _, p in ipairs(peers) do if p.name == aKey then sawSelf = true end end
  check("...and does not count themselves", sawSelf == false)

  -- Both halves of the counters, because "nobody sent anything" and "nothing
  -- arrived" are the two explanations for a quiet raid and they need opposite
  -- fixes. A single "messages" number cannot tell them apart.
  local s = nsA.Comms.stats
  check("sending is counted", s.sent > 0, s.sent)
  check("receiving is counted separately", s.received > 0, s.received)
  check("reassembled payloads are counted separately again", s.assembled > 0, s.assembled)

  muted = false
  stub.Use(A)
  nsA.Comms.Status()
  muted = true
end

-- ── Result ──────────────────────────────────────────────────────────────────

muted = false
_G.print = realPrint

io.write("\n", ("═"):rep(72), "\n")
if #failures == 0 then
  io.write(("PASS — %d checks, two clients\n"):format(checks))
  os.exit(0)
end
io.write(("FAIL — %d of %d checks\n\n"):format(#failures, checks))
for _, f in ipairs(failures) do io.write("  · ", f, "\n") end
os.exit(1)
