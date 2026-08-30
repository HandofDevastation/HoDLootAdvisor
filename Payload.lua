-- Payload.lua — receiving the raid payload (Payload B)
--
-- The roster's gear and everyone's EPGP standing cannot be baked into the addon:
-- the repo is public, and that is guild data. Addons also cannot reach the
-- internet. So it arrives the only way it can — the runner exports it from the
-- website and pastes it in, once, at raid start.
--
-- Format:  LA1:<base64 of Lua source>
--
-- WHY LUA SOURCE, NOT JSON: WoW has no JSON parser, so JSON would cost ~150
-- lines of parser to read a format neither side speaks natively. The static
-- payload is already Lua source. Full reasoning, and the size measurements that
-- chose this encoding over compression, are in
-- app/lib/loot-addon/raid-payload.ts.
--
-- ⚠️ THE PASTED STRING IS UNTRUSTED AND IS EVALUATED IN AN EMPTY SANDBOX.
-- Evaluating pasted text is the whole mechanism here, so it is done with NO
-- environment at all: the chunk cannot see _G, cannot call a single WoW API, and
-- can only build a table. A malicious paste can at worst waste memory.

local ADDON_NAME, ns = ...

local Payload = {}
ns.Payload = Payload

Payload.PREFIX = "LA1"

-- ---------------------------------------------------------------------------
-- base64
-- ---------------------------------------------------------------------------
-- Arithmetic rather than bitwise on purpose: WoW's Lua is 5.1 (no native
-- operators, a `bit` library) while the standalone harness is 5.4+ (operators,
-- no `bit`). Arithmetic is the only form that runs unchanged in both, and this
-- code MUST run in the harness — that is where it gets tested.

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_LOOKUP = {}
for i = 1, #B64_CHARS do
  B64_LOOKUP[B64_CHARS:sub(i, i)] = i - 1
end

