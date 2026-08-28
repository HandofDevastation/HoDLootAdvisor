-- Record.lua — the structured loot log
--
-- WHAT THIS IS FOR. Every drop and every roll of a raid night, captured from
-- C_LootHistory and exported in the SAME HODLOOT_EXPORT_V1 format the site
-- already imports (app/lib/loot-export.ts). It is a STRUCTURED BACKUP, not a
-- replacement: HoDLootTracker keeps running unchanged, and the site's import
-- dedupes on session_id + item_name|boss|character_name, so importing both
-- exports of one night is harmless by construction. That dedupe is the entire
-- safety argument for writing a second recorder at all.
--
-- WHY IT IS TRACTABLE. C_LootHistory.GetSortedDropsForEncounter(encounterID)
-- returns EVERY drop from a kill, each carrying rollInfos[] =
-- { playerName, playerGUID, playerClass, isSelf, state, isWinner, roll } —
-- which is very nearly loot_records.roll_data already. A SINGLE client
-- enumerates a whole kill, so this needs no comms and no adoption.
--
-- HOW IT DIFFERS FROM HoDLootTracker, which is the reason it is worth having:
-- the tracker builds its picture INCREMENTALLY from LOOT_HISTORY_UPDATE_DROP,
-- so anything it was not listening for is simply absent — a /reload mid-roll,
-- a late load, an event missed under load. This re-enumerates the WHOLE
-- encounter repeatedly and upserts, so the final state is whatever the client
-- believes at the end, not whatever we happened to witness.
--
-- ⚠️ TAINT. C_LootHistory is marked SecretArguments = "AllowedWhenUntainted".
-- Every read of it goes through pcall and every value is coerced to a plain
-- scalar before it is stored, exactly as Diagnostics.lua does. Losing a value
-- is acceptable; erroring mid-raid is not.

local ADDON_NAME, ns = ...

local Record = {}
ns.Record = Record

-- Epic+ by DEFAULT. Matches HoDLootTracker's MINIMUM_QUALITY so the two exports
-- of one night contain the same rows, and matches what the site's parser accepts
-- through its quality>=4 path.
--
-- It is a SETTING because it is also the only thing standing between you and
-- testing the recorder outside a raid: a follower dungeon or a delve drops
-- BLUES, so at the default threshold everything is correctly and silently
-- declined — which reads exactly like the addon being broken. Session 243, first
-- live run: the capture path worked perfectly and the quality gate rejected a
-- rare-quality vial, in both this addon and HoDLootTracker at once.
--
-- ⚠️ Lowering it has a real consequence, not just a test one: the site's parser
-- admits any Armor/Weapon row regardless of quality, so blues WOULD import if
-- they reached a guild export. What contains that is the auto-tag — a solo or
-- 5-man run is tagged Personal and Personal is excluded from the bulk export.
local function minQuality()
  local v = ns.Settings and ns.Settings.Get("minQuality")
  return tonumber(v) or 4
end

