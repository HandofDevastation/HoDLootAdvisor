-- Loot.lua — the loot path
--
-- One real handler, two ways in:
--   • a live roll        — START_LOOT_ROLL, read through the game's own API
--   • a fabricated roll  — /la test, built from the baked data
--
-- The dev path drives the SAME handler as the live path, not a parallel copy.
-- That is the whole point of it: group loot never fires in a dungeon (personal
-- loot), LFR queues for half an hour and cannot be repeated, and raid lockouts
-- mean a real roll is a once-a-week event. If the injected path were a separate
-- code path it would only ever prove that the separate code path works.
--
-- TWO SCOPES, and they degrade in that order. ScoreItem answers "is this for
-- ME" from the player's own equipped gear and needs nothing but the baked data.
-- RankRaiders answers "who is this FOR" and needs the raid payload (Payload B)
-- pasted in by the runner; without it the personal half still works.
--
-- Output goes to chat here and to the panel in Panel.lua. Chat lines are posted
-- ONLY by a deliberate trigger — see PostToChat.

local ADDON_NAME, ns = ...

local Loot = {}
ns.Loot = Loot

-- Badge labels + colours, matching BADGE_LABELS / BADGE_COLORS on the website so
-- the same item reads the same in game as on the page.
local BADGE = {
  major     = { label = "Major",     color = "ff6b6b" },
  moderate  = { label = "Moderate",  color = "C8962E" },
  minor     = { label = "Minor",     color = "a0a0b0" },
  sidegrade = { label = "Sidegrade", color = "888899" },
}

local function badgeText(badge)
  local b = BADGE[badge] or BADGE.sidegrade
  return "|cff" .. b.color .. b.label .. "|r"
end

local DIFF_LABEL = { n = "Normal", h = "Heroic", m = "Mythic" }

-- ---------------------------------------------------------------------------
-- Scoring one item for this character
-- ---------------------------------------------------------------------------

