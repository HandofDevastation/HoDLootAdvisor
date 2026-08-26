-- Journal.lua — what does the Adventure Guide actually give us?
--
-- The Encounter Journal is the in-game loot catalogue: every instance, RAIDS AND
-- DUNGEONS, with the loot table for each encounter. It is already our source —
-- /api/loot-advisor/fetch-journal calls Blizzard's journal-encounter HTTP
-- endpoint, and the client holds the same database locally. If the addon can
-- read it directly, browsing the season's loot needs no emitted payload and
-- dungeon loot needs no site work at all.
--
-- This file ASKS rather than assumes. Two wrong API recollections have already
-- cost real time this project — LOOT_HISTORY_AUTO_SHOW does not exist, and
-- GetSpecialization silently returned 0 for eighteen logins — so nothing here
-- states what the API is. It probes a candidate list, reports which names are
-- PRESENT, calls only those, and records the actual shapes it got back.
--
-- Same discipline as Diagnostics.lua: every call pcall'd, every value scrubbed,
-- and the full detail written to SavedVariables so it can be read afterwards
-- rather than transcribed out of chat.

local ADDON_NAME, ns = ...

local Journal = {}
ns.Journal = Journal

-- Candidate names, generously listed. A name being ABSENT is a finding, not an
-- error — that is the entire point of probing rather than calling.
local GLOBALS = {
  "EJ_GetNumTiers", "EJ_GetTierInfo", "EJ_SelectTier", "EJ_GetCurrentTier",
  "EJ_GetInstanceByIndex", "EJ_SelectInstance", "EJ_GetInstanceInfo",
  "EJ_GetEncounterInfoByIndex", "EJ_SelectEncounter", "EJ_GetEncounterInfo",
  "EJ_GetNumLoot", "EJ_GetLootInfoByIndex", "EJ_GetLootInfo",
  "EJ_SetLootFilter", "EJ_GetLootFilter", "EJ_ResetLootFilter",
  "EJ_SetDifficulty", "EJ_GetDifficulty", "EJ_IsValidInstanceDifficulty",
  "EJ_SetSearch", "EJ_ClearSearch", "EJ_GetNumSearchResults", "EJ_GetSearchResult",
  "EJ_GetCurrentInstance", "EJ_InstanceIsRaid", "EJ_ContentTab_Select",
}

local NAMESPACED = {
  "GetEncounterInfo", "GetLootInfoByIndex", "GetSectionInfo",
  "GetSlotFilter", "SetSlotFilter", "ResetSlotFilter",
  "InstanceHasLoot", "GetInstanceForGameMap", "GetDungeonEntrancesForMap",
  "SetPreviewMythicPlusLevel", "GetLootInfo",
}

-- ---------------------------------------------------------------------------
-- Careful calling
-- ---------------------------------------------------------------------------

local function resolve(name)
  local g = _G[name]
  if type(g) == "function" then return g, name end
  local ej = _G.C_EncounterJournal
  local m = ej and ej[name]
  if type(m) == "function" then return m, "C_EncounterJournal." .. name end
  return nil, nil
end

--- Returns ok, packed-returns. Collected through select('#') and never a
--- `{ pcall(...) }` table constructor: a nil anywhere in the list truncates that
--- table, which is how GetLootRollItemInfo's 13 returns silently became 9.
local function call(fn, ...)
  if type(fn) ~= "function" then return false, { n = 0 } end
  local function collect(ok, ...)
    if not ok then return false, { n = 1, (...) } end
    local n = select("#", ...)
    local out = { n = n }
    for i = 1, n do out[i] = (select(i, ...)) end
    return true, out
  end
  return collect(pcall(fn, ...))
end

