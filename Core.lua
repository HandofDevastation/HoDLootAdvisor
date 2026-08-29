-- Core.lua — Loot Advisor
--
-- The in-game half of hodguild.com's Loot Advisor page. This file is the
-- plumbing every other file draws on:
--   • the saved-variables database and the addon namespace
--   • access to the baked static payload (LootData.lua) with a loud failure
--   • resolving THIS character's class / spec / hero tree into the emitted keys
--   • item-link parsing, gear-track resolution and equipped-slot state
--   • the /la slash command router
--
-- Scoring lives in Scoring.lua (parity-proven against the website), the raw
-- event capture in Diagnostics.lua, and the loot path itself in Loot.lua.
--
-- STANDING RULE, worth restating at the top of the addon: the WEBSITE IS THE
-- ORACLE. Nothing here may quietly disagree with app/lib/loot-advisor.ts or
-- app/lib/gear-tracks.ts. Where this file mirrors site logic it says so and
-- names the source, so the two can be diffed by hand.

local ADDON_NAME, ns = ...
_G.HoDLootAdvisor = ns

ns.ADDON_NAME = ADDON_NAME

local PREFIX = "|cffF3C56BLoot Advisor|r"
ns.PREFIX = PREFIX

-- ---------------------------------------------------------------------------
-- Output
-- ---------------------------------------------------------------------------

function ns.Print(text)
  print(PREFIX .. ": " .. tostring(text))
end

--- Print without the prefix — for the indented continuation lines of a report,
--- where repeating the prefix on every row is just noise.
function ns.Line(text)
  print("  " .. tostring(text))
end

function ns.Warn(text)
  print(PREFIX .. ": |cffff4444" .. tostring(text) .. "|r")
end

function ns.Version()
  local v
  if C_AddOns and C_AddOns.GetAddOnMetadata then
    v = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
  end
  -- Running unpackaged (a dev symlink into AddOns), the BigWigs packager has
  -- not substituted its token, so the .toc still reads the literal
  -- "@project-version@". Report that honestly as a dev build.
  if not v or v:find("@") then return "dev" end
  return v
end

-- ---------------------------------------------------------------------------
-- Saved variables
-- ---------------------------------------------------------------------------
--
-- DIAGNOSTICS DEFAULT TO ON. That is deliberate for v1: the addon shows nothing
-- yet, so the only thing a raid night can produce is observations, and every
-- night without the logger installed is one we cannot replay. It costs a table
-- append per loot event.

local DB_DEFAULTS = {
  schema      = 1,
  diagnostics = true,
  logCap      = 3000,
  log         = {},
  -- frame name -> { left, top }, so a window opens where it was last left.
  windows     = {},
}

local function applyDefaults(db, defaults)
  for k, v in pairs(defaults) do
    if db[k] == nil then
      if type(v) == "table" then db[k] = {} else db[k] = v end
    end
  end
  return db
end

-- ---------------------------------------------------------------------------
-- The static payload
-- ---------------------------------------------------------------------------

--- The payload schema this build knows how to read.
---
--- ⚠️ DECLARED IN ONE PLACE ON PURPOSE. It is what makes a schema bump safe:
--- the release workflow refuses a payload the COMMITTED addon cannot read
--- rather than letting it half-read one, so the emitter and the addon's read
--- side land in the same release. CI greps this line; the packaged-copy test
--- asserts against it. Bump it in the same change that teaches the addon the
--- new shape, never before.
ns.EXPECTED_SCHEMA = 2

--- The baked game-data table from LootData.lua, or nil if it failed to load.
--- Every caller must handle nil: an addon that silently scores against no data
--- is worse than one that says it has none (Data Contract §0, degrade loudly).
function ns.Data()
  return _G.HoDLootAdvisorData
end

