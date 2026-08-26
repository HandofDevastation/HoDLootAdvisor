-- Roster.lua — who is actually standing here, and what are they wearing
--
-- The raid payload is a SNAPSHOT taken off the website before invites. Two
-- things are wrong with it by the time a boss dies, and they are different
-- problems:
--
--   1. WHO. It carries the active raid team. The people in the instance are
--      whoever turned up — which includes ALTS not on the team, trials, and the
--      occasional pug. Those people were previously INVISIBLE: not ranked, not
--      listed, not mentioned. That is the one thing the design says must never
--      happen ("a raider must never be silently missing").
--   2. WHAT. The gear came from a character audit that may be a day old. Someone
--      who has run a key since is wearing something the payload has never seen.
--
-- Three sources answer those, in descending order of how much they can be
-- trusted, and this file is where they meet:
--
--   GROUP ROSTER   — free, instant, everyone. Name, class, role. Nothing else.
--   COMMS (GEAR)   — installers only. Exact, live, and self-declared.
--   INSPECTION     — everyone else. Exact when it works, and it often does not:
--                    one target at a time, range-limited, silently refused.
--
-- ⚠️ INSPECTION IS BUILT ON ASSUMPTIONS THIS FILE DOES NOT TRUST. Every call is
-- guarded, every answer is RECORDED rather than assumed, and /la roster reports
-- what actually happened per person. That is deliberate and it is the same
-- pattern Journal.lua used on the Encounter Journal: the first live raid tells
-- us which half of this works, instead of us finding out by being wrong in
-- front of the raid. Nothing here can produce a WRONG answer — the failure mode
-- is a person marked unresolved, which is visible.

local ADDON_NAME, ns = ...

local Roster = {}
ns.Roster = Roster

-- ---------------------------------------------------------------------------
-- Pacing
-- ---------------------------------------------------------------------------
--
-- Inspection is throttled by the client and only one request can be in flight.
-- These numbers are deliberately unhurried: a raid resolves over a couple of
-- minutes of trash rather than in a burst at the door, and nothing downstream
-- is waiting on it — an unresolved raider still ranks from the snapshot.

local INSPECT_GAP     = 2.0   -- seconds between attempts, whatever the outcome
local INSPECT_TIMEOUT = 4.0   -- give up on a request that never answers

-- Per-person retry spacing. Someone out of range on the first sweep is usually
-- in range later, so failure is never final — but it backs off hard, because a
-- person who is genuinely uninspectable would otherwise be retried forever at
-- the same rate as everyone else.
local RETRY_LADDER = { 15, 30, 60, 120, 300 }

-- Slots that count as a complete enough read. There are 17 keys in SLOT_INV but
-- several share an inventory slot (ONE_HAND / TWO_HAND / RANGED all read
-- MAIN_HAND), and plenty of real characters have an empty off-hand or a missing
-- ring, so demanding all of them would retry forever. Twelve is comfortably
-- above what a cold cache returns and below what a geared character has.
local GEAR_ENOUGH = 12

-- A reading below the CURRENT LADDER'S lowest rung is not current-season gear.
-- It is usually a cold-cache read answering with the item's BASE level instead
-- of its upgraded one — which is worse than answering nothing, because it looks
-- like data. Live, that put a raider at "+160 ilvl" on a 279 helm, implying
-- equipped 119. Derived from the emitted ladder rather than picked, so it
-- follows a season rollover on its own.
local function ladderFloor()
  local ladder = ((ns.Data() or {}).tracks or {}).ladder
  if not ladder or #ladder == 0 then return nil end
  local lowest
  for _, e in ipairs(ladder) do
    if e.ilvl and (not lowest or e.ilvl < lowest) then lowest = e.ilvl end
  end
  return lowest
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

--- normalized name -> everything we have learned about them in game.
---   { name, realm, class, classToken, role, guid, unit,
---     spec, heroTree, gear = { SLOT -> {ilvl, track, ids} }, at,
---     attempts, nextTry, lastResult }
Roster.seen = {}

--- Deliberately NOT persisted, like the comms gear store and for the same
--- reason: an inspection is a reading of what someone was wearing at a moment
--- in this session. Restored from SavedVariables a week later it would outrank
--- a fresh site snapshot while looking more authoritative than it is.
local inFlight, lastAttempt = nil, 0

Roster.stats = {
  -- `tried` counts targets PICKED, whatever became of them; `attempted` counts
  -- requests actually SENT. They differ for everyone refused before the request
  -- — offline, out of range — and the difference matters: a sweep whose
  -- remaining people are all out of range does real work and sends nothing, so
  -- measuring progress by `attempted` says it did nothing at all.
  tried = 0,
  attempted = 0, resolved = 0, refused = 0, timedOut = 0, outOfRange = 0,
}

--- What the client actually answered, once, so /la roster can say which API
--- carried the data rather than which one we hoped would.
Roster.api = {}

