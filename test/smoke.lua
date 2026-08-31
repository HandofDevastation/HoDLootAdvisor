-- test/smoke.lua — drives the whole addon end to end, with no game.
--
--   cd loot-advisor-addon
--   lua test/smoke.lua
--
-- Loads the real files in .toc order against the stubbed client, equips a
-- character, and runs every path the addon has: status, scoring an ordinary
-- item, a ranked trinket, a tier token, the two "cannot be scored" cases, a
-- simulated live START_LOOT_ROLL, and the diagnostic log.
--
-- This is not a parity test — test/parity.lua owns correctness of the scoring
-- itself, against the website as oracle. This proves the WIRING: that the
-- emitted data, the character resolution, the track ladder, the equipped-slot
-- comparison and the scorer actually meet each other. The two together are what
-- lets the first in-game run be a confirmation rather than a debugging session.
--
-- Exit status is 0 only when every check passes.

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

-- ── Boot ────────────────────────────────────────────────────────────────────

stub.Install()

-- LoadWindow.lua is deliberately NOT loaded: it is real frame construction, and
-- stubbing enough of WoW's widget API to build it would test the stub rather
-- than the addon. Its LOGIC lives in Payload.lua, which is covered below; the
-- window itself is thin glue verified in game.
local ns = stub.LoadAddon({
  "LootData.lua", "Style.lua", "Scoring.lua", "Core.lua", "Settings.lua", "Payload.lua",
  -- Roster is loaded so the window-file helper scan below can actually verify
  -- ns.Roster.* calls rather than skipping them: the panel names IdentityFor,
  -- and a module the scan cannot see is a call it cannot check.
  "Diagnostics.lua", "Comms.lua", "Roster.lua", "Journal.lua", "Targets.lua", "Tooltip.lua",
  "Record.lua", "Loot.lua",
})

local data = _G.HoDLootAdvisorData
if not data then
  io.stderr:write("LootData.lua did not load — regenerate it:\n")
  io.stderr:write("  curl -s localhost:3000/api/loot-advisor/emit -o LootData.lua\n")
  os.exit(2)
end

-- ── Pick real items out of the emitted payload ──────────────────────────────
-- Chosen from the DATA rather than hard-coded, so this keeps working across a
-- re-emit and a season rollover.

local SPEC_KEY = stub.player.className .. "/" .. stub.player.specName

local function findItem(pred)
  local ids = {}
  for id in pairs(data.items) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    if pred(id, data.items[id]) then return id, data.items[id] end
  end
end

-- Every pick is filtered by eligibility for THIS character. Without that the
-- first CHEST in the payload is a cloth robe, and the scoring checks below fail
-- for the entirely correct reason that a Hunter cannot wear it.
local function usable(it)
  return type(it.classes) ~= "table" or it.classes[stub.player.className] == true
end

local chestId, chest = findItem(function(_, it)
  return it.slot == "CHEST" and usable(it)
end)
local trinketId, trinket = findItem(function(id, it)
  local e = (data.rankings[id] or {})[SPEC_KEY]
  return it.slot == "TRINKET" and usable(it) and e ~= nil and e.g ~= nil
end)
local tokenId, token = findItem(function(_, it)
  return it.slot == "TOKEN" and it.tokenSlot ~= nil and usable(it)
end)
local omniId = findItem(function(_, it) return it.slot == "TOKEN" and it.tokenSlot == nil end)

check("emitted data carries a CHEST item", chestId ~= nil)
check("emitted data carries a TRINKET ranked for " .. SPEC_KEY, trinketId ~= nil)
check("emitted data carries a tier TOKEN with a resolved slot", tokenId ~= nil,
      "tokenSlot is emitted by the site so the addon never copies TOKEN_SLOT_MAP")
check("emitted data carries an omni-token with NO slot", omniId ~= nil,
      "an omni-token must stay unscored — it exchanges for any tier slot")

-- ── The boss strip's running order ──────────────────────────────────────────
-- ⚠️ THE ORDER MUST BE UNIQUE ACROSS THE WHOLE SEASON. The site stores
-- display_order PER INSTANCE, so with two instances live the first boss of each
-- carried order = 1 — and this addon draws ONE FLAT STRIP with no instance
-- grouping, so it broke the tie alphabetically and drew the season's second raid
-- ahead of its first. The emitter now assigns a global sequence.
--
-- Asserted as a STRUCTURAL property rather than against a list of names: names
-- change every tier, and a hardcoded one would quietly stop testing anything.
do
  local seen, count, maxOrder = {}, 0, 0
  local dupe
  for _, b in pairs((data or {}).bosses or {}) do
    count = count + 1
    local o = b.order or 0
    if seen[o] then dupe = ("%s and %s share order %d"):format(seen[o], b.name, o) end
    seen[o] = b.name
    if o > maxOrder then maxOrder = o end
  end
  check("more than one boss is emitted", count > 1, tostring(count))
  check("no two bosses share a strip position", dupe == nil, dupe or "")
  check("...and the positions are dense, 1..N with no gaps",
        maxOrder == count, ("highest order %d over %d bosses"):format(maxOrder, count))
end

-- ── Equip the character ─────────────────────────────────────────────────────
-- Deliberately in LAST SEASON'S gear: everything this tier drops should read as
-- an upgrade, which is the flat-wall case the whole design worries about.

local S = stub.SLOTS
local VETERAN_1 = data.tracks.bonus.Veteran[1]

local function equip(slot, itemID, ilvl, extra)
  local e = { itemID = itemID, ilvl = ilvl, bonusIDs = { VETERAN_1 } }
  for k, v in pairs(extra or {}) do e[k] = v end
  stub.player.equipped[slot] = e
end

local LADDER_VETERAN_1 = nil
for _, entry in ipairs(data.tracks.ladder) do
  if entry.track == "Veteran" and entry.rank == 1 then LADDER_VETERAN_1 = entry.ilvl end
end
check("the ladder has a Veteran 1/6 rung", LADDER_VETERAN_1 ~= nil)

equip(S.INVSLOT_HEAD, 900001, LADDER_VETERAN_1, { setID = 5000, name = "Old Helm" })
equip(S.INVSLOT_CHEST, 900002, LADDER_VETERAN_1, { name = "Old Chest" })
equip(S.INVSLOT_HAND, 900003, LADDER_VETERAN_1, { setID = 5000, name = "Old Gloves" })
equip(S.INVSLOT_LEGS, 900004, LADDER_VETERAN_1, { setID = 5000, name = "Old Legs" })
-- Two trinkets at different item levels: the scorer must compare against the
-- WORSE one, since that is the piece which would actually be replaced.
equip(S.INVSLOT_TRINKET1, 900005, LADDER_VETERAN_1 + 6, { name = "Better Trinket" })
equip(S.INVSLOT_TRINKET2, 900006, LADDER_VETERAN_1, { name = "Worse Trinket" })

stub.Fire("ADDON_LOADED", "HoDLootAdvisor")
-- The real login sequence, not just the load. The session marker deliberately
-- waits for PLAYER_ENTERING_WORLD because spec data is not answerable at
-- ADDON_LOADED — firing only the first event would reproduce exactly the S243
-- log that recorded specKnown = false for a spec that resolves fine.
stub.Fire("PLAYER_ENTERING_WORLD", true, false)

-- ── Status ──────────────────────────────────────────────────────────────────

do
header("/la")
stub.Slash("")

local char = ns.ResolveCharacter()
check("class token resolved to the emitted class name", char.className == "Hunter", char.className)
check("hero talent tree detected", char.heroTree == "Dark Ranger", tostring(char.heroTree))
check("spec is known to the emitted payload", char.known == true)
check("spec resolves to a stat ranking", ns.SpecFor(char) ~= nil)

local pieces, setKnown = ns.TierPieceCount()
check("tier piece count read from equipped set ids", pieces == 3 and setKnown,
      ("got %d (known=%s)"):format(pieces, tostring(setKnown)))
end

-- ── Gear track resolution ───────────────────────────────────────────────────

header("track resolution")

local worst = ns.EquippedSlotState("TRINKET")
check("a two-slot comparison uses the WORSE equipped piece",
      worst.ilvl == LADDER_VETERAN_1, ("compared against ilvl %d"):format(worst.ilvl or -1))
check("equipped track resolved off the ladder", worst.track == "Veteran", tostring(worst.track))

local emptySlot = ns.EquippedSlotState("NECK")
check("an empty slot reports ilvl 0 with no track",
      emptySlot.empty and emptySlot.ilvl == 0 and emptySlot.track == nil)

local heroIlvl = nil
for _, entry in ipairs(data.tracks.ladder) do
  if entry.track == "Hero" and entry.rank == 1 then heroIlvl = entry.ilvl end
end
local track, rank = ns.ResolveTrack(heroIlvl, { data.tracks.bonus.Hero[1] })
check("a Hero 1/6 item level resolves to the Hero track",
      track == "Hero" and rank == 1, ("%s %s"):format(tostring(track), tostring(rank)))

local advTrack = ns.ResolveTrack(data.tracks.ladder[1].ilvl, {})
check("Adventurer folds into Veteran for scoring", advTrack == "Veteran", tostring(advTrack))

-- ── Item link parsing ───────────────────────────────────────────────────────

local link = stub.link(chestId, chest.name, { 12841, 9999 })
local parsed = ns.ParseItemLink(link)
check("item link parses to its item id", parsed and parsed.itemID == chestId)
check("item link parses its bonus ids",
      parsed and #parsed.bonusIDs == 2 and parsed.bonusIDs[1] == 12841,
      parsed and table.concat(parsed.bonusIDs, ",") or "nil")

-- ── Scoring, through the slash commands ─────────────────────────────────────

do
header("/la score  — an ordinary armour drop")
stub.Slash("score " .. chestId .. " h")
local chestOut = ns.Loot.ScoreItem(chestId, { difficulty = "h" })
check("chest scored without a reason", chestOut.reason == nil, chestOut.reason)
check("chest is an upgrade over last season's gear", chestOut.result.is_upgrade == true)
check("chest candidate ilvl came from the heroic column",
      chestOut.candidateIlvl == chest.ilvl.h,
      ("%s vs %s"):format(chestOut.candidateIlvl, chest.ilvl.h))
check("chest candidate resolved to the Hero track", chestOut.candidateTrack == "Hero",
      tostring(chestOut.candidateTrack))
check("stat alignment actually scored (spec ranking reached the scorer)",
      chestOut.result.stat_alignment > 0, chestOut.result.stat_alignment)

header("/la score  — a ranked trinket")
stub.Slash("score " .. trinketId .. " h")
local trinketOut = ns.Loot.ScoreItem(trinketId, { difficulty = "h" })
check("trinket picked up its letter grade for this spec",
      trinketOut.rankedTier == data.rankings[trinketId][SPEC_KEY].g,
      tostring(trinketOut.rankedTier))
check("the ranked override REPLACED stat alignment",
      trinketOut.result.is_ranked_override == true)
check("the ranked override's ilvl contribution was halved",
      trinketOut.result.ilvl_delta <= 20, trinketOut.result.ilvl_delta)

header("/la test  — a tier token, injected as a roll")
stub.Slash("test " .. tokenId .. " h")
local tokenOut = ns.Loot.ScoreItem(tokenId, { difficulty = "h" })
check("the token resolved to the slot its NAME encodes",
      tokenOut.slot == token.tokenSlot, tostring(tokenOut.slot))
check("the token is an upgrade on TRACK, not item level",
      tokenOut.result.is_upgrade == true)
check("set completion scored for a tier token", tokenOut.result.tier_bonus > 0,
      tokenOut.result.tier_bonus)
end

-- ── Eligibility ─────────────────────────────────────────────────────────────
-- The case that prompted this layer: a Cloth tier token was scored a Major
-- upgrade for a Hunter, because scoring has no opinion about armor types.

do
header("eligibility — items this character cannot use")

local clothToken = findItem(function(_, it)
  return it.slot == "TOKEN" and it.armor == "Cloth"
end)
local mailToken = findItem(function(_, it)
  return it.slot == "TOKEN" and it.armor == "Mail"
end)

check("the payload carries a Cloth and a Mail token to tell apart",
      clothToken ~= nil and mailToken ~= nil)

stub.Slash("score " .. clothToken .. " h")
local clothOut = ns.Loot.ScoreItem(clothToken, { difficulty = "h" })
check("a Cloth token is REFUSED for a Mail wearer",
      clothOut.ineligible == true and clothOut.result == nil, tostring(clothOut.reason))
check("the refusal is reported, not silently dropped", clothOut.reason ~= nil)

local mailOut = ns.Loot.ScoreItem(mailToken, { difficulty = "h" })
check("the Mail token is still scored for a Mail wearer",
      mailOut.ineligible == nil and mailOut.result ~= nil, tostring(mailOut.reason))

-- The spec-level half of the gate, which cannot be pre-resolved by the emitter
-- because it needs the viewer's spec. A Strength item is useless to an Agility
-- spec even when the class can equip the item at all.
local strItem = { classes = { Hunter = true }, primaryStat = "str", armor = "Mail" }
local agiItem = { classes = { Hunter = true }, primaryStat = "agi", armor = "Mail" }
local sharedItem = { classes = { Hunter = true }, armor = "Mail" }

local okStr = ns.CanUse(strItem, "Hunter", "Marksmanship")
local okAgi = ns.CanUse(agiItem, "Hunter", "Marksmanship")
local okShared = ns.CanUse(sharedItem, "Hunter", "Marksmanship")

check("a Strength item is refused for an Agility spec", okStr == false)
check("an Agility item is allowed for an Agility spec", okAgi == true)
check("an item with no detectable primary stat is never excluded", okShared == true,
      "shared-primary and undetectable items get the benefit of the doubt")

check("eligibility fails OPEN on a payload with no classes set",
      ns.CanUse({ armor = "Cloth" }, "Hunter", "Marksmanship") == true,
      "an over-broad list is fixable; an empty one reads as the addon being broken")
end

-- ── Degrading loudly ────────────────────────────────────────────────────────

do
header("items that cannot be scored — these must still be REPORTED")
stub.Slash("score " .. omniId)
stub.Slash("score 999999")

local omniOut = ns.Loot.ScoreItem(omniId, { difficulty = "h" })
check("an omni-token is reported unscored, with a reason",
      omniOut.reason ~= nil and omniOut.result == nil, tostring(omniOut.reason))
check("an omni-token still carries its name", omniOut.name ~= nil)

local unknownOut = ns.Loot.ScoreItem(999999, { difficulty = "h" })
check("an unrecognised item is reported unscored, with a reason",
      unknownOut.reason ~= nil, tostring(unknownOut.reason))
end

-- ── The raid payload ────────────────────────────────────────────────────────
-- Decoded from a fixture produced by the REAL TypeScript encoder
-- (test/make-payload.ts), so this proves the two sides agree — not that I wrote
-- the same misunderstanding twice.

header("raid payload — decode, validate, rank")

local fh = io.open("test/payload.txt", "r")
local encoded = fh and fh:read("*a") or nil
if fh then fh:close() end

if not encoded then
  io.stderr:write("test/payload.txt missing — regenerate it:\n")
  io.stderr:write("  npx tsx loot-advisor-addon/test/make-payload.ts > loot-advisor-addon/test/payload.txt\n")
  os.exit(2)
end

local decoded, decodeErr = ns.Payload.Decode(encoded)
check("the payload decodes", decoded ~= nil, decodeErr)

if decoded then
  ns.Payload.Store(decoded)
  local s = ns.Payload.Summary()
  check("every raider survived the round trip", s.raiders == 24, s.raiders)
  check("the raider with no EPGP standing is carried anyway, unranked",
        s.ranked == 23, ("%d of %d ranked"):format(s.ranked, s.raiders))
  check("the season name survived", s.seasonName == "Midnight: Season 2", s.seasonName)

  -- The slot order is read from the payload, never from a copy in Lua: a
  -- hardcoded order on both sides would shift every raider's gear by one the
  -- moment a slot is inserted, silently.
  local first = decoded.roster[1]
  local st = ns.Payload.SlotState(first, "CHEST")
  check("a raider's slot state resolves to an ilvl and a track",
        st ~= nil and st.ilvl > 0 and st.track ~= nil,
        st and ("%d / %s"):format(st.ilvl, tostring(st.track)))

  -- GEAR age and EXPORT age are different numbers. The fixture is stamped with
  -- an export time and a much older audit time precisely so that conflating
  -- them fails here: reporting the export age as the gear age tells the runner
  -- the roster is live when it may be days stale.
  check("the payload carries the gear-audit time separately from the export time",
        decoded.audit ~= nil and decoded.audit < decoded.stamp,
        ("audit=%s stamp=%s"):format(tostring(decoded.audit), tostring(decoded.stamp)))
  check("gear age and export age do not report the same thing",
        ns.Payload.GearAgeText() ~= ns.Payload.AgeText(),
        ("gear=%s export=%s"):format(ns.Payload.GearAgeText(), ns.Payload.AgeText()))

  -- The Me tab's reason to exist: facts about the PERSON that the Standings
  -- ladder does not carry.
  check("attendance nights survive the round trip",
        first.nights ~= nil and first.nightsOf == 21,
        ("%s of %s"):format(tostring(first.nights), tostring(first.nightsOf)))
  check("last item received survives the round trip",
        first.lastItem ~= nil and first.lastItemDays ~= nil, tostring(first.lastItem))
  check("a raider who has received nothing carries no last item",
        decoded.roster[4].lastItem == nil,
        "the panel phrases this as 'nothing on record', not a blank")

  local unaudited = decoded.roster[8]  -- index 7 in the generator, 0-based
  local emptyState = ns.Payload.SlotState(unaudited, "CHEST")
  check("an unaudited raider reports an EMPTY slot rather than vanishing",
        emptyState ~= nil and emptyState.ilvl == 0,
        "a raider missing from a ranking is worse than an approximate one")
end

-- ── Corrupt and hostile input ───────────────────────────────────────────────

do
header("payload — refusing bad input")