-- Enum.EncounterLootDropRollState -> the export's roll-type string.
--
-- MIRRORED VERBATIM from HoDLootTracker, deliberately, and NOT re-derived: the
-- two addons export the same night into the same table, and a mapping that
-- disagreed would put the same roll in two different cohorts depending on which
-- export happened to be imported first.
--
-- It is also safe against getting the enum wrong, which matters because these
-- numbers cannot be verified outside a live raid. The site classifies a roll by
-- rollType AND rollValue TOGETHER (rules/HoD_Rules_Loot-Gear.txt, "LOOT ROLL
-- COHORT DEFINITIONS"): anything with rollValue > 0 that is not greed/transmog/
-- pass is the Need cohort, so 'need' and 'noroll' land in the SAME bucket. The
-- distinctions that actually carry weight are 'pass' (counted even at value 0)
-- and greed/transmog — and those three are unambiguous.
--
-- The raw numeric state is kept on each roll in SavedVariables (never exported)
-- so the first real raid night answers empirically what these states are, the
-- same instrument-what-you-cannot-verify approach as Diagnostics.lua.
local ROLL_STATE = {
  [0] = "noroll",
  [1] = "pass",
  [2] = "greed",
  [3] = "transmog",
  [4] = "need",   -- NeedOffSpec
  [5] = "need",   -- NeedMainSpec
}

-- ---------------------------------------------------------------------------
-- Reading values that might bite
-- ---------------------------------------------------------------------------

local function safeIndex(t, key)
  if type(t) ~= "table" then return nil end
  local ok, v = pcall(function() return t[key] end)
  if not ok then return nil end
  return v
end

local function asString(v) return type(v) == "string" and v or nil end
local function asNumber(v) return type(v) == "number" and v or nil end
local function asBool(v) return v == true end

local function stripRealm(name)
  if not name then return nil end
  return name:match("^([^%-]+)") or name
end

-- ---------------------------------------------------------------------------
-- Field sanitising
-- ---------------------------------------------------------------------------
--
-- The export is a flat ~-delimited format, so a delimiter appearing INSIDE a
-- value shifts every field after it and the site parses garbage without
-- erroring. Character names cannot contain these characters, but boss and
-- instance names come from the client and are localized, so they are cleaned
-- rather than trusted.

local function clean(s)
  return (tostring(s or ""):gsub("[\r\n~]", " "))
end

--- Names inside the roll summary, where ';' separates entries and ':' separates
--- that entry's own fields.
local function cleanName(s)
  return (clean(s):gsub("[;:]", ""))
end

-- ---------------------------------------------------------------------------
-- The log
-- ---------------------------------------------------------------------------

local function lootDB()
  local d = ns.db
  if not d then return nil end
  if type(d.loot) ~= "table" then d.loot = { sessions = {} } end
  if type(d.loot.sessions) ~= "table" then d.loot.sessions = {} end
  return d.loot
end
Record.DB = lootDB

local currentBoss, currentEncounterID
local encounterNames = {}    -- loot-history encounterID -> boss name, when we can tell
local knownEncounters = {}   -- every encounter id C_LootHistory has handed us
local encounterSession = {}  -- encounterID -> the session table its drops belong to
local reportedScan = {}      -- encounter ids already noted in the diagnostic log
local sessionRef             -- the session table we are currently appending to

--- Set only by Record.Inject, so a fabricated drop can land somewhere while
--- standing in a city. Never set by any real capture path.
local injectContext

-- ---------------------------------------------------------------------------
-- Why a capture did not become a record
-- ---------------------------------------------------------------------------
--
-- A SILENT DECLINE IS INDISTINGUISHABLE FROM A BROKEN ADDON. That cost an hour
-- on the first live night (Session 243): a blue drop in a follower dungeon was
-- correctly rejected by the quality gate, in this addon and HoDLootTracker at
-- once, and the only observable outcome was "nothing was recorded" — which is
-- exactly what a genuine failure looks like.
--
-- So every rejection is now COUNTED and LOGGED with its reason. /la loot status
-- reports them without needing a /reload, which turns the next mystery into a
-- one-line answer instead of a log-reading session.

Record.declined = {}

local function decline(reason, detail)
  Record.declined[reason] = (Record.declined[reason] or 0) + 1
  if ns.Diagnostics then
    detail = detail or {}
    detail.reason = reason
    ns.Diagnostics.Note("lootDeclined", detail)
  end
  return false
end

--- The raw instanceType string, for reporting WHY the instance gate said no.
--- Deliberately unvalidated: the point is to record what the client actually
--- says, including for instance kinds nobody has checked yet.
local function currentInstanceType()
  local _, instanceType = GetInstanceInfo()
  return instanceType or "none"
end

--- Who is playing. SavedVariables are ACCOUNT-wide, so every character writes
--- into one log — which is what you want for guild loot, and which makes the
--- recording character part of a run's identity rather than an afterthought.
--- Without it, two characters clearing the same instance at the same difficulty
--- on the same day would merge into one run: separate lockouts, separate loot,
--- silently collapsed into a single session.
local function whoAmI()
  local name = UnitName and UnitName("player")
  local realm = GetRealmName and GetRealmName()
  return name or "?", realm
end

--- Instance context, or nil when we are not somewhere loot should be recorded.
--- This is the questing-noise gate: outside an instance there is no session, so
--- there is nothing to append to.
local function instanceContext()
  if injectContext then return injectContext end
  local name, instanceType, difficultyID, difficultyName, _, _, _, instanceID = GetInstanceInfo()
  if instanceType ~= "raid" and instanceType ~= "party" and instanceType ~= "scenario" then
    return nil
  end
  local character, realm = whoAmI()
  return {
    instance     = name or "Unknown",
    instanceID   = instanceID or 0,
    difficulty   = difficultyName or "Unknown",
    difficultyID = difficultyID or 0,
    character    = character,
    realm        = realm,
  }
end

-- ---------------------------------------------------------------------------
-- Guild vs personal
-- ---------------------------------------------------------------------------
--
-- A solo dungeon run and a guild raid night are both "loot", and mixing them
-- costs twice: the site's loot history fills with drops no guild event produced,
-- and a personal history worth keeping cannot be kept separately from one that
-- gets wiped after every import.
--
-- The tag is AUTO-SET and always OVERRIDABLE. Auto is right most nights and
-- wrong often enough — alt runs, guild dungeon nights — that a manual toggle is
-- not optional. Once set by hand it is never re-derived, or the automatic rule
-- would silently undo the correction the toggle exists to make.

Record.GUILD, Record.PERSONAL = "guild", "personal"

--- EVERY RUN STARTS PERSONAL (Session 245, Jason's call). Guild is opt-in, via
--- the window's "Mark Guild" button.
---
--- WHAT THIS REPLACES, and why guessing was abandoned rather than improved:
--- the rule used to be IsInRaid(), i.e. "a raid-sized group means the guild ran
--- it". Season 2's first day produced two counter-examples in one afternoon — an
--- LFR wing and a world boss, both auto-tagged guild, together worth 33 rows of
--- world-boss currency and a pug's drops in the site's loot history. Excluding
--- those two difficulties would have been a patch on a premise that was wrong
--- anyway: group SIZE never implied the group was ours. A pug Normal clear would
--- still have sailed through, and a guild LFR clear would still have needed a
--- manual flip in the other direction.
---
--- THE ASYMMETRY IS THE WHOLE ARGUMENT. A guild run mistakenly left Personal
--- costs one button press, and the run is sitting in the window with its tag
--- visible. A pug run mistakenly marked Guild reaches loot_records, which EPGP
--- re-derives charges from — so the cheap error is the one to default to.
---
--- Nothing here reads guild membership. UnitIsInMyGuild() would in principle
--- support a smarter rule, but an auto-tag that is right most of the time is
--- exactly what put the wrong rows in front of the raid to begin with.
local function autoKind()
  return Record.PERSONAL
end

--- Lowering the quality threshold is a TESTING move — it exists so a delve or a
--- follower dungeon records something. Carrying it into a raid is the version
--- that costs: raid trash drops blues, a raid group auto-tags GUILD, and Guild
--- runs are exactly what goes into the website's loot history. So the moment a
--- GUILD run starts with the threshold below Epic, say so, once per run.
---
--- A warning rather than a refusal: it is a legitimate thing to want, and
--- silently overriding the runner's setting is how a tool loses trust.
local function warnLoweredThreshold(s)
  if not s or s.warnedQuality then return end
  if (s.kind or Record.GUILD) ~= Record.GUILD then return end
  local q = minQuality()
  if q >= 4 then return end
  s.warnedQuality = true
  ns.Warn(("recording down to quality %d in a GUILD run — raid trash blues will be"):format(q))
  ns.Line("recorded and included in Export Guild Loot. |cffF3C56B/la set minQuality 4|r restores Epic-only.")
end

--- The session to append to, creating one if needed. nil outside an instance.
---
--- An existing tail session is REUSED when the date, instance and difficulty all
--- match. HoDLootTracker starts a fresh session on every zone-in, so a night with
--- three /reloads exports as three SESSION blocks for one raid; matching on those
--- three fields collapses them while still treating a difficulty change as the
--- genuinely different session it is.
local function session()
  local db = lootDB()
  if not db then return nil end
  local ctx = instanceContext()
  if not ctx then return nil end

  local today = date("%Y-%m-%d")

  -- The CHARACTER is part of a run's identity, not just a label on it. Two of
  -- your own characters running the same instance at the same difficulty on the
  -- same day are two runs with two lockouts, and merging them would attribute
  -- one character's drops to the other's session.
  local function matches(s)
    return s and s.date == today
      and s.instanceID == ctx.instanceID
      and s.difficultyID == ctx.difficultyID
      and (s.character or ctx.character) == ctx.character
  end

  --- There used to be an auto-UPGRADE here: a run that started personal became
  --- guild the moment a raid group formed around it. That existed to cover
  --- zoning in alone to check something, and it goes away with the auto rule it
  --- depended on — now that every run starts personal, promoting on group size
  --- would silently re-introduce exactly the guess that was just removed.
  --- Guild is set in ONE place only: Record.SetKind, from the window's button.
  local function reconcile(s)
    warnLoweredThreshold(s)
    return s
  end

  if matches(sessionRef) then return reconcile(sessionRef) end

  local tail = db.sessions[#db.sessions]
  if matches(tail) then
    sessionRef = tail
    return reconcile(tail)
  end

  local s = {
    date         = today,
    timestamp    = time(),
    instance     = ctx.instance,
    instanceID   = ctx.instanceID,
    difficulty   = ctx.difficulty,
    difficultyID = ctx.difficultyID,
    character    = ctx.character,
    realm        = ctx.realm,
    kind         = ctx.kind or autoKind(),
    kindManual   = false,
    items        = {},
  }
  db.sessions[#db.sessions + 1] = s
  sessionRef = s
  warnLoweredThreshold(s)
  return s
end

--- A kill's drops belong to the run that was current WHEN THE BOSS DIED, not to
--- whatever run is current when a rescan happens to land. The encounter is bound
--- to its session the first time we see it, and every later scan writes back
--- into that same table.
---
--- This is not a nicety. The follow-up scan ladder runs out to four minutes
--- after a kill, by which time you may well have left the instance — and
--- GetInstanceInfo then reports nothing, so an unbound scan would find no
--- session and quietly drop the winner it was waiting for. It also stops a
--- character swap from re-filing the previous character's drops into the new
--- one's run, which is what an alt clearing the same raid on the same day would
--- otherwise do.
local function sessionForEncounter(encounterID)
  local bound = encounterSession[encounterID]
  if bound then return bound end
  local s = session()
  if s then encounterSession[encounterID] = s end
  return s
end

--- Entries carry their own key, so the index is rebuilt by scanning rather than
--- held in a separate table — which is what makes a /reload mid-raid cost
--- nothing. A session is a few dozen items; this is not worth optimising.
local function findEntry(s, key)
  for _, e in ipairs(s.items) do
    if e.key == key then return e end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Item info
-- ---------------------------------------------------------------------------

--- Name / quality / item level / type for a link.
---
--- The item level comes from GetDetailedItemLevelInfo FIRST, because that is the
--- level the item actually dropped at — GetItemInfo's is the base level, and for
--- an upgraded raid drop the two differ by a whole track. This is strictly better
--- data than HoDLootTracker records, and is the one place the two exports will
--- legitimately disagree.
---
--- Every field may be nil: item data arrives asynchronously and a scan seconds
--- after the kill can see an uncached item. Callers refresh on later scans.
local function itemInfo(link)
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not getInfo or not link then return {} end
  local ok, name, _, quality, ilvl, _, itemType = pcall(getInfo, link)
  if not ok then return {} end
  return {
    name     = asString(name),
    quality  = asNumber(quality),
    ilvl     = ns.DetailedIlvl(link) or asNumber(ilvl),
    itemType = asString(itemType),
  }
end

--- Fill in anything the client could not answer when the drop was captured.
---
--- Item data loads ASYNCHRONOUSLY. A drop read moments after a kill — or any
--- personal loot, which is never rescanned — can come back with no name at all,
--- and the entry then keeps the "item:270160" placeholder forever. That is what
--- the review window was showing: a list of item numbers, useless to a human,
--- and it would have exported those numbers as the item name too.
---
--- Returns true when something was filled in.
function Record.RefreshItemInfo(e)
  if not e then return false end

  local needsName = (e.itemName or ""):match("^item:%d+$") ~= nil
  local needsRest = (e.itemILevel or 0) == 0 or (e.itemQuality or 0) == 0
    or (e.itemType or "") == ""
  if not needsName and not needsRest then return false end

  -- Ask the client to load it, so a later pass can answer even if this one
  -- cannot. Guarded: the API name has moved between namespaces before.
  if e.itemID and C_Item and C_Item.RequestLoadItemDataByID then
    pcall(C_Item.RequestLoadItemDataByID, e.itemID)
  end

  local meta = itemInfo(e.itemLink or (e.itemID and ("item:" .. e.itemID)))
  local changed = false
  if needsName and meta.name then e.itemName = meta.name; changed = true end
  if (e.itemQuality or 0) == 0 and meta.quality then e.itemQuality = meta.quality; changed = true end
  if (e.itemILevel or 0) == 0 and meta.ilvl then e.itemILevel = meta.ilvl; changed = true end
  if (e.itemType or "") == "" and meta.itemType then e.itemType = meta.itemType; changed = true end
  return changed
end

--- Sweep the whole log for unresolved item data. Cheap — a few dozen entries,
--- all cache hits after the first pass — and called before anything DISPLAYS or
--- EXPORTS, which are the two places a placeholder name would do damage.
function Record.ResolveItemInfo()
  local db = lootDB()
  local fixed = 0
  for _, s in ipairs((db or {}).sessions or {}) do
    for _, e in ipairs(s.items) do
      if Record.RefreshItemInfo(e) then fixed = fixed + 1 end
    end
  end
  return fixed
end

--- The boss this drop belongs to. ENCOUNTER_END is authoritative (it is the only
--- source of the localized encounter NAME); the baked payload is a cross-check
--- for the case where the loot-history encounter id turns out to be the Blizzard
--- journal id, which is the one thing about this API no documentation settles.
local function bossNameFor(encounterID)
  local named = encounterNames[encounterID]
  if named then return named end
  local data = ns.Data()
  local boss = data and (data.bosses or {})[encounterID]
  if boss and boss.name then return boss.name end
  return currentBoss
end

-- ---------------------------------------------------------------------------
-- Capture — group loot
-- ---------------------------------------------------------------------------

--- Upsert one EncounterLootDropInfo into the current session.
--- Returns true when the drop was recorded or refreshed.
local function upsertDrop(encounterID, info)
  local link = asString(safeIndex(info, "itemHyperlink"))
  if not link then return false end

  local parsed = ns.ParseItemLink(link)
  if not parsed then return false end

  local meta = itemInfo(link)
  -- nil quality means the item is not cached yet — record it and let a later
  -- scan resolve it. Filtering on unknown data would silently lose a drop.
  if meta.quality and meta.quality < minQuality() then
    return decline("below the quality threshold",
      { item = meta.name or parsed.itemID, quality = meta.quality, threshold = minQuality() })
  end

  local s = sessionForEncounter(encounterID)
  if not s then
    return decline("not somewhere loot is recorded",
      { instanceType = currentInstanceType(), encounterID = encounterID })
  end

  local lootListID = asNumber(safeIndex(info, "lootListID"))
  local key = ("g%s:%s"):format(tostring(encounterID), tostring(lootListID or parsed.itemID))

  -- A HAND-DELETED DROP MUST STAY DELETED. The follow-up scan ladder keeps
  -- re-enumerating an encounter for four minutes after the kill, and this path
  -- re-appends anything it does not already find — so deleting a row during that
  -- window would silently undo itself. Counted like every other refusal, because
  -- a resurrection that quietly does not happen is still a thing the log should
  -- be able to explain.
  if s.deleted and s.deleted[key] then
    return decline("deleted by hand", { item = meta.name or parsed.itemID, key = key })
  end

  local e = findEntry(s, key)

  if not e then
    e = {
      key         = key,
      lootListID  = lootListID,
      itemID      = parsed.itemID,
      -- Kept so the review window can show the REAL tooltip — the version that
      -- actually dropped, bonus IDs and all — rather than one rebuilt from the
      -- selected difficulty. Never exported: the format carries names, and a
      -- link's pipes would zero the whole export string in an EditBox.
      itemLink    = link,
      bonusIDs    = table.concat(parsed.bonusIDs, ":"),
      itemName    = meta.name or ("item:" .. parsed.itemID),
      itemQuality = meta.quality or 0,
      itemILevel  = meta.ilvl or 0,
      itemType    = meta.itemType or "",
      isGroupLoot = true,
      rolls       = {},
      timestamp   = time(),
      boss        = bossNameFor(encounterID) or "Unknown",
      -- The EXPORT's encounter id is the journal id from ENCOUNTER_END, which is
      -- what pairs with the boss NAME. The loot-history id is only a fallback,
      -- for the case where a drop is seen without an ENCOUNTER_END (a /reload
      -- after the kill, or an addon loaded mid-raid).
      encounterID = currentEncounterID or encounterID or 0,
    }
    s.items[#s.items + 1] = e
  end

  -- Refresh anything that was not resolvable on an earlier pass.
  if meta.name and e.itemName:match("^item:%d+$") then
    e.itemName = meta.name
  end
  if meta.quality and (e.itemQuality or 0) == 0 then e.itemQuality = meta.quality end
  if meta.ilvl and (e.itemILevel or 0) == 0 then e.itemILevel = meta.ilvl end
  if meta.itemType and (e.itemType or "") == "" then e.itemType = meta.itemType end
  if (e.boss == "Unknown" or not e.boss) then e.boss = bossNameFor(encounterID) or "Unknown" end
  if (e.encounterID or 0) == 0 then e.encounterID = currentEncounterID or encounterID or 0 end

  -- Rolls arrive incrementally, so this REPLACES each roller's entry rather than
  -- accumulating: the last thing the client tells us about a player is the true
  -- one, and a player can change their mind before the window closes.
  local rollInfos = safeIndex(info, "rollInfos")
  if type(rollInfos) == "table" then
    for i = 1, #rollInfos do
      local r = rollInfos[i]
      local name = asString(safeIndex(r, "playerName"))
      if name and name ~= "" then
        local state = asNumber(safeIndex(r, "state"))
        e.rolls[name] = {
          rollType  = ROLL_STATE[state or -1] or "noroll",
          rollValue = asNumber(safeIndex(r, "roll")) or 0,
          isWinner  = asBool(safeIndex(r, "isWinner")),
          -- Kept, never exported: the empirical answer to what these states
          -- really are in 12.1. See the ROLL_STATE comment.
          state     = state,
        }
      end
    end
  end

  -- The winner is nil until the roll window closes, which is why a single scan
  -- at ENCOUNTER_END is not enough and the follow-up ladder below exists.
  local winnerName = asString(safeIndex(safeIndex(info, "winner"), "playerName"))
  if not winnerName and type(rollInfos) == "table" then
    for i = 1, #rollInfos do
      if asBool(safeIndex(rollInfos[i], "isWinner")) then
        winnerName = asString(safeIndex(rollInfos[i], "playerName"))
        break
      end
    end
  end

  if winnerName and winnerName ~= "" then
    e.winnerFull = winnerName
    e.winner     = stripRealm(winnerName)
    local wr     = e.rolls[winnerName]
    if wr then
      e.winRollType  = wr.rollType
      e.winRollValue = wr.rollValue
    end
    -- A winner we cannot attribute a roll to still gets recorded. The site reads
    -- the roll cohort from roll_data, so an unknown win type costs a label, not
    -- the record.
    if not e.winRollType then
      e.winRollType  = "noroll"
      e.winRollValue = 0
    end

    -- IN-NIGHT CORRECTION (Experience §2.6, capability 7). Whoever just won this
    -- stops being a candidate for that slot for the rest of the night.
    --
    -- DERIVED LOCALLY, WITH NO MESSAGE. C_LootHistory reports the whole
    -- encounter to every client in the group, so each one reaches this same
    -- conclusion independently — which is exactly why the correction also
    -- covers raiders who have NOT installed the addon. Nothing here depends on
    -- them self-reporting, and a broadcast would only add a way for two clients
    -- to disagree about a fact they can both already see.
    --
    -- Called on every rescan rather than once: NoteWin refuses to downgrade, so
    -- repeating it is idempotent and the retry costs a table lookup.
    if ns.Comms and e.itemID then
      ns.Comms.NoteWin(e.winner, e.itemID, { ilvl = e.itemILevel })
    end
  end

  return true
end

-- ---------------------------------------------------------------------------
-- Capture — personal loot
-- ---------------------------------------------------------------------------
--
-- ENCOUNTER_LOOT_RECEIVED fires for everything the server hands out, group loot
-- included, so it is the only path that sees personal/push loot at all.
--
-- The de-duplication against a group drop is deliberately loose — same item, same
-- winner, this session — because it CANNOT be exact: our group entries are keyed
-- in C_LootHistory's encounter id space and this event reports the journal one.
-- Anything that slips through is absorbed by the site's own dedupe on
-- item_name|boss|character_name, which is precisely why that safety net is worth
-- leaning on rather than inventing a stricter key that could drop a real drop.

local function alreadyRecordedAsGroupWin(s, itemID, winner)
  for _, e in ipairs(s.items) do
    if e.isGroupLoot and e.itemID == itemID and e.winner and e.winner == winner then
      return true
    end
  end
  return false
end

function Record.OnEncounterLoot(encounterID, itemID, itemLink, _quantity, playerName)
  itemID = asNumber(tonumber(itemID))
  itemLink = asString(itemLink)
  playerName = asString(playerName)
  if not itemID or itemID == 0 or not itemLink or not playerName or playerName == "" then
    return false
  end

  local meta = itemInfo(itemLink)
  if meta.quality and meta.quality < minQuality() then
    return decline("below the quality threshold",
      { item = meta.name or itemID, quality = meta.quality, threshold = minQuality() })
  end

  local s = session()
  if not s then
    return decline("not somewhere loot is recorded",
      { instanceType = currentInstanceType(), encounterID = encounterID })
  end

  local short = stripRealm(playerName)
  if alreadyRecordedAsGroupWin(s, itemID, short) then return false end

  local key = ("p%s:%s:%s"):format(tostring(encounterID or 0), tostring(itemID), tostring(playerName))
  if findEntry(s, key) then return false end
  -- Same tombstone rule as the group path. Personal loot is captured once and
  -- never rescanned today, so this cannot currently fire — it is here because
  -- the two paths sharing one delete must not diverge the day that changes.
  if s.deleted and s.deleted[key] then
    return decline("deleted by hand", { item = meta.name or itemID, key = key })
  end

  local parsed = ns.ParseItemLink(itemLink)

  s.items[#s.items + 1] = {
    key          = key,
    itemID       = itemID,
    itemLink     = itemLink,
    bonusIDs     = parsed and table.concat(parsed.bonusIDs, ":") or "",
    itemName     = meta.name or ("item:" .. itemID),
    itemQuality  = meta.quality or 0,
    itemILevel   = meta.ilvl or 0,
    itemType     = meta.itemType or "",
    isGroupLoot  = false,
    rolls        = {},
    winner       = short,
    winnerFull   = playerName,
    winRollType  = "personal",
    winRollValue = 0,
    timestamp    = time(),
    boss         = bossNameFor(encounterID) or "Unknown",
    encounterID  = currentEncounterID or encounterID or 0,
  }
  return true
end

-- ---------------------------------------------------------------------------
-- Scanning
-- ---------------------------------------------------------------------------

--- Enumerate one encounter and upsert everything it reports.
--- Returns how many drops the client had for it.
function Record.ScanEncounter(encounterID)
  if encounterID == nil then return 0 end
  local hist = C_LootHistory
  local fn = hist and hist.GetSortedDropsForEncounter
  if type(fn) ~= "function" then return 0 end

  local ok, drops = pcall(fn, encounterID)
  if not ok or type(drops) ~= "table" then return 0 end

  local n = 0
  for i = 1, #drops do
    if upsertDrop(encounterID, drops[i]) then n = n + 1 end
  end

  -- WHICH ID SPACE ACTUALLY WORKS is the one thing no source settles, so the
  -- first id that returns drops is recorded once, with whether it came from
  -- ENCOUNTER_END or from a LOOT_HISTORY_* event.
  if n > 0 and not reportedScan[encounterID] and ns.Diagnostics then
    reportedScan[encounterID] = true
    ns.Diagnostics.Note("lootScan", {
      encounterID    = encounterID,
      drops          = n,
      isEncounterEnd = encounterID == currentEncounterID,
      boss           = bossNameFor(encounterID),
    })
  end

  return n
end

--- Re-enumerate every encounter this client has been told about.
function Record.ScanAll()
  local total = 0
  for id in pairs(knownEncounters) do
    total = total + Record.ScanEncounter(id)
  end
  return total
end

local function remember(encounterID)
  if encounterID ~= nil then knownEncounters[encounterID] = true end
end

-- A coalesced scan. Loot-history events fire once per player per roll, so
-- scanning on each one would re-enumerate an encounter dozens of times for no
-- new information.
local pendingScan = false
local function bump(delay)
  if not (C_Timer and C_Timer.After) then
    Record.ScanAll()
    return
  end
  if pendingScan then return end
  pendingScan = true
  C_Timer.After(delay or 2, function()
    pendingScan = false
    Record.ScanAll()
  end)
end

-- After a kill the winner is unknown until the roll window closes, and the
-- window can run to two minutes. These are cheap table walks over one
-- encounter, so the ladder runs long rather than risk exporting a night of
-- drops with no winners on them.
local FOLLOW_UPS = { 15, 45, 90, 150, 240 }

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

local frame = CreateFrame("Frame")

local WATCHED = {
  "ENCOUNTER_END",
  "ENCOUNTER_LOOT_RECEIVED",
  "LOOT_HISTORY_UPDATE_DROP",
  "LOOT_HISTORY_UPDATE_ENCOUNTER",
  "LOOT_HISTORY_GO_TO_ENCOUNTER",
  "PLAYER_ENTERING_WORLD",
}

-- Same guard Diagnostics uses and for the same reason: registering a name this
-- client does not know raises an error, and one wrong guess must not take the
-- recorder down with it.
for _, event in ipairs(WATCHED) do
  pcall(frame.RegisterEvent, frame, event)
end

--- Re-seed the live encounter index from drops we already recorded but never
--- resolved a WINNER for, and say how many were found.
---
--- WHY THIS EXISTS. The follow-up scan ladder runs to four minutes after a kill,
--- and a /reload inside that window used to lose every still-pending winner
--- permanently: PLAYER_ENTERING_WORLD wipes knownEncounters, so ScanAll() then
--- iterates nothing and `/la loot scan` has no ids to retry. Six real drops from
--- the 2026-08-18 world boss were lost exactly this way — the kill was at
--- 13:36:22, the reload at 13:39:07, and the 240s scan never fired.
---
--- ⚠️ THE ID MUST COME FROM THE ROW'S KEY, NOT FROM e.encounterID. The stored
--- encounterID is the JOURNAL id (it is what pairs with the boss name); the key
--- is built as "g<loot-history id>:<lootListID>", and the loot-history id is the
--- only one GetSortedDropsForEncounter understands. Seeding the journal id would
--- look correct, scan nothing, and report success.
---
--- Re-seeding is SAFE when the history really is gone (a genuine zone change):
--- ScanEncounter simply returns 0. And a re-scan cannot duplicate rows, because
--- upsertDrop matches on that same key and updates in place.
local function reseedUnresolved()
  local db = lootDB()
  if not db then return 0 end
  local seeded = 0
  for _, s in ipairs(db.sessions or {}) do
    for _, e in ipairs(s.items or {}) do
      if e.isGroupLoot and (e.winner == nil or e.winner == "") then
        local id = tonumber(tostring(e.key or ""):match("^g(%-?%d+):"))
        if id and not knownEncounters[id] then
          knownEncounters[id] = true
          seeded = seeded + 1
        end
      end
    end
  end
  return seeded
end

frame:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_ENTERING_WORLD" then
    -- Loot history is cleared on a zone change, so the ids we know are stale.
    -- The RECORDS persist; only the live index resets.
    sessionRef = nil
    knownEncounters = {}
    encounterSession = {}
    reportedScan = {}

    -- ...but a drop still missing its winner is worth one more ask. On a reload
    -- the client's loot history is usually still there, which is precisely the
    -- case the wipe above would otherwise make unrecoverable.
    local seeded = reseedUnresolved()
    if seeded > 0 then
      if ns.Diagnostics then
        ns.Diagnostics.Note("lootReseed", { encounters = seeded, event = event })
      end
      bump(5)
    end
    return
  end

  if event == "ENCOUNTER_END" then
    local encounterID, encounterName, _difficultyID, _groupSize, success = ...
    if success ~= 1 then return end
    currentBoss        = encounterName
    currentEncounterID = encounterID
    if encounterID ~= nil and encounterName then
      encounterNames[encounterID] = encounterName
    end
    -- The journal id is a CANDIDATE for the loot-history id space, not a known
    -- member of it. Remembering it costs one failed lookup if the spaces differ
    -- and buys the whole kill if they do not.
    remember(encounterID)
    bump(5)
    if C_Timer and C_Timer.After then
      for _, delay in ipairs(FOLLOW_UPS) do
        C_Timer.After(delay, function() Record.ScanAll() end)
      end
    end
    return
  end

  if event == "ENCOUNTER_LOOT_RECEIVED" then
    Record.OnEncounterLoot(...)
    return
  end

  -- The three LOOT_HISTORY_* events all hand us an encounter id as their first
  -- argument. That is the id space GetSortedDropsForEncounter actually speaks,
  -- learned from the client rather than assumed.
  local encounterID = ...
  remember(encounterID)
  bump(2)
end)

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Dev injection
-- ---------------------------------------------------------------------------
--
-- Group loot does not fire in dungeons, delves are personal loot, and a raid
-- lockout makes a real roll a weekly event — so without this the review window
-- cannot be looked at until a boss has actually died in a raid.
--
-- It drives the REAL upsert path with a fabricated EncounterLootDropInfo, which
-- is the same compromise /la test makes for the loot panel: only the API READ is
-- replaced, so everything downstream — the roll mapping, the winner resolution,
-- the export — is the code that will run for real. What it CANNOT tell you is
-- what C_LootHistory really returns in a raid. That is the diagnostic log's job.
--
-- The run it creates is tagged PERSONAL and named so it cannot be mistaken for
-- real data, which also keeps it out of the guild export by default.

-- Accented on purpose: an ASCII test roster is what let the payload byte-length
-- bug through in Session 242.
local INJECT_POOL = {
  { "Vörnix", "PALADIN" }, { "Dåmir", "MAGE" },     { "Mîrâñ", "WARRIOR" },
  { "Brambleÿ", "DRUID" }, { "Corvá", "ROGUE" },   { "Gloomrift", "HUNTER" },
  { "Totekahn", "SHAMAN" }, { "Cupcake", "PRIEST" }, { "Virstrina", "WARLOCK" },
}

-- The states worth generating, and how often. Need dominates because that is
-- what a contested drop looks like; pass is common enough to produce the
-- all-passed fallthrough case on its own every so often, which is the one the
-- site counts differently from a real win.
local INJECT_STATES = { 5, 5, 5, 4, 2, 2, 3, 1, 1, 0 }

local injectSeeded = false
local injectCounter = 0

--- Rolls for one fabricated drop: a random handful of the pool, random states,
--- random values, and the highest non-pass roll wins. Every injection differs,
--- so the review window fills with something that reads like a real night rather
--- than the same five rows repeated.
local function injectRolls()
  if not injectSeeded then
    math.randomseed(time())
    injectSeeded = true
  end

  -- Shuffle a copy, then take the first few.
  local pool = {}
  for i, p in ipairs(INJECT_POOL) do pool[i] = p end
  for i = #pool, 2, -1 do
    local j = math.random(i)
    pool[i], pool[j] = pool[j], pool[i]
  end

  local count = math.random(3, 6)
  local rollInfos = {}
  for i = 1, count do
    local state = INJECT_STATES[math.random(#INJECT_STATES)]
    rollInfos[i] = {
      playerName  = pool[i][1],
      playerClass = pool[i][2],
      state       = state,
      -- A pass is usually value 0, but CAN carry one: that is the fallthrough
      -- auto-roll, and the display has to handle both.
      roll        = (state == 1) and 0 or math.random(1, 100),
      isWinner    = false,
      isSelf      = false,
    }
  end

  -- Highest roll wins. If everyone passed, one of them takes it on a
  -- fallthrough auto-roll — nobody competed, and the site must not count it as
  -- a competitive win.
  local best
  for _, r in ipairs(rollInfos) do
    if r.state ~= 1 and (not best or r.roll > best.roll) then best = r end
  end
  if not best then
    best = rollInfos[math.random(#rollInfos)]
    best.roll = math.random(1, 100)
  end
  best.isWinner = true

  return rollInfos, best
end

--- Fabricate a drop and push it through the real recorder.
--- `itemID` defaults to something from the baked payload so the tooltip is real.
function Record.Inject(itemID)
  local data = ns.Data()
  if not itemID then
    -- Any real item from the payload, chosen deterministically so repeated
    -- injections build a run rather than one row over and over.
    local ids = {}
    for id in pairs((data or {}).items or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    if #ids == 0 then
      ns.Warn("no item data loaded — cannot inject.")
      return false
    end
    local n = 0
    local db = lootDB()
    for _, s in ipairs((db or {}).sessions or {}) do n = n + #s.items end
    itemID = ids[(n % #ids) + 1]
  end

  local rollInfos, winner = injectRolls()

  local character = whoAmI()
  -- A synthetic context, so a fabricated drop has somewhere to land while
  -- standing in a city. instanceContext() returns this for exactly one call.
  injectContext = {
    instance     = "Injected Test Run",
    instanceID   = 0,
    difficulty   = "Test Data",
    difficultyID = 0,
    character    = character,
    kind         = Record.PERSONAL,
  }

  local link = ns.ItemLinkFor(itemID)
  -- A unique lootListID per injection, so repeated calls build a run rather than
  -- upserting over the same row. time() alone repeats within one second.
  injectCounter = (injectCounter or 0) + 1
  local ok = upsertDrop(-1, {
    lootListID    = (time() % 100000) * 100 + injectCounter,
    itemHyperlink = link,
    rollInfos     = rollInfos,
    winner        = winner,
    allPassed     = false,
  })

  injectContext = nil

  if not ok then
    ns.Warn("injection did not record — item " .. tostring(itemID) .. " may not be in the payload.")
    return false
  end

  local rec = data and (data.items or {})[itemID]
  ns.Print(("injected a fake drop: %s — %d rollers, %s won with %d."):format(
    (rec and rec.name) or ("item " .. itemID),
    #rollInfos, winner.playerName, winner.roll))
  ns.Line("It is tagged |cff7BA7C9Personal|r and named 'Injected Test Run' so it stays out of the guild export.")
  if ns.Diagnostics then
    ns.Diagnostics.Note("lootInject", { itemID = itemID })
  end
  return true
end

--- Pretend a piece of loot just dropped for you, HERE, NOW, through the REAL
--- recording path — no fabricated context anywhere.
---
--- DISTINCT FROM Record.Inject, and the distinction is the whole point. Inject
--- supplies its own synthetic instance context so it works while standing in a
--- city, which means it never touches the instance gate. This one goes through
--- GetInstanceInfo and the real session creation, so it answers the question a
--- follower dungeon spent an evening failing to answer for want of a drop:
--- whether this instance type records at all, and what the run looks like when
--- it does.
---
--- It writes a REAL record. That is deliberate — a test that wrote somewhere
--- else would prove something else — so it says so, loudly, and points at the
--- Delete Run button.
function Record.Fake(itemID)
  local data = ns.Data()
  if not itemID then
    -- An EPIC item from the payload, so the default quality threshold is not
    -- what stops it. Deterministic: the lowest id, every time.
    local ids = {}
    for id in pairs((data or {}).items or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    itemID = ids[1]
  end
  if not itemID then
    ns.Warn("no item data loaded — cannot fake a drop.")
    return false
  end

  local name, realm = whoAmI()
  local full = realm and (name .. "-" .. realm:gsub("%s+", "")) or name

  -- Snapshot the decline counters so we can report WHICH gate refused, rather
  -- than just "nothing happened" — the exact failure this command exists for.
  local before = {}
  for reason, n in pairs(Record.declined) do before[reason] = n end

  local ok = Record.OnEncounterLoot(
    currentEncounterID or 0, itemID, ns.ItemLinkFor(itemID), 1, full)

  local rec = data and (data.items or {})[itemID]
  local label = (rec and rec.name) or ("item " .. itemID)

  if ok then
    local db = lootDB()
    local s = db and db.sessions[#db.sessions]
    ns.Print(("recorded a fake drop of %s for %s."):format(label, full))
    if s then
      ns.Line(("Run: %s · %s · %s · tagged %s"):format(
        s.instance or "?", s.difficulty or "?", s.character or "?",
        (s.kind == Record.PERSONAL) and "|cff7BA7C9Personal|r" or "|cffF3C56BGuild|r"))
    end
    ns.Warn("this is a REAL record — delete the run in /la loot when you are done.")
    return true
  end

  ns.Warn(("%s was NOT recorded."):format(label))
  for reason, n in pairs(Record.declined) do
    if n > (before[reason] or 0) then
      ns.Line(("Refused because: |cffF3C56B%s|r"):format(reason))
      if reason:find("quality") then
        ns.Line(("  Threshold is %d. |cffF3C56B/la set minQuality 3|r to record blues.")
          :format(minQuality()))
      else
        ns.Line(("  GetInstanceInfo reports instanceType = |cffF3C56B%s|r."):format(
          currentInstanceType()))
        ns.Line("  Loot is only recorded in raid, party or scenario instances.")
      end
    end
  end
  return false
end

--- Every recorded session, newest first, each carrying its index into the stored
--- list so the review window can act on it (rename the tag, delete it) without
--- holding a reference that a delete would invalidate.
--- `filter` is "guild" | "personal" | nil for everything.
function Record.Sessions(filter)
  local db = lootDB()
  local out = {}
  for i, s in ipairs((db or {}).sessions or {}) do
    if not filter or (s.kind or Record.GUILD) == filter then
      out[#out + 1] = { index = i, session = s }
    end
  end
  table.sort(out, function(a, b)
    return (a.session.timestamp or 0) > (b.session.timestamp or 0)
  end)
  return out
end

-- ---------------------------------------------------------------------------
-- What has dropped TODAY (Session 250)
-- ---------------------------------------------------------------------------
--
-- WHY THE PANEL READS THE RECORDER AND NOT Loot.recent. The in-memory list is
-- built from roll events and is wiped by a /reload, so a raider who reloads
-- mid-raid loses the whole night's drops off the Loot tab while the recorder's
-- copy sits in SavedVariables untouched. Worse, the memory list never learns a
-- WINNER — the roll event fires when the window opens, and who won arrives
-- minutes later on a rescan that only the recorder is listening for.
--
-- So the drops list and "Won By" come from the same place, which is also the
-- only place that can answer both.
--
-- ⚠️ TODAY, BY DATE, NOT "THE CURRENT RUN". A raid that crosses local midnight
-- would split into two runs, and a strict current-run read would empty the tab
-- at 00:00 while people are still in the instance. Date is what the recorder
-- already keys a run on, so this matches what the Loot Log shows rather than
-- introducing a second notion of "tonight".

--- Today's drops, newest first. Each entry is the recorder's own, so it carries
--- whatever the recorder knows — including a winner once the roll has settled.
---
--- `bossID` scopes it to ONE encounter, which is what the panel's boss strip
--- selects. Every recorded drop carries the journal encounter id from
--- ENCOUNTER_END, the same id space the emitted payload keys its bosses by, so
--- this is a direct comparison and not a name match.
---
--- ⚠️ AN UNFILTERED LIST WAS THE BUG. The Loot tab showed every drop of the
--- night whichever boss was selected, so clicking through the strip changed
--- nothing and the panel looked stuck on the last kill. A boss you have not
--- killed must come back EMPTY — that is a fact about tonight, and showing
--- another boss's loot under its portrait is worse than showing none.
function Record.RecentDrops(limit, bossID)
  local db = lootDB()
  local today = date("%Y-%m-%d")
  local out = {}
  for _, s in ipairs((db or {}).sessions or {}) do
    if s.date == today then
      for _, e in ipairs(s.items or {}) do
        if not bossID or e.encounterID == bossID then out[#out + 1] = e end
      end
    end
  end
  -- Newest first. Entries within a run are appended in the order they were
  -- seen, so reversing is enough and there is no timestamp to sort on that
  -- every path sets.
  local rev = {}
  for i = #out, 1, -1 do
    rev[#rev + 1] = out[i]
    if limit and #rev >= limit then break end
  end
  return rev
end

--- Who won this item today, or nil while the roll is still open.
---
--- nil IS A REAL ANSWER AND MUST NOT BE DRESSED UP. "Nobody has won it yet" and
--- "we never found out" look identical from here, because nothing in the addon
--- registers that a roll ENDED — only that one started. Callers show the absence
--- rather than a countdown or a "pending" they cannot stand behind.
function Record.WinnerFor(itemID)
  if not itemID then return nil end
  for _, e in ipairs(Record.RecentDrops()) do
    if e.itemID == itemID and e.winner and e.winner ~= "" then
      return e.winner
    end
  end
  return nil
end

function Record.SetKind(index, kind)
  local db = lootDB()
  local s = db and db.sessions[index]
  if not s then return false end
  s.kind = (kind == Record.PERSONAL) and Record.PERSONAL or Record.GUILD
  -- From here the automatic rule never touches it again.
  s.kindManual = true

  -- The lowered-threshold warning used to fire when a GUILD run started, back
  -- when a run could start guild. Nothing starts guild any more, so THIS is the
  -- moment it has to happen: marking a run Guild is what makes it site-bound,
  -- and it is usually done after the raid, when no further drop will arrive to
  -- trigger the check on its own.
  if s.kind == Record.GUILD then warnLoweredThreshold(s) end
  return true
end

--- Remove ONE drop from a run, leaving the rest of the run intact.
---
--- This exists because `/la loot fake` writes a REAL record, deliberately — a
--- test that wrote somewhere else would prove something else — and until now the
--- only way to remove it was to delete the whole run, taking any genuine drops
--- recorded alongside it. Jason's test drop sat in a Delve run with three real
--- ones for exactly that reason.
---
--- The key is TOMBSTONED rather than merely removed, so the scan ladder cannot
--- re-add it; see the note in upsertDrop. Returns the removed entry, or nil.
function Record.DeleteItem(index, key)
  local db = lootDB()
  local s = db and db.sessions[index]
  if not s or not key then return nil end

  for i, e in ipairs(s.items) do
    if e.key == key then
      table.remove(s.items, i)
      s.deleted = s.deleted or {}
      s.deleted[key] = true
      return e
    end
  end
  return nil
end

function Record.DeleteSession(index)
  local db = lootDB()
  local s = db and db.sessions[index]
  if not s then return 0 end
  local n = #s.items
  table.remove(db.sessions, index)
  -- Any encounter still bound to the removed table would keep upserting into a
  -- session no longer in the log — writes that vanish with no error.
  for id, bound in pairs(encounterSession) do
    if bound == s then encounterSession[id] = nil end
  end
  -- The live append target may have been the row just removed, or may have
  -- shifted down by one. Dropping the reference costs one lookup on the next
  -- capture and cannot leave us writing into a deleted table.
  sessionRef = nil
  return n
end

--- The night's loot in HODLOOT_EXPORT_V1, byte-for-byte the format
--- app/lib/loot-export.ts parses. Sessions with no items are omitted.
---
--- opts = { kind = "guild"|"personal"|nil, index = <one session only> }.
--- Scope is what keeps a paste small: one raid night is ~7 KB where the whole
--- accumulated history is hundreds. It is also why the export is not compressed
--- — see rules/HoD_Rules_Loot-Gear.txt on LibDeflate and the repo licence.
---
--- PERSONAL SESSIONS ARE EXCLUDED unless asked for by name. The site's loot
--- history is a record of guild events; a solo dungeon run has no raid session
--- to attach to and would only ever be noise there.
function Record.Export(opts)
  opts = opts or {}
  local db = lootDB()
  if not db or #db.sessions == 0 then return nil end

  -- Last chance to turn a placeholder into a real name. The site matches loot by
  -- item_name, so exporting "item:270160" would create a row that can never be
  -- reconciled with anything.
  Record.ResolveItemInfo()

  local wanted = {}
  if opts.index then
    wanted[opts.index] = true
  else
    for i, s in ipairs(db.sessions) do
      local kind = s.kind or Record.GUILD
      if opts.kind == nil then
        wanted[i] = kind == Record.GUILD
      else
        wanted[i] = kind == opts.kind
      end
    end
  end

  local lines = { "HODLOOT_EXPORT_V1" }
  local items = 0

  for i, s in ipairs(db.sessions) do
    if wanted[i] and #s.items > 0 then
      lines[#lines + 1] = ("SESSION~%s~%d~%s~%d~%s~%d"):format(
        clean(s.date), s.timestamp or 0,
        clean(s.instance), s.instanceID or 0,
        clean(s.difficulty), s.difficultyID or 0)

      for _, item in ipairs(s.items) do
        local rollParts = {}
        for playerName, roll in pairs(item.rolls or {}) do
          rollParts[#rollParts + 1] = ("%s:%s:%d:%s"):format(
            cleanName(playerName), roll.rollType or "noroll",
            roll.rollValue or 0, roll.isWinner and "1" or "0")
        end
        -- pairs() has no defined order and an export is diffed by hand against
        -- the tracker's often enough to be worth keeping stable.
        table.sort(rollParts)

        lines[#lines + 1] = ("ITEM~%d~%s~%d~%d~%s~%s~%d~%s~%s~%d~%d~%s~%s"):format(
          item.timestamp or 0,
          clean(item.boss),
          item.encounterID or 0,
          item.itemID or 0,
          clean(item.itemName),
          clean(item.itemType),
          item.itemILevel or 0,
          cleanName(item.winner or ""),
          clean(item.winRollType or ""),
          item.winRollValue or 0,
          item.itemQuality or 0,
          item.bonusIDs or "",
          table.concat(rollParts, ";"))
        items = items + 1
      end
    end
  end

  if items == 0 then return nil end
  lines[#lines + 1] = "END_EXPORT"

  -- EditBox:SetText() silently zeroes a string containing a pipe, and this one
  -- is going straight into an EditBox. The format carries item NAMES rather than
  -- links so there should be none — which is exactly why stripping them costs
  -- nothing and covers the day something changes. (Loot-Gear rules, "HoDLootTracker
  -- EditBox bug".)
  return (table.concat(lines, "\n"):gsub("|", "")), items
end

--- sessions, items, withWinner — what the status line and the window report.
--- `filter` scopes it the same way Record.Sessions does.
function Record.Counts(filter)
  local db = lootDB()
  local sessions, items, won = 0, 0, 0
  for _, s in ipairs((db or {}).sessions or {}) do
    if not filter or (s.kind or Record.GUILD) == filter then
      if #s.items > 0 then sessions = sessions + 1 end
      for _, e in ipairs(s.items) do
        items = items + 1
        if e.winner and e.winner ~= "" then won = won + 1 end
      end
    end
  end
  return sessions, items, won
end

--- Wipe everything, or just one tag's worth. Deleting only the guild sessions
--- after an import is the expected housekeeping now that a personal history is
--- something worth keeping indefinitely.
function Record.Clear(filter)
  local db = lootDB()
  if not db then return 0 end
  local removed = 0
  for i = #db.sessions, 1, -1 do
    local s = db.sessions[i]
    if not filter or (s.kind or Record.GUILD) == filter then
      removed = removed + #s.items
      for id, bound in pairs(encounterSession) do
        if bound == s then encounterSession[id] = nil end
      end
      table.remove(db.sessions, i)
    end
  end
  sessionRef = nil
  return removed
end

function Record.Status()
  Record.ScanAll()
  local _, items, won = Record.Counts()
  if items == 0 then
    ns.Print("no loot recorded yet.")
    ns.Line("Recording starts on its own when a boss dies in a raid or dungeon.")
    -- The important half. "Nothing recorded" plus "3 items were below the
    -- quality threshold" is a completely different message from "nothing
    -- recorded" alone, and only one of them means something is wrong.
    if not Record.ReportDeclines() then
      ns.Line(("Nothing has been declined either — no loot has been seen at all. (%s)"):format(
        currentInstanceType()))
    end
    return
  end

  local gs, gi = Record.Counts(Record.GUILD)
  local ps, pi = Record.Counts(Record.PERSONAL)
  ns.Print(("%d item%s recorded · %d with a winner."):format(
    items, items == 1 and "" or "s", won))
  ns.Line(("Guild: %d item%s across %d session%s"):format(
    gi, gi == 1 and "" or "s", gs, gs == 1 and "" or "s"))
  ns.Line(("Personal: %d item%s across %d session%s"):format(
    pi, pi == 1 and "" or "s", ps, ps == 1 and "" or "s"))
  if won < items then
    ns.Line(("%d have no winner yet — normal while a roll is open. The website's"):format(items - won))
    ns.Line("import skips them until one is recorded.")
  end
  Record.ReportDeclines()
  ns.Line("|cffF3C56B/la loot|r opens the loot log.")
end

--- What was seen and NOT recorded, since login. Printed by both /la loot status
--- and the no-loot-at-all branch above, because "nothing recorded" is precisely
--- the moment you need to know whether nothing DROPPED or something was refused.
function Record.ReportDeclines()
  local any = false
  for reason, n in pairs(Record.declined) do
    if not any then
      ns.Line("|cffF3C56BSeen but not recorded this session:|r")
      any = true
    end
    ns.Line(("  %d × %s"):format(n, reason))
  end
  if any then
    ns.Line("  |cff888899Quality threshold is |r/la set minQuality|cff888899 — 4 is Epic.|r")
  end
  return any
end

--- Slash router for /la loot [...]
function Record.Command(rest)
  local sub, arg = (rest or ""):lower():match("^%s*(%S*)%s*(%S*)$")
  sub = sub or ""

  if sub == "" or sub == "log" or sub == "export" then
    if ns.RecordWindow then
      ns.RecordWindow.Toggle()
    else
      ns.Warn("loot log window did not load.")
    end
  elseif sub == "status" then
    Record.Status()
  elseif sub == "inject" or sub == "test" then
    Record.Inject(tonumber(arg))
  elseif sub == "fake" then
    Record.Fake(tonumber(arg))
  elseif sub == "scan" then
    local encounters = 0
    for _ in pairs(knownEncounters) do encounters = encounters + 1 end
    local n = Record.ScanAll()
    local _, items = Record.Counts()
    ns.Print(("rescanned %d encounter%s — %d drop%s reported, %d item%s recorded in total."):format(
      encounters, encounters == 1 and "" or "s", n, n == 1 and "" or "s",
      items, items == 1 and "" or "s"))
  elseif sub == "clear" then
    -- Scoped on purpose: `/la loot clear guild` after an import is the routine
    -- one, and it must not take a personal history with it.
    local filter = (arg == "guild" and Record.GUILD)
      or (arg == "personal" and Record.PERSONAL)
      or nil
    if ns.RecordWindow then
      ns.RecordWindow.ConfirmClear(filter)
    else
      local n = Record.Clear(filter)
      ns.Print(("cleared %d recorded item%s."):format(n, n == 1 and "" or "s"))
    end
  else
    ns.Warn("usage: /la loot [log|status|scan|inject|fake|clear [guild|personal]]")
  end
end
