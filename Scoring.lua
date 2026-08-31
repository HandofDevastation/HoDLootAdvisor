-- Scoring.lua — the Loot Advisor scoring engine, ported from app/lib/loot-advisor.ts
--
-- This file MUST produce byte-identical results to the website's TypeScript
-- engine. If the addon and the site ever disagree in front of the raid, the
-- whole thing loses credibility instantly. Parity is enforced by
-- test/parity.lua against fixtures generated from the REAL TS engine
-- (/api/loot-advisor/parity-fixtures) — the site is the oracle, always.
--
-- Pure Lua: no WoW API calls, no globals beyond the module table. That is what
-- lets it run under a standalone interpreter for the parity harness, with no
-- game, no group and no raid.
--
-- PORTING GOTCHAS, all deliberate — do not "simplify" these away:
--
--  * JS Math.round() rounds half AWAY from zero for positives (0.5 -> 1), which
--    math.floor(x + 0.5) reproduces exactly. Lua has no built-in round. Every
--    rounding site here goes through round() for that reason.
--  * Object.entries() in JS iterates in insertion order; Lua's pairs() is
--    UNORDERED. Floating-point addition is not associative, so summing the same
--    stats in a different order can differ in the last bits and land a
--    Math.round on the other side of a .5 boundary. sortedKeys() makes the Lua
--    side deterministic; the harness would catch any residual divergence.
--  * JS `??` only falls back on null/undefined, while Lua's `or` also falls back
--    on false. Anywhere a boolean could legitimately be false, this uses an
--    explicit nil check instead of `or`.

local M = {}

-- ─── Constants (mirrored from loot-advisor.ts) ──────────────────────────────

M.TRACK_RANK = {
  Veteran  = 1,
  Champion = 2,
  Hero     = 3,
  Myth     = 4,
}

M.BADGE_THRESHOLDS = { major = 55, moderate = 35, minor = 15 }

-- Which slots use an officer-assigned S/A/B tier that REPLACES stat alignment.
--
-- Today this is trinkets only, which is exactly what the TS engine does, so
-- parity holds. It is a SET rather than a hard-coded `slot == "TRINKET"` check
-- because the agreed BIS direction widens this same mechanism to every slot
-- (HoD_LootAddon_Experience.md §9.2). Widening later means adding keys here,
-- not touching the scorer, the sort and the emitter together.
M.RANKED_SLOTS = { TRINKET = true }

-- ─── Small helpers ──────────────────────────────────────────────────────────

--- JS Math.round equivalent for non-negative values. See the header note.
local function round(x)
  return math.floor(x + 0.5)
end

--- Deterministic key order, so stat summation cannot diverge from JS by
--- floating-point association. See the header note.
local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function isEmpty(t)
  return t == nil or next(t) == nil
end

-- ─── Tier multipliers ───────────────────────────────────────────────────────

--- Tier index (0-based, as in the TS) -> multiplier, spread evenly from 1.0 at
--- the best tier down to 0.0 at the worst. Three tiers reproduces the legacy
--- 1.0 / 0.5 / 0.0 exactly. One tier means "all equally good" -> full weight.
function M.tierMultiplier(tierIndex, tierCount)
  if tierCount <= 1 then return 1.0 end
  return 1 - tierIndex / (tierCount - 1)
end

--- Stat name -> multiplier for one spec's ordered stat_ranks.
--- `ranks` is a 1-based Lua array of tiers, each tier an array of stat names.
function M.statMultipliers(ranks)
  local out = {}
  if isEmpty(ranks) then return out end
  local count = #ranks
  for i = 1, count do
    -- i is 1-based here; the TS uses a 0-based index, hence (i - 1).
    local m = M.tierMultiplier(i - 1, count)
    for _, stat in ipairs(ranks[i] or {}) do
      out[stat] = m
    end
  end
  return out
end

--- Resolve a character's stat ranking from the emitted spec table.
--- Prefers their hero talent tree's override, falls back to the spec's base row.
--- Matched on class+spec TOGETHER — the raw Blizzard spec name is ambiguous for
--- 8 specs (Frost DK vs Frost Mage, Holy Paladin vs Holy Priest, ...).
function M.resolveSpecRanks(specs, className, specName, heroTree)
  local entry = specs and specs[className .. "/" .. specName]
  if not entry then return nil end
  if heroTree and entry.trees then
    local want = heroTree:lower()
    for tree, ranks in pairs(entry.trees) do
      if tree:lower() == want then return ranks end
    end
  end
  return entry.base