local truncated = encoded:sub(1, math.floor(#encoded * 0.8))
local tOk, tErr = ns.Payload.Decode(truncated)
check("a truncated paste is REFUSED, not partially loaded", tOk == nil, tostring(tErr))
check("the truncation error names the shortfall",
      tErr ~= nil and (tErr:find("incomplete") ~= nil or tErr:find("corrupt") ~= nil),
      tostring(tErr))

local wrongVersion = "LA9:" .. encoded:sub(5)
local vOk, vErr = ns.Payload.Decode(wrongVersion)
check("an unknown format version is refused", vOk == nil, tostring(vErr))
check("the version error says to update the addon",
      vErr ~= nil and vErr:find("update the addon") ~= nil, tostring(vErr))

check("junk is refused", ns.Payload.Decode("hello") == nil)
check("an empty paste is refused", ns.Payload.Decode("") == nil)

-- The pasted string is EVALUATED, so the sandbox is load-bearing. A payload
-- that tries to touch a global must fail rather than run.
local hostile = "LA1:" .. (function(src)
  -- base64 encode, matching the site's encoder
  local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local out, i = {}, 1
  while i <= #src do
    local a, c, d = src:byte(i), src:byte(i + 1), src:byte(i + 2)
    local n = a * 65536 + (c or 0) * 256 + (d or 0)
    local chars = { b:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1),
                    b:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1),
                    c and b:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "=",
                    d and b:sub(n % 64 + 1, n % 64 + 1) or "=" }
    out[#out + 1] = table.concat(chars)
    i = i + 3
  end
  return table.concat(out)
end)('(function() _G.HOSTILE_PAYLOAD_RAN = true; return {} end)()')

local hOk = ns.Payload.Decode(hostile)
check("a payload that reaches for a global cannot run",
      _G.HOSTILE_PAYLOAD_RAN == nil,
      "the pasted string is evaluated, so the empty sandbox is load-bearing")
check("...and it is refused rather than silently accepted", hOk == nil)

-- Reload the good payload — the hostile tests must not have disturbed it.
ns.Payload.Store(ns.Payload.Decode(encoded))
end

-- ── Cross-raider ranking ────────────────────────────────────────────────────

header("/la who — ranking the whole roster")

stub.Slash("who " .. chestId .. " h")

local ranked, all, meta = ns.Loot.RankRaiders(chestId, { difficulty = "h" })
check("the ranking returns rows once a payload is loaded", ranked ~= nil)

if ranked then
  -- ⚠️ 24 ON THE EXPORT PLUS YOU (Session 256). The fixture roster does not list
  -- Gloomrift, and until this session that meant the person running the addon
  -- was absent from every ranking they looked at — the one name guaranteed to be
  -- standing there. Counting rows alone would not have caught it either way, so
  -- the presence of the player is asserted directly.
  check("every roster member was considered", #all == 25, #all)
  local sawMe = false
  for _, row in ipairs(all) do
    if (row.name or ""):lower() == "gloomrift" then sawMe = true end
  end
  check("...including the player, who is not on this export", sawMe)
  check("somebody ranks for the chest", #ranked > 0, #ranked)

  local ineligible = 0
  for _, row in ipairs(all) do
    if not row.eligible then ineligible = ineligible + 1 end
  end
  check("raiders who cannot use the item are excluded from the ranking",
        ineligible > 0 and #ranked <= (#all - ineligible),
        ("%d ineligible of %d"):format(ineligible, #all))

  -- Ordered by upgrade magnitude (Arrangement A). Priority is a COLUMN, not the
  -- sort: the raider with the best PR and the smallest upgrade must be visibly
  -- both, not quietly promoted.
  local descending = true
  for i = 2, #ranked do
    if ranked[i].result.raw_score > ranked[i - 1].result.raw_score then descending = false end
  end
  check("the list is ordered by upgrade magnitude", descending)

  check("the leader carries no gap", ranked[1].gap == 0 or ranked[1].gap == nil)
  if #ranked > 1 then
    check("everyone below the leader carries a negative gap",
          ranked[2].gap ~= nil and ranked[2].gap <= 0, tostring(ranked[2].gap))
  end

  local withPr = 0
  for _, row in ipairs(ranked) do if row.pr then withPr = withPr + 1 end end
  check("priority is carried alongside the upgrade", withPr > 0, withPr)
end

-- A trinket ranks by TIER GROUP first, which is exactly the case where row
-- order stops matching score order — so the gaps must be withheld.
local trinketRanked = ns.Loot.RankRaiders(trinketId, { difficulty = "h" })
if trinketRanked and #trinketRanked > 1 then
  local outOfOrder = false
  for i = 2, #trinketRanked do
    if trinketRanked[i].result.raw_score > trinketRanked[i - 1].result.raw_score then
      outOfOrder = true
    end
  end
  if outOfOrder then
    check("gaps are WITHHELD when tier grouping breaks score order",
          trinketRanked[2].gap == nil,
          "a negative-looking gap in front of the raid is worse than no gap")
  else
    check("trinket ranking stayed monotonic, so gaps are valid", true)
  end
end

-- ── Settings + chat ─────────────────────────────────────────────────────────
-- The addon speaks to the raid in exactly one place, and only when told to.

header("settings and the chat trigger")

check("settings start at their defaults",
      ns.Settings.Get("names") == 3 and ns.Settings.Get("channel") == "AUTO")
check("auto-open is OFF by default", ns.Settings.Get("autoOpen") == false,
      "an addon that throws a window over your screen mid-pull gets uninstalled")

check("a valid setting is accepted", ns.Settings.Set("names", "5") == true)
check("...and takes effect", ns.Settings.Get("names") == 5)

local badOk, badErr = ns.Settings.Set("names", "99")
check("an out-of-range value is REFUSED", badOk == false, tostring(badErr))
check("...and leaves the old value intact", ns.Settings.Get("names") == 5)
check("a non-numeric value is refused", ns.Settings.Set("names", "lots") == false)
check("an unknown key is refused", ns.Settings.Set("nonsense", "1") == false)
check("a bad channel is refused", ns.Settings.Set("channel", "YELL") == false)
check("a valid channel is accepted", ns.Settings.Set("channel", "RAID") == true)

-- Line construction honours the settings rather than hard-coding anything.
local lines = ns.Loot.ChatLines(chestId, { difficulty = "h" })
check("a chat post is two lines: the item, then the names", #lines == 2, #lines)
check("the item line names the item", lines[1]:find("Ophidian") ~= nil, lines[1])

local counted = select(2, lines[2]:gsub("%d%.", ""))
check("the name count follows the setting, not a constant",
      counted <= 5 and counted >= 1, ("listed %d names at names=5"):format(counted))

ns.Settings.Set("names", "1")
local oneLine = ns.Loot.ChatLines(chestId, { difficulty = "h" })
local oneCount = select(2, oneLine[2]:gsub("%d%.", ""))
check("lowering the setting shortens the line", oneCount == 1, oneCount)
check("the remainder is counted, not silently dropped",
      oneLine[2]:find("more") ~= nil, oneLine[2])

ns.Settings.Set("names", "3")
ns.Settings.Set("showGap", "off")
local noGap = ns.Loot.ChatLines(chestId, { difficulty = "h" })
check("the gap can be turned off", noGap[2]:find("%-%d") == nil, noGap[2])
ns.Settings.Set("showGap", "on")

-- ⚠️ THE TEAM IS IN THE RAID (Session 253). Ranking counts only export raiders
-- the group scan has seen, so with stub.inRaid set and nobody from the payload
-- standing here the chat post would have nobody to name.
for _, r in ipairs((ns.Payload.Current() or {}).roster or {}) do
  ns.Roster.seen[ns.Comms.Normalize(r.n)] = { name = r.n, unit = "raid20", realm = "Stormrage" }
end

-- Nothing may reach the raid without a deliberate trigger.
stub.sent = {}
stub.inRaid = true
stub.Slash("test " .. chestId .. " h")
check("a loot roll posts NOTHING to chat on its own", #stub.sent == 0,
      ("%d messages were sent unprompted"):format(#stub.sent))

local posted = ns.Loot.PostToChat(chestId, { difficulty = "h" })
check("the trigger posts when asked", posted == true and #stub.sent == 2, #stub.sent)
check("it posts to the raid channel", stub.sent[1].channel == "RAID", stub.sent[1].channel)
for i, m in ipairs(stub.sent) do
  check(("chat line %d is within the 255-byte cap"):format(i), #m.msg <= 255, #m.msg)
end

-- ⚠️ AN LFR IS RAID-SIZED AND STILL NOT A "RAID" CHANNEL. IsInRaid() is true
-- there, so resolveChannel returned "RAID" and the client REFUSED the message
-- outright with "You are not in a raid group" — the Post button doing nothing,
-- visibly, in the one content type that is always available to test in. Seen in
-- an LFR wing in Session 245 and again in 247, blamed on comms both times;
-- comms had picked INSTANCE_CHAT correctly and this had not.
stub.sent = {}
stub.instanceGroup = true
local lfr = ns.Loot.PostToChat(chestId, { difficulty = "h" })
check("posting in an instance group uses INSTANCE_CHAT",
      lfr == true and stub.sent[1] and stub.sent[1].channel == "INSTANCE_CHAT",
      stub.sent[1] and stub.sent[1].channel)

-- An explicit RAID setting names a channel that does not EXIST in an instance
-- group, so it redirects rather than posting nothing at all.
stub.sent = {}
ns.Settings.Set("channel", "RAID")
ns.Loot.PostToChat(chestId, { difficulty = "h" })
check("...even when the setting explicitly says RAID",
      stub.sent[1] and stub.sent[1].channel == "INSTANCE_CHAT",
      stub.sent[1] and stub.sent[1].channel)

-- SAY works in an instance group, so it is honoured as asked.
stub.sent = {}
ns.Settings.Set("channel", "SAY")
ns.Loot.PostToChat(chestId, { difficulty = "h" })
check("...but SAY is left alone, because SAY works there",
      stub.sent[1] and stub.sent[1].channel == "SAY",
      stub.sent[1] and stub.sent[1].channel)
ns.Settings.Set("channel", "AUTO")
stub.instanceGroup = false

-- Solo, there is no channel; the line must still be inspectable rather than
-- vanishing, or the button cannot be tested outside a raid.
stub.sent, stub.inRaid, stub.inGroup = {}, false, false
ns.Settings.Set("channel", "AUTO")
local soloOk = ns.Loot.PostToChat(chestId, { difficulty = "h" })
check("posting solo sends nothing", soloOk == false and #stub.sent == 0)

-- A pathological name must not produce a message the client would reject.
ns.Settings.Set("names", "10")
local longLines = ns.Loot.ChatLines(chestId, { difficulty = "h" })
for i, l in ipairs(longLines) do
  check(("a maximum-length line %d still fits the cap"):format(i), #l <= 255, #l)
end
ns.Settings.Set("names", "3")

-- ── Difficulty override + real item tooltips ────────────────────────────────

header("difficulty setting and tooltip links")

check("AUTO follows the instance", ns.Settings.Get("difficulty") == "AUTO"
      and ns.DifficultyKey() == "h", ns.DifficultyKey())

ns.Settings.Set("difficulty", "MYTHIC")
check("an explicit difficulty overrides detection", ns.DifficultyKey() == "m", ns.DifficultyKey())

local mythicScore = ns.Loot.ScoreItem(chestId)
check("scoring follows the difficulty setting with no argument",
      mythicScore.candidateIlvl == chest.ilvl.m,
      ("%s vs mythic %s"):format(mythicScore.candidateIlvl, chest.ilvl.m))

-- The tooltip link must carry the difficulty's BONUS IDs, or the client renders
-- the item at its BASE item level, which for raid loot is wildly wrong.
local link = ns.ItemLinkFor(chestId, "m")
local parsedLink = ns.ParseItemLink(link)
check("a tooltip link parses back to the right item",
      parsedLink and parsedLink.itemID == chestId, tostring(link))
check("...and carries a bonus id, so the tooltip shows the DROP ilvl",
      parsedLink and #parsedLink.bonusIDs > 0, tostring(link))

local mythBlock = data.tracks.bonus.Myth
local carried = parsedLink and parsedLink.bonusIDs[1]
local inMythBlock = false
for _, id in ipairs(mythBlock) do if id == carried then inMythBlock = true end end
check("the bonus id is from the MYTHIC block", inMythBlock, tostring(carried))

ns.Settings.Set("difficulty", "AUTO")

-- ── A live roll ─────────────────────────────────────────────────────────────

header("START_LOOT_ROLL — the live path")

local dropLink = stub.link(chestId, chest.name, { data.tracks.bonus.Hero[chest.dropRank or 1] })
stub.candidateIlvl = chest.ilvl.h
stub.SetRoll(77, {
  name = chest.name,
  link = dropLink,
  quality = 4,
  canNeed = false,          -- ineligible: must DISPLAY, never skip
  reasonNeed = 2,
  timeLeft = 47000,
})
stub.Fire("START_LOOT_ROLL", 77, 47000)

local sawIneligible = false
for _, line in ipairs(stub.printed) do
  if line:find("cannot Need") then sawIneligible = true end
end
check("a roll the player cannot Need on is still shown, and says so", sawIneligible,
      "the roll frame appears regardless of Need eligibility (12.1 GroupLootFrame_OnShow)")

-- ── Diagnostics ─────────────────────────────────────────────────────────────

header("/la diag")
stub.Fire("ENCOUNTER_END", 2894, "The Lost Explorers", 15, 20, 1)
stub.Fire("PLAYER_EQUIPMENT_CHANGED", 5, true)
stub.Slash("diag")
stub.Slash("diag dump 6")

local db = ns.db
local byEvent = {}
for _, e in ipairs(db.log) do byEvent[e.e] = (byEvent[e.e] or 0) + 1 end

-- Solo questing loot must not evict raid observations from the ring buffer.
local beforeNoise = #db.log
stub.inRaid, stub.inGroup = false, false
stub.instance.difficultyID = 0
local realInstanceInfo = _G.GetInstanceInfo
_G.GetInstanceInfo = function() return "Elwynn Forest", "none", 0, "", 0 end
for _ = 1, 20 do stub.Fire("CHAT_MSG_LOOT", "You receive loot: junk") end
check("solo questing loot is NOT logged", #db.log == beforeNoise,
      ("%d entries added while solo"):format(#db.log - beforeNoise))

_G.GetInstanceInfo = realInstanceInfo
stub.instance.difficultyID = 15
stub.inRaid = true
stub.Fire("CHAT_MSG_LOOT", "Vörnix receives loot")
check("...but the same event IS logged in a raid", #db.log == beforeNoise + 1)
stub.inRaid = false

check("diagnostics logged the loot roll", (byEvent.START_LOOT_ROLL or 0) >= 1)
check("diagnostics logged the encounter end", (byEvent.ENCOUNTER_END or 0) >= 1)
check("diagnostics recorded a session marker", (byEvent["@session"] or 0) >= 1)

-- The marker must report the spec it can actually see. S243's log said
-- specKnown = false on 18 of 18 logins and it was believed, because a log is
-- the thing you reason FROM — half of that was a real bug and half was the
-- marker running before the client could answer at all.
local sessionEntry, sessionCount
for _, e in ipairs(db.log) do
  if e.e == "@session" then sessionEntry = e; sessionCount = (sessionCount or 0) + 1 end
end
check("the session marker reports the spec as KNOWN, not as it looked at load",
      sessionEntry and sessionEntry.x and sessionEntry.x.specKnown == true,
      sessionEntry and sessionEntry.x
        and ("specKnown=%s specSource=%s"):format(
              tostring(sessionEntry.x.specKnown), tostring(sessionEntry.x.specSource))
        or "no marker")
check("one marker per login, not one per zone change", sessionCount == 1,
      ("%s markers"):format(tostring(sessionCount)))
check("diagnostics recorded the dev injection", (byEvent["@devInject"] or 0) >= 1)

local rollEntry
for _, e in ipairs(db.log) do if e.e == "START_LOOT_ROLL" then rollEntry = e end end
check("the roll's full GetLootRollItemInfo return list was captured",
      rollEntry and rollEntry.x and rollEntry.x.rollItemInfo
        and rollEntry.x.rollItemInfo.n == 13,
      rollEntry and rollEntry.x and rollEntry.x.rollItemInfo
        and ("captured %s returns"):format(tostring(rollEntry.x.rollItemInfo.n)) or "nothing captured")

-- NOT a claim that these event names exist in 12.1. The stub's accept-list is
-- the same guess-list Diagnostics registers, so agreement between them proves
-- nothing about the real client — only the live log can answer that, which is
-- the entire reason Diagnostics reports its rejections. What IS worth proving is
-- the MECHANISM: that a name the client refuses degrades to a recorded entry in
-- `unavailable` instead of erroring the addon out on load.
check("registration is guarded, so a rejected event cannot break loading",
      (function()
        local f = CreateFrame("Frame")
        local ok = pcall(f.RegisterEvent, f, "NOT_A_REAL_EVENT_12_1")
        return ok == false
      end)(),
      "an unknown event must fail softly, not throw out of Start()")

-- Everything in the log must survive a SavedVariables round trip, or a night's
-- observations are lost at logout — the one failure this file exists to prevent.
local function serialisable(v, depth)
  local t = type(v)
  if t == "number" or t == "string" or t == "boolean" or t == "nil" then return true end
  if t ~= "table" or (depth or 0) > 8 then return false end
  for k, val in pairs(v) do
    local kt = type(k)
    if kt ~= "string" and kt ~= "number" then return false end
    if not serialisable(val, (depth or 0) + 1) then return false end
  end
  return true
end
check("the whole log is serialisable to SavedVariables", serialisable(db.log, 0))

-- ── Spec resolution ─────────────────────────────────────────────────────────
--
-- The live log showed specId = 0 and specKnown = false on 18 of 18 logins, and
-- nothing errored: GetSpecialization() answered 0, ZERO IS TRUTHY IN LUA, so it
-- was passed straight to GetSpecializationInfo(0) and the spec silently never
-- resolved. Every item was then scored against an UNKNOWN spec — a neutral
-- value rather than the character's real stat ranking.

header("SPEC RESOLUTION")

local realGetSpec = _G.GetSpecialization
local idx, source = ns.SpecIndex()
check("a normal client resolves a spec index", idx == 1, tostring(idx))
check("and reports which API answered", source == "GetSpecialization", tostring(source))

_G.GetSpecialization = function() return 0 end
check("a spec index of 0 is rejected, not treated as a real spec",
      ns.SpecIndex() == nil, tostring(ns.SpecIndex()))
check("...and the character then reports itself as UNKNOWN rather than guessing",
      ns.ResolveCharacter().known == false)

-- The newer namespace wins when it exists, without removing the fallback.
_G.C_SpecializationInfo = {
  GetSpecialization = function() return 1 end,
  GetSpecializationInfo = function() return stub.player.specId, stub.player.specName end,
}
local nsIdx, nsSource = ns.SpecIndex()
check("C_SpecializationInfo is preferred when the client has it",
      nsIdx == 1 and nsSource == "C_SpecializationInfo.GetSpecialization", tostring(nsSource))

_G.C_SpecializationInfo = nil
_G.GetSpecialization = realGetSpec
check("spec resolution is restored for the rest of the run",
      ns.ResolveCharacter().known == true)

-- ── The loot recorder ───────────────────────────────────────────────────────
--
-- Drives a whole kill through Record.lua with no game: a boss dies,
-- C_LootHistory reports drops with rollInfos, the follow-up scans run, and the
-- result is exported in the format the site parses. The names are deliberately
-- accented — an ASCII roster is what let the payload length bug through in 242.

header("LOOT RECORDER")

local R = ns.Record
check("the recorder is on the namespace", R ~= nil)

-- Item data for the drops. Chosen from the emitted payload where possible so the
-- names are real, with the ids the recorder will read out of the links.
stub.items[270160] = { name = "Sunfury Chestguard", quality = 4, ilvl = 305, itemType = "Armor" }
stub.items[270161] = { name = "Voidscarred Greaves", quality = 4, ilvl = 305, itemType = "Armor" }
stub.items[270162] = { name = "Venom-Drenched Sack", quality = 4, ilvl = 308, itemType = "Armor" }

-- ── A guild raid kill ───────────────────────────────────────────────────────

stub.inRaid = true
stub.instance = {
  name = "The Venomous Abyss", difficultyID = 15,
  difficultyName = "Heroic (Raid)", instanceID = 2917,
}

-- A REAL RAID HAS A ROSTER, SO THE FIXTURE MUST TOO (Session 253). The guild
-- export is what scripts/loot-addon-contract/check-export.ts feeds through the
-- site's real parser, and the site branches on whether a winner carries a
-- realm. With no group standing here every winner exported bare, so that check
-- was proving the round trip for data the addon no longer produces.
--
-- Scanned rather than hand-seeded: this is the path that runs in game, so the
-- realms come from UnitName exactly as they would live. Vörnix is deliberately
-- on our OWN realm (empty answer from UnitName) and the rest are cross-realm.
stub.group = {
  { name = "Vörnix",    realm = nil,           class = "Hunter",  classToken = "HUNTER" },
  { name = "Dåmir",     realm = "Area52",      class = "Warrior", classToken = "WARRIOR" },
  { name = "Mîrâñ",     realm = "Illidan",     class = "Mage",    classToken = "MAGE" },
  { name = "Brambleÿ",  realm = "Tichondrius", class = "Druid",   classToken = "DRUID" },
  { name = "Corvá",     realm = "Area52",      class = "Priest",  classToken = "PRIEST" },
}
ns.Roster.Scan()

-- Two drops off one boss. The first is a contested Need roll; the second is a
-- pass-fallthrough, which the site counts differently from a real win and which
-- therefore has to survive the round trip intact.
--
-- ⚠️ THE `state` NUMBERS BELOW ARE THE GAME'S REAL ONES (corrected Session 255):
--   0 = need (main spec)   1 = need (off spec)   2 = transmog
--   3 = greed              4 = did not respond   5 = pass
-- They used to be written in the old inherited scheme, where 5 meant need and 1
-- meant pass — near enough the inverse. Every fixture in this file was renumbered
-- at once, and the expected export in test/export.txt did NOT change, which is
-- the proof the renumbering was faithful: the labels come out identical, only
-- the raw numbers feeding them are now the ones the client actually sends.
-- If a fixture here ever disagrees with Enum.EncounterLootDropRollState, the
-- fixture is wrong. Blizzard's generated docs are on disk; read them.
stub.lootHistory[2849] = {
  stub.drop(1, 270160, "Sunfury Chestguard", { 12841 }, {
    { name = "Vörnix",     state = 0, roll = 87, isWinner = true },
    { name = "Dåmir",      state = 0, roll = 42 },
    { name = "Mîrâñ",      state = 3, roll = 61 },
    { name = "Brambleÿ",  state = 5, roll = 0 },
    { name = "Gloomrift",  state = 4, roll = 0 },
  }),
  stub.drop(2, 270161, "Voidscarred Greaves", { 12841 }, {
    { name = "Corvá",  state = 5, roll = 55, isWinner = true },
    { name = "Dåmir",  state = 5, roll = 0 },
  }),
}

stub.Fire("ENCOUNTER_END", 2849, "Nymrissa Wavecaller", 15, 20, 1)

check("the scan is coalesced behind a timer rather than run per event",
      #stub.timers > 0 and select(2, R.Counts()) == 0,
      ("%d timers queued, %d items recorded before the clock ran"):format(
        #stub.timers, select(2, R.Counts())))

stub.RunTimers()

local _, recorded, won = R.Counts()
check("both drops from the kill were recorded", recorded == 2, ("recorded %d"):format(recorded))
check("both have a winner once the roll window closed", won == 2, ("%d with winners"):format(won))

-- A second enumeration must not duplicate anything: this runs five more times
-- from the follow-up ladder on a real kill.
R.ScanAll(); R.ScanAll()
local _, afterRescan = R.Counts()
check("re-enumerating the same encounter upserts rather than duplicates",
      afterRescan == 2, ("recorded %d after rescans"):format(afterRescan))

-- NOTHING is auto-tagged guild any more (Session 245) — a raid run starts
-- personal like every other, and "Mark Guild" is what makes it site-bound. So
-- the tests below mark it exactly the way the window's button does.
check("even a raid group starts out personal, not guild",
      #R.Sessions("guild") == 0, ("%d guild runs"):format(#R.Sessions("guild")))
for _, r in ipairs(R.Sessions()) do R.SetKind(r.index, "guild") end

local guildRuns = R.Sessions("guild")
check("marking the run Guild is what puts it in the guild set",
      #guildRuns == 1, ("%d guild runs"):format(#guildRuns))

local run = guildRuns[1] and guildRuns[1].session
local chest = run and run.items[1]
check("the drop carries the boss name from ENCOUNTER_END",
      chest and chest.boss == "Nymrissa Wavecaller", chest and chest.boss)
check("the winner is recorded without the realm suffix",
      chest and chest.winner == "Vörnix", chest and chest.winner)
check("the winning roll value came off the winner's own rollInfo",
      chest and chest.winRollValue == 87, chest and tostring(chest.winRollValue))
check("every roller was captured, not just the winner",
      chest and (function() local n = 0; for _ in pairs(chest.rolls) do n = n + 1 end; return n end)() == 5)
check("a pass is recorded as a pass",
      chest and chest.rolls["Brambleÿ"] and chest.rolls["Brambleÿ"].rollType == "pass",
      chest and chest.rolls["Brambleÿ"] and chest.rolls["Brambleÿ"].rollType)
check("a greed is recorded as a greed",
      chest and chest.rolls["Mîrâñ"] and chest.rolls["Mîrâñ"].rollType == "greed")
check("the raw roll state is kept for the mapping to be verified against later",
      chest and chest.rolls["Vörnix"] and chest.rolls["Vörnix"].state == 0)
check("the item level is the DROPPED level, not the base one",
      chest and chest.itemILevel == 305, chest and tostring(chest.itemILevel))
check("bonus IDs survived off the item link",
      chest and chest.bonusIDs == "12841", chest and chest.bonusIDs)

local greaves = run and run.items[2]
check("a pass-fallthrough win keeps its pass roll type",
      greaves and greaves.winRollType == "pass", greaves and greaves.winRollType)

-- ── The encounter id space is LEARNED, not assumed ──────────────────────────
-- The one thing no documentation settles. A loot-history event carrying an id
-- that ENCOUNTER_END never mentioned must still be enumerated.

stub.lootHistory[77301] = {
  stub.drop(9, 270162, "Venom-Drenched Sack", { 12841 }, {
    { name = "Dåmir", state = 0, roll = 91, isWinner = true },
  }),
}
stub.Fire("LOOT_HISTORY_UPDATE_DROP", 77301, 9)
stub.RunTimers()

local _, withLearned = R.Counts()
check("an encounter id learned from a LOOT_HISTORY_* event is enumerated too",
      withLearned == 3, ("recorded %d"):format(withLearned))

-- ── A second character, same raid, same day ─────────────────────────────────
--
-- SavedVariables are ACCOUNT-wide, so an alt clearing the same instance at the
-- same difficulty on the same day would merge into the main's run if the
-- character were not part of the run's identity — two lockouts and two sets of
-- loot silently collapsed into one session.

do
check("the run records which character was playing",
      run and run.character == "Gloomrift", run and run.character)

stub.player.name = "Vörnix"
stub.lootHistory[2850] = {
  stub.drop(1, 270160, "Sunfury Chestguard", { 12841 }, {
    { name = "Vörnix", state = 0, roll = 73, isWinner = true },
  }),
}
stub.Fire("ENCOUNTER_END", 2850, "Nymrissa Wavecaller", 15, 20, 1)
stub.RunTimers()

for _, r in ipairs(R.Sessions()) do R.SetKind(r.index, "guild") end
local twoChars = R.Sessions("guild")
check("an alt's run of the same raid is a SEPARATE run, not merged into the main's",
      #twoChars == 2, ("%d guild runs"):format(#twoChars))
check("each run is attributed to the character that recorded it",
      (function()
        local names = {}
        for _, r in ipairs(twoChars) do names[r.session.character or "?"] = true end
        return names["Gloomrift"] and names["Vörnix"]
      end)())

-- Back to the main for the rest.
stub.player.name = "Gloomrift"
end

-- ── Personal loot, and the personal/guild split ─────────────────────────────

stub.inRaid, stub.inGroup = false, false
stub.instance = {
  name = "Ara-Kara, City of Echoes", difficultyID = 8,
  difficultyName = "Mythic+ (5-man)", instanceID = 2660,
}
stub.items[270163] = { name = "Bloodstained Webwing", quality = 4, ilvl = 311, itemType = "Armor" }

stub.Fire("ENCOUNTER_LOOT_RECEIVED", 0, 270163,
          stub.link(270163, "Bloodstained Webwing", { 12841 }), 1, "Gloomrift-Stormrage", "HUNTER")

local personalRuns = R.Sessions("personal")
check("a solo run stays personal, in its own session",
      #personalRuns == 1, ("%d personal runs"):format(#personalRuns))

local solo = personalRuns[1] and personalRuns[1].session
check("personal loot records the receiver as the winner",
      solo and solo.items[1] and solo.items[1].winner == "Gloomrift")
check("personal loot is marked as such, not as a roll",
      solo and solo.items[1] and solo.items[1].winRollType == "personal")
check("the personal run did not land in either guild run",
      #R.Sessions("guild") == 2)

-- ── Export scoping ──────────────────────────────────────────────────────────

local guildText, guildItems = R.Export({ kind = "guild" })
check("the bulk export is guild-only — a personal run never leaks into it",
      guildItems == 4, ("exported %d items"):format(tostring(guildItems)))
check("personal loot is absent from the guild export",
      guildText and not guildText:find("Bloodstained Webwing", 1, true))
check("the guild export names its own format",
      guildText and guildText:sub(1, 17) == "HODLOOT_EXPORT_V1")
check("the export contains no pipe characters, which zero an EditBox",
      guildText and not guildText:find("|", 1, true))
check("accented names survive into the export",
      guildText and guildText:find("Vörnix", 1, true) ~= nil)

local personalText, personalItems = R.Export({ index = personalRuns[1].index })
check("a personal run can still be exported deliberately, one run at a time",
      personalItems == 1 and personalText:find("Bloodstained Webwing", 1, true) ~= nil)

-- The tag is auto-set and must be overridable; that is the whole point of it.
R.SetKind(personalRuns[1].index, "guild")
check("a run can be re-tagged by hand", #R.Sessions("guild") == 3)
R.SetKind(personalRuns[1].index, "personal")
check("and tagged back", #R.Sessions("personal") == 1)

-- ── A blank name is not a name ──────────────────────────────────────────────
--
-- ⚠️ THE BUG JASON ACTUALLY HIT, and the one my first fix missed. An item's
-- SECOND line rendered fine — so the entry existed and had scored — while the
-- name was simply absent until switching boss. `row.name:SetText(e.name or "?")`
-- draws blank for exactly one value: the empty string, because "" is TRUTHY in
-- Lua, so `or` never reaches the fallback and `if not e.name` never fires.
-- Same family as the recorded ZERO-IS-TRUTHY rule.
do
  header("An empty item name falls back rather than drawing blank")

  local catalogue = { [111] = { name = "Catalogued Item" }, [222] = { name = "" } }
  local entries = {
    { itemID = 111, name = "" },        -- the killer: truthy, and invisible
    { itemID = 222, name = nil },       -- absent, and our catalogue is ALSO ""
    { itemID = 333 },                   -- nothing anywhere
    { itemID = 444, name = "Real Name" },
  }
  local filled = ns.FillItemNames(entries, catalogue)

  check("an empty name is treated as missing, not as a name",
        entries[1].name == "Catalogued Item", tostring(entries[1].name))
  -- ⚠️ THE CHAIN GAINED THE CLIENT AND LOST THE ID (Session 258). Our catalogue
  -- is not the last word: 232 BIS items are absent from loot_items entirely, so
  -- the CLIENT is asked next — and only then a placeholder. The placeholder is
  -- no longer "item:<id>", which is a debugging string that reached the Slots
  -- page and was the only thing on it.
  --
  -- The stub answers nothing for these ids, so both fall through to the word.
  check("...and an empty name in OUR catalogue is not swapped in either",
        entries[2].name == ns.LOADING_NAME, tostring(entries[2].name))
  check("...with a WORD as the last resort, never the item id",
        entries[3].name == ns.LOADING_NAME
          and not entries[3].name:match("^item:"),
        tostring(entries[3].name))
  check("a real name is left alone", entries[4].name == "Real Name")
  check("...and the count reflects only what had to be filled", filled == 3, filled)

  -- The property that matters, stated as itself: nothing leaves here blank.
  local blank = 0
  for _, e in ipairs(entries) do
    if e.name == nil or e.name == "" then blank = blank + 1 end
  end
  check("NO entry can leave without a visible name", blank == 0, blank)
end

-- ── One vocabulary for the slot line ────────────────────────────────────────
--
-- ⚠️ THE USER WATCHED US SWITCH SOURCES (Jason, Session 254). The second line is
-- drawn from OUR payload while the Adventure Guide is cold and from the GUIDE a
-- moment later, and the two spoke differently: "TRINKET" then "Trinket",
-- "SHOULDER" then "Shoulder". Both correct, one flicker. The property that
-- matters is that both sources now produce the SAME string.
do
  header("Our slot keys and the game's labels produce one string")

  check("our key becomes the game's word",
        ns.SlotLabel("TRINKET") == "Trinket", ns.SlotLabel("TRINKET"))
  -- ⚠️ OFF HAND IS THE ONE PLACE WE DELIBERATELY DIFFER FROM THE CLIENT (Jason,
  -- Session 256: "Off Hand is the correct language. It's more succinct and
  -- clear"). Everywhere else our key maps to the GAME's phrase; here the game
  -- says "Held In Off-hand" and we say "Off Hand", so the translation has to run
  -- BOTH ways or the flicker this whole block exists to prevent comes back for
  -- exactly one slot. Asserted as a pair, because either half alone is the bug.
  check("...including where we deliberately differ from the game's wording",
        ns.SlotLabel("OFF_HAND") == "Off Hand", ns.SlotLabel("OFF_HAND"))
  check("...and the game's own phrase normalises to ours, so it cannot flicker",
        ns.SlotLabel("Held In Off-hand") == "Off Hand",
        ns.SlotLabel("Held In Off-hand"))
  -- A slot key we invented, for which the game has no word at all — a token row
  -- drew its badge beside an empty second line without this.
  check("a tier token gets a label rather than nothing",
        ns.SlotLabel("TOKEN") == "Tier Token", ns.SlotLabel("TOKEN"))

  -- THE SAFETY PROPERTY: this runs over BOTH sources, so it must never mangle a
  -- label the Guide already gave us.
  check("the game's own label passes through untouched",
        ns.SlotLabel("Trinket") == "Trinket", ns.SlotLabel("Trinket"))
  check("an unmapped value passes through untouched",
        ns.SlotLabel("Dagger") == "Dagger", ns.SlotLabel("Dagger"))
  check("nil survives", ns.SlotLabel(nil) == nil)

  -- The point of the whole change, stated as itself: one item, two sources, one
  -- rendered line.
  local fromUs   = ns.ItemSlotLine({ slotText = "SHOULDER", armorType = "Cloth" })
  local fromGame = ns.ItemSlotLine({ slotText = "Shoulder", armorType = "Cloth" })
  check("the two sources render IDENTICALLY, so no flicker is possible",
        fromUs == fromGame and fromUs == "Shoulder, Cloth", fromUs .. " vs " .. fromGame)

  -- ⚠️ "" IS TRUTHY, FOR THE THIRD TIME IN ONE SESSION. The Adventure Guide
  -- answers "" for a tier token's slot; kept, it beats our payload's real answer
  -- and the row draws its badge beside nothing.
  check("an empty string is not a value", ns.NonEmpty("") == nil)
  check("...nor is a non-string", ns.NonEmpty(nil) == nil and ns.NonEmpty(7) == nil)
  check("a real string survives", ns.NonEmpty("Cloth") == "Cloth")
  check("an empty slot renders as nothing rather than as a slot",
        ns.ItemSlotLine({ slotText = "", armorType = "" }) == "")

  -- A TIER TOKEN SAYS WHAT IT IS. Its slot alone reads as an ordinary armour
  -- piece, which is the one thing it is not.
  check("a tier token names itself, keeping the slot it is for",
        ns.ItemSlotLine({ slotText = "HANDS", tokenItem = true }) == "Hands, Tier Token",
        ns.ItemSlotLine({ slotText = "HANDS", tokenItem = true }))
  check("...and still says so with no slot resolved",
        ns.ItemSlotLine({ tokenItem = true }) == "Tier Token",
        ns.ItemSlotLine({ tokenItem = true }))
  check("an ordinary item is untouched by that",
        ns.ItemSlotLine({ slotText = "HANDS", armorType = "Plate" }) == "Hands, Plate")
end

-- ── The addon's own tooltip measures its own box ────────────────────────────
--
-- ⚠️ THE TOOLTIP IS A WINDOW FILE THE HARNESS CANNOT LOAD, so its ARITHMETIC
-- lives in Core and is tested here — the same rule that moved the item-name fill
-- out of Panel.lua in Session 253. Tip.lua measures the text and positions the
-- fontstrings; every number it uses comes from this function.
do
  header("The tooltip's box is computed from measured text")

  local opts = { pad = 10, lineGap = 3, titleGap = 6, colGap = 18, maxW = 300,
                 titleW = 120, titleH = 13 }

  -- ⚠️ A DOUBLE LINE IS BOTH COLUMNS PLUS THE TROUGH. Taking the WIDER of the
  -- two is the easy mistake, and it lets a label and its value touch on exactly
  -- the widest row — the one most worth reading.
  local box = ns.TipLayout({ { leftW = 100, rightW = 20, h = 11 } }, opts)
  check("a two-column row is as wide as both columns and the trough",
        box.contentW == 138, box.contentW)
  check("...and the frame adds the padding on both sides",
        box.w == 158, box.w)

  -- The title is content too: a long heading over short rows sets the width.
  check("a wide title widens the box",
        ns.TipLayout({ { leftW = 20, h = 11 } }, opts).contentW == 120)

  -- ⚠️ maxW CAPS PROSE, NEVER A TWO-COLUMN ROW: a paragraph folds, a label and a
  -- number have nowhere to fold to, so capping them overlaps the columns.
  check("long prose is capped so it wraps",
        ns.TipLayout({ { leftW = 900, h = 11, wrap = true } }, opts).contentW == 300)
  check("...but a wide two-column row is NOT capped, it stays legible",
        ns.TipLayout({ { leftW = 400, rightW = 40, h = 11 } }, opts).contentW == 458)

  -- Vertical stacking: title, then rows separated by the line gap only BETWEEN
  -- them — a trailing gap would sit inside the bottom padding and read as slop.
  local three = ns.TipLayout(
    { { leftW = 10, h = 11 }, { leftW = 10, h = 11 }, { leftW = 10, h = 11 } }, opts)
  check("the first row clears the title", three.y[1] == 10 + 13 + 6, three.y[1])
  check("rows stack by their own height plus the gap",
        three.y[2] == three.y[1] + 14 and three.y[3] == three.y[2] + 14,
        table.concat(three.y, ","))
  check("the box ends one padding below the last row, with no trailing gap",
        three.h == three.y[3] + 11 + 10, three.h)

  -- ⚠️ AN EXACT FIT IS NOT A FIT (Session 254). A wrapped line given precisely
  -- its measured width folds anyway, because the client's text metrics and the
  -- font's advance widths disagree by a fraction — which is how two sentences
  -- measuring 297.7 and 295.8 both wrapped inside a 300 ceiling. The slack is
  -- what stops that, and it must survive anyone "simplifying" the min().
  check("a wrapped line is given slack over its measured width",
        ns.TipLayout({ { leftW = 297.7, h = 11, wrap = true } }, opts).contentW == 300,
        ns.TipLayout({ { leftW = 297.7, h = 11, wrap = true } }, opts).contentW)
  check("...and the ceiling still bounds genuinely long prose",
        ns.TipLayout({ { leftW = 569.5, h = 11, wrap = true } }, opts).contentW == 300)

  -- With no title at all the first row sits at the padding, not below a gap for
  -- a heading that was never drawn.
  local untitled = ns.TipLayout({ { leftW = 10, h = 11 } },
    { pad = 10, lineGap = 3, titleGap = 6, colGap = 18, maxW = 300,
      titleW = 0, titleH = 0 })
  check("an untitled tooltip starts at the padding", untitled.y[1] == 10, untitled.y[1])
end

-- ── A placeholder name asks the client, and comes back ──────────────────────
--
-- ⚠️ THE BUG THAT KEPT RETURNING IN DIFFERENT COSTUMES (Jason, Session 253:
-- "this has bitten us SO MANY TIMES"). The client answers an item query with
-- nothing on the first ask and loads it in the background; the frame draws once
-- against that empty answer and never draws again, so the name appears only
-- when something unrelated forces a redraw — closing and reopening, or
-- switching boss. The journal path defended itself; the recorded-drops path did
-- not, and a drop recorded before its item resolved had "item:NNN" frozen into
-- SavedVariables where redrawing alone could never fix it.
do
  header("Unresolved item names ask the client and schedule a redraw")

  stub.requestedItems = {}
  local before = #stub.timers

  local asked = ns.WarmItemNames({
    { itemID = 270160, name = "Sunfury Chestguard" },   -- real name: leave alone
    { itemID = 999001, name = "item:999001" },          -- the frozen placeholder
    { itemID = 999002 },                                -- no name at all
  })

  check("an unresolved name is noticed", asked == true)
  check("...and the client is asked for exactly the unresolved ones",
        #stub.requestedItems == 2
          and ((stub.requestedItems[1] == 999001 and stub.requestedItems[2] == 999002)
            or (stub.requestedItems[1] == 999002 and stub.requestedItems[2] == 999001)),
        table.concat(stub.requestedItems, ","))
  check("...and a redraw is booked rather than waiting to be told",
        #stub.timers > before, ("%d -> %d timers"):format(before, #stub.timers))

  -- Coalesced: a second call while one is pending must not stack another.
  local pending = #stub.timers
  ns.WarmItemNames({ { itemID = 999003 } })
  check("a second unresolved list does not stack a second redraw",
        #stub.timers == pending, ("%d -> %d"):format(pending, #stub.timers))

  -- And the quiet case: everything named, nothing asked, nothing booked.
  stub.requestedItems = {}
  local quiet = #stub.timers
  local none = ns.WarmItemNames({ { itemID = 270160, name = "Sunfury Chestguard" } })
  check("a fully-named list asks for nothing and books nothing",
        none == false and #stub.requestedItems == 0 and #stub.timers == quiet)
end

-- ── The winner's REALM survives into the export ─────────────────────────────
--
-- Abirn has two REAL characters both called Abirnn — a Druid on Area-52 and a
-- Shaman on Thrall. The export carried the bare name, so the site could not say
-- which; because it refuses to guess between two same-named characters it
-- recorded NEITHER, and four contested need wins sat uncharged for a fortnight
-- while his standing read as an unlucky raider's (Session 253).
--
-- The third case is the one that matters most. A realm we cannot establish must
-- stay ABSENT: the roll window's own playerName omits the realm for cross-realm
-- players too, so stamping our own realm on any bare name would have invented
-- "Abirnn-Stormrage" for an Area-52 character.
do
  header("The winner's realm reaches the export")

  local function seenAs(name, realm)
    local key = (ns.Comms and ns.Comms.Normalize and ns.Comms.Normalize(name)) or name:lower()
    ns.Roster.seen[key] = { name = name, realm = realm, attempts = 0, nextTry = 0 }
  end

  seenAs("Abirnn",  "Area52")   -- cross-realm: UnitName hands us the realm
  seenAs("Zandion", "")         -- our own realm: UnitName hands us nothing
  -- "Straynger" is deliberately NEVER seeded — nobody knows where they are.

  -- Its OWN instance, so these probes form their own run. Dropping them into a
  -- session the later delete-a-run checks operate on made those fail: a fixture
  -- that changes shared state is testing the other tests too.
  local savedInstance = stub.instance
  stub.instance = { name = "Realm Probe Chamber", difficultyID = 8,
                    difficultyName = "Mythic+ (5-man)", instanceID = 9999 }

  stub.items[280101] = { name = "Realm Probe Alpha", quality = 4, ilvl = 300, itemType = "Armor" }
  stub.items[280102] = { name = "Realm Probe Beta",  quality = 4, ilvl = 300, itemType = "Armor" }
  stub.items[280103] = { name = "Realm Probe Gamma", quality = 4, ilvl = 300, itemType = "Armor" }

  stub.Fire("ENCOUNTER_LOOT_RECEIVED", 0, 280101,
            stub.link(280101, "Realm Probe Alpha", {}), 1, "Abirnn", "DRUID")
  stub.Fire("ENCOUNTER_LOOT_RECEIVED", 0, 280102,
            stub.link(280102, "Realm Probe Beta", {}), 1, "Zandion", "WARLOCK")
  stub.Fire("ENCOUNTER_LOOT_RECEIVED", 0, 280103,
            stub.link(280103, "Realm Probe Gamma", {}), 1, "Straynger", "MAGE")

  local realmRun
  for _, r in ipairs(R.Sessions("personal")) do
    if r.session.instance == "Realm Probe Chamber" then realmRun = r end
  end
  local realmText = realmRun and R.Export({ index = realmRun.index }) or ""
  stub.instance = savedInstance

  check("a cross-realm winner is exported WITH their realm, so two same-named characters can be told apart",
        realmText:find("Abirnn-Area52", 1, true) ~= nil,
        realmText:match("[^\n]*Realm Probe Alpha[^\n]*") or "no line for it")
  check("a winner on our OWN realm is stamped with it rather than left bare",
        realmText:find("Zandion-Stormrage", 1, true) ~= nil,
        realmText:match("[^\n]*Realm Probe Beta[^\n]*") or "no line for it")
  check("a winner the roster never saw stays BARE — an unknown realm is never invented",
        realmText:find("~Straynger~", 1, true) ~= nil
          and realmText:find("Straynger%-") == nil,
        realmText:match("[^\n]*Realm Probe Gamma[^\n]*") or "no line for it")
end

-- ── Deleting ONE DROP out of a run ──────────────────────────────────────────
--
-- `/la loot fake` writes a REAL record deliberately, so there has to be a way to
-- take one row back out. Until this existed the only tool was Delete Run, which
-- took the genuine drops recorded alongside it — S243 left exactly that sitting
-- in a Delve run.

local victimRun = R.Sessions("guild")[1]
local victimSession = victimRun.session
local victimKey = victimSession.items[1].key
local victimName = victimSession.items[1].itemName
local itemsBefore = #victimSession.items

local gone = R.DeleteItem(victimRun.index, victimKey)
check("one drop can be removed without touching the run",
      gone and gone.itemName == victimName and #victimSession.items == itemsBefore - 1,
      ("%d -> %d items"):format(itemsBefore, #victimSession.items))
check("the run itself survived removing a drop from it",
      R.Sessions("guild")[1] ~= nil and #R.Sessions("guild") == 2)

-- THE FAILURE THIS GUARDS. The follow-up scan ladder re-enumerates an encounter
-- for four minutes after the kill and re-appends whatever it does not find, so
-- without a tombstone the deleted row simply comes back and the delete looks
-- broken rather than undone.
R.ScanAll(); R.ScanAll()
check("a hand-deleted drop is NOT resurrected by the rescan ladder",
      #victimSession.items == itemsBefore - 1,
      ("%d items after two rescans"):format(#victimSession.items))
check("...and the refusal is counted, not silent",
      (R.declined["deleted by hand"] or 0) >= 1,
      ("counted %s"):format(tostring(R.declined["deleted by hand"])))

check("removing a drop that is already gone reports rather than errors",
      R.DeleteItem(victimRun.index, victimKey) == nil)

-- ── Deleting one run leaves the rest alone ──────────────────────────────────

local before = select(2, R.Counts())
local removed = R.DeleteSession(personalRuns[1].index)
local after = select(2, R.Counts())
check("deleting one run removes only its own loot",
      removed == 1 and after == before - 1, ("removed %d, %d -> %d"):format(removed, before, after))
check("both guild runs survived the delete", #R.Sessions("guild") == 2)

-- ── The whole log must survive SavedVariables ───────────────────────────────

check("the loot log is serialisable to SavedVariables", serialisable(db.loot, 0))

-- ── The Encounter Journal browse path ───────────────────────────────────────
--
-- This is the surface Targets browses, and it is the reason Targets needed no
-- site work at all: raids, dungeons AND world bosses, filtered to what the
-- viewer can use, entirely client-side.

header("journal browse")

local J = ns.Journal

-- ── A COLD CLIENT MUST NOT PAINT A WRONG LIST ───────────────────────────────
--
-- The Session 244 live report: the first look showed 13 items as raw ids with no
-- icons, and coming back later showed a SHORTER list with names. One cause, not
-- two — Blizzard's class/spec filter has to look at an item to judge it, so
-- before the client has loaded them it names nothing AND filters nothing. The
-- old code cached that first read as final, so it only corrected itself when the
-- user happened to navigate away and back.

-- ⚠️ DRAIN, DO NOT DISCARD (Session 254). Logging in now PREWARMS the season's
-- loot, so a warm pass is already booked by the time this runs — and the pending
-- flag that makes repeat asks coalesce is cleared by that timer FIRING. Throwing
-- the queue away instead left the flag latched forever, so the cold read below
-- correctly declined to book a second pass and the check read as a failure.
-- Running the queue is also what actually happens in game.
stub.journal.warm = true
for _ = 1, 20 do
  if #stub.timers == 0 then break end
  stub.RunTimers()
end
stub.journal.warm = false
stub.timers = {}
local coldList, warming = J.CachedLoot(2849, { classID = 3, specID = stub.player.specId })
check("a cold read is reported as still warming, not served as final", warming,
      ("%d items, warming=%s"):format(#coldList, tostring(warming)))
check("...and the client is asked for the item data", #stub.requestedItems > 0)

-- THE RETRY IS BOOKED BY THE READ ITSELF, not by an event. The first version of
-- this waited on GET_ITEM_INFO_RECEIVED, which only fires when the client
-- actually had to load something — so when it did not fire, the panel sat on
-- "Loading item data…" until the user navigated away and back, which is exactly
-- what the loading message was introduced to prevent.
check("a cold read books its own re-read without waiting for an event",
      #stub.timers == 1, ("%d re-reads queued"):format(#stub.timers))

-- Many callers, still one pending re-read.
J.CachedLoot(2849, { classID = 3, specID = stub.player.specId })
stub.Fire("GET_ITEM_INFO_RECEIVED", 270160)
stub.Fire("GET_ITEM_INFO_RECEIVED", 270161)
check("...and repeat asks coalesce into that ONE re-read", #stub.timers == 1,
      ("%d re-reads queued"):format(#stub.timers))

-- The client catches up, and the booked re-read runs.
stub.journal.warm = true
stub.RunTimers()

local warmList, stillWarming = J.CachedLoot(2849, { classID = 3, specID = stub.player.specId })
check("once the client answers, the list is named", not stillWarming
      and warmList[1] and warmList[1].name ~= nil)

-- ⚠️ THE FILTER WORKS WHILE THE ENTRIES ARE STILL COLD. Measured live by
-- /la journal: 17 items filtered to 5, every one of them nameless. I had claimed
-- the opposite — that a cold read cannot be filtered — and written it into both
-- the code comments and this harness, where it would have made the tests agree
-- with the wrong belief. The list LENGTH must therefore be stable across
-- warming; only the names change.
check("...and the cold read was ALREADY filtered — only names were missing",
      #coldList == #warmList,
      ("cold %d -> warm %d; length must not change as names arrive")
        :format(#coldList, #warmList))

-- An item the client will never resolve must not leave the panel loading
-- forever. The scheduled retries drive themselves, so this runs the CLOCK rather
-- than calling the reader — the same path the live addon takes.
stub.journal.warm = false
J.Invalidate()
stub.timers = {}
local _, stillWarming = J.CachedLoot(2849, { classID = 3, specID = stub.player.specId })
local ticks = 0
while stillWarming and ticks < 30 do
  stub.RunTimers()
  ticks = ticks + 1
  _, stillWarming = J.CachedLoot(2849, { classID = 3, specID = stub.player.specId })
end
check("a read that never warms gives up rather than retrying forever",
      not stillWarming and ticks < 30, ("gave up after %d retries"):format(ticks))
check("...and books no further work once it has given up", #stub.timers == 0,
      ("%d timers still queued"):format(#stub.timers))

stub.journal.warm = true
J.Invalidate()

local instances = J.CachedInstances()
-- The WORLD BOSS container is excluded from the browse catalogue — nobody puts a
-- world boss drop on a watch list (Jason, Session 244), and as of Session 251
-- world bosses are out of the Loot tab entirely (Champion track).
--
-- DERIVED FROM THE FIXTURE, not written as a literal, so adding an instance to
-- the stub cannot fail a check about world bosses.
-- ⚠️ RAIDS FROM THE TIER, DUNGEONS FROM THE SEASON (Session 260). The
-- catalogue is no longer "everything in the current tier": a Mythic+ season
-- rotates in revamped dungeons that live in OTHER tiers, and it leaves some of
-- the expansion's own dungeons out of the keystone pool entirely. Deriving the
-- expected count from both sources is the point — the old derivation read the
-- tier alone, which is the question the addon was wrongly asking.
local expectedInstances = 0
for _, inst in ipairs(stub.journal.instances) do
  if inst.isRaid and not ns.Journal.WORLD_BOSS_INSTANCES[inst.id] then
    expectedInstances = expectedInstances + 1
  end
end
local seasonMaps = 0
for _ in pairs(stub.journal.challengeMaps) do seasonMaps = seasonMaps + 1 end
expectedInstances = expectedInstances + seasonMaps

check("raids AND dungeons both enumerate", #instances == expectedInstances,
      ("%d instances, expected %d"):format(#instances, expectedInstances))

-- THE BUG AS JASON FOUND IT, both halves. A season dungeon from an older tier
-- must be present; an expansion dungeon outside the keystone pool must not.
local function catalogueHas(id)
  for _, inst in ipairs(instances) do if inst.id == id then return true end end
  return false
end
check("a season dungeon from an OLDER tier is in the catalogue",
      catalogueHas(1030), "Temple of Sethraliss, which the tier walk cannot see")
check("...and an in-tier dungeon the season does NOT run is left out",
      not catalogueHas(1250), "Magisters' Terrace is not in the keystone pool")
check("...and the fixture contains a world-boss container to exclude",
      expectedInstances < #stub.journal.instances,
      "otherwise the exclusion below is vacuous")

local function hasWorldBossList(list)
  for _, inst in ipairs(list) do
    if inst.id == 1312 or inst.name == "Midnight" then return true end
  end
  return false
end
check("...and the world-boss container is not among them",
      not hasWorldBossList(instances),
      "the tier-named raid entry is the world boss list")

-- THE EXCLUSION MUST NOT REST ON ONE MECHANISM. The first version matched only
-- on the tier name, read through an ASSUMED EJ_GetTierInfo return shape — it
-- shipped, and world bosses were still listed in game. So the id backstop is
-- tested by taking the name away, which is the state that actually occurred.
local savedTierInfo = _G.EJ_GetTierInfo
_G.EJ_GetTierInfo = function() return nil end
J.Invalidate()
check("world bosses stay excluded even when the tier name cannot be resolved",
      not hasWorldBossList(J.CachedInstances()),
      "the id backstop is what covers an unreadable tier name")

-- And with the name available but the id unknown — a future season, where the
-- backstop is stale and the naming convention is all there is.
_G.EJ_GetTierInfo = savedTierInfo
local savedIds = J.WORLD_BOSS_INSTANCES
J.WORLD_BOSS_INSTANCES = {}
J.Invalidate()
check("...and excluded by NAME when the id backstop is stale",
      not hasWorldBossList(J.CachedInstances()),
      "a new season's world-boss container is caught by the naming convention")
J.WORLD_BOSS_INSTANCES = savedIds
J.Invalidate()

local sawRaid, sawDungeon = false, false
for _, inst in ipairs(instances) do
  if inst.isRaid then sawRaid = true else sawDungeon = true end
end
check("...and the dungeon half is really there", sawRaid and sawDungeon)

local encounters = J.CachedEncounters(1317)
check("an instance enumerates its encounters", #encounters == 2,
      ("%d encounters"):format(#encounters))

local unfiltered = J.CachedLoot(2849)
check("an encounter's full loot table reads back", #unfiltered == 3,
      ("%d items"):format(#unfiltered))
check("a loot entry carries what a browse list needs",
      unfiltered[1].name and unfiltered[1].slot and unfiltered[1].itemID)
local sawVeryRare = false
for _, e in ipairs(unfiltered) do if e.veryRare then sawVeryRare = true end end
check("Blizzard's very-rare flag survives the read", sawVeryRare)

-- THE ORDERING TRAP, pinned. EJ_SetLootFilter only bites when the encounter is
-- re-selected afterwards; measured the other way round it reads back correctly
-- and changes nothing, which looks exactly like a broken filter. That cost a
-- whole probe run to work out, so it gets a test rather than a comment.
local filtered = J.CachedLoot(2849, { classID = 3, specID = stub.player.specId })
check("the class filter actually filters", #filtered == 2,
      ("%d of %d items for this class"):format(#filtered, #unfiltered))
check("...and it kept the item this class can use",
      filtered[1].itemID == 270160 or filtered[2].itemID == 270160)

-- Two different lists must not share one cache slot, or whoever asked last wins.
check("filtered and unfiltered results are cached separately",
      #J.CachedLoot(2849) == 3 and #J.CachedLoot(2849, { classID = 3 }) == 2)

-- BROWSING MUST NOT DEGRADE AS YOU CLICK THROUGH IT. This is the Session 244
-- live bug, reproduced: the loot read relied on the instance already being
-- selected, and the restore step moved it — so the first encounter answered and
-- everything after it came back empty, progressively, exactly as if the
-- catalogue had run out. Walking every encounter of every instance repeatedly is
-- what a user does with the arrows, so that is what this does.
local walkOK = true
for pass = 1, 3 do
  for _, inst in ipairs(J.CachedInstances()) do
    for _, enc in ipairs(J.CachedEncounters(inst.id)) do
      local expected = #(stub.journal.loot[enc.id] or {})
      if #J.CachedLoot(enc.id) ~= expected then walkOK = false end
    end
  end
  J.Invalidate()   -- a fresh read each pass, not the cache answering for us
end
check("clicking through every instance and encounter keeps returning loot", walkOK,
      "an encounter must select its OWN instance, never trust ambient state")

-- THE CONTRACT, stated directly rather than hoped for. The walk above passes
-- even with the fix removed, because each read happens to follow its own
-- encounter list and the ambient selection is coincidentally right — which is
-- exactly why the live bug survived the harness in the first place. So point the
-- journal somewhere ELSE and then read: a loot read must not care what is
-- currently selected.
J.Invalidate()
stub.journal.selectedInstance = 1304          -- a DIFFERENT instance
stub.journal.selectedEncounter = nil
local crossed = J.CachedLoot(2849)            -- an encounter of 1317
check("a loot read selects its own instance instead of trusting what is selected",
      #crossed == 3,
      ("%d items read while the journal pointed at another instance"):format(#crossed))

-- The specific corruption behind the live failure: an id guessed from a call
-- that does not return one. EJ_GetInstanceInfo's third value is a texture file
-- id, so it looks like an answer and passes a type check.
check("the browse path never selects an instance it only guessed at",
      stub.journal.encounters[stub.journal.selectedInstance] ~= nil,
      ("journal left pointing at %s"):format(tostring(stub.journal.selectedInstance)))

-- A cold item cache returns an entry with an id and no name. It must be reported
-- as such and re-asked, never frozen — the same failure that wrote item numbers
-- into the loot log as item names.
local coldBefore = #stub.requestedItems
local cold = J.CachedLoot(2910)
check("an item the client cannot name yet still appears, by id",
      #cold == 1 and cold[1].itemID == 270999 and cold[1].name == nil)
check("...and the client is asked to load it", #stub.requestedItems > coldBefore)

-- ── Targets ─────────────────────────────────────────────────────────────────

header("targets")

local T = ns.Targets
local TARGET_ITEM, TARGET_REC = findItem(function() return true end)

check("nothing is targeted to begin with", T.Count() == 0)
check("toggling on reports that it is now targeted",
      T.Toggle(TARGET_ITEM, { name = TARGET_REC.name }) == true)
check("...and it reads back as targeted", T.Has(TARGET_ITEM))
check("toggling again reports that it is no longer targeted",
      T.Toggle(TARGET_ITEM) == false)
check("...and it is gone", not T.Has(TARGET_ITEM) and T.Count() == 0)

-- THE SEPARATION THAT MATTERS. The loot log is account-wide so guild loot from
-- every character lands in one place; targets are per-character because a
-- Hunter's targets are meaningless on a Paladin. A per-character FILE cannot
-- leak across characters through a keying bug the way a hand-rolled namespace
-- inside the account file could — but only if nothing writes them there.
T.Add(TARGET_ITEM, { name = TARGET_REC.name, source = "Test Raid · Test Boss" })
check("a target is stored in the PER-CHARACTER saved variable",
      _G.HoDLootAdvisorCharDB and _G.HoDLootAdvisorCharDB.items[TARGET_ITEM] ~= nil)
check("...and NOT in the account-wide one",
      ns.db.targets == nil and ns.db.items == nil,
      "targets must never be written to the account-wide table")

check("targets survive a SavedVariables round trip",
      serialisable(_G.HoDLootAdvisorCharDB, 0))

-- Flagging something the client cannot name yet must not be blocked — the id is
-- the record and the name is a cache. Same eventual-consistency rule the loot
-- recorder and the journal browse both follow.
local UNCACHED = 999777
T.Add(UNCACHED)
check("an item with no cached name can still be flagged", T.Has(UNCACHED))
local before = #stub.requestedItems
local pending = T.ResolveNames()
check("...and the client is asked to load it rather than freezing a placeholder",
      pending >= 1 and #stub.requestedItems > before,
      ("%d pending, %d requests"):format(pending, #stub.requestedItems - before))
T.Remove(UNCACHED)

-- ── The tooltip line ────────────────────────────────────────────────────────

header("tooltip")

local method = ns.Tooltip.Start()
check("a tooltip mechanism was found and recorded", method ~= nil, tostring(method))

local lines = stub.FireTooltip(TARGET_ITEM)
local sawTargeted = false
for _, l in ipairs(lines) do
  if tostring(l.text):find("Targeted") then sawTargeted = true end
end
check("a targeted item announces itself in its own tooltip", sawTargeted,
      ("%d lines added"):format(#lines))

-- THE HALF THAT MATTERS MORE. This runs on EVERY item tooltip in the game, so
-- an item nobody flagged must come back completely untouched — not a blank line,
-- not a prefix, nothing.
local clean = stub.FireTooltip(UNCACHED)
check("an item that is NOT targeted gets no line at all", #clean == 0,
      ("%d lines added to an untargeted item"):format(#clean))

T.Clear()
check("clearing removes every target", T.Count() == 0)

-- Written for test/check-export.ts, which parses it with the REAL site parser
-- (app/lib/loot-export.ts). A Lua-side imitation of that parser would only prove
-- the same misunderstanding twice — the same argument that made make-payload.ts
-- use the real encoder.
local out = io.open("test/export.txt", "w")
if out then
  out:write(guildText)
  out:close()
  io.write("       wrote test/export.txt for check-export.ts\n")
end

-- ── A decline is never silent ───────────────────────────────────────────────
--
-- The first live night was lost to this: a blue drop was correctly rejected by
-- the quality gate in BOTH addons, and the only observable outcome was "nothing
-- was recorded" — identical to a real failure. Every rejection is now counted
-- with its reason, so /la loot status can tell the two apart.

do
R.declined = {}
stub.items[270199] = { name = "A Blue Thing", quality = 3, ilvl = 280, itemType = "Armor" }
local beforeDecline = select(2, R.Counts())
stub.Fire("ENCOUNTER_LOOT_RECEIVED", 0, 270199,
          stub.link(270199, "A Blue Thing", {}), 1, "Gloomrift", "HUNTER")

check("a below-threshold drop is not recorded",
      select(2, R.Counts()) == beforeDecline)
check("...but the refusal is COUNTED, with its reason",
      (R.declined["below the quality threshold"] or 0) == 1,
      tostring(R.declined["below the quality threshold"]))

-- Lowering the threshold is what makes a follower dungeon testable at all.
ns.Settings.Set("minQuality", "3")
stub.Fire("ENCOUNTER_LOOT_RECEIVED", 0, 270199,
          stub.link(270199, "A Blue Thing", {}), 1, "Gloomrift", "HUNTER")
check("lowering minQuality lets the same drop through",
      select(2, R.Counts()) == beforeDecline + 1)
ns.Settings.Set("minQuality", "4")
end

-- ── The Journal probe ───────────────────────────────────────────────────────
--
-- The probe exists to ANSWER what the Encounter Journal API is, not to assume
-- it — two wrong recollections have already cost real time here. It is kept
-- SEPARATE from the browse path above for exactly that reason: the browse path
-- is built on what the probe found, and the probe must stay able to contradict
-- it on a client where the answer has changed.

do
header("JOURNAL PROBE")

local okProbe, probeResult = pcall(ns.Journal.Probe)
check("the probe runs against a present API", okProbe,
      not okProbe and tostring(probeResult) or nil)
check("...and reports what it found rather than a fixed list",
      okProbe and #probeResult.present > 0 and #probeResult.absent > 0,
      okProbe and ("%d present / %d absent"):format(#probeResult.present, #probeResult.absent))
-- COUNTS DERIVED FROM THE FIXTURE, never written as literals. These were 2 and
-- 1; adding one dungeon to the stub broke an assertion that had nothing to do
-- with the change. The standing rule for these fixtures is to derive, so that a
-- fixture edit cannot fail a test it does not concern — or worse, quietly stop
-- testing anything after one.
local wantRaids, wantDungeons = 0, 0
for _, inst in ipairs(stub.journal.instances) do
  -- The world-boss container is a RAID entry the browse list excludes, so it
  -- counts here exactly as the probe counts it: as a raid.
  if inst.isRaid then wantRaids = wantRaids + 1 else wantDungeons = wantDungeons + 1 end
end
check("...enumerating DUNGEONS separately from raids — the whole question",
      okProbe and probeResult.Raids.count == wantRaids
        and probeResult.Dungeons.count == wantDungeons,
      okProbe and ("%d raids / %d dungeons, fixture has %d / %d"):format(
        probeResult.Raids.count, probeResult.Dungeons.count, wantRaids, wantDungeons))
check("...and the fixture actually contains both kinds",
      wantRaids > 0 and wantDungeons > 0, "otherwise the check above is vacuous")
-- The first live probe recorded 5 of 9 dungeons and could not answer "which
-- ones". A list short enough to walk is short enough to keep whole.
check("...recording EVERY instance, not a sample of them",
      okProbe and #probeResult.Dungeons.list == probeResult.Dungeons.count
        and #probeResult.Raids.list == probeResult.Raids.count)
-- The namespace split, pinned: loot reads resolve to C_EncounterJournal, and
-- keying them by the EJ_ name reported 17 items and enumerated zero of them.
check("...resolving loot through the namespace it actually lives in",
      okProbe and probeResult.loot and probeResult.loot.via == "GetLootInfoByIndex",
      okProbe and probeResult.loot and tostring(probeResult.loot.via))

-- A CLIENT WITH NONE OF IT. Still the property that makes the probe safe to run
-- anywhere, so it is tested by taking the API away rather than by never having
-- provided it.
-- ⚠️ EVERY EJ_ GLOBAL, NOT A HAND-KEPT LIST (Session 260). This was a literal
-- roll-call of thirteen names, and the moment the stub gained three more the
-- scenario stopped being "a client with none of the API" — it became "a client
-- missing the thirteen we remembered", which reported 3 present and failed a
-- check that was testing the right thing all along. A set defined by
-- enumeration goes stale silently; one defined by its RULE cannot.
local savedEJ = {}
for name in pairs(_G) do
  if type(name) == "string" and name:match("^EJ_") then savedEJ[name] = _G[name] end
end
for name in pairs(savedEJ) do _G[name] = nil end
local savedNS = _G.C_EncounterJournal
_G.C_EncounterJournal = nil

local okBare, bareResult = pcall(ns.Journal.Probe)
check("the probe survives a client with none of the API", okBare,
      not okBare and tostring(bareResult) or nil)
check("...and reports every candidate as absent rather than guessing",
      okBare and #bareResult.present == 0 and #bareResult.absent > 20,
      okBare and ("%d present / %d absent"):format(#bareResult.present, #bareResult.absent))
check("...without inventing counts it could not obtain",
      okBare and bareResult.numTiers == nil and bareResult.lootCount == nil)

-- The BROWSE path has to degrade the same way, since it runs on every panel
-- refresh: an absent API means an empty list, never an error in someone's face.
ns.Journal.Invalidate()
local okBrowse, browseResult = pcall(ns.Journal.CachedInstances)
check("browsing an absent catalogue returns nothing rather than erroring",
      okBrowse and type(browseResult) == "table" and #browseResult == 0,
      not okBrowse and tostring(browseResult) or nil)

for name, fn in pairs(savedEJ) do _G[name] = fn end
_G.C_EncounterJournal = savedNS
ns.Journal.Invalidate()
end

-- ── Windows behave like windows ─────────────────────────────────────────────
--
-- Escape must close the addon, the way every other WoW window works. Blizzard's
-- CloseSpecialWindows() walks UISpecialFrames and hides every shown frame in it,
-- so one press closes the lot. It holds GLOBAL NAMES — an anonymous frame
-- registers nothing and fails silently, which is why every window is named.

header("WINDOWS")

local win = CreateFrame("Frame", "HoDLootAdvisorTestWindow")
ns.MakeWindow(win)
check("a window is raised above its siblings when clicked", win.toplevel == true)
check("...and cannot be dragged off screen", win.clamped == true)

-- ⚠️ NOT UISpecialFrames ANY MORE (Session 258). That list closes EVERY shown
-- frame in it on one press, so with four windows open one Escape closed the
-- whole addon. The stack below is ours and Escape takes one off the top.
check("a window is not handed to UISpecialFrames", (function()
  for _, n in ipairs(UISpecialFrames or {}) do
    if n == "HoDLootAdvisorTestWindow" then return false end
  end
  return true
end)())

-- Showing pushes, hiding pops, and the LAST one shown is what Escape closes.
local stackBefore = #ns.windowStack
win:Show()
check("showing a window puts it on the stack", #ns.windowStack == stackBefore + 1,
      #ns.windowStack)
check("...and Escape closes that one", ns.EscapeTop() == win)
check("...leaving the stack as it was", #ns.windowStack == stackBefore,
      #ns.windowStack)

-- A window shown twice must not sit on the stack twice, or the second Escape
-- would close something already gone.
ns.MakeWindow(win)
win:Show()
win:Show()
local dupes = 0
for _, f in ipairs(ns.windowStack) do if f == win then dupes = dupes + 1 end end
check("showing twice does not duplicate the entry", dupes == 1, dupes)
ns.EscapeTop()

local anon = CreateFrame("Frame")
local before = #UISpecialFrames
ns.MakeWindow(anon)
check("an ANONYMOUS frame registers nothing — the trap this API sets",
      #UISpecialFrames == before)

-- A window remembers where it was dragged to, across opens and across sessions.
-- The default placement is only ever the answer to "where does this go the FIRST
-- time" — a position the user chose outranks it.

win.left, win.top = 412, 733
win.scripts.OnDragStop(win)
check("dragging a window saves its position", ns.db.windows["HoDLootAdvisorTestWindow"] ~= nil)
check("...as screen coordinates, not as an anchor to another frame",
      ns.db.windows["HoDLootAdvisorTestWindow"].left == 412)

win.points = {}
check("the saved position is restored on the next open", ns.RestoreWindowPosition(win) == true)
check("...to exactly where it was left",
      win.points[1] and win.points[1].x == 412 and win.points[1].y == 733,
      win.points[1] and (win.points[1].x .. "," .. win.points[1].y))

check("a window that was never moved has nothing to restore",
      ns.RestoreWindowPosition(CreateFrame("Frame", "HoDLootAdvisorNeverMoved")) == false)

ns.ResetWindowPositions()
check("positions can be forgotten, for a window dragged somewhere unhelpful",
      ns.RestoreWindowPosition(win) == false)

-- ── Settings keys are case-insensitive ──────────────────────────────────────
--
-- /la set lowercased its argument before looking it up, so every setting whose
-- key is not already all-lowercase answered "unknown setting" — showGap,
-- autoOpen and minQuality, half of them. The listing prints the camelCase key,
-- so it was telling people to type the exact string it would then reject.

check("a camelCase key resolves", ns.Settings.Set("minQuality", "3") == true)
check("...and so does the all-lowercase form the slash command used to produce",
      ns.Settings.Set("minquality", "4") == true)
check("both write the SAME stored key, not two invisible copies",
      ns.Settings.Get("minQuality") == 4 and ns.db.settings.minquality == nil,
      tostring(ns.db.settings.minquality))
check("a genuinely unknown key is still rejected",
      ns.Settings.Set("nosuchsetting", "1") == false)

-- ── A lowered threshold must not follow you into a raid ─────────────────────
--
-- minQuality is a TESTING knob: it exists so a delve records something. Carried
-- into a raid it is the expensive version — raid trash drops blues, and Guild
-- runs are what reach the website's loot history.
--
-- SINCE SESSION 245 nothing starts guild, so the warning moved to the moment the
-- run is MARKED Guild. That is also the more useful moment: marking usually
-- happens after the raid, when no further drop would arrive to trigger it.

ns.Settings.Set("minQuality", "3")
stub.inRaid = true
stub.instance = {
  name = "Tidebound Grotto", difficultyID = 16,
  difficultyName = "Mythic (Raid)", instanceID = 2925,
}
local before = #stub.printed
stub.lootHistory[9001] = {
  stub.drop(1, 270160, "Sunfury Chestguard", { 12841 },
            { { name = "Gloomrift", state = 0, roll = 50, isWinner = true } }),
}
stub.Fire("ENCOUNTER_END", 9001, "Some Boss", 16, 20, 1)
stub.RunTimers()

local warnedOnDrop = false
for i = before + 1, #stub.printed do
  if stub.printed[i]:find("GUILD run", 1, true) then warnedOnDrop = true end
end
check("a lowered threshold does NOT warn while the run is still personal",
      not warnedOnDrop)

local beforeMark = #stub.printed
for _, r in ipairs(R.Sessions()) do
  if r.session and r.session.instanceID == 2925 then R.SetKind(r.index, "guild") end
end
local warned = false
for i = beforeMark + 1, #stub.printed do
  if stub.printed[i]:find("GUILD run", 1, true) then warned = true end
end
check("marking a run Guild with a lowered threshold warns about it", warned)

-- Once per run, not once per drop — a warning that repeats is a warning nobody
-- reads.
local afterFirst = #stub.printed
R.ScanAll()
local repeated = false
for i = afterFirst + 1, #stub.printed do
  if stub.printed[i]:find("GUILD run", 1, true) then repeated = true end
end
check("...and does not repeat for every later drop in the same run", not repeated)

ns.Settings.Set("minQuality", "4")
stub.inRaid = false

-- Remove the throwaway raid so the later run-count checks stay about the runs
-- they were written for.
for _, r in ipairs(R.Sessions("guild")) do
  if r.session.instanceID == 2925 then R.DeleteSession(r.index) end
end
stub.instance = {
  name = "The Venomous Abyss", difficultyID = 15,
  difficultyName = "Heroic (Raid)", instanceID = 2917,
}
check("the throwaway raid was cleaned up", #R.Sessions("guild") == 2,
      ("%d guild runs"):format(#R.Sessions("guild")))

-- ── A late scan, after you have already left ────────────────────────────────
--
-- The follow-up ladder runs to four minutes after a kill, which is long enough
-- to have left the instance — and GetInstanceInfo then reports nothing at all.
-- A drop belongs to the run the boss died in, so the encounter stays bound to
-- its session and a late scan still lands. Before that binding existed, the
-- winner everyone was waiting for was silently dropped on the floor.

do
local guildBefore = select(2, R.Counts("guild"))
stub.instance.instanceType = "none"          -- back in a city
check("we are genuinely outside an instance now", select(2, GetInstanceInfo()) == "none")

stub.lootHistory[2849][#stub.lootHistory[2849] + 1] =
  stub.drop(3, 270162, "Venom-Drenched Sack", { 12841 }, {
    { name = "Mîrâñ", state = 0, roll = 66, isWinner = true },
  })
R.ScanAll()

local guildAfter = select(2, R.Counts("guild"))
check("a scan landing after you left the instance still records the drop",
      guildAfter == guildBefore + 1, ("%d -> %d"):format(guildBefore, guildAfter))
check("...into the run the boss died in, not a new one", #R.Sessions("guild") == 2)
check("and it is filed under the character who was there",
      (function()
        for _, r in ipairs(R.Sessions("guild")) do
          for _, e in ipairs(r.session.items) do
            if e.winner == "Mîrâñ" then return r.session.character == "Gloomrift" end
          end
        end
      end)())

stub.instance.instanceType = "raid"
end

-- ── Item data arrives late ──────────────────────────────────────────────────
--
-- GetItemInfo answers nil for anything not yet cached, so a drop read seconds
-- after a kill — and ALL personal loot, which is never rescanned — can be stored
-- as a bare "item:270160". Left alone the entry keeps that forever: the review
-- window shows a list of numbers, and the export writes those numbers as the
-- item NAME, producing loot rows the site can never reconcile.

local late = run.items[1]
local realName = late.itemName
late.itemName, late.itemILevel = "item:" .. late.itemID, 0

check("a fixture with an unresolved name is set up", late.itemName:match("^item:%d+$") ~= nil)
local fixedCount = R.ResolveItemInfo()
check("an unresolved item name is re-resolved once the client can answer",
      late.itemName == realName, late.itemName)
check("and the rest of the item data comes back with it",
      late.itemILevel == 305 and fixedCount >= 1, late.itemILevel)

-- Nothing to do when everything already resolves — this runs on every draw.
check("a second pass over resolved data changes nothing", R.ResolveItemInfo() == 0)

-- ── Guild is opt-in; nothing is auto-tagged (Session 245) ───────────────────
--
-- IsInRaid() alone used to decide this, so Season 2's opening day auto-tagged
-- an LFR wing AND a world boss as guild loot — a pug's drops and 33 rows of
-- world-boss currency headed for the site's loot history. The rule is now that
-- there is no rule: every run starts personal and "Mark Guild" is deliberate.
--
-- These two cases are kept as named regressions rather than folded into one
-- generic check, because they are the runs that actually caused the loss and a
-- future change to the default should have to fail on THEM by name.

local guildRunsBefore = #R.Sessions("guild")

stub.inRaid, stub.inGroup = true, true
stub.instance = {
  name = "The Venomous Abyss", difficultyID = 17,
  difficultyName = "Looking For Raid", instanceID = 3004,
}
stub.items[270914] = { name = "Venomwoven Effigy", quality = 4, ilvl = 285, itemType = "Miscellaneous" }
stub.Fire("ENCOUNTER_LOOT_RECEIVED", 0, 270914,
          stub.link(270914, "Venomwoven Effigy", { 12827 }), 1, "Gloomrift-Stormrage", "HUNTER")

local lfr
for _, r in ipairs(R.Sessions()) do
  if r.session and r.session.instanceID == 3004 then lfr = r.session end
end
check("an LFR run is recorded at all", lfr ~= nil)
check("...but is NOT auto-tagged as guild loot, despite being a raid group",
      lfr and lfr.kind == "personal", lfr and lfr.kind)

stub.instance = {
  name = "The Tidebound Grotto", difficultyID = 250,
  difficultyName = "World", instanceID = 2987,
}
stub.items[273000] = { name = "Corrosive Soul", quality = 4, ilvl = 1, itemType = "Miscellaneous" }
stub.Fire("ENCOUNTER_LOOT_RECEIVED", 0, 273000,
          stub.link(273000, "Corrosive Soul", {}), 1, "Gloomrift-Stormrage", "HUNTER")

local world
for _, r in ipairs(R.Sessions()) do
  if r.session and r.session.instanceID == 2987 then world = r.session end
end
check("a world-boss run is not auto-tagged as guild loot either",
      world and world.kind == "personal", world and world.kind)

check("and neither one joined the guild export",
      #R.Sessions("guild") == guildRunsBefore,
      ("%d guild runs, expected %d"):format(#R.Sessions("guild"), guildRunsBefore))

-- And a genuine raid difficulty is no exception: Guild is opt-in everywhere, so
-- the real raid night starts personal too and is promoted by hand.
stub.instance = {
  name = "The Venomous Abyss", difficultyID = 16,
  difficultyName = "Mythic (Raid)", instanceID = 3004,
}
stub.items[268251] = { name = "Amulet of the Twin Fangs", quality = 4, ilvl = 285, itemType = "Armor" }
stub.Fire("ENCOUNTER_LOOT_RECEIVED", 0, 268251,
          stub.link(268251, "Amulet of the Twin Fangs", { 12827 }), 1, "Gloomrift-Stormrage", "HUNTER")

local mythic
for _, r in ipairs(R.Sessions()) do
  if r.session and r.session.difficultyID == 16 then mythic = r.session end
end
check("even a real raid difficulty starts personal — Guild is opt-in everywhere",
      mythic and mythic.kind == "personal", mythic and mythic.kind)

local mythicRun
for _, r in ipairs(R.Sessions()) do
  if r.session == mythic then mythicRun = r end
end
check("...and Mark Guild is what promotes it", mythicRun ~= nil
      and R.SetKind(mythicRun.index, "guild") and mythic.kind == "guild", mythic.kind)
check("a hand-set tag is never re-derived afterwards", mythic.kindManual == true)

-- Put the harness back where the export checks below expect to find it.
stub.inRaid, stub.inGroup = false, false
stub.instance = {
  name = "Ara-Kara, City of Echoes", difficultyID = 8,
  difficultyName = "Mythic+ (5-man)", instanceID = 2660,
}

-- ── A /reload must not strand a winner that had not resolved yet (S245) ─────
--
-- REPRODUCES A REAL LOSS. On 2026-08-18 a world boss died at 13:36:22, six
-- group-loot drops were seen at 13:36:26, and a /reload at 13:39:07 landed 161
-- seconds in — after the 150s follow-up scan, before the 240s one. All six lost
-- their winner permanently, because PLAYER_ENTERING_WORLD wipes knownEncounters
-- and ScanAll() then has nothing to iterate: `/la loot scan` could not retry.
--
-- The recovery has to re-derive the encounter id from the ROW'S KEY, since the
-- stored encounterID is the journal id and only the key holds the loot-history
-- one. Seeding the wrong id space scans nothing while looking correct.

stub.inRaid, stub.inGroup = true, true
stub.instance = {
  name = "The Tidebound Grotto", difficultyID = 16,
  difficultyName = "Mythic (Raid)", instanceID = 2987,
}
stub.items[268238] = { name = "Grips of Swirling Fury", quality = 4, ilvl = 279, itemType = "Armor" }

-- The drop is seen while the roll is still open: rollers, but no winner yet.
stub.lootHistory[4242] = {
  stub.drop(1, 268238, "Grips of Swirling Fury", { 12825 }, {
    { name = "Gloomrift", state = 0, roll = 0 },
    { name = "Dröokz",    state = 0, roll = 0 },
  }),
}
stub.Fire("LOOT_HISTORY_UPDATE_DROP", 4242, 1)
stub.RunTimers(); R.ScanAll()

local pending
for _, r in ipairs(R.Sessions()) do
  for _, e in ipairs((r.session or {}).items or {}) do
    if e.itemID == 268238 then pending = e end
  end
end
check("a drop seen mid-roll is recorded before any winner exists", pending ~= nil)
check("...and has no winner yet", pending and (pending.winner == nil or pending.winner == ""),
      pending and pending.winner)

-- The /reload. This is what used to make the loss permanent.
stub.Fire("PLAYER_ENTERING_WORLD", false, true)

-- Meanwhile the roll resolved, exactly as the client would report afterwards.
stub.lootHistory[4242] = {
  stub.drop(1, 268238, "Grips of Swirling Fury", { 12825 }, {
    { name = "Gloomrift", state = 0, roll = 41 },
    { name = "Dröokz",    state = 0, roll = 93, isWinner = true },
  }),
}

-- What `/la loot scan` does. Without the re-seed this iterates nothing.
stub.RunTimers()
R.ScanAll()

check("after a reload, a pending winner is still recoverable",
      pending and pending.winner == "Dröokz", pending and (pending.winner or "still nil"))
check("...and it updated the existing row rather than adding a second one",
      (function()
        local n = 0
        for _, r in ipairs(R.Sessions()) do
          for _, e in ipairs((r.session or {}).items or {}) do
            if e.itemID == 268238 then n = n + 1 end
          end
        end
        return n == 1
      end)(), "duplicate rows for one drop")

-- ── Item quality: grades AND best-in-slot (schema 2, Session 245) ───────────
--
-- The parity harness proves the SCORER handles grades and BIS. It says nothing
-- about the PLUMBING that feeds them, which is what this covers — and the
-- plumbing is where the interesting failure is.
--
-- Everything below is found IN THE PAYLOAD rather than hard-coded, so a re-emit
-- or a season rollover cannot quietly turn these into vacuous passes.

-- In its OWN FUNCTION, not a do-block: Lua's 200-local limit is per FUNCTION,
-- and a do-block shares the main chunk's budget, which is already nearly full.
-- Everything it needs (ns, data, check, header) is reached as an upvalue.
-- The leading SEMICOLON is required: a line starting with '(' is otherwise
-- parsed as calling whatever the previous line evaluated to.
;(function()
  header("item quality — grades, BIS, and the keys they hide under")

  local S = ns.Scoring

  -- (1) THE SPLIT-KEY CASE, which is the whole reason resolution is per-field.
  -- Three specs grade trinkets differently in Raid vs Mythic+, so their GRADE sits
  -- on a "#scope" key — while their BIS listing never does, because a BIS context
  -- is the listing KIND, not a filter. Resolve per ENTRY and you find one and lose
  -- the other.
  local splitItem, splitKey, splitScope, splitGrade, splitBis
  for id, byKey in pairs(data.rankings) do
    for k, e in pairs(byKey) do
      local base, scope = k:match("^(.-)#(.+)$")
      if base and e.g and byKey[base] and byKey[base].b then
        splitItem, splitKey, splitScope = id, base, scope
        splitGrade, splitBis = e.g, byKey[base].b
        break
      end
    end
    if splitItem then break end
  end

  check("the payload contains a grade and a BIS listing on DIFFERENT keys",
        splitItem ~= nil, "no split-key case found — this check would be vacuous")

  if splitItem then
    local cls, spec = splitKey:match("^(.-)/(.+)$")
    local q = S.resolveQuality(data.rankings, splitItem, cls, spec, nil, splitScope)
    check("...and both survive resolution together",
          q ~= nil and q.grade == splitGrade and q.bis == splitBis,
          q and ("grade=%s bis=%s, wanted grade=%s bis=%s")
            :format(tostring(q.grade), tostring(q.bis), splitGrade, splitBis) or "nil")

    -- Out of that content type, the scoped grade must NOT be borrowed: an unscoped
    -- grade is the spec's general answer, a wrongly-scoped one is a confident
    -- answer to a question nobody asked.
    local other = (splitScope == "raid") and "mplus" or "raid"
    local qOther = S.resolveQuality(data.rankings, splitItem, cls, spec, nil, other)
    local baseGrade = (data.rankings[splitItem][splitKey] or {}).g
    local otherGrade = (data.rankings[splitItem][splitKey .. "#" .. other] or {}).g
    check("a scoped grade is not borrowed across content types",
          qOther == nil or qOther.grade == (otherGrade or baseGrade),
          qOther and tostring(qOther.grade) or "nil")
    check("...while the BIS listing, which is not scoped, still resolves",
          qOther ~= nil and qOther.bis == splitBis,
          qOther and tostring(qOther.bis) or "nil")
  end

  -- (2) HERO-TREE KEYS. Vengeance DH is the only spec that grades per tree, and
  -- it has NO base row at all — all 43 of its rows are tree-keyed (verified
  -- against the database, not inferred from the payload). Both of its trees are
  -- present, so a character on a KNOWN tree always resolves; a Vengeance DH
  -- whose tree we do not know resolves nothing.
  --
  -- ⚠️ That contradicts the comfortable claim that "the spec-level key always
  -- resolves". It is NOT a divergence — the site's pickRanking() returns null in
  -- exactly the same case, because every row scores -1 when no tree matches — so
  -- the two agree. It is a DATA property worth pinning down here, so that a
  -- future harvest which adds a base row does not change behaviour unnoticed.
  local treeItem, treeBaseKey, treeName, treeGrade
  for id, byKey in pairs(data.rankings) do
    for k, e in pairs(byKey) do
      local base, tree = k:match("^([^#]-/[^/#]+)/([^#]+)$")
      if base and tree and e.g then
        treeItem, treeBaseKey, treeName, treeGrade = id, base, tree, e.g
        break
      end
    end
    if treeItem then break end
  end

  check("the payload carries at least one hero-tree keyed grade",
        treeItem ~= nil, "none in payload — the checks below would be vacuous")

  if treeItem then
    local cls, spec = treeBaseKey:match("^(.-)/(.+)$")
    check("a hero-tree grade resolves for a character on that tree",
          S.resolveRankedTier(data.rankings, treeItem, cls, spec, treeName) == treeGrade,
          tostring(S.resolveRankedTier(data.rankings, treeItem, cls, spec, treeName)))

    -- Whatever the base key holds is what a character off that tree must get —
    -- the grade if a base row exists, nothing if it does not. Asserted against
    -- the payload rather than hard-coded, so this stays true either way.
    local baseEntry = data.rankings[treeItem][treeBaseKey]
    local expected  = baseEntry and baseEntry.g or nil
    check("a character on another tree falls back to the base row, or to nothing",
          S.resolveRankedTier(data.rankings, treeItem, cls, spec, "Not A Real Tree") == expected,
          ("got %s, base row %s"):format(
            tostring(S.resolveRankedTier(data.rankings, treeItem, cls, spec, "Not A Real Tree")),
            baseEntry and "exists" or "does not exist"))
  end

  -- (3) `bx` is omitted by the emitter whenever it would just repeat `b`, so the
  -- resolver rebuilds it. Callers that want the LABEL want the full set, and
  -- making each of them handle "sometimes absent" is how one ends up not.
  local singleItem, singleKey
  for id, byKey in pairs(data.rankings) do
    for k, e in pairs(byKey) do
      if e.b and not e.bx then singleItem, singleKey = id, k break end
    end
    if singleItem then break end
  end
  if singleItem then
    local cls, spec = singleKey:match("^([^/]+)/([^/#]+)")
    local q = S.resolveQuality(data.rankings, singleItem, cls, spec, nil, nil)
    check("a single-context BIS listing still reports its context list",
          q and q.contexts and #q.contexts == 1 and q.contexts[1] == q.bis,
          q and q.contexts and table.concat(q.contexts, ",") or "nil")
  end

  -- (4) An item listed BIS but never graded must still score as a quality item —
  -- this is the path that did not exist before, and the one BIS is FOR.
  local bisOnlyItem, bisOnlyKey, bisOnlyKind
  for id, byKey in pairs(data.rankings) do
    for k, e in pairs(byKey) do
      if e.b and not e.g and not k:find("[#/].*[#/]") then
        bisOnlyItem, bisOnlyKey, bisOnlyKind = id, k, e.b break
      end
    end
    if bisOnlyItem then break end
  end
  if bisOnlyItem then
    local cls, spec = bisOnlyKey:match("^([^/]+)/([^/#]+)")
    local q = S.resolveQuality(data.rankings, bisOnlyItem, cls, spec, nil, nil)
    check("an item that is BIS but ungraded resolves a BIS listing and no grade",
          q ~= nil and q.bis == bisOnlyKind and q.grade == nil,
          q and ("bis=%s grade=%s"):format(tostring(q.bis), tostring(q.grade)) or "nil")

    -- And it must actually reach the scorer as the quality signal.
    local scored = S.scoreCandidate(
      { equipped_ilvl = 0, equipped_track = nil, piece_count = 0,
        declared_need = false, ranked_tier = nil, bis = bisOnlyKind,
        already_owns = false, owned_ilvl = 0 },
      { slot = "TRINKET", is_tier = false, stats = {} },
      nil, 300, "Hero")
    check("...and a BIS listing drives the item-quality override in the scorer",
          scored.is_ranked_override == true, tostring(scored.is_ranked_override))
  end

  check("an unknown item resolves to nothing rather than erroring",
        S.resolveQuality(data.rankings, 1, "Hunter", "Marksmanship", nil, nil) == nil)

  -- ── What any of this actually LOOKS like ─────────────────────────────────
  --
  -- The checks above prove resolution. These prove the two surfaces a person
  -- reads: the compact tag on a chip or a ranking row, and the tooltip wording.
  -- Without them BIS is invisible except as a badge that silently got bigger.

  -- ⚠️ DERIVED FROM THE MAP, NOT SPELT OUT — and it still bites. What this
  -- check is FOR is that a BIS listing beats a grade, so it asserts the tag is
  -- the BIS label AND is not the grade's letter. Hardcoding "BIS" made it fail
  -- when the overall listing was renamed to "O-BIS" (Session 257), which is a
  -- label change and not a behaviour change — the S247 rule about deriving from
  -- the fixture rather than repeating its contents, applied to a label map.
  check("BIS outranks a grade in the tag, matching the scorer's strongest-wins",
        ns.QualityTag({ grade = "c", bis = "overall" }) == ns.BIS_SHORT.overall
        and ns.QualityTag({ grade = "c", bis = "overall" }) ~= "C",
        tostring(ns.QualityTag({ grade = "c", bis = "overall" })))
  check("a single-content BIS listing is distinguishable from an overall one",
        ns.QualityTag({ bis = "raid" }) == "R-BIS" and ns.QualityTag({ bis = "mplus" }) == "M-BIS")
  check("a grade shows as its letter when there is no BIS listing",
        ns.QualityTag({ grade = "s" }) == "S")
  check("the tank category is labelled, not shown as a letter",
        ns.QualityTag({ grade = "defensive" }) == "DEF")
  check("nothing to say produces no tag at all", ns.QualityTag(nil) == nil
        and ns.QualityTag({}) == nil)

  -- Tooltip wording, on a REAL item this character actually has a listing for.
  local meKey = stub.player.className .. "/" .. stub.player.specName
  local tipItem, tipEntry
  for id, byKey in pairs(data.rankings) do
    local e = byKey[meKey]
    if e and e.b then tipItem, tipEntry = id, e break end
  end
  check("this character has a BIS listing to render", tipItem ~= nil, meKey)

  if tipItem then
    local tipLines = stub.FireTooltip(tipItem)
    local joined = ""
    for _, l in ipairs(tipLines) do joined = joined .. tostring(l.text) .. "\n" end
    local wanted = ({ overall = "Overall BIS", raid = "Raid BIS", mplus = "M+ BIS" })[tipEntry.b]
    check("the tooltip names the BIS listing in words, not a code",
          joined:find(wanted, 1, true) ~= nil, joined:gsub("\n", " | "))

    -- Every context, not just the strongest: Raid BIS and M+ BIS score the same,
    -- so naming only one tells half the readers the wrong thing.
    if tipEntry.bx and #tipEntry.bx > 1 then
      local allNamed = true
      for _, ctx in ipairs(tipEntry.bx) do
        local long = ({ overall = "Overall BIS", raid = "Raid BIS", mplus = "M+ BIS" })[ctx]
        if long and not joined:find(long, 1, true) then allNamed = false end
      end
      check("...and names EVERY context that lists it, not just the strongest",
            allNamed, joined:gsub("\n", " | "))
    end

    if tipEntry.g then
      check("...and reports the letter grade alongside the BIS listing",
            joined:find("Grade " .. tipEntry.g:upper(), 1, true) ~= nil
            or joined:find("Defensive", 1, true) ~= nil, joined:gsub("\n", " | "))
    end
  end

  -- A catalyse target names the piece you end up with, because under 12.1 the
  -- drop you chase and the piece you get are different items.
  local catItem
  for id, byKey in pairs(data.rankings) do
    local e = byKey[meKey]
    if e and e.cat then catItem = id break end
  end
  if catItem then
    local catLines = stub.FireTooltip(catItem)
    local joined = ""
    for _, l in ipairs(catLines) do joined = joined .. tostring(l.text) .. "\n" end
    check("a catalyse target says what it becomes",
          joined:find("Catalyse target", 1, true) ~= nil, joined:gsub("\n", " | "))
    -- The arrow shipped as U+2192 and the game font has no such glyph, so it
    -- drew as a missing-glyph box in the live tooltip.
    --
    -- Scoped to ARROWS rather than to "any non-ASCII", because the separator in
    -- "Overall BIS · Raid BIS" is U+00B7 and renders correctly — confirmed from
    -- the live tooltip, which is the only authority on what the font has. A
    -- blanket non-ASCII ban would fail on the character we can see working.
    local ARROWS = { "\226\134\146", "\226\134\144", "\226\135\146", "\226\128\148" }
    local badArrow
    for _, a in ipairs(ARROWS) do
      if joined:find(a, 1, true) then badArrow = a end
    end
    check("...using arrow characters the game font actually has",
          badArrow == nil, badArrow and ("found a glyph the font lacks: " .. joined) or "")
  end
end)()


-- ── The design layer (Session 245) ──────────────────────────────────────────
--
-- Style.lua is mostly frame construction the harness cannot exercise, but its
-- COLOUR MATHS is pure and is what every surface depends on being right. A hex
-- typo here is invisible in code review and obvious only in game, which is
-- exactly the kind of thing worth pinning down headlessly.

;(function()
  local S = ns.Style
  header("design layer")

  check("Style.lua loaded and is on the namespace", S ~= nil)
  if not S then return end

  -- Round-trip: the tokens must still be the SITE's values. These are the ones
  -- a careless edit would silently drift from app/globals.css.
  local function hexOf(c)
    return ("%02x%02x%02x"):format(
      math.floor(c.r * 255 + 0.5), math.floor(c.g * 255 + 0.5), math.floor(c.b * 255 + 0.5))
  end
  -- ⚠️ THE TEXT TOKENS ARE NOT ON THIS LIST ANY MORE, and their being on it was
  -- the bug rather than the guard. They were pinned to app/globals.css, so this
  -- check actively HELD the panel's body text at the site's #e8e8f0 while the
  -- mock said pure white — a test enforcing the wrong source of truth. Surfaces
  -- and semantic hues still come from the site; TEXT comes from the mock and is
  -- checked separately below.
  local EXPECTED = {
    bg = "0d0d14", bgAlt = "13131f", elevated = "1a1a2e", border = "2a2a45",
    gold = "f3c56b", green = "20ba56", blue = "3382ff", orange = "ff7729",
    grey = "606060", red = "c41e3a", purple = "8031ff", hotPink = "ff0080",
  }
  local drift = {}
  for name, want in pairs(EXPECTED) do
    local got = S.COLOR[name] and hexOf(S.COLOR[name])
    if got ~= want then drift[#drift + 1] = ("%s=%s want %s"):format(name, tostring(got), want) end
  end
  check("every colour token still matches the site's DS 2.0 value",
        #drift == 0, table.concat(drift, ", "))

  -- ── Text, read out of the Figma mock (Session 251) ───────────────────────
  -- Verified against the file directly: the item name, its slot line and the
  -- column headers are all #ffffff, and the footnote is rgba(255,255,255,0.5).
  -- Dim is WHITE AT ALPHA, never a darker hue — a purple grey on a purple panel
  -- is what made the secondary lines read as muddy.
  check("body text is pure white, as the mock draws it",
        hexOf(S.COLOR.text) == "ffffff", hexOf(S.COLOR.text))
  check("dim text is white, not a hue",
        hexOf(S.COLOR.textDim) == "ffffff", hexOf(S.COLOR.textDim))
  check("...dimmed by alpha instead", S.COLOR.textDim.a == 0.5, tostring(S.COLOR.textDim.a))
  check("the third step stays on the same ramp",
        hexOf(S.COLOR.textMuted) == "ffffff" and (S.COLOR.textMuted.a or 1) < 0.5,
        tostring(S.COLOR.textMuted.a))
  -- Not vacuous: if dim ever equals body text the hierarchy is gone entirely.
  check("...and the three steps are actually distinct",
        (S.COLOR.text.a or 1) > S.COLOR.textDim.a
          and S.COLOR.textDim.a > (S.COLOR.textMuted.a or 1))

  check("BIS uses the hot-pink token, not the unreadable gold",
        hexOf(S.COLOR.hotPink) == "ff0080" and S.COLOR.hotPink ~= S.COLOR.gold)

  -- The escape code is what colours chat and tooltip text; an off-by-one in the
  -- rounding shows up as a subtly wrong colour nobody can trace.
  check("colour escape codes round-trip", S.code(S.COLOR.hotPink) == "|cffff0080",
        S.code(S.COLOR.hotPink))
  check("...including a channel that rounds up", S.code(S.COLOR.gold) == "|cfff3c56b",
        S.code(S.COLOR.gold))

  -- ⚠️ THE ESCAPE CODE HAS NO ALPHA, so a half-alpha white must be FLATTENED or
  -- it comes out pure white and the dim is silently lost — which is what would
  -- have happened to the gap column's "tie" and "-16" the moment the ramp moved
  -- to alpha. Composited over the panel ground.
  local dimCode = S.code(S.COLOR.textDim)
  check("a dimmed colour does not come out as pure white in an inline escape",
        dimCode ~= "|cffffffff", dimCode)
  check("...it lands between the ground and white", dimCode:match("^|cff(%x%x)") ~= nil
        and tonumber(dimCode:match("^|cff(%x%x)"), 16) > 0x20
        and tonumber(dimCode:match("^|cff(%x%x)"), 16) < 0xf0, dimCode)
  check("...while a fully opaque colour is untouched by the flattening",
        S.code(S.COLOR.white) == "|cffffffff", S.code(S.COLOR.white))

  local r, g, b = S.rgb(S.COLOR.green)
  check("rgb() unpacks to three channels in 0-1",
        math.abs(r - 0x20 / 255) < 1e-6 and math.abs(g - 0xba / 255) < 1e-6
        and math.abs(b - 0x56 / 255) < 1e-6)
  -- FOUR channels now: the mock dims by alpha, so alpha is part of a colour and
  -- rides through every SetTextColor call that already unpacked rgb().
  check("rgb() with no colour falls back rather than erroring", select("#", S.rgb(nil)) == 4)
  check("...and an alpha-less colour still reports fully opaque",
        select(4, S.rgb(S.COLOR.gold)) == 1, tostring(select(4, S.rgb(S.COLOR.gold))))
  check("...while a dimmed one carries its alpha through",
        select(4, S.rgb(S.COLOR.textDim)) == 0.5,
        tostring(select(4, S.rgb(S.COLOR.textDim))))

  -- Fonts are referenced by PATH, and a path typo is silent — SetFont returns
  -- false and the helper falls back to the game font, so the addon just looks
  -- stock and nothing says why. So this checks the FILES ARE ACTUALLY THERE,
  -- which is the failure the path string alone cannot catch: a correct path to a
  -- font nobody copied looks identical in code.
  local missing = {}
  for _, key in ipairs({ "title", "titleMed", "body", "bodyMed", "label" }) do
    local path = S.FONT[key]
    if type(path) ~= "string" or not path:find("Media", 1, true) or not path:find(".ttf", 1, true) then
      missing[#missing + 1] = key .. " has a bad path: " .. tostring(path)
    else
      -- The addon path is Interface\AddOns\HoDLootAdvisor\...; on disk that
      -- last segment is this working directory.
      local file = path:gsub("^.*HoDLootAdvisor\\", ""):gsub("\\", "/")
      local fh = io.open(file, "rb")
      if fh then fh:close() else missing[#missing + 1] = key .. " missing on disk: " .. file end
    end
  end
  check("every font role resolves to a TTF that exists in Media/fonts",
        #missing == 0, table.concat(missing, ", "))

  -- The OFL requires its licence to travel with the font software, and General
  -- Sans's terms require ITF to be credited. Shipping the fonts without these is
  -- a licensing fault, not a cosmetic one.
  for _, doc in ipairs({ "Media/fonts/OFL.txt", "Media/fonts/FONT-LICENSES.md" }) do
    local fh = io.open(doc, "rb")
    check(("the bundled fonts ship their licence (%s)"):format(doc), fh ~= nil)
    if fh then fh:close() end
  end

  local sizes = 0
  for _ in pairs(S.SIZE) do sizes = sizes + 1 end
  check("the type scale is named roles, not scattered magic numbers", sizes >= 5)

  -- ── Per-boss BIS counts (the dropdown's whole point) ──────────────────────
  --
  -- "Which boss should I care about" is the question the picker exists to
  -- answer, and the count is the answer. It can be silently wrong in two ways
  -- that look identical on screen: counting against the wrong boss id space, or
  -- counting LISTINGS instead of items.

  local totalBis, bossesWithBis = 0, 0
  for id in pairs(data.bosses or {}) do
    local n = ns.BisCountForBoss(id)
    check(("boss %s returns a non-negative count"):format(tostring(id)),
          type(n) == "number" and n >= 0, tostring(n))
    totalBis = totalBis + n
    if n > 0 then bossesWithBis = bossesWithBis + 1 end
  end

  -- Independent recount, deliberately NOT sharing the implementation: walk the
  -- payload directly and compare. A bug reproduced in both halves would pass,
  -- so this counts by a different route — items first, then their boss.
  local expected = 0
  local meClass, meSpec = stub.player.className, stub.player.specName
  for itemID, rec in pairs(data.items or {}) do
    if rec.boss and data.bosses and data.bosses[rec.boss] then
      local q = ns.Scoring.resolveQuality(data.rankings, itemID, meClass, meSpec, nil, nil)
      if q and q.bis then expected = expected + 1 end
    end
  end
  check("the per-boss counts sum to an independent walk of the payload",
        totalBis == expected, ("%d from the picker, %d counted directly"):format(totalBis, expected))

  check("an unknown boss id counts nothing rather than erroring",
        ns.BisCountForBoss(-1) == 0)
  check("a nil boss id is handled", ns.BisCountForBoss(nil) == 0)

  -- ── The same counts, in the shape the three pickers actually read ─────────
  --
  -- Every picker reads the MAP now, because the per-boss form re-walks the whole
  -- payload and three pickers ask a few dozen times a refresh. The two must
  -- agree exactly or two controls disagree about the same boss on one screen.
  local byBoss, mapTotal, agree = ns.BisCountsByBoss(), 0, true
  for id in pairs(data.bosses or {}) do
    if (byBoss[id] or 0) ~= ns.BisCountForBoss(id) then agree = false end
  end
  for id, n in pairs(byBoss) do
    mapTotal = mapTotal + n
    if n == 0 then agree = false end     -- absent, not zero: a zero would print
    if not (data.bosses and data.bosses[id]) then agree = false end
  end
  check("the map form agrees with the per-boss form, boss for boss", agree)
  check("...and totals the same", mapTotal == totalBis,
        ("%d from the map, %d from the per-boss calls"):format(mapTotal, totalBis))

  -- ── Rolled up to instances (the Targets browse picker) ────────────────────
  --
  -- This one CROSSES AN ID BOUNDARY: it takes boss ids out of our payload and
  -- hands them to the Encounter Journal to be placed. If those are ever
  -- different id spaces it does not error — it returns an empty table and every
  -- instance reads as a plain name, which looks exactly like "no BIS here". It
  -- was already wrong once for a smaller version of the same reason (the guard
  -- named a journal function that does not exist), so the check is emphatically
  -- not that it runs.
  local byInst = ns.BisCountsByInstance()

  -- Placement asserted against the FIXTURE, not against the same index the
  -- implementation uses: the stub puts 2849 and 2894 in instance 1317, so that
  -- is what 1317 must hold. Deriving the expectation from InstanceForEncounter
  -- would agree with itself no matter which id space it read.
  local want1317 = (byBoss[2849] or 0) + (byBoss[2894] or 0)
  check("BIS counts land on the instance the journal puts each boss in",
        (byInst[1317] or 0) == want1317,
        ("1317 holds %s, expected %d"):format(tostring(byInst[1317]), want1317))
  check("...and the fixture placed some, so that check is not vacuous",
        want1317 > 0, ("placed %d"):format(want1317))

  -- Most of the payload's bosses are in raids this fixture's journal does not
  -- enumerate. Unplaceable is normal and must be silent, not a nil bucket.
  local instTotal = 0
  for _, n in pairs(byInst) do instTotal = instTotal + n end
  check("bosses the journal cannot place are dropped, not bucketed under nil",
        instTotal <= mapTotal and byInst[nil] == nil,
        ("%d placed of %d"):format(instTotal, mapTotal))

  -- NOTHING TO COUNT MUST COST NOTHING. Walking every instance's encounter list
  -- to ask "does this hold anything" would make the browse picker pay for a full
  -- catalogue walk on every refresh, including for the dungeons and world bosses
  -- the payload does not cover. Inverting it is the whole design, and the only
  -- way to prove the journal went untouched is to take it away.
  --
  -- A journal that answers EVERY name with a function that explodes when CALLED.
  -- Naming one function here instead would only pin the guard the implementation
  -- happens to use today: the first version of this check stubbed
  -- InstanceForEncounter alone, and a rewrite that walked the whole catalogue
  -- through CachedInstances sailed straight past it. Capability checks are still
  -- free, since reading a name is not calling it.
  local savedData, savedJournal = ns.Data, ns.Journal
  ns.Data = function() return nil end
  ns.Journal = setmetatable({}, { __index = function(_, name)
    return function() error("touched the journal (" .. tostring(name) .. ") with nothing to place") end
  end })
  local okEmpty, emptyRes = pcall(ns.BisCountsByInstance)
  ns.Data, ns.Journal = savedData, savedJournal
  check("with nothing to place, the roll-up never touches the journal", okEmpty,
        not okEmpty and tostring(emptyRes) or nil)
  check("...and returns an empty table rather than nil",
        okEmpty and type(emptyRes) == "table" and next(emptyRes) == nil)
end)()

-- ── The item column's ordering ladder (Session 250) ─────────────────────────
--
-- ONE LADDER FOR EVERY MODE (Jason, Session 249):
--   Targeted -> BIS (Overall -> Raid -> M+) -> Major -> Moderate -> Minor
--   -> Sidegrade -> Not an upgrade -> Not for you
--
-- This is the ONLY place it is tested, because the surface that uses it is
-- Panel.lua and no harness loads that. The logic was put in Core.lua precisely
-- so this file could reach it.

header("Item ordering — the ladder the Loot tab's column sorts on")

;(function()
  local B = ns.ITEM_BAND
  check("the ladder's bands are exported", type(B) == "table")

  -- Each rung, on its own, in the order the rule states.
  local function band(e) return ns.ItemBand(e) end

  check("a target sits on the top rung",
        band({ targeted = true, badge = "sidegrade" }) == B.targeted)
  check("overall BIS outranks raid BIS",
        band({ quality = { bis = "overall" } }) < band({ quality = { bis = "raid" } }))
  check("raid BIS outranks M+ BIS",
        band({ quality = { bis = "raid" } }) < band({ quality = { bis = "mplus" } }))
  check("BIS outranks a Major upgrade",
        band({ quality = { bis = "mplus" } }) < band({ badge = "major", isUpgrade = true }))
  check("Major outranks Moderate",
        band({ badge = "major", isUpgrade = true })
        < band({ badge = "moderate", isUpgrade = true }))
  check("Moderate outranks Minor",
        band({ badge = "moderate", isUpgrade = true })
        < band({ badge = "minor", isUpgrade = true }))
  check("Minor outranks Sidegrade",
        band({ badge = "minor", isUpgrade = true })
        < band({ badge = "sidegrade", isUpgrade = true }))
  check("Sidegrade outranks 'not an upgrade'",
        band({ badge = "sidegrade", isUpgrade = true })
        < band({ badge = "major", isUpgrade = false }))
  check("'not an upgrade' outranks 'not for you'",
        band({ badge = "major", isUpgrade = false }) < band({ ineligible = true }))

  -- ⚠️ THE RULE JASON STATED FLATLY, and the one a reasonable implementation
  -- gets wrong: a target pins to the top EVEN WHEN THE VIEWER CANNOT USE THE
  -- ITEM. A Resto Druid may legitimately be chasing Feral gear. An
  -- implementation that checked eligibility first would put this last.
  check("a target pins above everything even when it is NOT usable",
        band({ targeted = true, ineligible = true }) == B.targeted)
  check("...and specifically above an overall-BIS item that is usable",
        band({ targeted = true, ineligible = true })
        < band({ quality = { bis = "overall" } }))

  -- An item we could not score is not the same as one that scored badly, but it
  -- is not an upgrade we can vouch for either.
  check("an unscored item lands with the non-upgrades, not with the badges",
        band({ reason = "not in this season's loot table" }) == B.notAnUpgrade)
  check("a nil entry is handled rather than erroring", band(nil) == B.notForYou)

  -- ── The sort itself ───────────────────────────────────────────────────────
  local list = {
    { name = "Zeta sidegrade", badge = "sidegrade", isUpgrade = true, gain = 1 },
    { name = "Alpha major",    badge = "major",     isUpgrade = true, gain = 10 },
    { name = "Beta major",     badge = "major",     isUpgrade = true, gain = 30 },
    { name = "Unusable target", targeted = true, ineligible = true },
    { name = "Best in slot",   quality = { bis = "overall" } },
    { name = "Cannot equip",   ineligible = true },
  }
  ns.OrderItems(list)
  local order = {}
  for i, e in ipairs(list) do order[i] = e.name end
  check("the whole list sorts into the ladder",
        table.concat(order, " | ") ==
        "Unusable target | Best in slot | Beta major | Alpha major | Zeta sidegrade | Cannot equip",
        table.concat(order, " | "))

  -- TIES BREAK BY UPGRADE SIZE, THEN NAME — so the column is stable between
  -- refreshes. A selector whose rows move under the pointer gets misclicked
  -- during the only sixty seconds anyone is looking at it.
  check("within a band the bigger upgrade sorts first",
        list[3].name == "Beta major" and list[4].name == "Alpha major")

  local tied = {
    { name = "Bravo", badge = "major", isUpgrade = true, gain = 5 },
    { name = "Alpha", badge = "major", isUpgrade = true, gain = 5 },
  }
  ns.OrderItems(tied)
  check("an exact tie in upgrade size falls back to the name",
        tied[1].name == "Alpha" and tied[2].name == "Bravo")

  check("sorting an empty list is not an error", #ns.OrderItems({}) == 0)
  check("a non-table is returned untouched rather than erroring",
        ns.OrderItems(nil) == nil)
end)()

header("The column's second line, the standing ordinal, and the header counts")

;(function()
  -- Armour reads slot then armour type; a weapon reads its type alone, because
  -- "Main Hand, 1H Axe" says the same thing twice in a 198px row.
  check("armour reads slot then armour type",
        ns.ItemSlotLine({ slotText = "Chest", armorType = "Plate" }) == "Chest, Plate",
        ns.ItemSlotLine({ slotText = "Chest", armorType = "Plate" }))
  check("a weapon reads its type alone",
        ns.ItemSlotLine({ slotText = "Two-Hand", armorType = "Polearm" }) == "Polearm",
        ns.ItemSlotLine({ slotText = "Two-Hand", armorType = "Polearm" }))
  check("an unknown subtype falls through to the weapon shape, never to blank",
        ns.ItemSlotLine({ slotText = "Main Hand", armorType = "Warglaive" }) == "Warglaive")
  check("with no armour type the slot stands alone",
        ns.ItemSlotLine({ slotText = "Trinket" }) == "Trinket")
  check("with nothing at all it is empty rather than nil",
        ns.ItemSlotLine({}) == "")
  check("a nil entry is handled", ns.ItemSlotLine(nil) == "")

  -- ⚠️ 11, 12 AND 13 TAKE "th" DESPITE ENDING IN 1, 2 AND 3. A raid of 20+
  -- reaches every one of them, so this is not a corner.
  local function ord(n) local a, b = ns.Ordinal(n) return (a or "?") .. (b or "") end
  check("1st / 2nd / 3rd",
        ord(1) == "1st" and ord(2) == "2nd" and ord(3) == "3rd",
        ord(1) .. " " .. ord(2) .. " " .. ord(3))
  check("4th and 11th, 12th, 13th are all 'th'",
        ord(4) == "4th" and ord(11) == "11th" and ord(12) == "12th" and ord(13) == "13th",
        ord(11) .. " " .. ord(12) .. " " .. ord(13))
  check("21st, 22nd, 23rd pick their suffix up again",
        ord(21) == "21st" and ord(22) == "22nd" and ord(23) == "23rd",
        ord(21) .. " " .. ord(22) .. " " .. ord(23))
  check("111th, 112th, 113th stay 'th' two hundreds up",
        ord(111) == "111th" and ord(112) == "112th" and ord(113) == "113th")
  check("a non-number answers nil rather than erroring", ns.Ordinal(nil) == nil)

  -- THE HEADER COUNTS THE LIST IT IS ABOUT TO DRAW, so it cannot claim a BIS the
  -- column below does not show.
  local bis, targets = ns.CountsForItems({
    { quality = { bis = "overall" } },
    { quality = { bis = "raid" }, targeted = true },
    { quality = { grade = "a" } },
    { targeted = true },
    {},
  })
  check("BIS entries are counted whatever kind of BIS they are", bis == 2, bis)
  check("targets are counted independently of BIS", targets == 2, targets)
  local zb, zt = ns.CountsForItems({})
  check("an empty list counts zero and zero", zb == 0 and zt == 0)
  local nb, nt = ns.CountsForItems(nil)
  check("a nil list is handled", nb == 0 and nt == 0)
end)()

header("Current Drops and the winner lookup (what the Loot tab reads)")

;(function()
  -- WHY THE PANEL READS THE RECORDER AND NOT Loot.recent: the in-memory roll
  -- list is wiped by a /reload and never learns a WINNER, because the roll event
  -- fires when the window OPENS and who won arrives minutes later on a rescan.
  --
  -- ⚠️ "CURRENT" IS A RUN, NOT A CALENDAR DAY (Session 256). It used to be every
  -- run dated today, which answered a question nobody asked — a lunchtime LFR sat
  -- under the same boss portrait as the guild night — and which changed its
  -- answer to "none of them" at midnight, mid-raid. These fixtures therefore
  -- carry TIMESTAMPS rather than only dates; the date no longer decides anything.
  local db = _G.HoDLootAdvisorDB
  local saved = db.loot
  local savedInstance = stub.instance
  local now = time()
  local HOURS = 3600

  -- Out of an instance is the post-raid case: the run you just left is still the
  -- one being asked about, because the winner of a late roll lands after you have
  -- gone. stub.instance is restored at the end of the block.
  -- ⚠️ instanceType MATTERS AND THE STUB DEFAULTS IT TO "raid". Without it set,
  -- a fixture named Orgrimmar is still reported as a raid instance and the
  -- out-of-instance path never runs.
  stub.instance = { name = "Orgrimmar", difficultyID = 0, difficultyName = "",
                    instanceID = 1, instanceType = "none" }

  db.loot = { sessions = {
    { date = "1999-01-01", timestamp = now - (10 * 24 * HOURS),
      items = { { itemID = 111, itemName = "Ancient", winner = "Nobody",
                  timestamp = now - (10 * 24 * HOURS) } } },
    { date = "2026-08-28", timestamp = now - (30 * HOURS),
      items = { { itemID = 555, itemName = "Last night", timestamp = now - (30 * HOURS) } } },
    { date = "2026-08-29", timestamp = now - (2 * HOURS),
      items = {
        { itemID = 222, itemName = "First drop",  winner = "Vörnix", timestamp = now - (2 * HOURS) },
        { itemID = 333, itemName = "Second drop", timestamp = now - (90 * 60) },
        { itemID = 444, itemName = "Third drop",  winner = "Dåmir",  timestamp = now - (60 * 60) },
    } },
  } }

  local drops = ns.Record.RecentDrops()
  check("the current run is read, and only it", #drops == 3, #drops)
  check("newest first", drops[1].itemID == 444, drops[1] and drops[1].itemID)
  check("a run from another day is not included", (function()
    for _, e in ipairs(drops) do if e.itemID == 111 then return false end end
    return true
  end)())
  check("...nor last night's, which is inside no window", (function()
    for _, e in ipairs(drops) do if e.itemID == 555 then return false end end
    return true
  end)())
  check("the cap is honoured", #ns.Record.RecentDrops(2) == 2)

  -- ⚠️ THE MIDNIGHT REGRESSION, and the reason any of this changed. A run STAMPED
  -- with yesterday but written into ten minutes ago is the current run: a raid
  -- that started at 21:00 and is still going at 00:30 has not become a different
  -- raid. Before this the tab emptied itself mid-pull and the night split into
  -- two runs, which then exported with two different dates — and the site files a
  -- night against the raid session on the date it carries, so the second half had
  -- nowhere to land.
  db.loot = { sessions = {
    { date = "2026-08-28", timestamp = now - (4 * HOURS),
      items = {
        { itemID = 777, itemName = "Before midnight", timestamp = now - (3 * HOURS) },
        { itemID = 888, itemName = "After midnight",  timestamp = now - (10 * 60) },
    } },
  } }
  local across = ns.Record.RecentDrops()
  check("a run that crossed midnight is still the current run", #across == 2, #across)
  check("...and the drop from before the rollover is still in it", (function()
    for _, e in ipairs(across) do if e.itemID == 777 then return true end end
    return false
  end)())

  -- The other side of the same rule: a run nobody has touched for a day is over,
  -- whatever its date says. This is what stops Tuesday and Thursday merging.
  db.loot = { sessions = {
    { date = "2026-08-29", timestamp = now - (26 * HOURS),
      items = { { itemID = 999, itemName = "Yesterday", timestamp = now - (26 * HOURS) } } },
  } }
  check("a run that went cold is not current, whatever its date",
        #ns.Record.RecentDrops() == 0, #ns.Record.RecentDrops())

  -- ⚠️ THE BOSS FILTER. Without it the Loot tab showed every drop of the night
  -- under whichever boss portrait was selected, so clicking the strip changed
  -- nothing and the panel looked stuck on the last kill.
  db.loot = { sessions = { { date = "2026-08-29", timestamp = now - HOURS, items = {
    { itemID = 11, itemName = "From boss A", encounterID = 2888, timestamp = now - HOURS },
    { itemID = 22, itemName = "From boss B", encounterID = 2894, timestamp = now - 1800 },
    { itemID = 33, itemName = "Also boss A", encounterID = 2888, winner = "Vörnix",
      timestamp = now - 600 },
  } } } }
  check("no boss id returns everything", #ns.Record.RecentDrops() == 3)
  check("a boss id returns only that boss's drops",
        #ns.Record.RecentDrops(nil, 2888) == 2, #ns.Record.RecentDrops(nil, 2888))
  check("...and the other boss's, separately",
        #ns.Record.RecentDrops(nil, 2894) == 1)
  -- A boss nobody killed tonight must come back EMPTY: showing another boss's
  -- loot under its portrait is worse than showing none.
  check("a boss with no kill tonight returns nothing",
        #ns.Record.RecentDrops(nil, 2871) == 0, #ns.Record.RecentDrops(nil, 2871))

  db.loot = { sessions = {
    { date = "1999-01-01", timestamp = now - (10 * 24 * HOURS),
      items = { { itemID = 111, itemName = "Ancient", winner = "Nobody",
                  timestamp = now - (10 * 24 * HOURS) } } },
    { date = "2026-08-29", timestamp = now - (2 * HOURS),
      items = {
        { itemID = 222, itemName = "First drop",  winner = "Vörnix", timestamp = now - (2 * HOURS) },
        { itemID = 333, itemName = "Second drop", timestamp = now - (90 * 60) },
        { itemID = 444, itemName = "Third drop",  winner = "Dåmir",  timestamp = now - 600 },
    } },
  } }

  check("a settled item reports its winner", ns.Record.WinnerFor(444) == "Dåmir",
        tostring(ns.Record.WinnerFor(444)))
  -- ⚠️ SCOPED TO THE CURRENT RUN, and this NARROWED in Session 256 — it used to
  -- search every run dated today. On a raid night nothing is lost, because the
  -- night is one run; what it stops is a winner from a different instance
  -- entirely being reported under tonight's item.
  check("...anywhere within that run", ns.Record.WinnerFor(222) == "Vörnix")

  -- ⚠️ nil IS A REAL ANSWER AND MUST NOT BE DRESSED UP. Nothing in the addon
  -- registers that a roll ENDED — only that one started — so "still open" and
  -- "we never found out" are indistinguishable from here. The panel shows the
  -- absence rather than a countdown or a "pending" it cannot stand behind.
  check("an unsettled item answers nil, not a placeholder",
        ns.Record.WinnerFor(333) == nil, tostring(ns.Record.WinnerFor(333)))
  check("yesterday's winner does not leak into today",
        ns.Record.WinnerFor(111) == nil, tostring(ns.Record.WinnerFor(111)))
  check("an unknown item answers nil", ns.Record.WinnerFor(999999) == nil)
  check("a nil item id is handled", ns.Record.WinnerFor(nil) == nil)

  db.loot = saved
  stub.instance = savedInstance
end)()

header("A raid that runs past midnight is still one run")

;(function()
  -- THE WRITER'S HALF of the same rule, and the half that reaches the SITE. A
  -- run used to be stamped with the day it started and only continued while that
  -- was still "today", so the moment the clock rolled over the recorder stopped
  -- recognising the raid it was already recording and opened a second run.
  --
  -- ⚠️ THAT IS AN IMPORT BUG, NOT A COSMETIC ONE. Each run exports with its own
  -- date and the site files a night against the raid session carrying that date,
  -- so the post-midnight half arrived stamped with the NEXT day and had no
  -- session to land on. The site reports such a night rather than filing it
  -- somewhere wrong, so it would surface as loot that simply did not import.
  local db = _G.HoDLootAdvisorDB
  local saved, savedInstance, savedEpoch = db.loot, stub.instance, stub.epoch
  db.loot = { sessions = {} }
  stub.instance = { name = "The Venomous Abyss", difficultyID = 15,
                    difficultyName = "Heroic (Raid)", instanceID = 2917 }

  -- Ten minutes either side of a UTC midnight. Derived rather than written down,
  -- so the fixture cannot drift away from the harness clock.
  local dayStart = stub.epoch - (stub.epoch % 86400)
  local before, after = dayStart + 86400 - 600, dayStart + 86400 + 600

  -- ⚠️ A DIFFERENT ENCOUNTER PER KILL, and the first version of this test got it
  -- wrong. A kill is BOUND to its run the first time it is seen and every later
  -- scan writes back into that same record, so re-firing one encounter id is a
  -- rescan of one kill — not a second kill — and the run never has to be looked
  -- up again. Reusing the id tested nothing and reported it as a failure.
  local function killWith(itemID, name, at, encounterID)
    stub.epoch = at
    stub.items[itemID] = { name = name, quality = 4, ilvl = 305, itemType = "Armor" }
    stub.lootHistory[encounterID] = { stub.drop(1, itemID, name, { 12841 }, {
      { name = "Vörnix", state = 0, roll = 87, isWinner = true } }) }
    stub.Fire("ENCOUNTER_END", encounterID, "A Boss", 15, 20, 1)
    stub.RunTimers(300)
  end

  killWith(270701, "Before Midnight", before, 2849)
  check("the raid opens one run", #db.loot.sessions == 1, #db.loot.sessions)
  local startedOn = db.loot.sessions[1].date
  -- ⚠️ ASSERT THE SHAPE, NOT JUST THAT IT MATCHES ITSELF. The first version of
  -- this block only ever compared this value to itself, so when the change
  -- accidentally wrote an EMPTY date into every run, every check here still
  -- passed — nil equals nil. The tracked export fixture caught it instead.
  -- A date is what the SITE matches a night against; it has to be a real one.
  check("...stamped with a real calendar date",
        type(startedOn) == "string" and startedOn:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil,
        tostring(startedOn))

  killWith(270702, "After Midnight", after, 2850)
  check("the date really did roll over", date("%Y-%m-%d") ~= startedOn,
        ("%s -> %s"):format(tostring(startedOn), date("%Y-%m-%d")))
  check("the kill after midnight joins the SAME run",
        #db.loot.sessions == 1, #db.loot.sessions)
  check("...and the run keeps the date the raid STARTED on, which is the one the "
        .. "site matches against", db.loot.sessions[1].date == startedOn,
        tostring(db.loot.sessions[1].date))
  check("...with both kills in it", #db.loot.sessions[1].items == 2,
        #db.loot.sessions[1].items)

  -- The other direction: come back to the same raid a day later and it is a new
  -- night, because nothing has been written into the old run for far too long.
  killWith(270703, "Tomorrow Night", after + (24 * 3600), 2851)
  check("a visit a day later is a new run", #db.loot.sessions == 2, #db.loot.sessions)

  db.loot, stub.instance, stub.epoch = saved, savedInstance, savedEpoch
end)()

header("The badge ramp — one table, three surfaces")

;(function()
  -- The item column, the detail header and the ranked rows all read Style.BADGE.
  -- Three copies of this is how the strip and the ranking list came to disagree
  -- about Moderate before.
  local S = ns.Style
  check("the ramp is on the namespace", type(S.BADGE) == "table")
  for _, key in ipairs({ "major", "moderate", "minor", "sidegrade" }) do
    local label, color = S.Badge(key)
    check(("%s has a label and a colour"):format(key),
          type(label) == "string" and label ~= "" and type(color) == "table"
          and color.r ~= nil, tostring(label))
  end
  -- ⚠️ TWO VALUES, ALWAYS. `local a, b = S and S.Badge(k)` adjusts the `and` to
  -- ONE value and silently drops the colour — which it did, at three call sites,
  -- before this check existed.
  local label, color = S.Badge("major")
  check("Major's colour is the design's red, not the old green",
        color and math.floor(color.r * 255 + 0.5) == 255
             and math.floor(color.g * 255 + 0.5) == 89,
        color and ("%d,%d,%d"):format(color.r * 255, color.g * 255, color.b * 255))
  check("an unknown badge falls back to a drawable label rather than nothing",
        (S.Badge("wat")) == "Sidegrade")
  check("a nil badge does the same", (S.Badge(nil)) == "Sidegrade")

  -- BIS AND THE TARGET MARK MUST NOT SHARE A HUE (Session 249). Both were the
  -- brand gold, which is exactly the collision the rule forbids.
  local bisTag, bisColor = ns.QualityTag({ bis = "overall" })
  check("the overall listing tags with its own label",
        bisTag == ns.BIS_SHORT.overall and bisTag ~= nil, tostring(bisTag))
  -- The three listings must stay distinguishable from one another; that is the
  -- property the labels exist for, and it survives any renaming of them.
  check("the three BIS listings are three distinct labels",
        ns.BIS_SHORT.overall ~= ns.BIS_SHORT.raid
        and ns.BIS_SHORT.raid ~= ns.BIS_SHORT.mplus
        and ns.BIS_SHORT.overall ~= ns.BIS_SHORT.mplus)
  check("BIS and the target marker are different colours",
        bisColor and ns.TARGET_COLOR
        and not (bisColor[1] == ns.TARGET_COLOR[1]
                 and bisColor[2] == ns.TARGET_COLOR[2]
                 and bisColor[3] == ns.TARGET_COLOR[3]))
end)()

-- ── The Standings tab (Session 250) ─────────────────────────────────────────

header("Standings — number formatting, ages, and the ladder/roster join")

;(function()
  check("thousands are separated", ns.Commify(1240) == "1,240", ns.Commify(1240))
  check("...and so are millions", ns.Commify(1234567) == "1,234,567", ns.Commify(1234567))
  check("three digits are left alone", ns.Commify(199) == "199")
  check("exactly four digits gain one separator", ns.Commify(1000) == "1,000")
  check("a fractional GP is floored, not rounded up",
        ns.Commify(37.339) == "37", ns.Commify(37.339))
  check("negatives keep their sign", ns.Commify(-1240) == "-1,240", ns.Commify(-1240))
  check("zero is zero, never blank", ns.Commify(0) == "0")

  -- The LAST ITEM column's compact age.
  check("under a week reads in days", ns.ShortAge(2) == "2 days", ns.ShortAge(2))
  check("one day is singular", ns.ShortAge(1) == "1 day")
  check("seven days is one week, singular", ns.ShortAge(7) == "1 wk", ns.ShortAge(7))
  check("six weeks", ns.ShortAge(45) == "6 wks", ns.ShortAge(45))
  check("today reads as zero days rather than blank", ns.ShortAge(0) == "0 days")
  -- ⚠️ nil MEANS NEVER RECEIVED AN ITEM, which is genuinely absent data and gets
  -- the em-dash — NOT a zero, which would claim they got something today.
  check("unknown answers nil so the column can draw an em-dash", ns.ShortAge(nil) == nil)

  check("the long form says today", ns.LongAge(0) == "today")
  check("...yesterday", ns.LongAge(1) == "yesterday")
  check("...days inside a fortnight", ns.LongAge(5) == "5 days ago")
  check("...weeks beyond it", ns.LongAge(21) == "3 weeks ago", ns.LongAge(21))
  check("...months beyond two", ns.LongAge(103) == "3 months ago", ns.LongAge(103))
  check("unknown answers nil", ns.LongAge(nil) == nil)

  -- ── The ladder/roster join ────────────────────────────────────────────────
  local savedCurrent, savedByName = ns.Payload.Current, ns.Payload.byName
  ns.Payload.Current = function()
    return { ladder = {
      { n = "Vörnix",  ep = 1240, gp = 247, pr = 5.02, rank = 1 },
      { n = "Dåmir",   ep = 1190, gp = 289, pr = 4.12, rank = 2 },
      { n = "Ghostly", ep = 900,  gp = 250, pr = 3.60, rank = 3 },
    } }
  end
  ns.Payload.byName = {
    ["vörnix"] = { n = "Vörnix", c = "Warlock", lastItemDays = 42 },
    ["dåmir"]  = { n = "Dåmir",  c = "Demon Hunter" },
    -- Ghostly is on the ladder and NOT on the roster.
  }

  local rows, total = ns.StandingsRows()
  check("every ladder entry becomes a row", #rows == 3, #rows)
  check("the total is the ladder's length, for the rail's 'of N'", total == 3, total)
  check("the rank comes from the ladder, not from the row's position",
        rows[1].rank == 1 and rows[2].rank == 2)
  check("EP, GP and priority ride through", rows[1].ep == 1240 and rows[1].gp == 247
        and rows[1].pr == 5.02)
  check("class is joined from the roster, for the name colour",
        rows[1].class == "Warlock" and rows[2].class == "Demon Hunter",
        tostring(rows[1].class))
  check("last-item age is joined too", rows[1].lastItemDays == 42)
  check("a roster row with no last item leaves it absent, not zero",
        rows[2].lastItemDays == nil)

  -- ⚠️ A LADDER NAME WITH NO ROSTER ROW IS STILL SHOWN. Dropping it would be the
  -- silent omission this project keeps writing rules about, and it is exactly
  -- what a main swap or a late roster edit produces.
  check("a ladder entry missing from the roster is NOT dropped",
        rows[3] ~= nil and rows[3].name == "Ghostly", rows[3] and rows[3].name)
  check("...it just has no class to colour by", rows[3].class == nil)
  check("...and its standing still shows", rows[3].pr == 3.60)

  -- ── The ladder carries its own class (Session 253) ────────────────────────
  --
  -- ⚠️ THE JOIN ABOVE IS NO LONGER THE ONLY SOURCE, because it silently failed
  -- for a fifth of the raid team. The ladder was named after the PERSON (their
  -- display name) while the roster is keyed by CHARACTER, so Abirn, Death,
  -- Gloom, Televoker and Zugbee matched nothing: white names and an em-dash
  -- where their Last Item should be, which reads as "won nothing" rather than
  -- as a broken lookup. The site now names the ladder after the raid-roster
  -- character AND ships the class, so neither has to be inferred.
  ns.Payload.Current = function()
    return { ladder = {
      -- Not on the roster at all, and still colourable from its own field.
      { n = "Offroster", c = "Priest",  ep = 800, gp = 100, pr = 8.00, rank = 1 },
      -- Present on the roster; the empty string must NOT beat the join.
      { n = "Vörnix",    c = "",        ep = 700, gp = 100, pr = 7.00, rank = 2 },
    } }
  end
  local carried = ns.StandingsRows()
  check("a ladder rung colours itself from its OWN class, with no roster row to join",
        carried[1].class == "Priest", tostring(carried[1].class))
  check("...and an empty class still falls back to the roster join",
        carried[2].class == "Warlock", tostring(carried[2].class))

  ns.Payload.Current = function() return nil end
  local none, zero = ns.StandingsRows()
  check("with nothing imported it is empty rather than an error",
        type(none) == "table" and #none == 0 and zero == 0)

  ns.Payload.Current, ns.Payload.byName = savedCurrent, savedByName
end)()

header("Which list the Loot tab opens on")

;(function()
  -- IN A RAID, WHAT DROPPED IS THE QUESTION; anywhere else, what CAN drop.
  local saved = ns.CurrentContentScope
  ns.CurrentContentScope = function() return "raid" end
  check("inside a raid it opens on Current Drops",
        ns.DefaultLootSource() == "drops", ns.DefaultLootSource())
  ns.CurrentContentScope = function() return "mplus" end
  check("a keystone dungeon opens on the Full Loot Table — group loot is not a thing there",
        ns.DefaultLootSource() == "table", ns.DefaultLootSource())
  ns.CurrentContentScope = function() return nil end
  check("out in the world it opens on the Full Loot Table",
        ns.DefaultLootSource() == "table", ns.DefaultLootSource())
  ns.CurrentContentScope = saved
end)()

-- ── Auto-open survives a failure further down the roll handler ──────────────
--
-- ⚠️ THE PANEL USED TO OPEN LAST, behind scoring, chat reporting, the ranking,
-- the recorder and a comms broadcast — with the whole handler inside a pcall, so
-- a throw anywhere in that chain silently took the panel with it. The symptom is
-- a window that opens on some kills and not others for reasons unrelated to the
-- kill, which is exactly what a raid reported and what no amount of reasoning
-- about difficulty was going to explain.

header("Dungeons as a content mode — tiles, pooled loot, and scoring")

;(function()
  stub.journal.warm = true
  ns.Journal.Invalidate()

  -- The control selects CONTENT, not just difficulty. Everything below runs in
  -- dungeon mode; the setting is restored at the end so later sections are not
  -- silently changed by this one.
  local prevMode = ns.Settings.Get("difficulty")
  ns.Settings.Set("difficulty", "MPLUS")
  check("selecting Dungeons switches the content mode", ns.ContentMode() == "mplus",
        ns.ContentMode())

  -- ── Tiles are DUNGEONS ────────────────────────────────────────────────────
  local dungeons = ns.DungeonList()
  local raidCount, dungeonCount, emptyCount = 0, 0, 0
  for _, inst in ipairs(stub.journal.instances) do
    if not ns.Journal.WORLD_BOSS_INSTANCES[inst.id] then
      if inst.isRaid then
        raidCount = raidCount + 1
      elseif stub.journal.noLoot[inst.id] then
        -- The season list carries a CONTAINER that holds no loot ("Keystone
        -- Dungeons"). A tile for it opens onto an empty list and reads as a bug.
        emptyCount = emptyCount + 1
      else
        dungeonCount = dungeonCount + 1
      end
    end
  end
  check("the strip's tiles are the season's dungeons", #dungeons == dungeonCount,
        ("%d tiles, fixture has %d dungeons"):format(#dungeons, dungeonCount))
  check("...and the fixture has raids too, so this is a real filter",
        raidCount > 0, "otherwise the tile list could be everything and still pass")
  check("a dungeon that lists no loot gets no tile", emptyCount > 0,
        "the fixture must contain one or the exclusion is untested")
  local sawEmpty = false
  for _, d in ipairs(dungeons) do
    if stub.journal.noLoot[d.id] then sawEmpty = true end
  end
  check("...and it really is absent from the strip", not sawEmpty)

  local anyRaid = false
  for _, d in ipairs(dungeons) do
    for _, inst in ipairs(stub.journal.instances) do
      if inst.id == d.id and inst.isRaid then anyRaid = true end
    end
  end
  check("...and no raid leaks into the dungeon tiles", not anyRaid)

  -- ⚠️ NOT BOSSES. In a Mythic+ run there is one chest at the end, so listing
  -- individual bosses would show a choice the game never offers (Jason).
  local multiBoss
  for _, d in ipairs(dungeons) do
    if #ns.Journal.CachedEncounters(d.id) > 1 then multiBoss = d end
  end
  check("the fixture has a dungeon with more than one boss", multiBoss ~= nil,
        "needed for the pooling check below to mean anything")

  -- ── Loot is POOLED across the dungeon, deduplicated ───────────────────────
  local pooled = ns.DungeonLoot(multiBoss.id)
  local perBoss, sharedID = 0, nil
  local seenAcross = {}
  for _, enc in ipairs(ns.Journal.CachedEncounters(multiBoss.id)) do
    for _, j in ipairs(ns.Journal.CachedLoot(enc.id) or {}) do
      perBoss = perBoss + 1
      if seenAcross[j.itemID] then sharedID = j.itemID end
      seenAcross[j.itemID] = true
    end
  end
  check("an item two bosses share appears ONCE in the dungeon's list",
        sharedID ~= nil and perBoss > #pooled,
        ("%d entries across bosses, %d pooled, shared id %s")
          :format(perBoss, #pooled, tostring(sharedID)))
  local occurrences = 0
  for _, e in ipairs(pooled) do if e.itemID == sharedID then occurrences = occurrences + 1 end end
  check("...exactly once", occurrences == 1, occurrences)

  -- ── The Adventure Guide's slot wording maps to ours ───────────────────────
  -- These are the GAME'S spellings. A string transform would turn "Two-Hand"
  -- into "TWOHAND" and every two-hander would score and price as unknown.
  local function slotOf(id)
    for _, e in ipairs(pooled) do if e.itemID == id then return ns.JournalSlot(e) end end
  end
  check("\"Two-Hand\" maps to the payload's slot name", slotOf(880002) == "TWO_HAND", tostring(slotOf(880002)))
  check("\"Held In Off-hand\" maps to OFF_HAND", slotOf(880004) == "OFF_HAND", tostring(slotOf(880004)))
  check("\"Head\" maps to HEAD", slotOf(880001) == "HEAD", tostring(slotOf(880001)))
  check("\"Finger\" maps to FINGER", slotOf(880003) == "FINGER", tostring(slotOf(880003)))
  -- ⚠️ nil IS THE HONEST ANSWER for an item the guide does not place. Guessing
  -- would give it a real badge and a price against the wrong slot weight.
  check("an item with no slot resolves to nothing, not a guess", slotOf(880005) == nil,
        tostring(slotOf(880005)))

  -- ── Scoring an item that is NOT in our loot table ─────────────────────────
  local twoHand
  for _, e in ipairs(pooled) do if e.itemID == 880002 then twoHand = e end end
  check("the dungeon item is genuinely absent from our loot table",
        (ns.Data().items or {})[880002] == nil,
        "if this ever fails the test below proves nothing")

  local bare = ns.Loot.ScoreItem(880002)
  check("...so scoring it with no record is refused, with a reason",
        bare.result == nil and bare.reason ~= nil, tostring(bare.reason))

  local rec = ns.JournalRecord(twoHand)
  check("a record can be synthesised from the guide entry", rec ~= nil)
  check("...pinned at the Mythic+ drop level, not a raid difficulty",
        rec.ilvl.n == ns.MPLUS_ILVL and rec.ilvl.h == ns.MPLUS_ILVL
          and rec.ilvl.m == ns.MPLUS_ILVL, ns.MPLUS_ILVL)

  -- ⚠️ SCORED WITH THE CATALOGUE LINK, exactly as the panel does. The earlier
  -- version of this passed no link and therefore proved nothing: in game the
  -- Adventure Guide hands every entry a link describing the item at its BASE
  -- level, that link won over the record's declared level, and dungeon items
  -- showed ilvl 292 / Veteran while these tests were green.
  check("the fixture's catalogue link really does report a different level",
        ns.DetailedIlvl(twoHand.link) ~= ns.MPLUS_ILVL
          and ns.DetailedIlvl(twoHand.link) ~= nil,
        tostring(ns.DetailedIlvl(twoHand.link)))

  local scored = ns.Loot.ScoreItem(880002, { record = rec, itemLink = twoHand.link })
  check("a dungeon item scores once described", scored.result ~= nil, tostring(scored.reason))
  check("...at the fixed Mythic+ item level, NOT the catalogue link's",
        scored.candidateIlvl == ns.MPLUS_ILVL,
        ("got %s, want %s"):format(tostring(scored.candidateIlvl), tostring(ns.MPLUS_ILVL)))
  -- 311 is Hero 3/6 and nothing else on the ladder, so the track resolves with
  -- no bonus IDs at all — which is the point: a raid bonus block would state a
  -- provenance a dungeon drop does not have.
  check("...on the Hero track, resolved from the ladder alone",
        scored.candidateTrack == ns.MPLUS_TRACK, tostring(scored.candidateTrack))

  -- ⚠️ THE SELECTED RAID DIFFICULTY MUST NOT MOVE A DUNGEON ITEM. Its drop level
  -- is fixed; a +20 drops what a +10 drops.
  local asNormal = ns.Loot.ScoreItem(880002, { record = rec, difficulty = "n", itemLink = twoHand.link })
  local asMythic = ns.Loot.ScoreItem(880002, { record = rec, difficulty = "m", itemLink = twoHand.link })
  check("raid difficulty does not change a dungeon item's level or track",
        asNormal.candidateIlvl == asMythic.candidateIlvl
          and asNormal.candidateTrack == asMythic.candidateTrack,
        ("%s/%s vs %s/%s"):format(tostring(asNormal.candidateIlvl), tostring(asNormal.candidateTrack),
                                  tostring(asMythic.candidateIlvl), tostring(asMythic.candidateTrack)))

  -- ⚠️ AND AT AN OVERLAPPING ITEM LEVEL, WHICH IS THE ONLY PLACE IT BITES.
  -- The check above passes even with the guard removed, because 311 is Hero 3/6
  -- and NOTHING ELSE on the current ladder — no tie, so a bonus ID cannot move
  -- it. Several rungs DO overlap (318 is both Hero 5/6 and Myth 1/6), and there
  -- the bonus ID is exactly what breaks the tie. Season tuning moves this number
  -- every rollover, so the guard has to be tested at a value where it matters
  -- rather than at the one that happens to be safe today.
  local realIlvl = ns.MPLUS_ILVL
  local OVERLAP = 318
  local overlapRec = ns.JournalRecord(twoHand)
  overlapRec.ilvl = { n = OVERLAP, h = OVERLAP, m = OVERLAP }
  local ovN = ns.Loot.ScoreItem(880002, { record = overlapRec, difficulty = "n" })
  local ovM = ns.Loot.ScoreItem(880002, { record = overlapRec, difficulty = "m" })
  check("at an OVERLAPPING level, raid difficulty still cannot move the track",
        ovN.candidateTrack == ovM.candidateTrack,
        ("normal says %s, mythic says %s — a raid bonus block is deciding a dungeon drop")
          :format(tostring(ovN.candidateTrack), tostring(ovM.candidateTrack)))
  check("...and the fixture level really is ambiguous on the ladder",
        select(1, ns.ResolveTrack(OVERLAP, { ns.BonusIdsFor("m", 1)[1] }))
          ~= select(1, ns.ResolveTrack(OVERLAP, {})),
        "otherwise the check above is vacuous")
  ns.MPLUS_ILVL = realIlvl

  -- ── THE SAME TRAP, ON RAID LOOT ───────────────────────────────────────────
  -- Everything above proves a DUNGEON item ignores its catalogue link. A raid
  -- item is in our loot table, so it has a real record and `rec.synthetic` is
  -- false — it took the link branch and read the guide's base level, identically
  -- on every difficulty. Heroic and Mythic showed the same item level in the
  -- Full Loot Table for a whole season and the difficulty control looked inert.
  --
  -- ⚠️ THE FIXTURE HAS TO SUPPLY THE INPUT THAT CAUSES THE BUG. The catalogue
  -- level is chosen to differ from ALL THREE of n/h/m: equal to any one of them
  -- and the check passes with the fix removed, which is the S251 lesson about a
  -- guard that will not bite.
  -- Re-read the payload record rather than reusing the `chest` local from the
  -- top of the file: that name is SHADOWED further down by a recorded drop, and
  -- deriving from the fixture is what the fixture rule asks for anyway.
  local raidRec = (ns.Data().items or {})[chestId]
  local savedItem = stub.items[chestId]
  local CATALOGUE_ILVL = 264
  stub.items[chestId] = { name = raidRec.name, quality = 4, ilvl = CATALOGUE_ILVL,
                          itemType = "Armor" }
  local catLink = stub.link(chestId, raidRec.name, {})

  check("the raid item's difficulty columns are genuinely different",
        raidRec.ilvl.h ~= raidRec.ilvl.m and raidRec.ilvl.n ~= raidRec.ilvl.h,
        ("n=%s h=%s m=%s"):format(tostring(raidRec.ilvl.n), tostring(raidRec.ilvl.h),
                                  tostring(raidRec.ilvl.m)))
  check("...and the catalogue link reports none of them",
        ns.DetailedIlvl(catLink) == CATALOGUE_ILVL
          and CATALOGUE_ILVL ~= raidRec.ilvl.n and CATALOGUE_ILVL ~= raidRec.ilvl.h
          and CATALOGUE_ILVL ~= raidRec.ilvl.m,
        tostring(ns.DetailedIlvl(catLink)))

  local catH = ns.Loot.ScoreItem(chestId, { itemLink = catLink, difficulty = "h",
                                            catalogue = true })
  local catM = ns.Loot.ScoreItem(chestId, { itemLink = catLink, difficulty = "m",
                                            catalogue = true })
  check("a catalogue link never sets a raid item's heroic level",
        catH.candidateIlvl == raidRec.ilvl.h,
        ("got %s, want %s"):format(tostring(catH.candidateIlvl), tostring(raidRec.ilvl.h)))
  check("...nor its mythic level",
        catM.candidateIlvl == raidRec.ilvl.m,
        ("got %s, want %s"):format(tostring(catM.candidateIlvl), tostring(raidRec.ilvl.m)))
  check("...so Mythic and Heroic actually differ in the browse list",
        catM.candidateIlvl > catH.candidateIlvl,
        ("h=%s m=%s"):format(tostring(catH.candidateIlvl), tostring(catM.candidateIlvl)))

  -- ⚠️ THE OTHER HALF OF THE RULE. A REAL DROP'S link is still the best answer
  -- and must keep winning — it describes the item that actually dropped, upgrade
  -- track and all. Only the caller can tell the two apart, which is why this is
  -- a flag and not a property of the record.
  local dropped = ns.Loot.ScoreItem(chestId, { itemLink = catLink, difficulty = "h" })
  check("a real drop's link still outranks our table",
        dropped.candidateIlvl == CATALOGUE_ILVL,
        ("got %s, want %s"):format(tostring(dropped.candidateIlvl), tostring(CATALOGUE_ILVL)))

  -- The tooltip has to move with the level, or the panel shows two authorities
  -- disagreeing on one screen — the failure the dungeon fix already named.
  local rlH = ns.RaidItemLink(chestId, "h")
  local rlM = ns.RaidItemLink(chestId, "m")
  check("a raid item gets a difficulty-specific tooltip link", rlH ~= nil and rlM ~= nil)
  check("...and Heroic's differs from Mythic's", rlH ~= rlM,
        ("%s vs %s"):format(tostring(rlH), tostring(rlM)))
  check("...carrying the bonus id for that difficulty's track",
        (ns.ParseItemLink(rlM) or {}).bonusIDs
          and ns.ParseItemLink(rlM).bonusIDs[1] == ns.BonusIdsFor("m", raidRec.dropRank)[1],
        tostring(rlM))
  -- ⚠️ NIL, NOT A BARE ITEM STRING, for an item we never imported: the guide's
  -- link is then the best tooltip available and the caller keeps it.
  check("an item outside our loot table gets no raid link at all",
        ns.RaidItemLink(880002, "m") == nil, tostring(ns.RaidItemLink(880002, "m")))

  -- ── THE SOURCE'S OWN BONUS IDS (Session 259) ──────────────────────────────
  --
  -- ⚠️ THE POINT IS AN ITEM WE KNOW NOTHING ELSE ABOUT. Everything above needs a
  -- record in our loot table to answer at all; a crafted BIS pick has none, and
  -- guessing one from its absence is what put a crafted bracer at ITEM LEVEL 28
  -- beside an equipped 311. So this stages an id that is deliberately NOT in the
  -- payload's items, which is the only case that proves the new path.
  do
    local data = ns.Data()
    local CRAFTED = 880777
    local me = ns.ResolveCharacter()
    local key = me.className .. "/" .. me.specName
    check("the staged id really is outside our loot table",
          (data.items or {})[CRAFTED] == nil)

    data.rankings[CRAFTED] = { [key] = { b = "overall", bi = "13751:12497:13836" } }
    local link = ns.BisItemLink(CRAFTED, me.className, me.specName, me.heroTree)
    check("a pick with stated bonus ids gets a link from them", link ~= nil, tostring(link))
    local p = link and ns.ParseItemLink(link)
    check("...carrying all three, in the source's own order",
          p and p.bonusIDs and #p.bonusIDs == 3
            and p.bonusIDs[1] == 13751 and p.bonusIDs[2] == 12497 and p.bonusIDs[3] == 13836,
          link)
    check("...and it is NOT a bare item string, which tooltips at base level",
          link and not link:match("^item:%d+$"), link)

    -- ⚠️ A MALFORMED ID MUST NOT REACH THE CLIENT. One harvested string carries
    -- what looks like an item id in the bonus field; a bad value renders a
    -- nonsense tooltip rather than erroring, which is the failure mode this
    -- whole change exists to remove.
    data.rankings[CRAFTED] = { [key] = { b = "overall", bi = "nonsense" } }
    check("a malformed bonus string yields no link rather than a bad one",
          ns.BisItemLink(CRAFTED, me.className, me.specName, me.heroTree) == nil)

    -- The common case for a catalyse SOURCE: the guide publishes ids for the
    -- piece it lists, never for the drop that becomes it.
    data.rankings[CRAFTED] = { [key] = { b = "overall" } }
    check("a pick with no stated ids yields nil, so the caller keeps its own link",
          ns.BisItemLink(CRAFTED, me.className, me.specName, me.heroTree) == nil)

    -- ── "FROM CRAFTED" IS A CLAIM, NOT AN INFERENCE (Session 259) ──────────
    --
    -- ⚠️ THE SECOND HALF IS THE IMPORTANT ONE. Labelling from `rec == nil` was
    -- the tempting fix and it is wrong: dungeon loot, tier pieces, world bosses
    -- and Delve gear are all equally absent from our raid table, so that rule
    -- would have called every one of them Crafted. The pair below is what pins
    -- it — same absence, opposite answers, decided by what the item SAYS.
    check("an item whose description says Crafted gets a source line",
          (ns.CraftedSource({ nameDesc = "Tidal Crafted" }) or {}).boss == "Crafted")
    check("...rendered as a BOSS line, so it inherits those weights with no branch",
          ns.CraftedSource({ nameDesc = "Tidal Crafted" }).instance == nil)
    check("...and it is case-insensitive, since the prefix varies by season",
          (ns.CraftedSource({ nameDesc = "SOME OTHER CRAFTED" }) or {}).boss == "Crafted")
    check("a dungeon item saying Mythic+ is NOT called crafted",
          ns.CraftedSource({ nameDesc = "Mythic+" }) == nil)
    check("an item with NO description is not called crafted either",
          ns.CraftedSource({}) == nil and ns.CraftedSource(nil) == nil)

    -- End to end through the report: the same staged id, once claiming crafted
    -- and once not, with everything else identical.
    local function pickFor(nd)
      data.rankings[CRAFTED] = { [key] = { b = "overall", bx = { "overall" }, nd = nd } }
      stub.itemEquipLoc[CRAFTED] = "INVTYPE_WRIST"
      local rep = ns.SlotsReport("overall")
      for _, row in ipairs(rep.rows) do
        for _, p in ipairs(row.picks) do if p.itemID == CRAFTED then return p end end
      end
    end
    local craftedPick = pickFor("Tidal Crafted")
    check("the report gives a crafted BIS pick its source line",
          craftedPick and craftedPick.source and craftedPick.source.boss == "Crafted",
          craftedPick and craftedPick.source and craftedPick.source.boss)
    local plainPick = pickFor(nil)
    check("...and the SAME item with no claim gets no source line at all",
          plainPick and plainPick.source == nil,
          plainPick and plainPick.source and plainPick.source.boss)

    -- ── DUNGEON LOOT GETS ITS SOURCE FROM THE GUIDE (Session 259) ─────────
    --
    -- ⚠️ THE CASE THAT WAS SILENTLY BLANK. loot_items holds RAID loot only, so
    -- every dungeon BIS pick drew no second line at all — and a missing line is
    -- invisible in a way a wrong one is not, which is why it survived until
    -- Jason listed the items by name. The guide is the only thing that knows.
    local idx = ns.Journal and ns.Journal.SourceIndex and ns.Journal.SourceIndex()
    check("the journal builds an itemID -> source index", type(idx) == "table")
    local anyItem, anyEntry
    for id, e in pairs(idx or {}) do anyItem, anyEntry = id, e; break end
    check("...with at least one item in it, so the checks below mean something",
          anyItem ~= nil)
    if anyItem then
      local src = ns.JournalSource(anyItem)
      check("...and JournalSource names the boss for one",
            src and ns.NonEmpty(src.boss) ~= nil, src and src.boss)
      check("...and the instance it sits in",
            src and ns.NonEmpty(src.instance) ~= nil, src and src.instance)
    end
    check("an item the guide has never heard of gets no line invented for it",
          ns.JournalSource(880999) == nil)

    -- ── THE PLAYER'S OWN GUIDE SETTINGS ARE NOT OUR INPUT (Session 260) ─────
    --
    -- Journal.Loot's own header already says ambient selection state is a race,
    -- and then two pieces of ambient state were left outside it. Both belong to
    -- the PLAYER and both silently narrow what we read: the slot dropdown, and
    -- the difficulty. Jason's guide was on "Chest" and "(5) Mythic" when he
    -- checked, which is exactly how sticky they are.
    do
      ns.Journal.Invalidate()
      stub.journal.slotFilter = "Finger"      -- as if the player left it there
      stub.journal.difficulty = 1             -- DungeonNormal
      local idx2 = ns.Journal.SourceIndex()

      -- The bug as reported: an item the guide lists only at Mythic.
      local hit = idx2 and idx2[880042]
      check("an item listed only at Mythic still reaches the source index",
            hit ~= nil, "the difficulty the PLAYER left selected decided it")
      check("...naming the boss that drops it",
            hit and hit.boss == "The Brood Matron", hit and hit.boss)
      check("...and the dungeon it sits in",
            hit and hit.instance == "Altar of Fangs", hit and hit.instance)

      -- A slot filter of Finger would have hidden every one of these.
      check("a player's slot filter does not truncate what we index",
            idx2 and idx2[880001] ~= nil and idx2[880002] ~= nil,
            "a Head and a Two-Hand item, read while the filter said Finger")

      -- ⚠️ AND WE PUT BOTH BACK. Leaving someone's Adventure Guide on a
      -- different slot or difficulty than they left it is our bug, not a
      -- detail — the addon reads this on every login, unprompted.
      check("the player's slot filter is restored afterwards",
            stub.journal.slotFilter == "Finger", tostring(stub.journal.slotFilter))
      check("...and so is their difficulty",
            stub.journal.difficulty == 1, tostring(stub.journal.difficulty))

      -- ⚠️ AND THE SOURCE INDEX FOLLOWS THE SEASON, NOT THE TIER. This is the
      -- item Jason chased for three rounds: its dungeon was never enumerated,
      -- so no amount of filter or difficulty fixing downstream could have found
      -- it. The out-of-season item is the other half — a catalogue scoped to
      -- the season must not quietly widen either.
      check("an item from a season dungeon in an older tier is indexed",
            idx2 and idx2[880043] ~= nil,
            "Sandworn Guardian's Breastplate, Temple of Sethraliss")
      check("...naming its boss",
            idx2 and idx2[880043] and idx2[880043].boss == "Avatar of Sethraliss",
            idx2 and idx2[880043] and idx2[880043].boss)
      check("...and an out-of-season dungeon's loot is NOT indexed",
            idx2 and idx2[880044] == nil,
            "Magisters' Terrace is in the tier but not in the season")

      stub.journal.slotFilter, stub.journal.difficulty = nil, nil
      ns.Journal.Invalidate()
    end

    -- ⚠️ AND THROUGH THE REPORT, WHICH IS THE BUG AS REPORTED. Testing
    -- ns.JournalSource on its own passed with the call site deleted — the probe
    -- did not bite, which is the S256 rule saying the check was aimed at the
    -- wrong thing. What Jason saw was a dungeon pick with a blank second line,
    -- so the assertion has to run the pick through SlotsReport.
    local dungeonId, dungeonSrc
    for id, e in pairs(idx or {}) do
      if not (data.items or {})[id] and ns.NonEmpty(e.boss) then
        dungeonId, dungeonSrc = id, e
        break
      end
    end
    check("the guide names an item our raid table does NOT, to stage with",
          dungeonId ~= nil)
    if dungeonId then
      data.rankings[dungeonId] = { [key] = { b = "overall", bx = { "overall" } } }
      stub.itemEquipLoc[dungeonId] = "INVTYPE_FINGER"
      local rep = ns.SlotsReport("overall")
      local found
      for _, row in ipairs(rep.rows) do
        for _, p in ipairs(row.picks) do if p.itemID == dungeonId then found = p end end
      end
      check("a dungeon BIS pick reaches the report", found ~= nil)
      check("...and carries the guide's source, not a blank line",
            found and found.source and found.source.boss == dungeonSrc.boss,
            found and found.source and found.source.boss or "NO SOURCE LINE")
      -- ⚠️ AND IS NOT CALLED A TIER PIECE (Session 260). tierPiece was
      -- `rec == nil` — "absent from our RAID loot table" — which is equally
      -- true of every dungeon drop, so a dungeon helm was given the TIER PIECE
      -- chip, the tier layout, and an OBTAINED BY panel offering a token that
      -- does not produce it. Jason found it on the first screen he opened.
      -- This was the last consumer of the proxy Session 259 retired everywhere
      -- else. A source we can actually NAME refutes the tier claim; absence of
      -- one still only means we do not know.
      check("...and is NOT labelled a tier piece",
            found and found.tierPiece == false,
            found and tostring(found.tierPiece))

      -- ⚠️ AND A SLOT TIER DOES NOT EXIST IN IS NEVER TIER (Session 260, Jason:
      -- a WRIST showed a TIER PIECE chip). Absence of a source was still pure
      -- elimination, so any unsourced pick got the label — bracers, rings,
      -- weapons alike. Staged as the wrist case exactly: an item nothing can
      -- name a source for, in a slot with no token in any season.
      data.rankings[dungeonId][key] = { b = "overall", bx = { "overall" } }
      stub.itemEquipLoc[dungeonId] = "INVTYPE_WRIST"
      local wristIdx = ns.Journal.SourceIndex()[dungeonId]
      local savedSrc = wristIdx and wristIdx.boss
      if wristIdx then wristIdx.boss = nil end   -- nothing can name it
      local rep2 = ns.SlotsReport("overall")
      local wrist
      for _, row in ipairs(rep2.rows) do
        for _, p in ipairs(row.picks) do if p.itemID == dungeonId then wrist = p end end
      end
      check("an unsourced pick in a WRIST slot is not called a tier piece",
            wrist and wrist.tierPiece == false,
            wrist and tostring(wrist.tierPiece) or "no pick")
      if wristIdx then wristIdx.boss = savedSrc end
      stub.itemEquipLoc[dungeonId] = "INVTYPE_FINGER"
      data.rankings[dungeonId] = { [key] = { b = "overall", bx = { "overall" } } }

      -- ⚠️ AND A ROUTE INSIDE THE OBTAINED BY PANEL GETS THE SAME LADDER
      -- (Session 260, Jason: "a piece listed as a catalyze target that has NO
      -- location/source showing"). The panel drew a line for one route and
      -- nothing for the other on the same screen, because ObtainRoutes called
      -- ns.ItemSource ALONE while the pick above it walked all three rungs.
      -- A catalyse source that drops in a REVAMPED DUNGEON — which is what
      -- Desert Guardian's Breastplate is — is not in our raid table at all.
      -- Both now go through ns.SourceFor, so they cannot diverge again.
      local tierTarget = 999042
      data.rankings[dungeonId][key].cat = tierTarget
      local routes = ns.ObtainRoutes(tierTarget, "FINGER",
        ns.ResolveCharacter and ns.ResolveCharacter()) or {}
      local catRoute
      for _, r in ipairs(routes) do
        if r.itemID == dungeonId then catRoute = r end
      end
      check("a catalyse source from a dungeon reaches the OBTAINED BY panel",
            catRoute ~= nil)
      check("...carrying the guide's source line, not a blank",
            catRoute and catRoute.source and catRoute.source.boss == dungeonSrc.boss,
            catRoute and catRoute.source and catRoute.source.boss or "NO SOURCE LINE")
      data.rankings[dungeonId][key].cat = nil
      data.rankings[dungeonId] = nil
      stub.itemEquipLoc[dungeonId] = nil
    end

    -- ⚠️ THE INDEX MUST NOT FREEZE HALF-EMPTY. A first look at the guide is
    -- cold, so an index memoised at that moment would be permanently short —
    -- the async trap this addon has hit repeatedly. Loot arriving clears it.
    local before = ns.Journal.SourceIndex()
    check("the index is memoised while nothing changes",
          ns.Journal.SourceIndex() == before)
    ns.Journal.CachedLoot(anyEntry and 0 or 0)
    check("...and is rebuilt as soon as any loot is read again",
          ns.Journal.SourceIndex() ~= before)

    data.rankings[CRAFTED] = nil
    stub.itemEquipLoc[CRAFTED] = nil
  end

  stub.items[chestId] = savedItem

  -- ── THE GREAT VAULT LEVEL ─────────────────────────────────────────────────
  -- Season 2 rewards the vault one full track above the drop. These are the
  -- levels the site emits, read off Wowhead and Icy Veins — NOT method.gg, which
  -- gives 311 to both Hero 3/6 and Hero 4/6 and so contradicts itself.
  header("Great Vault levels")

  local vN, vH, vM = ns.VaultReward("n"), ns.VaultReward("h"), ns.VaultReward("m")
  local vD = ns.VaultReward("mplus")
  check("the payload carries a vault table", ns.HasVaultData())
  check("Normal raid vaults at Hero 1/6",
        vN and vN.track == "Hero" and vN.rank == 1 and vN.ilvl == 305,
        vN and ("%s %d = %d"):format(vN.track, vN.rank, vN.ilvl) or "nil")
  check("Heroic raid vaults at Myth 1/6 (318)",
        vH and vH.track == "Myth" and vH.rank == 1 and vH.ilvl == 318,
        vH and ("%s %d = %d"):format(vH.track, vH.rank, vH.ilvl) or "nil")
  check("Mythic raid vaults at Myth 6/6 (334)",
        vM and vM.track == "Myth" and vM.rank == 6 and vM.ilvl == 334,
        vM and ("%s %d = %d"):format(vM.track, vM.rank, vM.ilvl) or "nil")
  check("a dungeon vaults at Myth 1/6 (318), above its 311 drop",
        vD and vD.track == "Myth" and vD.rank == 1 and vD.ilvl == 318
          and vD.ilvl > ns.MPLUS_ILVL,
        vD and ("%s %d = %d"):format(vD.track, vD.rank, vD.ilvl) or "nil")

  -- ⚠️ THE OVERLAP IS THE WHOLE REASON THE BONUS ID IS ATTACHED. 318 is Hero 5/6
  -- AND Myth 1/6, and the resolver assumes the LOWER track with nothing to break
  -- the tie — so a Heroic vault reward would report "Hero" without it, which is
  -- the opposite of the claim the toggle makes.
  local heroicVault = ns.Loot.ScoreItem(chestId, { difficulty = "h", vault = true })
  local heroicDrop  = ns.Loot.ScoreItem(chestId, { difficulty = "h" })
  check("a heroic item scored for the vault reports the vault level",
        heroicVault.candidateIlvl == 318, tostring(heroicVault.candidateIlvl))
  check("...on the MYTH track, not Hero 5/6 which shares that item level",
        heroicVault.candidateTrack == "Myth", tostring(heroicVault.candidateTrack))
  check("...and 318 really is ambiguous without a bonus id",
        select(1, ns.ResolveTrack(318, {})) == "Hero",
        "otherwise the check above proves nothing")
  check("...while the same item WITHOUT the toggle keeps its drop level",
        heroicDrop.candidateIlvl == raidRec.ilvl.h
          and heroicDrop.candidateIlvl ~= heroicVault.candidateIlvl,
        ("drop %s vs vault %s"):format(tostring(heroicDrop.candidateIlvl),
                                       tostring(heroicVault.candidateIlvl)))

  -- ⚠️ NEVER BELOW THE DROP. The penultimate and final bosses drop Myth 9 (344),
  -- which is ABOVE the Myth 6/6 (334) the vault otherwise gives — and Blizzard
  -- hands those out at Myth 9 in the vault too. An item like that must keep 344.
  local ascended = nil
  for id, it in pairs(ns.Data().items or {}) do
    if it.ilvl and it.ilvl.m and it.ilvl.m > 334 and usable(it) and it.slot ~= "TOKEN" then
      ascended = id; break
    end
  end
  if ascended then
    local asc = ns.Loot.ScoreItem(ascended, { difficulty = "m", vault = true })
    local ascDrop = (ns.Data().items[ascended].ilvl or {}).m
    check("an ascended mythic item keeps its own level in the vault",
          asc.candidateIlvl == ascDrop,
          ("vault gave %s, the boss drops %s"):format(tostring(asc.candidateIlvl),
                                                      tostring(ascDrop)))
    check("...which is genuinely above the Myth 6/6 vault rung",
          ascDrop > vM.ilvl, ("%s vs %s"):format(tostring(ascDrop), tostring(vM.ilvl)))
  else
    check("a mythic item above Myth 6/6 exists to test the carve-out", false,
          "no item in the payload drops above 334 — the carve-out is untested")
  end

  -- ── THE TOOLTIP MOVES WITH THE NUMBER ─────────────────────────────────────
  -- This shipped broken: the detail line read "Myth · ilvl 318" while the
  -- tooltip an inch away read "Hero 3/6, Item Level 311", because the link still
  -- carried the DROP's bonus id. The tooltip is now derived from the score.
  check("318 is Myth 1/6 and Hero 5/6 on the same ladder",
        ns.LadderRank("Myth", 318) == 1 and ns.LadderRank("Hero", 318) == 5,
        "the overlap is why the link needs an explicit track")

  -- ⚠️ PINNED TO HEROIC ON PURPOSE. The ambient setting here is MPLUS, which
  -- ns.DifficultyKey() resolves to "m" — track Myth — and that is the SAME track
  -- the vault reward uses, so a link built from the drop's difficulty and a link
  -- built from the vault's track come out IDENTICAL and the check below passes
  -- with the fix removed. Found by revert-checking it: the guard was fine, the
  -- fixture had chosen the one value that could not fail.
  local pinnedDiff = ns.Settings.Get("difficulty")
  ns.Settings.Set("difficulty", "HEROIC")
  check("the drop track and the vault track now genuinely differ",
        ns.DIFFICULTY_TRACK[ns.DifficultyKey()] == "Hero",
        "otherwise the tooltip checks below are vacuous")

  local vaultLink = ns.TooltipLinkFor(chestId, "Myth", 318)
  local dropLink  = ns.TooltipLinkFor(chestId, "Hero", 311)
  check("a tooltip link can be built for the vault level", vaultLink ~= nil)
  check("...carrying MYTH 1/6's bonus id, not Hero's",
        (ns.ParseItemLink(vaultLink) or {}).bonusIDs
          and ns.ParseItemLink(vaultLink).bonusIDs[1] == ns.BonusIdsForTrack("Myth", 1)[1],
        tostring(vaultLink))
  check("...and it differs from the drop level's link", vaultLink ~= dropLink,
        "identical links are how the two numbers came to disagree")

  -- ⚠️ THE ASCENDED GAP IS HONEST, NOT AN INVENTED ID. Myth 7-9 (337/341/344)
  -- have no mined bonus id — they are NOT the next three numbers, since every
  -- block is six ids then a gap of two — so the caller keeps the link it had.
  check("no tooltip link is invented for an ascended level",
        ns.TooltipLinkFor(chestId, "Myth", 344) == nil,
        tostring(ns.TooltipLinkFor(chestId, "Myth", 344)))

  ns.Settings.Set("difficulty", pinnedDiff)

  -- The case Jason actually hit: a DUNGEON item in vault mode.
  local dRec = ns.JournalRecord(twoHand)
  local dVault = ns.Loot.ScoreItem(880002, { record = dRec, itemLink = twoHand.link,
                                             catalogue = true, vault = true })
  local dDrop  = ns.Loot.ScoreItem(880002, { record = dRec, itemLink = twoHand.link,
                                             catalogue = true })
  check("a dungeon item in vault mode scores at Myth 1/6 (318)",
        dVault.candidateIlvl == 318 and dVault.candidateTrack == "Myth",
        ("%s / %s"):format(tostring(dVault.candidateIlvl), tostring(dVault.candidateTrack)))
  check("...against Hero 3/6 (311) as a drop",
        dDrop.candidateIlvl == ns.MPLUS_ILVL and dDrop.candidateTrack == "Hero",
        ("%s / %s"):format(tostring(dDrop.candidateIlvl), tostring(dDrop.candidateTrack)))
  check("...and its tooltip link follows the score rather than the drop",
        ns.TooltipLinkFor(880002, dVault.candidateTrack, dVault.candidateIlvl)
          ~= ns.TooltipLinkFor(880002, dDrop.candidateTrack, dDrop.candidateIlvl),
        "this is the exact pair that read 318 on screen and 311 in the tooltip")

  -- ── When the toggle is OFFERED ────────────────────────────────────────────
  -- ⚠️ ON AUTO TOO, SINCE SESSION 257, and that REVERSES what this block used to
  -- assert. The old rule refused the toggle on AUTO because "the vault level of
  -- whatever this is" named no content. The control now reads "Auto: Heroic" —
  -- it states the content it resolved to, on screen, and updates when you zone —
  -- so the reason lapsed, while the cost of a checkbox that is in the design and
  -- missing from the game did not.
  local savedDiff = ns.Settings.Get("difficulty")
  local savedVault = ns.Settings.Get("vault")

  ns.Settings.Set("difficulty", "AUTO")
  check("the Vault toggle is offered on AUTO, which names its own content now",
        ns.VaultShown() == true)
  ns.Settings.Set("vault", "on")
  check("...and reads the stored setting there", ns.VaultOn() == true)

  ns.Settings.Set("difficulty", "HEROIC")
  check("the Vault toggle is offered once a difficulty is chosen", ns.VaultShown() == true)
  check("...and reads the stored setting", ns.VaultOn() == true)
  ns.Settings.Set("vault", "off")
  check("...and off means off", ns.VaultOn() == false)

  -- ⚠️ NO VAULT DATA, NO TOGGLE. An older payload carries no vault table, and
  -- the control must not offer a level it would have to invent — the same rule
  -- the GP price follows.
  local savedTracks = ns.Data().tracks.vault
  ns.Data().tracks.vault = nil
  check("an older payload with no vault table hides the toggle entirely",
        ns.HasVaultData() == false and ns.VaultShown() == false)
  ns.Settings.Set("vault", "on")
  check("...and cannot be forced on by the stored setting", ns.VaultOn() == false)
  local noData = ns.Loot.ScoreItem(chestId, { difficulty = "h", vault = true })
  check("...and scoring with vault asked for falls back to the drop level",
        noData.candidateIlvl == raidRec.ilvl.h, tostring(noData.candidateIlvl))
  ns.Data().tracks.vault = savedTracks

  ns.Settings.Set("difficulty", savedDiff)
  ns.Settings.Set("vault", savedVault and "on" or "off")

  -- ── BOTH SCORERS AGREE ────────────────────────────────────────────────────
  -- The item column is scored by ScoreItem and the detail pane's roster ranking
  -- by RankRaiders. They run side by side on one screen, so a second copy of the
  -- vault arithmetic would be two chances to disagree in front of the raid.
  local rankVault = ns.Loot.RankRaiders(chestId, { difficulty = "h", vault = true })
  local rankDrop  = ns.Loot.RankRaiders(chestId, { difficulty = "h" })
  if rankVault and rankDrop and rankVault[1] and rankDrop[1] then
    check("the roster ranking honours vault mode too",
          (rankVault[1].ilvlGain or 0) > (rankDrop[1].ilvlGain or 0),
          ("vault gain %s vs drop gain %s"):format(tostring(rankVault[1].ilvlGain),
                                                   tostring(rankDrop[1].ilvlGain)))
  else
    check("a roster is loaded so the two scorers can be compared",
          rankVault ~= nil and rankDrop ~= nil,
          "without a payload this comparison proves nothing")
  end

  -- An ordinary mythic item DOES move up to the vault rung.
  local plainMythic = nil
  for id, it in pairs(ns.Data().items or {}) do
    if it.ilvl and it.ilvl.m and it.ilvl.m < 334 and usable(it) and it.slot ~= "TOKEN" then
      plainMythic = id; break
    end
  end
  if plainMythic then
    local pm = ns.Loot.ScoreItem(plainMythic, { difficulty = "m", vault = true })
    check("an ordinary mythic item vaults up to Myth 6/6 (334)",
          pm.candidateIlvl == 334, tostring(pm.candidateIlvl))
  end

  -- ── Eligibility fails OPEN ────────────────────────────────────────────────
  -- The guide entry carries no class list, and an empty one reads as the addon
  -- being broken. An over-broad list is visibly wrong and fixable.
  check("an item with no class list is not declared unusable",
        not scored.ineligible, tostring(scored.reason))

  -- ── An unplaceable item is listed but never scored ────────────────────────
  local noSlot
  for _, e in ipairs(pooled) do if e.itemID == 880005 then noSlot = e end end
  check("an item the guide cannot place yields no record", ns.JournalRecord(noSlot) == nil)

  -- ── Tonight's drops, filtered by the DUNGEON rather than one boss ────────
  -- A Mythic+ tile is an instance and drops are recorded against an encounter.
  -- Passing the tile id straight through filters on the wrong number space.
  local ids = ns.EncounterIdsFor(multiBoss.id)
  check("a dungeon tile resolves to a SET of encounter ids", type(ids) == "table",
        type(ids))
  local n = 0
  for _ in pairs(ids) do n = n + 1 end
  check("...one per boss in the dungeon", n == #ns.Journal.CachedEncounters(multiBoss.id), n)
  check("...and never the instance id itself, which is a different id space",
        ids[multiBoss.id] ~= true,
        "an instance id matching an encounter id would be a coincidence, not a match")

  -- The recorder must accept that set. A number still works for raid tiles.
  local okSet = pcall(ns.Record.RecentDrops, 40, ids)
  local okNum = pcall(ns.Record.RecentDrops, 40, 2849)
  check("the recorder filters on a set as well as a single boss", okSet and okNum)

  -- ── And it can be priced, which is the other half of the answer ───────────
  local live = ns.Payload.Current()
  if live and live.gp then
    check("a dungeon item is priced from its slot and level",
          ns.Payload.Price(880002, ns.MPLUS_ILVL, "TWO_HAND") ~= nil)
  end

  -- ── USABLE ONLY MUST ACTUALLY FILTER ────────────────────────────────────
  -- ⚠️ THE LIVE BUG (Jason, Session 251): a LEATHER shoulder listed under Usable
  -- Only for a Warlock. A dungeon item has no `classes` set — we have never
  -- imported dungeon loot tables — so it fell straight through the class gate,
  -- which fails OPEN by design, and every dungeon item read as usable.
  --
  -- The answer is the GAME'S, not a re-derivation: Blizzard's own journal filter
  -- judges each item for this character. Nothing in Lua knows what a Warlock can
  -- wear, which is the whole point.
  local usable = ns.DungeonUsable(multiBoss.id)
  check("the game answers which items this character can use", type(usable) == "table",
        type(usable))

  local mine, theirs   -- an item of our armour type, and one of somebody else's
  for _, e in ipairs(pooled) do
    if e.itemID == 880001 then mine = e elseif e.itemID == 880006 then theirs = e end
  end
  check("the fixture carries an item of another class's armour type", theirs ~= nil,
        "this is the leather-shoulder case; without it the check below is vacuous")

  check("...and the game excludes it", usable and usable[theirs.itemID] ~= true,
        "Blizzard's filter should not list it for this class")
  check("...while keeping our own", usable and usable[mine.itemID] == true)

  local mineRec   = ns.JournalRecord(mine, usable)
  local theirsRec = ns.JournalRecord(theirs, usable)
  check("an item another class wears is marked unusable on the record",
        theirsRec.usable == false, tostring(theirsRec.usable))
  check("...and ours is not", mineRec.usable == true, tostring(mineRec.usable))

  local theirsScored = ns.Loot.ScoreItem(theirs.itemID, { record = theirsRec })
  check("...so it scores as INELIGIBLE, which is what Usable Only filters on",
        theirsScored.ineligible == true, tostring(theirsScored.reason))
  local mineScored = ns.Loot.ScoreItem(mine.itemID, { record = mineRec })
  check("...and ours still scores", mineScored.ineligible ~= true, tostring(mineScored.reason))

  -- ⚠️ NOT KNOWING IS NOT THE SAME AS USABLE, and it must not become a silent
  -- "yes". With no answer from the game the item is left UNJUDGED — it falls
  -- through to the existing fail-open, which is the documented behaviour for
  -- anything we cannot ask about.
  local unjudged = ns.JournalRecord(theirs, nil)
  check("with no answer from the game, the item is left unjudged rather than allowed",
        unjudged.usable == nil, tostring(unjudged.usable))

  -- ── Tile art: one file per DUNGEON, keyed by instance id ─────────────────
  -- ⚠️ TWO ID SPACES. Raid art is keyed by ENCOUNTER id and dungeon art by
  -- INSTANCE id, and the ranges overlap — so they live in separate folders. One
  -- folder would eventually draw a raid boss's face on a dungeon, silently.
  --
  -- A NEW SEASON NEEDS NEW ART or these fall back to initials, exactly as the
  -- raid tiles do. It belongs on the rollover checklist.
  local missing = {}
  for _, d in ipairs(dungeons) do
    local f = io.open(("Media/dungeons/%d.png"):format(d.id), "rb")
    if f then f:close() else missing[#missing + 1] = ("%s (%d)"):format(d.name, d.id) end
  end
  -- The stub's dungeons are invented, so this cannot assert every tile has art.
  -- What it CAN assert is that the folder exists and is keyed the way the panel
  -- reads it — against the REAL season's ids, which are the ones that ship.
  local realSeasonDungeons = { 1304, 1311, 1309, 1313, 1322, 1041, 1030, 1202 }
  local haveReal = 0
  for _, id in ipairs(realSeasonDungeons) do
    local f = io.open(("Media/dungeons/%d.png"):format(id), "rb")
    if f then f:close(); haveReal = haveReal + 1 end
  end
  check("every dungeon of the shipping season has bundled art",
        haveReal == #realSeasonDungeons,
        ("%d of %d — a missing file falls back to an initial")
          :format(haveReal, #realSeasonDungeons))
  check("...in their own folder, not mixed with the boss art",
        io.open("Media/bosses/2849.png", "rb") ~= nil,
        "raid art keys on ENCOUNTER ids and dungeon art on INSTANCE ids")

  -- ── Back in raid mode, nothing about the tile changes shape ──────────────
  ns.Settings.Set("difficulty", "HEROIC")
  -- ⚠️ THIS CHECK USED TO ASSERT THE BUG. It read "a raid tile is still a
  -- single boss id, not a set" and passed for months while Current Drops showed
  -- nothing on every raid boss: a drop carries the DungeonEncounter id from
  -- ENCOUNTER_END (Entombed Sentinels = 3445) and the tile is the JOURNAL id
  -- (2874), so filtering one against the other matched nothing. A full LFR
  -- recorded eighteen drops and displayed none. The harness agreed with the
  -- belief that was also written into the code — exactly the S244 trap.
  do
    local boss = ns.Data() and (ns.Data().bosses or {})[2849]
    local hadEnc = boss and boss.enc
    if boss then boss.enc = 3379 end   -- Nymrissa: 2849 in the journal, 3379 on the kill

    local ids = ns.EncounterIdsFor(2849)
    check("a raid tile resolves to BOTH id spaces, so a recorded drop can match it",
          type(ids) == "table" and ids[2849] == true and ids[3379] == true,
          type(ids) == "table" and "journal=" .. tostring(ids[2849]) .. " kill=" .. tostring(ids[3379])
            or tostring(ids))

    -- ⚠️ THE FALLBACK MUST BE STAGED, NOT INHERITED (Session 254). This restored
    -- the boss's ORIGINAL value and then asserted there was no kill id — which
    -- held only while the emitted payload carried none. The moment the emitter
    -- started shipping `enc`, the restore put a real id back and the check for
    -- the no-id path failed, having never actually tested that path on its own
    -- terms. The S251 rule exactly: a fixture that differs from production in a
    -- field the code branches on is testing a system that does not exist — and
    -- here it was the fixture QUIETLY AGREEING with production instead.
    if boss then boss.enc = nil end
    local bare = ns.EncounterIdsFor(2849)
    check("...and a boss with no kill id still matches on the journal id alone",
          type(bare) == "table" and bare[2849] == true and bare[3379] == nil)

    if boss then boss.enc = hadEnc end
  end
  check("...and raid mode is raid mode", ns.ContentMode() == "raid", ns.ContentMode())

  ns.Settings.Set("difficulty", prevMode or "AUTO")
end)()

header("Roll states — read from the client's names, never from numbers")

-- ⚠️ WHY THIS EXISTS. The old map was six hardcoded numbers copied from
-- HoDLootTracker and never checked against a client. 1,538 rolls out of a real
-- log say it is inverted, and the game's own roll window confirmed two of them
-- directly: an Off-Spec need that rolled 6 and WON was recorded as a pass.
--
-- ⚠️ WHAT THIS CAN AND CANNOT PROVE. It proves the resolver keys on NAMES and
-- reports what it could not match. It CANNOT prove the client's real member
-- names are among the ones we recognise — the stub's enum is a fixture, not an
-- observation, and asserting otherwise would be exactly the mistake that put
-- the wrong numbers here in the first place. That is why an unmatched name is
-- carried out of the function and printed both in the diagnostics and on the
-- Loot Log window: in game, being wrong about the names is VISIBLE.
;(function()
  -- Names deliberately spelled several ways, because the one thing we control
  -- is being generous about spelling. The numbers are arbitrary AND SHUFFLED —
  -- if any of them leaked into an assertion, this test would be asserting the
  -- very thing the change removes.
  local fixture = {
    NoRoll             = 7,
    Pass               = 3,
    Greed              = 11,
    Transmogrification = 2,
    Disenchant         = 5,  -- NOT a real retail option; here only to prove it is REPORTED, not mapped
    NeedMainSpec       = 9,
    NeedOffSpec        = 4,
    SomethingNewIn122  = 42,
  }

  local map, source, unresolved = ns.BuildRollStates(fixture)
  check("the client's names are used when it has them", source == "enum", source)
  check("a need resolves by name, whatever its number", map[9] == "need", tostring(map[9]))
  check("an OFF-SPEC need is its own value now", map[4] == "need_offspec", tostring(map[4]))
  check("transmog resolves under its long spelling", map[2] == "transmog", tostring(map[2]))
  check("greed resolves", map[11] == "greed", tostring(map[11]))
  check("pass resolves", map[3] == "pass", tostring(map[3]))
  -- ⚠️ DISENCHANT IS NOT MAPPED, ON PURPOSE. The API still returns
  -- canDisenchant, but the option is not offered in retail: false in all 43 roll
  -- windows of a real log, while need/greed/transmog all vary. It was mapped for
  -- a few minutes on the strength of the API field alone, which is the "the
  -- surface outlived the feature" trap. Unmapped means REPORTED, so if it ever
  -- comes back we find out from the client rather than from a guess.
  check("disenchant is NOT given an invented label", map[5] == nil, tostring(map[5]))
  check("...it is reported as unmatched instead",
        table.concat(unresolved, ","):find("Disenchant=5", 1, true) ~= nil,
        table.concat(unresolved, ","))

  -- The whole point: the OLD numbers must carry no weight at all. Under the old
  -- map 2 was greed and 3 was transmog; here they are transmog and pass.
  check("the inherited numbers no longer mean anything",
        map[2] ~= "greed" and map[3] ~= "transmog",
        "if this fails the resolver is still keying on numbers")

  -- An unrecognised member is NAMED, not swallowed. This is the mechanism that
  -- makes a future rename visible instead of silent.
  local reported = table.concat(unresolved, ",")
  check("an unrecognised state name is reported, with its number",
        reported:find("SomethingNewIn122=42", 1, true) ~= nil, reported)
  check("...and it is not given a label", map[42] == nil, tostring(map[42]))

  -- ── The branch that actually matters ─────────────────────────────────────
  -- If the client names nothing, we know nothing new, so behaviour must not
  -- change on no evidence — and the fallback must ANNOUNCE itself.
  local fbMap, fbSource = ns.BuildRollStates(nil)
  check("with no enum at all, the fallback map is used", fbSource == "inherited", fbSource)

  -- ⚠️ THIS ASSERTION USED TO PIN THE OLD GUESSWORK (fbMap[2]=="greed" and
  -- fbMap[5]=="need") and would now FAIL, correctly. The fallback numbers were
  -- established in Session 255 from Blizzard's own generated API documentation
  -- on disk, corroborated by 1,322 recorded head-to-head rolls and a
  -- screenshotted LFR checked roll by roll. The fallback is no longer a guess,
  -- so it is pinned to the REAL values — all six of them, so a future edit
  -- cannot quietly reintroduce the swap.
  check("...and the fallback carries the real, documented numbers",
        fbMap[0] == "need" and fbMap[1] == "need_offspec" and fbMap[2] == "transmog"
        and fbMap[3] == "greed" and fbMap[4] == "noroll" and fbMap[5] == "pass",
        "fallback map has drifted from Enum.EncounterLootDropRollState")

  -- The specific inversion that caused the damage: passes filed as needs.
  check("...so a pass is never filed as a need again",
        fbMap[5] ~= "need" and fbMap[0] ~= "noroll")

  -- An enum full of names we do not recognise is no better than no enum.
  local _, alienSource, alienUnresolved = ns.BuildRollStates({ Wibble = 1, Wobble = 2 })
  check("an enum naming nothing we know falls back rather than emptying the map",
        alienSource == "inherited", alienSource)
  check("...and says which names it could not match", #alienUnresolved == 2, #alienUnresolved)

  -- An unmapped state is "unknown", never a default. Defaulting to "noroll" is
  -- how 531 passes came to be filed as needs with nobody able to tell.
  check("an unmapped state is unknown, not defaulted", ns.RollTypeFor(9999) == "unknown")
  check("a non-numeric state is unknown too", ns.RollTypeFor(nil) == "unknown")

  -- The source is reachable for the surfaces that report it.
  local liveSource = ns.RollStateSource()
  check("the map's source is queryable for the UI to report",
        liveSource == "enum" or liveSource == "inherited", tostring(liveSource))
end)()

header("GP cost — the price the panel puts beside an item")

-- ⚠️ THE EXPECTED VALUES ARE THE WEBSITE'S OWN, not the formula written out a
-- second time here. test/fixtures.lua carries a `prices` block generated by the
-- REAL computeGpCharge() (app/lib/epgp.ts) over the same constants the raid
-- export ships, so this is a parity check that happens to live in the smoke
-- harness rather than an assertion that the code agrees with itself.
--
-- It lives HERE and not in test/parity.lua because pricing needs the namespace
-- — Payload.lua and the static item table — and the parity harness deliberately
-- loads nothing but Scoring.lua.
;(function()
  local ok, fx = pcall(dofile, "test/fixtures.lua")
  local cases = ok and type(fx) == "table" and fx.prices or nil
  if not cases or type(cases.pricing) ~= "table" then
    -- ⚠️ A LOUD SKIP, NOT A FAILURE, AND NOT SILENCE.
    --
    -- test/fixtures.lua is GITIGNORED — it is generated from the running site,
    -- so it does not exist in CI, and CI runs this harness on every weekly data
    -- refresh. Failing here would break every release for a file that is not
    -- meant to be in the repo. Passing quietly would be worse: it would report
    -- 450 green checks while the one that proves the addon's prices match the
    -- website never ran.
    --
    -- Same shape as the Lua 5.1 compile check below, and for the same reason.
    io.write("\n  SKIP price parity — test/fixtures.lua is absent.\n")
    io.write("       This check does NOT run in CI (the fixture is generated, not committed).\n")
    io.write("       Locally:  curl -s localhost:3000/api/loot-advisor/parity-fixtures -o test/fixtures.lua\n\n")
    return
  end

  -- The constants arrive the way they do in game: inside the stored payload.
  local live = ns.Payload.Current()
  local restore = live and live.gp
  if live then live.gp = cases.pricing end

  -- Synthetic item records, so the matrix is not tied to whichever items happen
  -- to be in this season's payload. Ids are far outside the real range.
  local data = ns.Data()
  local synthetic = {}
  local nextID = 990001

  local mismatch, compared, priced = nil, 0, 0
  for _, c in ipairs(cases) do
    local id = nextID
    nextID = nextID + 1
    synthetic[#synthetic + 1] = id
    data.items[id] = { name = c.name, slot = c.slot, tokenSlot = c.tokenSlot }

    local got = ns.Payload.Price(id, c.ilvl)
    compared = compared + 1
    if c.gp == nil then
      if got ~= nil then
        mismatch = mismatch or ("%s @ %d: expected no price, got %s")
          :format(c.slot, c.ilvl, tostring(got))
      end
    else
      priced = priced + 1
      if got == nil then
        mismatch = mismatch or ("%s @ %d: expected %.4f, got nothing"):format(c.slot, c.ilvl, c.gp)
      elseif math.abs(got - c.gp) > 1e-6 then
        mismatch = mismatch or ("%s @ %d: expected %.4f, got %.4f"):format(c.slot, c.ilvl, c.gp, got)
      end
    end
  end

  check(("every GP price matches the website (%d cases)"):format(compared),
        mismatch == nil, mismatch)
  -- Not vacuous: an empty fixture, or one whose every case expects nil, would
  -- otherwise pass while proving nothing.
  check("...and the matrix actually priced things", priced > 0, priced)

  -- ilvl 0 is "the client has not resolved this item yet". A price of zero
  -- would be a lie dressed as data; nothing is the honest answer.
  check("an unresolved item has no price", ns.Payload.Price(synthetic[1], 0) == nil)

  -- A slot with no weight cannot be priced. Omitting it is the point — see
  -- buildPricing(), which drops a slot rather than defaulting it to 1.0.
  data.items[999900] = { name = "Test Tabard", slot = "TABARD" }
  check("a slot the config does not price returns nothing",
        ns.Payload.Price(999900, 305) == nil)

  -- A dungeon or world-boss drop has no record of ours at all. It can still be
  -- priced when the caller supplies the slot, which is what makes the price
  -- work outside the raid loot table.
  check("an item we have never imported is priced from a supplied slot",
        ns.Payload.Price(999999, 305, "HEAD") ~= nil)
  check("...and without a slot it is not priced at all",
        ns.Payload.Price(999999, 305) == nil)

  -- The formatted form, which is what the panel actually shows.
  check("the price renders as whole GP",
        ns.Payload.PriceText(synthetic[1], 305) ~= nil
          and ns.Payload.PriceText(synthetic[1], 305):match("^%d+ GP$") ~= nil,
        tostring(ns.Payload.PriceText(synthetic[1], 305)))

  -- WITH NO PRICING BLOCK THERE IS NO PRICE. An export made before this shipped
  -- carries no `gp` key, and the panel must show nothing rather than fall back
  -- to a constant of its own.
  if live then
    live.gp = nil
    check("an export with no pricing block yields no price",
          ns.Payload.Price(synthetic[1], 305) == nil)
    live.gp = restore
  end

  for _, id in ipairs(synthetic) do data.items[id] = nil end
  data.items[999900] = nil
end)()

header("Patterns and housing decor are not loot — but unknown GEAR still is")

;(function()
  stub.itemClass = {
    [900001] = 4,   -- an armour piece we have never imported
    [900002] = 2,   -- a weapon we have never imported
    [900003] = 9,   -- Recipe — "Pattern: Adorned Fang"
    [900004] = 15,  -- Miscellaneous — housing decor
    [900005] = 0,   -- Consumable
  }

  -- ⚠️ THE RULE THIS MUST NOT BREAK (Data Contract §0): an item we never
  -- imported still appears, so a real upgrade can never go invisible because
  -- our table was incomplete. The test is the GAME'S item class, never our own
  -- ignorance.
  check("an unknown ARMOUR piece is still gear", ns.IsGearItem(900001, nil))
  check("an unknown WEAPON is still gear", ns.IsGearItem(900002, nil))
  check("a profession pattern is not", ns.IsGearItem(900003, nil) == false)
  check("housing decor is not", ns.IsGearItem(900004, nil) == false)
  check("a consumable is not", ns.IsGearItem(900005, nil) == false)

  -- ⚠️ TIER TOKENS ARE "MISCELLANEOUS" TO BLIZZARD. Filtering on class alone
  -- would drop every tier token off the loot table, which is the opposite of
  -- helpful — so anything in OUR payload counts as gear whatever its class.
  check("a tier token survives despite being Miscellaneous",
        ns.IsGearItem(900004, { name = "Venomwoven Idol", slot = "TOKEN" }))

  -- FAILS OPEN: an extra row is visibly wrong and fixable; a missing one is
  -- invisible and costs somebody an upgrade.
  local savedInstant = _G.GetItemInfoInstant
  _G.GetItemInfoInstant = nil
  check("with no way to ask the client, everything counts as gear",
        ns.IsGearItem(900003, nil))
  _G.GetItemInfoInstant = function() error("client refused") end
  check("...and an erroring client does the same", ns.IsGearItem(900003, nil))
  _G.GetItemInfoInstant = savedInstant

  stub.itemClass = nil
end)()

header("Auto-open fires even when the rest of the roll handler breaks")

;(function()
  local savedScore, savedPanel = ns.Loot.ScoreItem, ns.Panel
  local savedGet = ns.Settings.Get

  local shown = 0
  ns.Panel = { Show = function() shown = shown + 1 end, Refresh = function() end }
  ns.Settings.Get = function(key)
    if key == "autoOpen" then return true end
    return savedGet(key)
  end

  -- Everything after the open throws.
  ns.Loot.ScoreItem = function() error("deliberate failure below the open") end

  local ok = pcall(ns.Loot.HandleRoll, { itemID = 270160, name = "Anything" })
  check("the handler still fails loudly rather than swallowing the error", not ok)
  check("...and the panel opened ANYWAY, before the failure", shown == 1, shown)

  -- And the ordinary path still opens exactly once, not twice.
  ns.Loot.ScoreItem = savedScore
  shown = 0
  pcall(ns.Loot.HandleRoll, { itemID = 270160, name = "Anything" })
  check("a healthy roll opens it exactly once", shown == 1, shown)

  -- With the setting off it must stay shut — nobody is opted in by an update.
  ns.Settings.Get = function(key)
    if key == "autoOpen" then return false end
    return savedGet(key)
  end
  shown = 0
  pcall(ns.Loot.HandleRoll, { itemID = 270160, name = "Anything" })
  check("with the setting off it never opens", shown == 0, shown)

  ns.Loot.ScoreItem, ns.Panel, ns.Settings.Get = savedScore, savedPanel, savedGet
end)()

-- ── Is the panel drawing on whole pixels? ───────────────────────────────────
--
-- The arithmetic behind "it looks blurry". Blizzard's PixelUtil defines the
-- conversion; ns.DisplayReport applies it. Covered here because the readout is
-- the thing that tells Jason whether a font size is landing on a pixel or
-- between two, and a readout that lies is worse than none.

header("Pixel alignment — the arithmetic behind a blurry panel")

;(function()
  local realGPSS = _G.GetPhysicalScreenSize

  -- The defining property: at scale 768/height, one UI unit IS one pixel. If
  -- this ever stops holding, the readout's advice is wrong at every size.
  local exact = true
  for _, h in ipairs({ 768, 1080, 1440, 1794, 2160, 2880 }) do
    _G.GetPhysicalScreenSize = function() return h, h end
    local r = ns.DisplayReport(768 / h)
    if not r or math.abs(r.pixelsPerUnit - 1) > 1e-9 or not r.aligned then exact = false end
  end
  check("at the pixel-perfect scale one unit is exactly one pixel, at every height", exact)

  -- ⚠️ THE BUG THIS FILE CAUGHT. `local a, b = f and f()` adjusts to ONE value,
  -- so the height arrived nil and every report said "no screen size". Pinned so
  -- a tidy-up cannot reintroduce it.
  _G.GetPhysicalScreenSize = function() return 3440, 1440 end
  local r = ns.DisplayReport(1)
  check("both screen dimensions survive the call", r ~= nil and r.screenWidth == 3440 and r.screenHeight == 1440,
        r and (r.screenWidth .. "x" .. tostring(r.screenHeight)) or "nil report")

  check("an unaligned scale is REPORTED as unaligned, not rounded away",
        r and r.aligned == false, r and tostring(r.aligned))
  check("...and it says which scale would fix it", r and math.abs(r.perfectScale - 768 / 1440) < 1e-9)

  -- Every named size is measured, so none can drift unnoticed.
  check("every role in the type scale is measured", r and #r.sizes == 5, r and #r.sizes)

  -- A client that cannot answer must produce nil, not a confident wrong number.
  _G.GetPhysicalScreenSize = nil
  check("a client with no screen size reports nothing rather than guessing",
        ns.DisplayReport(1) == nil)
  check("...and the readout says so in words",
        ns.Settings.DisplayLine(nil):find("did not report", 1, true) ~= nil,
        ns.Settings.DisplayLine(nil))

  -- The wording branches: aligned vs not. Both must be reachable and truthful.
  _G.GetPhysicalScreenSize = function() return 2560, 1440 end
  local sharp = ns.Settings.DisplayLine(ns.DisplayReport(768 / 1440))
  local soft  = ns.Settings.DisplayLine(ns.DisplayReport(1))
  check("an aligned client is told it is as sharp as it gets",
        sharp:find("whole pixels", 1, true) ~= nil, sharp)
  check("an unaligned client is told text lands between pixels",
        soft:find("BETWEEN pixels", 1, true) ~= nil, soft)

  -- ⚠️ THE READOUT SHIPPED OVERLAPPING THE LAST SETTING'S HELP TEXT. It was
  -- given no band in the window height, and WoW frames do not clip children, so
  -- nothing errored — it simply drew on top. Height is derived, so assert that
  -- every band is in the sum and that adding a setting still moves it.
  -- ⚠️ THE HEIGHT IS CAPPED NOW AND THE CONTENT SCROLLS (Jason, Session 258:
  -- "the settings page is comically large… I just built it that height in Figma
  -- to show all the pieces"). So the old assertion — that the window grows with
  -- the settings and still leaves a band for the readout — describes a window
  -- that no longer exists. What has to hold instead is that the CONTENT grows
  -- while the WINDOW stays inside the panel's own height.
  local h = ns.Settings.WindowHeight()
  local content = ns.Settings.ContentHeight()
  local rows = #ns.Settings.SPEC
  check("the content height grows with the number of settings",
        content > rows * 40, content)
  check("...while the window never exceeds the addon window's 600", h <= 600, h)
  check("...and the readout and footer still have their bands",
        h - 128 - 58 - 48 > 0, h)
  -- The cap only means something if there is genuinely more content than room.
  check("...with more content than fits, so the scroll is load-bearing",
        content > h - 128 - 58 - 48, ("content %d, room %d"):format(content, h - 234))

  -- ── Snapping to whole pixels ──────────────────────────────────────────────
  -- The fix, not just the diagnosis. Every window routes through MakeWindow,
  -- which asks PixelSnapScale for a scale that lands units on whole pixels.
  -- ⚠️ SNAPPING IS NOW ALLOWED TO DECLINE, and that is the contract this block
  -- tests. It used to assert that every combination snapped; it now asserts the
  -- two properties that actually matter — when it snaps the result is aligned,
  -- and it NEVER resizes the window by more than a tenth. A snap that moves the
  -- window 20% is not snapping, and it is what made the panel massively larger
  -- than the frame it was drawn from.
  local everyInteger, neverZero, neverResizes = true, true, true
  local worst = 0
  for _, h in ipairs({ 1080, 1440, 1794, 1800, 2160, 2880, 4320 }) do
    for _, ps in ipairs({ 0.4, 0.5, 0.64, 0.65, 0.71, 0.8, 1.0 }) do
      _G.GetPhysicalScreenSize = function() return math.floor(h * 16 / 9), h end
      local own, target = ns.PixelSnapScale(ps)
      if own then
        if target < 1 or target ~= math.floor(target) then neverZero = false end
        local out = ns.DisplayReport(ps * own)
        if not out or not out.aligned then everyInteger = false end
        -- own IS the size multiplier: it is what SetScale receives.
        local drift = math.abs(own - 1)
        if drift > worst then worst = drift end
        if drift > 0.10 then neverResizes = false end
      end
    end
  end
  check("when it snaps, the result lands on whole pixels", everyInteger)
  check("...and never collapses a window below one pixel per unit", neverZero)
  check("...and never resizes a window by more than a tenth",
        neverResizes, ("worst drift: %.1f%%"):format(worst * 100))

  -- ⚠️ JASON'S OWN CLIENT, PINNED. 1800 physical rows at ~0.711 gives 1.667
  -- pixels per unit, which rounds to 2 and would make every window 20% bigger
  -- than drawn. It must decline rather than snap.
  _G.GetPhysicalScreenSize = function() return 2880, 1800 end
  check("a 1.667 px/unit client is left alone rather than grown 20%",
        ns.PixelSnapScale(768 / 1800 * (5 / 3)) == nil)

  -- ...while the case the rule was WRITTEN for still snaps: 4K at the default
  -- scale is 1.83 -> 2, a 9% move, and the crispness is worth it.
  _G.GetPhysicalScreenSize = function() return 3840, 2160 end
  check("a 1.83 px/unit client still snaps, because 9% is affordable",
        ns.PixelSnapScale(0.65) ~= nil)

  -- ⚠️ SetScale is RELATIVE to the parent. Returning the DESIRED effective scale
  -- instead of the own-scale would double-apply the parent's and shrink every
  -- window. Pinned: at parent scale 0.65 on 4K the answer must be 2 px/unit.
  _G.GetPhysicalScreenSize = function() return 3840, 2160 end
  local own, target = ns.PixelSnapScale(0.65)
  check("the returned scale is relative to the parent, not absolute",
        target == 2 and math.abs(0.65 * own - 2 * (768 / 2160)) < 1e-9,
        ("target=%s own=%.4f"):format(tostring(target), own or -1))

  -- A client that cannot answer must leave the window alone rather than guess.
  _G.GetPhysicalScreenSize = nil
  check("with no screen size the window is left at whatever it inherited",
        ns.PixelSnapScale(0.65) == nil)
  _G.GetPhysicalScreenSize = function() return 3840, 2160 end
  check("a nonsense parent scale is refused rather than dividing by zero",
        ns.PixelSnapScale(0) == nil and ns.PixelSnapScale(nil) == nil)

  _G.GetPhysicalScreenSize = realGPSS
end)()

-- ── Every file compiles under the Lua the GAME runs ─────────────────────────
--
-- ⚠️ WOW IS LUA 5.1 AND THE luac ON A DEV MACHINE IS NOT. Session 250 shipped a
-- Panel.lua that `luac -p` passed and the game REFUSED: as one function, build()
-- closed over more than 60 upvalues, which is a hard limit in 5.1 and was raised
-- to 255 in 5.2. The file never compiled, ns.Panel was never set, and /la
-- answered "panel did not load" — with the whole addon otherwise working, so
-- nothing pointed at the panel.
--
-- Every file-scope constant a function references costs one upvalue, so this is
-- a limit a growing builder crosses silently and a modern parser will never
-- mention. Checked here for EVERY file, not just the window ones.
--
-- Skipped rather than failed when no 5.1 parser is installed: this must not
-- block the harness on a machine without luajit, but a skip is REPORTED so the
-- absence of the check is never mistaken for the check passing.

header("Every file compiles under Lua 5.1 — the version the game runs")

;(function()
  local probe = io.popen("luajit -v 2>/dev/null")
  local version = probe and probe:read("*a") or ""
  if probe then probe:close() end

  if not version:match("LuaJIT") then
    io.write("  SKIP no Lua 5.1 parser found — install luajit to enable this check\n")
    io.write("       (brew install luajit). The game is 5.1; a 5.4/5.5 luac is not\n")
    io.write("       evidence, and this is the check that would have caught the\n")
    io.write("       60-upvalue limit that stopped Panel.lua loading in Session 250.\n")
    return
  end

  local FILES = {
    "LootData.lua", "Style.lua", "Scoring.lua", "Core.lua", "Settings.lua",
    "Payload.lua", "Diagnostics.lua", "Comms.lua", "Roster.lua", "Journal.lua",
    "Targets.lua", "Tooltip.lua", "Record.lua", "Loot.lua",
    -- THE WINDOW FILES ESPECIALLY. Nothing else in this harness loads them, so
    -- without this they reach the game entirely unparsed.
    "LoadWindow.lua", "RecordWindow.lua", "Panel.lua", "MinimapButton.lua",
  }

  for _, path in ipairs(FILES) do
    local pipe = io.popen(("luajit -bl %q 2>&1 >/dev/null"):format(path))
    local err = pipe and pipe:read("*a") or "could not run luajit"
    if pipe then pipe:close() end
    check(("%s compiles under 5.1"):format(path), err == "",
          err ~= "" and (err:gsub("%s+$", "")) or nil)
  end

  -- ── Headroom against the 200-local ceiling ────────────────────────────────
  --
  -- ⚠️ "IT COMPILES" IS NOT THE SAME AS "THERE IS ROOM TO ADD A LINE", and the
  -- difference is a whole file the game refuses. Panel.lua reached EXACTLY 200
  -- top-level locals in Session 258: it compiled, every 5.4 test passed, and the
  -- next constant anyone declared would have failed the file in game with no
  -- syntax error to point at — the S250 failure mode, where a file that never
  -- compiles reports as a MISSING MODULE.
  --
  -- So this measures the margin rather than the pass. It probes by prepending
  -- throwaway locals and asking luajit, which is the only parser here that
  -- counts the way the client does.
  local MARGIN = 5
  local function headroom(path, want)
    local src = io.open(path):read("a")
    local probe = ("local __hr%d = %d\n"):rep(want):format(
      table.unpack((function() local t = {} for i = 1, want * 2 do t[i] = i end return t end)()))
    local tmp = os.tmpname() .. ".lua"
    local fh = io.open(tmp, "w"); fh:write(probe .. src); fh:close()
    local pipe = io.popen(("luajit -bl %q 2>&1 >/dev/null"):format(tmp))
    local err = pipe and pipe:read("*a") or ""
    if pipe then pipe:close() end
    os.remove(tmp)
    return not err:match("200 local variables")
  end

  for _, path in ipairs(FILES) do
    check(("%s has room for %d more top-level locals"):format(path, MARGIN),
          headroom(path, MARGIN),
          "at the Lua 5.1 ceiling — group new constants into a table "
            .. "(see SL / RAIL / FOOT in Panel.lua) rather than adding names")
  end
end)()

-- ── Every helper the window files call actually exists ──────────────────────
--
-- ⚠️ THE WINDOW FILES SHIP HAVING NEVER RUN. No harness loads Panel.lua,
-- LoadWindow.lua or RecordWindow.lua — stubbing enough of WoW's widget API to
-- build them would test the stub — so a misremembered helper name in one of them
-- is invisible until it errors in front of the raid.
--
-- This does not run them. It READS them, pulls out every `ns.Thing(` and
-- `ns.Thing.Other(` they call, and checks the name is really on the namespace.
-- That catches the single most likely fault in an untested file — calling
-- something that does not exist — without pretending to test the drawing.
--
-- Deliberately restricted to CALLS. Data fields are populated lazily
-- (Payload.byName only exists once a payload has loaded), so requiring those to
-- be present here would fail on a namespace that is behaving correctly.

header("Window files reference only helpers that exist")

;(function()
  -- The three files no harness loads, and which therefore cannot be on the
  -- namespace while this runs.
  local DEFERRED = { Panel = true, LoadWindow = true, RecordWindow = true }

  local WINDOWS = { "Panel.lua", "LoadWindow.lua", "RecordWindow.lua", "MinimapButton.lua" }

  for _, path in ipairs(WINDOWS) do
    local fh = io.open(path, "r")
    if not fh then
      check(("%s can be read"):format(path), false, "not found")
    else
      local src = fh:read("*a")
      fh:close()

      -- Strip comments first: this file's own prose names helpers it does not
      -- call, and a doc comment mentioning a renamed function should not fail
      -- a build.
      src = src:gsub("%-%-%[%[.-%]%]", " "):gsub("%-%-[^\n]*", " ")

      local missing, seen = {}, {}
      -- Two levels: ns.Foo( and ns.Foo.Bar(
      for a, b in src:gmatch("ns%.([%a_][%w_]*)%.([%a_][%w_]*)%s*%(") do
        local key = a .. "." .. b
        if not seen[key] and not DEFERRED[a] then
          seen[key] = true
          local parent = ns[a]
          if type(parent) ~= "table" then
            missing[#missing + 1] = key .. " (ns." .. a .. " is " .. type(parent) .. ")"
          elseif parent[b] == nil then
            missing[#missing + 1] = key
          end
        end
      end
      for a in src:gmatch("ns%.([%a_][%w_]*)%s*%(") do
        if not seen[a] and not DEFERRED[a] then
          seen[a] = true
          if ns[a] == nil then missing[#missing + 1] = a end
        end
      end

      check(("%s calls no helper that is missing"):format(path), #missing == 0,
            #missing > 0 and table.concat(missing, ", ") or nil)
      -- Not vacuous: a file whose scan found nothing would pass silently.
      check(("...and the scan actually found calls in %s"):format(path),
            next(seen) ~= nil)
    end
  end
end)()

-- ── Result ──────────────────────────────────────────────────────────────────

io.write("\n", ("═"):rep(72), "\n")
if #failures == 0 then
  io.write(("PASS — %d checks\n"):format(checks))
  os.exit(0)
end
io.write(("FAIL — %d of %d checks\n\n"):format(#failures, checks))
for _, f in ipairs(failures) do io.write("  · ", f, "\n") end
os.exit(1)
