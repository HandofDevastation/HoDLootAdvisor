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
-- ⚠️ OVERALL IS "O-BIS", NOT "BIS" (Session 257, from the mock). The three
-- listings now read as a set — O-BIS / R-BIS / M-BIS — where a bare "BIS" beside
-- an "R-BIS" invited the reading that one was a general claim and the other a
-- qualified one. They are three answers to the same question about different
-- content, and the design names them symmetrically.
local BIS_SHORT = { overall = "O-BIS", raid = "R-BIS", mplus = "M-BIS" }
local BIS_LONG  = { overall = "Overall BIS", raid = "Raid BIS", mplus = "M+ BIS" }
ns.BIS_LONG = BIS_LONG
-- Exported so the panel's chips can label themselves without a second copy of
-- the map — the drift trap this file exists to avoid.
ns.BIS_SHORT = BIS_SHORT

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

--- Guarantee every entry carries a VISIBLE name, filling from our own catalogue
--- and falling back to the id. Returns how many it had to fill.
---
--- ⚠️ AN EMPTY STRING IS A TRUTHY NAME IN LUA, AND THAT IS THE WHOLE BUG
--- (Session 253). Same family as the recorded "ZERO IS TRUTHY IN LUA" rule:
--- `e.name or fallback` returns "" unchanged, and `if not e.name` never fires
--- for "". The panel's old guard lived inside its journal branch, promised in
--- its own comment never to leave "a blank row, which reads as a bug", and
--- could not keep that promise for the one value that produces exactly that.
--- The recorded-drops branch had no guard at all.
---
--- THE SYMPTOM: an item's second line rendered fine — proving the entry existed
--- and had scored — while the name was simply absent, until switching boss
--- forced a re-read from a warmer source. That "it appears if I change view"
--- shape is what this exists to end.
---
--- Lives HERE rather than in Panel.lua because the harness does not load window
--- files, and a rule this project already wrote says logic must be testable.
--- What a row shows while the client is still fetching an item's name.
---
--- ⚠️ NOT THE ITEM ID (Jason, Session 258). "item:251222" is a debugging
--- string that reached the Slots page and was the ONLY thing on it — see
--- ns.ItemName for why. A blank row is invisible and an id is meaningless to a
--- raider; a word that says what is happening is neither.
---
--- ⚠️ THE RECORDER STILL WRITES "item:<id>" AND MUST. That placeholder goes
--- into SavedVariables and then into the export, where the SITE matches loot on
--- item_name — so it has to stay a value Record.ResolveItemInfo can recognise
--- and replace later. This constant is for DISPLAY only; the two are different
--- jobs and were never the same string by design.
ns.LOADING_NAME = "Loading…"

--- An item's name, asked of every source in turn.
---
--- ⚠️ OUR CATALOGUE IS NOT ENOUGH AND THIS IS THE WHOLE BUG. 232 BIS items are
--- absent from loot_items — they do not drop from a boss — so `items[id]` has
--- nothing for them, and FillItemNames used to stop there and write the id.
--- On the Loot tab that never showed, because entries arrive from the Encounter
--- Journal already carrying names; on the Slots page, which is built entirely
--- from `rankings`, it meant EVERY row read "item:251222".
---
--- The client knows these names. Asking it is one call, and a cold answer of nil
--- is what WarmItemNames exists to come back from.
function ns.ItemName(itemID, catalogue)
  if not itemID then return nil end
  catalogue = catalogue or ((ns.Data() or {}).items or {})
  local rec = catalogue[itemID]
  local fromUs = rec and ns.NonEmpty(rec.name)
  if fromUs then return fromUs end

  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if type(getInfo) ~= "function" then return nil end
  local ok, name = pcall(getInfo, itemID)
  if not ok then return nil end
  return ns.NonEmpty(name)
end

function ns.FillItemNames(entries, catalogue)
  catalogue = catalogue or ((ns.Data() or {}).items or {})
  local filled = 0
  for _, e in ipairs(entries or {}) do
    if e and (e.name == nil or e.name == "") then
      -- Our catalogue, then the CLIENT, then a word rather than an id.
      e.name = ns.ItemName(e.itemID, catalogue) or ns.LOADING_NAME
      filled = filled + 1
    end
  end
  return filled
end