--- Returns a result table, ALWAYS — never nil, never a silent skip.
--- On failure it carries `reason`, because an item we cannot score still has to
--- appear, named, flagged as unscored (Data Contract §0: degrade loudly). The
--- drop list is driven by what the GAME reports, never by what our table holds.
---
--- opts = { itemLink, difficulty = "n"|"h"|"m", catalogue = true|nil,
---          vault = true|nil }
---
--- `vault` scores the item at its GREAT VAULT level instead of its drop level —
--- see the block on vault mode below.
---
--- `catalogue` marks itemLink as an Adventure Guide link rather than a real
--- drop's: it names the item but describes it at its base level, so it must not
--- decide the item level. See the block on candidate item level below.
function Loot.ScoreItem(itemID, opts)
  opts = opts or {}
  local out = { itemID = itemID, itemLink = opts.itemLink }

  local data = ns.Data()
  if not data then
    out.reason = "no static data loaded"
    return out
  end

  local rec = (data.items or {})[itemID]

  -- AN ITEM OUTSIDE OUR LOOT TABLE CAN STILL BE SCORED, when the caller can
  -- describe it. Dungeon loot is the case this exists for: we have never
  -- imported dungeon loot tables, but the Adventure Guide names the item and its
  -- slot, and a Mythic+ drop's item level is fixed (ns.MPLUS_ILVL). What the
  -- synthetic record cannot supply is a stat block — see ns.JournalRecord — so
  -- such an item scores its item-level gain and track gap in full, and its stat
  -- alignment as zero UNLESS it carries a BIS listing or a grade, which replace
  -- stat alignment outright. The picks that matter therefore score completely.
  --
  -- ⚠️ THE CALLER SUPPLIES IT; THIS NEVER INVENTS ONE. Falling back to a
  -- self-made record here would score every unrecognised drop against empty
  -- stats and a guessed slot, which is exactly the confident-wrong-answer the
  -- "unscored" path exists to avoid.
  if not rec and opts.record then
    rec = opts.record
    out.synthetic = true
  end

  out.rec = rec
  if not rec then
    out.reason = "not in this season's loot table"
    return out
  end
  out.name = rec.name

  local slot = ns.ItemSlot(rec)
  out.slot = slot
  if not slot then
    -- An omni-token exchanges for ANY tier slot, so there is no single equipped
    -- piece to compare it against. The website skips scoring these for exactly
    -- the same reason; EPGP still prices them.
    out.reason = (rec.slot == "TOKEN") and "omni-token — exchangeable for any tier slot"
                                        or "no comparable equipment slot"
    return out
  end

  local char = ns.ResolveCharacter()
  out.char = char

  -- Eligibility BEFORE scoring, never after: the scorer has no opinion about
  -- armor types, so an ineligible item would otherwise come back with a real
  -- badge on it. The item is still reported — it dropped, it is real, and
  -- hiding it would be the silent-omission failure — just never ranked.
  local usable, why = ns.CanUse(rec, char.className, char.specName)
  if not usable then
    out.ineligible = true
    out.reason = why
    return out
  end

  local spec = ns.SpecFor(char)
  out.specKnown = spec ~= nil

  -- Candidate item level. A real drop carries a LINK, and the link's bonus IDs
  -- give the item level that actually dropped — better data than our table,
  -- which only knows the per-difficulty value. The table is the fallback.
  local diffKey = opts.difficulty or ns.DifficultyKey()
  out.difficulty = diffKey

  local bonusIDs
  local candidateIlvl

  -- ⚠️ A CATALOGUE LINK IS NOT A DROP LINK, and reading it as one is why dungeon
  -- items showed ilvl 292 / Veteran instead of 311 / Hero. The Adventure Guide's
  -- link describes the item at its BASE level — it has no idea what key level
  -- you would run — so DetailedIlvl answers the base and the track resolves from
  -- that. The rule the file already states about uncached links applies here for
  -- the same reason: an item level that looks like data and is not.
  --
  -- A SYNTHETIC RECORD DECLARES ITS OWN LEVEL and that declaration wins. The
  -- record exists precisely because the caller knows something the link does not
  -- — for Mythic+ that a +10 and a +20 both drop Hero 3/6 (ns.MPLUS_ILVL).
  --
  -- This does NOT affect real drops: a drop carries no synthetic record, so its
  -- link is still the best answer and is still preferred over our table.
  --
  -- ⚠️ AND THE SAME TRAP SAT UNDERNEATH IT FOR RAID LOOT, unfixed until Session
  -- 252, because `rec.synthetic` is a PROXY FOR DUNGEONS rather than for "this
  -- link came out of a catalogue". A raid item IS in our table, so it has a real
  -- record and took this branch — reading the Adventure Guide's link, which
  -- knows nothing about which difficulty you are browsing. Every item in the
  -- Full Loot Table therefore showed ONE item level on Heroic and Mythic alike;
  -- the 13-point difference between the two tracks simply never appeared, and
  -- the difficulty control looked inert. `opts.catalogue` says the thing the
  -- proxy was standing in for, and the caller is the only one who knows it: the
  -- browse list is a catalogue, Current Drops is not.
  if opts.itemLink and not rec.synthetic and not opts.catalogue then
    local parsed = ns.ParseItemLink(opts.itemLink)
    bonusIDs = parsed and parsed.bonusIDs
    candidateIlvl = ns.DetailedIlvl(opts.itemLink)
  end
  if not candidateIlvl then
    candidateIlvl = (rec.ilvl or {})[diffKey] or 0
    -- No link: synthesise the bonus ID this item would carry at this difficulty
    -- and drop rank, so the track resolves the same way it would from a link.
    --
    -- ⚠️ NOT FOR A DUNGEON ITEM. The bonus-ID blocks are RAID difficulty blocks
    -- (Normal->Champion, Heroic->Hero, Mythic->Myth), so attaching one to a
    -- Mythic+ drop would state a raid provenance it does not have — and the
    -- selected raid difficulty would then move a dungeon item's track, which is
    -- fixed. The ladder alone resolves it, unambiguously: 311 is Hero 3/6 and
    -- nothing else on the current ladder.
    if not rec.synthetic then
      bonusIDs = bonusIDs or ns.BonusIdsFor(diffKey, rec.dropRank)
    end
  end
  -- ── GREAT VAULT MODE ──────────────────────────────────────────────────────
  -- Score the piece as the WEEKLY CHEST would hand it over rather than as the
  -- boss drops it — a full track higher in Season 2. ns.ApplyVault owns the
  -- rule; Loot.RankRaiders calls the SAME function so the item column and the
  -- detail pane cannot state different levels for one item.
  if opts.vault then
    candidateIlvl, bonusIDs, out.vaultReward =
      ns.ApplyVault(rec, diffKey, candidateIlvl, bonusIDs)
  end

  out.candidateIlvl = candidateIlvl

  local track, rank = ns.ResolveTrack(candidateIlvl, bonusIDs)
  out.candidateTrack, out.candidateRank = track, rank

  local equipped = ns.EquippedSlotState(slot) or { ilvl = 0, track = nil, empty = true }
  out.equipped = equipped

  local owns, ownedIlvl = ns.EquippedCopy(slot, itemID)
  local pieces, setIdsKnown = ns.TierPieceCount()
  out.tierPieces, out.setIdsKnown = pieces, setIdsKnown

  -- Grade AND best-in-slot, resolved together (schema 2). They are ONE quality
  -- axis and the scorer takes the strongest — never their sum.
  local quality = ns.Scoring.resolveQuality(
    data.rankings, itemID, char.className or "", char.specName or "", char.heroTree,
    ns.CurrentContentScope and ns.CurrentContentScope() or nil
  )
  out.quality    = quality
  out.rankedTier = quality and quality.grade or nil

  local candidate = {
    equipped_ilvl  = equipped.ilvl or 0,
    equipped_track = equipped.track,
    piece_count    = pieces,
    declared_need  = false,
    ranked_tier    = out.rankedTier,
    bis            = quality and quality.bis or nil,
    already_owns   = owns,
    owned_ilvl     = ownedIlvl,
  }
  local item = { slot = slot, is_tier = rec.tier == true, stats = rec.stats or {} }

  out.result = ns.Scoring.scoreCandidate(candidate, item, spec, candidateIlvl, track)
  return out
end

-- ---------------------------------------------------------------------------
-- Reporting it
-- ---------------------------------------------------------------------------

local function itemLabel(out)
  if out.itemLink then return out.itemLink end
  if out.name then return out.name end
  return "item " .. tostring(out.itemID)
end

local function trackLabel(track, rank)
  if not track then return "off-ladder" end
  if rank then return ("%s %d/6"):format(track, rank) end
  return track
end

