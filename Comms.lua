-- Comms.lua — addon-to-addon messaging
--
-- THE KEYSTONE (Data Contract §4). Three capabilities in
-- HoD_LootAddon_Experience.md §5 are claimed and cannot exist without this file:
--   6. live gear accuracy   — installers self-report exactly (§3.2 tier 1)
--   7. in-night correction  — a winner drops off future lists for that slot
--   and the multi-installer story generally: one runner pastes, everyone sees it.
--
-- THE DESIGN CONSTRAINT THAT SHAPES EVERYTHING: most of the raid will not
-- install this. So the system must be fully useful with exactly ONE installer
-- and get incrementally better with each additional one. Nothing here is ever
-- gated behind "enough people have it" — every path degrades to the site
-- snapshot, which is what the addon already runs on today.
--
-- ⚠️ THIS FILE NEVER SPEAKS TO THE RAID. Addon messages travel on a hidden
-- channel that only other addons see; they are NOT chat. The standing rule in
-- rules/HoD_Rules_Loot-Gear.txt — "the addon never speaks to the raid on its
-- own" — is about SendChatMessage, which lives in Loot.lua behind a deliberate
-- button press. Nothing in this file can produce a line a player reads.
--
-- WHAT IS DELIBERATELY NOT HERE:
--   • Bidding. BID_OPEN / BID_CAST / BID_CLOSE / BID_RESULT are RESERVED in the
--     type table and refused on receipt with a named reason, so switching
--     bidding on later is a handler, not a flag day. Backburnered because it is
--     meaningless until EPGP actually decides loot.
--   • Compression. LibDeflate is GPL v3 and vendoring it would relicense a
--     public repo that is not ours to relicense (Payload.lua carries the same
--     note). The PROTOCOL VERSION in every envelope makes adding it later a
--     decoder branch rather than a flag day.
--   • Per-recipient redaction. Settled Session 243: ROSTER broadcasts the
--     payload AS-IS, because the website already shows the whole team the same
--     standings. There is no two-tier payload and no filtering step. The
--     condition attached to that decision — officer-authored adjustment notes
--     must never be in the tool — is met STRUCTURALLY: the export reads
--     epgp_standings and never touches epgp_ledger, so the notes were never in
--     reach. An addon cannot enforce this client-side anyway; SavedVariables
--     are a text file.

local ADDON_NAME, ns = ...

local Comms = {}
ns.Comms = Comms

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

--- Bumped when the ENVELOPE or any body format changes incompatibly. Checked on
--- every single message: silent protocol drift between two clients in one raid
--- is the worst failure this system has, because both sides look like they are
--- working.
Comms.PROTOCOL = 1

--- ⚠️ THE TWO DESIGN DOCS DISAGREE and this is the one that governs.
--- HoD_LootAddon_Experience.md §8 is the "Names — SETTLED" table and says
--- HoDLootAdvisor (14 chars, inside Blizzard's 16-char limit, and matching the
--- folder / SavedVariables / global-table convention every other name follows).
--- HoD_LootAddon_Data_Contract.md §4.1 says "HoDLoot", written earlier and in
--- passing while making a point about the length limit. Flagged for Jason.
Comms.PREFIX = "HoDLootAdvisor"

-- Blizzard rejects an addon message whose body exceeds 255 bytes. The envelope
-- header eats into that, so the usable chunk size is computed per message from
-- the header this message will actually carry — never a hardcoded guess that
-- goes stale the moment a type name gets longer.
local MESSAGE_LIMIT = 255
local SAFETY_MARGIN = 8

-- Outbound pacing. The client throttles addon messages and DROPS the excess; a
-- 12 KB roster payload is ~60 chunks, so firing them in one frame loses most of
-- them with nothing raised. Sending is therefore queued and paced, and the
-- interval BACKS OFF when the client actually says it is throttling us rather
-- than being tuned to a number somebody guessed.
local BURST         = 3      -- messages per drain
local BASE_INTERVAL = 0.15   -- seconds between drains when nothing is throttling
local MAX_INTERVAL  = 2.0

-- A partial message that never completes must not sit in memory forever, and a
-- buffer left over from a disconnect must not merge into the next one.
local BUFFER_TTL = 60

-- HELLO is announced on load and whenever the group changes. Both fire in
-- bursts (zoning into an instance produces several), so it is rate-limited.
local HELLO_INTERVAL = 30

-- WANT is rate-limited harder, because its ANSWER is expensive: a ~60-message
-- roster reply. GROUP_ROSTER_UPDATE fires on every join, leave and role change,
-- so an unlimited request is a client with no data flooding the raid.
local WANT_INTERVAL = 20

-- How long a self-test may capture our own messages before it is considered
-- abandoned. A belt to the timer's braces: if the timer never fires, an armed
-- test would swallow our own traffic forever.
local SELFTEST_TTL = 120

Comms.TYPES = {
  HELLO      = true,   -- any → all: presence + version
  WANT       = true,   -- any → runner: send me the current raid payload
  ROSTER     = true,   -- runner → all: Payload B, chunked
  GEAR       = true,   -- any → all: sender's own equipped state
  DROPS      = true,   -- runner → all: the computed ranking for one item
  -- Reserved. Present so the version does not have to move when they land.
  TGT        = false,  -- a raider's targeted items (Experience §9.1)
  BID_OPEN   = false,
  BID_CAST   = false,
  BID_CLOSE  = false,
  BID_RESULT = false,
}

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

--- Who else is running the addon: normalized name -> { version, at }.
--- This is the answer to a question the runner otherwise has no way to ask —
--- how many people are running it tonight.
Comms.peers = {}

--- Reassembly, keyed by sender|type|channel|total. See the note on that key
--- where messages are received.
local buffers = {}

--- Self-reported gear (provenance tier 1): name -> { slot -> {ilvl,track,ids,at} }.
--- Deliberately NOT persisted. Gear self-reports are only meaningful for the
--- session they were made in, and a stale one restored from SavedVariables
--- would outrank the fresh site snapshot while looking more authoritative than
--- it is — exactly the provenance inversion the three-tier rule exists to stop.
Comms.gear = {}

--- In-night corrections (provenance tier 3): name -> { slot -> {ilvl,track,itemID,at} }.
--- Also deliberately not persisted, for the same reason and one more: a
--- correction is scoped to tonight's run.
Comms.corrections = {}

--- Authoritative rankings from the runner: itemID -> { rows, at }.
Comms.rankings = {}

--- What installers say about THEMSELVES: name -> { class, spec, heroTree, at }.
--- The most trustworthy identity there is — it comes off their own client — and
--- the only source at all for someone the raid-night export has never heard of.
Comms.identity = {}

--- Version mismatches already reported, so a drifting client warns ONCE rather
--- than on every chunk of a 60-chunk payload.
local warnedVersion = {}

local queue, draining, interval = {}, false, BASE_INTERVAL
local lastHello, lastWant = 0, 0

--- Everything this file cannot verify about itself. A comms layer fails
--- invisibly by design — a dropped chunk looks exactly like a quiet raid — so
--- the counters are the only way to tell "nobody sent anything" from "nothing
--- arrived", and /la comms reports them without a reload.
Comms.stats = {
  sent = 0, queued = 0, throttled = 0, requeued = 0, failed = 0,
  received = 0, dropped = 0, assembled = 0, evicted = 0,
}

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