end

-- ─── Badge ──────────────────────────────────────────────────────────────────

function M.scoreToBadge(score)
  if score >= M.BADGE_THRESHOLDS.major    then return "major"    end
  if score >= M.BADGE_THRESHOLDS.moderate then return "moderate" end
  if score >= M.BADGE_THRESHOLDS.minor    then return "minor"    end
  return "sidegrade"
end

-- ─── F1 · item level delta (0-40) ───────────────────────────────────────────

function M.scoreIlvlDelta(candidateIlvl, equippedIlvl)
  local delta = candidateIlvl - equippedIlvl
  if delta <= 0 then return 0 end
  return math.min(delta * 2, 40)
end

-- ─── F2 · track gap (0-20) ──────────────────────────────────────────────────

function M.scoreTrackGap(candidateTrack, equippedTrack)
  local equipped  = M.TRACK_RANK[equippedTrack or "Veteran"] or M.TRACK_RANK.Veteran
  local candidate = M.TRACK_RANK[candidateTrack] or 0
  local gap = math.max(candidate - equipped, 0)
  return math.min(gap * 10, 20)
end

-- ─── F3 · stat alignment (0-30) ─────────────────────────────────────────────
-- Weighted average of the item's secondaries against the spec's ranking.
-- An unlisted stat scores 0 — no stat is ever penalised, it simply carries no
-- weight for this spec (the standing language rule: never call a stat "bad").

-- `spec` is nil when the character's spec is UNKNOWN, or a table { ranks = ... }
-- when it is known. That distinction is load-bearing and was a real port bug the
-- parity harness caught: the TS engine returns a neutral 15 for an unknown spec,
-- but 0 for a known spec scoring an item with no usable stats. Collapsing both
-- to "no ranks" made 3,840 cases diverge.
--
-- CONTRACT: the emitter guarantees every emitted spec carries a non-empty
-- `base` ranking (it skips any spec whose stat_ranks are missing and reports the
-- count), so `spec.ranks` being empty here means the item scores 0 rather than
-- silently falling back to something the addon was never sent.
function M.scoreStatAlignment(itemStats, spec)
  if spec == nil then return 15 end         -- unknown spec -> neutral, as in TS
  local ranks = spec.ranks
  if isEmpty(itemStats) then return 0 end

  local keys = sortedKeys(itemStats)

  local total = 0
  for _, k in ipairs(keys) do total = total + itemStats[k] end
  if total == 0 then return 0 end

  local multipliers = M.statMultipliers(ranks)

  local weighted = 0
  for _, k in ipairs(keys) do
    local m = multipliers[k] or 0
    weighted = weighted + (itemStats[k] / total) * m
  end

  return round(weighted * 30)
end

-- ─── F4 · tier completion (0-25) ────────────────────────────────────────────

function M.scoreTierCompletion(itemIsTier, currentPieceCount)
  if not itemIsTier then return 0 end
  if currentPieceCount >= 4 then return 0 end
  if currentPieceCount == 3 then return 25 end
  if currentPieceCount == 1 then return 10 end
  if currentPieceCount == 0 then return 5 end
  return 0
end

-- ─── F5 · declared need ─────────────────────────────────────────────────────
-- Always 0 on the website (intentionally abandoned). Kept so the factor
-- breakdown lines up 1:1 with the TS, and so the reserved Target work has an
-- obvious home if it ever becomes scored — which it currently must NOT be.

function M.scoreDeclaredNeed(declared)
  if declared then return 15 end
  return 0
end