function Payload.DecodeBase64(data)
  if type(data) ~= "string" then return nil, "not a string" end
  -- Strip anything outside the alphabet: a paste can pick up whitespace and
  -- line breaks, and none of it is meaningful.
  data = data:gsub("[^A-Za-z0-9+/=]", "")
  if #data == 0 then return nil, "empty after cleaning" end

  local out = {}
  local i = 1
  local n = #data
  while i <= n do
    local c1 = B64_LOOKUP[data:sub(i, i)]
    local c2 = B64_LOOKUP[data:sub(i + 1, i + 1)]
    if not c1 or not c2 then break end
    local c3 = B64_LOOKUP[data:sub(i + 2, i + 2)]
    local c4 = B64_LOOKUP[data:sub(i + 3, i + 3)]

    out[#out + 1] = string.char(c1 * 4 + math.floor(c2 / 16))
    if c3 then
      out[#out + 1] = string.char((c2 % 16) * 16 + math.floor(c3 / 4))
      if c4 then
        out[#out + 1] = string.char((c3 % 4) * 64 + c4)
      end
    end
    i = i + 4
  end

  return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Sandboxed evaluation
-- ---------------------------------------------------------------------------

--- Compile `src` as an expression with NO environment.
--- setfenv is the 5.1 path (WoW); load(..., "t", {}) is the 5.2+ path (harness).
--- Both produce a chunk that cannot reach a single global.
local function sandboxedChunk(src)
  if setfenv then
    local chunk, err = loadstring("return " .. src, "HoDLootAdvisorPayload")
    if not chunk then return nil, err end
    setfenv(chunk, {})
    return chunk
  end
  return load("return " .. src, "HoDLootAdvisorPayload", "t", {})
end

-- ---------------------------------------------------------------------------
-- Decode + validate
-- ---------------------------------------------------------------------------

--- Returns payload, err. Never throws.
--- Validation is deliberately strict and LOUD: a payload that is subtly wrong
--- produces subtly wrong advice in front of the raid, which is worse than
--- refusing to load.
function Payload.Decode(text)
  if type(text) ~= "string" or text == "" then
    return nil, "nothing pasted"
  end

  text = text:gsub("^%s+", ""):gsub("%s+$", "")

  local prefix, body = text:match("^(%w+):(.*)$")
  if not prefix then
    return nil, "not a Loot Advisor export (no version prefix)"
  end
  if prefix ~= Payload.PREFIX then
    -- Version drift between the site and the addon is the failure mode most
    -- likely to produce confidently wrong output, so it is refused, not warned.
    return nil, ("this export is format '%s' but this addon reads '%s' — update the addon")
      :format(prefix, Payload.PREFIX)
  end

  local src, decodeErr = Payload.DecodeBase64(body)
  if not src then return nil, "could not decode: " .. tostring(decodeErr) end

  local chunk, compileErr = sandboxedChunk(src)
  if not chunk then
    return nil, "export is corrupt (truncated paste?): " .. tostring(compileErr)
  end

  local ok, data = pcall(chunk)
  if not ok or type(data) ~= "table" then
    return nil, "export did not evaluate to a table"
  end

  -- INTEGRITY: the payload states its own length, so a paste that arrived
  -- incomplete is caught here rather than decoding into a plausible roster that
  -- is quietly missing people. Truncation usually breaks the Lua syntax first,
  -- but not always — a cut landing between two roster entries can leave
  -- something that parses.
  if type(data.bytes) == "number" and #src ~= data.bytes then
    return nil, ("paste is incomplete — got %d of %d characters. Try copying again.")
      :format(#src, data.bytes)
  end

  if type(data.slots) ~= "table" or #data.slots == 0 then
    return nil, "export carries no slot order"
  end
  if type(data.tracks) ~= "table" or #data.tracks == 0 then
    return nil, "export carries no track order"
  end
  if type(data.roster) ~= "table" then
    return nil, "export carries no roster"
  end

  -- Each raider's gear is an ilvl/track pair per slot. A length mismatch means
  -- the two sides disagree about the slot list, which would silently shift every
  -- raider's gear by one slot and score everyone wrongly.
  local want = #data.slots * 2
  for i, r in ipairs(data.roster) do
    if type(r.g) ~= "table" or #r.g ~= want then
      return nil, ("raider %d (%s) has %d gear values, expected %d")
        :format(i, tostring(r.n), r.g and #r.g or 0, want)
    end
  end

  return data
end

-- ---------------------------------------------------------------------------
-- Storing + querying
-- ---------------------------------------------------------------------------

--- Persisted to SavedVariables so a /reload or a relog costs no round trip —
--- the runner pastes once per night, not once per UI error.
---
--- `raw` is the ENCODED string it arrived as, kept alongside the decoded table
--- so the runner can re-broadcast it and answer a late joiner's WANT without
--- re-serializing the roster (which would need a Lua serializer this addon
--- deliberately does not have). ~12 KB, next to a decoded table that is larger.
--- `from` is who sent it, so DROPS can tell the runner's ranking from anyone
--- else's — nil when it was pasted in locally.
--- ⚠️ REPAINTING THE PANEL IS PART OF STORING, not the caller's job to
--- remember. Every path that changes the payload changes what the panel should
--- show — the Runner tab appears and disappears with it — and doing it at the
--- call sites meant an import left the open panel showing the pre-import
--- world until the window was closed and reopened. There are four such paths
--- (import, comms receive, clear, unload) and patching them one at a time is
--- how three of them get it right and the fourth does not.
local function repaintPanel()
  if ns.Panel and ns.Panel.Refresh then pcall(ns.Panel.Refresh) end
end

function Payload.Store(data, raw, from)
  ns.db.raid = data
  ns.db.raidRaw = raw
  ns.db.raidFrom = from and ns.Comms and ns.Comms.Normalize(from) or nil
  Payload.BuildIndex()
  repaintPanel()
end

function Payload.Current()
  return ns.db and ns.db.raid or nil
end

function Payload.Clear()
  if ns.db then
    ns.db.raid = nil
    -- The raw string and the runner flag are part of the SAME fact. Leaving
    -- either behind would make Comms.IsRunner() answer yes with nothing to
    -- send, so the runner would keep silently ignoring everyone's WANT.
    ns.db.raidRaw = nil
    ns.db.raidFrom = nil
    ns.db.isRunner = false
  end
  Payload.slotIndex = nil
  Payload.byName = nil
  repaintPanel()
end

--- Slot name -> its position in the payload's OWN slot order, and character
--- name -> roster entry. Rebuilt on load rather than stored, so a stale index
--- can never outlive the payload it describes.
function Payload.BuildIndex()
  local data = Payload.Current()
  Payload.slotIndex, Payload.byName = nil, nil
  if not data then return end

  local slotIndex = {}
  for i, name in ipairs(data.slots) do slotIndex[name] = i end
  Payload.slotIndex = slotIndex

  local byName = {}
  for _, r in ipairs(data.roster) do
    if r.n then byName[r.n:lower()] = r end
  end
  Payload.byName = byName
end

--- One raider's equipped state for a loot slot: { ilvl, track, ids, source }.
--- Mirrors ns.EquippedSlotState for the local player, but reads the payload
--- instead of the game — the site already reduced each slot to the WORST
--- competing piece, so there is no per-slot logic to repeat here.
---
--- GEAR PROVENANCE IS THREE-TIER, BEST AVAILABLE WINS (Data Contract §3.2), and
--- `source` says which tier answered so the panel can show it:
---   "live"      — the raider's own client said so over comms. Exact.
---   "corrected" — they were seen winning something for this slot tonight.
---   "snapshot"  — the site export. Always present, possibly hours stale.
--- A raider is NEVER silently missing: with no comms at all every row falls
--- through to the snapshot, which is exactly how the addon behaved before comms
--- existed. That is the property that lets one installer be a working system.
function Payload.SlotState(raider, lootSlot)
  if not (raider and lootSlot) then return nil end

  -- ⚠️ THE SNAPSHOT IS OPTIONAL, AND THAT IS THE POINT (Session 256). This used
  -- to require a loaded export before it would answer anything, so with none
  -- loaded it returned nil for EVERY raider and the whole ranked list collapsed
  -- — which is every install outside this guild. The group scan and the inspect
  -- pass describe people perfectly well on their own; the export is one source
  -- among four, not the price of entry.
  local data = Payload.Current()
  local idx = Payload.slotIndex and Payload.slotIndex[lootSlot]

  -- An AD-HOC raider carries no `g` at all: the export has never heard of them,
  -- so there is no snapshot to fall back to. They resolve entirely from what we
  -- learned in game, and if that is nothing they are not ranked — they are
  -- listed as unresolved instead. Defaulting them to ilvl 0 would make every
  -- item a maximum upgrade and float a stranger to the top of every list.
  local ilvl, track = 0, nil
  local snapshot = false
  if raider.g and data and idx then
    snapshot = true
    ilvl = raider.g[(idx - 1) * 2 + 1] or 0
    local trackIdx = raider.g[(idx - 1) * 2 + 2] or 0
    track = trackIdx > 0 and data.tracks[trackIdx] or nil
  end
  local ids = raider.ids and raider.ids[lootSlot] or nil
  local source = "snapshot"

  -- FOUR TIERS NOW, resolved newest-first among the three live ones. An
  -- inspection is a full, exact read of what someone is wearing — as good as a
  -- self-report at the moment it was taken — so it competes on recency rather
  -- than sitting in a fixed rank below it. The tie-break when two readings are
  -- equally fresh goes to the self-report, because their own client cannot be
  -- out of range or answer with a cold cache.
  local better, tier = nil, nil
  if ns.Comms then better, tier = ns.Comms.BestKnown(raider.n, lootSlot) end

  local seen = ns.Roster and ns.Roster.GearFor(raider.n, lootSlot)
  if seen and (not better or (seen.at or 0) > (better.at or 0)) then
    better, tier = seen, "inspected"
  end
  if better then
    ilvl = better.ilvl or ilvl
    track = better.track or track
    -- A correction knows the ITEM someone won but not what else is in the slot,
    -- so it can only ADD to the ids the snapshot already listed. Replacing them
    -- would forget the trinket they were already wearing and wrongly reopen
    -- them as a candidate for a copy of it.
    if better.ids then
      ids = better.ids
    elseif better.itemID then
      local merged = {}
      for _, id in ipairs(ids or {}) do merged[#merged + 1] = id end
      merged[#merged + 1] = better.itemID
      ids = merged
    end
    source = tier
  end

  -- YOUR OWN EQUIPMENT IS ASKED FOR, NEVER REMEMBERED. Everyone else's best
  -- answer is a report or an inspection, each as old as the moment it was taken
  -- — so they compete on recency. Yours can be read from the client right now,
  -- so it wins outright rather than joining that race.
  --
  -- It is also what the PERSONAL column already scores against, and your own row
  -- in the ranked table sitting beside your own column showing a different item
  -- level is the disagreement this removes. Solo with no export there is nothing
  -- else at all: no snapshot, and no self-report, because a broadcast with no
  -- group to carry it never comes back.
  local selfRead = false
  if ns.Comms and ns.Comms.IsSelf(raider.n) and ns.EquippedSlotState then
    local mine = ns.EquippedSlotState(lootSlot)
    if mine then
      ilvl, track = mine.ilvl or 0, mine.track
      source, selfRead = "live", true
    end
  end

  -- Nothing from the export AND nothing learned in game. Returning a zeroed
  -- state here would read as "empty slot", which the scorer treats as anything
  -- being an upgrade.
  if not snapshot and not better and not selfRead then return nil end

  return {
    ilvl   = ilvl,
    track  = track,
    ids    = ids,
    empty  = ilvl == 0,
    source = source,
  }
end

--- The roster to actually rank: everyone in the export, plus anyone standing in
--- the instance the export has never heard of.
---
--- WHY THIS EXISTS. Payload B carries the ACTIVE RAID TEAM, deliberately not
--- tonight's signups, so a raider who did not RSVP still ranks. What it cannot
--- carry is someone who is not on the team at all — an ALT, a trial, a pug —
--- and those people were previously invisible in every surface. "A raider must
--- never be silently missing" did not hold for them.
---
--- AN AD-HOC ENTRY IS ONLY INCLUDED ONCE WE CAN DESCRIBE IT. Somebody we know
--- is present but know nothing about belongs in the UNRESOLVED list, not in a
--- ranking built on blanks. ns.Roster.Unresolved() is where they show up.
---
--- They carry no EPGP standing, because that only exists on the website. Their
--- priority column reads em-dash, which is the honest answer rather than a
--- fabricated one.
--- ⚠️ AND IT WORKS WITH NO EXPORT AT ALL (Session 256). It used to return an
--- empty list the moment no payload was loaded, which took the whole ranked
--- table with it — so an install outside this guild, and any pug or LFR night,
--- got the personal column and nothing else. Everything the group half needs is
--- independent of the site: who is here, what they are wearing, what spec they
--- are in, what they can use. The export supplies a fourth thing, EPGP priority,
--- and its absence is a missing COLUMN rather than a missing feature.
function Payload.EffectiveRoster()
  local data = Payload.Current()
  if not ns.Roster then return data and data.roster or {} end

  -- ⚠️ IN A GROUP, RANK ONLY THE PEOPLE IN IT (Jason, Session 253). The roster
  -- is the raid TEAM, not the people standing here — so an LFR showed twenty-two
  -- strangers alongside sixteen guild raiders who were at home, and "31 of 38
  -- raiders gain from it" counted absentees. On a guild night it is the same
  -- fault, quieter: anyone who did not turn up still ranks above people who did.
  --
  -- OUT OF A GROUP THE WHOLE ROSTER STAYS, deliberately. Browsing the loot table
  -- solo is planning, and an empty list there would be a worse bug than a long
  -- one — the same fail-open reasoning as guildMemberUserIds on the site.
  local inGroup = IsInGroup and IsInGroup() or false

  -- Roster.RealmFor answers nil only when the group scan has never seen them,
  -- which is exactly "not here". Someone present but not yet INSPECTED still has
  -- a roster entry, so nobody is dropped for being slow to resolve.
  local function seen(name)
    return ns.Roster.RealmFor and ns.Roster.RealmFor(name) ~= nil
  end

  -- ⚠️ NO FAIL-OPEN HERE, AND THAT IS DELIBERATE (Jason, Session 253, correcting
  -- my first version). I built an exception for "the scan has seen nobody yet",
  -- reasoning that an empty list reads as broken. Jason's answer is that an
  -- empty list is CORRECT and expected: joining an LFR should show nobody and
  -- backfill as the inspect passes complete. Showing the last-imported raid
  -- team instead is not a safe default, it is the clutter being complained
  -- about — sixteen people who are demonstrably somewhere else.
  --
  -- The fail-open lives one level up instead, and it is the honest one: OUT of a
  -- group we show the whole imported roster, because browsing solo is planning
  -- and there is no "here" to filter against.
  local out = {}
  for _, r in ipairs((data and data.roster) or {}) do
    if not inGroup or seen(r.n) then out[#out + 1] = r end
  end

  for _, entry in ipairs(ns.Roster.AdHoc()) do
    local ident = ns.Roster.IdentityFor(entry.name)
    -- Gear is the gate: class and spec alone cannot score anything.
    local hasGear = ns.Roster.HasGear(entry.name)
    if ident and ident.class and ident.spec and hasGear then
      out[#out + 1] = {
        n = entry.name, c = ident.class, s = ident.spec, h = ident.heroTree,
        adhoc = true,
      }
    end
  end

  -- ⚠️ YOU ARE THE ONE PERSON THE SCAN DELIBERATELY SKIPS. The ad-hoc list
  -- excludes yourself, because you are never inspected and in a guild night you
  -- are already on the export. With no export you are on nothing — so the one
  -- name certain to be standing there was the one name the ranked list could not
  -- contain, and "who is this for" answered without mentioning you.
  --
  -- This also covers the case that always existed and was never noticed: playing
  -- an alt, or a trial, on a night whose export does not list you.
  --
  -- Resolved from the client rather than from the scan, because your class, spec
  -- and hero tree are all directly readable — the same call the personal column
  -- scores through, so the two cannot disagree about who you are.
  local me = UnitName and UnitName("player")
  if me and ns.ResolveCharacter then
    local mine = ns.ResolveCharacter()
    if mine.className and mine.specName then
      -- Name-folded rather than compared raw: the export writes the name the
      -- site holds and the client answers with its own, and a realm suffix on
      -- one side would list you twice.
      local function isMe(name)
        if ns.Comms and ns.Comms.IsSelf then return ns.Comms.IsSelf(name) end
        return (name or ""):lower() == me:lower()
      end
      local listed = false
      for _, r in ipairs(out) do
        if isMe(r.n) then listed = true; break end
      end
      if not listed then
        out[#out + 1] = {
          n = me, c = mine.className, s = mine.specName, h = mine.heroTree,
          me = true,
        }
      end
    end
  end

  return out
end

--- Does this raider already hold a copy of the item in that slot, and at what
--- item level. Only the two-socket slots carry ids, which is the only place the
--- question can arise.
function Payload.OwnsCopy(raider, lootSlot, itemID)
  -- Same reasoning as the live read in SlotState: for YOU the client can be
  -- asked outright, and it answers about both sockets. The payload only ever
  -- recorded the worst piece in the slot, so reading it here could miss the copy
  -- you are actually wearing and offer you a second one.
  if raider and ns.Comms and ns.Comms.IsSelf(raider.n) and ns.EquippedCopy then
    return ns.EquippedCopy(lootSlot, itemID)
  end

  local state = Payload.SlotState(raider, lootSlot)
  if not (state and state.ids) then return false, nil end
  for _, id in ipairs(state.ids) do
    if id == itemID then
      -- We know they hold one, but not at which item level — the payload keeps
      -- ilvl for the WORST piece in the slot only. Treating that as the owned
      -- level is the conservative reading: it can understate the copy they hold
      -- and so never wrongly excludes them from an upgrade.
      return true, state.ilvl
    end
  end
  return false, nil
end

function Payload.Summary()
  local data = Payload.Current()
  if not data then return nil end
  local ranked = 0
  for _, r in ipairs(data.roster) do
    if r.pr then ranked = ranked + 1 end
  end
  return {
    raiders    = #data.roster,
    ranked     = ranked,
    ladder     = data.ladder and #data.ladder or 0,
    seasonName = data.seasonName,
    stamp      = data.stamp,
    audit      = data.audit,
  }
end

local function ageText(stamp)
  if not stamp then return "unknown age" end
  local secs = time() - stamp
  if secs < 0 then return "just now" end
  if secs < 3600 then return ("%d min ago"):format(math.floor(secs / 60)) end
  if secs < 86400 then return ("%dh ago"):format(math.floor(secs / 3600)) end
  return ("%.1f days ago"):format(secs / 86400)
end

--- How long ago the EXPORT was taken off the website.
function Payload.AgeText()
  local data = Payload.Current()
  return ageText(data and data.stamp)
end

--- How long ago the OLDEST GEAR AUDIT in this payload was taken.
---
--- This is the number that matters and it is NOT the export time: an export
--- made seconds ago can be built entirely from day-old gear. Reporting the
--- export age as the gear age claims the roster is live when it is not, which
--- is precisely the provenance the design requires be visible. Falls back to
--- naming the gap rather than silently substituting the export stamp.
function Payload.GearAgeText()
  local data = Payload.Current()
  if not (data and data.audit) then return "age unknown" end
  return ageText(data.audit)
end

-- ---------------------------------------------------------------------------
-- What an item costs
-- ---------------------------------------------------------------------------

--- GP = base x 2^(ilvl / div) x slot weight, x1.25 for a tier token.
---
--- ⚠️ EVERY CONSTANT COMES FROM THE PAYLOAD. The addon holds no copy of the
--- base constant, the divisor, the token surcharge or any slot weight, because
--- a copy is the thing that goes stale: the scale is re-tuned every season
--- (item cost climbs ~2.9x per 40 item levels) and a stale constant would put a
--- confident wrong price on screen. No pricing block, no price shown.
---
--- ⚠️ THE ITEM LEVEL IS THE CALLER'S, not the one our table predicts. A drop
--- carries its real level in its link, which is better data than the emitted
--- ilvl table — the same reasoning as ns.ItemLinkFor.
---
--- There is NO off-spec price. Per rules/HoD_Rules_EPGP.txt a bid is a bid, and
--- the multiplier is deliberately not even sent.
---
--- @param itemID number
--- @param ilvl number the level this copy actually is
--- @param slotOverride string|nil a loot slot, for an item with no record of
---   our own — a dungeon or world-boss drop read from the Encounter Journal.
--- @return number|nil GP, or nil when it cannot be priced honestly
function Payload.Price(itemID, ilvl, slotOverride)
  local data = Payload.Current()
  local gp = data and data.gp
  if type(gp) ~= "table" then return nil end
  if type(gp.base) ~= "number" or type(gp.div) ~= "number" or gp.div == 0 then return nil end
  if type(gp.w) ~= "table" then return nil end
  if type(ilvl) ~= "number" or ilvl <= 0 then return nil end

  local static = ns.Data and ns.Data() or nil
  local rec = static and (static.items or {})[itemID] or nil
  local isToken = rec ~= nil and rec.slot == "TOKEN"

  -- An omni-token buys ANY tier slot, so ns.ItemSlot answers nil for it. The
  -- site prices it as a chest — the most expensive of the tier slots and the
  -- common case — and this must make the SAME choice or the two disagree in
  -- front of the raid. See gpSlotWeight() in app/lib/epgp.ts.
  local slot = slotOverride or (rec and ns.ItemSlot(rec)) or (isToken and "CHEST") or nil
  if not slot then return nil end

  local weight = gp.w[slot]
  if type(weight) ~= "number" then return nil end
  if isToken then weight = weight * (gp.token or 1) end

  return gp.base * (2 ^ (ilvl / gp.div)) * weight
end

--- The price as the panel shows it: whole GP, or nil.
--- Rounded, never floored — 99.6 is 100, which is what the site's preview says.
function Payload.PriceText(itemID, ilvl, slotOverride)
  local gp = Payload.Price(itemID, ilvl, slotOverride)
  if not gp then return nil end
  return ("%d GP"):format(math.floor(gp + 0.5))
end
