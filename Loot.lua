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
--- opts = { itemLink, difficulty = "n"|"h"|"m" }
function Loot.ScoreItem(itemID, opts)
  opts = opts or {}
  local out = { itemID = itemID, itemLink = opts.itemLink }

  local data = ns.Data()
  if not data then
    out.reason = "no static data loaded"
    return out
  end

  local rec = (data.items or {})[itemID]
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
  if opts.itemLink then
    local parsed = ns.ParseItemLink(opts.itemLink)
    bonusIDs = parsed and parsed.bonusIDs
    candidateIlvl = ns.DetailedIlvl(opts.itemLink)
  end
  if not candidateIlvl then
    candidateIlvl = (rec.ilvl or {})[diffKey] or 0
    -- No link: synthesise the bonus ID this item would carry at this difficulty
    -- and drop rank, so the track resolves the same way it would from a link.
    bonusIDs = bonusIDs or ns.BonusIdsFor(diffKey, rec.dropRank)
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
  local data = ns.Data()
  local raid = ns.Payload.Current()
  if not (data and raid) then return nil end

  local rec = (data.items or {})[itemID]
  if not rec then return nil end
  local slot = ns.ItemSlot(rec)
  if not slot then return nil end

  local candidateIlvl = opts.candidateIlvl
  local candidateTrack = opts.candidateTrack
  if not candidateIlvl then
    local diffKey = opts.difficulty or ns.DifficultyKey()
    candidateIlvl = (rec.ilvl or {})[diffKey] or 0
    candidateTrack = ns.ResolveTrack(candidateIlvl, ns.BonusIdsFor(diffKey, rec.dropRank))
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

      local result = ns.Scoring.scoreCandidate(
        {
          equipped_ilvl  = state.ilvl or 0,
          equipped_track = state.track,
          piece_count    = r.tier or 0,
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

  return ranked, rows, { slot = slot, ilvl = candidateIlvl, track = candidateTrack, rec = rec }
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
  local ranked, all, meta = Loot.RankRaiders(itemID, opts)
  if not ranked then return false end

  local limit = (opts and opts.limit) or 5
  local rec = meta.rec

  ns.Print(("%s — %d of %d raiders can use it"):format(
    rec.name or ("item " .. itemID), #ranked, #all))

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
    bits[#bits + 1] = ("+%d ilvl"):format(meta.ilvl - (row.equipped.ilvl or 0))
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
local function resolveChannel()
  local want = ns.Settings.Get("channel")
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
  local ranked, _, meta = Loot.RankRaiders(itemID, opts)
  local data = ns.Data()
  local rec = data and (data.items or {})[itemID]
  local name = (rec and rec.name) or ("item " .. tostring(itemID))

  if not ranked then
    return { ("[Loot Advisor] %s — no raid night imported"):format(name) }
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

function Loot.HandleRoll(roll)
  if not roll or not roll.itemID then
    ns.Warn("loot roll with no resolvable item — nothing to score.")
    return
  end

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
    local ranked = Loot.RankRaiders(roll.itemID, { difficulty = roll.difficulty })
    if ranked and #ranked > 0 then
      ns.Comms.BroadcastDrops(roll.itemID, ranked)

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

  if ns.Panel then
    ns.Panel.Refresh()
    -- Opening is OPT-IN and off by default. An addon that throws a window over
    -- your screen mid-pull gets uninstalled before it proves anything.
    if ns.Settings.Get("autoOpen") then ns.Panel.Show() end
  end

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