-- ─── Item quality (replaces F3) ─────────────────────────────────────────────
--
-- ONE axis, fed by the most authoritative signal available. A trinket grade, a
-- BIS listing and stat alignment all answer the SAME question — "how good is
-- this item for this spec" — so they occupy one factor and the STRONGEST WINS
-- rather than stacking. A BIS trinket is usually S-graded; it must score 60
-- once, not 110.
--
-- This is the slot-agnostic override the Data Contract required: trinket grades
-- are simply the currently-populated case, and BIS widens the same mechanism.
--
-- SCALE (Jason, Session 244): "Overall BIS" and "S grade" make the same claim,
-- so they are worth the same, and the single-content BIS lists sit where A does.
-- B is minimal and C/D/F score NOTHING — nobody is excited by a B-grade trinket.
--
-- ⚠️ ZERO POINTS IS NOT ENOUGH ON ITS OWN. A graded trinket still collects
-- halved-ilvl + track gap = 40 for a raider in last season's gear, so an
-- F-grade read "Moderate". Low grades therefore CAP THE BADGE too.
--
-- MUST MATCH app/lib/loot-advisor.ts EXACTLY. The parity harness proves it.

M.GRADE_POINTS = {
  s = 60, a = 42, b = 14, c = 0, d = 0, f = 0,
  -- Tanks' "Defensive trinkets" is a CATEGORY, not a rank. Scored as B and
  -- labelled, with no systematic survival-vs-damage distinction.
  defensive = 14,
}

M.BIS_POINTS = { overall = 60, raid = 40, mplus = 40 }

M.GRADE_BUCKET = { s = 1, a = 2, b = 3, c = 3, d = 3, f = 3, defensive = 3 }

--- The badge a grade may not exceed, however large the gear gap.
M.GRADE_BADGE_CEILING = { c = "moderate", d = "minor", f = "sidegrade" }

local BADGE_ORDER = { sidegrade = 1, minor = 2, moderate = 3, major = 4 }

--- Clamp a badge down to a ceiling. Never raises it.
function M.capBadge(badge, ceiling)
  if not ceiling then return badge end
  if (BADGE_ORDER[badge] or 0) > (BADGE_ORDER[ceiling] or 0) then return ceiling end
  return badge
end

--- Returns score, bucket, ceiling — or nil when there is no quality signal and
--- F3 stat alignment should be used instead.
function M.scoreItemQuality(grade, bis)
  local gradePts = grade and M.GRADE_POINTS[grade] or nil
  local bisPts   = bis and M.BIS_POINTS[bis] or nil
  if gradePts == nil and bisPts == nil then return nil end

  -- STRONGEST WINS, never summed. A BIS listing overrides a low grade outright:
  -- the source calling an item best-in-slot knows about its effect, which a
  -- letter cannot contradict.
  if bisPts ~= nil and (gradePts == nil or bisPts > gradePts) then
    return bisPts, 1, nil
  end
  return gradePts, M.GRADE_BUCKET[grade], M.GRADE_BADGE_CEILING[grade]
end

--- Retained so older call sites keep working; the override is not trinket-only.
function M.scoreRankedOverride(grade)
  local score, bucket = M.scoreItemQuality(grade, nil)
  return score, bucket
end

-- ─── Main ───────────────────────────────────────────────────────────────────
--
-- candidate = {
--   equipped_ilvl, equipped_track, piece_count, declared_need,
--   ranked_tier,            -- "s"|"a"|"b" or nil
--   already_owns, owned_ilvl,
--   class_name, spec_name, hero_tree,
-- }
-- item = { slot, is_tier, stats }
--
-- Returns a table mirroring the TS ScoreResult's scoring-relevant fields.