local function normalize(name)
  if type(name) ~= "string" or name == "" then return nil end
  -- CHAT_MSG_ADDON reports a cross-realm sender as "Name-Realm". The raid
  -- payload's roster is indexed by bare lowercased name, so this has to match
  -- that shape or a self-report from a cross-realm raider silently attaches to
  -- nobody. Same-name-different-realm would collide; that is the same
  -- assumption the payload index already makes, not a new one.
  local short = name:match("^([^%-]+)") or name
  return short:lower()
end
Comms.Normalize = normalize

function Comms.PlayerName()
  local n = UnitName and UnitName("player")
  return n
end

--- Is this message one of ours coming back? The client delivers your own addon
--- messages to you, so without this the runner would re-decode its own roster
--- broadcast and every HELLO would count the sender as a peer of themselves.
function Comms.IsSelf(sender)
  local me = Comms.PlayerName()
  if not me then return false end
  return normalize(sender) == normalize(me)
end

-- ---------------------------------------------------------------------------
-- Channel
-- ---------------------------------------------------------------------------

--- Which addon channel to broadcast on, or nil when there is nobody to talk to.
---
--- INSTANCE_CHAT IS NOT OPTIONAL. In an LFG/LFR group the RAID and PARTY
--- channels are not the group's channel, and a message sent to them goes
--- nowhere — with no error, which is how this breaks silently in exactly the
--- content most available for testing.
--- ⚠️ INSTRUMENTED, because a live LFR printed "You are not in a raid group"
--- — the client's own refusal, which is what it says when RAID is used for a
--- group whose channel is INSTANCE_CHAT. Whether that came from here or from
--- somewhere else is NOT yet established, and guessing at it twice is how
--- Session 245 lost an evening. So every input is recorded and /la comms
--- reports them; the next instanced group answers it from evidence.
---
--- Comms.channelWhy holds the raw values behind the last decision.
function Comms.Channel()
  local why = {}
  Comms.channelWhy = why

  why.enumCategory = Enum and Enum.PartyCategory and Enum.PartyCategory.Instance
  why.globalCategory = _G.LE_PARTY_CATEGORY_INSTANCE
  local instanceCategory = why.enumCategory or why.globalCategory
  why.category = instanceCategory

  if instanceCategory and IsInGroup then
    local ok, inInstanceGroup = pcall(IsInGroup, instanceCategory)
    why.instanceCall, why.instanceGroup = ok, inInstanceGroup
    if ok and inInstanceGroup then
      why.chose = "INSTANCE_CHAT"
      return "INSTANCE_CHAT"
    end
  end

  why.inRaid = IsInRaid and IsInRaid() or false
  why.inGroup = IsInGroup and IsInGroup() or false

  if why.inRaid then why.chose = "RAID" end
  if not why.chose and why.inGroup then why.chose = "PARTY" end

  -- Logged ON CHANGE only. The channel is consulted on every send, so logging
  -- each call would bury a raid night under itself — but the MOMENT it changes
  -- is exactly what a post-mortem needs, and "You are not in a raid group"
  -- during an LFR is a question about this decision and nothing else.
  if why.chose ~= Comms.loggedChannel then
    Comms.loggedChannel = why.chose
    if ns.Diagnostics then ns.Diagnostics.Note("commsChannel", why) end
  end

  return why.chose
end

-- ---------------------------------------------------------------------------
-- The envelope:  v|type|seq|total|payload
-- ---------------------------------------------------------------------------
--
-- ⚠️ THE PAYLOAD IS THE LAST FIELD ON PURPOSE. It is captured with (.*), so a
-- pipe INSIDE a payload cannot break parsing — which matters because WoW item
-- links are made of pipes and one will eventually end up in a body. Bodies
-- still use their own separators (";" between records, "," between fields) and
-- never a pipe, so the two levels cannot be confused.

local function header(msgType, seq, total)
  return ("%d|%s|%d|%d|"):format(Comms.PROTOCOL, msgType, seq, total)
end

function Comms.Encode(msgType, seq, total, body)
  return header(msgType, seq, total) .. (body or "")
end

--- Returns protocol, type, seq, total, body — or nil plus a reason.
function Comms.Decode(text)
  if type(text) ~= "string" then return nil, "not a string" end
  local v, msgType, seq, total, body =
    text:match("^(%d+)|([%u_]+)|(%d+)|(%d+)|(.*)$")
  if not v then return nil, "malformed envelope" end

  v, seq, total = tonumber(v), tonumber(seq), tonumber(total)

  -- ⚠️ RANGE, NOT TRUTHINESS. Zero is truthy in Lua, so `if seq then` accepts a
  -- seq of 0 and a total of 0 — the exact trap that cost Session 243 an entire
  -- login's worth of unresolved specs. A 0-of-0 message would allocate a buffer
  -- that can never complete.
  if not (seq and total and seq >= 1 and total >= 1 and seq <= total) then
    return nil, "chunk numbering out of range"
  end

  return v, msgType, seq, total, body
end

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------

--- Did SendAddonMessage succeed?
---
--- ⚠️ THE SUCCESS VALUE IS ZERO. Enum.SendAddonMessageResult.Success is 0, and
--- zero is truthy in Lua, so `if C_ChatInfo.SendAddonMessage(...) then` reports
--- success for EVERY outcome including a throttle. Older clients returned a
--- boolean and some return nothing at all, so all three shapes are handled
--- explicitly and none of them by truthiness.
local function sendResult(result)
  if result == nil then return true, false end         -- API returned nothing
  if result == true then return true, false end
  if result == false then return false, false end
  if type(result) == "number" then
    local E = Enum and Enum.SendAddonMessageResult
    local success   = (E and E.Success) or 0
    local throttled = E and E.AddonMessageThrottle
    if result == success then return true, false end
    if throttled and result == throttled then return false, true end
    return false, false
  end
  return true, false
end
Comms.SendResult = sendResult

local function rawSend(msg)
  local fn = C_ChatInfo and C_ChatInfo.SendAddonMessage
  if not fn then return false, false end
  local ok, result = pcall(fn, Comms.PREFIX, msg.text, msg.channel, msg.target)
  if not ok then return false, false end
  return sendResult(result)
end

local function drain()
  local sentThisPass, hitThrottle = 0, false

  for _ = 1, BURST do
    local msg = queue[1]
    if not msg then break end

    local ok, throttled = rawSend(msg)
    if ok then
      table.remove(queue, 1)
      Comms.stats.sent = Comms.stats.sent + 1
      sentThisPass = sentThisPass + 1
    elseif throttled then
      -- LEFT AT THE FRONT so ordering is preserved. Chunks arriving out of
      -- order would still reassemble (they are indexed by seq), but a dropped
      -- one never arrives at all, which is the failure this queue exists for.
      Comms.stats.throttled = Comms.stats.throttled + 1
      Comms.stats.requeued = Comms.stats.requeued + 1
      hitThrottle = true
      break
    else
      -- A hard refusal (not in a group any more, invalid channel). Retrying
      -- cannot help and would spin, so it is dropped and counted — but WHICH
      -- channel was refused is the whole diagnosis, and a bare counter cannot
      -- say. "You are not in a raid group" is the client refusing RAID for a
      -- group whose channel is INSTANCE_CHAT, and that is invisible from a
      -- number.
      Comms.lastFailure = { channel = msg.channel, target = msg.target, at = time() }
      if ns.Diagnostics then
        ns.Diagnostics.Note("commsSendFailed", {
          channel = msg.channel, why = Comms.channelWhy,
        })
      end
      table.remove(queue, 1)
      Comms.stats.failed = Comms.stats.failed + 1
    end
  end

  if hitThrottle then
    interval = math.min(interval * 2, MAX_INTERVAL)
  elseif sentThisPass > 0 then
    interval = math.max(BASE_INTERVAL, interval * 0.9)
  end

  if queue[1] then
    C_Timer.After(interval, drain)
  else
    draining = false
  end