--- Make sure every name on screen is a real one, and come back when it is not.
---
--- ⚠️ THE RECURRING ADDON BUG, FIXED AT THE SOURCE RATHER THAN PER VIEW (Jason,
--- Session 253: "this has bitten us SO MANY TIMES... figure that shit out once
--- and for all"). The shape is always identical: the client answers an item
--- query with NOTHING the first time and loads it in the background, the frame
--- draws once against that empty answer, and nothing ever draws again — so the
--- data appears only when something else forces a redraw, which is why closing
--- and reopening, or switching boss, "fixes" it.
---
--- TWO HALVES, AND ONLY HAVING ONE IS WHY IT KEPT COMING BACK:
---   1. ASK. C_Item.RequestLoadItemDataByID tells the client to go and get it.
---   2. COME BACK. An unconditional, coalesced re-render — NOT one that waits on
---      GET_ITEM_INFO_RECEIVED, because that event only fires when the client
---      actually had to load something. Journal.lua learned this the hard way
---      and its comment says so; this is the same rule applied everywhere else.
---
--- ⚠️ AND IT UNFREEZES STORED PLACEHOLDERS. A drop recorded before its item
--- resolved has "item:270160" written into SavedVariables. Redrawing renders the
--- same frozen string forever, so refreshing alone never fixed it —
--- Record.ResolveItemInfo has to re-read the record. Its own comment claims it
--- is "called before anything DISPLAYS", and the panel — the main display —
--- never called it. Only the Loot Log window did, which is exactly why the Loot
--- Log looked right while the panel did not.
---
--- Safe to call on every refresh: it does nothing when every name is real.
local itemWarmPending = false

function ns.WarmItemNames(entries)
  local unresolved = {}
  for _, e in ipairs(entries or {}) do
    local id = e and e.itemID
    -- A name that is still the id placeholder is not a name.
    -- BOTH placeholders count as unnamed: the display one this session
    -- introduced, and the recorder's id form, which still arrives from stored
    -- drops and is exactly what Record.ResolveItemInfo goes back for.
    local unnamed = (not e.name) or e.name == "" or e.name == ns.LOADING_NAME
      or (id and e.name == ("item:" .. tostring(id)))
    if id and unnamed then unresolved[#unresolved + 1] = id end
  end
  if #unresolved == 0 then return false end

  local req = C_Item and C_Item.RequestLoadItemDataByID
  if req then for _, id in ipairs(unresolved) do pcall(req, id) end end

  if itemWarmPending then return true end
  itemWarmPending = true
  if C_Timer and C_Timer.After then
    C_Timer.After(0.3, function()
      itemWarmPending = false
      -- Re-read the STORED records first, then redraw. In that order: the panel
      -- renders from the record, so refreshing before resolving shows the same
      -- placeholder again.
      if ns.Record and ns.Record.ResolveItemInfo then pcall(ns.Record.ResolveItemInfo) end
      if ns.Panel and ns.Panel.Refresh then pcall(ns.Panel.Refresh) end
    end)
  end
  return true
end

--- How the inspection sweep is going: how many people standing here we can
--- actually describe, out of how many are here at all.
---
--- ⚠️ THIS IS NOT "N OF M REPORTING" AND THE TWO ARE EASY TO CONFUSE (Jason,
--- Session 253, having reasonably assumed they were the same thing). Reporting
--- counts people BROADCASTING over addon comms — i.e. who else has this addon
--- installed — and is 0 in a group of strangers however well the sweep is
--- going. This counts what the sweep has resolved, from any source, which is
--- the question "is everyone inspected yet" actually asks.
---
--- Excludes yourself: you are never inspected, and counting yourself would make
--- a solo "1 of 1" that means nothing.
function ns.InspectionSummary()
  local R = ns.Roster
  if not (R and R.seen and R.NeedsInspect) then return nil end
  local here, resolved = 0, 0
  for _, e in pairs(R.seen) do
    if e.unit and not e.isSelf then
      here = here + 1
      -- NeedsInspect is false for "reporting live" too, which is correct: a
      -- self-report is a better answer than an inspection, not a missing one.
      if not R.NeedsInspect(e) then resolved = resolved + 1 end
    end
  end
  if here == 0 then return nil end
  return { resolved = resolved, here = here }
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

--- A section heading in two tones: the label in the heading purple, the value
--- in white, as ONE string for a single fontstring.
---
--- ⚠️ IN CORE FOR TWO REASONS, and the second one bit immediately. It is
--- display logic Panel.lua could hold, but Panel.lua is the file no harness
--- loads — and adding it there as a file-scope local pushed the chunk past Lua
--- 5.1's ceiling of 200 top-level locals, so the game would have refused the
--- whole file while lua5.4 compiled it happily. Core §1.1's S250/S254 box: the
--- limits differ at each layer, and luajit is the only check that sees them.
function ns.HeadingTwoTone(label, value)
  local S = ns.Style
  if not S then return (label or "") .. (value or "") end
  return S.code(S.COLOR.accent) .. (label or "") .. "|r" .. (value or "")
end

-- ---------------------------------------------------------------------------
-- The Slots page (Session 258)
-- ---------------------------------------------------------------------------
--
-- TWO THINGS PER SLOT: the item you want, and where it comes from. Everything
-- here answers the second half; the first is one lookup.
--
-- In Core rather than Panel.lua for the reason every other piece of logic is:
-- no harness loads a window file, so anything written there ships never having
-- run. Panel.lua renders the table this returns and decides nothing.

--- The rail, in the MOCK'S OWN ORDER, which is the character sheet's order and
--- not our payload's.
---
--- ⚠️ RINGS AND TRINKETS ARE ONE ROW EACH, NEVER NUMBERED (Jason). They are
--- interchangeable sockets that happen to number two, so there is no "BIS for
--- Trinket 1" — `sockets` is what carries the pairing, and it is used for
--- exactly two things: the one-of-two check state, and not claiming you are
--- done when one socket is still wrong.
---
--- `tex` is the name GetInventorySlotInfo answers to, so the icons come from
--- the CLIENT and no art has to be copied in at a new tier — unlike the boss
--- portraits, which do.
---
--- ⚠️ BACK ASKS FOR THE CHEST TEXTURE ON PURPOSE. There is no separate cloak
--- texture in the paperdoll set, and the mock draws Back with the chest icon,
--- so 13 icons cover the 14 loot-bearing rows. Reading "BACKSLOT" here would
--- diverge from the design for no gain.
ns.SLOT_ROWS = {
  { key = "HEAD",      label = "Head",      tex = "HEADSLOT",          sockets = 1 },
  { key = "NECK",      label = "Neck",      tex = "NECKSLOT",          sockets = 1 },
  { key = "SHOULDER",  label = "Shoulder",  tex = "SHOULDERSLOT",      sockets = 1 },
  { key = "BACK",      label = "Back",      tex = "CHESTSLOT",         sockets = 1 },
  { key = "CHEST",     label = "Chest",     tex = "CHESTSLOT",         sockets = 1 },
  { key = "WRIST",     label = "Wrist",     tex = "WRISTSLOT",         sockets = 1 },
  { key = "HANDS",     label = "Hands",     tex = "HANDSSLOT",         sockets = 1 },
  { key = "WAIST",     label = "Waist",     tex = "WAISTSLOT",         sockets = 1 },
  { key = "LEGS",      label = "Legs",      tex = "LEGSSLOT",          sockets = 1 },
  { key = "FEET",      label = "Feet",      tex = "FEETSLOT",          sockets = 1 },
  { key = "FINGER",    label = "Finger",    tex = "FINGER0SLOT",       sockets = 2 },
  { key = "TRINKET",   label = "Trinket",   tex = "TRINKET0SLOT",      sockets = 2 },
  { key = "MAIN_HAND", label = "Main Hand", tex = "MAINHANDSLOT",      sockets = 1 },
  { key = "OFF_HAND",  label = "Off Hand",  tex = "SECONDARYHANDSLOT", sockets = 1 },
}

--- The three views, in the mock's dropdown order. Values match the payload's
--- own context strings, so no translation table can drift.
ns.SLOT_VIEWS = {
  { key = "overall", label = "Overall BIS" },
  { key = "raid",    label = "Raid BIS" },
  { key = "mplus",   label = "M+ BIS" },
}

--- The chip a context is shown as. O / R / M, per the mock.
ns.BIS_CHIP = { overall = "O-BIS", raid = "R-BIS", mplus = "M-BIS" }

--- Our payload's slot keys folded onto the RAIL's rows.
---
--- The weapon keys all compete for the main hand — the same fold
--- extractSlotState has always done for TWO_HAND — and a rail row that could
--- never be selected is worse than one that pools a little.
local SLOT_FOLD = {
  ONE_HAND = "MAIN_HAND", TWO_HAND = "MAIN_HAND", RANGED = "MAIN_HAND",
}

--- INVTYPE (what the CLIENT answers) folded onto the same rows.
---
--- Needed because 232 BIS items are not in loot_items at all — they do not drop
--- from a boss — so our payload carries an id and nothing else and the slot has
--- to come from the client. GetItemInfoInstant is the right call: it reads the
--- static item database and answers SYNCHRONOUSLY, unlike GetItemInfo, so a
--- cold cache costs nothing here.
local INVTYPE_SLOT = {
  INVTYPE_HEAD = "HEAD", INVTYPE_NECK = "NECK", INVTYPE_SHOULDER = "SHOULDER",
  INVTYPE_CLOAK = "BACK", INVTYPE_CHEST = "CHEST", INVTYPE_ROBE = "CHEST",
  INVTYPE_WRIST = "WRIST", INVTYPE_HAND = "HANDS", INVTYPE_WAIST = "WAIST",
  INVTYPE_LEGS = "LEGS", INVTYPE_FEET = "FEET", INVTYPE_FINGER = "FINGER",
  INVTYPE_TRINKET = "TRINKET",
  INVTYPE_WEAPONMAINHAND = "MAIN_HAND", INVTYPE_2HWEAPON = "MAIN_HAND",
  INVTYPE_WEAPON = "MAIN_HAND", INVTYPE_RANGED = "MAIN_HAND",
  INVTYPE_RANGEDRIGHT = "MAIN_HAND",
  INVTYPE_WEAPONOFFHAND = "OFF_HAND", INVTYPE_HOLDABLE = "OFF_HAND",
  INVTYPE_SHIELD = "OFF_HAND",
}

--- Which rail row an item belongs to, our payload first and the client second.
function ns.SlotForItem(itemID, rec)
  local mine = rec and ns.ItemSlot(rec)
  if mine then return SLOT_FOLD[mine] or mine end
  -- ⚠️ THE GLOBAL, NOT THE C_Item MEMBER, and that is not a style choice. Both
  -- exist on retail, but ns.IsGearItem has been calling the global on a live
  -- 12.1 client since Session 250 — so this is the form that is PROVEN here,
  -- and one file reaching for the namespaced spelling is how two call sites
  -- come to disagree about which one the client has.
  if type(GetItemInfoInstant) ~= "function" or not itemID then return nil end
  local ok, _, _, _, equipLoc = pcall(GetItemInfoInstant, itemID)
  if not ok then return nil end
  return INVTYPE_SLOT[equipLoc or ""]
end

--- The empty-slot texture the character sheet itself draws.
function ns.SlotIcon(row)
  local fn = GetInventorySlotInfo
  if not (fn and row and row.tex) then return nil end
  local ok, _, tex = pcall(fn, row.tex)
  if not ok then return nil end
  return tex
end

--- The instance an encounter belongs to, by NAME.
---
--- ⚠️ THE PAYLOAD DOES NOT CARRY THIS. `bosses` holds name / order / enc and no
--- instance, so the second line of every source ("…, The Venomous Abyss") has
--- to come from the Encounter Journal, which already indexes it. Returns nil
--- rather than a guess when the journal has not been walked yet; the caller
--- prints the boss alone, which is still true.
function ns.InstanceNameFor(encounterID)
  local J = ns.Journal
  if not (J and J.InstanceForEncounter and J.CachedInstances) then return nil end
  local id = J.InstanceForEncounter(encounterID)
  if not id then return nil end
  for _, inst in ipairs(J.CachedInstances()) do
    if inst.id == id then return ns.NonEmpty(inst.name) end
  end
  return nil
end

--- Where an item comes from, as the two halves the mock prints separately.
---
--- ⚠️ A CRAFTED ITEM CANNOT BE DESCRIBED YET and is left blank rather than
--- guessed at. The mock draws "From Crafted: Inscription", but nothing in the
--- payload says an item is crafted or which profession makes it — 53 Overall
--- picks name an item in neither the raid nor the M+ list, which is what
--- crafted gear looks like from here. An emitter field would close it; until
--- then a missing line is honest and an invented one is not.
function ns.ItemSource(itemID, rec)
  if not (rec and rec.boss) then return nil end
  local data = ns.Data()
  local boss = data and data.bosses and data.bosses[rec.boss]
  local bossName = boss and ns.NonEmpty(boss.name)
  if not bossName then return nil end
  return { boss = bossName, instance = ns.InstanceNameFor(rec.boss) }
end

--- Where the Adventure Guide says an item drops — the answer for DUNGEON loot,
--- which our own tables know nothing about.
---
--- Returns the same { boss, instance } shape as ns.ItemSource, so the line reads
--- "From Avatar of Sethraliss, Temple of Sethraliss" with no second code path.
--- NIL while the guide is still cold, which is correct rather than unfortunate:
--- Journal.CachedLoot books a re-read and ScheduleWarm refreshes the panel, so
--- the line fills in rather than being guessed at.
function ns.JournalSource(itemID)
  if not (itemID and ns.Journal and ns.Journal.SourceIndex) then return nil end
  local hit = ns.Journal.SourceIndex()[itemID]
  -- An entry with no usable name is worse than none: it would draw "From ,".
  if not (hit and ns.NonEmpty(hit.boss)) then return nil end
  return { boss = hit.boss, instance = ns.NonEmpty(hit.instance) }
end

--- "From Crafted", but ONLY when the item says it is crafted.
---
--- ⚠️ POSITIVE SIGNAL ONLY. The item's own name-description is "Tidal Crafted"
--- on crafted gear, "Mythic+" on some dungeon drops, and empty on ordinary raid
--- loot — so this fires on a statement, never on an absence. Anything we cannot
--- confirm gets NO line, which is what it had before: a missing line reads as
--- "we do not know", a wrong one reads as a fact.
---
--- Returns the SAME SHAPE as ns.ItemSource so buildSourceLine needs no branch:
--- `boss` is the bold white run and there is no instance to follow it.
function ns.CraftedSource(q)
  local desc = q and q.nameDesc
  if type(desc) ~= "string" then return nil end
  if not desc:lower():find("crafted", 1, true) then return nil end
  return { boss = "Crafted" }
end

--- Where an item comes from, as one ladder, for every surface that draws the
--- line. Most authoritative first: our own raid table (which names the boss the
--- way the rest of the site does), then the Adventure Guide (the ONLY place
--- dungeon loot has a source at all, and it names the dungeon too), then the
--- item's own crafted claim.
---
--- ⚠️ ONE SEAM, BECAUSE THERE WERE TWO AND THEY DISAGREED (Session 260, Jason:
--- "a piece listed as a catalyze target that has NO location/source showing").
--- SlotsReport walked all three rungs; ObtainRoutes called ns.ItemSource ALONE,
--- so a route drawn from a dungeon drop or a crafted piece got no second line
--- while the pick directly above it got one. Desert Guardian's Breastplate is a
--- revamped-dungeon drop, so our raid table has never heard of it.
--- Core §1.1: a new surface must CALL the settled seam, not re-derive it.
---
--- `q` is optional — a tier TOKEN carries no BIS row, so it has no quality to
--- read a crafted claim off, and the other two rungs still answer for it.
function ns.SourceFor(itemID, rec, q)
  return ns.ItemSource(itemID, rec)
    or ns.JournalSource(itemID)
    or ns.CraftedSource(q)
end

-- ns.HasTierToken lived here until Session 261. It was the last CONDITION on the
-- tier-piece elimination — "a token exists for this slot, so an unsourced pick
-- in it must be tier" — and the emitted `ts` flag answers that question outright
-- from Blizzard's item-set membership. Deleted rather than left unused: a
-- plausible-looking helper with no callers is one somebody wires back in.
-- ObtainRoutes below still derives the token for its own purpose, which is
-- naming a route rather than classifying a piece.

--- Every way to end up holding one item.
---
--- ⚠️ THE TIER TOKEN CARRIES NO BIS ROW and never has, so it cannot be found by
--- asking which token is BIS. It is DERIVED, exactly as the Session 256 rule
--- says: the token whose own slot matches this row and whose class gate admits
--- you. 15 of 40 specs name no catalyse target for hands, so a tier slot
--- showing only the token is the NORMAL case and not an error state.
---
--- The catalyse SOURCE is the other direction: an item carrying `cat` converts
--- INTO this piece, and it is that item — not the piece — that is chased.
function ns.ObtainRoutes(itemID, slotKey, char)
  local out = {}
  local data = ns.Data()
  if not (data and data.items and itemID) then return out end

  for tokenID, rec in pairs(data.items) do
    if rec.slot == "TOKEN" and ns.ItemSlot(rec) == slotKey
      and (not char or ns.CanUse(rec, char.className, char.specName)) then
      out[#out + 1] = {
        itemID = tokenID, name = ns.ItemName(tokenID), kind = "TIER TOKEN",
        source = ns.SourceFor(tokenID, rec),
      }
    end
  end

  if data.rankings and char then
    for srcID in pairs(data.rankings) do
      local q = ns.Scoring.resolveQuality(
        data.rankings, srcID, char.className, char.specName, char.heroTree, nil)
      if q and q.catalysesInto == itemID then
        local rec = data.items[srcID]
        out[#out + 1] = {
          itemID = srcID, name = ns.ItemName(srcID),
          kind = "CATALYZE TARGET", source = ns.SourceFor(srcID, rec, q),
        }
      end
    end
  end

  table.sort(out, function(a, b)
    -- The token first, because it is the route that always exists.
    if (a.kind == "TIER TOKEN") ~= (b.kind == "TIER TOKEN") then
      return a.kind == "TIER TOKEN"
    end
    return (a.name or "") < (b.name or "")
  end)
  return out
end

--- The whole page, for one view.
---
--- ⚠️ THE VIEW IS CHOSEN, NEVER DERIVED FROM WHERE YOU STAND. CurrentContentScope
--- reads the instance you are in, which is right for the Loot tab and wrong for
--- a planning page browsed in a city — the answer would change as you walked
--- around. So contentScope is passed as nil here on purpose, and the view
--- filters the CONTEXTS instead.
---
--- ⚠️ OVERALL IS ITS OWN ANSWER, NOT A LABEL ON THE RAID PICK. Raid and M+
--- differ in 321 of 550 spec-slots, so these are three genuinely different
--- lists and folding them would be wrong in more than half of all cases.
function ns.SlotsReport(view)
  view = view or "overall"
  local out = { view = view, rows = {}, ready = false }

  local char = ns.ResolveCharacter and ns.ResolveCharacter()
  if char and char.className and char.specName then
    out.specLabel = char.specName .. " " .. char.className
  end
  local data = ns.Data()

  local bySlot = {}
  for _, row in ipairs(ns.SLOT_ROWS) do bySlot[row.key] = {} end

  if data and data.rankings and char and char.className and char.specName then
    out.ready = true
    for itemID in pairs(data.rankings) do
      local q = ns.Scoring.resolveQuality(
        data.rankings, itemID, char.className, char.specName, char.heroTree, nil)
      -- An item that CONVERTS into a tier piece is a route to that piece, not a
      -- pick of its own — it surfaces under OBTAINED BY, without a BIS chip,
      -- because two BIS chips in one slot group say nothing about which to chase.
      if q and q.bis and q.contexts and not q.catalysesInto then
        local inView = false
        for _, c in ipairs(q.contexts) do
          if c == view then inView = true end
        end
        if inView then
          local rec = data.items and data.items[itemID]
          local slotKey = ns.SlotForItem(itemID, rec)
          if slotKey and bySlot[slotKey] then
            local contexts = {}
            for _, c in ipairs(q.contexts) do contexts[c] = true end
            local owned = false
            if ns.EquippedCopy then owned = ns.EquippedCopy(slotKey, itemID) end
            local src = ns.SourceFor(itemID, rec, q)
            bySlot[slotKey][#bySlot[slotKey] + 1] = {
              itemID = itemID,
              -- Through ns.ItemName, not rec.name: a BIS pick is usually one of
              -- the 232 items our payload has no record of at all.
              name = ns.ItemName(itemID),
              contexts = contexts,
              -- ⚠️ "FROM CRAFTED" IS THE ITEM'S OWN CLAIM, NEVER AN INFERENCE
              -- (Jason, Session 259: "If it's not a crafted piece, don't label
              -- it a crafted piece"). The tempting signal was `rec == nil` —
              -- not in our raid loot table — but that is equally true of
              -- dungeon loot, tier pieces, world bosses and Delve gear, so it
              -- would have labelled all of them Crafted. `nd` is the
              -- name-description the item itself carries ("Tidal Crafted"),
              -- resolved through the same spec key ladder as the rest.
              --
              -- Rendered through the SAME shape a boss line uses, so it picks
              -- up the same weights with no second code path: `boss` is the
              -- bold white run, and a crafted item has no instance to name.
              source = src,
              owned = owned,
              -- HISTORY, because two sessions were spent narrowing this and the
              -- narrowing was the wrong move each time. Session 260 found the
              -- chip on Worldroot Canopy ("not in our raid table" is equally
              -- true of dungeon loot, crafted gear, world bosses and Delve
              -- gear), then on a WRIST (absence of a source is true of any
              -- slot). Both were answered by adding a CONDITION to an
              -- elimination, which shrinks a wrong answer without making it
              -- right — and ns.HasTierToken, the last of those conditions, is
              -- deleted along with this.
              --
              -- ⚠️ NOW THE POSITIVE TEST, AND THE ELIMINATION IS GONE (Session
              -- 261). `q.tierSet` is Blizzard's own item-set membership,
              -- resolved by the harvest from preview_item.set.item_set.name and
              -- emitted as `ts` — the "emit the answer, never infer it in Lua"
              -- move that already settled the item level and the crafted line.
              --
              -- WHAT THE OLD RULE COST: "not in our loot table AND nothing
              -- sourced it AND a token exists for this slot" is true of every
              -- dungeon, crafted and Delve pick in the five tier slots. 62 such
              -- picks were eligible for a TIER PIECE chip they should never have
              -- had — bounded only by whatever the player's own Adventure Guide
              -- happened to source, which is not a guarantee and is exactly the
              -- load-bearing dependency Session 260 was about.
              --
              -- ⚠️ NO FALLBACK TO THE OLD TEST WHEN `ts` IS ABSENT, deliberately.
              -- An older payload simply reports no tier pieces, which is a
              -- visible and harmless absence; falling back would restore the
              -- wrong answers for exactly the installs least able to notice.
              tierPiece = q.tierSet == true,
            }
          end
        end
      end
    end
  end

  for _, row in ipairs(ns.SLOT_ROWS) do
    local picks = bySlot[row.key]
    table.sort(picks, function(a, b)
      if a.owned ~= b.owned then return a.owned end
      return (a.name or tostring(a.itemID)) < (b.name or tostring(b.itemID))
    end)
    local ownedCount = 0
    for _, p in ipairs(picks) do if p.owned then ownedCount = ownedCount + 1 end end
    -- FULL means every socket this row has is already holding one of its picks;
    -- PARTIAL is the one-of-two case the paired slots exist for, and it is drawn
    -- dimmed rather than as a second full check.
    local check = "none"
    if ownedCount > 0 then
      check = (ownedCount >= (row.sockets or 1)) and "full" or "partial"
    end
    out.rows[#out.rows + 1] = {
      key = row.key, label = row.label, tex = row.tex,
      sockets = row.sockets or 1, picks = picks, check = check,
    }
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

--- OUR SLOT KEYS, IN THE GAME'S OWN WORDING.
---
--- ⚠️ TWO VOCABULARIES FOR ONE FIELD, AND THE USER WATCHED US SWITCH BETWEEN
--- THEM (Jason, Session 254). The row's second line was drawn from OUR payload
--- while the Adventure Guide was still cold, then redrawn from the Guide half a
--- second later — so it read "TRINKET" and then "Trinket", "SHOULDER" and then
--- "Shoulder". Both were right; only one was in the language the game speaks.
--- Normalising here makes the two sources produce the IDENTICAL string, so the
--- flicker becomes impossible rather than merely quick.
---
--- The wording deliberately mirrors JOURNAL_SLOT below, which already maps the
--- Guide's labels the other way. These are the two halves of one translation and
--- must stay in step.
---
--- ⚠️ A TIER TOKEN HAD NO LABEL AT ALL, so a token row drew its badge beside an
--- EMPTY second line (Venomwoven Effigy). "TOKEN" is a slot key we invented; it
--- is not a place on the body and the Guide has no word for it, so we supply one.
local SLOT_LABEL = {
  HEAD = "Head", NECK = "Neck", SHOULDER = "Shoulder", BACK = "Back",
  CHEST = "Chest", WRIST = "Wrist", HANDS = "Hands", WAIST = "Waist",
  LEGS = "Legs", FEET = "Feet", FINGER = "Finger", TRINKET = "Trinket",
  MAIN_HAND = "Main Hand", OFF_HAND = "Off Hand",
  ONE_HAND = "One-Hand", TWO_HAND = "Two-Hand", RANGED = "Ranged",
  TOKEN = "Tier Token",

  -- ⚠️ THE GUIDE'S OWN WORDING, NORMALISED TO OURS (Session 256). Every other
  -- entry above maps OUR key to the GAME's phrase, because matching the game is
  -- what stops the line changing under the reader when the Adventure Guide
  -- answers a beat after our payload. "Off Hand" is Jason's call and is the one
  -- place we deliberately differ from the client's wording — so the translation
  -- has to run the other way too, or an off-hand item would read "Off Hand" and
  -- then flip to "Held In Off-hand", which is precisely the flicker the rest of
  -- this table exists to prevent. JOURNAL_SLOT already accepts both spellings on
  -- the way IN; this is the same pair on the way OUT.
  ["Held In Off-hand"] = "Off Hand",
}

--- ⚠️ UNKNOWN VALUES PASS THROUGH UNTOUCHED, which is what makes this safe to
--- run over BOTH sources: the Guide's "Trinket" is not a key here and is left
--- exactly as it arrived, so this can never mangle a label the game gave us.
function ns.SlotLabel(slot)
  if type(slot) ~= "string" or slot == "" then return slot end
  return SLOT_LABEL[slot] or slot
end

--- "" IS NOT A VALUE. Returns nil for anything that is not a real string.
---
--- ⚠️ THE THIRD TIME THIS FAMILY HAS BITTEN IN ONE SESSION (Session 254), after
--- the blank item name and the blank fallback inside it. Here the Adventure
--- Guide answers "" for a tier token's slot; "" is TRUTHY, so `j.slot or
--- ourSlot` kept the empty one and a token drew its badge beside nothing — while
--- our payload had known the answer all along (tokenSlot="HANDS").
---
--- Use this at every seam where a value arrives from the client. The rule this
--- project already wrote says test for EMPTINESS, never truthiness; this is that
--- rule as a function so it stops being remembered case by case.
function ns.NonEmpty(s)
  if type(s) ~= "string" or s == "" then return nil end
  return s
end

function ns.ItemSlotLine(entry)
  if not entry then return "" end
  local slot, armor = ns.SlotLabel(entry.slotText), ns.NonEmpty(entry.armorType)
  -- ⚠️ A TIER TOKEN IS NOT AN ARMOUR PIECE AND SAYING ONLY ITS SLOT HIDES WHAT
  -- IT IS (Jason, Session 254: "it just says if it's an upgrade, but doesn't say
  -- Tier Token"). The slot is still worth carrying — a token is FOR a slot — so
  -- it leads, and the kind follows. ~17 characters at the 10px size, well inside
  -- the 150px line; measure before lengthening it.
  if entry.tokenItem then
    return slot and slot ~= "" and (slot .. ", Tier Token") or "Tier Token"
  end
  if armor and ARMOR_CLASS[armor] then
    return slot and slot ~= "" and (slot .. ", " .. armor) or armor
  end
  if armor and armor ~= "" then return armor end
  return slot or ""
end

--- The tooltip's box, from measured text. No frames: this is the arithmetic
--- behind Tip.lua, which is a window file the harness cannot load.
---
--- `lines` are measured entries { leftW, rightW, h, wrap }; opts carries the
--- design's spacing plus the title's own measurements. Returns the frame's size
--- and the y offset of every line, so the widget positions and never computes.
---
--- ⚠️ A DOUBLE LINE'S WIDTH IS BOTH COLUMNS PLUS THE TROUGH, not the wider of
--- the two. Taking the max is the easy mistake and it lets a label and its value
--- touch on exactly the widest row — the one most worth reading.
---
--- ⚠️ maxW CAPS PROSE, NEVER A TWO-COLUMN ROW. A wrapped paragraph should fold;
--- a label and a number have nowhere to fold TO, so capping them would overlap
--- the columns rather than narrow them.
function ns.TipLayout(lines, opts)
  opts = opts or {}
  local pad      = opts.pad or 10
  local lineGap  = opts.lineGap or 3
  local titleGap = opts.titleGap or 6
  local colGap   = opts.colGap or 18
  local maxW     = opts.maxW or 300

  local contentW = opts.titleW or 0
  for _, l in ipairs(lines or {}) do
    local w
    if (l.rightW or 0) > 0 then
      w = (l.leftW or 0) + colGap + l.rightW
    elseif l.wrap then
      -- ⚠️ SLACK, BECAUSE AN EXACT FIT IS NOT A FIT (Session 254). Giving a line
      -- precisely its own measured width wraps it: the client's text metrics and
      -- the font's advance widths disagree by a fraction, which is how two
      -- sentences measuring 297.7 and 295.8 both folded inside a 300 ceiling.
      w = math.min(math.ceil(l.leftW or 0) + 2, maxW)
    else
      w = l.leftW or 0
    end
    if w > contentW then contentW = w end
  end

  local y = pad
  if (opts.titleH or 0) > 0 then y = y + opts.titleH + titleGap end

  local ys = {}
  for i, l in ipairs(lines or {}) do
    ys[i] = y
    y = y + (l.h or 0)
    if i < #lines then y = y + lineGap end
  end

  return {
    contentW = contentW,
    w = contentW + pad * 2,
    h = y + pad,
    y = ys,
  }
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

--- Does the payload know vault levels at all? The only remaining reason to hide
--- the toggle: with no table there is no number to compute, so offering the
--- control would promise something nothing can answer.
function ns.VaultLevelsKnown()
  return ns.HasVaultData()
end

--- Should the Vault toggle be OFFERED?
---
--- ⚠️ THE AUTO GATE IS GONE (Session 257) and this REVERSES the Session 252
--- rule rather than quietly dropping it. That rule refused to offer the toggle
--- on AUTO because "the vault level of whatever this is" was a claim with no
--- stated subject — correct at the time, when the control read only "Auto". It
--- now reads "Auto: Heroic": the subject IS stated, it is visible on screen, and
--- it updates when you zone. The reason lapsed when that label changed.
---
--- What was actually costing us was the control VANISHING. A checkbox that is
--- present in the design and absent in the game reads as a missing feature, and
--- it took a screenshot from Jason to surface it.
function ns.VaultShown()
  return ns.VaultLevelsKnown()
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

--- Walking into an instance returns the Content control to AUTO.
---
--- ⚠️ A STICKY MANUAL CHOICE BECOMES A LIE THE NEXT TIME YOU ZONE IN (Jason,
--- Session 253). The control read "Raid: Heroic" through an entire LFR, so the
--- Full Loot Table scored every item at Heroic item levels in a wing that
--- cannot drop them — a wrong number under a confident label, which is what
--- Core §7.7 forbids. Nothing was broken; the control simply remembered a
--- choice made somewhere else.
---
--- A MANUAL PICK STILL WINS AND STILL STICKS. This resets only on the boundary
--- where the old choice is knowably stale — the moment you enter somewhere new.
--- Inside the instance, choose whatever you like and it holds.
---
--- Announced rather than silent: a control that changes itself without saying so
--- is worse than one that is wrong, because the next person to read it has no
--- reason to doubt it.
local contentWatcher = CreateFrame and CreateFrame("Frame")
if contentWatcher then
  contentWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
  contentWatcher:SetScript("OnEvent", function()
    if not (ns.Settings and GetInstanceInfo) then return end
    local ok, _, instanceType = pcall(GetInstanceInfo)
    if not ok then return end
    -- Only somewhere the control means something. Zoning into a city must not
    -- discard a choice made for the raid you are about to walk back into.
    if instanceType ~= "raid" and instanceType ~= "party" and instanceType ~= "scenario" then
      return
    end
    local was = ns.Settings.Get("difficulty")
    if was == nil or was == "AUTO" then return end
    ns.Settings.Set("difficulty", "AUTO")
    if ns.Print then
      ns.Print(("Content set back to Auto on entering the instance (was %s)."):format(tostring(was)))
    end
    if ns.Panel and ns.Panel.Refresh then pcall(ns.Panel.Refresh) end
  end)
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

--- The scale that puts this frame's units on WHOLE pixels.
---
--- ⚠️ THE TARGET IS A WHOLE NUMBER OF PIXELS PER UNIT, NOT ONE. Forcing 1 would
--- halve every window on a 4K display. What matters is that the number is an
--- integer: at 2.0 the client doubles every pixel exactly and nothing lands on a
--- boundary, while at 1.83 — where this addon has been — every glyph edge falls
--- between two pixels and gets resampled. That is the whole of "it looks blurry".
---
--- So: keep the size the user already has, and round it to the nearest whole
--- number of pixels per unit. On a 4K screen at the default scale that is 1.83
--- rounding to 2 — a 9% size change and nothing else.
---
--- @param parentScale number the effective scale this frame would inherit
--- @return number|nil ownScale to pass to SetScale, nil if it cannot be computed
--- @return number|nil pixelsPerUnit the whole number chosen
function ns.PixelSnapScale(parentScale)
  if type(GetPhysicalScreenSize) ~= "function" then return nil end
  local _, sh = GetPhysicalScreenSize()
  if type(sh) ~= "number" or sh <= 0 then return nil end
  if type(parentScale) ~= "number" or parentScale <= 0 then return nil end

  local factor  = 768 / sh                       -- UI units per physical pixel
  local current = parentScale / factor           -- pixels per unit with no scaling
  local target  = math.floor(current + 0.5)
  if target < 1 then target = 1 end              -- never collapse a window to nothing

  -- ⚠️ SNAPPING MUST BE NEARLY FREE, OR IT IS NOT SNAPPING — IT IS RESIZING.
  -- Jason measured the panel at 1.20x the size of the Figma frame at 100% and
  -- said, correctly, that it was massively larger than intended. This function
  -- was the cause: his client gives 1.667 pixels per unit, which rounds to 2 and
  -- makes every window 20% BIGGER than drawn.
  --
  -- The original note above reasons about 1.83 -> 2, which costs 9% and is a
  -- fair price for crisp glyph edges. It never asked what the price is at other
  -- ratios, and the answer is that it is unbounded in the middle: 1.5 -> 2 costs
  -- 33%. A window that does not match the design it was drawn from is a worse
  -- fault than a resampled edge, so the snap now DECLINES when it is expensive.
  --
  -- THE THRESHOLD IS DERIVED FROM THE TWO REAL CASES, not picked. Both are
  -- complaints Jason actually made, and 10% is the only band that satisfies
  -- both of them:
  --   · 1.83 -> 2 costs 9%. That is a 4K client at the default scale, it is the
  --     case this function was written for, and the crispness was worth it.
  --   · 1.667 -> 2 costs 20%. That is Jason's own client, and it made the panel
  --     visibly larger than the frame it was drawn from.
  -- The middle of the range is where it gets expensive — 1.5 -> 2 is 33% — and
  -- the original never asked what it was paying there.
  local drift = math.abs(target - current) / current
  if drift > 0.10 then return nil end

  -- SetScale is RELATIVE to the parent, so divide out what we already inherit.
  return (target * factor) / parentScale, target
end

function ns.MakeWindow(frame)
  if not frame then return end

  -- Put the window on whole pixels BEFORE anything is measured off it. Every
  -- window routes through here, so this is the one place that decides it — and
  -- the internal numbers are already whole, so once one unit is a whole number
  -- of pixels every offset inside lands on a pixel too, with no rounding pass.
  if frame.SetScale and frame.GetParent then
    local parent = frame:GetParent()
    local ps = parent and parent.GetEffectiveScale and parent:GetEffectiveScale()
    local own = ns.PixelSnapScale(ps)
    if own then pcall(frame.SetScale, frame, own) end
  end

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

  -- ⚠️ ESCAPE CLOSES ONE WINDOW, THE MOST RECENTLY OPENED (Jason, Session 258:
  -- "the Esc key should close them one at a time in reverse order").
  --
  -- THIS REPLACES UISpecialFrames, WHICH CANNOT DO THAT. Blizzard's
  -- CloseSpecialWindows() walks the whole list and hides EVERY shown frame in
  -- it, so with the panel, the import window, the loot log and settings all
  -- open, one press closed the entire addon. That was written here as though it
  -- were the desirable behaviour ("ONE press closes the whole addon rather than
  -- one window per press") — it is simply what the mechanism does, and it is
  -- not what a stack of windows should do.
  --
  -- The stack is ours instead, ordered by when each window was SHOWN, and the
  -- key handler below takes the top one off.
  ns.TrackWindow(frame)
  -- Every window routes through here, which makes it the one place that can
  -- know about all of them.
  ns.RegisterScaledWindow(frame)
end

-- ---------------------------------------------------------------------------
-- The window stack, and Escape
-- ---------------------------------------------------------------------------

--- Windows currently open, oldest first. The LAST entry is what Escape closes.
ns.windowStack = {}

local function stackRemove(frame)
  for i = #ns.windowStack, 1, -1 do
    if ns.windowStack[i] == frame then table.remove(ns.windowStack, i) end
  end
end

--- The one frame that listens for Escape.
---
--- ⚠️ KEYBOARD IS ENABLED ONLY WHILE ONE OF OUR WINDOWS IS OPEN, and the handler
--- PROPAGATES everything that is not Escape. A frame that swallows keys
--- permanently eats movement keys and hotbars, which is the standard way this
--- gets done wrong. An EditBox with focus still receives keys first, so typing
--- into the import box is unaffected — and Escape there clears its focus before
--- any of this sees it, which is the right order.
local escCatcher

local function ensureCatcher()
  if escCatcher then return escCatcher end
  escCatcher = CreateFrame("Frame", nil, UIParent)
  escCatcher:SetFrameStrata("TOOLTIP")
  escCatcher:EnableKeyboard(false)
  if escCatcher.SetPropagateKeyboardInput then
    escCatcher:SetPropagateKeyboardInput(true)
  end
  escCatcher:SetScript("OnKeyDown", function(self, key)
    if key ~= "ESCAPE" or #ns.windowStack == 0 then
      if self.SetPropagateKeyboardInput then self:SetPropagateKeyboardInput(true) end
      return
    end
    if self.SetPropagateKeyboardInput then self:SetPropagateKeyboardInput(false) end
    ns.EscapeTop()
    self:EnableKeyboard(#ns.windowStack > 0)
  end)
  return escCatcher
end

--- Close the most recently opened window. The whole of what Escape does, split
--- out so the headless harness can drive it — a key handler is the one part of
--- this that no test can press.
---
--- Returns the frame it closed, or nil when nothing was open.
function ns.EscapeTop()
  local top = table.remove(ns.windowStack)
  if top and top.Hide then top:Hide() end
  return top
end

--- Every window the size setting governs, registered as it is built.
---
--- ⚠️ IT IS NOT "PANEL SIZE", IT IS ADDON SIZE (Jason, Session 258: "the
--- scaling setting doesn't seem to impact the settings window itself. It should
--- apply to the main addon window, the raid data import window, the loot log
--- window and the settings window"). The setting existed to fix a mismatch
--- between WoW's UI units and the design's pixels — that mismatch is a property
--- of the MONITOR, so it applies to every window this addon draws, not to the
--- one that happened to be open when the control was written.
ns.scaledWindows = {}

function ns.RegisterScaledWindow(frame)
  if not frame then return end
  for _, f in ipairs(ns.scaledWindows) do if f == frame then return end end
  ns.scaledWindows[#ns.scaledWindows + 1] = frame
  ns.ApplyWindowScale(frame)
end

--- The stored size, as a multiplier on whatever the client gave the window.
--- Clamped here rather than at each call site so the slash command, the slider
--- and a hand-edited SavedVariables all land in the same range.
function ns.WindowScale()
  local pct = tonumber(ns.Settings and ns.Settings.Get("panelScale")) or 100
  if pct < 50 then pct = 50 elseif pct > 200 then pct = 200 end
  return pct / 100
end

--- Apply it to one window, or to all of them.
---
--- ⚠️ AGAINST THE WINDOW'S OWN BASELINE, remembered the first time it is seen.
--- MakeWindow has already pixel-snapped each frame to its own value, so scaling
--- from a shared constant would undo that — and re-reading GetScale each time
--- would compound the multiplier on every call.
--- A window that must NOT be resized right now, because the control being
--- dragged lives on it.
---
--- ⚠️ YOU CANNOT RESCALE THE WINDOW THAT OWNS THE SLIDER YOU ARE DRAGGING
--- (Jason, Session 258: "as you start moving it, the settings page flickers in
--- and out at a HUGE size. It's impossible to set it"). Resizing the settings
--- window moves and resizes the slider UNDER THE CURSOR, which changes the
--- value, which resizes the window again — a feedback loop, and the reason the
--- control was unusable.
---
--- The old comment on the panelScale spec said the window "resizes under the
--- drag" and that was FINE when this setting scaled the panel only: the slider
--- was on a different window and stayed still. Making the setting govern all
--- four windows — which is what it should do — is what turned live feedback
--- into a loop. So the live preview still happens, on every window EXCEPT the
--- one holding the control; that one catches up on release.
ns.scaleHeld = nil

function ns.ApplyWindowScale(frame)
  local list = frame and { frame } or ns.scaledWindows
  local mult = ns.WindowScale()
  for _, f in ipairs(list) do
    if f and f.SetScale and f ~= ns.scaleHeld then
      f._baseScale = f._baseScale or (f.GetScale and f:GetScale()) or 1
      pcall(f.SetScale, f, f._baseScale * mult)
    end
  end
end

--- Hold a window out of live scaling for the duration of a drag, then let it
--- catch up. Idempotent, and safe to release when nothing is held.
function ns.HoldWindowScale(frame)
  ns.scaleHeld = frame
end

function ns.ReleaseWindowScale()
  local held = ns.scaleHeld
  ns.scaleHeld = nil
  if held then ns.ApplyWindowScale(held) end
end

--- Put a window on the stack when it opens and take it off when it closes,
--- however it closes — a button, a slash command or Escape itself.
function ns.TrackWindow(frame)
  if not (frame and frame.HookScript) then return end
  frame:HookScript("OnShow", function(self)
    stackRemove(self)
    ns.windowStack[#ns.windowStack + 1] = self
    ensureCatcher():EnableKeyboard(true)
  end)
  frame:HookScript("OnHide", function(self)
    stackRemove(self)
    if escCatcher then escCatcher:EnableKeyboard(#ns.windowStack > 0) end
    -- ⚠️ A WINDOW THAT CLOSES MID-DRAG MUST RELEASE ITS SCALE HOLD, or the hold
    -- outlives the drag and that window can never be resized again. Put here
    -- rather than on the slider's own OnHide because a child's OnHide depends
    -- on the client propagating it — true in WoW, and not something worth
    -- resting a stuck-forever state on.
    if ns.scaleHeld == self then ns.ReleaseWindowScale() end
  end)
end

-- ---------------------------------------------------------------------------
-- Is the panel drawing on whole pixels?
-- ---------------------------------------------------------------------------
--
-- WoW draws the interface in an abstract space that is 768 units tall and then
-- stretches it onto the real screen. Blizzard's own PixelUtil states the
-- conversion (Blizzard_SharedXML/PixelUtil.lua, read rather than recalled):
--
--     uiUnitFactor = 768 / physicalScreenHeight
--     realPixels   = uiUnits * effectiveScale / uiUnitFactor
--
-- Substituting gives the whole story in one line:
--
--     realPixels = uiUnits * effectiveScale * physicalHeight / 768
--
-- When effectiveScale happens to EQUAL uiUnitFactor the two cancel and one unit
-- is exactly one pixel — the "pixel perfect" scale every crisp UI runs at. At
-- any other scale a font size of 12 lands on some fractional number of pixels,
-- every glyph edge falls between two of them, and the client resamples. Nothing
-- is wrong, nothing errors; it just goes soft. That is the entire mechanism
-- behind "the addon looks blurry next to that other one".
--
-- ⚠️ LOGIC LIVES HERE, NOT IN A WINDOW FILE. The settings window only prints
-- what this returns, so the arithmetic stays inside the harness's reach.
--- @return table|nil report, nil when the client cannot answer
function ns.DisplayReport(scaleOverride)
  -- ⚠️ NOT `local sw, sh = GetPhysicalScreenSize and GetPhysicalScreenSize()`.
  -- In a multiple assignment Lua adjusts `a and f()` to ONE value, so the height
  -- silently arrives nil and the whole report returns "no screen size". Written
  -- that way first; the harness below caught it before it reached the game.
  if type(GetPhysicalScreenSize) ~= "function" then return nil end
  local sw, sh = GetPhysicalScreenSize()
  if type(sh) ~= "number" or sh <= 0 then return nil end

  local scale = scaleOverride
  if not scale then
    scale = (UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 1
  end

  local factor  = 768 / sh
  local perfect = factor                      -- the scale at which 1 unit = 1 pixel
  local pxPerUnit = scale / factor            -- how many real pixels one unit covers

  -- A size is exact when it lands on a whole pixel. Compare against the ROUNDED
  -- value rather than testing equality on a float.
  local function pixelsFor(size)
    local px = size * pxPerUnit
    local nearest = math.floor(px + 0.5)
    return px, nearest, math.abs(px - nearest)
  end

  local sizes, worst = {}, 0
  for _, role in ipairs({ "title", "head", "row", "small", "tiny" }) do
    local size = ns.Style and ns.Style.SIZE and ns.Style.SIZE[role]
    if size then
      local px, nearest, err = pixelsFor(size)
      sizes[#sizes + 1] = { role = role, size = size, pixels = px, nearest = nearest, drift = err }
      if err > worst then worst = err end
    end
  end

  return {
    screenWidth  = sw,
    screenHeight = sh,
    scale        = scale,
    perfectScale = perfect,
    pixelsPerUnit = pxPerUnit,
    aligned      = math.abs(pxPerUnit - math.floor(pxPerUnit + 0.5)) < 0.001,
    worstDrift   = worst,          -- 0 = every size exact, 0.5 = worst possible
    sizes        = sizes,
    -- What a design should be drawn at so its numbers mean pixels.
    designHeight = sh,
  }
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
      out[#out + 1] = { id = inst.id, name = inst.name, order = #out + 1,
                        bis = ns.DungeonBisCount(inst.id) }
    end
  end
  return out
end

--- How many of a dungeon's drops are best-in-slot for the viewer.
---
--- ⚠️ THIS WAS A HARDCODED ZERO (Jason, Session 260: "shouldn't there be BIS
--- icons on some dungeons?"). Raid tiles have carried a diamond since the strip
--- was built, and the dungeon branch shipped with `bis = 0` written in as a
--- placeholder — so the mark could never appear on a dungeon however many BIS
--- picks it held. A literal that stands in for a calculation looks exactly like
--- a calculation that returns zero.
---
--- ⚠️ COUNTED OFF THE POOLED LIST, WHICH IS THE LIST THE TILE OPENS. A key
--- drops one chest, so the dungeon is the unit of loot and ns.DungeonLoot
--- already pools and deduplicates across its bosses. Counting any other way
--- would let the tile disagree with what it shows when clicked — and the test
--- asserts they match rather than trusting that they do.
---
--- Cheap after the season prewarm: DungeonLoot reads through CachedLoot, so a
--- refresh costs table walks rather than journal calls.
function ns.DungeonBisCount(instanceID)
  local data = ns.Data()
  if not (data and data.rankings and instanceID) then return 0 end
  local char = ns.ResolveCharacter and ns.ResolveCharacter()
  if not (char and char.className and char.specName) then return 0 end
  local scope = ns.CurrentContentScope and ns.CurrentContentScope() or nil

  local n = 0
  for _, j in ipairs((ns.DungeonLoot(instanceID))) do
    if j.itemID then
      local q = ns.Scoring.resolveQuality(
        data.rankings, j.itemID, char.className, char.specName, char.heroTree, scope)
      if q and q.bis then n = n + 1 end
    end
  end
  return n
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
--- The link for a BIS pick, built from the bonus IDs THE SOURCE PUBLISHED.
---
--- ⚠️ THIS ENDS THE GUESSING, AND THE GUESSING WAS THE BUG (Session 259). With
--- no stated ids the only question a consumer could ask was "is this item in our
--- raid loot table?" — a proxy for "is it raid loot" — and then it had to pick a
--- difficulty. That proxy is wrong for dungeon, crafted and tier picks alike: it
--- put a crafted bracer at the M+ drop level, and before that at its BASE level
--- of 28 beside an equipped 311, which read as the whole page being untrustworthy.
---
--- ⚠️ THE CLIENT RESOLVES IT, SO NOTHING HERE LEARNS WHAT "CRAFTED" MEANS. Handed
--- Martyr's Bindings' own ids the game draws "Tidal Crafted · Item Level 331"
--- itself. Every classification we would otherwise have had to derive — track,
--- rank, crafted, Mythic+ — is already in the string.
---
--- Returns NIL when the pick names none (one harvested row in 1884, plus every
--- catalyse SOURCE, which the guide never publishes ids for), so the caller keeps
--- whatever link it had rather than being handed a bare one.
function ns.BisItemLink(itemID, className, specName, heroTree)
  if not itemID then return nil end
  local data = ns.Data()
  local q = data and data.rankings and ns.Scoring.resolveQuality(
    data.rankings, itemID, className, specName, heroTree, nil)
  local ids = q and q.bonusIds
  if type(ids) ~= "string" or ids == "" then return nil end

  local list, n = {}, 0
  for part in ids:gmatch("[^:]+") do
    local v = tonumber(part)
    -- ⚠️ VALIDATED, NOT TRUSTED. One harvested string carries what looks like an
    -- ITEM id in the bonus field, so a malformed entry reaches here; a bad id
    -- would render a nonsense tooltip rather than erroring, which is the kind of
    -- wrong number this whole change exists to stop.
    if v and v > 0 and v == math.floor(v) then n = n + 1; list[n] = v end
  end
  if n == 0 then return nil end

  -- item : id : enchant : gem1-4 : suffix : unique : level : specID :
  -- modifiersMask : itemContext : numBonusIDs : bonusID...
  return ("item:%d::::::::::::%d:%s"):format(itemID, n, table.concat(list, ":"))
end

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
  if ns.ContentMode() ~= "mplus" then
    -- ⚠️ A RAID BOSS HAS TWO IDS AND THE DROP CARRIES THE OTHER ONE
    -- (Session 253). The tile is keyed by JOURNAL encounter id, because that is
    -- what the Encounter Journal answers with. A recorded drop carries the id
    -- from ENCOUNTER_END, which is the DungeonEncounter id — Entombed Sentinels
    -- is 2874 in the journal and 3445 on the kill. Returning the tile id alone
    -- compared 3445 against 2874 and matched nothing, so Current Drops read
    -- "NO DROPS CURRENTLY" on every raid boss forever; a full LFR recorded
    -- eighteen drops and displayed none of them.
    -- The payload now ships `enc` alongside, so accept EITHER.
    local set = { [tileId] = true }
    local data = ns.Data()
    local boss = data and (data.bosses or {})[tileId]
    if boss and boss.enc then set[boss.enc] = true end
    return set
  end
  local set = {}
  for _, enc in ipairs(ns.Journal and ns.Journal.CachedEncounters(tileId) or {}) do
    if enc.id then set[enc.id] = true end
  end
  return set
end
