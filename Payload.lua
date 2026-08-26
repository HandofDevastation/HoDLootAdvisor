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
function Payload.Store(data, raw, from)
  ns.db.raid = data
  ns.db.raidRaw = raw
  ns.db.raidFrom = from and ns.Comms and ns.Comms.Normalize(from) or nil
  Payload.BuildIndex()
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
  local data = Payload.Current()
  if not (data and raider and Payload.slotIndex) then return nil end

  local idx = Payload.slotIndex[lootSlot]
  if not idx then return nil end

  -- An AD-HOC raider carries no `g` at all: the export has never heard of them,
  -- so there is no snapshot to fall back to. They resolve entirely from what we
  -- learned in game, and if that is nothing they are not ranked — they are
  -- listed as unresolved instead. Defaulting them to ilvl 0 would make every
  -- item a maximum upgrade and float a stranger to the top of every list.
  local ilvl, track = 0, nil
  if raider.g then
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

  -- Nothing from the export AND nothing learned in game. Returning a zeroed
  -- state here would read as "empty slot", which the scorer treats as anything
  -- being an upgrade.
  if not raider.g and not better then return nil end

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
function Payload.EffectiveRoster()
  local data = Payload.Current()
  if not data then return {} end
  if not ns.Roster then return data.roster end

  local out = {}
  for _, r in ipairs(data.roster) do out[#out + 1] = r end

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

  return out
end

--- Does this raider already hold a copy of the item in that slot, and at what
--- item level. Only the two-socket slots carry ids, which is the only place the
--- question can arise.
function Payload.OwnsCopy(raider, lootSlot, itemID)
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