function M.scoreCandidate(candidate, item, spec, candidateIlvl, candidateTrack)
  local isRankedSlot = M.RANKED_SLOTS[item.slot] == true
  local hasTier      = candidate.ranked_tier ~= nil

  local function blank(alreadyOwns)
    return {
      raw_score = 0,
      badge = "sidegrade",
      ilvl_delta = 0, track_gap = 0, stat_alignment = 0,
      tier_bonus = 0, declared_need = 0,
      is_ranked_override = false, ranked_tier = nil,
      already_owns = alreadyOwns,
      is_upgrade = false,
    }
  end

  -- Cannot equip two of the same trinket, but a HIGHER ilvl copy is still an
  -- upgrade. Exclude only when they already hold it at >= the candidate ilvl.
  if isRankedSlot and candidate.already_owns then
    local owned = candidate.owned_ilvl or candidateIlvl
    if candidateIlvl <= owned then
      return blank(true)
    end
  end

  -- Downgrade guard. TOKENS compare by TRACK, not raw ilvl: a raider already on
  -- the same or higher track gets nothing from the token regardless of their
  -- upgrade rank within it. Everything else compares ilvl. Exception: a ranked
  -- item they do not own yet is always shown, since its value is in the tier
  -- rather than the item level.
  local candidateRank = M.TRACK_RANK[candidateTrack] or 0
  local equippedRank  = M.TRACK_RANK[candidate.equipped_track or "Veteran"] or M.TRACK_RANK.Veteran

  local isToken       = item.slot == "TOKEN"
  local isIlvlUpgrade = candidateIlvl > candidate.equipped_ilvl
  local isTrackUpgrade = candidateRank > equippedRank
  local isRankedNotOwned = isRankedSlot and hasTier and not candidate.already_owns

  local isUpgrade
  if isToken then
    isUpgrade = (candidate.equipped_ilvl == 0) or isTrackUpgrade
  else
    isUpgrade = isIlvlUpgrade or isRankedNotOwned
  end

  if not isUpgrade then
    return blank(candidate.already_owns == true)
  end

  local f1 = M.scoreIlvlDelta(candidateIlvl, candidate.equipped_ilvl)
  -- HALVING STAYS TRINKET-ONLY, deliberately: it exists because a trinket's
  -- EFFECT dominates its item level, which is a fact about trinkets and not
  -- about ranked items generally. A BIS chest keeps its full ilvl delta.
  if isRankedSlot and hasTier then f1 = round(f1 / 2) end

  local f2 = M.scoreTrackGap(candidateTrack, candidate.equipped_track)
  local f4 = M.scoreTierCompletion(item.is_tier, candidate.piece_count)
  local f5 = M.scoreDeclaredNeed(candidate.declared_need)

  -- SLOT-AGNOSTIC: whatever quality signal exists for this spec+item replaces
  -- stat alignment, from a trinket grade or a BIS listing alike.
  local f3, isOverride, tierIndex, ceiling = 0, false, nil, nil
  local qScore, qBucket, qCeiling = M.scoreItemQuality(candidate.ranked_tier, candidate.bis)
  if qScore ~= nil then
    f3, tierIndex, ceiling = qScore, qBucket, qCeiling
    isOverride = true
  else
    f3 = M.scoreStatAlignment(item.stats, spec)
  end

  local raw = f1 + f2 + f3 + f4 + f5

  return {
    raw_score = raw,
    -- Ceiling applied AFTER the arithmetic: the score still reflects the real
    -- gear gap while the badge refuses to overstate a poor item.
    badge = M.capBadge(M.scoreToBadge(raw), ceiling),
    ilvl_delta = f1, track_gap = f2, stat_alignment = f3,
    tier_bonus = f4, declared_need = f5,
    is_ranked_override = isOverride, ranked_tier = tierIndex,
    already_owns = candidate.already_owns == true,
    is_upgrade = true,
  }
end

-- ─── Sort grouping ──────────────────────────────────────────────────────────
-- Ranked slots sort by tier bucket FIRST, raw score only within a bucket, and
-- a raider holding no copy outranks one merely upgrading a copy they own.
--   0/1 = S no-copy / owns · 2/3 = A · 4/5 = B · 6/7 = unranked
-- Non-ranked slots always return 0.
--
-- ⚠️ This is why the gap-from-the-leader display CANNOT assume row order equals
-- score order. Keep the monotonicity check that omits gaps when it does not —
-- never a per-slot special case, because BIS will generalise this to more slots.