function ns.DataSummary()
  local data = ns.Data()
  if not data then return nil end
  local counts = { bosses = 0, items = 0, specs = 0, rankings = 0, ladder = 0 }
  for _ in pairs(data.bosses or {}) do counts.bosses = counts.bosses + 1 end
  for _ in pairs(data.items or {}) do counts.items = counts.items + 1 end
  for _ in pairs(data.specs or {}) do counts.specs = counts.specs + 1 end
  -- Two different numbers, and they read as a discrepancy against the emitter's
  -- headers if only one is shown: `rankedItems` is how many ITEMS carry a
  -- tier, `rankings` is how many spec-level tiers those items carry between
  -- them (the emitter's X-Trinkets count).
  -- Schema 2: `rankings` replaced `trinkets`, and an entry is now a TABLE of
  -- signals rather than a bare letter. Grades and BIS listings are counted apart
  -- because they come from different sources and fail differently — a harvest
  -- that silently dropped one of them shows up here as a zero rather than as a
  -- slightly smaller total.
  counts.rankedItems, counts.grades, counts.bis = 0, 0, 0
  for _, byKey in pairs(data.rankings or {}) do
    counts.rankedItems = counts.rankedItems + 1
    for _, e in pairs(byKey) do
      counts.rankings = counts.rankings + 1
      if e.g then counts.grades = counts.grades + 1 end
      if e.b then counts.bis = counts.bis + 1 end
    end
  end
  counts.ladder = #((data.tracks or {}).ladder or {})
  counts.season = (data.meta or {}).seasonName
  counts.schema = (data.meta or {}).schema
  counts.generatedAt = (data.meta or {}).generatedAt
  return counts
end

-- ---------------------------------------------------------------------------
-- Who is this character
-- ---------------------------------------------------------------------------
--
-- The emitted spec keys are "Class/Spec" using ENGLISH names as the website's
-- Blizzard sync stores them ("Death Knight/Blood"). UnitClass's second return is
-- a locale-independent TOKEN, so the class half maps exactly. The spec half uses
-- GetSpecializationInfo's name, which is localized — correct on an enUS client
-- and wrong on any other. Rather than invent a spec-id table from memory (the
-- standing rule on WoW data: no recall, verified sources only), a miss is
-- reported loudly by ResolveCharacter and the real spec id is recorded in the
-- diagnostic log, so a verified id→name map can be built from observation later.

ns.CLASS_NAME = {
  DEATHKNIGHT = "Death Knight",
  DEMONHUNTER = "Demon Hunter",
  DRUID       = "Druid",
  EVOKER      = "Evoker",
  HUNTER      = "Hunter",
  MAGE        = "Mage",
  MONK        = "Monk",
  PALADIN     = "Paladin",
  PRIEST      = "Priest",
  ROGUE       = "Rogue",
  SHAMAN      = "Shaman",
  WARLOCK     = "Warlock",
  WARRIOR     = "Warrior",
}

--- The active hero talent tree's NAME ("Dark Ranger"), or nil.
--- nil is the NORMAL case, not an error: hero-tree stat overrides are opt-in per
--- spec and only 8 exist across all 40, so falling back to the spec's base
--- ranking is right far more often than not.
function ns.HeroTreeName()
  if not (C_ClassTalents and C_Traits) then return nil end
  local ok, configID = pcall(C_ClassTalents.GetActiveConfigID)
  if not ok or not configID then return nil end
  local ok2, subTreeIDs = pcall(C_ClassTalents.GetHeroTalentSpecsForClassSpec, configID)
  if not ok2 or type(subTreeIDs) ~= "table" then return nil end
  for _, stID in ipairs(subTreeIDs) do
    local ok3, info = pcall(C_Traits.GetSubTreeInfo, configID, stID)
    if ok3 and type(info) == "table" and info.isActive then
      return info.name
    end
  end
  return nil
end

--- The player's specialization index (1-4), plus which API answered.
---
--- INSTRUMENTED, THEN FIXED BY THE INSTRUMENT (Session 243). The first real logs
--- showed specId = 0 and specKnown = false on 18 of 18 logins: GetSpecialization()
--- answered 0, and because ZERO IS TRUTHY IN LUA the old `if idx then` guard
--- waved it through to GetSpecializationInfo(0), which returns nothing usable. So
--- the spec silently never resolved and every item was scored against an UNKNOWN
--- spec — a neutral value instead of the character's real stat ranking. Nothing
--- errored; the badges just quietly meant less than they claimed.
---
--- Blizzard has been moving these calls into C_SpecializationInfo, so both are
--- tried in turn and the one that answered is recorded rather than assumed.
function ns.SpecIndex()
  -- Built by appending, for the same nil-hole reason as ns.SpecInfo below.
  local sources = {}
  if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization then
    sources[#sources + 1] = { "C_SpecializationInfo.GetSpecialization",
                              C_SpecializationInfo.GetSpecialization }
  end
  if _G.GetSpecialization then
    sources[#sources + 1] = { "GetSpecialization", _G.GetSpecialization }
  end

  for _, src in ipairs(sources) do
    if type(src[2]) == "function" then
      local ok, idx = pcall(src[2])
      -- A spec index is 1-4. Anything else is "no answer" — including 0, which
      -- is exactly what slipped through before.
      if ok and type(idx) == "number" and idx >= 1 and idx <= 8 then
        return idx, src[1]
      end
    end
  end
  return nil, nil
end

--- id, name for a spec index, from whichever namespace has the function.
function ns.SpecInfo(idx)
  if not idx then return nil, nil end

  -- Appended one at a time, never written as a table literal: a literal whose
  -- FIRST entry is nil — which it is whenever C_SpecializationInfo does not
  -- exist — makes ipairs stop before it starts, and the whole lookup silently
  -- does nothing. Exactly the nil-hole trap that truncated GetLootRollItemInfo's
  -- returns in Session 242.
  local fns = {}
  if C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo then
    fns[#fns + 1] = C_SpecializationInfo.GetSpecializationInfo
  end
  if _G.GetSpecializationInfo then
    fns[#fns + 1] = _G.GetSpecializationInfo
  end

  for _, fn in ipairs(fns) do
    local ok, id, name = pcall(fn, idx)
    if ok and type(name) == "string" and name ~= "" then return id, name end
  end
  return nil, nil
end

--- { className, specName, heroTree, specId, known } for the player.
--- `known` is false when the resolved Class/Spec key is absent from the emitted
--- spec table — which is the signal that the localization assumption above has
--- broken, or that the emitter skipped a spec for having no stat ranking.
function ns.ResolveCharacter()
  local _, classToken = UnitClass("player")
  local className = ns.CLASS_NAME[classToken or ""]

  local idx, specSource = ns.SpecIndex()
  local specId, specName = ns.SpecInfo(idx)

  local heroTree = ns.HeroTreeName()

  local data = ns.Data()
  local known = false
  if data and className and specName then
    known = (data.specs or {})[className .. "/" .. specName] ~= nil
  end

  return {
    className  = className,
    specName   = specName,
    heroTree   = heroTree,
    specId     = specId,
    specIndex  = idx,
    specSource = specSource,
    classToken = classToken,
    known      = known,
  }
end

-- ── The item-quality tag ────────────────────────────────────────────────────
--
-- WHY THIS IS SHOWN AT ALL (Jason): a trinket needs simming to know whether it
-- is an upgrade, so a published grade carries information the score cannot. And
-- without it BIS is worse than invisible — it silently makes some badges bigger,
-- changing the advice without showing its reasoning.
--
-- SHORT ON PURPOSE. A strip chip is 88px wide and a ranking row has ~26px
-- between the name and the badge, so this has to read at a glance in almost no
-- space. The full wording lives in the tooltip.
--
-- BIS OUTRANKS A GRADE, matching the scorer: they are one axis and the strongest
-- wins, so showing both would imply a sum that is not happening.
local QUALITY_MUTED = { 0.533, 0.533, 0.600 }
local QUALITY_GOLD  = { 0.953, 0.773, 0.420 }
-- ⚠️ BIS AND THE TARGET MARK MUST NOT SHARE A HUE (Session 249). Both used to be
-- the brand gold, which is exactly the collision that rule forbids — a gold mark
-- beside a gold tag says nothing about which is which. Jason's design settles the
-- pair: BIS takes the yellow, the target takes the green.
local BIS_COLOR    = { 1.000, 0.957, 0.408 }   -- #fff468
local TARGET_COLOR = { 0.125, 0.729, 0.337 }   -- #20ba56
ns.BIS_COLOR    = BIS_COLOR
ns.TARGET_COLOR = TARGET_COLOR
local GRADE_COLOR = {
  s = { 1.000, 0.420, 0.420 }, a = { 0.980, 0.640, 0.320 },
  b = { 0.784, 0.588, 0.180 }, c = { 0.627, 0.627, 0.690 },
  d = { 0.533, 0.533, 0.600 }, f = { 0.533, 0.533, 0.600 },
  defensive = { 0.470, 0.700, 0.900 },
}
local BIS_SHORT = { overall = "BIS", raid = "R-BIS", mplus = "M-BIS" }
local BIS_LONG  = { overall = "Overall BIS", raid = "Raid BIS", mplus = "M+ BIS" }
ns.BIS_LONG = BIS_LONG

--- The compact tag for one resolved quality entry, or nil when there is none.
--- Returns text plus colour so every surface renders it identically.
local function qualityTag(q)
  if not q then return nil end
  if q.bis then return BIS_SHORT[q.bis] or "BIS", BIS_COLOR end
  if q.grade then
    return q.grade == "defensive" and "DEF" or q.grade:upper(),
           GRADE_COLOR[q.grade] or QUALITY_MUTED
  end
  return nil
end
ns.QualityTag = qualityTag

--- Is the group we are in a GUILD run?
---
--- ⚠️ THIS GATES THE ONE THING THE RAID CAN SEE. Everything else the addon
--- sends is a hidden addon message that nobody without the addon can observe;
--- auto-posting writes real chat lines that every stranger in an LFR would
--- read. So this is the gate that has to be right, and it fails CLOSED.
---
--- MEASURED, NOT INFERRED FROM HOW THE GROUP FORMED. The obvious test — "was
--- this assembled by the group finder?" — is holed: a pug raid joined by
--- INVITE is indistinguishable from a guild raid by that measure, and Jason
--- joins both the same way. UnitIsInMyGuild is a fact about each person
--- instead of a guess about the group.
---
--- A MAJORITY, because the three cases separate cleanly on it: a raid night is
--- almost entirely guildmates, an LFR is none, and a pug raid is a handful at
--- most. A guild raid carrying so many pugs that guildmates are not a majority
--- stays quiet — the wrong answer in that direction costs a chat line nobody
--- got, and in the other direction it is the addon talking to strangers.
---
--- Returns inGuildRun, guildmates, total.
function ns.IsGuildRun()
  if not (IsInGroup and IsInGroup()) then return false, 0, 0 end
  if not UnitIsInMyGuild then return false, 0, 0 end

  local total, mates = 0, 0
  for _, unit in ipairs(ns.Roster and ns.Roster.UnitTokens() or {}) do
    if (not UnitExists) or UnitExists(unit) then
      local name = UnitName and UnitName(unit)
      if name and name ~= "" then
        total = total + 1
        -- Ourselves included deliberately: we are in the guild, and excluding
        -- the one person we are certain about would make a five-guildmate
        -- group of nine read as a minority.
        local isSelf = ns.Comms and ns.Comms.IsSelf(name)
        if isSelf or UnitIsInMyGuild(unit) then mates = mates + 1 end
      end
    end
  end

  return total > 0 and (mates * 2) > total, mates, total
end

--- A raider ranked as one spec while standing in another, rendered identically
--- wherever it appears. Returns marker, title, sentence — or nil.
---
--- ⚠️ SILENT WHEN THE SPEC CHANGE DOES NOT CHANGE THIS ITEM. Most of a tier
--- grades the same for both of a class's specs, and Affliction and Destruction
--- want their stats in the same order — so flagging every spec difference would
--- put a marker on almost every row of almost every item and mean nothing by
--- the third one. It speaks only where the TAG actually differs, which is where
--- a loot decision could go the other way.
---
--- In Core rather than Panel.lua so the harness can reach it: pure logic in a
--- window file is untestable, which this project has repeatedly got wrong.
function ns.SpecSplitTag(row)
  local alt = row and row.altSpec
  if not (alt and alt.spec) then return nil end

  local rosterTag = qualityTag(row.quality)
  local altTag = qualityTag(alt.quality)
  if rosterTag == altTag then return nil end

  local function describe(tag) return tag or "not graded" end

  return "*", "Ranked as a different spec",
    ("Ranked as %s (%s), the spec on the raid roster. Seen playing %s, where this is %s. "):format(
      tostring(row.spec), describe(rosterTag), tostring(alt.spec), describe(altTag))
    .. "The ranking follows the roster."
end

-- Where a raider's gear reading came from, for the panel's provenance marker.
-- The SNAPSHOT case deliberately returns nil rather than a label: it is the
-- normal state for almost every row, and tagging all twenty of them turns the
-- signal into wallpaper. What matters is which rows are BETTER than the
-- snapshot, not that the rest are ordinary.
-- The SHORT form has to fit a 36px column, which is why it is not the sentence.
-- The sentence goes in the tooltip, where there is room for it — the same split
-- the quality tag already makes between its compact tag and its full wording.
-- {r,g,b} triples, matching GRADE_COLOR above rather than hex strings: the
-- panel's SetTextColor takes three numbers, and one convention per file beats
-- two. Green is --hue-green (#20ba56), gold is the brand accent (#F3C56B).
local PROVENANCE = {
  live      = { text = "live", color = { 0.125, 0.729, 0.337 },
                help = "Reported live by this raider's own client — exact, not a snapshot." },
  corrected = { text = "won",  color = QUALITY_GOLD,
                help = "Patched from an item they were seen winning tonight." },
  -- Read off their character in game. Exact when it worked, and it is allowed
  -- to have not worked — which is why the unresolved list exists.
  inspected = { text = "seen", color = { 0.470, 0.700, 0.900 },
                help = "Read from this raider in game just now, not from the export." },
}

--- Returns short, colorHex, help — or nil for the snapshot tier.
--- In Core rather than Panel.lua so the headless harness can reach it: pure
--- logic in Panel is untestable, which this project has now got wrong three
--- times (Sessions 245 Parts 5 and 10).
function ns.ProvenanceTag(state)
  local entry = state and state.source and PROVENANCE[state.source]
  if not entry then return nil end
  return entry.text, entry.color, entry.help
end

--- Who in tonight's roster is reporting live gear and who is not.
--- Returns { reporting, total, missing = { names } }.
---
--- THE GAP HAS TO BE VISIBLE. A non-reporting raider is scored from the site
--- snapshot and is NEVER silently omitted, but "ranked from possibly-stale
--- data" and "ranked from what they are wearing right now" are different
--- claims, and the runner is the person who needs to know which is which. The
--- missing list is capped by the caller, not here — this answers the question,
--- it does not decide how to say it.
function ns.GearReportingSummary()
  local raid = ns.Payload and ns.Payload.Current()
  if not raid then return nil end

  local reporting, missing = 0, {}
  for _, r in ipairs(raid.roster) do
    local live = ns.Comms and ns.Comms.gear[ns.Comms.Normalize(r.n or "")]
    if live and next(live) then
      reporting = reporting + 1
    else
      missing[#missing + 1] = r.n
    end
  end
  table.sort(missing)
  return { reporting = reporting, total = #raid.roster, missing = missing }
end

--- How many drops are on a BIS list for THIS character, for EVERY boss at once,
--- keyed by journal encounter id.
---
--- The point of putting these on the pickers: "which of these should I care
--- about" is the question you actually have when choosing where to look, and a
--- bare list of names cannot answer it. Counting ITEMS, not listings — an item
--- on two of your BIS lists is still one thing to win.
---
--- Counted from OUR payload rather than from the journal, deliberately: this is
--- a question about our BIS data, so an item we have no listing for contributes
--- nothing and there is nothing to degrade about it.
---
--- ALL of them in one pass, because three pickers now ask: the boss list wants
--- nine answers and the browse lists want one per encounter and per instance, so
--- the per-boss form would re-walk the whole payload a few dozen times a refresh
--- to produce the same table.
function ns.BisCountsByBoss()
  local out = {}
  local data = ns.Data()
  if not (data and data.items and data.rankings) then return out end
  local char = ns.ResolveCharacter and ns.ResolveCharacter()
  if not (char and char.className and char.specName) then return out end
  local scope = ns.CurrentContentScope and ns.CurrentContentScope() or nil

  for itemID, rec in pairs(data.items) do
    if rec.boss then
      local q = ns.Scoring.resolveQuality(
        data.rankings, itemID, char.className, char.specName, char.heroTree, scope)
      if q and q.bis then out[rec.boss] = (out[rec.boss] or 0) + 1 end
    end
  end
  return out
end

--- The same count for a single boss.
function ns.BisCountForBoss(bossID)
  if not bossID then return 0 end
  return ns.BisCountsByBoss()[bossID] or 0
end

--- The same counts rolled up to journal INSTANCES, keyed by instance id.
---
--- Inverted deliberately. The obvious shape — walk every instance, ask what its
--- encounters hold — makes the browse picker pay for a full Encounter Journal
--- catalogue walk on every refresh, including for the dungeons and world bosses
--- our payload does not cover at all. This starts from the handful of bosses
--- that actually have a BIS item and asks the journal where each one lives, so
--- when there is nothing to count it never touches the journal.
function ns.BisCountsByInstance()
  local out = {}
  if not (ns.Journal and ns.Journal.InstanceForEncounter) then return out end
  for bossID, n in pairs(ns.BisCountsByBoss()) do
    local instanceID = ns.Journal.InstanceForEncounter(bossID)
    if instanceID then out[instanceID] = (out[instanceID] or 0) + n end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Ordering the item column (Session 250)
-- ---------------------------------------------------------------------------
--
-- ONE LADDER FOR EVERY MODE, settled by Jason in Session 249:
--
--   Targeted -> BIS (Overall -> Raid -> M+) -> Major -> Moderate -> Minor
--   -> Sidegrade -> Not an upgrade -> Not for you
--
-- ⚠️ TARGETS PIN TO THE TOP REGARDLESS OF USABILITY (Jason, flatly). A target is
-- an actively chosen thing, so an item somebody has decided they want outranks
-- the machine's opinion of it — including "your class cannot wear this", because
-- a Resto Druid may legitimately be chasing Feral gear.
--
-- TIES BREAK BY UPGRADE SIZE, THEN NAME, so the list does not reshuffle between
-- refreshes. That matters more than it looks: the column is a SELECTOR, and a
-- selector whose rows move under the pointer is one that gets misclicked during
-- the only sixty seconds anybody is looking at it.
--
-- In Core rather than Panel.lua because it is pure logic and Panel.lua is the
-- one file no harness loads — the fourth time this project has had to move
-- something for that reason.

-- Lower sorts first. Gaps left between bands so a future rung (a second BIS
-- kind, say) can be inserted without renumbering the ones around it.
local ITEM_BAND = {
  targeted     = 0,
  bisOverall   = 10,
  bisRaid      = 11,
  bisMplus     = 12,
  major        = 20,
  moderate     = 21,
  minor        = 22,
  sidegrade    = 23,
  notAnUpgrade = 30,
  notForYou    = 40,
}
ns.ITEM_BAND = ITEM_BAND

local BIS_BAND = {
  overall = ITEM_BAND.bisOverall,
  raid    = ITEM_BAND.bisRaid,
  mplus   = ITEM_BAND.bisMplus,
}
local BADGE_BAND = {
  major     = ITEM_BAND.major,
  moderate  = ITEM_BAND.moderate,
  minor     = ITEM_BAND.minor,
  sidegrade = ITEM_BAND.sidegrade,
}

--- Which rung of the ladder one scored item sits on.
---
--- `entry` is the panel's item record: targeted, quality (grade + bis), badge,
--- ineligible, and whether it scored as an upgrade at all.
function ns.ItemBand(entry)
  if not entry then return ITEM_BAND.notForYou end
  -- FIRST, and before eligibility: see the pin rule above.
  if entry.targeted then return ITEM_BAND.targeted end
  if entry.ineligible then return ITEM_BAND.notForYou end
  local bis = entry.quality and entry.quality.bis
  if bis then return BIS_BAND[bis] or ITEM_BAND.bisMplus end
  -- An item we could not score at all is not the same as one that scored badly,
  -- but it is not an upgrade we can vouch for either — it sits with them rather
  -- than being promoted by an absent badge.
  if entry.reason or not entry.badge then return ITEM_BAND.notAnUpgrade end
  if entry.isUpgrade == false then return ITEM_BAND.notAnUpgrade end
  return BADGE_BAND[entry.badge] or ITEM_BAND.sidegrade
end

--- Sort a list of item entries into the ladder, in place, and return it.
function ns.OrderItems(entries)
  if type(entries) ~= "table" then return entries end
  for _, e in ipairs(entries) do
    e.band = ns.ItemBand(e)
  end
  table.sort(entries, function(a, b)
    if a.band ~= b.band then return a.band < b.band end
    -- Upgrade SIZE, not raw score: the score is never displayed and two items
    -- from different bands are not comparable on it anyway. Within one band the
    -- ilvl gain is the honest tiebreak and it is a number both sides can see.
    local ga, gb = a.gain or 0, b.gain or 0
    if ga ~= gb then return ga > gb end
    return (a.name or "") < (b.name or "")
  end)
  return entries
end

--- "Chest, Plate" · "1H Axe" · "Trinket" — the item column's second line.
---
--- Armour reads SLOT then ARMOUR TYPE; a weapon reads its type alone, because
--- "Main Hand, 1H Axe" says the same thing twice in a 198px row. Driven by
--- whether the armour type is one of the four armour classes rather than by a
--- weapon list, so a subtype we have never seen falls through to the weapon
--- shape instead of vanishing.
local ARMOR_CLASS = { Cloth = true, Leather = true, Mail = true, Plate = true }

function ns.ItemSlotLine(entry)
  if not entry then return "" end
  local slot, armor = entry.slotText, entry.armorType
  if armor and ARMOR_CLASS[armor] then
    return slot and slot ~= "" and (slot .. ", " .. armor) or armor
  end
  if armor and armor ~= "" then return armor end
  return slot or ""
end

--- "1st" · "2nd" · "13th" · "21st" — the detail header's standing.
--- Returns the number and the suffix separately, because the design sets them at
--- different sizes (24px on the digits, 18px on the suffix).
function ns.Ordinal(n)
  if type(n) ~= "number" then return nil, nil end
  local abs = math.floor(math.abs(n))
  local suffix = "th"
  -- 11, 12 and 13 take "th" despite ending in 1, 2 and 3 — the case every
  -- hand-rolled version of this gets wrong, and a raid of 20+ reaches it.
  local lastTwo = abs % 100
  if lastTwo < 11 or lastTwo > 13 then
    local last = abs % 10
    if last == 1 then suffix = "st"
    elseif last == 2 then suffix = "nd"
    elseif last == 3 then suffix = "rd" end
  end
  return tostring(abs), suffix
end

--- How many of a list of items are BIS for the viewer, and how many they have
--- targeted — the boss header's "For You: 1 BIS | 2 Targets".
---
--- Counted off the SAME entries the column is about to draw, deliberately, so
--- the header can never claim a BIS the list below does not show. Asking the
--- payload separately is what let the picker labels and the list disagree.
function ns.CountsForItems(entries)
  local bis, targets = 0, 0
  for _, e in ipairs(entries or {}) do
    if e.quality and e.quality.bis then bis = bis + 1 end
    if e.targeted then targets = targets + 1 end
  end
  return bis, targets
end

-- ---------------------------------------------------------------------------
-- The Standings tab (Session 250)
-- ---------------------------------------------------------------------------

--- "1,240" — thousands separated, the way the design writes EP.
--- Handles negatives and leaves anything non-numeric alone.
function ns.Commify(n)
  if type(n) ~= "number" then return tostring(n or "") end
  local sign = n < 0 and "-" or ""
  local whole = tostring(math.floor(math.abs(n)))
  local out = whole
  while true do
    local swapped
    out, swapped = out:gsub("^(%d+)(%d%d%d)", "%1,%2")
    if swapped == 0 then break end
  end
  return sign .. out
end

--- "2 days" · "1 wk" · "6 wks" — the LAST ITEM column's compact age.
--- nil for unknown, which the column renders as an em-dash: per Core §1.1 the
--- dash is reserved for genuinely absent data, and "never received an item" is
--- absent, not zero.
function ns.ShortAge(days)
  if type(days) ~= "number" then return nil end
  if days < 7 then return ("%d day%s"):format(days, days == 1 and "" or "s") end
  local wks = math.floor(days / 7)
  return ("%d wk%s"):format(wks, wks == 1 and "" or "s")
end

--- "today" · "yesterday" · "5 days ago" · "3 weeks ago" · "2 months ago" —
--- the long form the personal card uses. Extracted from the old Me tab so the
--- two surfaces cannot drift into describing the same date differently.
function ns.LongAge(days)
  if type(days) ~= "number" then return nil end
  if days == 0 then return "today" end
  if days == 1 then return "yesterday" end
  if days < 14 then return ("%d days ago"):format(days) end
  if days < 60 then return ("%d weeks ago"):format(math.floor(days / 7)) end
  return ("%d months ago"):format(math.floor(days / 30))
end

-- ---------------------------------------------------------------------------
-- Is this thing even gear? (Session 250)
-- ---------------------------------------------------------------------------
--
-- The Encounter Journal lists EVERYTHING an encounter can drop, which in 12.1
-- includes profession patterns and housing decor. Those arrived on the Full Loot
-- Table as UNSCORED rows — the addon correctly saying it had no opinion about a
-- leatherworking recipe, at the cost of two lines of noise on a list whose whole
-- job is "who is this for".
--
-- ⚠️ THIS MUST NOT BECOME "HIDE WHAT WE DO NOT RECOGNISE". Data Contract §0 is
-- explicit that an item we never imported still has to appear, named and flagged
-- as unscored, because the alternative is a real upgrade going invisible. So the
-- test is a FACT ABOUT THE ITEM — the game's own class — and never our own
-- ignorance of it. An armour piece we have never seen still shows, unscored.
--
-- ⚠️ AND TIER TOKENS ARE "MISCELLANEOUS" TO BLIZZARD, not Armor. Filtering on
-- class alone would drop every tier token off the list, which is the opposite of
-- helpful — so anything in OUR payload is gear by definition, tokens included.
-- That clause has to come first.
local GEAR_CLASS = { [2] = true, [4] = true }   -- 2 Weapon, 4 Armor

--- itemID plus our payload record (may be nil). Returns true when the row
--- belongs on a loot list.
---
--- FAILS OPEN. With no way to ask the client, everything is gear: an extra row
--- is visibly wrong and fixable, a missing one is invisible and costs somebody
--- an upgrade. Same convention as the eligibility fail-open.
function ns.IsGearItem(itemID, rec)
  if rec then return true end
  if type(GetItemInfoInstant) ~= "function" then return true end
  local ok, _, _, _, _, _, classID = pcall(GetItemInfoInstant, itemID)
  if not ok or classID == nil then return true end
  return GEAR_CLASS[classID] == true
end

--- Which list the Loot tab should open on: "drops" or "table".
---
--- IN A RAID, WHAT DROPPED IS THE QUESTION; anywhere else it is what CAN drop.
--- Jason's call, and it holds even when nothing has dropped yet — inside a raid
--- an empty drops list is information ("nothing yet"), while outside one it is
--- just an empty screen, because nothing is ever going to arrive.
---
--- Reuses ns.CurrentContentScope rather than reading GetInstanceInfo again: that
--- is the settled seam for "where is this player standing", and a second copy is
--- one of them going stale. A keystone dungeon answers "mplus", which correctly
--- falls through to the full table — group loot does not happen there.
function ns.DefaultLootSource()
  return (ns.CurrentContentScope and ns.CurrentContentScope() == "raid")
    and "drops" or "table"
end

--- The Standings table: the EPGP ladder, joined to the roster for the two things
--- the ladder does not carry — a raider's CLASS (for the name colour) and when
--- they last received an item.
---
--- ⚠️ DRIVEN BY THE LADDER, NOT THE ROSTER. The ladder is what the site ranked
--- and it owns the rank numbers, ties included — this must not re-derive them.
--- A ladder name with no roster row is still shown, uncoloured, rather than
--- dropped: a raider missing from a standings table is the silent omission this
--- project keeps writing rules about, and it is exactly the case a main-swap or
--- a late roster edit produces.
---
--- Returns rows plus the ladder's total, which is the "of 17" on the personal
--- rail — one number, read once, so the rail and the table cannot disagree.
function ns.StandingsRows()
  local raid = ns.Payload and ns.Payload.Current()
  local ladder = raid and raid.ladder
  if not ladder then return {}, 0 end

  local byName = ns.Payload.byName or {}
  local out = {}
  for i, s in ipairs(ladder) do
    -- ⚠️ THE LADDER CARRIES ITS OWN CLASS NOW, AND THE JOIN IS A FALLBACK
    -- (Session 253). This used to take class and Last Item SOLELY from a
    -- name match against the roster — but the ladder was named after the
    -- PERSON (display name) while the roster is keyed by CHARACTER, so anyone
    -- whose display name differed from the toon they raid on silently lost
    -- both. Five of seventeen raid-team members were affected: Abirn, Death,
    -- Gloom, Televoker and Zugbee rendered white with an em-dash while
    -- everyone else was coloured, and it read as "they have won nothing".
    --
    -- The site now names the ladder after the raid-roster character, so the
    -- join succeeds by construction; `s.c` is belt and braces for a standing
    -- whose character is not on the roster at all.
    local roster = s.n and byName[s.n:lower()]
    local class = s.c
    if class == "" then class = nil end
    out[#out + 1] = {
      rank = s.rank or i,
      name = s.n,
      class = class or (roster and roster.c) or nil,
      ep = s.ep, gp = s.gp, pr = s.pr,
      lastItemDays = roster and roster.lastItemDays or nil,
    }
  end
  return out, #ladder
end

--- Which body of content the player is in right now: "raid", "mplus", or nil
--- when it is neither or cannot be told.
---
--- Three specs split their GRADE table by Raid vs Mythic+ (Blood DK, Prot
--- Warrior, Aug Evoker) and grade the same trinket differently in each, so the
--- right letter depends on where you are standing. Everywhere else this returns
--- nil and the unscoped key resolves, which is the overwhelmingly common case.
---
--- nil ON DOUBT, deliberately: an unscoped grade is the spec's general answer,
--- while a WRONGLY scoped one is a confident answer to a question nobody asked.
function ns.CurrentContentScope()
  if type(GetInstanceInfo) ~= "function" then return nil end
  local ok, _, instanceType, difficultyID = pcall(GetInstanceInfo)
  if not ok then return nil end
  if instanceType == "raid" then return "raid" end
  -- 8 is Mythic Keystone. A non-keystone 5-man is neither bucket: the guides
  -- mean KEYSTONE content by "Mythic+", and a normal dungeon run is not that.
  if instanceType == "party" and difficultyID == 8 then return "mplus" end
  return nil
end

--- The spec table Scoring.scoreCandidate expects, or nil for an UNKNOWN spec.
--- That distinction is load-bearing and is not a style choice: the engine scores
--- an unknown spec a neutral 15 and a known spec with nothing worth weighting a
--- 0. Collapsing the two diverged 3,840 parity cases when the port was written.
function ns.SpecFor(char)
  local data = ns.Data()
  if not (data and char and char.className and char.specName) then return nil end
  local ranks = ns.Scoring.resolveSpecRanks(
    data.specs, char.className, char.specName, char.heroTree
  )
  if not ranks then return nil end
  return { ranks = ranks }
end

-- ---------------------------------------------------------------------------
-- Slots
-- ---------------------------------------------------------------------------
--
-- Mirrors extractSlotState() in app/loot-advisor/page.tsx, which maps a LOOT
-- slot onto the equipment slots that actually compete with it and compares
-- against the WORST of them (the piece you would replace). ONE_HAND competes
-- with both hands; TWO_HAND and RANGED occupy MAIN_HAND (Blizzard reports
-- two-handers there — a fix that had to be made twice on the site).

ns.SLOT_INV = {
  HEAD     = { INVSLOT_HEAD },
  NECK     = { INVSLOT_NECK },
  SHOULDER = { INVSLOT_SHOULDER },
  BACK     = { INVSLOT_BACK },
  CHEST    = { INVSLOT_CHEST },
  WRIST    = { INVSLOT_WRIST },
  HANDS    = { INVSLOT_HAND },
  WAIST    = { INVSLOT_WAIST },
  LEGS     = { INVSLOT_LEGS },
  FEET     = { INVSLOT_FEET },
  FINGER   = { INVSLOT_FINGER1, INVSLOT_FINGER2 },
  TRINKET  = { INVSLOT_TRINKET1, INVSLOT_TRINKET2 },
  MAIN_HAND = { INVSLOT_MAINHAND },
  OFF_HAND  = { INVSLOT_OFFHAND },
  ONE_HAND  = { INVSLOT_MAINHAND, INVSLOT_OFFHAND },
  TWO_HAND  = { INVSLOT_MAINHAND },
  RANGED    = { INVSLOT_MAINHAND },
}

-- The five slots a tier token can resolve to. Used for the set-piece count.
ns.TIER_SLOTS = { "HEAD", "SHOULDER", "CHEST", "HANDS", "LEGS" }

--- The gear slot an emitted item actually competes for. For a tier token that
--- is the slot its NAME encodes, resolved by the emitter (never by a copy of
--- TOKEN_SLOT_MAP here — that map changes every season and belongs to the site).
--- Returns nil for an omni-token, which has no single slot to compare against.
function ns.ItemSlot(rec)
  if not rec then return nil end
  if rec.slot == "TOKEN" then return rec.tokenSlot end
  return rec.slot
end

-- ---------------------------------------------------------------------------
-- Item links and gear tracks
-- ---------------------------------------------------------------------------

local function detailedIlvl(link)
  local fn = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo
  if not fn then return nil end
  local ok, ilvl = pcall(fn, link)
  if ok and type(ilvl) == "number" and ilvl > 0 then return ilvl end
  return nil
end
ns.DetailedIlvl = detailedIlvl

--- itemID + bonus IDs out of an item link or item string.
--- Field order in an item link is fixed:
---   item : id : enchant : gem1-4 : suffix : unique : level : specID :
---   modifiersMask : itemContext : numBonusIDs : bonusID...
--- so the bonus list is numBonusIDs entries starting one field later.
function ns.ParseItemLink(link)
  if type(link) ~= "string" then return nil end
  local itemString = link:match("|Hitem:([%-%d:]*)") or link:match("^item:([%-%d:]*)")
  if not itemString then return nil end

  local parts = {}
  for field in (itemString .. ":"):gmatch("([^:]*):") do
    parts[#parts + 1] = field
  end

  local itemID = tonumber(parts[1])
  if not itemID then return nil end

  local bonusIDs = {}
  local numBonus = tonumber(parts[13]) or 0
  for i = 1, numBonus do
    local id = tonumber(parts[13 + i])
    if id then bonusIDs[#bonusIDs + 1] = id end
  end

  return { itemID = itemID, bonusIDs = bonusIDs }
end

-- Ladder order, lowest track first. Mirrors TRACK_ORDER in gear-tracks.ts.
ns.TRACK_ORDER = { "Adventurer", "Veteran", "Champion", "Hero", "Myth" }

local TRACK_INDEX = {}
for i, t in ipairs(ns.TRACK_ORDER) do TRACK_INDEX[t] = i end

--- The scorer only knows four tracks; Adventurer folds into Veteran, exactly as
--- toScoringTrack() does on the site.
function ns.ScoringTrack(track)
  if track == "Adventurer" then return "Veteran" end
  return track
end

local function bonusListHasTrack(bonusIDs, track)
  local data = ns.Data()
  local block = ((data or {}).tracks or {}).bonus
  block = block and block[track]
  if not block then return false end
  for _, id in ipairs(bonusIDs or {}) do
    for _, want in ipairs(block) do
      if id == want then return true end
    end
  end
  return false
end

--- Item level + bonus IDs -> scoring track, LADDER-FIRST.
---
--- This is resolveGearTrack() from app/lib/gear-tracks.ts, not
--- resolveDisplayTrack(). The two exist on purpose and must not be collapsed:
--- SCORING wants a piece expressed in CURRENT-season power, so that last
--- season's Myth gear does not make this season's tier token look like no
--- upgrade at all. Bonus IDs only break a tie between two tracks that share an
--- item level.
---
--- Returns scoringTrack, rank, rawTrack — or nil when the item level is not on
--- this season's ladder at all (off-season or crafted gear).
function ns.ResolveTrack(ilvl, bonusIDs)
  local data = ns.Data()
  local ladder = ((data or {}).tracks or {}).ladder
  if not ladder then return nil end

  local candidates = {}
  for _, e in ipairs(ladder) do
    if e.ilvl == ilvl then candidates[#candidates + 1] = e end
  end
  if #candidates == 0 then return nil end
  if #candidates == 1 then
    return ns.ScoringTrack(candidates[1].track), candidates[1].rank, candidates[1].track
  end

  for _, track in ipairs(ns.TRACK_ORDER) do
    if bonusListHasTrack(bonusIDs, track) then
      for _, c in ipairs(candidates) do
        if c.track == track then
          return ns.ScoringTrack(track), c.rank, track
        end
      end
      -- The matched track is not among the candidates at this item level. The
      -- site returns null here rather than guessing; so do we.
      return nil
    end
  end

  -- No bonus ID matched — assume the LOWER track. This understates gear and so
  -- inflates apparent upgrade size, which is the site's current behaviour at the
  -- overlapping item levels. Same trade-off, same direction, deliberately.
  table.sort(candidates, function(a, b)
    return (TRACK_INDEX[a.track] or 99) < (TRACK_INDEX[b.track] or 99)
  end)
  return ns.ScoringTrack(candidates[1].track), candidates[1].rank, candidates[1].track
end

-- ---------------------------------------------------------------------------
-- Eligibility — can this character use the item at all
-- ---------------------------------------------------------------------------
--
-- This is a SEPARATE question from scoring, and asking it is not optional: the
-- scorer will happily rate a Cloth tier token a Major upgrade for a Hunter,
-- because "how big an upgrade is this" has no opinion about armor types.
--
-- The hard part is NOT reimplemented here. The website's canUseItem() branches
-- over armor types, weapon subtypes, shields vs held off-hands and token armor
-- types; the emitter runs THAT function per class and ships the answer as the
-- item's `classes` set. All that is left in Lua is two lookups.
--
-- Returns usable, reason.

function ns.CanUse(rec, className, specName)
  if not rec then return true end

  -- ⚠️ AN EXPLICIT ANSWER FROM THE GAME WINS, AND IS CHECKED FIRST. A dungeon
  -- item has no `classes` set — we have never imported dungeon loot tables — so
  -- it fell straight through the gate below and EVERY dungeon item was reported
  -- usable. Live: a leather shoulder listed under Usable Only for a Warlock.
  --
  -- The answer is NOT re-derived here. Blizzard's own Encounter Journal filter
  -- judges the item for this character (ns.DungeonUsable), and that answer is
  -- attached to the record. Porting armour types and weapon subtypes into Lua is
  -- exactly what the rule above forbids, and it is why this is a lookup.
  --
  -- nil means WE DO NOT KNOW and falls through to the existing behaviour, which
  -- for a record with no `classes` is fail-open — unchanged for anything that
  -- cannot ask the game.
  if rec.usable == false then
    return false, ("your class cannot use this%s"):format(
      rec.armor and (" (" .. rec.armor .. ")") or "")
  end

  -- Fail OPEN on a payload that predates the field. An over-broad list is
  -- visibly wrong and fixable; an empty one reads as the addon being broken.
  if type(rec.classes) == "table" then
    if not className or not rec.classes[className] then
      return false, ("your class cannot use this%s"):format(
        rec.armor and (" (" .. rec.armor .. ")") or "")
    end
  end

  -- The finer spec gate, which needs the viewer's spec and so cannot be
  -- pre-resolved: a Strength weapon is useless to an Agility spec of a class
  -- that can otherwise equip it. An item with no detectable primary stat, or
  -- one carrying two (shared-primary plate), emits no primaryStat and is never
  -- excluded here — same benefit of the doubt the website gives.
  local data = ns.Data()
  local want = rec.primaryStat
  if want and specName and data and data.specPrimary then
    local mine = data.specPrimary[(className or "") .. "/" .. specName]
    if mine and mine ~= want then
      return false, ("wrong primary stat for %s (%s)"):format(specName, want)
    end
  end

  return true
end

-- Raid difficulty -> the gear track that difficulty drops on. Core §7.7's
-- DIFFICULTY_TRACK map, unchanged since the Loot Advisor was built.
ns.DIFFICULTY_TRACK = { n = "Champion", h = "Hero", m = "Myth" }

--- The bonus IDs a drop WOULD carry at a given difficulty and drop rank.
--- Only used when there is no item link to read them from — the dev-injection
--- path, and a live drop whose link we failed to parse. Deriving them keeps
--- those paths on the same track-resolution code as a real drop instead of a
--- shortcut that could quietly disagree with it.
function ns.BonusIdsFor(difficultyKey, dropRank)
  return ns.BonusIdsForTrack(ns.DIFFICULTY_TRACK[difficultyKey or ""], dropRank)
end

--- The same thing keyed on an EXPLICIT track and rank rather than on a raid
--- difficulty. The Great Vault needs this: its reward is a track ABOVE the one
--- the difficulty drops, so there is no difficulty whose block holds it.
---
--- ⚠️ AND THE BONUS ID IS NOT DECORATION HERE — IT IS LOAD-BEARING. Vault levels
--- land on the ladder's OVERLAPS by design: 318 is Hero 5/6 and Myth 1/6 both,
--- and the resolver assumes the LOWER track when nothing breaks the tie. Without
--- this id a Heroic vault reward would report as Hero rather than Myth, which is
--- the entire claim the toggle is making.
function ns.BonusIdsForTrack(track, rank)
  local data = ns.Data()
  local blocks = ((data or {}).tracks or {}).bonus
  local block = blocks and track and blocks[track]
  if not block then return {} end
  local id = block[(rank or 1)]
  if not id then return {} end
  return { id }
end

--- The item level a track+rank pair sits at on the emitted ladder.
function ns.LadderIlvl(track, rank)
  local data = ns.Data()
  for _, rung in ipairs(((data or {}).tracks or {}).ladder or {}) do
    if rung.track == track and rung.rank == rank then return rung.ilvl end
  end
  return nil
end

--- What this content's loot becomes in the GREAT VAULT: { track, rank, ilvl }.
--- `key` is "n" | "h" | "m" for raid, or "mplus" for a dungeon.
---
--- Season 2 rewards the vault one full track above the drop — Normal drops
--- Champion and vaults Hero, Heroic drops Hero and vaults Myth. The mapping is
--- GAME TUNING and is emitted with the ladder, never written down here: it moved
--- wholesale in 12.1 and will move again.
---
--- ⚠️ NIL WHEN THE PAYLOAD PREDATES THIS, and the caller must show nothing
--- rather than a computed guess — the same rule the GP price follows. An older
--- payload carries no vault table and the toggle simply stays unavailable.
function ns.VaultReward(key)
  local data = ns.Data()
  local v = (((data or {}).tracks or {}).vault or {})[key or ""]
  if not v or not v.track or not v.rank then return nil end
  local ilvl = ns.LadderIlvl(v.track, v.rank)
  if not ilvl then return nil end
  return { track = v.track, rank = v.rank, ilvl = ilvl }
end

--- Is a Great Vault level knowable for this content at all?
function ns.HasVaultData()
  return (((ns.Data() or {}).tracks or {}).vault) ~= nil
end

--- The rank an item level sits at on a GIVEN track, or nil if it is not a rung
--- of that track. The track is supplied because the ladder overlaps: 318 is
--- Hero 5/6 and Myth 1/6, and only the caller knows which one it means.
function ns.LadderRank(track, ilvl)
  local data = ns.Data()
  for _, rung in ipairs(((data or {}).tracks or {}).ladder or {}) do
    if rung.track == track and rung.ilvl == ilvl then return rung.rank end
  end
  return nil
end

--- An item link that tooltips at a SPECIFIC track and item level — whatever the
--- scorer just decided this item is worth showing as.
---
--- ⚠️ THE TOOLTIP MUST BE DERIVED FROM THE SCORE, NOT RECOMPUTED ALONGSIDE IT.
--- Shipping the Vault toggle without this put "Myth · ilvl 318" on the detail
--- line and "Hero 3/6, Item Level 311" in the tooltip an inch away, because the
--- link was still built from the DROP's bonus id. That is the two-authorities
--- failure the catalogue-link rule already names, and it is the second time this
--- panel has produced it — so the fix is not another parallel calculation but a
--- single input: the level the scorer arrived at.
---
--- ⚠️ NIL WHEN THE LEVEL HAS NO BONUS ID, and the caller keeps whatever link it
--- had. Myth ranks 7-9 (337/341/344) are the live case: the ascended drops from
--- the last two bosses have no mined bonus id, so their tooltip stays at the
--- drop's own link rather than being given an invented one.
function ns.TooltipLinkFor(itemID, track, ilvl)
  if not (itemID and track and ilvl) then return nil end
  local rank = ns.LadderRank(track, ilvl)
  if not rank then return nil end
  local ids = ns.BonusIdsForTrack(track, rank)
  if #ids == 0 then return nil end
  return ("item:%d:0:0:0:0:0:0:0:0:0:0:0:%d:%s")
    :format(itemID, #ids, table.concat(ids, ":"))
end

--- Move a candidate item level up to what the Great Vault would hand over.
--- Returns ilvl, bonusIDs, reward — unchanged when there is no vault data.
---
--- ⚠️ ONE IMPLEMENTATION, called by BOTH scorers. Loot.ScoreItem answers "what
--- is this worth to me" and Loot.RankRaiders answers "who is it for", and they
--- run side by side on one screen — the item column and the detail pane. Two
--- copies of this arithmetic is two chances for those to disagree in front of
--- the raid, which is the failure the whole parity discipline exists to stop.
---
--- ⚠️ NEVER BELOW THE DROP. Mythic vaults at Myth 6/6 (334), but the penultimate
--- and final bosses — and Very Rare mythic items — are Myth 9 (344) as a drop
--- AND in the vault. Those are precisely the items whose own drop level already
--- exceeds the vault rung, so taking the higher of the two reproduces Blizzard's
--- carve-out without this needing to know which bosses are last.
function ns.ApplyVault(rec, diffKey, ilvl, bonusIDs)
  local reward = ns.VaultReward((rec and rec.synthetic) and "mplus" or diffKey)
  if not reward then return ilvl, bonusIDs, nil end
  if reward.ilvl > (ilvl or 0) then
    return reward.ilvl, ns.BonusIdsForTrack(reward.track, reward.rank), reward
  end
  return ilvl, bonusIDs, reward
end

--- Should the Vault toggle be OFFERED?
---
--- Only once a CONTENT choice has been made. On AUTO the panel follows whichever
--- instance you are standing in, and "the vault level of whatever this is" is a
--- claim with no stated subject — worse, it would silently change meaning when
--- you zoned. And only if the payload knows the levels at all.
function ns.VaultShown()
  local v = ns.Settings and ns.Settings.Get("difficulty") or "AUTO"
  if v == "AUTO" then return false end
  return ns.HasVaultData()
end

--- Is the viewer asking for vault levels right now?
---
--- ⚠️ GATED ON VaultShown, not on the stored setting alone. The setting persists
--- across a reload, so someone who ticked it on Mythic and later switched to
--- AUTO would otherwise still be reading vault levels with the checkbox nowhere
--- on screen to say so.
function ns.VaultOn()
  if not ns.VaultShown() then return false end
  return (ns.Settings and ns.Settings.Get("vault")) and true or false
end

--- An item string the GAME can render a real tooltip from, carrying the bonus
--- IDs for a given difficulty.
---
--- A bare "item:270910" tooltips at the item's BASE item level, which for raid
--- loot is wildly wrong — the whole point of a bonus ID is that it tells the
--- client which upgraded version this is. So the difficulty's block is attached
--- and the client computes the real item level and stats itself, rather than us
--- re-deriving numbers we would then have to keep in step with Blizzard's.
---
--- Field order is fixed:
---   item : id : enchant : gem1-4 : suffix : unique : level : specID :
---   modifiersMask : itemContext : numBonusIDs : bonusID...
function ns.ItemLinkFor(itemID, difficultyKey)
  if not itemID then return nil end
  local data = ns.Data()
  local rec = data and (data.items or {})[itemID]
  if not rec then return ("item:%d"):format(itemID) end

  local bonus = ns.BonusIdsFor(difficultyKey or ns.DifficultyKey(), rec.dropRank)
  if #bonus == 0 then return ("item:%d"):format(itemID) end

  return ("item:%d:0:0:0:0:0:0:0:0:0:0:0:%d:%s")
    :format(itemID, #bonus, table.concat(bonus, ":"))
end

--- What the player is wearing in a loot slot: { ilvl, track, link, empty }.
--- An empty slot is ilvl 0 with no track, which the scorer reads as "anything is
--- an upgrade" — correct, and the same thing the site does with a missing piece.
function ns.EquippedSlotState(lootSlot)
  local invSlots = ns.SLOT_INV[lootSlot]
  if not invSlots then return nil end

  local worstIlvl, worstLink
  for _, inv in ipairs(invSlots) do
    local link = GetInventoryItemLink("player", inv)
    if link then
      local ilvl = detailedIlvl(link) or 0
      if not worstIlvl or ilvl < worstIlvl then
        worstIlvl, worstLink = ilvl, link
      end
    end
  end

  if not worstLink then
    return { ilvl = 0, track = nil, empty = true }
  end

  local parsed = ns.ParseItemLink(worstLink)
  local track = ns.ResolveTrack(worstIlvl, parsed and parsed.bonusIDs)
  return { ilvl = worstIlvl, track = track, link = worstLink, empty = false }
end

--- Does the player already have this exact item equipped in the given slot, and
--- at what item level. Only meaningful for the two-slot slots — you cannot wear
--- two of the same trinket, which is why the scorer excludes those candidates.
function ns.EquippedCopy(lootSlot, itemID)
  local invSlots = ns.SLOT_INV[lootSlot]
  if not invSlots then return false, nil end
  local bestIlvl
  for _, inv in ipairs(invSlots) do
    local link = GetInventoryItemLink("player", inv)
    local parsed = link and ns.ParseItemLink(link)
    if parsed and parsed.itemID == itemID then
      local ilvl = detailedIlvl(link) or 0
      if not bestIlvl or ilvl > bestIlvl then bestIlvl = ilvl end
    end
  end
  return bestIlvl ~= nil, bestIlvl
end

--- How many tier set pieces the player is wearing, for the set-completion
--- factor. INSTRUMENTED, NOT TRUSTED: this reads the set id off equipped items,
--- which Blizzard has historically left empty for modern tier sets. `known` is
--- false when nothing reported a set id at all, and the raw ids go into the
--- diagnostic log, so the first raid night tells us whether this works rather
--- than us assuming either way. F4 only applies to tier tokens, so a wrong 0
--- costs at most the set bonus on token scoring.
function ns.TierPieceCount()
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not getInfo then return 0, false, {} end

  local setIds, counts, best, bestCount = {}, {}, nil, 0
  for _, slotName in ipairs(ns.TIER_SLOTS) do
    local inv = ns.SLOT_INV[slotName][1]
    local itemID = GetInventoryItemID("player", inv)
    if itemID then
      local ok, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, setID = pcall(getInfo, itemID)
      if ok and setID then
        setIds[slotName] = setID
        counts[setID] = (counts[setID] or 0) + 1
        if counts[setID] > bestCount then best, bestCount = setID, counts[setID] end
      end
    end
  end

  if not best then return 0, false, setIds end
  return bestCount, true, setIds
end

-- ---------------------------------------------------------------------------
-- Raid difficulty
-- ---------------------------------------------------------------------------
--
-- Only ever a FALLBACK for the candidate item level: a real drop carries a link,
-- and the link's bonus IDs give the item level that actually dropped, which is
-- better data than the difficulty table. This exists for the dev-injection path
-- and for a drop whose link we could not parse.

ns.DIFFICULTY_KEY = {
  [14] = "n", -- Normal
  [15] = "h", -- Heroic
  [16] = "m", -- Mythic
  [17] = "n", -- Raid Finder: below our table, floored to Normal
}

--- "n" | "h" | "m", plus the raw difficulty id for the log.
---
--- An explicit SETTING wins over detection. Auto-detect is right in a raid but
--- useless everywhere else — planning next week's loot from a city returns no
--- instance at all, and silently scoring everything as Heroic with no way to say
--- otherwise is wrong for a Mythic team. Every consumer funnels through here, so
--- the setting reaches the panel, the chat lines and the slash commands alike.
-- ⚠️ "MPLUS" IS DELIBERATELY ABSENT FROM THIS MAP. The control selects CONTENT
-- as well as difficulty now, and Mythic+ is not a raid difficulty — it has no
-- n/h/m key and its item level is fixed. Leaving it out means every existing
-- caller of ns.DifficultyKey() falls through to auto-detection exactly as it did
-- before, rather than being handed a fourth value it has never seen.
local SETTING_KEY = { NORMAL = "n", HEROIC = "h", MYTHIC = "m" }

--- "raid" or "mplus" — WHICH CONTENT the Loot tab is showing.
---
--- Separate from ns.DifficultyKey() on purpose: one answers "which loot table",
--- the other "at what item level", and only raids have the second question.
function ns.ContentMode()
  local v = ns.Settings and ns.Settings.Get("difficulty")
  return (v == "MPLUS") and "mplus" or "raid"
end

function ns.DifficultyKey()
  local id = select(3, GetInstanceInfo())
  local forced = ns.Settings and SETTING_KEY[ns.Settings.Get("difficulty") or "AUTO"]
  if forced then return forced, id end
  local key = ns.DIFFICULTY_KEY[id or 0]
  return key or "h", id
end

-- ---------------------------------------------------------------------------
-- Window placement
-- ---------------------------------------------------------------------------
--
-- Every secondary window used to anchor itself CENTER, and the panel anchors
-- CENTER+260 — so each one opened squarely on top of the panel, two title bars
-- and two sets of footer buttons interleaved and unreadable. It happened once
-- with the loot log and again with settings, which is the signal it belongs in
-- ONE place rather than being fixed per window.
--
-- Sides are assigned so the two that can be open together are not on the same
-- one: the loot log and the paste window take the LEFT, settings the RIGHT.
-- Clamped to screen, so docking can never push a window off a narrow display,
-- and every window stays movable — wherever the user drags it is theirs.

--- Make a frame behave like a WINDOW: on top when it is shown, and brought to
--- the front when it is clicked.
---
--- Every one of these frames is in the DIALOG strata, and within one strata the
--- frame LEVEL decides who draws over whom. Unmanaged, they INTERLEAVE — the
--- panel's text drew straight through the settings window's background, which is
--- what "the windows overlap" actually looked like on screen. Docking them apart
--- (below) only hid that for the default position; it could never survive the
--- user dragging one over another, which is the normal thing to do.
---
--- SetToplevel is Blizzard's own answer to this: a top-level frame is raised
--- within its strata automatically on click. Raise() covers the show.
--- Remember where a window was dragged to, across opens AND across sessions.
---
--- SCREEN COORDINATES, not the anchor as found. A window that has never been
--- moved is anchored TO THE PANEL by DockBesidePanel, and persisting that
--- relationship would drag it around whenever the panel moved — and on the next
--- login it would point at a frame that has not been built yet.
function ns.SaveWindowPosition(frame)
  local name = frame and frame.GetName and frame:GetName()
  if not (name and ns.db) then return end
  local left, top = frame:GetLeft(), frame:GetTop()
  if not (left and top) then return end
  ns.db.windows = ns.db.windows or {}
  ns.db.windows[name] = { left = left, top = top }
end

--- Restore a saved position. Returns false when there is none, which is the
--- signal to fall back to the default placement.
function ns.RestoreWindowPosition(frame)
  local name = frame and frame.GetName and frame:GetName()
  local saved = name and ns.db and ns.db.windows and ns.db.windows[name]
  if not saved then return false end
  frame:ClearAllPoints()
  frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", saved.left, saved.top)
  return true
end

function ns.ResetWindowPositions()
  if ns.db then ns.db.windows = {} end
end

function ns.MakeWindow(frame)
  if not frame then return end

  -- Appearance first, so every window picks up the DS 2.0 skin from ONE call
  -- site. All five windows already route through here for drag/escape handling,
  -- which makes this the cheapest place to make them look like one product —
  -- and the cheapest place to change that decision later.
  if ns.Style and ns.Style.Window then pcall(ns.Style.Window, frame) end

  if frame.SetToplevel then frame:SetToplevel(true) end
  if frame.SetClampedToScreen then frame:SetClampedToScreen(true) end

  -- Wrap whatever OnDragStop the window already set rather than replacing it —
  -- every window here happens to use the plain StopMovingOrSizing, but a window
  -- that needed its own teardown would otherwise lose it silently. MakeWindow is
  -- called AFTER the drag scripts in all five, which is what makes this safe.
  if frame.GetScript and frame.SetScript then
    local prior = frame:GetScript("OnDragStop")
    frame:SetScript("OnDragStop", function(self, ...)
      if prior then prior(self, ...) elseif self.StopMovingOrSizing then self:StopMovingOrSizing() end
      ns.SaveWindowPosition(self)
    end)
  end

  -- ESCAPE CLOSES IT, the way every other window in WoW works. Blizzard's
  -- CloseSpecialWindows() walks UISpecialFrames and hides every shown frame in
  -- it, so ONE press closes the whole addon rather than one window per press.
  --
  -- ⚠️ The list holds GLOBAL NAMES, not frame references, so an anonymous frame
  -- registers nothing and fails silently. Every window here is deliberately
  -- named for this reason — check GetName() before adding a new one.
  --
  -- Registering is idempotent: MakeWindow runs once per frame at build time, but
  -- a duplicate entry would make Blizzard hide the same frame twice per press,
  -- and that is the kind of thing that only shows up as a weird interaction with
  -- someone else's addon months later.
  local name = frame.GetName and frame:GetName()
  if not (name and UISpecialFrames) then return end
  for _, existing in ipairs(UISpecialFrames) do
    if existing == name then return end
  end
  table.insert(UISpecialFrames, name)
end

function ns.DockBesidePanel(frame, side)
  if not frame then return end
  ns.MakeWindow(frame)
  frame:Raise()

  -- A position the user chose OUTRANKS the default placement, always. Docking
  -- is only ever the answer to "where should this go the first time".
  if ns.RestoreWindowPosition(frame) then return end

  frame:ClearAllPoints()
  local panel = _G.HoDLootAdvisorPanel
  if panel and panel:IsShown() then
    if side == "RIGHT" then
      frame:SetPoint("TOPLEFT", panel, "TOPRIGHT", 8, 0)
    else
      frame:SetPoint("TOPRIGHT", panel, "TOPLEFT", -8, 0)
    end
  else
    frame:SetPoint("CENTER")
  end
end

-- ---------------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(_, event, name)
  if event ~= "ADDON_LOADED" or name ~= ADDON_NAME then return end

  HoDLootAdvisorDB = applyDefaults(HoDLootAdvisorDB or {}, DB_DEFAULTS)
  ns.db = HoDLootAdvisorDB

  -- Settings are merged per KEY, not wholesale: a saved table from an older
  -- version is missing any setting added since, and replacing it would discard
  -- the runner's choices while leaving it alone would leave new keys nil.
  ns.db.settings = applyDefaults(ns.db.settings or {}, ns.Settings.Defaults())

  ns.Payload.BuildIndex()

  local summary = ns.DataSummary()
  if not summary then
    ns.Warn("LootData.lua did not load — no item data. Scoring is unavailable.")
  elseif summary.items == 0 then
    ns.Warn("LootData.lua loaded but carries no items. Scoring is unavailable.")
  elseif summary.schema ~= ns.EXPECTED_SCHEMA then
    -- Half-reading a payload from a different schema produces advice that looks
    -- right and is not, which is the failure this whole addon is most careful
    -- about. Say so plainly rather than carrying on.
    ns.Warn(("LootData.lua is schema %s but this build reads schema %d — "
      .. "update the addon. Scoring may be wrong."):format(
      tostring(summary.schema), ns.EXPECTED_SCHEMA))
  end

  if ns.Diagnostics then ns.Diagnostics.Start() end

  -- Comms after the database exists (it persists the runner flag) and after
  -- Diagnostics (it logs whether its prefix registration was even accepted).
  if ns.Comms then
    ns.Comms.Start()
    -- Announce, and ask for tonight's data if we have none. Both are no-ops
    -- outside a group, which is the state at almost every login — the real
    -- trigger is GROUP_ROSTER_UPDATE, and this covers the /reload-mid-raid case
    -- that would otherwise wait for the next roster change to catch up.
    if ns.Comms.Channel() then
      ns.Comms.Announce(true)
      if not ns.Payload.Current() then ns.Comms.RequestPayload() end
    end
  end

  -- Roster after Comms, since it asks Comms who is already reporting live and
  -- never inspects those people. Kicking is cheap and self-limiting: the pump
  -- stops the moment there is nobody left to resolve, and never starts at all
  -- outside a group.
  if ns.Roster then
    ns.Roster.Start()
    ns.Roster.Kick()
  end

  -- The targeted-item tooltip line. Registers once, for every item tooltip in
  -- the game — which is the entire point of it, since a target matters where the
  -- panel is not.
  if ns.Tooltip then ns.Tooltip.Start() end

  -- The minimap button. Built here rather than at file scope because it reads
  -- the saved position and the hide setting, neither of which exists until the
  -- SavedVariables are loaded.
  if ns.MinimapButton then ns.MinimapButton.Init() end

  ns.Print(("v%s loaded. Click the minimap button to open it, or |cff888888/la help|r for commands."):format(ns.Version()))
  loader:UnregisterEvent("ADDON_LOADED")
end)

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

local function cmdStatus()
  local summary = ns.DataSummary()
  ns.Print(("v%s"):format(ns.Version()))

  if not summary then
    ns.Warn("no static data loaded (LootData.lua missing or broken).")
  else
    ns.Line(("Data: %s · schema %s · %d items · %d bosses · %d specs"):format(
      tostring(summary.season), tostring(summary.schema),
      summary.items, summary.bosses, summary.specs))
    ns.Line(("Quality: %d rated items · %d entries (%d grades, %d best-in-slot)"):format(
      summary.rankedItems or 0, summary.rankings or 0,
      summary.grades or 0, summary.bis or 0))
    ns.Line(("Generated: %s"):format(tostring(summary.generatedAt)))
  end

  local char = ns.ResolveCharacter()
  local specLabel = ("%s/%s"):format(tostring(char.className), tostring(char.specName))
  if char.heroTree then specLabel = specLabel .. " (" .. char.heroTree .. ")" end
  if char.known then
    ns.Line("You: " .. specLabel .. " |cff20ba56— stat ranking found|r")
  else
    ns.Line("You: " .. specLabel .. " |cffff4444— NO stat ranking for this spec|r")
    ns.Line("     Items would score against a neutral value. Spec id: " .. tostring(char.specId))
  end

  local pieces, known = ns.TierPieceCount()
  ns.Line(("Tier pieces: %d%s"):format(pieces, known and "" or " (no set ids reported — see /la diag)"))

  local key, diffId = ns.DifficultyKey()
  ns.Line(("Difficulty: %s (id %s)"):format(key, tostring(diffId)))

  -- WHERE THE ROLL LABELS COME FROM. The inherited number map is known wrong
  -- (Record.lua, Session 251), so which map answered is a fact worth stating
  -- rather than something to infer from the labels themselves.
  if ns.RollStateSource then
    local source, unresolved = ns.RollStateSource()
    if source == "enum" then
      ns.Line("Roll labels: read from the client's own state names")
      if unresolved and #unresolved > 0 then
        -- NAMED, not counted. An unrecognised member name is the next version
        -- of this bug, and it is only actionable if we can see what it is.
        ns.Line("     |cffF3C56Bunmatched state names:|r " .. table.concat(unresolved, ", "))
      end
    else
      ns.Line("Roll labels: |cffff4444inherited number map — UNVERIFIED and known wrong|r")
      ns.Line("     The client named no roll states, so rolls may be mislabelled.")
    end
  end

  local raid = ns.Payload and ns.Payload.Summary()
  if raid then
    ns.Line(("Raid night: %d raiders · %d with standings · %s"):format(
      raid.raiders, raid.ranked, tostring(raid.seasonName)))
    ns.Line(("     Exported %s · gear synced %s"):format(
      ns.Payload.AgeText(), ns.Payload.GearAgeText()))
  else
    ns.Line("Raid night: |cff888899nothing imported|r — |cffF3C56B/la load|r to paste tonight's export.")
    ns.Line("     Without it, scoring answers 'is this for me' but not 'who is it for'.")
  end

  if ns.Record then
    local _, gi = ns.Record.Counts(ns.Record.GUILD)
    local _, pi = ns.Record.Counts(ns.Record.PERSONAL)
    ns.Line(("Loot log: %d guild · %d personal items — |cffF3C56B/la loot|r to review"):format(gi, pi))
  end

  if ns.Targets then
    -- The TOOLTIP MECHANISM is reported because it can be absent, and a tooltip
    -- line that silently never appears is indistinguishable from one nobody
    -- flagged anything for. Tooltip.lua's own header claimed this line existed
    -- before it did — the claim is now true.
    local method = ns.Tooltip and ns.Tooltip.method
    ns.Line(("Targets: %d on this character — |cffF3C56B/la targets|r"):format(
      ns.Targets.Count()))
    if method then
      ns.Line(("     Tooltip line: on (%s)"):format(method))
    else
      ns.Line("     Tooltip line: |cffff4444unavailable|r — no tooltip hook on this client.")
    end
  end

  if ns.Diagnostics then ns.Diagnostics.Status() end
end

local function cmdHelp()
  ns.Print("commands:")
  ns.Line("|cffF3C56B/la|r — open the panel")
  ns.Line("|cffF3C56B/la status|r — data, your spec, raid data, diagnostics")
  ns.Line("|cffF3C56B/la load|r — import tonight's raid export from the website")
  ns.Line("|cffF3C56B/la who <itemID|itemLink> [n|h|m]|r — rank the whole roster for an item")
  ns.Line("|cffF3C56B/la score <itemID|itemLink> [n|h|m]|r — score one item for you")
  ns.Line("|cffF3C56B/la test <itemID|itemLink> [n|h|m]|r — fake a loot roll through the real handler")
  ns.Line("|cffF3C56B/la drops|r — what dropped, with a Post button per item")
  ns.Line("|cffF3C56B/la loot|r — the loot log: every drop and roll, reviewable and exportable")
  ns.Line("     |cff888888/la loot status · scan · clear [guild|personal]|r")
  ns.Line("     |cff888888/la loot fake|r — pretend a drop landed HERE, through the real path")
  ns.Line("|cffF3C56B/la post <itemID|itemLink>|r — post one item's ranking to chat")
  ns.Line("|cffF3C56B/la config|r — settings (names per line, channel, auto-open)")
  ns.Line("|cffF3C56B/la set <key> <value>|r — change one setting; |cffF3C56B/la set|r lists them")
  ns.Line("|cffF3C56B/la targets|r — what this character is going after (|cff888888clear|r empties it)")
  ns.Line("     |cff888888right-click any item in the panel to flag it|r")
  ns.Line("|cffF3C56B/la roster|r — who is actually here, and who we cannot describe yet")
  ns.Line("     |cff888888/la roster scan · probe|r")
  ns.Line("|cffF3C56B/la comms|r — who else is running it, and what has been sent/received")
  ns.Line("     |cff888888/la comms push · want · gear · hello · loop · flush|r")
  ns.Line("|cffF3C56B/la journal|r — probe the Adventure Guide's loot catalogue (diagnostic)")
  ns.Line("|cffF3C56B/la windows|r — forget where windows were dragged to")
  ns.Line("|cffF3C56B/la diag|r — diagnostic logging: |cff888888on / off / clear / dump / events|r")
end

SLASH_HODLOOTADVISOR1 = "/la"
SLASH_HODLOOTADVISOR2 = "/lootadvisor"
SlashCmdList["HODLOOTADVISOR"] = function(msg)
  msg = tostring(msg or "")
  -- The remainder is passed through RAW, not split on whitespace: an item link
  -- pasted by shift-clicking carries "[Item Name With Spaces]" and splitting it
  -- would tear the link apart.
  local cmd, rest = msg:match("^%s*(%S*)%s*(.*)$")
  cmd = (cmd or ""):lower()

  -- Bare /la opens the PANEL; the text status moved to /la status. The panel is
  -- the primary surface now, and the same convention Build Barn uses (/gbb
  -- opens the window, /gbb status is the text smoke test).
  if cmd == "" then
    if ns.Panel then ns.Panel.Toggle() else ns.Warn("panel did not load.") end
  elseif cmd == "status" then
    cmdStatus()
  elseif cmd == "help" then
    cmdHelp()
  elseif cmd == "diag" then
    if ns.Diagnostics then
      local sub, arg = rest:match("^(%S*)%s*(%S*)$")
      ns.Diagnostics.Command(sub, arg)
    else
      ns.Warn("diagnostics module did not load.")
    end
  elseif cmd == "score" then
    if ns.Loot then ns.Loot.ScoreCommand(rest) else ns.Warn("loot module did not load.") end
  elseif cmd == "who" then
    if ns.Loot then ns.Loot.WhoCommand(rest) else ns.Warn("loot module did not load.") end
  elseif cmd == "test" then
    if ns.Loot then ns.Loot.TestCommand(rest) else ns.Warn("loot module did not load.") end
  elseif cmd == "load" then
    if ns.LoadWindow then ns.LoadWindow.Toggle() else ns.Warn("load window did not load.") end
  elseif cmd == "loot" then
    if ns.Record then ns.Record.Command(rest) else ns.Warn("loot recorder did not load.") end
  elseif cmd == "drops" or cmd == "panel" then
    if ns.Panel then ns.Panel.Toggle() else ns.Warn("panel did not load.") end
  elseif cmd == "config" or cmd == "settings" then
    ns.Settings.Toggle()
  elseif cmd == "set" then
    ns.Settings.Command(rest)
  elseif cmd == "post" then
    local itemID = tonumber(rest:match("|Hitem:(%d+)")) or tonumber(rest:match("^%s*(%d+)"))
    if itemID then ns.Loot.PostToChat(itemID) else ns.Warn("usage: /la post <itemID or item link>") end
  elseif cmd == "targets" or cmd == "target" then
    if ns.Targets then ns.Targets.Command(rest) else ns.Warn("targets module did not load.") end
  elseif cmd == "roster" then
    if ns.Roster then
      local sub, arg = rest:match("^(%S*)%s*(.*)$")
      ns.Roster.Command(sub, arg)
    else
      ns.Warn("roster module did not load.")
    end
  elseif cmd == "comms" then
    if ns.Comms then
      local sub, arg = rest:match("^(%S*)%s*(.*)$")
      ns.Comms.Command(sub, arg)
    else
      ns.Warn("comms module did not load.")
    end
  elseif cmd == "journal" then
    if ns.Journal then ns.Journal.Probe() else ns.Warn("journal probe did not load.") end
  elseif cmd == "windows" then
    ns.ResetWindowPositions()
    ns.Print("window positions reset — each one returns to its default place next time it opens.")
  elseif cmd == "unload" then
    -- Payload.Clear repaints the panel itself — see repaintPanel in Payload.lua.
    ns.Payload.Clear()
    ns.Print("raid data cleared.")
  else
    ns.Warn("unknown command: " .. cmd)
    cmdHelp()
  end
end

-- ---------------------------------------------------------------------------
-- Mythic+ dungeons as a content mode
-- ---------------------------------------------------------------------------
--
-- WHY THIS EXISTS. The Loot tab's boss strip is filled from our EMITTED payload,
-- which is season-scoped RAID bosses only, so a dungeon item could not be
-- browsed, targeted or scored at all. The difficulty control becomes a CONTENT
-- control: Raid (Normal/Heroic/Mythic) or Dungeons.
--
-- ⚠️ TILES ARE DUNGEONS, NOT DUNGEON BOSSES (Jason). In a Mythic+ run you do not
-- loot individual bosses — there is one chest at the end — so listing bosses you
-- cannot loot separately would be showing a distinction the game does not make.
-- One tile per dungeon, its loot pooled across every encounter inside it.
--
-- ⚠️ WORLD BOSSES ARE DELIBERATELY EXCLUDED (Jason): Champion track, which is
-- below anything this guild cares about. Journal.Instances already drops the
-- world-boss container, so nothing extra is needed here — but do not "fix" that
-- exclusion thinking it is an oversight.

--- What a Mythic+ dungeon actually DROPS. Not what it unlocks.
---
--- ⚠️ THE VAULT IS A DIFFERENT QUESTION and the two are easy to conflate.
--- MPLUS_VAULT_TRACK on the site says +10 and above reward MYTH — that is the
--- weekly vault, and a bonus roll. The DROP off the end-of-run chest is Hero 3/6
--- at every key level from +10 up; a +20 drops exactly what a +10 drops.
--- Jason, Session 251, and 311 is Hero 3/6 on our own ladder.
---
--- Below +10 is deliberately not modelled: nobody at this guild's level cares
--- about it after the first week of a season.
ns.MPLUS_ILVL  = 311
ns.MPLUS_TRACK = "Hero"
ns.MPLUS_RANK  = 3

--- The season's dungeons, as the strip's tiles.
---
--- Read from the ADVENTURE GUIDE, not from our payload: the guide is the game's
--- own catalogue of the current season and needs no emit, no site work and no
--- season rollover on our side. Journal.Instances already excludes the
--- world-boss container.
function ns.DungeonList()
  local out = {}
  for _, inst in ipairs(ns.Journal and ns.Journal.CachedInstances() or {}) do
    -- ⚠️ THE SEASON'S DUNGEON LIST CARRIES A CONTAINER THAT HOLDS NOTHING —
    -- "Keystone Dungeons" (1319 in Midnight S2) enumerates like any other
    -- instance and lists no loot. Left in, it draws a tile that opens onto an
    -- empty list, which reads as the addon being broken. Journal.HasLoot fails
    -- open, so a client that will not answer shows the tile rather than hiding
    -- a real dungeon.
    if inst.isRaid == false and ns.Journal.HasLoot(inst.id) then
      out[#out + 1] = { id = inst.id, name = inst.name, order = #out + 1, bis = 0 }
    end
  end
  return out
end

--- Everything one dungeon can drop, pooled across its bosses and deduplicated.
---
--- ⚠️ POOLED BECAUSE THE GAME POOLS IT. One chest at the end of a key means the
--- dungeon is the unit of loot, so splitting by boss would invent a choice the
--- player never makes. An item that several bosses share appears ONCE.
---
--- Second return says whether any read is still warming — the item cache is
--- cold on a first look and the caller must expect to draw again.
function ns.DungeonLoot(instanceID)
  local out, seen, warming = {}, {}, false
  if not (ns.Journal and instanceID) then return out, false end
  for _, enc in ipairs(ns.Journal.CachedEncounters(instanceID)) do
    local list, warm = ns.Journal.CachedLoot(enc.id)
    if warm then warming = true end
    for _, j in ipairs(list or {}) do
      if j.itemID and not seen[j.itemID] then
        seen[j.itemID] = true
        out[#out + 1] = j
      end
    end
  end
  return out, warming
end

-- The Adventure Guide's own slot wording -> the loot slot vocabulary the scorer,
-- the payload and the GP weights all speak.
--
-- ⚠️ THE GUIDE SAYS "Two-Hand" AND THE PAYLOAD SAYS "TWO_HAND". Both halves are
-- real vocabularies; neither is negotiable, so the mapping is explicit rather
-- than a string transform. A transform would silently produce "TWOHAND" and
-- every two-hander would price and score as an unknown slot.
local JOURNAL_SLOT = {
  ["head"] = "HEAD", ["neck"] = "NECK", ["shoulder"] = "SHOULDER",
  ["shoulders"] = "SHOULDER", ["back"] = "BACK", ["cloak"] = "BACK",
  ["chest"] = "CHEST", ["robe"] = "CHEST", ["wrist"] = "WRIST",
  ["wrists"] = "WRIST", ["hands"] = "HANDS", ["waist"] = "WAIST",
  ["legs"] = "LEGS", ["feet"] = "FEET", ["finger"] = "FINGER",
  ["trinket"] = "TRINKET", ["main hand"] = "MAIN_HAND",
  ["off hand"] = "OFF_HAND", ["held in off-hand"] = "OFF_HAND",
  ["one-hand"] = "ONE_HAND", ["two-hand"] = "TWO_HAND",
  ["ranged"] = "RANGED",
}

--- The loot slot for an Adventure Guide entry, or nil when we cannot tell.
---
--- ⚠️ nil IS AN HONEST ANSWER HERE. An unmapped slot means the item is listed
--- but not scored or priced, which is visibly incomplete. Guessing a slot would
--- give it a real badge and a real price computed against the wrong weight,
--- which is not.
function ns.JournalSlot(entry)
  if type(entry) ~= "table" then return nil end
  local slot = entry.slot
  if type(slot) ~= "string" or slot == "" then return nil end
  return JOURNAL_SLOT[slot:lower()]
end

--- An item link that tooltips a dungeon drop at the level it ACTUALLY drops at.
---
--- ⚠️ THE ADVENTURE GUIDE'S OWN LINK IS A CATALOGUE LINK and tooltips the item
--- at its BASE level — 292 for a piece that drops at 311. Left alone, the
--- tooltip contradicted the line printed directly beneath it, which is worse
--- than either number alone: two authorities disagreeing on one screen.
---
--- Attaches the Hero block's rank-3 bonus id and lets the CLIENT compute the
--- level and stats, the same reasoning as ns.ItemLinkFor — we never re-derive
--- numbers we would then have to keep in step with Blizzard's.
function ns.MplusItemLink(itemID)
  if not itemID then return nil end
  local data = ns.Data()
  local block = (((data or {}).tracks or {}).bonus or {})[ns.MPLUS_TRACK]
  local id = block and block[ns.MPLUS_RANK]
  if not id then return ("item:%d"):format(itemID) end
  -- item : id : enchant : gem1-4 : suffix : unique : level : specID :
  -- modifiersMask : itemContext : numBonusIDs : bonusID...
  return ("item:%d::::::::::::1:%d"):format(itemID, id)
end

--- An item link that tooltips a RAID drop at the level it actually drops at on
--- the selected difficulty.
---
--- ⚠️ THE DUNGEON VERSION ABOVE FIXED HALF A BUG. The Adventure Guide's link is
--- a CATALOGUE link for raid loot too, and it is not difficulty-aware: browsing
--- the Full Loot Table on Mythic tooltipped the same item level as on Heroic.
--- The scorer half is fixed by opts.catalogue in Loot.ScoreItem; without this
--- the tooltip would then contradict the item level printed beside it, which is
--- the failure that rule exists to prevent.
---
--- Returns NIL rather than a bare "item:%d" when no bonus ID resolves, so the
--- caller keeps the guide's link: for an item we never imported, the catalogue
--- link is still the best tooltip available, and a bare item string would throw
--- away the little it does know.
function ns.RaidItemLink(itemID, difficultyKey)
  if not itemID then return nil end
  local data = ns.Data()
  local rec = data and (data.items or {})[itemID]
  if not rec then return nil end
  if #ns.BonusIdsFor(difficultyKey or ns.DifficultyKey(), rec.dropRank) == 0 then return nil end
  -- Delegated so the item-string field layout lives in exactly one place.
  return ns.ItemLinkFor(itemID, difficultyKey)
end

--- The subset of a dungeon's loot THE GAME says this character can equip.
---
--- ⚠️ THIS IS THE GAME'S ANSWER, NOT OURS. EJ_SetLootFilter(classID, specID) is
--- Blizzard's own eligibility filter — measured taking a 17-item encounter to 5
--- for a Marksmanship Hunter — so asking it costs one extra read and nothing has
--- to know that a Warlock cannot wear leather. Re-deriving that in Lua is the
--- five-things-to-drift trap the eligibility rule exists to prevent.
---
--- ⚠️ IT DOES NOT FILTER THE LIST, only the VERDICT. The item column still shows
--- everything the dungeon drops, because the pane ranks the whole ROSTER per
--- item and filtering at the source would hide somebody else's upgrade. This
--- decides one flag per item; the Usable Only toggle acts on that flag.
---
--- @return table|nil set of usable itemIDs, or nil when we cannot answer — and
---   nil MUST mean "do not claim", so an unanswerable client shows everything
---   rather than an empty list.
function ns.DungeonUsable(instanceID)
  if not (ns.Journal and instanceID) then return nil end

  local char = ns.ResolveCharacter()
  local classID = select(3, UnitClass("player"))
  -- A LIST FILTERED WITHOUT A SPEC IS A DIFFERENT LIST. Answering nil here is
  -- honest; answering a half-filtered set would mark items unusable that are
  -- not, which is worse than the bug being fixed.
  if not (classID and char and char.specId) then return nil end

  local set, answered = {}, false
  for _, enc in ipairs(ns.Journal.CachedEncounters(instanceID)) do
    local list, warming = ns.Journal.CachedLoot(enc.id, {
      classID = classID, specID = char.specId,
    })
    -- ⚠️ A WARMING READ IS WRONG IN A WAY THAT MATTERS HERE: Blizzard's filter
    -- cannot judge an item the client has not loaded, so a cold read comes back
    -- UNFILTERED and would mark nothing unusable. Refuse the whole answer rather
    -- than build a set from a mix of judged and unjudged encounters.
    if warming then return nil end
    for _, j in ipairs(list or {}) do
      if j.itemID then
        set[j.itemID] = true
        answered = true
      end
    end
  end

  if not answered then return nil end
  return set
end

--- A scoreable record for an item that is NOT in our emitted loot table.
---
--- WHAT IT CAN AND CANNOT CARRY:
---   name, slot, ilvl  — from the Adventure Guide and the fixed M+ drop level.
---   stats             — EMPTY, and that is not a stand-in for unknown. We have
---                       never imported dungeon stat blocks, so F3 stat
---                       alignment scores 0. An item with a BIS listing or a
---                       letter GRADE is unaffected, because quality REPLACES
---                       stat alignment rather than adding to it — so the picks
---                       that matter score in full.
---   classes           — ABSENT, which the eligibility check treats as FAIL
---                       OPEN (rules/HoD_Rules_Loot-Gear.txt). An over-broad
---                       list is visibly wrong and fixable; an empty one reads
---                       as the addon being broken.
---
--- ⚠️ NOT WRITTEN INTO ns.Data(). This record is handed to the scorer for one
--- call and thrown away. Injecting it into the static table would make an item
--- we have not imported indistinguishable from one we have, everywhere.
--- @param usableSet table|nil the answer from ns.DungeonUsable, or nil for
---   "not known" — which leaves the item unjudged rather than marking it usable.
function ns.JournalRecord(entry, usableSet)
  local slot = ns.JournalSlot(entry)
  if not slot then return nil end

  -- Blizzard's own verdict, or nil. NEVER a default of true: defaulting is what
  -- put a leather shoulder on a Warlock's usable list.
  local usable
  if type(usableSet) == "table" then
    usable = usableSet[entry.itemID] == true
  elseif entry.unusable == true then
    -- The per-entry flags (handError / weaponTypeError) as a second source. They
    -- can only say NO, never yes, so they narrow and never widen.
    usable = false
  end

  return {
    name     = entry.name,
    slot     = slot,
    armor    = entry.armorType,
    stats    = {},
    primary  = {},
    ilvl     = { n = ns.MPLUS_ILVL, h = ns.MPLUS_ILVL, m = ns.MPLUS_ILVL },
    usable   = usable,
    synthetic = true,
  }
end

--- The Blizzard encounter ids a strip tile covers.
---
--- A RAID tile is one boss, so the answer is itself. A DUNGEON tile is an
--- instance covering several encounters, and drops are recorded against the
--- ENCOUNTER — different id spaces, so the instance id must never be used as a
--- drop filter directly.
function ns.EncounterIdsFor(tileId)
  if not tileId then return nil end
  if ns.ContentMode() ~= "mplus" then return tileId end
  local set = {}
  for _, enc in ipairs(ns.Journal and ns.Journal.CachedEncounters(tileId) or {}) do
    if enc.id then set[enc.id] = true end
  end
  return set
end