--- A short human description of one value, for the chat summary.
local function describe(v)
  local t = type(v)
  if t == "string" then
    return #v > 40 and ('"' .. v:sub(1, 40) .. '…"') or ('"' .. v .. '"')
  end
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "table" then
    -- A returned TABLE is itself the finding: modern EJ calls return info
    -- tables where older ones returned flat values, and which one this client
    -- does decides how the browse list is written.
    local keys = {}
    for k in pairs(v) do
      if type(k) == "string" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    if #keys > 8 then
      local head = {}
      for i = 1, 8 do head[i] = keys[i] end
      return ("table{%s,… %d fields}"):format(table.concat(head, ","), #keys)
    end
    return ("table{%s}"):format(table.concat(keys, ","))
  end
  return "<" .. t .. ">"
end

local function describeAll(packed, limit)
  local parts = {}
  for i = 1, math.min(packed.n or 0, limit or 6) do
    parts[#parts + 1] = describe(packed[i])
  end
  if (packed.n or 0) == 0 then return "nil" end
  return table.concat(parts, " · ")
end

-- ---------------------------------------------------------------------------
-- The probe
-- ---------------------------------------------------------------------------

--- Walk an indexed enumerator until it stops answering.
--- `cap` exists because an API that answers forever would hang the client.
local function enumerate(fn, cap, ...)
  local out = {}
  for i = 1, (cap or 40) do
    local ok, ret = call(fn, i, ...)
    if not ok or (ret.n or 0) == 0 or ret[1] == nil then break end
    out[#out + 1] = ret
  end
  return out
end

-- ---------------------------------------------------------------------------
-- The browse API
-- ---------------------------------------------------------------------------
--
-- Everything above this line is the PROBE — a diagnostic that asks what the
-- client has. Everything below is the read path built on what three live runs
-- established (rules/HoD_Rules_Loot-Gear.txt, "THE ENCOUNTER JOURNAL IS A
-- CLIENT-SIDE LOOT CATALOGUE"). The split is deliberate: the probe must keep
-- answering "what is actually there" without the browse path's assumptions
-- baked into it, because that is what caught two wrong answers already.
--
-- THREE FACTS THIS PATH IS BUILT ON, none of them recalled:
--  · loot reads live on C_EncounterJournal.GetLootInfoByIndex. The EJ_-prefixed
--    name is ABSENT on 12.1, and keying the lookup by it enumerated ZERO items
--    while reporting a count of 17.
--  · EJ_SetLootFilter must be applied BEFORE the encounter is (re-)selected.
--    Measured the other way round it reads back correctly and changes nothing,
--    which is indistinguishable from a broken filter.
--  · a cold item cache returns a FIVE-FIELD loot entry where a warm one returns
--    the full record. Item data is eventually consistent, never immediately
--    correct — the same rule the loot recorder learned.

--- Resolve once, at call time rather than at load: the Journal API is present
--- from the start, but resolving lazily keeps this file honest about the fact
--- that a name being missing is a normal outcome rather than an error.
local function api(name)
  local fn = resolve(name)
  return fn
end

local function firstOf(...)
  for i = 1, select("#", ...) do
    local fn = api((select(i, ...)))
    if fn then return fn end
  end
  return nil
end

--- Instance ids that are WORLD BOSS containers rather than real instances.
---
--- THIS IS THE MECHANISM, not a backstop. The first attempt matched the instance
--- name against the TIER name, on the assumption that the world-boss container
--- is named after its tier. `/la journal` settled it: EJ_GetTierInfo(13) returns
--- "Current Season", while the container is named "Midnight" — so that match
--- could never fire, and the code shipped claiming to work while doing nothing.
--- The name comparison is KEPT only because it costs nothing and would catch an
--- expansion-named tier, but nothing rests on it.
---
--- SEASON-SPECIFIC, accepted deliberately. A stale entry does nothing at all
--- (the id simply stops matching); a missing one shows ONE EXTRA INSTANCE in the
--- browse list. Both are visible, neither hides loot. Read the new id off
--- `/la journal`, which lists every instance with its id, at rollover.
---
--- 1312 = "Midnight", Midnight Season 2. Verified in a live client, Session 244.
Journal.WORLD_BOSS_INSTANCES = { [1312] = true }

--- Read a scalar return, or nil.
local function one(fn, ...)
  if not fn then return nil end
  local ok, ret = call(fn, ...)
  if not ok or (ret.n or 0) == 0 then return nil end
  return ret[1]
end

--- Selecting a tier or instance drives the REAL Adventure Guide, so anything we
--- change has to go back. Returns a restore function.
---
--- ⚠️ THE TIER IS RESTORABLE AND THE INSTANCE IS NOT: EJ_GetCurrentInstance is
--- ABSENT on 12.1 (verified, not assumed), so there is no way to read back which
--- instance was selected. EJ_GetInstanceInfo with no argument is TRIED for it,
--- guarded, because it costs nothing if it answers nothing — but the honest
--- statement is that browsing may leave an open Adventure Guide on a different
--- instance within the same tier. Reading the catalogue ONCE and caching it is
--- what keeps that from happening repeatedly.
local function saveState()
  local priorTier = one(api("EJ_GetCurrentTier"))
  -- EJ_GetCurrentInstance is ABSENT on 12.1 (verified), so the prior INSTANCE
  -- cannot be read back and is not restored.
  --
  -- ⚠️ DO NOT REINSTATE THE EJ_GetInstanceInfo() FALLBACK THAT WAS HERE. It read
  -- select(3, ...) as an instance id; the third return is bgImage, a texture
  -- FILE ID — a number, so it passed a type check and looked like an answer.
  -- Every restore then pointed the journal at an instance that does not exist,
  -- and browsing died progressively: the first encounter read fine and each one
  -- after it came back empty. Guessing at an id is not a cheap fallback, it is a
  -- silent corruption. Restore only what can actually be read.
  local priorInstance = one(api("EJ_GetCurrentInstance"))

  return function()
    local selectTier = api("EJ_SelectTier")
    if priorTier and selectTier then call(selectTier, priorTier) end
    local selectInstance = api("EJ_SelectInstance")
    if priorInstance and selectInstance then call(selectInstance, priorInstance) end
    local reset = api("EJ_ResetLootFilter")
    if reset then call(reset) end
  end
end

--- Point the journal at a tier. Defaults to the CURRENT tier, which is what the
--- client itself considers live — never a hardcoded number. Tier 13 is Midnight
--- Season 2 today and will not be next season.
local function selectTier(tier)
  local sel = api("EJ_SelectTier")
  if not sel then return nil end
  tier = tier or one(api("EJ_GetCurrentTier"))
  if not tier then return nil end
  call(sel, tier)
  return tier
end

--- Every instance in a tier: raids AND dungeons, in the journal's own order.
---
--- World bosses arrive here as a RAID entry (1312 "Midnight" in Season 2), which
--- is the journal's own modelling and not something to correct — it is why the
--- catalogue covers world bosses for free.
function Journal.Instances(tier)
  local byIndex = api("EJ_GetInstanceByIndex")
  if not byIndex then return {} end

  local restore = saveState()
  local resolved = selectTier(tier)

  -- THE WORLD BOSS CONTAINER is a raid entry named after the TIER itself (1312
  -- "Midnight" in Season 2), excluded from the browse catalogue — Jason's call:
  -- nobody puts a world boss drop on a watch list.
  --
  -- ⚠️ THE NAME MATCH IS NOT WHAT DOES THE WORK — see WORLD_BOSS_INSTANCES.
  -- EJ_GetTierInfo(13) returns "Current Season", NOT the expansion name, so
  -- comparing an instance name to the tier name never fires on the tier we
  -- actually browse. It is kept because it costs one comparison and would catch
  -- an expansion-named tier; the id set is the mechanism.
  --
  -- Which one answered is RECORDED, because that is the only thing that makes
  -- the next failure diagnosable instead of another guess.
  local tierName
  local tierInfo = api("EJ_GetTierInfo")
  if tierInfo and resolved then
    local ok, ret = call(tierInfo, resolved)
    if ok then
      for i = 1, (ret.n or 0) do
        local v = ret[i]
        -- A hyperlink is also a string; the NAME is the one without |H in it.
        if type(v) == "string" and v ~= "" and not v:find("|H", 1, true) then
          tierName = v
          break
        end
      end
    end
  end

  local out, excluded = {}, {}

  for _, isRaid in ipairs({ true, false }) do
    for i = 1, 60 do
      local ok, ret = call(byIndex, i, isRaid)
      if not ok or (ret.n or 0) == 0 or ret[1] == nil then break end
      -- EJ_GetInstanceByIndex returns instanceID, name, description, bgImage,
      -- buttonImage, loreImage, buttonImage2, dungeonAreaMapID, link, shouldDisplayDifficulty.
      -- NOTE bgImage (the 4th) is a texture FILE ID. It is a number, and reading
      -- a number here as an instance id is precisely what broke browsing once.
      local id, name = ret[1], ret[2]
      local isWorldBossList =
        (tierName and type(name) == "string"
          and name:lower():gsub("%s+", "") == tierName:lower():gsub("%s+", ""))
        or Journal.WORLD_BOSS_INSTANCES[id]

      if isWorldBossList then
        excluded[#excluded + 1] = ("%s (%s)"):format(tostring(name), tostring(id))
      else
        out[#out + 1] = {
          id     = id,
          name   = name,
          isRaid = isRaid,
          tier   = resolved,
        }
      end
    end
  end

  if ns.Diagnostics then
    ns.Diagnostics.Note("journalCatalogue", {
      tier = resolved, tierName = tierName,
      tierNameResolved = tierName ~= nil,
      instances = #out, excluded = excluded,
    })
  end

  restore()
  return out
end

--- The encounters in one instance, in journal order.
function Journal.Encounters(instanceID)
  local sel = api("EJ_SelectInstance")
  local byIndex = api("EJ_GetEncounterInfoByIndex")
  if not (sel and byIndex and instanceID) then return {} end

  local restore = saveState()
  call(sel, instanceID)

  local out = {}
  for i = 1, 30 do
    local ok, ret = call(byIndex, i)
    if not ok or (ret.n or 0) == 0 or ret[1] == nil then break end
    -- name, description, encounterID, rootSectionID, link, instanceID.
    out[#out + 1] = { name = ret[1], id = ret[3], instanceID = instanceID }
  end

  restore()
  return out
end

--- What one encounter can drop.
---
--- opts.classID / opts.specID apply Blizzard's OWN eligibility filter — "show me
--- only what I can use" for free, without going anywhere near our emitted
--- eligibility answers. Pass neither to see everything.
---
--- Returns a list of { itemID, name, link, icon, slot, armorType, quality,
--- veryRare, unusable }, plus a second return of how many entries came back
--- UNRESOLVED (a cold item cache). The caller uses that to know it should ask
--- again rather than to treat a five-field entry as the API's shape.
function Journal.Loot(encounterID, opts)
  opts = opts or {}
  local selEnc = api("EJ_SelectEncounter")
  -- The namespaced name FIRST. This ordering is the entire finding of probe run
  -- one: the global does not exist, and preferring it enumerated nothing.
  local lootAt = firstOf("GetLootInfoByIndex", "EJ_GetLootInfoByIndex", "GetLootInfo")
  if not (selEnc and lootAt and encounterID) then return {}, 0 end

  local restore = saveState()

  -- SELECT THE INSTANCE FIRST — never rely on it already being selected. An
  -- encounter only resolves within its own instance, and this used to read
  -- whatever the journal happened to be pointing at, which was fine on the first
  -- call (the encounter list had just selected it) and empty on every call
  -- after. Ambient selection state is not an input; it is a race.
  local instanceID = opts.instanceID or Journal.InstanceForEncounter(encounterID)
  local selInst = api("EJ_SelectInstance")
  if instanceID and selInst then call(selInst, instanceID) end

  -- FILTER BEFORE SELECT. The other order reads back correctly and filters
  -- nothing — see the header note.
  local setFilter = api("EJ_SetLootFilter")
  if setFilter and opts.classID then
    call(setFilter, opts.classID, opts.specID or 0)
  end
  call(selEnc, encounterID)

  local count = one(api("EJ_GetNumLoot")) or 0
  local out, cold = {}, 0

  for i = 1, count do
    local ok, ret = call(lootAt, i)
    local info = ok and ret[1]
    if type(info) == "table" then
      local itemID = info.itemID
      if itemID then
        -- A cold cache answers the id but not the name. Recorded as such rather
        -- than rendered as a placeholder that never goes away — the same failure
        -- that wrote "item:270160" into the loot log as an item NAME.
        local resolved = type(info.name) == "string" and info.name ~= ""
        if not resolved then cold = cold + 1 end
        out[#out + 1] = {
          itemID    = itemID,
          name      = resolved and info.name or nil,
          link      = info.link,
          icon      = info.icon,
          slot      = info.slot,
          armorType = info.armorType,
          quality   = info.itemQuality,
          veryRare  = info.displayAsVeryRare or info.displayAsExtremelyRare or false,
          -- Blizzard's own eligibility flags. Kept because they answer for
          -- DUNGEON and WORLD BOSS loot, which our emitted payload has never
          -- carried an answer for.
          unusable  = (info.handError or info.weaponTypeError) and true or false,
          encounterID = encounterID,
        }
      end
    end
  end

  -- INSTRUMENTED because the unfiltered-first-paint has no confirmed cause. The
  -- filter ARGUMENTS matter as much as the counts: a nil specID would mean the
  -- character's spec had not resolved when the panel first drew, which would
  -- explain an unfiltered list without any theory about item caches. Recording
  -- which values went in is how that gets settled instead of guessed.
  if ns.Diagnostics then
    ns.Diagnostics.Note("journalLoot", {
      encounterID = encounterID, instanceID = instanceID,
      classID = opts.classID, specID = opts.specID,
      filterApplied = (setFilter ~= nil and opts.classID ~= nil),
      reported = count, enumerated = #out, unnamed = cold,
    })
  end

  restore()
  return out, cold
end

-- ---------------------------------------------------------------------------
-- The cached catalogue
-- ---------------------------------------------------------------------------
--
-- Every read above DRIVES the real Adventure Guide — it selects a tier, an
-- instance and an encounter, and puts back what it can. Doing that on every
-- panel refresh would mean fighting the user for their own UI, so the catalogue
-- is read ONCE and held. The tier does not change under us during a session;
-- an item's NAME can (a cold cache), which is why the loot cache records whether
-- it was complete and re-reads only when it was not.

local cache = { instances = nil, encounters = {}, loot = {}, cold = {}, index = nil }

function Journal.Invalidate()
  cache = { instances = nil, encounters = {}, loot = {}, cold = {}, index = nil }
end

function Journal.CachedInstances()
  if not cache.instances then
    cache.instances = Journal.Instances()
  end
  return cache.instances
end

function Journal.CachedEncounters(instanceID)
  if not instanceID then return {} end
  if not cache.encounters[instanceID] then
    cache.encounters[instanceID] = Journal.Encounters(instanceID)
  end
  return cache.encounters[instanceID]
end

--- Which instance an encounter belongs to.
---
--- Built by walking the catalogue once, because an encounter cannot be read
--- without its instance selected and there is no API that answers this directly.
--- The alternative — assuming the right instance is already selected — is the
--- bug this index exists to kill.
function Journal.InstanceForEncounter(encounterID)
  if not encounterID then return nil end
  if not cache.index then
    cache.index = {}
    for _, inst in ipairs(Journal.CachedInstances()) do
      for _, enc in ipairs(Journal.CachedEncounters(inst.id)) do
        -- FIRST WINS. An encounter appearing in two instances would otherwise
        -- flip between them depending on enumeration order.
        if enc.id and not cache.index[enc.id] then cache.index[enc.id] = inst.id end
      end
    end
  end
  return cache.index[encounterID]
end

--- Loot for an encounter, optionally through Blizzard's class/spec filter.
---
--- Keyed by encounter AND filter, because they are genuinely different lists —
--- caching them together is how you get "17 items" and "5 items" answering to
--- the same key depending on who asked last.
---
--- A read that came back with unnamed entries is NOT cached as final: the client
--- is asked to load them and the next call re-reads. That is the async item-data
--- rule, and skipping it is what freezes "item:270160" into a list forever.
--- How many times a cold read is retried before it is accepted as final. An
--- item the client will never resolve must not leave the list loading forever.
local MAX_WARM_ATTEMPTS = 8

--- Loot for an encounter, plus whether the read is still WARMING.
---
--- WHAT IS ACTUALLY KNOWN: the first read of an encounter comes back with
--- entries carrying an itemID and no NAME, and a later read carries the full
--- record. That is observed, repeatedly, and is the same eventual-consistency
--- rule the loot recorder learned.
---
--- ⚠️ WHAT IS NOT KNOWN IS WHY THE FIRST PAINT WAS ALSO UNFILTERED. I asserted
--- that Blizzard's class/spec filter cannot judge an unloaded item, so a cold
--- read filters nothing. `/la journal` then measured the opposite: the probe
--- filtered 17 items to 5 while every entry was still nameless. So that
--- explanation is WRONG and the unfiltered first paint has no confirmed cause
--- yet — see the instrumentation below, which records the filter arguments and
--- the counts on every read so the next occurrence carries evidence.
---
--- None of that changes what to DO: read again. The retry is driven by the
--- observation, not by the theory, which is why it survived the theory failing.
---
--- Returns list, warming.
function Journal.CachedLoot(encounterID, opts)
  if not encounterID then return {}, false end
  opts = opts or {}
  local key = ("%s/%s/%s"):format(
    tostring(encounterID), tostring(opts.classID or "-"), tostring(opts.specID or "-"))

  local attempts = cache.cold[key]
  if cache.loot[key] and not attempts then
    return cache.loot[key], false
  end
  -- Given up on: return what we have rather than retrying forever.
  if attempts and attempts >= MAX_WARM_ATTEMPTS then
    return cache.loot[key] or {}, false
  end

  local list, cold = Journal.Loot(encounterID, opts)
  cache.loot[key] = list
  if cold > 0 then
    cache.cold[key] = (attempts or 0) + 1
    Journal.RequestItems(list)
    local warming = cache.cold[key] < MAX_WARM_ATTEMPTS
    -- Book the re-read HERE rather than waiting to be told the client has data.
    -- Nothing else guarantees another attempt, and without one the panel stays
    -- on its loading message forever.
    if warming then Journal.ScheduleWarm() end
    return list, warming
  end

  cache.cold[key] = nil
  return list, false
end

--- Re-read everything that came back cold. Called when the client answers with
--- item data it did not have before.
---
--- Returns true if any read is still warming, so the caller knows whether to
--- expect another pass.
function Journal.Warm()
  local stillWarming = false
  for key, attempts in pairs(cache.cold) do
    if attempts >= MAX_WARM_ATTEMPTS then
      cache.cold[key] = nil
    else
      -- The key carries everything the re-read needs, which is the reason it is
      -- built from the arguments rather than being an opaque counter.
      local encID, classID, specID = key:match("^(%d+)/([^/]+)/([^/]+)$")
      if encID then
        local _, warming = Journal.CachedLoot(tonumber(encID), {
          classID = tonumber(classID), specID = tonumber(specID),
        })
        stillWarming = stillWarming or warming
      else
        cache.cold[key] = nil
      end
    end
  end
  return stillWarming
end

-- ---------------------------------------------------------------------------
-- Warming on its own
-- ---------------------------------------------------------------------------
--
-- Without this the list only corrects itself when the user happens to navigate
-- away and back, which is exactly how the bug presented: ids and no filter on
-- the first look, names and a filter on the second. The client tells us when it
-- has the data — we just have to listen and re-read.
--
-- COALESCED behind a timer, because GET_ITEM_INFO_RECEIVED fires once PER ITEM
-- and a thirteen-item encounter would otherwise drive thirteen full re-reads,
-- each of which drives the real Adventure Guide.

local warmPending = false

--- Re-read soon, once, however many callers ask.
---
--- ⚠️ THIS MUST NOT DEPEND ON GET_ITEM_INFO_RECEIVED, and the first version did.
--- That event only fires when the client actually had to LOAD something — so
--- whenever a journal read came back incomplete for any other reason, or the
--- items were already cached, nothing ever fired and the panel sat on "Loading
--- item data…" until the user navigated away and back. Which is precisely the
--- behaviour the loading message was introduced to fix.
---
--- So the retry is UNCONDITIONAL and time-based. The event is kept as an
--- accelerator, not as the mechanism. What we know empirically is that the first
--- read is incomplete and a later one is not; we do not need a theory of why in
--- order to read again.
function Journal.ScheduleWarm(delay)
  if warmPending then return end
  warmPending = true
  C_Timer.After(delay or 0.25, function()
    warmPending = false
    local stillWarming = Journal.Warm()
    -- Only the panel knows whether it is showing; Refresh is a no-op when not.
    if ns.Panel and ns.Panel.Refresh then ns.Panel.Refresh() end
    -- Keep going until it resolves or the attempt cap gives up, so this cannot
    -- stall halfway with a loading message and no pending work.
    if stillWarming then Journal.ScheduleWarm(delay) end
  end)
end

local warmFrame = CreateFrame("Frame")
warmFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
warmFrame:SetScript("OnEvent", function() Journal.ScheduleWarm(0.2) end)

--- Ask the client to load any item we could not name yet, so a later pass can.
--- Mirrors Record.ResolveItemInfo: assume every client-side item read is
--- eventually consistent, and go back for it rather than freezing a placeholder.
function Journal.RequestItems(entries)
  local req = C_Item and C_Item.RequestLoadItemDataByID
  if not req then return end
  for _, e in ipairs(entries or {}) do
    if e.itemID and not e.name then pcall(req, e.itemID) end
  end
end

function Journal.Probe()
  local report = { present = {}, absent = {} }

  ns.Print("probing the Encounter Journal…")

  -- 1. WHICH NAMES EXIST. Everything below depends on this, and it is the half
  -- that cannot be got wrong by recall.
  local fns = {}
  for _, name in ipairs(GLOBALS) do
    local fn, where = resolve(name)
    if fn then fns[name] = fn; report.present[#report.present + 1] = where
    else report.absent[#report.absent + 1] = name end
  end
  for _, name in ipairs(NAMESPACED) do
    local fn, where = resolve(name)
    if fn then fns[name] = fn; report.present[#report.present + 1] = where
    else report.absent[#report.absent + 1] = name end
  end

  --- The first of several candidate names that actually resolved. Session 243's
  --- probe learned the hard way that this is needed: EJ_GetLootInfoByIndex is
  --- ABSENT on 12.1 while C_EncounterJournal.GetLootInfoByIndex is present, and
  --- keying the lookup by the global's name found nothing — so the probe
  --- reported 17 items of loot and then enumerated zero of them.
  local function pick(...)
    for i = 1, select("#", ...) do
      local name = (select(i, ...))
      if fns[name] then return fns[name], name end
    end
    return nil, nil
  end

  ns.Line(("API: |cff20ba56%d present|r · |cffff4444%d absent|r"):format(
    #report.present, #report.absent))
  ns.Line("  " .. table.concat(report.present, ", "))
  if #report.absent > 0 then
    ns.Line("  |cff888899absent:|r " .. table.concat(report.absent, ", "))
  end

  -- 2. STATE WE MUST PUT BACK. Selecting a tier/instance drives the real
  -- Adventure Guide, so anything we change is restored before returning —
  -- a diagnostic that leaves the user's UI on a different raid is a bug.
  local _, curTier = call(fns.EJ_GetCurrentTier)
  local _, curInstance = call(fns.EJ_GetCurrentInstance)
  report.priorTier = curTier and curTier[1]
  report.priorInstance = curInstance and curInstance[1]

  -- 3. TIERS
  local ok, tiers = call(fns.EJ_GetNumTiers)
  report.numTiers = ok and tiers[1] or nil
  if report.numTiers then
    ns.Line(("Tiers: %s (currently on %s)"):format(
      tostring(report.numTiers), tostring(report.priorTier)))
  end

  -- WHAT DOES EJ_GetTierInfo ACTUALLY RETURN? The world-boss exclusion was
  -- written against an assumed shape, shipped, and did not work — because this
  -- was never asked. The probe reports presence; presence is not shape.
  if fns.EJ_GetTierInfo and report.priorTier then
    local okT, tierRet = call(fns.EJ_GetTierInfo, report.priorTier)
    report.tierInfo = okT and describeAll(tierRet, 4) or "call failed"
    ns.Line(("EJ_GetTierInfo(%s): %s"):format(
      tostring(report.priorTier), tostring(report.tierInfo)))
  end

  -- 4. INSTANCES — and the question that actually matters: DUNGEONS.
  -- EJ_GetInstanceByIndex's second argument is documented as isRaid; passing
  -- false is the whole reason this probe exists, because a dungeon catalogue in
  -- the client means dungeon targets need no site work at all.
  --- EVERY instance is recorded, not a sample. The first probe capped this at 5
  --- and proved dungeons enumerate without saying WHICH — enough to answer the
  --- yes/no and useless for the question that followed it immediately. A list
  --- short enough to walk is short enough to keep whole.
  local function listInstances(isRaid, label)
    local rows = enumerate(fns.EJ_GetInstanceByIndex, 60, isRaid)
    report[label] = { count = #rows, list = {} }
    ns.Line(("%s this tier: |cffF3C56B%d|r"):format(label, #rows))
    for i = 1, #rows do
      local line = describeAll(rows[i], 2)
      report[label].list[i] = line
      ns.Line("    " .. line)
    end
    return rows
  end

  local raids = listInstances(true, "Raids")
  local dungeons = listInstances(false, "Dungeons")

  -- 4b. Does each DUNGEON actually carry a loot table? Enumerating the list is
  -- not the same as the list being useful, and this is one call each.
  if fns.EJ_SelectInstance and fns.EJ_GetEncounterInfoByIndex then
    report.dungeonDetail = {}
    for i = 1, #dungeons do
      local id, name = dungeons[i][1], dungeons[i][2]
      call(fns.EJ_SelectInstance, id)
      local encs = enumerate(fns.EJ_GetEncounterInfoByIndex, 20)
      local hasLoot
      if fns.InstanceHasLoot then
        local okL, l = call(fns.InstanceHasLoot, id)
        hasLoot = okL and l[1]
      end
      report.dungeonDetail[i] = ("%s · %s · %d encounters · loot=%s"):format(
        tostring(id), tostring(name), #encs, tostring(hasLoot))
      ns.Line("    " .. report.dungeonDetail[i])
    end
  end

  -- 5. DRILL INTO ONE INSTANCE — encounters, then loot. Uses the FIRST raid so
  -- the result is comparable against the payload we already emit.
  local probe = raids[1] or dungeons[1]
  local instanceID = probe and probe[1]
  if instanceID and fns.EJ_SelectInstance then
    call(fns.EJ_SelectInstance, instanceID)

    local encounters = enumerate(fns.EJ_GetEncounterInfoByIndex, 30)
    report.encounters = { count = #encounters, list = {} }
    ns.Line(("Encounters in instance %s: |cffF3C56B%d|r"):format(
      tostring(instanceID), #encounters))
    for i = 1, #encounters do
      report.encounters.list[i] = describeAll(encounters[i], 2)
    end
    for i = 1, math.min(#encounters, 3) do ns.Line("    " .. report.encounters.list[i]) end

    -- LOOT. The prize. EJ_GetLootInfoByIndex has returned a flat list in some
    -- versions and an info TABLE in others; describe() reports which, because
    -- that decides how a browse list reads it.
    if encounters[1] and fns.EJ_SelectEncounter then
      call(fns.EJ_SelectEncounter, encounters[1][1])
      local okN, n = call(fns.EJ_GetNumLoot)
      report.lootCount = okN and n[1] or nil
      ns.Line(("Loot for that encounter: |cffF3C56B%s|r"):format(tostring(report.lootCount)))

      local lootFn, lootName = pick("GetLootInfoByIndex", "EJ_GetLootInfoByIndex", "GetLootInfo")
      local loot = enumerate(lootFn, 30)
      report.loot = { count = #loot, via = lootName, sample = {} }
      ns.Line(("  via %s: |cffF3C56B%d|r entries"):format(tostring(lootName), #loot))
      for i = 1, math.min(#loot, 4) do
        report.loot.sample[i] = describeAll(loot[i], 4)
        ns.Line("    " .. report.loot.sample[i])
      end
      -- The SHAPE decides how a browse list reads it, so the first entry's
      -- fields are recorded in full rather than summarised.
      if type(loot[1] and loot[1][1]) == "table" then
        local fields = {}
        for k, v in pairs(loot[1][1]) do
          if type(k) == "string" then fields[k] = describe(v) end
        end
        report.loot.firstEntry = fields
      end

      -- 6. THE CLASS/SPEC FILTER. If this works, "show me only what I can use"
      -- is free, and the eligibility data we emit is not needed for browsing.
      if fns.EJ_SetLootFilter then
        local char = ns.ResolveCharacter()
        local classID = select(3, UnitClass("player"))
        local okF = call(fns.EJ_SetLootFilter, classID, char.specId or 0)
        -- Re-select the encounter before measuring. The first probe set the
        -- filter, saw the count unchanged at 17, and could not tell whether the
        -- filter had failed or simply had not been applied to a cached query.
        call(fns.EJ_SelectEncounter, encounters[1][1])
        local okA, after = call(fns.EJ_GetNumLoot)
        local okG, got = call(fns.EJ_GetLootFilter)
        report.filtered = { set = okF, classID = classID, specId = char.specId,
                            count = okA and after[1] or nil,
                            readBack = okG and describeAll(got, 2) or nil,
                            afterEnum = #enumerate(lootFn, 30) }
        ns.Line(("Loot filtered to %s/%s: |cffF3C56B%s|r of %s (enumerated %d, filter reads back %s)"):format(
          tostring(char.className), tostring(char.specName),
          tostring(report.filtered.count), tostring(report.lootCount),
          report.filtered.afterEnum, tostring(report.filtered.readBack)))
        if fns.EJ_ResetLootFilter then call(fns.EJ_ResetLootFilter) end
      else
        ns.Line("|cff888899No EJ_SetLootFilter — a browse list would filter itself.|r")
      end
    end
  end

  -- 7. PUT IT BACK.
  if report.priorTier and fns.EJ_SelectTier then call(fns.EJ_SelectTier, report.priorTier) end
  if report.priorInstance and fns.EJ_SelectInstance then
    call(fns.EJ_SelectInstance, report.priorInstance)
  end

  if ns.Diagnostics then ns.Diagnostics.Note("journalProbe", report) end
  ns.Line("Full detail is in SavedVariables after a |cffF3C56B/reload|r.")
  return report
end
