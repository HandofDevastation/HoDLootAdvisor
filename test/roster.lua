-- test/roster.lua — a raid full of strangers, none of them in the export.
--
--   cd loot-advisor-addon
--   lua test/roster.lua
--
-- Models the hardest real case there is, and the one an LFR wing produces
-- exactly: twenty-odd people in a raid instance, NONE on the raid-night export,
-- NONE running the addon. Everything has to come from the group roster and from
-- inspection, and inspection has to cope with the three ways it fails.
--
-- ⚠️ THE FAILURES ARE THE POINT. A harness where every inspect succeeds proves
-- only that the happy path compiles. The fixture below deliberately contains
-- someone out of range, someone offline, someone whose client never answers at
-- all (NotifyInspect succeeds and INSPECT_READY never fires — the failure mode
-- with no callback), and someone who answers with an empty cache. Each has a
-- different correct response and a different reason string.
--
-- What this CANNOT prove is whether Blizzard lets you inspect a stranger in
-- LFR, how far inspect range really is, or whether hero talents are readable
-- for another player. Those are facts about the client. /la roster probe and a
-- real LFR wing answer them; this proves the queue behaves whatever they say.

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

stub.Install()

local realPrint = _G.print
local muted = true
_G.print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  local line = table.concat(parts, " ")
  stub.printed[#stub.printed + 1] = line
  if not muted then realPrint((line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))) end
end

local ns = stub.LoadAddon({
  "LootData.lua", "Style.lua", "Scoring.lua", "Core.lua", "Settings.lua",
  "Payload.lua", "Diagnostics.lua", "Comms.lua", "Roster.lua", "Journal.lua",
  "Targets.lua", "Tooltip.lua", "Record.lua", "Loot.lua",
})
stub.Fire("ADDON_LOADED", "HoDLootAdvisor")

local Roster = ns.Roster

-- ── The wing ────────────────────────────────────────────────────────────────
-- Named for what each one is TESTING, so a failure says which case broke.

local function stranger(name, opts)
  opts = opts or {}
  local e = {
    name = name, realm = "Area 52",
    class = opts.class or "Hunter", classToken = opts.classToken or "HUNTER",
    guid = "Player-" .. name, role = "DAMAGER",
    connected = opts.connected ~= false,
    inspectable = opts.inspectable ~= false,
    silent = opts.silent or false,
    specId = opts.specId, specName = opts.specName,
    equipped = opts.equipped or {},
  }
  return e
end

