-- Diagnostics.lua — the passive observer
--
-- THIS IS THE POINT OF v1. Everything about the loot path that we could verify
-- from Blizzard's shipped UI source has been verified (Data Contract §5). What
-- no source can answer is how those events actually behave in a live 20-man
-- raid: what fires, in what order, with what values, and what is already nil by
-- the time we read it.
--
-- So this file logs every loot-related event with its FULL return values into
-- SavedVariables, and the first real raid night becomes the confirmation —
-- passively, with nobody doing anything special. The failure mode is benign: the
-- addon shows nothing, which is exactly where we are today. Every raid night
-- without this installed is an observation we cannot get back, which is why it
-- was built before the panel.
--
-- Two things it must never do: error in combat, or lose data by growing without
-- bound. Hence pcall around every API call and a hard cap on the log.

local ADDON_NAME, ns = ...

local Diagnostics = {}
ns.Diagnostics = Diagnostics

-- ---------------------------------------------------------------------------
-- What we watch
-- ---------------------------------------------------------------------------
--
-- Registering an unknown event NAME raises a Lua error in modern clients, and
-- some of these are educated guesses rather than verified names. So every
-- registration is pcall'd and the failures are RECORDED — "this event does not
-- exist in 12.1" is itself a finding, and `/la diag events` reports it.

local WATCHED = {
  -- The roll window itself
  "START_LOOT_ROLL",
  "CANCEL_LOOT_ROLL",
  "CONFIRM_LOOT_ROLL",
  "LOOT_ROLLS_COMPLETE",
  -- The structured history — the completeness path (C_LootHistory)
  "LOOT_HISTORY_UPDATE_DROP",
  "LOOT_HISTORY_UPDATE_ENCOUNTER",
  "LOOT_HISTORY_GO_TO_ENCOUNTER",
  "LOOT_HISTORY_CLEAR_HISTORY",
  -- LOOT_HISTORY_AUTO_SHOW and LOOT_HISTORY_FULL_UPDATE were guessed here and
  -- REJECTED by a live 12.1 client (Session 242) — they do not exist. Do not
  -- re-add them; the four LOOT_HISTORY_* names above are the real ones and
  -- registered fine. This is precisely what the pcall guard is for.
  -- Award / receipt
  "ENCOUNTER_LOOT_RECEIVED",
  "CHAT_MSG_LOOT",
  -- Kill context, so a night's log can be split by pull
  "ENCOUNTER_START",
  "ENCOUNTER_END",
  "BOSS_KILL",
  -- Gear provenance: an installer's own equipped state, self-reported
  "PLAYER_EQUIPMENT_CHANGED",
}

-- Events whose payload is large and highly repetitive; logged, but the enriched
-- extras are skipped so a long night does not fill the log with equipment noise.
local LEAN = {
  PLAYER_EQUIPMENT_CHANGED = true,
  CHAT_MSG_LOOT = true,
}

-- Events that fire constantly during ordinary solo play. The log is a RING
-- BUFFER, so questing loot does not merely add noise — it EVICTS the raid
-- observations this exists to capture (a single evening of questing produced 98
-- CHAT_MSG_LOOT entries against 1 real one). Recorded only when the context
-- could plausibly be a group kill.
local NOISY = { CHAT_MSG_LOOT = true }

local function inRelevantContext()
  if IsInGroup and IsInGroup() then return true end
  local _, instanceType = GetInstanceInfo()
  return instanceType == "raid" or instanceType == "party"
end

Diagnostics.registered = {}
Diagnostics.unavailable = {}

-- ---------------------------------------------------------------------------
-- Making values safe to store
-- ---------------------------------------------------------------------------
--
-- SavedVariables can only hold numbers, strings, booleans and tables of those.
-- 12.1 also introduced SECRET values, which can error merely on being read in
-- insecure code — C_LootHistory is explicitly marked SecretArguments. So
-- anything that is not a plain scalar is recorded as its TYPE rather than its
-- value, and even tostring() goes through pcall. Losing a value's contents is
-- acceptable; erroring mid-raid is not.

local MAX_DEPTH = 3

local function scrub(v, depth)
  local t = type(v)
  if t == "number" or t == "string" or t == "boolean" then return v end
  if t == "nil" then return nil end
  if t == "table" then
    if (depth or 0) >= MAX_DEPTH then return "<table:deep>" end
    local out = {}
    local ok = pcall(function()
      for k, val in pairs(v) do
        if type(k) == "string" or type(k) == "number" then
          out[k] = scrub(val, (depth or 0) + 1)
        end
      end
    end)
    if not ok then return "<table:unreadable>" end
    return out
  end
  local ok, s = pcall(tostring, v)
  return "<" .. t .. (ok and (":" .. tostring(s)) or "") .. ">"
end
Diagnostics.scrub = scrub