-- ---------------------------------------------------------------------------
-- Enumerating the group
-- ---------------------------------------------------------------------------

--- Every unit token in the group, including the player.
--- Raid and party use different token families and the player is NOT in the
--- party one — "party1" is the OTHER person — which is the classic way a
--- five-man scan quietly omits whoever is running it.
function Roster.UnitTokens()
  local tokens = {}
  local n = (GetNumGroupMembers and GetNumGroupMembers()) or 0

  if IsInRaid and IsInRaid() then
    for i = 1, n do tokens[#tokens + 1] = "raid" .. i end
    return tokens
  end

  tokens[#tokens + 1] = "player"
  for i = 1, math.max(0, n - 1) do tokens[#tokens + 1] = "party" .. i end
  return tokens
end

local function normalize(name)
  return ns.Comms and ns.Comms.Normalize(name) or (name and name:lower())
end

--- Read name / class / role off the group roster. Free, instant, and available
--- for everyone whether or not they have the addon, which is what makes the
--- "who is here" half work with no cooperation from anybody.
function Roster.Scan()
  local tokens = Roster.UnitTokens()
  local found = {}

  for _, unit in ipairs(tokens) do
    if not UnitExists or UnitExists(unit) then
      local name, realm = UnitName(unit)
      if name and name ~= "" then
        local key = normalize(name)
        local entry = Roster.seen[key] or { attempts = 0, nextTry = 0 }

        entry.name  = name
        entry.realm = realm
        entry.unit  = unit
        entry.guid  = UnitGUID and UnitGUID(unit) or nil
        -- ⚠️ IN A RAID YOU ARE raidN, NOT "player". Testing the token for
        -- "player" only identifies yourself in a PARTY, so in a raid the addon
        -- queued an inspect against its own character — which then sat in the
        -- unresolved list forever, since inspecting yourself answers nothing.
        -- Identity is a NAME question, and it is already answered elsewhere the
        -- same way (Comms.IsSelf).
        entry.isSelf = (ns.Comms and ns.Comms.IsSelf(name)) or (unit == "player")

        local className, classToken = UnitClass(unit)
        entry.class      = className or entry.class
        entry.classToken = classToken or entry.classToken

        if UnitGroupRolesAssigned then
          local role = UnitGroupRolesAssigned(unit)
          if role and role ~= "NONE" then entry.role = role end
        end

        Roster.seen[key] = entry
        found[key] = true
      end
    end
  end

  -- Anyone no longer in the group keeps their entry but loses their unit token.
  -- The entry is NOT deleted: they may have disconnected mid-raid and what we
  -- learned about them is still the best answer if they come back.
  for key, entry in pairs(Roster.seen) do
    if not found[key] then entry.unit = nil end
  end

  return Roster.seen
end

-- ---------------------------------------------------------------------------
-- What is missing
-- ---------------------------------------------------------------------------

--- Does this person still need inspecting? Returns false plus the reason why
--- not, so the report can say "already known" rather than staying silent.
---
--- SOMEONE RUNNING THE ADDON IS NEVER INSPECTED. Their own client tells us the
--- same facts, exactly, for free, and re-reading them over a throttled channel
--- that can fail would only create a way for the two to disagree.
function Roster.NeedsInspect(entry)
  if not entry then return false, "unknown" end
  if not entry.unit then return false, "not in the group" end
  if entry.isSelf then return false, "that is you" end

  local key = normalize(entry.name)
  if ns.Comms and ns.Comms.gear[key] and next(ns.Comms.gear[key]) then
    return false, "reporting live"
  end

  -- ⚠️ PARTIAL GEAR IS NOT RESOLVED, and treating it as resolved is what a live
  -- LFR proved. Inspecting twenty-four strangers returned 0, 1, 2, 4, 6, 12 and
  -- 17 slots — the client answers INSPECT_READY as soon as it has ANYTHING, and
  -- fills the rest in as the item cache warms. The old test was
  -- `next(entry.gear)`, so one slot out of seventeen counted, and those people
  -- were never asked again. Only the four who returned NOTHING got retried,
  -- which is exactly the four that later came back complete.
  --
  -- CONVERGENCE RATHER THAN A HARDCODED COUNT: a target is done when the read
  -- stops IMPROVING, so someone with genuinely empty slots settles just as
  -- surely as someone fully geared, and neither needs a number invented for
  -- them. The floor is a backstop for the case where the first read is already
  -- near-complete.
  if entry.spec and entry.gearCount and
     (entry.gearCount >= GEAR_ENOUGH or (entry.gearStable or 0) >= 2) then
    return false, "inspected"
  end
  return true
end

--- Everyone we know is here but cannot yet describe, with WHY for each.
--- This is the list the panel and /la roster show: a person we cannot resolve
--- is a visible gap, never an absence.
function Roster.Unresolved()
  local out = {}
  for _, entry in pairs(Roster.seen) do
    if entry.unit and not entry.isSelf then
      local needs = Roster.NeedsInspect(entry)
      if needs then
        out[#out + 1] = {
          name = entry.name, class = entry.class,
          attempts = entry.attempts or 0,
          reason = entry.lastResult or "not tried yet",
          inPayload = Roster.InPayload(entry.name),
        }
      end
    end
  end
  table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
  return out
end

function Roster.InPayload(name)
  local byName = ns.Payload and ns.Payload.byName
  return (byName and byName[normalize(name) or ""]) ~= nil
end

--- People in the instance who are NOT in the raid-night export at all — the
--- alts, trials and pugs the payload cannot know about. Before this they were
--- ranked nowhere and mentioned nowhere.
function Roster.AdHoc()
  local out = {}
  for _, entry in pairs(Roster.seen) do
    if entry.unit and not entry.isSelf and not Roster.InPayload(entry.name) then
      out[#out + 1] = entry
    end
  end
  table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
  return out
end

-- ---------------------------------------------------------------------------
-- The inspect queue
-- ---------------------------------------------------------------------------

--- Who to inspect next, or nil. Oldest failure first, so one uninspectable
--- person cannot starve everyone behind them.
function Roster.NextTarget(now)
  local best, bestTry
  for _, entry in pairs(Roster.seen) do
    if Roster.NeedsInspect(entry) and (entry.nextTry or 0) <= now then
      if not best or (entry.nextTry or 0) < bestTry then
        best, bestTry = entry, entry.nextTry or 0
      end
    end
  end
  return best
end

local function scheduleRetry(entry, now, reason)
  entry.attempts = (entry.attempts or 0) + 1
  entry.lastResult = reason
  -- Clamped to the last rung rather than growing without bound: someone
  -- genuinely uninspectable should still be retried occasionally, because the
  -- reason is usually range and range changes.
  local rung = RETRY_LADDER[math.min(entry.attempts, #RETRY_LADDER)]
  entry.nextTry = now + rung
end
Roster.ScheduleRetry = scheduleRetry

--- Try to start one inspection. Returns the entry it targeted, or nil plus why
--- not — every branch names itself, because a scanner that silently does
--- nothing is indistinguishable from a broken one.
function Roster.Step(now)
  now = now or (GetTime and GetTime()) or time()

  if inFlight then
    if (now - inFlight.startedAt) < INSPECT_TIMEOUT then return nil, "waiting" end
    -- ⚠️ A REQUEST THAT NEVER ANSWERS IS THE COMMON CASE, not an anomaly. There
    -- is no failure callback: NotifyInspect on someone out of range simply
    -- never fires INSPECT_READY. Without this timeout the queue stops dead on
    -- the first such person and every later one is never tried.
    Roster.stats.timedOut = Roster.stats.timedOut + 1
    scheduleRetry(inFlight.entry, now, "no answer")
    inFlight = nil
    if ClearInspectPlayer then pcall(ClearInspectPlayer) end
  end

  if (now - lastAttempt) < INSPECT_GAP then return nil, "too soon" end

  local entry = Roster.NextTarget(now)
  if not entry then return nil, "nobody to inspect" end

  Roster.stats.tried = Roster.stats.tried + 1
  if Roster.sweep then Roster.sweep.pending[normalize(entry.name) or ""] = nil end
  lastAttempt = now

  local function refuse(reason)
    scheduleRetry(entry, now, reason)
    if ns.Diagnostics then
      ns.Diagnostics.Note("inspectRefused", {
        who = entry.name, reason = reason, attempt = entry.attempts,
      })
    end
    return nil, reason
  end

  if UnitIsConnected and not UnitIsConnected(entry.unit) then return refuse("offline") end

  -- CanInspect answers range, faction and visibility in one call. Passing false
  -- suppresses the client's own error message, which would otherwise print in
  -- the runner's chat once per attempt per person.
  if CanInspect and not CanInspect(entry.unit, false) then
    Roster.stats.outOfRange = Roster.stats.outOfRange + 1
    return refuse("out of range")
  end

  if not NotifyInspect then return refuse("no inspect API") end

  Roster.stats.attempted = Roster.stats.attempted + 1
  inFlight = { entry = entry, startedAt = now, guid = entry.guid }
  if ns.Diagnostics then
    ns.Diagnostics.Note("inspectSent", {
      who = entry.name, unit = entry.unit, attempt = entry.attempts or 0,
    })
  end
  pcall(NotifyInspect, entry.unit)
  return entry
end

-- ---------------------------------------------------------------------------
-- Reading an inspected unit
-- ---------------------------------------------------------------------------

--- Record which function answered, once per name, so the report can say what
--- carried the data rather than what we assumed would.
local function noteApi(name, ok)
  if Roster.api[name] == nil then Roster.api[name] = ok and true or false end
end

--- The inspected unit's specialization NAME, or nil.
---
--- ⚠️ THE SPEC ID IS ALL THE INSPECT API GIVES, and turning an id into the
--- "Class/Spec" key our data is keyed by needs a name. GetSpecializationInfoByID
--- is the documented route; it is called through pcall and its absence is
--- RECORDED rather than assumed away, because a nil spec here is survivable
--- (the person still ranks on gear) and a wrong one is not.
function Roster.InspectSpec(unit)
  local getId = _G.GetInspectSpecialization
  noteApi("GetInspectSpecialization", getId ~= nil)
  if not getId then return nil end

  local ok, specId = pcall(getId, unit)
  -- ⚠️ RANGE, NOT TRUTHINESS. This API answers 0 when it has nothing, and zero
  -- is truthy in Lua — the exact trap that silently unspecced 18 of 18 logins
  -- in Session 243.
  if not ok or type(specId) ~= "number" or specId < 1 then return nil, specId end

  local byId = _G.GetSpecializationInfoByID
  noteApi("GetSpecializationInfoByID", byId ~= nil)
  if not byId then return nil, specId end

  local ok2, id, name = pcall(byId, specId)
  if not ok2 or not name then return nil, specId end
  return name, specId
end

--- Everything the inspected unit is wearing, as slot -> { ilvl, track, ids }.
--- Same shape as the comms GEAR store and Payload.SlotState, so it drops
--- straight into the provenance chain with no per-source special casing.
--- Returns gear, count, suspect — the last being readings discarded for being
--- impossible this season.
function Roster.InspectGear(unit)
  local gear, count, suspect = {}, 0, 0
  local floor = ladderFloor()
  for slot, invSlots in pairs(ns.SLOT_INV) do
    local worstIlvl, worstLink, ids = nil, nil, {}
    for _, inv in ipairs(invSlots) do
      local link = GetInventoryItemLink and GetInventoryItemLink(unit, inv)
      if link then
        local parsed = ns.ParseItemLink(link)
        if parsed and parsed.itemID then ids[#ids + 1] = parsed.itemID end
        local ilvl = ns.DetailedIlvl(link) or 0
        -- WORST of the competing slots, matching extractSlotState on the site:
        -- the weaker piece is the one that would be replaced.
        if ilvl > 0 and (not worstIlvl or ilvl < worstIlvl) then
          worstIlvl, worstLink = ilvl, link
        end
      end
    end
    if worstIlvl and worstIlvl > 0 then
      if floor and worstIlvl < floor then
        -- Below anything this season can produce. Recorded, never used: an
        -- invented item level reaches the ranking as a confident wrong answer,
        -- while a missing one just leaves them out of that item's list.
        suspect = suspect + 1
      else
        local parsed = ns.ParseItemLink(worstLink)
        gear[slot] = {
          ilvl  = worstIlvl,
          track = ns.ResolveTrack(worstIlvl, parsed and parsed.bonusIDs),
          ids   = #ids > 0 and ids or nil,
        }
        count = count + 1
      end
    end
  end
  return gear, count, suspect
end

--- INSPECT_READY. The event carries a GUID, never a unit token, so the request
--- has to be matched by GUID — a token can point at a different person by the
--- time the answer arrives, which is how an inspect result gets filed against
--- the wrong raider.
function Roster.OnInspectReady(guid)
  if not inFlight then return end
  if inFlight.guid and guid and inFlight.guid ~= guid then return end

  local entry = inFlight.entry
  local unit = entry.unit
  inFlight = nil

  if not unit then return end

  local specName, specId = Roster.InspectSpec(unit)
  local gear, count, suspect = Roster.InspectGear(unit)

  entry.spec   = specName or entry.spec
  entry.specId = specId or entry.specId
  entry.at     = time()

  -- Recorded BEFORE the branch: a read that was ENTIRELY impossible values has
  -- count 0 and would otherwise look identical to a read that returned nothing
  -- at all, which is a different problem with a different fix.
  entry.suspect = suspect

  if count > 0 then
    -- IMPROVEMENT, not replacement. A later read can be WORSE than an earlier
    -- one if the cache went cold again, and overwriting a complete read with a
    -- two-slot one would undo the retry that just paid off.
    local previous = entry.gearCount or 0
    if count >= previous then
      entry.gear = gear
      entry.gearCount = count
    end
    entry.gearStable = (count <= previous) and ((entry.gearStable or 0) + 1) or 0

    Roster.stats.resolved = Roster.stats.resolved + 1
    if Roster.NeedsInspect(entry) then
      -- Answered, but not completely. Keep asking: the item cache warms over
      -- the following seconds and the next read is usually fuller.
      entry.lastResult = ("partial (%d slots)"):format(count)
      scheduleRetry(entry, (GetTime and GetTime()) or time(), entry.lastResult)
    else
      entry.lastResult = specName and "inspected" or "gear only, no spec"
      entry.attempts = 0
      entry.nextTry = 0
    end
  else
    -- Answered, but with nothing usable. Counted apart from a timeout because
    -- it means something quite different: the request WORKED and the data was
    -- not there, which is a cache problem rather than a range one.
    Roster.stats.refused = Roster.stats.refused + 1
    scheduleRetry(entry, (GetTime and GetTime()) or time(), "answered with no gear")
  end

  if ClearInspectPlayer then pcall(ClearInspectPlayer) end

  if ns.Diagnostics then
    ns.Diagnostics.Note("inspectReady", {
      who = entry.name, spec = specName, specId = specId,
      slots = count, suspect = suspect, attempt = entry.attempts or 0,
      result = entry.lastResult,
    })
  end

  if ns.Panel and ns.Panel.Refresh then pcall(ns.Panel.Refresh) end
end

-- ---------------------------------------------------------------------------
-- Provenance
-- ---------------------------------------------------------------------------

--- What we learned in game about one person's slot, or nil.
--- Feeds Payload.SlotState as the "inspected" tier: below a self-report, above
--- the site snapshot.
function Roster.GearFor(name, slot)
  local entry = Roster.seen[normalize(name) or ""]
  local g = entry and entry.gear and entry.gear[slot]
  if not g then return nil end
  return { ilvl = g.ilvl, track = g.track, ids = g.ids, at = entry.at }
end

--- Everyone standing here, whether or not the export knows them, with where
--- each one's information came from. The single list the panel's roster view
--- and /la roster both read, so the two cannot drift.
function Roster.Everyone()
  Roster.Scan()
  local out = {}
  for _, entry in pairs(Roster.seen) do
    if entry.unit then
      local ident = Roster.IdentityFor(entry.name) or {}
      out[#out + 1] = {
        name = entry.name, class = ident.class or entry.class,
        spec = ident.spec, heroTree = ident.heroTree,
        source = ident.source or "group",
        inPayload = Roster.InPayload(entry.name),
        hasGear = Roster.HasGear(entry.name),
        reason = entry.lastResult,
      }
    end
  end
  table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
  return out
end

--- Who this person is, best source first.
---
--- A SELF-REPORT BEATS AN INSPECTION, always, and not on recency. Their own
--- client reads its own specialization directly; our inspection reads it across
--- the network, can be refused, and can answer from a cold cache. When both
--- exist they will normally agree — and when they do not, the one that cannot
--- be out of range is the one to believe.
function Roster.IdentityFor(name)
  local key = normalize(name) or ""

  local told = ns.Comms and ns.Comms.identity[key]
  if told and told.class and told.spec then
    return { class = told.class, spec = told.spec, heroTree = told.heroTree,
             source = "reported" }
  end

  local entry = Roster.seen[key]
  if entry and entry.class and entry.spec then
    return { class = entry.class, spec = entry.spec, heroTree = entry.heroTree,
             source = "inspected" }
  end

  -- Class alone is still worth returning: it comes free from the group roster
  -- and is enough to colour a name and to say who is standing there, even when
  -- nothing can be scored for them.
  if entry and entry.class then
    return { class = entry.class, source = "group" }
  end
  return nil
end

--- Do we have any gear at all for this person, from any source? The gate on
--- ranking an ad-hoc raider: class and spec cannot score an item on their own.
function Roster.HasGear(name)
  local key = normalize(name) or ""
  local live = ns.Comms and ns.Comms.gear[key]
  if live and next(live) then return true end
  local entry = Roster.seen[key]
  return (entry and entry.gear and next(entry.gear)) ~= nil
end

--- Their spec as OBSERVED in game, which is NOT necessarily the spec they
--- should be scored as.
---
--- ⚠️ THIS DOES NOT OVERRIDE THE ROSTER, and that is a rule rather than a
--- preference. rules/HoD_Rules_Loot-Gear.txt "SCORE THE SPEC THEY RAID, NEVER
--- THE ONE THEY WERE LAST AUDITED IN" exists because a live observation caught
--- three raiders mid-delve and mis-scored every one of them — a healer as DPS,
--- a DPS as a tank. An inspect is exactly such an observation, taken at a
--- better moment but by the same method.
--- So an observed spec is REPORTED as a discrepancy for an officer to act on,
--- and is used for SCORING only when the person is not on the roster at all,
--- where it is the only answer that exists.
function Roster.SpecDiscrepancies()
  local out = {}
  local byName = ns.Payload and ns.Payload.byName
  if not byName then return out end

  for key, entry in pairs(Roster.seen) do
    local r = byName[key]
    if r and entry.spec and r.s and entry.spec ~= r.s then
      out[#out + 1] = { name = entry.name, roster = r.s, observed = entry.spec }
    end
  end
  table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
  return out
end

-- ---------------------------------------------------------------------------
-- Driving it
-- ---------------------------------------------------------------------------

local ticker, frame

function Roster.Start()
  if frame then return end
  frame = CreateFrame("Frame")
  frame:RegisterEvent("INSPECT_READY")
  frame:RegisterEvent("GROUP_ROSTER_UPDATE")
  -- Zoning into the instance is the moment the raid is actually assembled and
  -- in range of each other, which is the best moment to sweep.
  frame:RegisterEvent("PLAYER_ENTERING_WORLD")
  frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "INSPECT_READY" then
      Roster.OnInspectReady(arg1)
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
      -- ⚠️ KICK, NOT JUST SCAN. The pump exits without rescheduling when there
      -- is no group, which is the state at almost every login — so a Kick at
      -- load ran once, found nothing, and the pump was DEAD from then on. In a
      -- live LFR that showed as "0 resolved of 0 attempted" with twenty-four
      -- people sitting in the unresolved list, and only a manual scan revived
      -- it. Joining a group is exactly when it needs to start.
      Roster.Scan()
      Roster.Kick()
    end
  end)
end

--- One pass of the pump: re-read the group, try one inspection, schedule the
--- next pass. Runs only while there is a group and something left to resolve,
--- so a solo player pays nothing.
function Roster.Pump()
  ticker = nil
  if not (ns.Comms and ns.Comms.Channel()) then return end

  Roster.Scan()
  Roster.Step()

  local now = (GetTime and GetTime()) or time()
  local left = Roster.Unresolved()

  -- ⚠️ "DONE" IS NOT "EVERYONE RESOLVED". Some people genuinely cannot be
  -- inspected right now — out of range across a raid room, offline, a client
  -- that never answers — and waiting for the list to empty means waiting
  -- forever. A pass is finished when there is nobody left to TRY, which is a
  -- state that actually arrives.
  local eligible = Roster.NextTarget(now)

  -- The sweep can finish while there is still plenty to do — everyone got a
  -- turn, and the ones that failed are simply queued to be asked again. So the
  -- report is checked here rather than only on the way out.
  if Roster.announceWhenDone and Roster.sweep and next(Roster.sweep.pending) == nil then
    Roster.announceWhenDone = nil
    Roster.sweep = nil
    local st = Roster.stats
    if #left == 0 then
      ns.Print(("everyone here is resolved — %d inspected."):format(st.resolved))
    else
      ns.Print(("done for now: %d resolved, %d still out of reach — %s."):format(
        st.resolved, #left, Roster.ReasonSummary(left)))
      ns.Line("     |cff888899They rank from the site snapshot meanwhile, and are retried "
        .. "automatically as they come into range.|r")
    end
  end

  if eligible then
    ticker = now + INSPECT_GAP   -- when the next pass is DUE
    C_Timer.After(INSPECT_GAP, Roster.Pump)
    return
  end

  -- ⚠️ A SWEEP THAT FINISHES SILENTLY IS INDISTINGUISHABLE FROM ONE THAT NEVER
  -- RAN. "/la roster scan" answered "retrying 24 raiders now" and then said
  -- nothing ever again, because the work happens in the background over the
  -- following minute — so from outside, a sweep that was working looked exactly
  -- like one that did nothing. Reported ONCE, and only when somebody asked.
  if ns.Diagnostics then
    local s = Roster.stats
    ns.Diagnostics.Note("inspectSweepDone", {
      resolved = s.resolved, attempted = s.attempted, outOfRange = s.outOfRange,
      timedOut = s.timedOut, refused = s.refused, left = #left,
      reasons = Roster.ReasonSummary(left),
    })
  end

  if Roster.announceWhenDone and Roster.sweep and next(Roster.sweep.pending) == nil then
    Roster.announceWhenDone = nil
    Roster.sweep = nil
    local s = Roster.stats
    if #left == 0 then
      ns.Print(("everyone here is resolved — %d inspected."):format(s.resolved))
    else
      ns.Print(("done for now: %d resolved, %d still out of reach — %s."):format(
        s.resolved, #left, Roster.ReasonSummary(left)))
      ns.Line("     |cff888899They rank from the site snapshot meanwhile, and are retried "
        .. "automatically as they come into range.|r")
    end
  end

  if #left == 0 then return end

  -- Nobody is eligible YET but people are still outstanding, so sleep until the
  -- earliest of them comes due rather than waking every couple of seconds to
  -- find the same answer. The usual reason is range, and range changes.
  local soonest
  for _, entry in pairs(Roster.seen) do
    if Roster.NeedsInspect(entry) then
      local t = entry.nextTry or 0
      if not soonest or t < soonest then soonest = t end
    end
  end
  if soonest then
    local delay = math.max(INSPECT_GAP, soonest - now)
    -- Stamped with when it will FIRE, not when it was scheduled, so a long
    -- sleep waiting for a backoff rung is not mistaken for a wedged pump.
    ticker = now + delay
    C_Timer.After(delay, Roster.Pump)
  end
end

--- "3 out of range, 1 offline" — the shape of what is left, so a runner can
--- tell "they are across the room" from "the feature is broken".
function Roster.ReasonSummary(list)
  local counts, order = {}, {}
  for _, u in ipairs(list or Roster.Unresolved()) do
    local r = u.reason or "not tried yet"
    if not counts[r] then order[#order + 1] = r end
    counts[r] = (counts[r] or 0) + 1
  end
  table.sort(order)
  local parts = {}
  for _, r in ipairs(order) do parts[#parts + 1] = ("%d %s"):format(counts[r], r) end
  return table.concat(parts, ", ")
end

--- Kick the pump. Safe to call repeatedly — it will not stack tickers.
--- ⚠️ THE GUARD IS STALENESS, NOT A BARE FLAG. `ticker` records WHEN the next
--- pump was scheduled rather than merely that it was, so a scheduled pass that
--- is somehow never delivered — an error inside a timer callback, a reload
--- landing between two of them — cannot wedge the pump permanently. A bare
--- flag makes that state unrecoverable: Kick refuses because it believes the
--- pump is running, and nothing is running. This addon already lost a whole
--- LFR wing to a pump that stopped and could not be restarted; that one was a
--- missing event, and this is the other way to reach the same dead end.
--- ⚠️ `ticker` HOLDS THE TIME THE NEXT PASS IS DUE, and the guard is "due
--- recently or still to come", with a grace period after.
---
--- The first version stored the time the pass was SCHEDULED and asked whether
--- that was recent — which is wrong for a long sleep. Waiting out a five-minute
--- backoff rung stamps a time five minutes ahead, `now - ticker` is NEGATIVE,
--- and negative is less than any window, so the pump read as "currently
--- running" for the whole sleep. If that pass was then lost — a cleared timer,
--- an error inside the callback — Kick refused to restart it until the clock
--- caught up. Which is the exact wedge this guard was added to prevent,
--- reintroduced by measuring from the wrong end.
local function scheduled()
  if not ticker then return false end
  local now = (GetTime and GetTime()) or time()
  return now <= (ticker + INSPECT_GAP * 2)
end

--- A SWEEP IS "EVERYONE GOT A TURN", NOT "NOBODY IS DUE RIGHT NOW".
---
--- ⚠️ The first definition was the latter and it was wrong by construction.
--- Failures are never given up on, so somebody is due again almost immediately
--- — which makes "nobody eligible" a narrow timing window rather than a state,
--- and whether the completion line appeared depended on exactly when the last
--- pass happened to land. It failed about one harness run in twenty and would
--- have been far worse in game, where a raid is never still.
---
--- The set below is the people who were unresolved when the sweep was asked
--- for. Each is struck off when it gets a turn, whatever the outcome. Empty
--- means every one of them has been tried, which is a fact rather than a
--- coincidence of timing.
local function beginSweep()
  local pending, n = {}, 0
  for _, u in ipairs(Roster.Unresolved()) do
    pending[normalize(u.name) or ""] = true
    n = n + 1
  end
  Roster.sweep = (n > 0) and { pending = pending, count = n } or nil
  return n
end

--- `announce` asks for a line when this sweep finishes.
---
--- ⚠️ IT REMEMBERS HOW MUCH WORK HAD BEEN DONE WHEN IT WAS ASKED, not merely
--- that it was asked. A pump already in flight would otherwise consume the flag
--- on its CURRENT pass — reporting "done" before a single one of the retries
--- the user just requested had run, and then staying silent through the sweep
--- that mattered. Which of those happened depended on pairs() ordering, so it
--- was intermittent, which is the worst way for it to be wrong.
--- `force` bypasses the already-running guard.
---
--- ⚠️ A DELIBERATE PRESS MUST NEVER BE VETOED BY A BACKGROUND TICKER. The guard
--- exists to stop automatic kicks stacking passes on top of each other, and
--- applying it to a human asking is a category error: they get silence, and the
--- addon believes something is running when the pass may well have been lost.
--- Two overlapping passes are harmless — Step is already gated by its own
--- pacing and by the single in-flight request — while a refused manual scan is
--- the feature not working.
function Roster.Kick(announce, force)
  if announce then
    Roster.announceWhenDone = true
    beginSweep()
  end
  if not force and scheduled() then return false, "already running" end
  ticker = (GetTime and GetTime()) or time()   -- due immediately
  C_Timer.After(0, Roster.Pump)
  return true
end

-- ---------------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------------

function Roster.Status()
  Roster.Scan()

  local here = 0
  for _, e in pairs(Roster.seen) do if e.unit then here = here + 1 end end

  ns.Print(("roster: %d in the group"):format(here))
  if here == 0 then
    ns.Line("|cff888899Not in a group — nothing to resolve.|r")
    return
  end

  local s = Roster.stats
  ns.Line(("Inspected: %d resolved of %d attempted · %d out of range · %d no answer · %d empty")
    :format(s.resolved, s.attempted, s.outOfRange, s.timedOut, s.refused))

  local adhoc = Roster.AdHoc()
  if #adhoc > 0 then
    -- The people the export could not know about. Named, because "who is that"
    -- is the question a runner has when a name they do not recognise appears
    -- in a ranking.
    local names = {}
    for _, e in ipairs(adhoc) do
      names[#names + 1] = e.name .. (e.spec and (" (" .. e.spec .. ")") or "")
    end
    ns.Line(("Not on the raid-night export: %d — %s"):format(#adhoc, table.concat(names, ", ")))
  end

  local missing = Roster.Unresolved()
  if #missing == 0 then
    ns.Line("|cff20ba56Everyone here is resolved.|r")
  else
    ns.Line(("|cffF3C56BStill unresolved: %d|r"):format(#missing))
    for i = 1, math.min(8, #missing) do
      local m = missing[i]
      ns.Line(("     %s — %s%s"):format(m.name, m.reason,
        m.inPayload and "" or " |cff888899(and not on the export)|r"))
    end
    if #missing > 8 then ns.Line(("     and %d more"):format(#missing - 8)) end
    ns.Line("     |cff888899They still rank from the site snapshot — /la roster scan to retry now.|r")
  end

  local drift = Roster.SpecDiscrepancies()
  if #drift > 0 then
    -- Reported, never applied. See SpecDiscrepancies for why.
    ns.Warn(("%d raider%s specced differently to the roster:")
      :format(#drift, #drift == 1 and " is" or "s are"))
    for _, d in ipairs(drift) do
      ns.Line(("     %s — roster says %s, playing %s"):format(d.name, d.roster, d.observed))
    end
    ns.Line("     |cff888899Scoring still uses the roster spec. Tell an officer if it is wrong.|r")
  end
end

--- Dump what the client actually answers, for diagnosing a raid night where
--- inspection did not work. Reports which functions EXIST as well as what they
--- returned, because "the API is missing" and "the API said no" need different
--- fixes and look identical from the outside.
function Roster.Probe()
  ns.Print("inspect probe — what this client actually offers:")
  local names = {
    "NotifyInspect", "CanInspect", "ClearInspectPlayer", "GetInspectSpecialization",
    "GetSpecializationInfoByID", "UnitGUID", "UnitIsConnected", "GetNumGroupMembers",
    "UnitGroupRolesAssigned", "GetInventoryItemLink",
  }
  for _, n in ipairs(names) do
    ns.Line(("  %-26s %s"):format(n,
      _G[n] and "|cff20ba56present|r" or "|cffff4444ABSENT|r"))
  end

  for name, ok in pairs(Roster.api) do
    ns.Line(("  answered: %-22s %s"):format(name, ok and "yes" or "no"))
  end

  local tokens = Roster.UnitTokens()
  ns.Line(("Group tokens: %d — %s"):format(#tokens,
    #tokens > 0 and table.concat(tokens, " ", 1, math.min(6, #tokens)) or "none"))
end

function Roster.Command(sub, rest)
  sub = (sub or ""):lower()

  if sub == "" or sub == "status" then
    Roster.Status()
  elseif sub == "scan" then
    -- A DELIBERATE PRESS CLEARS THE BACKOFF. The ladder exists to stop the
    -- automatic pump hammering someone uninspectable; a human asking is a
    -- different thing, and making them wait out a five-minute rung would make
    -- the manual trigger useless in exactly the moment it is wanted.
    Roster.Scan()
    local n = 0
    for _, e in pairs(Roster.seen) do
      if Roster.NeedsInspect(e) then e.nextTry = 0 n = n + 1 end
    end
    -- Through Kick, so the flag records how much work had been done when it was
    -- asked for. Setting it directly here stored a BOOLEAN where the completion
    -- guard expects a count, and the comparison threw — inside a timer, where
    -- Lua's error surfaces as the pump simply stopping.
    Roster.Kick(true, true)
    if n == 0 then
      Roster.announceWhenDone = nil
      Roster.sweep = nil
      ns.Print("nothing to retry — everyone here is already resolved.")
    else
      ns.Print(("retrying %d unresolved raider%s — one every %.0fs, so this takes about %ds. "
        .. "You will get a line when it finishes."):format(
        n, n == 1 and "" or "s", INSPECT_GAP, math.ceil(n * INSPECT_GAP)))
    end
  elseif sub == "probe" then
    Roster.Probe()
  else
    ns.Warn("unknown: /la roster " .. sub)
    ns.Line("|cffF3C56B/la roster|r — status · scan · probe")
  end
end