-- ⚠️ DETERMINISTIC ON PURPOSE. The first version walked pairs(stub.SLOTS) and
-- took the first N, which is hash order — so "give them one slot" sometimes
-- picked INVSLOT_BODY or INVSLOT_TABARD, neither of which the addon tracks as
-- gear. The partial read then contained NOTHING, took a different branch, and
-- the test failed roughly one run in twenty. A fixture whose contents depend on
-- hash order is not a fixture.
local GEAR_SLOTS = {}
for name, inv in pairs(stub.SLOTS) do
  if name ~= "INVSLOT_BODY" and name ~= "INVSLOT_TABARD" then
    GEAR_SLOTS[#GEAR_SLOTS + 1] = inv
  end
end
table.sort(GEAR_SLOTS)

local function gearSet(ilvl, only)
  local eq = {}
  for i, inv in ipairs(GEAR_SLOTS) do
    if not only or i <= only then eq[inv] = { itemID = 270160, ilvl = ilvl } end
  end
  return eq
end

stub.group = {
  stranger("Normalguy",  { specId = 254, specName = "Marksmanship", equipped = gearSet(308) }),
  stranger("Faraway",    { inspectable = false }),
  stranger("Loggedoff",  { connected = false }),
  stranger("Neveranswers", { silent = true }),
  stranger("Coldcache",  { specId = 254, specName = "Marksmanship", equipped = {} }),
  -- ⚠️ THE CASE A LIVE LFR FOUND. The client answers INSPECT_READY as soon as
  -- it has ANYTHING and fills the rest in as its item cache warms, so a first
  -- read of two slots out of seventeen is completely normal. Treating that as
  -- resolved is what left twenty-four strangers half-read and never asked
  -- again.
  stranger("Warmingup",  { specId = 254, specName = "Marksmanship",
                           equipped = gearSet(308, 2) }),
  -- A base-item-level read from a cold cache: far below anything this season
  -- can drop. Live, this became "+160 ilvl" on a 279 helm.
  stranger("Basegear",   { specId = 254, specName = "Marksmanship",
                           equipped = gearSet(9) }),
  -- Deliberately UNDERGEARED: `ranked` holds upgrades only, so a stranger in
  -- better gear than the drop is correctly absent from it and would make the
  -- ad-hoc ranking check below pass or fail for the wrong reason.
  stranger("Alsofine",   { specId = 253, specName = "Beast Mastery", equipped = gearSet(280) }),
}
stub.inRaid, stub.inGroup = true, false

local function pump(rounds, maxDelay)
  local ran = 0
  for _ = 1, rounds or 200 do
    local n = stub.RunTimers(maxDelay)
    if n == 0 then break end
    ran = ran + n
  end
  return ran
end

--- Drive ONE inspection of one person through the real path: clear their
--- backoff, move the clock past the pacing gap, let Step issue the request, and
--- run the timer that delivers INSPECT_READY.
---
--- Deliberately NOT calling OnInspectReady directly — it ignores an answer it
--- never asked for, which is correct (a stale reply must not be filed against
--- whoever is being inspected now) and means a direct call proves nothing.
local function inspectOnce(entry)
  -- ⚠️ CLEAR PENDING TIMERS FIRST. The background pump is still scheduled from
  -- earlier sections, and running it here would inspect this person several
  -- more times — converging exactly the partial state being examined. The point
  -- is to see ONE answer, not the settled result of many.
  stub.timers = {}
  if stub.active then stub.active.timers = stub.timers end

  entry.nextTry = 0
  stub.clock = stub.clock + 10
  Roster.Step()
  pump(20)
end

-- ═══════════════════════════════════════════════════════════════════════════
header("seeing who is here")
-- ═══════════════════════════════════════════════════════════════════════════

do
  local tokens = Roster.UnitTokens()
  check("a raid enumerates raid tokens", tokens[1] == "raid1", tokens[1])
  check("...one per member, including yourself", #tokens == #stub.group + 1, #tokens)

  Roster.Scan()
  local here = 0
  for _, e in pairs(Roster.seen) do if e.unit then here = here + 1 end end
  check("everyone in the instance is seen, with no addon and no export",
        here == #stub.group + 1, here)

  local entry = Roster.seen["normalguy"]
  check("class comes free from the group roster",
        entry ~= nil and entry.class == "Hunter", entry and entry.class)
  check("...and so does a GUID, which is how an inspect result is matched back",
        entry.guid == "Player-Normalguy", entry.guid)

  -- ⚠️ A PARTY DOES NOT INCLUDE YOU IN ITS TOKENS. "party1" is the OTHER
  -- person, so a scan that walks party1..N and stops silently omits whoever is
  -- running the addon — and they are the one person always present.
  stub.inRaid, stub.inGroup = false, true
  local partyTokens = Roster.UnitTokens()
  check("a party scan includes the player explicitly", partyTokens[1] == "player")
  check("...and does not run off the end", #partyTokens == #stub.group + 1, #partyTokens)
  stub.inRaid, stub.inGroup = true, false
end

-- ═══════════════════════════════════════════════════════════════════════════
header("nobody here is on the export")
-- ═══════════════════════════════════════════════════════════════════════════

do
  -- No payload loaded at all, which is the LFR case exactly.
  check("with no export, nobody is 'in the payload'", Roster.InPayload("Normalguy") == false)
  -- Everyone EXCEPT you: in a raid the player is raidN rather than "player", so
  -- an addon that identifies itself by token lists its own character as a
  -- stranger and then tries to inspect it.
  check("...so every OTHER person present is ad-hoc",
        #Roster.AdHoc() == #stub.group, #Roster.AdHoc())
  check("...and that is everyone the wing contains", #stub.group == 8, #stub.group)

  -- ⚠️ AND NOBODY IS RANKED YET, because we know nothing about their gear.
  -- Ranking them now would put strangers in the list at ilvl 0, which the
  -- scorer reads as an empty slot — making every drop a maximum upgrade for
  -- every one of them.
  -- ⚠️ THE COUNT WAS A PROXY AND IT BROKE (Session 256). This asserted the list
  -- was EMPTY, which was true only because a missing export emptied it outright
  -- — the same list is now built from the group, so YOU are in it. The property
  -- worth pinning was never "the list is empty", it is that a stranger we cannot
  -- describe is not in it, so that is what is asserted now.
  local eff = ns.Payload.EffectiveRoster()
  local strangersRanked = 0
  for _, r in ipairs(eff) do
    if not r.me then strangersRanked = strangersRanked + 1 end
  end
  check("an ad-hoc raider with no gear is NOT ranked", strangersRanked == 0, strangersRanked)
  check("...but the player is, from their own client",
        #eff == 1 and eff[1].me == true, #eff)
  check("...but IS listed as unresolved, so they are visible rather than absent",
        #Roster.Unresolved() == #stub.group, #Roster.Unresolved())
end

-- ═══════════════════════════════════════════════════════════════════════════
header("the pump has to survive being started with no group")
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ⚠️ THE DEFECT THIS PINS COST A WHOLE LFR WING. The pump exits without
-- rescheduling when there is no group — which is the state at almost every
-- login — so the Kick at load ran once, found nothing, and the pump was dead
-- from then on. GROUP_ROSTER_UPDATE only rescanned; it never restarted it. In
-- the live run that read as "0 resolved of 0 attempted" with twenty-four people
-- listed as unresolved, and only a manual scan revived it.

do
  -- Login, solo. Exactly the order the real client produces.
  stub.inRaid, stub.inGroup = false, false
  ns.Roster.Kick()
  pump(50)
  check("with no group the pump stops rather than spinning", true)

  -- The raid assembles.
  stub.inRaid = true
  Roster.stats.attempted = 0
  stub.Fire("GROUP_ROSTER_UPDATE")
  pump(30)

  check("joining a group restarts the pump by itself",
        Roster.stats.attempted > 0, Roster.stats.attempted)

  -- Reset for the sections below, which drive it deliberately.
  for _, e in pairs(Roster.seen) do
    e.gear, e.spec, e.attempts, e.nextTry, e.lastResult = nil, nil, 0, 0, nil
  end
  Roster.stats.attempted, Roster.stats.resolved, Roster.stats.tried = 0, 0, 0
  Roster.stats.outOfRange, Roster.stats.timedOut, Roster.stats.refused = 0, 0, 0
end

-- ═══════════════════════════════════════════════════════════════════════════
header("the inspect queue, including all three ways it fails")
-- ═══════════════════════════════════════════════════════════════════════════

do
  Roster.Kick()
  pump(600)

  local seen = Roster.seen

  check("someone in range and connected resolves",
        seen["normalguy"].gear ~= nil and seen["normalguy"].spec == "Marksmanship",
        seen["normalguy"].lastResult)
  check("...and a second one does too, so the queue moves on rather than sticking",
        seen["alsofine"].gear ~= nil, seen["alsofine"].lastResult)
  check("...with the item level actually read off them, not defaulted to zero",
        (seen["alsofine"].gear.CHEST or {}).ilvl == 280,
        seen["alsofine"].gear.CHEST and seen["alsofine"].gear.CHEST.ilvl)

  -- Each failure gets its OWN reason. "It did not work" is not a diagnosis, and
  -- these four need four different responses from a runner.
  check("out of range is named as such",
        seen["faraway"].lastResult == "out of range", seen["faraway"].lastResult)
  check("offline is named as such",
        seen["loggedoff"].lastResult == "offline", seen["loggedoff"].lastResult)
  check("a request that never answers times out rather than stalling the queue",
        seen["neveranswers"].lastResult == "no answer", seen["neveranswers"].lastResult)
  check("an answer with an empty cache is distinguished from no answer at all",
        seen["coldcache"].lastResult == "answered with no gear", seen["coldcache"].lastResult)

  -- ⚠️ THE STALL IS THE FAILURE THAT MATTERS. NotifyInspect on someone out of
  -- range never fires INSPECT_READY and there is no error callback, so without
  -- a timeout the queue stops on the first such person and NOBODY after them is
  -- ever tried. Both people who CAN resolve sit after the silent one in the
  -- fixture, so if the timeout were removed they would still be unknown.
  check("people queued BEHIND a silent target still got their turn",
        seen["alsofine"].gear ~= nil)

  -- ⚠️ THE ADDON MUST NEVER INSPECT ITS OWN CHARACTER. In a raid you are raidN,
  -- not "player", so a self-check written against the token identifies you only
  -- in a PARTY — and in a raid the queue would fire an inspect at yourself,
  -- which answers nothing, and then retry it forever on the ladder.
  local meKey = ns.Comms.Normalize(stub.player.name)
  check("your own entry is marked as you", Roster.seen[meKey].isSelf == true)
  check("...so you are never queued for inspection",
        Roster.NeedsInspect(Roster.seen[meKey]) == false,
        select(2, Roster.NeedsInspect(Roster.seen[meKey])))
  local inspectedSelf = false
  for _, unit in ipairs(stub.inspectCalls) do
    local e = stub.UnitEntry(unit)
    if e and e.name == stub.player.name then inspectedSelf = true end
  end
  check("...and no inspect was ever actually sent at you", inspectedSelf == false)

  check("everything that failed is scheduled to be retried, not written off",
        (seen["faraway"].nextTry or 0) > 0 and (seen["neveranswers"].nextTry or 0) > 0)
  check("...and nobody is ever permanently given up on",
        Roster.NeedsInspect(seen["faraway"]) == true)
end

-- ═══════════════════════════════════════════════════════════════════════════
header("a partial read is not a finished one")
-- ═══════════════════════════════════════════════════════════════════════════

do
  -- Driven ONE READ AT A TIME. Left to the pump this converges — a read that
  -- stops improving is accepted, which is the design — so the state to inspect
  -- is the one immediately after the FIRST answer, before the retries settle.
  local warm = Roster.seen["warmingup"]
  warm.gear, warm.gearCount, warm.gearStable, warm.lastResult = nil, nil, nil, nil
  warm.attempts, warm.nextTry = 0, 0
  inspectOnce(warm)

  check("a partial read is recorded", (warm.gearCount or 0) > 0, warm.gearCount)
  check("...but is NOT treated as resolved",
        Roster.NeedsInspect(warm) == true,
        select(2, Roster.NeedsInspect(warm)))
  check("...and says so, naming how much it got",
        (warm.lastResult or ""):find("partial") ~= nil, warm.lastResult)
  check("...and is scheduled to be asked again", (warm.nextTry or 0) > 0)

  -- The cache warms; the next read is complete.
  local partial = warm.gearCount
  for _, inv in pairs(stub.SLOTS) do
    stub.group[6].equipped[inv] = { itemID = 270160, ilvl = 308 }
  end
  inspectOnce(warm)
  check("a later, fuller read completes it",
        Roster.NeedsInspect(warm) == false, warm.lastResult)
  check("...and the fuller reading is the one kept",
        (warm.gearCount or 0) > partial and warm.gearCount >= 12, warm.gearCount)

  -- ⚠️ A WORSE LATER READ MUST NOT UNDO A GOOD ONE. The cache can go cold
  -- again, and overwriting seventeen slots with two would throw away exactly
  -- the retry that just paid off.
  -- ⚠️ THE REGRESSION CASE HAS TO BE ONE THAT CAN ACTUALLY OCCUR. A person
  -- already marked resolved is never re-inspected, so making the stub answer
  -- thinner for THEM proves nothing — the first version of this check passed
  -- with the fix reverted for exactly that reason. What really happens is a
  -- PARTIAL read being retried and the retry coming back with less, because the
  -- item cache went cold again. Put them back in that state.
  warm.gearCount, warm.gearStable = 5, 0
  warm.lastResult, warm.attempts, warm.nextTry = "partial (5 slots)", 0, 0
  local before = warm.gearCount
  check("...and they are back in a state that gets retried",
        Roster.NeedsInspect(warm) == true)

  stub.group[6].equipped = gearSet(308, 1)
  inspectOnce(warm)
  check("a thinner later read does not replace a fuller one",
        warm.gearCount == before, warm.gearCount)
  check("...and a read that did not improve counts toward settling",
        (warm.gearStable or 0) > 0, warm.gearStable)

  -- Put them back together for the sections below, which expect a raid where
  -- the resolvable people are resolved.
  for _, inv in pairs(stub.SLOTS) do
    stub.group[6].equipped[inv] = { itemID = 270160, ilvl = 308 }
  end
  inspectOnce(warm)
  check("...and a full read afterwards still resolves them",
        Roster.NeedsInspect(warm) == false, warm.lastResult)

  -- The impossible reading.
  local base = Roster.seen["basegear"]
  check("an item level below this season's ladder is discarded, not ranked",
        base.gear == nil or next(base.gear) == nil,
        base.gear and base.gearCount)
  check("...and counted as suspect rather than silently dropped",
        (base.suspect or 0) > 0, base.suspect)
end

-- ═══════════════════════════════════════════════════════════════════════════
header("what a resolved stranger becomes")
-- ═══════════════════════════════════════════════════════════════════════════

do
  local gear = Roster.GearFor("Normalguy", "CHEST")
  check("their gear is readable by slot", gear ~= nil and gear.ilvl == 308,
        gear and gear.ilvl)
  check("...with a track resolved off the item level, same as everyone else",
        gear.track ~= nil, gear and tostring(gear.track))

  local ident = Roster.IdentityFor("Normalguy")
  check("their identity resolves from the inspection",
        ident ~= nil and ident.spec == "Marksmanship" and ident.source == "inspected",
        ident and ident.source)

  check("someone we could not inspect has class but no spec",
        (Roster.IdentityFor("Faraway") or {}).spec == nil)
  check("...and is still named, because class comes free",
        (Roster.IdentityFor("Faraway") or {}).class == "Hunter")

  check("a resolved stranger now HAS gear by the roster's own test",
        Roster.HasGear("Normalguy") == true)
  check("...and an unresolved one does not", Roster.HasGear("Faraway") == false)
end

-- ═══════════════════════════════════════════════════════════════════════════
header("a self-report always beats an inspection")
-- ═══════════════════════════════════════════════════════════════════════════

do
  -- Their own client speaks. Fed through the REAL comms path from a sender
  -- named as them, so the sender normalization is part of what is under test.
  ns.Comms.Handle(
    ns.Comms.Encode("GEAR", 1, 1, "@,Hunter,Beast Mastery,Pack Leader;CHEST,321,Myth"),
    "RAID", "Normalguy")

  local ident = Roster.IdentityFor("Normalguy")
  -- NOT on recency: their own client reads its own specialization directly,
  -- while ours reads it across the network and can answer from a cold cache.
  check("a self-reported identity outranks the inspected one",
        ident.spec == "Beast Mastery" and ident.source == "reported", ident.source)
  check("...including the hero tree, which inspection may not be able to give at all",
        ident.heroTree == "Pack Leader", ident.heroTree)

  check("and we stop inspecting someone who is telling us directly",
        Roster.NeedsInspect(Roster.seen["normalguy"]) == false,
        select(2, Roster.NeedsInspect(Roster.seen["normalguy"])))
end

-- ═══════════════════════════════════════════════════════════════════════════
header("the whole group ranked with NO export at all")
-- ═══════════════════════════════════════════════════════════════════════════
--
-- THE CASE THIS FILE ALREADY MODELS, with the export never arriving: anyone
-- outside this guild, and any pug or LFR night, where nobody imports anything
-- ever. Until Session 256 the ranked table was dead here — the roster builder
-- and the ranker BOTH returned nothing without a payload — so the addon showed a
-- personal column and pointed at an Import Raid Night button for data that was
-- never coming. Everything the group half needs was already working and simply
-- never reached.
--
-- ⚠️ IT RUNS BEFORE THE SCENARIO BELOW, which loads the export and cannot be
-- undone. Order is load-bearing here.

do
  local dataT = _G.HoDLootAdvisorData
  local noExportChest
  for id, it in pairs(dataT.items) do
    if it.slot == "CHEST" and it.classes and it.classes["Hunter"] then
      noExportChest = id
      break
    end
  end

  check("nothing has been imported", ns.Payload.Current() == nil)

  local ranked, all, meta = ns.Loot.RankRaiders(noExportChest, { difficulty = "h" })
  check("a ranking is produced anyway", ranked ~= nil and all ~= nil,
        ranked and #ranked or "nil")

  local byName = {}
  for _, row in ipairs(all or {}) do byName[row.name or ""] = row end

  check("a stranger resolved in game is in it",
        byName["Normalguy"] ~= nil)
  check("...scored from what their own client reported",
        byName["Normalguy"] and byName["Normalguy"].equipped
          and byName["Normalguy"].equipped.source == "live",
        byName["Normalguy"] and byName["Normalguy"].equipped
          and byName["Normalguy"].equipped.source)

  -- The gate that stops a stranger we cannot describe floating to the top at
  -- ilvl 0 has to survive the export going away — it is the only thing standing
  -- between an unreadable pug and a maximum upgrade on every item.
  check("...while one we could not read is still left out", byName["Faraway"] == nil)

  -- YOU are the person this used to omit, and the omission was invisible because
  -- your own column was right beside it.
  check("the player is ranked among them",
        byName[stub.player.name] ~= nil, stub.player.name)

  check("no priority column is claimed", meta and meta.priority == false)
  check("...and no roster is claimed either", meta and meta.roster == false)
  local withPr = 0
  for _, row in ipairs(all or {}) do if row.pr then withPr = withPr + 1 end end
  check("...and not one row carries a standing", withPr == 0, withPr)
end

-- ═══════════════════════════════════════════════════════════════════════════
header("an ad-hoc raider reaching a real ranking")
-- ═══════════════════════════════════════════════════════════════════════════

do
  -- Now load the export. Nobody in the wing is on it — which is the whole point.
  local fh = io.open("test/payload.txt", "r")
  local encoded = fh and fh:read("*a") or nil
  if fh then fh:close() end
  if not encoded then
    io.stderr:write("test/payload.txt missing — see test/make-payload.ts\n")
    os.exit(2)
  end
  local data = ns.Payload.Decode(encoded)
  ns.Payload.Store(data, encoded)

  -- ⚠️ THE TEAM HAS TO BE STANDING HERE (Session 253). The ranking now counts
  -- only export raiders the group scan has SEEN, so a fixture that never puts
  -- any of them in the instance ranks an empty list and every check below it
  -- fails for want of a raider rather than for anything it tests. This is a
  -- guild night with strangers mixed in, which is the situation the whole file
  -- is about; the absent-member filter is exercised deliberately further down,
  -- where roster[3] is left out of the group on purpose.
  -- TWO of them, not all twenty-four: this file's premise is a raid of
  -- STRANGERS, and seeding the whole export would also put every one of them in
  -- the unresolved list, which is a different thing entirely.
  for i = 1, 2 do
    local r = data.roster[i]
    if r then
      Roster.seen[ns.Comms.Normalize(r.n)] = { name = r.n, unit = "raid20", class = r.c, spec = r.s }
    end
  end

  local base = #data.roster
  local effective = ns.Payload.EffectiveRoster()
  check("the export's own roster is all there", base == 24, base)

  -- ⚠️ THIS CHECK USED TO READ "plus the strangers we managed to resolve" and
  -- assert #effective > base — i.e. the whole export PLUS everyone here. That is
  -- the behaviour Jason rejected (Session 253): the export is the raid TEAM, and
  -- in an LFR it put sixteen people who were at home into the ranking beside the
  -- strangers, reporting "31 of 38 raiders gain from it". The ranking is now the
  -- people PRESENT — the two export raiders standing here plus the strangers we
  -- resolved — so it is SMALLER than the export, not larger.
  -- THREE KINDS OF ENTRY, not two (Session 256): the export's own raiders, the
  -- strangers resolved from the group, and YOU — who are on neither list here,
  -- since this fixture's export does not name the player.
  local fromExport, strangers, mine = 0, 0, 0
  for _, r in ipairs(effective) do
    if r.me then mine = mine + 1
    elseif r.adhoc then strangers = strangers + 1
    else fromExport = fromExport + 1 end
  end
  check("the player is present exactly once", mine == 1, mine)
  check("only export raiders actually in the instance are ranked",
        fromExport == 2, ("%d of %d on the export"):format(fromExport, base))
  check("...alongside the strangers we managed to resolve",
        strangers > 0, ("%d strangers"):format(strangers))

  -- Only the resolved ones. A stranger we cannot describe stays out of the
  -- ranking and stays IN the unresolved list.
  local adhocInRanking = {}
  for _, r in ipairs(effective) do
    if r.adhoc then adhocInRanking[#adhocInRanking + 1] = r.n end
  end
  table.sort(adhocInRanking)
  check("exactly the resolvable strangers were added",
        table.concat(adhocInRanking, ",") == "Alsofine,Normalguy,Warmingup",
        table.concat(adhocInRanking, ","))

  -- ⚠️ THE SWEEP'S PROGRESS IS ITS OWN NUMBER, not "N of M Reporting" — that one
  -- counts who else is running the addon and reads 0 in a group of strangers
  -- however well the inspecting is going. Jason read it as sweep progress,
  -- which is exactly what it looks like when nothing else reports that.
  do
    local sweep = ns.InspectionSummary()
    local stillOut = #Roster.Unresolved()
    check("the sweep reports its own progress", sweep ~= nil)
    -- Eight strangers plus the two export raiders the fixture put in the
    -- instance. Everyone HERE counts, export or not: the sweep inspects roster
    -- members too, because the payload's gear is only as fresh as their last
    -- logout while an inspection is what they are wearing now.
    check("...counting everyone here but yourself, whether or not they are on the export",
          sweep and sweep.here == #stub.group + 2, sweep and sweep.here)
    check("...and resolved is the ones no longer waiting on an inspect",
          sweep and sweep.resolved == sweep.here - stillOut,
          sweep and ("%d resolved, %d here, %d unresolved")
            :format(sweep.resolved, sweep.here, stillOut))
  end

  local unresolvedNames = {}
  for _, u in ipairs(Roster.Unresolved()) do unresolvedNames[#unresolvedNames + 1] = u.name end
  table.sort(unresolvedNames)
  -- Basegear is here because every reading it produced was impossible for this
  -- season, so nothing survived — which is the correct outcome, and visible.
  -- Dåmir1 and Vörnix0 are the two export raiders now standing here (see the
  -- fixture note above). They belong on this list: nobody has inspected them, so
  -- there is no LIVE reading — the report flags them inPayload, which is exactly
  -- the distinction it exists to draw between "we cannot see them" and "we do
  -- not need to".
  check("and the rest are named as unresolved rather than dropped",
        table.concat(unresolvedNames, ",")
          == "Basegear,Coldcache,Dåmir1,Faraway,Loggedoff,Neveranswers,Vörnix0",
        table.concat(unresolvedNames, ","))

  -- The end of the whole chain: a stranger, resolved in game, ranked for a real
  -- item out of the real payload, by the real scorer.
  local dataT = _G.HoDLootAdvisorData
  local chestId
  for id, it in pairs(dataT.items) do
    if it.slot == "CHEST" and it.classes and it.classes["Hunter"] then chestId = id break end
  end
  check("the payload has a chest a Hunter can use", chestId ~= nil)

  local ranked = ns.Loot.RankRaiders(chestId, { difficulty = "h" })
  local found
  for _, row in ipairs(ranked or {}) do
    if row.name == "Alsofine" then found = row end
  end
  check("a stranger who was invisible an hour ago now appears in the ranking",
        found ~= nil, ranked and (#ranked .. " ranked"))
  found = found or {}
  check("...marked as ad-hoc, so the panel can say they are not on the export",
        found and found.adhoc == true)
  check("...scored from gear read off them in game",
        found and found.equipped and found.equipped.source == "inspected",
        found and found.equipped and found.equipped.source)
  check("...and carrying NO priority, because EPGP only exists on the website",
        found and found.pr == nil)
  check("the panel gets a distinct provenance tag for it",
        (ns.ProvenanceTag(found.equipped)) == "seen")

  -- The ranking row carries everything the panel needs to mark them. Asserted
  -- on the ROW rather than on the drawing, since Panel.lua is frame
  -- construction and the harness deliberately does not load it.
  check("...and the row says they are not on the export",
        found.adhoc == true)
  check("...while a raider FROM the export is not marked",
        (function()
          for _, row in ipairs(ranked or {}) do
            if row.adhoc ~= true then return true end
          end
          return false
        end)())
end

-- ═══════════════════════════════════════════════════════════════════════════
header("the manual retry, and the spec discrepancy report")
-- ═══════════════════════════════════════════════════════════════════════════

do
  -- The automatic ladder has pushed the failures out to a later rung. A human
  -- asking is a different thing from the pump hammering, so a deliberate press
  -- clears the backoff — otherwise the manual trigger is useless in exactly the
  -- moment somebody reaches for it.
  local far = Roster.seen["faraway"]
  far.nextTry = 999999
  muted = true
  local before = #stub.printed
  Roster.Command("scan")
  check("a manual scan clears the backoff so it retries now", far.nextTry == 0, far.nextTry)

  -- ⚠️ AND IT SAYS HOW LONG IT WILL TAKE. The live version answered "retrying
  -- 24 raiders now" and then never spoke again, because the work happens in the
  -- background over the following minute — so from outside, a sweep that was
  -- working looked identical to one that did nothing at all.
  local said = table.concat(stub.printed, "\n", before + 1, #stub.printed)
  check("...and says roughly how long it will take", said:find("takes about") ~= nil, said)

  -- A sweep that scheduled nothing cannot finish. Pinning this separately so a
  -- failure says WHICH half broke — the kick, or the completion report.
  check("...and the scan actually scheduled a pass",
        #stub.timers > 0, ("%d timers queued"):format(#stub.timers))

  before = #stub.printed
  pump(600)
  local done = (#stub.printed > before)
    and table.concat(stub.printed, "\n", before + 1, #stub.printed) or "(nothing printed)"
  -- ⚠️ "DONE" IS NOT "EVERYONE RESOLVED". Four of these six genuinely cannot be
  -- inspected, so waiting for the list to empty waits forever. A pass is
  -- finished when there is nobody left to TRY.
  local pend = {}
  for k in pairs((Roster.sweep or {}).pending or {}) do pend[#pend+1] = k end
  check("...and reports ONCE when the sweep has done all it can",
        done:find("done for now") ~= nil,
        ("%s | announce=%s pending=[%s] tried=%d"):format(
          done, tostring(Roster.announceWhenDone), table.concat(pend, ","),
          Roster.stats.tried))
  check("...naming what is still out of reach, by reason",
        done:find("out of range") ~= nil and done:find("offline") ~= nil, done)

  -- Only when somebody asked. A background sweep that narrates itself every
  -- time the raid re-forms is the spam this addon is otherwise careful about.
  before = #stub.printed
  Roster.announceWhenDone = nil
  Roster.Kick()
  pump(600)
  local quiet = (#stub.printed > before)
    and table.concat(stub.printed, "\n", before + 1, #stub.printed) or "(nothing printed)"
  check("an automatic sweep finishes silently",
        quiet:find("everyone here is resolved") == nil, quiet)

  -- Someone on the export, playing something else. REPORTED, never applied:
  -- rules/HoD_Rules_Loot-Gear.txt scores the spec they RAID, and a live
  -- observation is exactly what that rule exists to distrust.
  local first = ns.Payload.Current().roster[1]
  Roster.seen[ns.Comms.Normalize(first.n)] = {
    name = first.n, unit = "raid9", class = first.c,
    spec = (first.s == "Marksmanship") and "Survival" or "Marksmanship",
  }
  local drift = Roster.SpecDiscrepancies()
  check("a raider specced differently to the roster is reported", #drift == 1, #drift)
  check("...naming both what the roster says and what they are playing",
        drift[1] and drift[1].roster == first.s and drift[1].observed ~= first.s,
        drift[1] and (drift[1].roster .. " vs " .. drift[1].observed))

  -- REVERT-PROOF for the rule: the ranking must still use the ROSTER's spec.
  local roster = ns.Payload.byName[ns.Comms.Normalize(first.n)]
  check("...and the export's spec is what still reaches the scorer",
        roster.s == first.s, roster.s)
end

-- ═══════════════════════════════════════════════════════════════════════════
header("the OTHER spec's grade, carried but never applied")
-- ═══════════════════════════════════════════════════════════════════════════

-- A trinket's grade is per SPEC, so a raider playing something other than what
-- the roster says can be an A where they are ranked and an S where they are
-- standing. The ranking does not move — that is settled — but the alternative
-- is carried so the person running loot can see it before deciding.
--
-- Reuses the divergence the previous section set up: roster[1] is on the export
-- as Marksmanship and has just been seen playing Survival.

do
  local data = _G.HoDLootAdvisorData
  local first = ns.Payload.Current().roster[1]
  local key = ns.Comms.Normalize(first.n)

  -- ⚠️ A SECOND EXPORT RAIDER HAS TO BE STANDING HERE (Session 253). Since the
  -- ranking dropped absent roster members, only people the group scan has seen
  -- are ranked — and this fixture had seeded exactly ONE, the diverged raider.
  -- The "no divergence, no marker" checks below then had no subject at all and
  -- failed for want of a raider rather than for anything they test. A real raid
  -- has several of the team present; the fixture now does too, which is also
  -- what makes the absent-member filter genuinely exercised rather than
  -- vacuously true.
  local second = ns.Payload.Current().roster[2]
  if second then
    Roster.seen[ns.Comms.Normalize(second.n)] = {
      name = second.n, unit = "raid10", class = second.c, spec = second.s,
    }
  end

  -- ⚠️ THE ABSENT HALF OF THE TEAM MUST NOT BE RANKED (Jason, Session 253).
  -- An LFR ranked twenty-two strangers alongside sixteen guild raiders sitting
  -- at home and reported "31 of 38 raiders gain from it". On a guild night the
  -- same fault is quieter and worse: someone who did not turn up outranks
  -- someone who did.
  do
    -- Take roster[3] back OUT of the instance: the fixture above puts the whole
    -- team in, so somebody has to actually be missing for this to mean anything.
    local absent = ns.Payload.Current().roster[3]
    if absent then Roster.seen[ns.Comms.Normalize(absent.n)] = nil end
    local present = {}
    for _, r in ipairs(ns.Payload.EffectiveRoster()) do present[r.n] = true end
    check("an export raider standing in the group is ranked",
          present[first.n] == true and present[second.n] == true)
    check("...and one who did not turn up is not",
          absent ~= nil and present[absent.n] == nil,
          absent and absent.n or "no third raider in the fixture")
  end

  --- Find a Hunter trinket whose tag DIFFERS between the two specs, and one
  --- where it does not. Chosen from the real tables rather than hardcoded: a
  --- literal id here would rot the first time a tier's grades are refreshed,
  --- and would do it silently by simply never diverging again.
  local differing, agreeing
  for id, it in pairs(data.items) do
    if it.slot == "TRINKET" and it.classes and it.classes["Hunter"] then
      local a = ns.QualityTag(ns.Scoring.resolveQuality(data.rankings, id, "Hunter", "Marksmanship", nil))
      local b = ns.QualityTag(ns.Scoring.resolveQuality(data.rankings, id, "Hunter", "Survival", nil))
      if a ~= b then differing = differing or id
      elseif a ~= nil then agreeing = agreeing or id end
    end
  end
  check("the tier has a Hunter trinket graded differently for the two specs",
        differing ~= nil, tostring(differing))
  check("...and one graded the same for both", agreeing ~= nil, tostring(agreeing))

  local rows = ns.Loot.RankRaiders(differing, { difficulty = "h" })
  local row
  for _, r in ipairs(rows or {}) do if r.name == first.n then row = r end end
  check("the diverged raider is still ranked", row ~= nil)

  check("the row carries the spec they were seen in",
        row and row.altSpec and row.altSpec.spec == "Survival",
        row and row.altSpec and row.altSpec.spec)

  -- ⚠️ THE POINT OF THE WHOLE FEATURE. Ranked as one, graded differently as the
  -- other, and the ranking is unmoved.
  check("...ranked as the ROSTER's spec regardless", row and row.spec == "Marksmanship",
        row and row.spec)

  local mark, title, help = ns.SpecSplitTag(row)
  check("the panel gets a marker for it", mark == "*", tostring(mark))
  check("...and a sentence naming both specs",
        help and help:find("Marksmanship") ~= nil and help:find("Survival") ~= nil, help)
  check("...which says the ranking follows the roster",
        help and help:find("follows the roster") ~= nil)
  check("...with a title to hang it on", title ~= nil and title ~= "")

  -- ⚠️ SILENT WHERE IT DOES NOT MATTER. Most of a tier grades the same for both
  -- of a class's specs; a marker on every row of every item would mean nothing
  -- by the third one. Without this check the feature passes as "always speaks",
  -- which is the version that makes the panel useless.
  local same = ns.Loot.RankRaiders(agreeing, { difficulty = "h" })
  local sameRow
  for _, r in ipairs(same or {}) do if r.name == first.n then sameRow = r end end
  check("the same raider on an item both specs grade alike", sameRow ~= nil)
  check("...still carries the observed spec",
        sameRow and sameRow.altSpec ~= nil)
  check("...but gets NO marker, because nothing about this item changes",
        (ns.SpecSplitTag(sameRow)) == nil, tostring((ns.SpecSplitTag(sameRow))))

  -- And a raider who has NOT been seen in a different spec never gets one.
  local other
  for _, r in ipairs(rows or {}) do
    if r.name ~= first.n and not r.adhoc and r.eligible then other = r break end
  end
  check("a raider with no observed divergence carries no alternative",
        other ~= nil and other.altSpec == nil, other and other.name)
  check("...and no marker", other ~= nil and (ns.SpecSplitTag(other)) == nil)
end

-- ═══════════════════════════════════════════════════════════════════════════
header("the guild-run gate — the only thing the raid can actually see")
-- ═══════════════════════════════════════════════════════════════════════════

-- Every other message this addon sends is a hidden addon message that nobody
-- without the addon can observe. Auto-posting writes REAL chat lines, so this
-- gate is the one that has to be right, and it has to fail closed.

do
  local savedGroup, savedRaid, savedIn = stub.group, stub.inRaid, stub.inGroup

  local function party(n, guildmates)
    local g = {}
    for i = 1, n do
      g[i] = { name = "Stranger" .. i, className = "Hunter", classToken = "HUNTER",
               guid = "G" .. i, connected = true, equipped = {},
               inGuild = i <= guildmates }
    end
    stub.group, stub.inRaid, stub.inGroup = g, true, false
    return g
  end

  -- Solo. Not a run of any kind.
  stub.group, stub.inRaid, stub.inGroup = {}, false, false
  check("solo is not a guild run", (ns.IsGuildRun()) == false)

  -- LFR: twenty-four strangers, none of them guildmates. The case that started
  -- this whole conversation.
  party(24, 0)
  local isRun, mates, total = ns.IsGuildRun()
  check("an LFR of strangers is not a guild run", isRun == false, isRun)
  check("...and it counts only the player as a guildmate", mates == 1, mates)
  check("...out of the whole group", total == 25, total)

  -- A raid night: nearly everyone is a guildmate.
  party(19, 17)
  isRun, mates, total = ns.IsGuildRun()
  check("a raid of guildmates IS a guild run", isRun == true, isRun)
  check("...counting the player among them", mates == 18, mates)

  -- ⚠️ AND THE RUNNER TAB MUST BE ABLE TO SAY SO. RunnerReport read these
  -- through `select(2, ns.IsGuildRun and ns.IsGuildRun())`, which collapses the
  -- call to ONE value, so both counts were always nil and the panel rendered
  -- "0 of 0 here are guildmates" beside a group it had just correctly called a
  -- guild run (Session 249, live). The gate was right; the sentence was not.
  local report = ns.Comms.RunnerReport()
  check("the runner report carries the guild-run verdict", report.guildRun == true)
  check("...and the counts behind it, not nils rendered as zero",
        report.guildMates == mates and report.groupSize == total,
        ("%s of %s"):format(tostring(report.guildMates), tostring(report.groupSize)))

  -- ⚠️ THE CASE THE "was it formed by the finder?" TEST GOT WRONG. A pug raid
  -- joined by INVITE looks exactly like a guild raid to any test based on how
  -- the group was assembled. Jason joins both the same way, so this is the one
  -- that had to stop guessing.
  party(19, 3)
  check("a pug raid joined by invite is NOT a guild run", (ns.IsGuildRun()) == false)

  -- FAILS CLOSED at the boundary. Exactly half guildmates stays quiet: a chat
  -- line nobody got is cheap, the addon talking to strangers is not.
  party(9, 4)   -- 4 mates + the player = 5 of 10, not a majority
  isRun, mates, total = ns.IsGuildRun()
  check("an exactly-half group stays quiet", isRun == false,
        ("%d of %d"):format(mates, total))
  party(9, 5)   -- 5 + player = 6 of 10
  check("...and one more guildmate tips it", (ns.IsGuildRun()) == true)

  stub.group, stub.inRaid, stub.inGroup = savedGroup, savedRaid, savedIn
end

do
  -- The setting itself: off unless someone turns it on. Nobody is opted into
  -- posting to their guild's raid chat by installing an update.
  ns.Settings.Reset()
  check("auto-post is OFF by default", ns.Settings.Get("autoPost") == false,
        tostring(ns.Settings.Get("autoPost")))
  ns.Settings.Set("autoPost", "on")
  check("...and can be turned on", ns.Settings.Get("autoPost") == true)
  ns.Settings.Set("autoPost", "off")
end

-- ── Result ──────────────────────────────────────────────────────────────────

muted = false
_G.print = realPrint
io.write("\n")
ns.Roster.Status()

io.write("\n", ("═"):rep(72), "\n")
if #failures == 0 then
  io.write(("PASS — %d checks, a raid of strangers\n"):format(checks))
  os.exit(0)
end
io.write(("FAIL — %d of %d checks\n\n"):format(#failures, checks))
for _, f in ipairs(failures) do io.write("  · ", f, "\n") end
os.exit(1)