--- Pack varargs preserving holes: select('#') is the only honest length when a
--- middle return is nil, and a nil-holed loot return is exactly the kind of
--- thing this log exists to catch.
local function packArgs(...)
  local n = select("#", ...)
  local out = { n = n }
  for i = 1, n do
    out[i] = scrub((select(i, ...)))
  end
  return out
end

-- ---------------------------------------------------------------------------
-- The log
-- ---------------------------------------------------------------------------

local function db()
  return ns.db
end

local function append(entry)
  local d = db()
  if not d or not d.diagnostics then return end
  local log = d.log
  if not log then log = {}; d.log = log end

  entry.t = time()
  log[#log + 1] = entry

  local cap = d.logCap or 3000
  local over = #log - cap
  if over > 0 then
    -- Drop the oldest. A raid night is a few hundred entries, so this only ever
    -- runs when the log has gone unread for weeks.
    for _ = 1, over do table.remove(log, 1) end
    d.logTruncated = (d.logTruncated or 0) + over
  end
end
Diagnostics.Append = append

--- Record a free-form note alongside the events — used to mark a login, a
--- /reload, or a dev-injected roll, so the log reads as a timeline rather than a
--- pile of events with no context.
function Diagnostics.Note(label, detail)
  append({ e = "@" .. tostring(label), x = scrub(detail, 0) })
end

-- ---------------------------------------------------------------------------
-- Per-event enrichment
-- ---------------------------------------------------------------------------
--
-- The event arguments alone are rarely the interesting part. What matters is
-- what the companion API returns AT THAT MOMENT — which is precisely what we
-- cannot verify outside a raid. Every call is pcall'd and packed with its full
-- return list, in order, so the log answers "what did GetLootRollItemInfo
-- actually give us" rather than "what did we think it gave us".

local function call(fnPath, fn, ...)
  if type(fn) ~= "function" then return { missing = fnPath } end
  -- The returns are collected through select('#'), never a `{ pcall(...) }`
  -- table constructor: a nil return anywhere in the list truncates that table,
  -- and these APIs are full of conditional nils. GetLootRollItemInfo's three
  -- `reason` returns are nil whenever the player IS eligible, which silently
  -- turned its 13 returns into 9 — losing canTransmog, the last one, entirely.
  local function collect(ok, ...)
    if not ok then return { error = scrub((...), 0) } end
    return packArgs(...)
  end
  return collect(pcall(fn, ...))
end

local ENRICH = {}

ENRICH.START_LOOT_ROLL = function(rollID)
  return {
    -- 13 returns, order verified in Blizzard's GroupLootFrame.lua for 12.1.0:
    -- texture, name, count, quality, bindOnPickUp, canNeed, canGreed,
    -- canDisenchant, reasonNeed, reasonGreed, reasonDisenchant,
    -- deSkillRequired, canTransmog
    rollItemInfo = call("GetLootRollItemInfo", GetLootRollItemInfo, rollID),
    rollItemLink = call("GetLootRollItemLink", GetLootRollItemLink, rollID),
    timeLeft     = call("GetLootRollTimeLeft", GetLootRollTimeLeft, rollID),
  }
end

ENRICH.ENCOUNTER_END = function(encounterID)
  local hist = C_LootHistory
  return {
    sortedDrops = call(
      "C_LootHistory.GetSortedDropsForEncounter",
      hist and hist.GetSortedDropsForEncounter,
      encounterID
    ),
  }
end

ENRICH.LOOT_HISTORY_UPDATE_ENCOUNTER = ENRICH.ENCOUNTER_END
ENRICH.LOOT_HISTORY_GO_TO_ENCOUNTER  = ENRICH.ENCOUNTER_END

ENRICH.LOOT_HISTORY_UPDATE_DROP = function(encounterID, lootListID)
  local hist = C_LootHistory
  return {
    drop = call(
      "C_LootHistory.GetInfoForEncounterDrop",
      hist and hist.GetInfoForEncounterDrop,
      encounterID, lootListID
    ),
  }
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

local frame = CreateFrame("Frame")

frame:SetScript("OnEvent", function(_, event, ...)
  local d = db()
  if not d or not d.diagnostics then return end
  if NOISY[event] and not inRelevantContext() then return end

  local entry = { e = event, a = packArgs(...) }

  if not LEAN[event] then
    local enrich = ENRICH[event]
    if enrich then
      local ok, extra = pcall(enrich, ...)
      entry.x = ok and extra or { enrichError = scrub(extra, 0) }
    end
  end

  append(entry)
end)

-- The loot path registers its OWN frame in Loot.lua. Diagnostics is a pure
-- observer: dispatching the real handler from here would mean `/la diag off`
-- silently switched the addon's actual behaviour off with it.

function Diagnostics.Start()
  for _, event in ipairs(WATCHED) do
    local ok = pcall(frame.RegisterEvent, frame, event)
    if ok then
      Diagnostics.registered[#Diagnostics.registered + 1] = event
    else
      Diagnostics.unavailable[#Diagnostics.unavailable + 1] = event
    end
  end

  -- THE MARKER IS DEFERRED, and that is the whole point of this frame.
  -- Session 243 read specKnown = false on 18 of 18 logins and concluded the spec
  -- never resolved. Half of that was a real bug (zero is truthy; fixed), but the
  -- marker ALSO ran at ADDON_LOADED, before the client can answer a spec query
  -- at all — so it kept recording false for a spec that now resolves fine. A log
  -- that lies is worse than no log: it is the thing we reason FROM.
  local waiter = CreateFrame("Frame")
  waiter:RegisterEvent("PLAYER_ENTERING_WORLD")
  waiter:SetScript("OnEvent", function(self)
    -- PLAYER_ENTERING_WORLD fires again on every zone and instance load. One
    -- marker per login is the intent, so this unregisters itself.
    self:UnregisterAllEvents()
    self:SetScript("OnEvent", nil)
    Diagnostics.SessionMarker()
  end)
end

--- The login marker. Written once spec data is actually available — see the
--- deferral note in Start(). If the spec STILL does not resolve here, that is a
--- genuine finding rather than a timing artefact, which is what makes the
--- recorded specSource worth having.
function Diagnostics.SessionMarker()
  local char = ns.ResolveCharacter()
  local pieces, setKnown, setIds = ns.TierPieceCount()
  local _, difficultyID = ns.DifficultyKey()

  -- A login marker, carrying the things we want a verified map of later: the
  -- real spec id behind the localized spec name, and whether equipped tier
  -- pieces report a set id at all.
  Diagnostics.Note("session", {
    version      = ns.Version(),
    class        = char.className,
    classToken   = char.classToken,
    spec         = char.specName,
    specId       = char.specId,
    -- WHICH API answered, not an assumption about which exists. 18 of 18 logins
    -- reporting no spec at all is what turned this from a nicety into the fix.
    specIndex    = char.specIndex,
    specSource   = char.specSource,
    heroTree     = char.heroTree,
    specKnown    = char.known,
    tierPieces   = pieces,
    setIdsKnown  = setKnown,
    setIds       = setIds,
    difficultyID = difficultyID,
    dataSchema   = (ns.Data() and ns.Data().meta or {}).schema,
    unavailable  = Diagnostics.unavailable,
  })
end

-- ---------------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------------

local function counts()
  local d = db()
  local byEvent, total = {}, 0
  for _, e in ipairs((d and d.log) or {}) do
    byEvent[e.e] = (byEvent[e.e] or 0) + 1
    total = total + 1
  end
  return byEvent, total
end

function Diagnostics.Status()
  local d = db()
  if not d then return end
  local byEvent, total = counts()
  ns.Line(("Diagnostics: %s · %d entries logged (cap %d)"):format(
    d.diagnostics and "|cff20ba56ON|r" or "|cffff4444OFF|r", total, d.logCap or 3000))
  if (d.logTruncated or 0) > 0 then
    ns.Line(("  %d oldest entries dropped to stay under the cap"):format(d.logTruncated))
  end
  if #Diagnostics.unavailable > 0 then
    ns.Line("  Events this client rejected: " .. table.concat(Diagnostics.unavailable, ", "))
  end
  local shown = 0
  for event, n in pairs(byEvent) do
    if event:sub(1, 1) ~= "@" then
      ns.Line(("  %s × %d"):format(event, n))
      shown = shown + 1
    end
  end
  if shown == 0 then
    ns.Line("  No loot events seen yet — expected until a boss dies.")
  end
end

function Diagnostics.Command(sub, arg)
  local d = db()
  if not d then return end
  sub = (sub or ""):lower()

  if sub == "" or sub == "status" then
    Diagnostics.Status()
  elseif sub == "on" then
    d.diagnostics = true
    Diagnostics.Note("enabled")
    ns.Print("diagnostic logging ON.")
  elseif sub == "off" then
    d.diagnostics = false
    ns.Print("diagnostic logging OFF. Loot events will no longer be recorded.")
  elseif sub == "clear" then
    local _, total = counts()
    d.log = {}
    d.logTruncated = 0
    ns.Print(("cleared %d log entries."):format(total))
  elseif sub == "events" then
    ns.Print("registered events:")
    ns.Line(table.concat(Diagnostics.registered, ", "))
    if #Diagnostics.unavailable > 0 then
      ns.Warn("rejected by this client: " .. table.concat(Diagnostics.unavailable, ", "))
    end
  elseif sub == "dump" then
    local n = tonumber(arg) or 10
    local log = d.log or {}
    ns.Print(("last %d of %d entries:"):format(math.min(n, #log), #log))
    for i = math.max(1, #log - n + 1), #log do
      local e = log[i]
      ns.Line(("[%d] %s (%d args)"):format(i, tostring(e.e), (e.a and e.a.n) or 0))
    end
    ns.Line("Full detail is in SavedVariables\\HoDLootAdvisor.lua after a /reload or logout.")
  else
    ns.Warn("usage: /la diag [on|off|clear|dump [n]|events]")
  end
end