--- The emitted keys for one character, MOST SPECIFIC FIRST. Mirrors the site's
--- pickRanking() ordering exactly: a tree beats a content scope, and the bare
--- "Class/Spec" key always exists as the floor — which is what makes this safe
--- and is the same property the standing base-spec rule protects.
---
--- ⚠️ BUILT BY APPENDING, never as a table literal. `{ a and x, y }` whose first
--- entry is nil makes ipairs iterate NOTHING (Core §1.1, "TWO LUA TRAPS THAT
--- FAIL SILENTLY") — and heroTree is nil for most characters, so a literal here
--- would resolve nothing for exactly the common case.
local function qualityKeys(className, specName, heroTree, contentScope)
  local base = className .. "/" .. specName
  local keys = {}
  if heroTree and contentScope then keys[#keys + 1] = base .. "/" .. heroTree .. "#" .. contentScope end
  if heroTree then keys[#keys + 1] = base .. "/" .. heroTree end
  if contentScope then keys[#keys + 1] = base .. "#" .. contentScope end
  keys[#keys + 1] = base
  return keys
end

--- Resolve an item's quality signals for one character: the letter GRADE, the
--- BIS listing, every context listing it, and the tier piece it catalyses into.
---
--- ⚠️ RESOLVED PER FIELD, not per entry. A grade and a BIS listing for the same
--- spec and item routinely live under DIFFERENT keys — grades can be scoped by
--- content ("Blood DK, Mythic+"), BIS listings never are, because the context is
--- the LISTING KIND rather than a filter. Returning the first entry that matched
--- would therefore find a scoped grade and silently drop the BIS listing sitting
--- on the base key. Each field falls back independently.
function M.resolveQuality(rankings, itemId, className, specName, heroTree, contentScope)
  local byKey = rankings and rankings[itemId]
  if not byKey then return nil end

  local grade, bis, contexts, catalysesInto, bonusIds, nameDesc, tierSet
  for _, key in ipairs(qualityKeys(className, specName, heroTree, contentScope)) do
    local e = byKey[key]
    if e then
      if grade == nil then grade = e.g end
      if bis == nil then bis = e.b; contexts = e.bx end
      if catalysesInto == nil then catalysesInto = e.cat end
      -- ⚠️ RESOLVED THROUGH THE SAME KEY LADDER AS EVERYTHING ELSE, and that is
      -- the whole reason it is read here rather than in Core.lua. The guide
      -- bakes its socket and stat choices into these ids, so 112 of 247 items
      -- carry a DIFFERENT string per spec — reading `bi` off the first entry in
      -- the table would hand most specs another spec's build.
      --
      -- ADDITIVE ONLY: nothing scored changes, and no existing field moves.
      if bonusIds == nil then bonusIds = e.bi end
      if nameDesc == nil then nameDesc = e.nd end
      -- ⚠️ BLIZZARD SAYS THIS IS A TIER PIECE; NOTHING HERE INFERS IT. The
      -- emitter resolves preview_item.set.item_set.name and ships the ANSWER,
      -- so this is a read rather than a rule. What it REPLACES is an
      -- elimination — not in our loot table, nothing sourced it, a token exists
      -- for the slot — which labelled ordinary dungeon and crafted picks in the
      -- five tier slots as tier.
      --
      -- ⚠️ nil MEANS NOT TIER, and that is only safe because the harvest asks
      -- the question for every pick in those five slots. Do not read an absence
      -- here as "unknown" and reintroduce a fallback guess.
      if tierSet == nil then tierSet = e.ts end
    end
  end

  if grade == nil and bis == nil and catalysesInto == nil then return nil end
  -- `bx` is omitted by the emitter when it would just repeat `b`, so rebuild it
  -- here: every caller wanting the LABEL wants the full set, and making that
  -- caller handle "sometimes absent" is how one of them ends up not handling it.
  if bis and not contexts then contexts = { bis } end
  return { grade = grade, bis = bis, contexts = contexts, catalysesInto = catalysesInto,
           bonusIds = bonusIds, nameDesc = nameDesc, tierSet = tierSet }
end

--- Just the letter grade. Kept as its own call because the scorer's ranked-tier
--- input is the grade alone, and most callers want nothing else.
function M.resolveRankedTier(rankings, itemId, className, specName, heroTree, contentScope)
  local q = M.resolveQuality(rankings, itemId, className, specName, heroTree, contentScope)
  return q and q.grade or nil
end

function M.getRankedSortGroup(result, slot)
  if not M.RANKED_SLOTS[slot] then return 0 end
  local owns = result.already_owns == true
  if not result.is_ranked_override then
    if owns then return 7 else return 6 end
  end
  local t = result.ranked_tier
  if t == 1 then if owns then return 1 else return 0 end end
  if t == 2 then if owns then return 3 else return 2 end end
  if t == 3 then if owns then return 5 else return 4 end end
  if owns then return 7 else return 6 end
end

-- WoW loads this file through the .toc, where a file-scope `return` is simply
-- discarded — so hand the module to the addon's private namespace as well.
-- Under the parity harness this file is require()d instead, where `...` is
-- (modname, filepath); the type check is what keeps that path untouched, and
-- the `return` below is what that path actually uses.
local _, ns = ...
if type(ns) == "table" then ns.Scoring = M end

return M
