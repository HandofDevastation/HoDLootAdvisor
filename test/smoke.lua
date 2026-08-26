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
  "Diagnostics.lua", "Comms.lua", "Journal.lua", "Targets.lua", "Tooltip.lua",
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

-- ── Eligibility ─────────────────────────────────────────────────────────────
-- The case that prompted this layer: a Cloth tier token was scored a Major
-- upgrade for a Hunter, because scoring has no opinion about armor types.

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

-- ── Degrading loudly ────────────────────────────────────────────────────────

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

-- ── Cross-raider ranking ────────────────────────────────────────────────────

header("/la who — ranking the whole roster")

stub.Slash("who " .. chestId .. " h")

local ranked, all, meta = ns.Loot.RankRaiders(chestId, { difficulty = "h" })
check("the ranking returns rows once a payload is loaded", ranked ~= nil)

if ranked then
  check("every roster member was considered", #all == 24, #all)
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

-- Two drops off one boss. The first is a contested Need roll; the second is a
-- pass-fallthrough, which the site counts differently from a real win and which
-- therefore has to survive the round trip intact.
stub.lootHistory[2849] = {
  stub.drop(1, 270160, "Sunfury Chestguard", { 12841 }, {
    { name = "Vörnix",     state = 5, roll = 87, isWinner = true },
    { name = "Dåmir",      state = 5, roll = 42 },
    { name = "Mîrâñ",      state = 2, roll = 61 },
    { name = "Brambleÿ",  state = 1, roll = 0 },
    { name = "Gloomrift",  state = 0, roll = 0 },
  }),
  stub.drop(2, 270161, "Voidscarred Greaves", { 12841 }, {
    { name = "Corvá",  state = 1, roll = 55, isWinner = true },
    { name = "Dåmir",  state = 1, roll = 0 },
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
      chest and chest.rolls["Vörnix"] and chest.rolls["Vörnix"].state == 5)
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
    { name = "Dåmir", state = 5, roll = 91, isWinner = true },
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

check("the run records which character was playing",
      run and run.character == "Gloomrift", run and run.character)

stub.player.name = "Vörnix"
stub.lootHistory[2850] = {
  stub.drop(1, 270160, "Sunfury Chestguard", { 12841 }, {
    { name = "Vörnix", state = 5, roll = 73, isWinner = true },
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
-- THREE instances exist in the fixture; the WORLD BOSS container is excluded, so
-- the browse catalogue offers two. Nobody puts a world boss drop on a watch list
-- (Jason, Session 244).
check("raids AND dungeons both enumerate", #instances == 2,
      ("%d instances"):format(#instances))

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

-- ── The Journal probe ───────────────────────────────────────────────────────
--
-- The probe exists to ANSWER what the Encounter Journal API is, not to assume
-- it — two wrong recollections have already cost real time here. It is kept
-- SEPARATE from the browse path above for exactly that reason: the browse path
-- is built on what the probe found, and the probe must stay able to contradict
-- it on a client where the answer has changed.

header("JOURNAL PROBE")

local okProbe, probeResult = pcall(ns.Journal.Probe)
check("the probe runs against a present API", okProbe,
      not okProbe and tostring(probeResult) or nil)
check("...and reports what it found rather than a fixed list",
      okProbe and #probeResult.present > 0 and #probeResult.absent > 0,
      okProbe and ("%d present / %d absent"):format(#probeResult.present, #probeResult.absent))
check("...enumerating DUNGEONS separately from raids — the whole question",
      okProbe and probeResult.Raids.count == 2 and probeResult.Dungeons.count == 1,
      okProbe and ("%d raids / %d dungeons"):format(
        probeResult.Raids.count, probeResult.Dungeons.count))
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
local savedEJ = {}
for _, name in ipairs({
  "EJ_GetNumTiers", "EJ_GetCurrentTier", "EJ_SelectTier", "EJ_GetInstanceByIndex",
  "EJ_SelectInstance", "EJ_GetEncounterInfoByIndex", "EJ_SelectEncounter",
  "EJ_GetNumLoot", "EJ_SetLootFilter", "EJ_GetLootFilter", "EJ_ResetLootFilter",
  "EJ_GetTierInfo", "EJ_GetInstanceInfo",
}) do
  savedEJ[name], _G[name] = _G[name], nil
end
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

local registered = 0
for _, n in ipairs(UISpecialFrames) do
  if n == "HoDLootAdvisorTestWindow" then registered = registered + 1 end
end
check("...and Escape closes it, via UISpecialFrames", registered == 1)

-- A duplicate entry would have Blizzard hide the same frame twice per press.
ns.MakeWindow(win)
registered = 0
for _, n in ipairs(UISpecialFrames) do
  if n == "HoDLootAdvisorTestWindow" then registered = registered + 1 end
end
check("registering twice does not duplicate the entry", registered == 1)

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
            { { name = "Gloomrift", state = 5, roll = 50, isWinner = true } }),
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

local guildBefore = select(2, R.Counts("guild"))
stub.instance.instanceType = "none"          -- back in a city
check("we are genuinely outside an instance now", select(2, GetInstanceInfo()) == "none")

stub.lootHistory[2849][#stub.lootHistory[2849] + 1] =
  stub.drop(3, 270162, "Venom-Drenched Sack", { 12841 }, {
    { name = "Mîrâñ", state = 5, roll = 66, isWinner = true },
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
    { name = "Gloomrift", state = 5, roll = 0 },
    { name = "Dröokz",    state = 5, roll = 0 },
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
    { name = "Gloomrift", state = 5, roll = 41 },
    { name = "Dröokz",    state = 5, roll = 93, isWinner = true },
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

  check("BIS outranks a grade in the tag, matching the scorer's strongest-wins",
        ns.QualityTag({ grade = "c", bis = "overall" }) == "BIS",
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
  local EXPECTED = {
    bg = "0d0d14", bgAlt = "13131f", elevated = "1a1a2e", border = "2a2a45",
    text = "e8e8f0", textDim = "9090b0", textMuted = "606080",
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

  check("BIS uses the hot-pink token, not the unreadable gold",
        hexOf(S.COLOR.hotPink) == "ff0080" and S.COLOR.hotPink ~= S.COLOR.gold)

  -- The escape code is what colours chat and tooltip text; an off-by-one in the
  -- rounding shows up as a subtly wrong colour nobody can trace.
  check("colour escape codes round-trip", S.code(S.COLOR.hotPink) == "|cffff0080",
        S.code(S.COLOR.hotPink))
  check("...including a channel that rounds up", S.code(S.COLOR.gold) == "|cfff3c56b",
        S.code(S.COLOR.gold))

  local r, g, b = S.rgb(S.COLOR.green)
  check("rgb() unpacks to three channels in 0-1",
        math.abs(r - 0x20 / 255) < 1e-6 and math.abs(g - 0xba / 255) < 1e-6
        and math.abs(b - 0x56 / 255) < 1e-6)
  check("rgb() with no colour falls back rather than erroring", select("#", S.rgb(nil)) == 3)

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

-- ── Result ──────────────────────────────────────────────────────────────────

io.write("\n", ("═"):rep(72), "\n")
if #failures == 0 then
  io.write(("PASS — %d checks\n"):format(checks))
  os.exit(0)
end
io.write(("FAIL — %d of %d checks\n\n"):format(#failures, checks))
for _, f in ipairs(failures) do io.write("  · ", f, "\n") end
os.exit(1)