end

--- Exposed so the harness can drive the queue deterministically, and so
--- /la comms can flush by hand if a raid night ever needs it.
function Comms.Drain() drain() end

local function enqueue(text, channel, target)
  queue[#queue + 1] = { text = text, channel = channel, target = target }
  Comms.stats.queued = Comms.stats.queued + 1
  if not draining then
    draining = true
    C_Timer.After(0, drain)
  end
end

--- How many BYTES of body fit in one message of this type.
---
--- #body is BYTES in Lua, which is what the client counts. A raider named
--- Vörnix costs 7 bytes and 6 characters; measuring in characters is how a
--- roster full of accented names overflows a limit that passed every ASCII
--- test. Same trap as the JS/Lua length rule in the Payload B format rules.
---
--- Budgeted against the WORST-CASE header — the one carrying a four-digit
--- sequence number — because the chunk size is fixed for the whole message
--- while the header grows as the count climbs. Sized against a one-digit header
--- instead, a sixty-chunk message is fine and a twelve-hundred-chunk one
--- overflows on its late chunks only.
---
--- Split out and exposed for ONE reason: the safety margin is currently wide
--- enough to absorb that difference, so the bug is latent rather than live and
--- no end-to-end check can see it. Testing the arithmetic directly is the only
--- honest way to pin it — a test that passes with the fix reverted is not a test.
function Comms.ChunkBytes(msgType)
  return (MESSAGE_LIMIT - SAFETY_MARGIN) - #header(msgType, 9999, 9999)
end

Comms.MESSAGE_LIMIT = MESSAGE_LIMIT
Comms.SAFETY_MARGIN = SAFETY_MARGIN
Comms.HeaderFor = header

--- Split a body across as many chunks as it needs and queue them all.
--- Returns the chunk count, or nil plus a reason.
---
--- The chunk size is derived from the header this message will really carry,
--- using the WORST-CASE sequence number, so the last chunk of a 60-chunk
--- message cannot be the one that overflows.
function Comms.Send(msgType, body, channel, target)
  if Comms.TYPES[msgType] == nil then
    return nil, "unknown message type: " .. tostring(msgType)
  end
  if Comms.TYPES[msgType] == false then
    return nil, msgType .. " is reserved and not implemented"
  end

  channel = channel or Comms.Channel()
  if not channel then return nil, "not in a group" end
  if channel == "WHISPER" and (not target or target == "") then
    return nil, "a direct message needs a target"
  end

  body = body or ""

  local chunkBytes = Comms.ChunkBytes(msgType)
  if chunkBytes < 1 then return nil, "envelope leaves no room for a body" end

  local total = math.max(1, math.ceil(#body / chunkBytes))
  for seq = 1, total do
    local from = (seq - 1) * chunkBytes + 1
    enqueue(Comms.Encode(msgType, seq, total, body:sub(from, from + chunkBytes - 1)),
      channel, target)
  end

  return total
end

-- ---------------------------------------------------------------------------
-- Receiving
-- ---------------------------------------------------------------------------

local function evictStale(now)
  for key, buf in pairs(buffers) do
    if now - buf.at > BUFFER_TTL then
      buffers[key] = nil
      Comms.stats.evicted = Comms.stats.evicted + 1
    end
  end
end

--- Reassembly key.
---
--- ⚠️ CHANNEL IS PART OF IT, and that is not tidiness. The runner answers a
--- late joiner DIRECTLY while possibly broadcasting the same ROSTER to the
--- raid; from the receiver's side both are "ROSTER from the runner", and a key
--- of sender+type alone would interleave two different messages into one
--- corrupt buffer that still decodes to something. `total` is in the key for
--- the same reason — a re-send of a different size is a different message.
local function bufferKey(sender, msgType, channel, total)
  return table.concat({ sender or "?", msgType, channel or "?", total }, "\1")
end

--- Feed one raw addon message in. Returns the completed body when this message
--- finished a payload, otherwise nil plus a reason.
function Comms.Receive(text, channel, sender)
  Comms.stats.received = Comms.stats.received + 1

  local v, msgType, seq, total, body = Comms.Decode(text)
  if not v then
    Comms.stats.dropped = Comms.stats.dropped + 1
    return nil, msgType  -- the decode reason
  end

  if v ~= Comms.PROTOCOL then
    Comms.stats.dropped = Comms.stats.dropped + 1
    local who = normalize(sender) or "?"
    if not warnedVersion[who] then
      warnedVersion[who] = true
      -- LOUD, and once. A mismatch means two clients in one raid disagree about
      -- what the bytes mean, and the failure mode of ignoring it quietly is
      -- advice that looks right and is not.
      ns.Warn(("%s is running a different Loot Advisor protocol (v%d, this is v%d) — "):format(
        sender or "someone", v, Comms.PROTOCOL)
        .. "one of you needs to update. Ignoring their messages.")
    end
    return nil, "protocol mismatch"
  end

  if Comms.TYPES[msgType] == nil then
    Comms.stats.dropped = Comms.stats.dropped + 1
    return nil, "unknown type " .. tostring(msgType)
  end
  if Comms.TYPES[msgType] == false then
    -- A reserved type arriving means somebody is running a NEWER build that has
    -- implemented it. Not an error and not a warning — counted, so /la comms
    -- can say so, because "nothing happened" would be the only other symptom.
    Comms.stats.dropped = Comms.stats.dropped + 1
    return nil, msgType .. " is reserved in this build"
  end

  local now = time()
  evictStale(now)

  if total == 1 then
    Comms.stats.assembled = Comms.stats.assembled + 1
    return body, msgType
  end

  local key = bufferKey(sender, msgType, channel, total)
  local buf = buffers[key]

  -- A RE-SENT seq 1 restarts the buffer, because the usual cause of a stalled
  -- half-buffer is the sender having given up and started again — and merging
  -- the two attempts produces a payload that still decodes, into something
  -- wrong. But "restart whenever seq 1 arrives" is the wrong rule: chunks are
  -- indexed by seq precisely so arrival ORDER cannot matter, and a seq 1 that
  -- lands last would then throw away everything before it. The distinguishing
  -- fact is whether we ALREADY HAVE a seq 1 — a second one is a restart, a
  -- first one is just late.
  if not buf or (seq == 1 and buf.parts[1] ~= nil) then
    buf = { parts = {}, have = 0, total = total, at = now }
    buffers[key] = buf
  end

  if buf.parts[seq] == nil then
    buf.parts[seq] = body
    buf.have = buf.have + 1
  end
  buf.at = now

  if buf.have < total then return nil, "incomplete" end

  local ordered = {}
  for i = 1, total do
    -- Built by APPENDING, never as a table literal: a literal holding a nil
    -- truncates, and ipairs over it would silently walk a prefix of the message.
    if buf.parts[i] == nil then
      buffers[key] = nil
      Comms.stats.dropped = Comms.stats.dropped + 1
      return nil, "reassembly hole"
    end
    ordered[#ordered + 1] = buf.parts[i]
  end
  buffers[key] = nil
  Comms.stats.assembled = Comms.stats.assembled + 1
  return table.concat(ordered), msgType
end

-- ---------------------------------------------------------------------------
-- Body formats
-- ---------------------------------------------------------------------------
--
-- All of them are flat text with ";" between records and "," between fields.
-- No pipes, ever — the envelope owns that character.

local function escapeField(s)
  -- Defensive rather than expected: nothing we build should contain a
  -- separator, but an item name we did not author eventually will.
  return (tostring(s):gsub("[;,|]", " "))
end
Comms.EscapeField = escapeField

--- GEAR body: one record per slot, naming the slot.
---   HEAD,305,Hero;TRINKET,321,Myth,270160+270164;...
---
--- ⚠️ SELF-DESCRIBING, never indexed against a slot order held in Lua. The raid
--- payload carries its OWN slot order for exactly this reason (Payload B format
--- rule (d)): a hardcoded order on both sides shifts every raider's gear by one
--- the moment a slot is inserted, and nothing errors. A GEAR message is read by
--- clients that may be running a different build, so it has to name its slots.
function Comms.EncodeGear()
  local out = {}
  for slot in pairs(ns.SLOT_INV) do out[#out + 1] = slot end
  table.sort(out)  -- stable ordering makes the message diffable in a log

  -- ⚠️ IDENTITY RIDES ALONG, and it is what makes an ad-hoc raider possible.
  -- The first version assumed the payload already knew who the sender was —
  -- true for the raid team, false for an ALT, a trial or a pug, who were
  -- previously invisible: not ranked, not listed, not mentioned. Their own
  -- client knows their class, spec and hero tree exactly, so an unknown sender
  -- can be added as a full roster entry rather than dropped.
  --
  -- The record is prefixed "@" so it cannot be mistaken for a slot: slot names
  -- are a fixed set and none of them start with one.
  local char = ns.ResolveCharacter()
  local records = {
    ("@,%s,%s,%s"):format(
      escapeField(char.className or ""), escapeField(char.specName or ""),
      escapeField(char.heroTree or "")),
  }
  for _, slot in ipairs(out) do
    local state = ns.EquippedSlotState(slot)
    -- ⚠️ GUARDED ON THE ITEM LEVEL, NOT ON `empty`. A slot can hold an item
    -- whose level has not resolved yet — item data arrives asynchronously, so a
    -- read taken seconds after a login answers 0 — and `empty` is false for it.
    -- Reporting "CHEST at ilvl 0" would then OVERRIDE a perfectly good site
    -- snapshot with nothing, which is worse than staying quiet: the whole point
    -- of tier 1 is that it is more accurate than the snapshot, not less.
    if state and (state.ilvl or 0) > 0 then
      local fields = { slot, tostring(state.ilvl or 0), state.track or "" }
      local ids = Comms.EquippedIds(slot)
      if #ids > 0 then fields[#fields + 1] = table.concat(ids, "+") end
      records[#records + 1] = table.concat(fields, ",")
    end
  end
  return table.concat(records, ";")
end

--- The item ids equipped in a slot. Only the two-socket slots can produce more
--- than one, and they are the only slots where "do you already own a copy" can
--- be asked at all.
function Comms.EquippedIds(slot)
  local ids = {}
  local invSlots = ns.SLOT_INV[slot]
  if not invSlots then return ids end
  for _, inv in ipairs(invSlots) do
    local link = GetInventoryItemLink and GetInventoryItemLink("player", inv)
    local parsed = link and ns.ParseItemLink(link)
    if parsed and parsed.itemID then ids[#ids + 1] = parsed.itemID end
  end
  return ids
end

--- Returns slots, identity. Identity is nil for a message from an older build,
--- which is exactly the fallback the roster needs anyway.
function Comms.DecodeGear(body)
  local slots, identity = {}, nil
  for record in tostring(body or ""):gmatch("[^;]+") do
    local fields = {}
    for field in (record .. ","):gmatch("([^,]*),") do fields[#fields + 1] = field end
    local slot, ilvl, track, ids = fields[1], tonumber(fields[2]), fields[3], fields[4]

    if slot == "@" then
      identity = {
        class    = (fields[2] ~= "" and fields[2]) or nil,
        spec     = (fields[3] ~= "" and fields[3]) or nil,
        heroTree = (fields[4] ~= "" and fields[4]) or nil,
      }
    elseif slot and ns.SLOT_INV[slot] and ilvl and ilvl > 0 then
      local idList
      if ids and ids ~= "" then
        idList = {}
        for id in ids:gmatch("[^%+]+") do
          local n = tonumber(id)
          if n then idList[#idList + 1] = n end
        end
      end
      slots[slot] = {
        ilvl  = ilvl,
        track = (track ~= "" and track) or nil,
        ids   = idList,
      }
    end
  end
  return slots, identity
end

--- DROPS body: the runner's computed ranking for one item.
---   <itemID>;<name>,<badge>,<gap>,<ilvlDelta>,<pr>;...
---
--- WHY THE RUNNER COMPUTES AND EVERYONE DISPLAYS (Data Contract §4): with a
--- partial install each client hears a different subset of GEAR self-reports,
--- so scoring independently produces slightly different orderings depending on
--- who you happened to hear from. One client computes; the result is small.
function Comms.EncodeDrops(itemID, rows)
  local parts = { tostring(itemID) }
  for _, row in ipairs(rows or {}) do
    parts[#parts + 1] = table.concat({
      escapeField(row.name or "?"),
      escapeField((row.result and row.result.badge) or ""),
      tostring(row.gap or ""),
      tostring((row.result and row.result.ilvl_delta) or ""),
      tostring(row.pr or ""),
    }, ",")
  end
  return table.concat(parts, ";")
end

function Comms.DecodeDrops(body)
  local records = {}
  for record in tostring(body or ""):gmatch("[^;]+") do
    records[#records + 1] = record
  end
  local itemID = tonumber(records[1])
  if not itemID then return nil, "no item id" end

  local rows = {}
  for i = 2, #records do
    local fields = {}
    for field in (records[i] .. ","):gmatch("([^,]*),") do fields[#fields + 1] = field end
    rows[#rows + 1] = {
      name  = fields[1],
      badge = (fields[2] ~= "" and fields[2]) or nil,
      gap   = tonumber(fields[3]),
      delta = tonumber(fields[4]),
      pr    = tonumber(fields[5]),
    }
  end
  return itemID, rows
end

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

local handlers = {}

handlers.HELLO = function(body, sender)
  local who = normalize(sender)
  if not who then return end
  local known = Comms.peers[who] ~= nil
  Comms.peers[who] = { version = body ~= "" and body or "?", at = time() }
  if not known and ns.Diagnostics then
    ns.Diagnostics.Note("commsPeer", { who = who, version = body })
  end
end

handlers.WANT = function(body, sender)
  -- ONLY THE RUNNER ANSWERS. If every client holding a payload replied, one
  -- late joiner would pull a full roster broadcast out of everyone at once.
  -- "Runner" means whoever PASTED the payload, which is also exactly who the
  -- Experience doc gives the Runner tab to.
  if not Comms.IsRunner() then return end

  local raw = Comms.CurrentRaw()
  if not raw then return end

  -- They said what they already have. Sending a payload no newer than theirs is
  -- pure noise on a channel that is throttled.
  local theirs = tonumber(body) or 0
  local data = ns.Payload.Current()
  local ours = (data and data.stamp) or 0
  if theirs > 0 and ours > 0 and theirs >= ours then return end

  -- ADDRESSED TO THEM ALONE, not re-broadcast (Data Contract §4.2). One person
  -- reloading must not cost the whole raid another 60 messages.
  --
  -- ⚠️ "WHISPER" HERE IS A ROUTING LABEL, NOT A CHAT WHISPER. SendAddonMessage
  -- reuses the chat system's address names, but addon messages travel on a
  -- separate hidden channel: they raise CHAT_MSG_ADDON, never
  -- CHAT_MSG_WHISPER. Nothing reaches a chat frame, no whisper window opens,
  -- no sound plays, and nobody without this addon can observe it at all. All
  -- the label does is address one player instead of the group.
  local chunks, err = Comms.Send("ROSTER", raw, "WHISPER", sender)
  if chunks then
    ns.Print(("sent tonight's raid data to %s."):format(sender or "?"))
  elseif ns.Diagnostics then
    ns.Diagnostics.Note("commsWantFailed", { sender = sender, err = err })
  end
end

handlers.ROSTER = function(body, sender)
  local data, err = ns.Payload.Decode(body)
  if not data then
    ns.Warn(("raid data from %s could not be read: %s"):format(tostring(sender), tostring(err)))
    if ns.Diagnostics then
      ns.Diagnostics.Note("commsRosterFailed", { sender = sender, err = err, bytes = #body })
    end
    return
  end

  -- Receiving a payload does NOT make you the runner. That distinction is what
  -- keeps a WANT from being answered by twenty people.
  ns.Payload.Store(data, body, sender)
  Comms.SetRunner(false)

  local s = ns.Payload.Summary()
  ns.Print(("received tonight's raid data from %s — %d raiders, gear synced %s."):format(
    tostring(sender), s and s.raiders or 0, ns.Payload.GearAgeText()))

  if ns.Diagnostics then
    ns.Diagnostics.Note("commsRoster", {
      sender = sender, bytes = #body, raiders = s and s.raiders or 0,
    })
  end

  if ns.Panel and ns.Panel.Refresh then pcall(ns.Panel.Refresh) end
end

handlers.GEAR = function(body, sender)
  local who = normalize(sender)
  if not who then return end
  local slots, identity = Comms.DecodeGear(body)
  local at = time()
  local store = Comms.gear[who] or {}
  for slot, state in pairs(slots) do
    state.at = at
    store[slot] = state
  end
  Comms.gear[who] = store

  -- Their own declaration of who they are. Kept apart from the gear so the
  -- roster can tell "they told us" from "we read it off them", which matters
  -- because only one of those two can be out of range or answer with a cold
  -- cache.
  if identity then
    Comms.identity[who] = {
      class = identity.class, spec = identity.spec,
      heroTree = identity.heroTree, at = at,
    }
  end

  if ns.Panel and ns.Panel.Refresh then pcall(ns.Panel.Refresh) end
end

handlers.DROPS = function(body, sender)
  -- Only the runner's ranking is authoritative, and taking one from anyone else
  -- would let any installer reorder everybody's panel.
  if not Comms.RunnerIs(sender) then return end
  local itemID, rows = Comms.DecodeDrops(body)
  if not itemID then return end
  Comms.rankings[itemID] = { rows = rows, at = time(), from = normalize(sender) }
  if ns.Panel and ns.Panel.Refresh then pcall(ns.Panel.Refresh) end
end

--- Drive one received message all the way through. Split out from the event
--- handler so the harness exercises the real path rather than a copy of it.
function Comms.Handle(text, channel, sender)
  -- WHILE A SELF-TEST IS ARMED, our own messages are CAPTURED instead of
  -- dropped — they are the one case we deliberately send to ourselves. Routed
  -- through the REAL Receive() rather than a shortcut, so the volume test
  -- exercises the actual chunking and reassembly rather than a copy of it.
  --
  -- The arm EXPIRES on a clock as well as on its timer. A timer that never
  -- fires (an error mid-callback, a disconnect) would otherwise leave the test
  -- armed forever and every later self-message would be swallowed silently —
  -- and a comms layer that quietly eats its own traffic is precisely the kind
  -- of invisible failure this file is otherwise built to avoid.
  local st = Comms.selfTest
  if st and Comms.IsSelf(sender) then
    if (time() - (st.sentAt or 0)) > SELFTEST_TTL then
      Comms.selfTest = nil
    else
      st.chunksIn = (st.chunksIn or 0) + 1
      local body = Comms.Receive(text, channel, sender)
      if body then
        st.heard = true
        st.body = body
        -- ⚠️ STAMPED WHEN IT ACTUALLY ARRIVES, not when the verdict prints.
        -- The first live run reported "30s" for a send that took about two,
        -- because the only clock being read was the verdict timer's own delay.
        -- A measurement that always returns its own timeout is not one.
        st.doneAt = GetTime and GetTime() or time()
      end
      return
    end
  end

  if Comms.IsSelf(sender) then return end

  local body, msgType = Comms.Receive(text, channel, sender)
  if body == nil then return end

  local fn = handlers[msgType]
  if fn then
    local ok, err = pcall(fn, body, sender)
    if not ok and ns.Diagnostics then
      ns.Diagnostics.Note("commsHandlerError", { type = msgType, err = tostring(err) })
    end
  end
end

-- ---------------------------------------------------------------------------
-- Runner identity
-- ---------------------------------------------------------------------------

--- The runner is whoever PASTED tonight's payload in, not whoever happens to
--- hold one. Persisted, so a /reload does not silently demote the person the
--- rest of the raid is asking for data.
function Comms.IsRunner()
  return (ns.db and ns.db.isRunner) == true and Comms.CurrentRaw() ~= nil
end

function Comms.SetRunner(isRunner)
  if ns.db then ns.db.isRunner = isRunner and true or false end
end

--- Did this message come from the person whose payload we are using?
--- Falls back to "any sender" ONLY when we have no idea who that is, so a raid
--- where nobody has announced still functions rather than ignoring everything.
function Comms.RunnerIs(sender)
  local from = ns.db and ns.db.raidFrom
  if not from then return true end
  return normalize(sender) == from
end

function Comms.CurrentRaw()
  return ns.db and ns.db.raidRaw or nil
end

--- "ok" · "none" · "legacy" — and the third one is the reason this exists.
---
--- ⚠️ A PAYLOAD PASTED BEFORE THIS BUILD HAS NO RAW COPY. Comms needs the
--- ENCODED string to re-send, and storing it alongside the decoded table only
--- started with comms; there is no way back, because reconstructing it would
--- need a Lua serializer this addon deliberately does not have.
---
--- WHY IT GETS ITS OWN STATE RATHER THAN FALLING IN WITH "none": the runner in
--- that position has a full roster on screen, is ranking the raid correctly,
--- and CANNOT broadcast or answer anyone — while every message about it says
--- "no raid data loaded", which is flatly untrue and sends them looking for the
--- wrong problem. A capture path that refuses input must say WHICH refusal it
--- made; the same rule that made the recorder count its declines by reason.
--- Self-heals on the next paste, which is the fix and needs saying out loud.
function Comms.RawStatus()
  if Comms.CurrentRaw() then return "ok" end
  if ns.Payload and ns.Payload.Current() then return "legacy" end
  return "none"
end

--- The sentence to show a runner who cannot send, or nil when they can.
function Comms.RawProblem()
  local state = Comms.RawStatus()
  if state == "ok" then return nil end
  if state == "legacy" then
    local s = ns.Payload.Summary()
    return ("tonight's %d-raider roster was loaded by an older build, which did not keep the "
      .. "copy comms needs to send it. Paste the export again with /la load and it is fixed.")
      :format(s and s.raiders or 0)
  end
  return "no raid data loaded — paste tonight's export with /la load first."
end

-- ---------------------------------------------------------------------------
-- Outbound actions
-- ---------------------------------------------------------------------------

--- Announce presence + version. Rate-limited: zoning fires several group
--- updates in a row and each one would otherwise cost a message.
function Comms.Announce(force)
  local now = time()
  if not force and (now - lastHello) < HELLO_INTERVAL then return nil, "too soon" end
  local chunks, err = Comms.Send("HELLO", ns.Version())
  if chunks then lastHello = now end
  return chunks, err
end

--- Ask the runner for tonight's payload. Sent when we have none, which is the
--- late-joiner and fresh-install case.
---
--- ⚠️ RATE-LIMITED, and this is not defensive tidiness. It is driven by
--- GROUP_ROSTER_UPDATE, which fires on every single join, leave, role change
--- and zone-in — dozens of times over a raid's first few minutes. Someone with
--- no payload would ask on every one of them, and each answer is a ~60-message
--- reply on a channel that is already throttled. The one client in the worst
--- position to be flooding the raid is the one that has nothing.
function Comms.RequestPayload(force)
  local now = time()
  if not force and (now - lastWant) < WANT_INTERVAL then return nil, "too soon" end
  local data = ns.Payload.Current()
  local chunks, err = Comms.Send("WANT", tostring((data and data.stamp) or 0))
  if chunks then lastWant = now end
  return chunks, err
end

--- Push the payload to everyone. Called once when the runner pastes it, and by
--- hand from /la comms push.
function Comms.BroadcastRoster()
  local raw = Comms.CurrentRaw()
  if not raw then return nil, Comms.RawProblem() end
  return Comms.Send("ROSTER", raw)
end

--- Tell everyone what we are actually wearing (provenance tier 1). This is the
--- personal reason to install the addon: your own row stops depending on how
--- stale the site snapshot was.
function Comms.BroadcastGear()
  local body = Comms.EncodeGear()
  if body == "" then return nil, "nothing equipped" end
  return Comms.Send("GEAR", body)
end

--- Push a computed ranking. Runner only — see EncodeDrops.
function Comms.BroadcastDrops(itemID, rows)
  if not Comms.IsRunner() then return nil, "not the runner" end
  if not rows or #rows == 0 then return nil, "nothing to send" end
  return Comms.Send("DROPS", Comms.EncodeDrops(itemID, rows))
end

--- The runner's ranking for an item, if one arrived and is still fresh.
--- Stale rankings are ignored rather than deleted: a kill's ranking stops being
--- the answer long before the table is worth tidying.
function Comms.AuthoritativeRanking(itemID, maxAge)
  local entry = Comms.rankings[itemID]
  if not entry then return nil end
  if (time() - entry.at) > (maxAge or 900) then return nil end
  return entry.rows, entry.from
end

-- ---------------------------------------------------------------------------
-- Provenance
-- ---------------------------------------------------------------------------

--- The best-known state for one raider's slot, and where it came from.
--- Returns nil when comms has nothing, which leaves the caller on the snapshot.
---
--- NEWEST WINS between a self-report and an in-night correction, rather than a
--- fixed precedence. A raider who wins a piece and equips it self-reports it a
--- moment later, and that report is exact where the correction is derived; a
--- raider who wins and does NOT equip it is still correctly held off future
--- lists for that slot. A fixed order gets one of those two cases wrong.
function Comms.BestKnown(name, slot)
  local who = normalize(name)
  if not who then return nil end

  local live = (Comms.gear[who] or {})[slot]
  local corr = (Comms.corrections[who] or {})[slot]

  if live and corr then
    if (corr.at or 0) > (live.at or 0) then return corr, "corrected" end
    return live, "live"
  end
  if live then return live, "live" end
  if corr then return corr, "corrected" end
  return nil
end

--- Note that someone won an item, so they stop appearing as a candidate for
--- that slot for the rest of the night (Experience §2.6, capability 7).
---
--- DERIVED LOCALLY, WITH NO MESSAGE. C_LootHistory is client-side data about
--- the whole encounter, so every client in the group can see the same win
--- without anyone broadcasting it — which is also why this works for raiders
--- who have not installed the addon: nothing depends on them self-reporting.
--- A message would only add a way for the two to disagree.
--- opts = { ilvl = <as actually dropped>, difficulty = "n"|"h"|"m" }
function Comms.NoteWin(winner, itemID, opts)
  opts = opts or {}
  local who = normalize(winner)
  if not (who and itemID) then return false, "need a winner and an item" end

  local data = ns.Data()
  local rec = data and (data.items or {})[itemID]
  if not rec then return false, "item not in our table" end

  local slot = ns.ItemSlot(rec)
  if not slot then return false, "item has no single slot" end  -- omni-token

  local key = opts.difficulty or ns.DifficultyKey()
  -- The OBSERVED item level beats the table's, when the recorder managed to
  -- resolve one: the link's bonus IDs say which version actually dropped, where
  -- the table only says what that difficulty usually yields. Falls back rather
  -- than requiring it, because item data arrives asynchronously and a win seen
  -- seconds after the kill routinely has no item level yet.
  local ilvl = opts.ilvl
  if not ilvl or ilvl <= 0 then ilvl = (rec.ilvl or {})[key] or 0 end
  if ilvl == 0 then return false, "no item level for this difficulty" end
  local track = ns.ResolveTrack(ilvl, ns.BonusIdsFor(key, rec.dropRank))

  local store = Comms.corrections[who] or {}
  local existing = store[slot]
  -- Never DOWNGRADE somebody on a correction. Winning a Normal piece does not
  -- undo the Heroic one they won an hour ago, and the payload holds the WORST
  -- competing piece per slot, so a lower value here would wrongly reopen them
  -- as a candidate.
  if existing and (existing.ilvl or 0) >= ilvl then return false, "already corrected higher" end

  store[slot] = { ilvl = ilvl, track = track, itemID = itemID, at = time() }
  Comms.corrections[who] = store

  if ns.Diagnostics then
    ns.Diagnostics.Note("commsWin", { who = who, itemID = itemID, slot = slot, ilvl = ilvl })
  end
  return true, slot
end

function Comms.ClearCorrections()
  Comms.corrections = {}
end

-- ---------------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------------

function Comms.PeerList()
  local list = {}
  for who, info in pairs(Comms.peers) do
    list[#list + 1] = { name = who, version = info.version, at = info.at }
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

function Comms.Status()
  local s = Comms.stats
  ns.Print(("comms v%d · prefix %s · %s"):format(
    Comms.PROTOCOL, Comms.PREFIX,
    Comms.registered and "registered" or "|cffff4444prefix NOT registered|r"))

  local channel = Comms.Channel()
  ns.Line(("Channel: %s%s"):format(
    channel or "|cff888899none — not in a group|r",
    Comms.IsRunner() and "  |cffF3C56B(you are the runner)|r" or ""))

  -- Surfaced HERE above everything else, because it is the state in which every
  -- other line looks healthy: a full roster, correct rankings, and no ability
  -- to send any of it to anyone.
  if Comms.RawStatus() == "legacy" then
    ns.Warn(Comms.RawProblem())
  end

  local peers = Comms.PeerList()
  if #peers == 0 then
    ns.Line("Running it: |cff888899nobody else has announced|r")
  else
    local names = {}
    for _, p in ipairs(peers) do names[#names + 1] = p.name .. " (" .. tostring(p.version) .. ")" end
    ns.Line(("Running it: %d — %s"):format(#peers, table.concat(names, ", ")))
  end

  -- SENT AND RECEIVED SEPARATELY, because "nobody sent anything" and "nothing
  -- arrived" are the two explanations for a quiet raid and they need completely
  -- different fixes. A silent comms layer is indistinguishable from a broken
  -- one otherwise — the same reasoning that made the recorder count its
  -- declines.
  ns.Line(("Sent: %d of %d queued · %d throttled · %d failed · %d still queued"):format(
    s.sent, s.queued, s.throttled, s.failed, #queue))

  if Comms.lastFailure then
    ns.Warn(("the client refused a message addressed to %s."):format(
      tostring(Comms.lastFailure.channel)))
    local w = Comms.channelWhy or {}
    ns.Line(("     Channel picked: %s · instance-group: %s · raid: %s · party: %s · category id: %s")
      :format(tostring(w.chose), tostring(w.instanceGroup), tostring(w.inRaid),
        tostring(w.inGroup), tostring(w.category)))
    ns.Line("     |cff888899An LFG/LFR group's channel is INSTANCE_CHAT; RAID is refused there.|r")
  end
  ns.Line(("Received: %d messages · %d payloads assembled · %d dropped · %d buffers evicted"):format(
    s.received, s.assembled, s.dropped, s.evicted))

  local corrected = 0
  for _ in pairs(Comms.corrections) do corrected = corrected + 1 end

  -- WHO IS NOT REPORTING, BY NAME (Experience §3, "the panel also shows a not-
  -- reporting list so the gap is visible"). They are still ranked, from the
  -- snapshot, and never silently dropped — but a runner deciding how much to
  -- trust a close call needs to know whose row is live and whose is not.
  local gear = ns.GearReportingSummary()
  if not gear then
    local live = 0
    for _ in pairs(Comms.gear) do live = live + 1 end
    ns.Line(("Gear: %d reporting live · %d corrected by a win tonight"):format(live, corrected))
    return
  end

  ns.Line(("Gear: %d of %d reporting live · %d corrected by a win tonight"):format(
    gear.reporting, gear.total, corrected))

  -- SOLO, "nobody is reporting live gear" is trivially true — there is no
  -- channel for anyone to report on — so naming seventeen people for it is
  -- telling the runner something that carries no information. The gap is worth
  -- showing only where it could have been closed.
  if #gear.missing > 0 and Comms.Channel() then
    -- Capped, and the remainder COUNTED rather than trimmed away — twenty-three
    -- names is a wall, and "and 18 more" is honest where simply stopping is not.
    local shown = {}
    for i = 1, math.min(5, #gear.missing) do shown[#shown + 1] = gear.missing[i] end
    local line = "     Not reporting: " .. table.concat(shown, ", ")
    if #gear.missing > #shown then
      line = line .. (" and %d more"):format(#gear.missing - #shown)
    end
    ns.Line(line .. "  |cff888899(scored from the site snapshot)|r")
  end
end

-- ---------------------------------------------------------------------------
-- The solo self-test
-- ---------------------------------------------------------------------------

--- Round-trip one message through the REAL client, alone, with no group.
---
--- WHY THIS EXISTS: everything else about comms can be proven headlessly — the
--- harness runs two clients in one Lua process and they hold a full
--- conversation. What NO stub can prove is the part that leaves the machine:
--- whether the prefix registration was actually accepted, what
--- SendAddonMessage really returns on this build, and whether CHAT_MSG_ADDON
--- fires at all. An addon message addressed to YOURSELF exercises exactly that
--- path with one account and no group — and, being an addon message, it is
--- invisible: no chat line, no whisper window, nothing a player would see.
---
--- ⚠️ IT REPORTS, IT DOES NOT ASSERT. Whether a self-addressed message is
--- delivered back is a claim
--- about Blizzard's server, and the whole point of this command is to find out
--- rather than to assume — so it prints the registration answer, the raw result
--- code the send returned, and whether the event came back. If a self-addressed
--- message turns out not to be delivered on 12.1, that shows up here as a named
--- negative instead of as a silent raid night.
--- mode "loop" (default) sends ONE message; mode "volume" sends the entire raid
--- payload — ~50 messages — and checks it comes back byte for byte.
---
--- ⚠️ VOLUME IS THE ONE THAT MATTERS NOW. The single message proved
--- registration, send and receive work on this client. What it CANNOT show is
--- the failure this whole queue exists for: the client throttles addon messages
--- and DROPS the excess, so a roster broadcast can lose chunks in the middle
--- with nothing raised anywhere. That needs volume, and volume was the reason
--- this was filed as needing a second client — until the loop test proved a
--- message addressed to yourself comes back, which means one account can send
--- itself the real thing.
---
--- WHAT IT MEASURES, none of which a stub can answer: how many messages the
--- client accepted, how many it throttled, how long the queue took to clear at
--- the current pacing, and whether the reassembled payload is IDENTICAL to what
--- went out. Byte-identical is the only pass — a payload that decodes but is
--- short is exactly the failure mode that would put a wrong roster in front of
--- the raid.
function Comms.SelfTest(mode)
  local me = Comms.PlayerName()
  if not me then
    ns.Warn("cannot self-test: the client did not answer UnitName(\"player\").")
    return
  end

  local fn = C_ChatInfo and C_ChatInfo.SendAddonMessage
  if not fn then
    ns.Warn("C_ChatInfo.SendAddonMessage does not exist on this client.")
    return
  end

  ns.Line(("Prefix %s: %s"):format(Comms.PREFIX,
    Comms.registered and "|cff20ba56registered|r"
      or "|cffff4444NOT registered — inbound messages are dropped by the client|r"))

  if mode == "volume" then
    local raw = Comms.CurrentRaw()
    if not raw then
      ns.Warn(Comms.RawProblem())
      return
    end

    local chunkBytes = Comms.ChunkBytes("ROSTER")
    local expected = math.ceil(#raw / chunkBytes)
    ns.Print(("comms volume test — sending the whole raid payload to yourself: "
      .. "%d bytes in about %d messages."):format(#raw, expected))
    ns.Line("This is the throttle test. Wait for the verdict.")

    Comms.selfTest = {
      mode = "volume", sentAt = time(), heard = false, expect = raw,
      -- GetTime is a high-resolution frame clock; time() is whole seconds, which
      -- cannot express a two-second send at all. Both are kept: sentAt drives the
      -- arm's expiry, startedAt measures the send.
      startedAt = GetTime and GetTime() or time(),
      statsAt = { sent = Comms.stats.sent, throttled = Comms.stats.throttled,
                  failed = Comms.stats.failed, dropped = Comms.stats.dropped },
    }

    -- THROUGH THE REAL QUEUE, deliberately — the queue and its backoff are the
    -- thing under test. Sending directly would prove nothing about either.
    local chunks, err = Comms.Send("ROSTER", raw, "WHISPER", me)
    if not chunks then
      ns.Warn("could not queue the payload: " .. tostring(err))
      Comms.selfTest = nil
      return
    end

    -- POLLED, not a fixed wait. The verdict arrives the moment the payload is
    -- whole, which for a normal roster is a couple of seconds; the 30-second
    -- figure is only the giving-up point, and making everyone sit through it
    -- on every run buries how fast this actually is.
    local deadline, tick = 30, 1
    local waited = 0
    local function verdict()
      local st = Comms.selfTest
      if not st then return end

      if not st.heard and waited < deadline then
        waited = waited + tick
        C_Timer.After(tick, verdict)
        return
      end

      local d = st.statsAt
      local sent      = Comms.stats.sent - d.sent
      local throttled = Comms.stats.throttled - d.throttled
      local failed    = Comms.stats.failed - d.failed
      local elapsed   = (st.doneAt and st.startedAt) and (st.doneAt - st.startedAt) or nil

      ns.Print(("volume test: %d sent · %d throttled · %d failed · %d arrived%s")
        :format(sent, throttled, failed, st.chunksIn or 0,
          elapsed and ("  ·  %.1fs"):format(elapsed) or ("  ·  gave up after %ds"):format(waited)))

      if st.heard and st.body == st.expect then
        ns.Line("|cff20ba56PASSED|r — the payload came back byte for byte. "
          .. "Chunking, pacing and reassembly all work against the live client.")
      elseif st.heard then
        -- Reassembled, but not what went out. Worse than not arriving at all,
        -- because a short roster still decodes into a plausible one.
        ns.Warn(("reassembled %d bytes but sent %d — the payload came back WRONG.")
          :format(#(st.body or ""), #st.expect))
      elseif sent < chunks then  -- luacheck: ignore
        ns.Warn(("the queue has not finished — %d of %d sent. Pacing is too slow, "
          .. "or the client is throttling hard."):format(sent, chunks))
      else
        ns.Warn(("all %d messages were accepted but the payload never reassembled — "
          .. "%d chunks arrived of %d."):format(sent, st.chunksIn or 0, chunks))
        ns.Line("That is the client silently dropping addon messages under load,")
        ns.Line("which is exactly what the send queue exists to prevent. The pacing")
        ns.Line("numbers need raising.")
      end

      if ns.Diagnostics then
        ns.Diagnostics.Note("commsVolumeTest", {
          bytes = #st.expect, chunks = chunks, sent = sent, throttled = throttled,
          failed = failed, arrived = st.chunksIn or 0,
          matched = (st.heard and st.body == st.expect) or false, seconds = elapsed,
        })
      end
      Comms.selfTest = nil
    end
    C_Timer.After(tick, verdict)
    return
  end

  ns.Print("comms self-test — sending one hidden addon message to yourself.")
  Comms.selfTest = { mode = "loop", sentAt = time(), heard = false }

  -- Sent DIRECTLY rather than through the queue: the queue is paced and this
  -- needs the raw return value, which is the one thing being measured.
  local text = Comms.Encode("HELLO", 1, 1, "selftest")
  local ok, result = pcall(fn, Comms.PREFIX, text, "WHISPER", me)
  local sent, throttled = sendResult(result)
  ns.Line(("Send: %s · returned %s%s"):format(
    ok and (sent and "|cff20ba56accepted|r" or "|cffff4444refused|r") or "|cffff4444errored|r",
    tostring(result),
    throttled and " (throttled)" or ""))

  if ns.Diagnostics then
    ns.Diagnostics.Note("commsSelfTest", {
      registered = Comms.registered, ok = ok, result = tostring(result),
    })
  end

  C_Timer.After(3, function()
    local st = Comms.selfTest
    if st and st.heard then
      ns.Print("|cff20ba56self-test passed|r — the message came back. "
        .. "Registration, send and receive all work on this client.")
      ns.Line("Next: |cffF3C56B/la comms volume|r sends the WHOLE payload to yourself,")
      ns.Line("which is the throttle test one message cannot be.")
    else
      ns.Warn("self-test: nothing came back within 3 seconds.")
      ns.Line("That means one of: the prefix is not registered, self-addressed addon")
      ns.Line("messages are not delivered on this build, or CHAT_MSG_ADDON is not firing.")
      ns.Line("It does NOT prove comms is broken in a group — test with a second")
      ns.Line("client before concluding that.")
    end
    Comms.selfTest = nil
  end)
end

function Comms.Command(sub, rest)
  sub = (sub or ""):lower()

  if sub == "loop" or sub == "selftest" then
    Comms.SelfTest("loop")
  elseif sub == "volume" then
    Comms.SelfTest("volume")
  elseif sub == "" or sub == "status" then
    Comms.Status()
  elseif sub == "hello" then
    local chunks, err = Comms.Announce(true)
    ns.Print(chunks and "announced." or ("could not announce: " .. tostring(err)))
  elseif sub == "push" then
    local chunks, err = Comms.BroadcastRoster()
    if chunks then
      ns.Print(("sending tonight's raid data to the group — %d messages."):format(chunks))
    else
      ns.Warn("could not send: " .. tostring(err))
    end
  elseif sub == "want" then
    -- Forced: a deliberate press is not the case the rate limit exists for.
    local chunks, err = Comms.RequestPayload(true)
    ns.Print(chunks and "asked the runner for tonight's data."
      or ("could not ask: " .. tostring(err)))
  elseif sub == "gear" then
    local chunks, err = Comms.BroadcastGear()
    ns.Print(chunks and "sent your equipped gear to the group."
      or ("could not send gear: " .. tostring(err)))
  elseif sub == "flush" then
    Comms.Drain()
    ns.Print(("%d messages still queued."):format(#queue))
  else
    ns.Warn("unknown: /la comms " .. sub)
    ns.Line("|cffF3C56B/la comms|r — status · hello · push · want · gear · flush")
  end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

Comms.registered = false

local frame

--- Called from Core's ADDON_LOADED, once the database exists.
function Comms.Start()
  if frame then return end

  local fn = C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix
  if fn then
    -- ⚠️ RECORDED, NOT ASSUMED. An unregistered prefix means every inbound
    -- message is silently dropped by the client before the addon ever sees it,
    -- which looks exactly like nobody else running the addon. Registration can
    -- fail (there is a global cap on prefixes), so the answer is stored and
    -- reported by /la comms rather than taken on faith.
    local ok, result = pcall(fn, Comms.PREFIX)
    Comms.registered = ok and (result ~= false)
    if ns.Diagnostics then
      ns.Diagnostics.Note("commsPrefix", {
        prefix = Comms.PREFIX, ok = ok, result = tostring(result),
      })
    end
  end

  frame = CreateFrame("Frame")
  frame:RegisterEvent("CHAT_MSG_ADDON")
  frame:RegisterEvent("GROUP_ROSTER_UPDATE")
  frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
  frame:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
      local prefix, text, channel, sender = ...
      if prefix == Comms.PREFIX then
        Comms.Handle(text, channel, sender)
      end
      return
    end

    if event == "GROUP_ROSTER_UPDATE" then
      if not Comms.Channel() then return end
      Comms.Announce()
      -- No payload and we are in a group: this is the late-joiner case.
      if not ns.Payload.Current() then Comms.RequestPayload() end
      return
    end

    if event == "PLAYER_EQUIPMENT_CHANGED" then
      -- Re-broadcast on a gear change, coalesced: swapping a full set fires this
      -- once per piece, and each one would otherwise cost a message on a
      -- throttled channel.
      if Comms.gearPending then return end
      Comms.gearPending = true
      C_Timer.After(3, function()
        Comms.gearPending = false
        if Comms.Channel() then Comms.BroadcastGear() end
      end)
    end
  end)
end