function Loot.Report(out)
  if out.reason then
    -- Two different things, and conflating them would be misleading: an
    -- INELIGIBLE item is working correctly and simply is not for you, while an
    -- unscored one means our data fell short.
    local tag = out.ineligible and "|cff888899not for you|r" or "|cffff4444unscored|r"
    ns.Print(("%s — %s (%s)"):format(itemLabel(out), tag, out.reason))
    return
  end

  local r = out.result
  local head = ("%s — %s"):format(itemLabel(out), badgeText(r.badge))
  if not r.is_upgrade then
    head = ("%s — |cff888899not an upgrade for you|r"):format(itemLabel(out))
  end
  ns.Print(head)

  ns.Line(("%s · %s ilvl %d (%s) vs your %s"):format(
    out.slot,
    DIFF_LABEL[out.difficulty] or out.difficulty,
    out.candidateIlvl,
    trackLabel(out.candidateTrack, out.candidateRank),
    out.equipped.empty and "|cffff6b6bempty slot|r"
      or ("%d (%s)"):format(out.equipped.ilvl, trackLabel(out.equipped.track))
  ))

  if r.is_upgrade then
    local parts = {}
    parts[#parts + 1] = ("ilvl %d"):format(r.ilvl_delta)
    parts[#parts + 1] = ("track %d"):format(r.track_gap)
    if r.is_ranked_override then
      parts[#parts + 1] = ("tier %s %d"):format(tostring(out.rankedTier):upper(), r.stat_alignment)
    else
      parts[#parts + 1] = ("stats %d"):format(r.stat_alignment)
    end
    if r.tier_bonus > 0 then parts[#parts + 1] = ("set %d"):format(r.tier_bonus) end
    -- The raw score is printed HERE and nowhere a raider would see it in
    -- normal use. On the website it is never displayed at all — four summed
    -- heuristics invite false precision — but this is the developer path, and
    -- the breakdown is the only way to tell a scoring bug from a data bug.
    ns.Line(("score %d = %s"):format(r.raw_score, table.concat(parts, " + ")))
  elseif r.already_owns then
    ns.Line("You already have this at the same or higher item level.")
  end

  if not out.specKnown then
    ns.Line("|cffff4444No stat ranking for your spec|r — stats scored as neutral. /la for detail.")
  end
  if out.rec and out.rec.tier and not out.setIdsKnown then
    ns.Line("|cffC8962ESet piece count unverified|r — no equipped item reported a set id.")
  end
end

-- ---------------------------------------------------------------------------
-- Ranking everyone
-- ---------------------------------------------------------------------------
--
-- The point of the whole system: not "is this an upgrade for me" but "who is
-- this drop actually for". Needs the raid payload; without it this returns nil
-- and the caller falls back to the personal view.
--
-- Every raider on the roster is scored, including ones who are not an upgrade —
-- they are filtered for DISPLAY, never dropped silently. A raider who is absent
-- from a ranking cannot be told apart from one the addon never knew about.

--- Returns rows, or nil when no payload is loaded.
--- Each row: { name, class, spec, result, pr, rank, gap, eligible, reason }
function Loot.RankRaiders(itemID, opts)
  opts = opts or {}
  -- ⚠️ ONLY THE BAKED DATA IS REQUIRED (Session 256). This asked for a loaded
  -- raid-night export too, and returned nil without one — so the ranked table
  -- was dead for anyone who has never imported, which is every install outside
  -- this guild and every pug or LFR night. The export carries EPGP priority and
  -- a gear snapshot; neither is what makes a ranking possible. Who is here comes
  -- from the group, their gear from inspection, their spec from the client, and
  -- the scoring from the payload baked into the addon.
  local data = ns.Data()
  if not data then return nil end
  local raid = ns.Payload.Current()

  local rec = (data.items or {})[itemID]
  if not rec then return nil end
  local slot = ns.ItemSlot(rec)
  if not slot then return nil end

  local candidateIlvl = opts.candidateIlvl
  local candidateTrack = opts.candidateTrack
  if not candidateIlvl then
    local diffKey = opts.difficulty or ns.DifficultyKey()
    candidateIlvl = (rec.ilvl or {})[diffKey] or 0
    local bonusIDs = ns.BonusIdsFor(diffKey, rec.dropRank)
    -- Same seam the personal scorer uses — see ns.ApplyVault. Whoever is asking
    -- "who is this for" must be asking about the same item level the column
    -- beside it is showing.
    if opts.vault then
      candidateIlvl, bonusIDs = ns.ApplyVault(rec, diffKey, candidateIlvl, bonusIDs)
    end
    candidateTrack = ns.ResolveTrack(candidateIlvl, bonusIDs)
  end

  local rows = {}
  -- The EXPORT's roster plus anyone in the instance it has never heard of —
  -- alts, trials, pugs. See Payload.EffectiveRoster.
  for _, r in ipairs(ns.Payload.EffectiveRoster()) do
    local usable, why = ns.CanUse(rec, r.c, r.s)
    if usable then
      -- nil means we can describe neither their export gear nor anything seen
      -- in game, which only happens for an ad-hoc raider. They are skipped
      -- HERE and surfaced by ns.Roster.Unresolved(), rather than ranked on a
      -- zero that would make every item a maximum upgrade for them.
      local state = ns.Payload.SlotState(r, slot)
      if state then
      local owns, ownedIlvl = ns.Payload.OwnsCopy(r, slot, itemID)

      local ranks = ns.Scoring.resolveSpecRanks(data.specs, r.c or "", r.s or "", r.h)
      local spec = ranks and { ranks = ranks } or nil

      local quality = ns.Scoring.resolveQuality(
        data.rankings, itemID, r.c or "", r.s or "", r.h,
        ns.CurrentContentScope and ns.CurrentContentScope() or nil
      )

      -- Tier pieces ride in the export, so an ad-hoc raider has none to read and
      -- scores 0 — the honest answer for someone we can only see from outside.
      -- YOURS are countable from your own equipment, and the personal column
      -- already counts them that way; leaving your row on 0 would grade a tier
      -- token differently in two places on one screen.
      local pieces = r.tier or 0
      if r.me and ns.TierPieceCount then pieces = (ns.TierPieceCount()) or 0 end

      local result = ns.Scoring.scoreCandidate(
        {
          equipped_ilvl  = state.ilvl or 0,
          equipped_track = state.track,
          piece_count    = pieces,
          declared_need  = false,
          ranked_tier    = quality and quality.grade or nil,
          bis            = quality and quality.bis or nil,
          already_owns   = owns,
          owned_ilvl     = ownedIlvl,
        },
        { slot = slot, is_tier = rec.tier == true, stats = rec.stats or {} },
        spec, candidateIlvl, candidateTrack
      )

      -- ── The spec they are ACTUALLY in, when it is not the one they are
      -- ranked as ────────────────────────────────────────────────────────────
      --
      -- THE RANKING DOES NOT MOVE. The roster's spec is the officer-set one and
      -- stays the basis of the score — that is a settled decision, and the rule
      -- behind it (rules/HoD_Rules_Loot-Gear.txt "SCORE THE SPEC THEY RAID")
      -- exists because a live observation once mis-scored a healer as DPS.
      --
      -- But a raider who genuinely plays two specs by fight is not that case,
      -- and a TRINKET's grade is per spec: the same item can be an A for the
      -- spec they are ranked as and an S for the one they are standing in. So
      -- the alternative is CARRIED, for the panel to show and a human to weigh.
      --
      -- Ad-hoc raiders are skipped: they are already scored on their observed
      -- spec, so there is no second answer to offer.
      local altSpec = nil
      if not r.adhoc and ns.Roster and ns.Roster.IdentityFor then
        local ident = ns.Roster.IdentityFor(r.n)
        if ident and ident.spec and ident.spec ~= r.s then
          altSpec = {
            spec = ident.spec,
            tree = ident.heroTree,
            source = ident.source,
            quality = ns.Scoring.resolveQuality(
              data.rankings, itemID, r.c or "", ident.spec, ident.heroTree,
              ns.CurrentContentScope and ns.CurrentContentScope() or nil
            ),
          }
        end
      end

      rows[#rows + 1] = {
        name = r.n, class = r.c, spec = r.s, tree = r.h,
        result = result,
        quality = quality,
        altSpec = altSpec,
        equipped = state,
        -- The "+26 ilvl" a row displays, computed ONCE here rather than at each
        -- surface. It is also the only form of it that survives the wire: a
        -- ranking received from the runner carries no equipped state to
        -- subtract from, so every consumer reading this field is what lets a
        -- received row and a locally computed one render through one path.
        ilvlGain = candidateIlvl - (state.ilvl or 0),
        pr = r.pr, rank = r.rank,
        adhoc = r.adhoc,
        sortGroup = ns.Scoring.getRankedSortGroup(result, slot),
        eligible = true,
      }
      end
    else
      rows[#rows + 1] = { name = r.n, class = r.c, spec = r.s, eligible = false, reason = why }
    end
  end

  -- Upgrade magnitude orders the list (Arrangement A), with the ranked-slot tier
  -- group taking precedence where it applies. Priority is a COLUMN, not the
  -- sort — a raider with the highest PR and the smallest upgrade should be
  -- visibly both, not silently reordered into first place.
  local ranked = {}
  for _, row in ipairs(rows) do
    if row.eligible and row.result.is_upgrade then ranked[#ranked + 1] = row end
  end
  table.sort(ranked, function(a, b)
    if a.sortGroup ~= b.sortGroup then return a.sortGroup < b.sortGroup end
    if a.result.raw_score ~= b.result.raw_score then
      return a.result.raw_score > b.result.raw_score
    end
    return (a.name or "") < (b.name or "")
  end)

  -- GAP FROM THE LEADER, and the precondition that makes it meaningful: it is
  -- only valid when row order equals SCORE order, which ranked slots break by
  -- sorting on tier group first. Check monotonicity and omit the gaps entirely
  -- rather than special-casing the slot — BIS will generalise this failure to
  -- more slots, and a negative gap in front of the raid is worse than none.
  local monotonic = true
  for i = 2, #ranked do
    if ranked[i].result.raw_score > ranked[i - 1].result.raw_score then
      monotonic = false
      break
    end
  end
  if monotonic and #ranked > 0 then
    local top = ranked[1].result.raw_score
    for i, row in ipairs(ranked) do
      row.gap = (i == 1) and 0 or (row.result.raw_score - top)
    end
  end

  return ranked, rows, {
    slot = slot, ilvl = candidateIlvl, track = candidateTrack, rec = rec,
    -- The two halves of "N of M raiders can use it". Carried on meta because a
    -- ranking that arrived over comms has no `rows` to count.
    usable = #ranked, total = #rows,
    -- Whether a PRIORITY column has anything to say. EPGP reaches the addon only
    -- in the export, so with none loaded every cell would be an em-dash under a
    -- heading — a number we failed to find, rather than a question that does not
    -- apply here. Same reasoning that hides the standing block and the Standings
    -- tab together (rules/HoD_Rules_Loot-Gear.txt, "NO STANDING WITHOUT A RAID
    -- NIGHT"); a column is the third place that claim is made and it must agree
    -- with the other two.
    priority = raid ~= nil,
    -- Whether an EXPORT underlies this ranking at all, which is a different
    -- question from whether it carried standings. It is what makes the ad-hoc
    -- asterisk mean anything: "not on tonight's raid roster" is information when
    -- there IS a roster and noise when there is not — with no export everyone
    -- present is equally unknown to us, so marking them all says nothing.
    roster = raid ~= nil,
  }
end

--- The ranking to DISPLAY for one item: the runner's, when they have sent one.
---
--- ⚠️ THE RUNNER COMPUTES, EVERYONE DISPLAYS (Data Contract §4) — a settled
--- decision that was not implemented. handlers.DROPS stored the runner's
--- ranking and refreshed the panel, and the panel then called RankRaiders and
--- recomputed the whole thing locally; Comms.AuthoritativeRanking had no
--- callers at all. Every client scoring for itself is exactly the divergence
--- the rule exists to prevent: clients hear different subsets of GEAR
--- self-reports, so two panels can order the same drop differently in front of
--- the raid.
---
--- FALLS BACK TO LOCAL, deliberately. Nothing has been received for a Boss-tab
--- item, and nothing has been received in the seconds before the runner's
--- broadcast lands. A locally computed list is the right answer there — it is
--- what a lone installer sees, and it is right whenever gear reports agree.
---
--- Returns rows, all, meta, runnerName. `all` is nil for a received ranking:
--- the wire carries the people who can use the item, and the counts behind
--- "N of M" ride on meta instead.
function Loot.RankingFor(itemID, opts)
  local comms = ns.Comms
  if comms and comms.AuthoritativeRanking and not comms.IsRunner() then
    local rows, from, meta = comms.AuthoritativeRanking(itemID)
    if rows and #rows > 0 then
      local display = {}
      for i, r in ipairs(rows) do
        display[i] = {
          name = r.name,
          class = r.class,
          result = { badge = r.badge },
          -- Rebuilt from the raw grade/bis rather than a rendered tag, so
          -- ns.QualityTag formats it here exactly as it did on the runner's
          -- screen. Absent quality stays absent — never invented locally,
          -- which would reintroduce the disagreement in miniature.
          quality = (r.grade or r.bis) and { grade = r.grade, bis = r.bis } or nil,
          gap = r.gap,
          ilvlGain = r.gain,
          pr = r.pr,
          adhoc = r.adhoc,
          fromRunner = true,
        }
      end
      -- Read off the ROWS, not from whether we hold an export. A client with no
      -- payload of its own still shows priorities when the runner's ranking
      -- carried them, and shows none when it did not — the column follows the
      -- data on screen rather than a fact about this client.
      local anyPr = false
      for _, r in ipairs(display) do
        if r.pr then anyPr = true; break end
      end

      return display, nil, {
        usable = (meta and meta.usable) or #display,
        total  = meta and meta.total,
        priority = anyPr,
        -- A ranking can only be BROADCAST by a runner, and only an import makes
        -- anyone the runner — so a received list always has a roster behind it,
        -- whether or not this client holds one.
        roster = true,
      }, from
    end
  end

  local ranked, all, meta = Loot.RankRaiders(itemID, opts)
  return ranked, all, meta, nil
end

local CLASS_COLOR = {
  ["Death Knight"] = "C41E3A", ["Demon Hunter"] = "A330C9", ["Druid"] = "FF7C0A",
  ["Evoker"] = "33937F", ["Hunter"] = "AAD372", ["Mage"] = "3FC7EB",
  ["Monk"] = "00FF98", ["Paladin"] = "F48CBA", ["Priest"] = "FFFFFF",
  ["Rogue"] = "FFF468", ["Shaman"] = "0070DD", ["Warlock"] = "8788EE",
  ["Warrior"] = "C69B6D",
}

local function coloredName(row)
  local hex = CLASS_COLOR[row.class or ""] or "FFFFFF"
  return ("|cff%s%s|r"):format(hex, row.name or "?")
end

--- Print the ranked list. `limit` caps the rows shown; the rest are counted, not
--- hidden — "and 6 more" is honest where simply stopping is not.
function Loot.ReportRanking(itemID, opts)
  -- RankingFor for the same reason the panel and the chat post use it: this is
  -- a display, and a client showing its own arithmetic while the runner shows
  -- theirs is the disagreement Data Contract §4 exists to prevent.
  local ranked, _, meta = Loot.RankingFor(itemID, opts)
  if not ranked then return false end

  local limit = (opts and opts.limit) or 5
  -- From the data, not from meta.rec: a received ranking carries counts and
  -- rows, never our item record.
  local data = ns.Data()
  local rec = (data and (data.items or {})[itemID]) or {}

  local total = meta.total
  ns.Print(total
    and ("%s — %d of %d raiders can use it"):format(
      rec.name or ("item " .. itemID), meta.usable or #ranked, total)
    or ("%s — %d raiders can use it"):format(
      rec.name or ("item " .. itemID), meta.usable or #ranked))

  if #ranked == 0 then
    ns.Line("Not an upgrade for anyone on the roster.")
    return true
  end

  for i = 1, math.min(limit, #ranked) do
    local row = ranked[i]
    local bits = { ("%d. %s"):format(i, coloredName(row)) }
    bits[#bits + 1] = badgeText(row.result.badge)
    if row.gap and row.gap < 0 then
      bits[#bits + 1] = ("%d"):format(row.gap)
    elseif row.gap == 0 and i > 1 then
      bits[#bits + 1] = "tie"
    end
    bits[#bits + 1] = ("+%d ilvl"):format(row.ilvlGain or 0)
    if row.pr then
      bits[#bits + 1] = ("PR %.2f"):format(row.pr)
    else
      bits[#bits + 1] = "|cff888899no standing|r"
    end
    ns.Line(table.concat(bits, "  "))
  end

  if #ranked > limit then
    ns.Line(("…and %d more"):format(#ranked - limit))
  end

  return true
end

-- ---------------------------------------------------------------------------
-- Posting to chat
-- ---------------------------------------------------------------------------
--
-- NEVER automatic. The runner presses a button per item, which is what keeps
-- this from being spam and is why the "how chatty should it be" question does
-- not need a universal answer — the chatty case simply never fires unless
-- somebody chooses it, item by item.
--
-- This is also the ONLY part of the system non-installers ever see, so it has
-- to carry the answer on its own: item, then ranked names with badges.

--- Where a posted line should go. AUTO follows the group you are actually in,
--- so the same button works in a raid, a 5-man, or solo testing.
--- ⚠️ AN INSTANCE GROUP TAKES INSTANCE_CHAT, AND IT IS NOT OPTIONAL. In an LFR
--- the group is raid-sized, so IsInRaid() is true and this returned "RAID" —
--- which the client REFUSES with "You are not in a raid group", posting
--- nothing. The same ladder Comms.Channel already walks, for the same reason;
--- the two were only ever different because this one was written first.
local function instanceChannel()
  local category = (Enum and Enum.PartyCategory and Enum.PartyCategory.Instance)
    or _G.LE_PARTY_CATEGORY_INSTANCE
  if not (category and IsInGroup) then return false end
  local ok, inInstanceGroup = pcall(IsInGroup, category)
  return ok and inInstanceGroup and true or false
end

local function resolveChannel()
  local want = ns.Settings.Get("channel")
  -- SAY works anywhere and is the one choice an instance group does not
  -- invalidate, so it is honoured as asked. RAID / RAID_WARNING / PARTY name a
  -- channel that does not EXIST in an instance group, so they redirect rather
  -- than being refused by the client and posting nothing at all.
  if want == "SAY" then return "SAY" end
  if instanceChannel() then return "INSTANCE_CHAT" end
  if want ~= "AUTO" then return want end
  if IsInRaid and IsInRaid() then return "RAID" end
  if IsInGroup and IsInGroup() then return "PARTY" end
  return nil   -- solo: nothing to broadcast to
end

--- Chat messages cap at 255 bytes; a long item name plus five accented names
--- can exceed it, and an over-long SendChatMessage is REJECTED rather than
--- truncated, so the line would silently never appear.
local function clamp(text, limit)
  limit = limit or 255
  if #text <= limit then return text end
  return text:sub(1, limit - 1) .. "…"
end

--- Build the lines for one item. Returned rather than sent, so the same code
--- feeds both the real post and the preview shown in the drops window.
function Loot.ChatLines(itemID, opts)
  -- RankingFor, like the panel: a line posted to raid chat is the most public
  -- display there is, so a non-runner pressing Post must post the RUNNER's
  -- ranking rather than a second opinion computed from a different set of gear
  -- reports. It also means someone who never imported tonight's roster can
  -- still post a real list instead of "no raid night imported".
  local ranked = Loot.RankingFor(itemID, opts)
  local data = ns.Data()
  local rec = data and (data.items or {})[itemID]
  local name = (rec and rec.name) or ("item " .. tostring(itemID))

  if not ranked then
    -- ⚠️ NOT "no raid night imported" ANY MORE (Session 256). Ranking no longer
    -- needs an export, so the only way here is an item this season's table
    -- cannot describe — and only the runner can post, so whoever reads this line
    -- HAS imported one. It said the opposite.
    return { ("[Loot Advisor] %s — not in the season's loot table"):format(name) }
  end
  if #ranked == 0 then
    return { ("[Loot Advisor] %s — not an upgrade for anyone here"):format(name) }
  end

  local limit = ns.Settings.Get("names")
  local showGap = ns.Settings.Get("showGap")

  local parts = {}
  for i = 1, math.min(limit, #ranked) do
    local row = ranked[i]
    local badge = (BADGE[row.result.badge] or BADGE.sidegrade).label
    local bit = ("%d. %s %s"):format(i, row.name or "?", badge)
    if showGap and row.gap and row.gap < 0 then
      bit = bit .. (" %d"):format(row.gap)
    end
    parts[#parts + 1] = bit
  end

  local tail = ""
  if #ranked > limit then tail = ("  (+%d more)"):format(#ranked - limit) end

  return {
    clamp(("[Loot Advisor] %s"):format(name)),
    clamp(table.concat(parts, "   ") .. tail),
  }
end

--- Post one item's ranking. Returns ok, err.
function Loot.PostToChat(itemID, opts)
  local channel = resolveChannel()
  local lines = Loot.ChatLines(itemID, opts)

  if not channel then
    -- Solo or a channel that does not apply: show what WOULD have been sent
    -- rather than failing silently, so the button is testable outside a raid.
    ns.Print("not in a group — this is what would be posted:")
    for _, line in ipairs(lines) do ns.Line(line) end
    return false, "not in a group"
  end

  for _, line in ipairs(lines) do
    SendChatMessage(line, channel)
  end
  return true
end

-- ---------------------------------------------------------------------------
-- The real handler
-- ---------------------------------------------------------------------------
--
-- roll = { rollID, rollTime, itemLink, itemID, name, canNeed, canGreed,
--          canTransmog, source = "live" | "dev" }

-- What has dropped recently, newest last. This is what the drops window lists
-- and what each chat button is attached to. Kept in memory only: it describes
-- one pull, and a stale list surviving a reload would be worse than an empty one.
Loot.recent = {}

local RECENT_CAP = 12

function Loot.RememberDrop(roll, out)
  for _, d in ipairs(Loot.recent) do
    -- Same item rolling again in the same pull is the same drop to us.
    if d.itemID == roll.itemID and d.rollID == roll.rollID then return d end
  end
  local entry = {
    itemID = roll.itemID,
    rollID = roll.rollID,
    name   = (out and out.name) or roll.name or ("item " .. tostring(roll.itemID)),
    link   = roll.itemLink,
    badge  = out and out.result and out.result.badge or nil,
    reason = out and out.reason or nil,
    at     = time(),
  }
  Loot.recent[#Loot.recent + 1] = entry
  while #Loot.recent > RECENT_CAP do table.remove(Loot.recent, 1) end
  return entry
end

function Loot.ClearRecent()
  Loot.recent = {}
  if ns.Panel then ns.Panel.Refresh() end
end

--- Open the panel for a drop, when the runner has asked for that.
---
--- ⚠️ TWO PATHS PRODUCE A DROP AND ONLY ONE USED TO REACH HERE (Session 253).
--- This lived inline in HandleRoll, which is driven by START_LOOT_ROLL — the
--- LEGACY roll system. Modern group loot arrives through C_LootHistory instead,
--- so in a live LFR eighteen drops were recorded across two bosses and the
--- panel never opened once, with "Open Panel On A Drop" switched ON. Nothing
--- errored: the opener simply was not on that path.
---
--- ⚠️ AND I CALLED IT "NOT A BUG" FIRST, from the setting's default being false
--- without checking whether Jason had turned it on. He had.
---
--- The decision is recorded on EVERY branch, including the "setting is off" one
--- — a log that goes quiet in exactly the case it was added to explain is the
--- S249 trap, and this is a feature whose whole failure mode is silence.
function Loot.AutoOpen(why)
  local on = ns.Settings and ns.Settings.Get("autoOpen") and true or false
  if ns.Diagnostics then
    ns.Diagnostics.Note("autoOpen", { why = why, enabled = on, havePanel = ns.Panel ~= nil })
  end
  if not (on and ns.Panel) then return false end

  -- pcall'd on its own so a fault in the panel can never break the scoring and
  -- recording path, which is the half that matters when loot is on the line.
  local shown, err = pcall(ns.Panel.Show)
  if not shown and ns.Diagnostics then
    ns.Diagnostics.Note("panelShowError", { why = why, err = tostring(err) })
  end
  return shown and true or false
end

function Loot.HandleRoll(roll)
  if not roll or not roll.itemID then
    ns.Warn("loot roll with no resolvable item — nothing to score.")
    return
  end

  -- ⚠️ OPEN FIRST, SCORE AFTER. This used to be the LAST thing the handler did,
  -- behind scoring, chat reporting, the ranking, the recorder and a comms
  -- broadcast — and the whole handler runs inside a pcall, so a throw anywhere
  -- in that chain silently took the panel with it. The symptom is a window that
  -- opens on some kills and not others for reasons that have nothing to do with
  -- the kill: a cold item cache, one unlucky item, an edge case in the roster.
  --
  -- Nothing above this line can fail: we have a roll and an item id. Opening
  -- here means the setting does what it says regardless of what happens next,
  -- and Panel.Refresh at the end still fills it in once the drop is recorded.
  --
  -- pcall'd on its own so the reverse is also true — a fault in the panel can
  -- never break the scoring and recording path, which is the half that matters
  -- when loot is actually on the line.
  Loot.AutoOpen("startLootRoll")

  local out = Loot.ScoreItem(roll.itemID, {
    itemLink   = roll.itemLink,
    difficulty = roll.difficulty,
  })
  out.roll = roll
  Loot.Report(out)

  local bits = {}
  if roll.canNeed == false then bits[#bits + 1] = "|cffff6b6byou cannot Need this|r" end
  if roll.rollTime and roll.rollTime > 0 then
    bits[#bits + 1] = ("%ds to roll"):format(math.floor(roll.rollTime / 1000 + 0.5))
  end
  if roll.source == "dev" then bits[#bits + 1] = "|cff888899(injected)|r" end
  if #bits > 0 then ns.Line(table.concat(bits, " · ")) end

  -- The cross-raider answer, when a raid payload has been loaded. This is the
  -- half that makes the addon worth running for the raid rather than for you.
  Loot.ReportRanking(roll.itemID, { limit = 5 })

  Loot.RememberDrop(roll, out)

  -- THE RUNNER COMPUTES, EVERYONE DISPLAYS (Data Contract §4). With a partial
  -- install each client hears a different subset of GEAR self-reports, so two
  -- people scoring independently can produce slightly different orderings for
  -- the same drop — which, in front of the raid, is the one thing that would
  -- cost this tool its credibility outright. The runner's ranking is therefore
  -- broadcast and taken as authoritative.
  --
  -- ⚠️ THIS IS AN ADDON MESSAGE, NOT CHAT. It is invisible to the raid; nothing
  -- here can post a line anyone reads. The rule that the addon never speaks to
  -- the raid on its own is about SendChatMessage, which is still behind the
  -- Post button and untouched by this.
  if ns.Comms and ns.Comms.IsRunner() then
    local ranked, _, meta = Loot.RankRaiders(roll.itemID, { difficulty = roll.difficulty })
    if ranked and #ranked > 0 then
      ns.Comms.BroadcastDrops(roll.itemID, ranked, meta)

      -- ── The one thing the raid can actually see ─────────────────────────
      -- THREE CONDITIONS, ALL REQUIRED, and each is doing separate work:
      --   · the setting is on          — off by default; nobody is opted in
      --                                  by an update they did not read about
      --   · we are the runner          — checked above; otherwise every
      --                                  installer posts the same shortlist
      --   · it is a guild run          — ns.IsGuildRun, which fails closed
      -- The Post button is untouched and still works everywhere, including
      -- the places this deliberately will not fire.
      if ns.Settings and ns.Settings.Get("autoPost") and ns.IsGuildRun() then
        Loot.PostToChat(roll.itemID, { difficulty = roll.difficulty })
      end
    end
  end

  -- Opening happened at the TOP of this function, before anything that can
  -- fail. This just fills in what the drop added. Opening is OPT-IN and off by
  -- default: an addon that throws a window over your screen mid-pull gets
  -- uninstalled before it proves anything.
  if ns.Panel then pcall(ns.Panel.Refresh) end

  return out
end

--- Live entry point. rollTime is milliseconds and gives the panel a REAL
--- countdown rather than a guess, which is why it is carried through.
---
--- The roll frame appears REGARDLESS of Need eligibility (verified in
--- GroupLootFrame_OnShow, 12.1.0): Blizzard shows the frame and then greys the
--- Need button. So ineligibility is something to DISPLAY, not a reason to skip.
--- The only case with nothing to show is name == nil.
function Loot.OnStartLootRoll(rollID, rollTime)
  if not rollID then return end

  local texture, name, count, quality, bindOnPickUp, canNeed, canGreed,
        canDisenchant, reasonNeed, reasonGreed, reasonDisenchant,
        deSkillRequired, canTransmog = GetLootRollItemInfo(rollID)

  if not name then return end

  local link = GetLootRollItemLink and GetLootRollItemLink(rollID)
  local parsed = link and ns.ParseItemLink(link)

  Loot.HandleRoll({
    rollID      = rollID,
    rollTime    = rollTime,
    itemLink    = link,
    itemID      = parsed and parsed.itemID,
    name        = name,
    quality     = quality,
    canNeed     = canNeed,
    canGreed    = canGreed,
    canTransmog = canTransmog,
    reasonNeed  = reasonNeed,
    source      = "live",
  })
end

-- Its own frame, registered independently of Diagnostics: the observer must be
-- switchable without switching the addon's behaviour off with it.
local frame = CreateFrame("Frame")
local ok = pcall(frame.RegisterEvent, frame, "START_LOOT_ROLL")
if ok then
  frame:SetScript("OnEvent", function(_, event, ...)
    if event == "START_LOOT_ROLL" then
      -- Never let a scoring error break the roll UI or spam the raid.
      local handled, err = pcall(Loot.OnStartLootRoll, ...)
      if not handled then
        ns.Warn("error scoring a loot roll: " .. tostring(err))
        if ns.Diagnostics then ns.Diagnostics.Note("handlerError", tostring(err)) end
      end
    end
  end)
else
  Loot.eventUnavailable = true
end

-- ---------------------------------------------------------------------------
-- Developer entry points
-- ---------------------------------------------------------------------------

--- Accepts a bare item id or a shift-clicked item link, plus an optional
--- trailing n/h/m difficulty.
local function parseArgs(rest)
  rest = tostring(rest or "")
  local itemID = tonumber(rest:match("|Hitem:(%d+)")) or tonumber(rest:match("^%s*(%d+)"))
  local diff = rest:match("%s+([nhmNHM])%s*$")
  local link = rest:match("(|c%x+|Hitem:.-|h.-|h|r)")
  return itemID, diff and diff:lower() or nil, link
end

local function needItem(rest, usage)
  local itemID, diff, link = parseArgs(rest)
  if not itemID then
    ns.Warn(usage)
    return nil
  end
  return itemID, diff, link
end

--- Score an item without pretending anything rolled.
function Loot.ScoreCommand(rest)
  local itemID, diff, link = needItem(rest, "usage: /la score <itemID or item link> [n|h|m]")
  if not itemID then return end
  Loot.Report(Loot.ScoreItem(itemID, { itemLink = link, difficulty = diff }))
  Loot.ReportRanking(itemID, { difficulty = diff, limit = 5 })
end

--- The full ranked roster for one item — the planning view, usable before a
--- boss is even pulled ("who should we prioritise here").
function Loot.WhoCommand(rest)
  local itemID, diff = needItem(rest, "usage: /la who <itemID or item link> [n|h|m]")
  if not itemID then return end
  if not ns.Payload.Current() then
    ns.Warn("nothing imported yet — use |cffF3C56B/la load|r and paste tonight's export.")
    return
  end
  Loot.ReportRanking(itemID, { difficulty = diff, limit = 20 })
end

--- Fabricate a roll and drive the REAL handler with it.
function Loot.TestCommand(rest)
  local itemID, diff, link = needItem(rest, "usage: /la test <itemID or item link> [n|h|m]")
  if not itemID then return end

  local data = ns.Data()
  local rec = data and (data.items or {})[itemID]

  if ns.Diagnostics then
    ns.Diagnostics.Note("devInject", { itemID = itemID, difficulty = diff })
  end

  Loot.HandleRoll({
    rollID      = -1,          -- negative: cannot collide with a real roll id
    rollTime    = 47000,
    itemLink    = link,
    itemID      = itemID,
    name        = rec and rec.name,
    canNeed     = true,
    canGreed    = true,
    canTransmog = false,
    difficulty  = diff,
    source      = "dev",
  })
end
