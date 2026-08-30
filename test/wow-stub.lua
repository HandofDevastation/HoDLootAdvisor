-- test/wow-stub.lua — just enough WoW to run the addon on a Mac.
--
-- Group loot does not fire in dungeons, LFR queues for half an hour and cannot
-- be repeated, and a raid lockout makes a real roll a once-a-week event. So the
-- addon has to be runnable without the game, or it can only be debugged during
-- the one window where being broken costs the most.
--
-- This stubs the API surface Core/Diagnostics/Loot actually touch, with a fake
-- character whose equipped gear is declared per-slot. It is a TEST DOUBLE, not
-- an emulator: it proves the addon's own logic and data wiring, and it can say
-- nothing about how the real client behaves. That is what the diagnostic log on
-- a live raid night is for.

local stub = {}

-- ── The fake character ──────────────────────────────────────────────────────
-- Overridable by a scenario before Install() is called.

stub.player = {
  name       = "Gloomrift",
  realm      = "Stormrage",
  classToken = "HUNTER",
  className  = "Hunter",
  specId     = 254,
  specName   = "Marksmanship",
  heroTree   = "Dark Ranger",
  -- inventory slot -> { itemID, ilvl, bonusIDs, setID }
  equipped   = {},
}

stub.instance = {
  name = "The Venomous Abyss", difficultyID = 15,
  difficultyName = "Heroic (Raid)", instanceID = 2917,
}

-- Item data for things that are NOT equipped — the drops a test hands to the
-- recorder. Keyed by itemID: { name, quality, ilvl, itemType }.
stub.items = {}

-- What C_LootHistory reports, keyed by encounter id. A test assigns
-- stub.lootHistory[2849] = { <EncounterLootDropInfo>, ... } and the recorder
-- enumerates it exactly as it would in game.
stub.lootHistory = {}

stub.printed = {}

-- ── Inventory slot constants ────────────────────────────────────────────────
-- Values are Blizzard's, and are stable across every modern expansion.

local SLOTS = {
  INVSLOT_HEAD = 1, INVSLOT_NECK = 2, INVSLOT_SHOULDER = 3, INVSLOT_BODY = 4,
  INVSLOT_CHEST = 5, INVSLOT_WAIST = 6, INVSLOT_LEGS = 7, INVSLOT_FEET = 8,
  INVSLOT_WRIST = 9, INVSLOT_HAND = 10, INVSLOT_FINGER1 = 11, INVSLOT_FINGER2 = 12,
  INVSLOT_TRINKET1 = 13, INVSLOT_TRINKET2 = 14, INVSLOT_BACK = 15,
  INVSLOT_MAINHAND = 16, INVSLOT_OFFHAND = 17, INVSLOT_TABARD = 19,
}
stub.SLOTS = SLOTS

--- Build an item link the way the game does, so ParseItemLink is exercised on
--- the real format rather than a convenient one.
---   |cffQUALITY|Hitem:id:ench:g1:g2:g3:g4:suffix:unique:level:spec:mask:ctx:nBonus:bonus...|h[Name]|h|r
function stub.link(itemID, name, bonusIDs)
  bonusIDs = bonusIDs or {}
  local fields = { itemID, 0, 0, 0, 0, 0, 0, 0, 80, 0, 0, 0, #bonusIDs }
  for _, b in ipairs(bonusIDs) do fields[#fields + 1] = b end
  return ("|cffa335ee|Hitem:%s|h[%s]|h|r"):format(
    table.concat(fields, ":"), name or ("item " .. itemID))
end

-- ── Clients ─────────────────────────────────────────────────────────────────
--
-- Comms needs TWO of them, and a stub with one hardcoded character cannot prove
-- anything about a protocol. A "client" is the per-character state the addon
-- touches through globals: its frames, its timers, its saved variables, its
-- printed output, and which character it is. Everything else — the instance,
-- the loot history, the items in the world — stays SHARED, which is not a
-- shortcut but the truth: two people in one raid see the same encounter, and
-- that is exactly why the in-night correction needs no message.
--
-- stub.Use(client) swaps the active one. The addon reads every global at CALL
-- time, so a swap is enough; only CreateFrame runs at LOAD time, which is why
-- each client must be loaded while it is the active one.

function stub.NewClient(player)
  local c = {
    player  = player,
    frames  = {},
    timers  = {},
    printed = {},
    sent    = {},
    addonSent = {},
    db      = nil,
  }
  return c
end

function stub.Use(client)
  stub.active  = client
  stub.player  = client.player
  stub.frames  = client.frames
  stub.timers  = client.timers
  stub.printed = client.printed
  stub.sent    = client.sent
  _G.HoDLootAdvisorDB = client.db
  return client
end

-- ── Frames + events ─────────────────────────────────────────────────────────

-- Every event name this stub will accept. Anything else is REJECTED, mirroring
-- the real client's behaviour of erroring on an unknown event — which is how
-- Diagnostics discovers that one of its guessed names does not exist.
local KNOWN_EVENTS = {
  ADDON_LOADED = true, PLAYER_LOGIN = true,
  START_LOOT_ROLL = true, CANCEL_LOOT_ROLL = true, CONFIRM_LOOT_ROLL = true,
  LOOT_ROLLS_COMPLETE = true,
  CHAT_MSG_ADDON = true, GROUP_ROSTER_UPDATE = true, INSPECT_READY = true,
  LOOT_HISTORY_UPDATE_DROP = true, LOOT_HISTORY_UPDATE_ENCOUNTER = true,
  LOOT_HISTORY_GO_TO_ENCOUNTER = true, LOOT_HISTORY_CLEAR_HISTORY = true,
  LOOT_HISTORY_AUTO_SHOW = true, LOOT_HISTORY_FULL_UPDATE = true,
  ENCOUNTER_LOOT_RECEIVED = true, CHAT_MSG_LOOT = true,
  ENCOUNTER_START = true, ENCOUNTER_END = true, BOSS_KILL = true,
  PLAYER_EQUIPMENT_CHANGED = true, PLAYER_ENTERING_WORLD = true,
  GET_ITEM_INFO_RECEIVED = true,
}
stub.KNOWN_EVENTS = KNOWN_EVENTS

local frameMeta = {}
frameMeta.__index = {
  RegisterEvent = function(self, event)
    if not KNOWN_EVENTS[event] then
      error("Attempt to register unknown event '" .. tostring(event) .. "'", 2)
    end
    self.events[event] = true
  end,
  UnregisterEvent = function(self, event) self.events[event] = nil end,
  UnregisterAllEvents = function(self) self.events = {} end,
  SetScript = function(self, which, fn) self.scripts[which] = fn end,
  GetScript = function(self, which) return self.scripts[which] end,
  GetName = function(self) return self.name end,
  GetLeft = function(self) return self.left end,
  GetTop = function(self) return self.top end,
  ClearAllPoints = function(self) self.points = {} end,
  SetPoint = function(self, point, rel, relPoint, x, y)
    self.points = self.points or {}
    self.points[#self.points + 1] = { point = point, relPoint = relPoint, x = x, y = y }
  end,
  Raise = function(self) self.raised = (self.raised or 0) + 1 end,
  SetToplevel = function(self, v) self.toplevel = v end,
  SetClampedToScreen = function(self, v) self.clamped = v end,
}

--- Deliver an event to the ACTIVE client's frames only. With two clients
--- loaded, firing into both would mean a test could never tell which one
--- reacted — and the whole point of the loopback is that they are separate.
function stub.Fire(event, ...)
  for _, f in ipairs(stub.frames) do
    if f.events[event] and f.scripts.OnEvent then
      f.scripts.OnEvent(f, event, ...)
    end
  end
end

-- ── The loot roll currently on offer ────────────────────────────────────────

stub.rolls = {}

--- Register a fake roll so GetLootRollItemInfo/Link answer for it, exactly as
--- the live path reads them.
function stub.SetRoll(rollID, info)
  stub.rolls[rollID] = info
end

-- ── Install ─────────────────────────────────────────────────────────────────

function stub.Install()
  for name, value in pairs(SLOTS) do _G[name] = value end

  -- The default client, built from whatever stub.player a scenario set before
  -- calling Install(). Single-client tests never mention clients at all — they
  -- keep using stub.player / stub.printed / stub.timers exactly as before,
  -- because Use() points those names at the active client's own tables.
  stub.Use(stub.NewClient(stub.player))

  _G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, " ")
    stub.printed[#stub.printed + 1] = line
    -- Strip WoW colour escapes so terminal output stays readable.
    io.write((line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")), "\n")
  end

  -- ESC-to-close registers GLOBAL NAMES, so the stub has to carry the name
  -- through: an anonymous frame registers nothing, silently.
  _G.UISpecialFrames = {}

  _G.CreateFrame = function(_frameType, name)
    local f = setmetatable({ events = {}, scripts = {}, name = name }, frameMeta)
    stub.frames[#stub.frames + 1] = f
    return f
  end

  -- ⚠️ A FIXED WALL CLOCK, and it is not tidiness (Session 256). These were
  -- os.time / os.date, so every fixture this harness GENERATES carried the
  -- moment the suite happened to run. test/export.txt is TRACKED and is written
  -- by smoke.lua, so it changed on every single run and `git diff` showed churn
  -- forever — which trains everyone to wave that file through.
  --
  -- IT DESTROYS A PROOF THIS SUITE ACTUALLY CITES. smoke.lua's roll-state block
  -- argues the Session 255 renumbering was faithful BECAUSE the expected export
  -- did not change. A file that always changes cannot carry that argument, and
  -- a real change to it would have been indistinguishable from the timestamps
  -- moving. Frozen, the file is byte-stable and any diff is a behaviour change.
  --
  -- UTC rather than local, so the fixture is identical here and in CI. GetTime
  -- below is the FRAME clock and is a different thing — it still advances,
  -- because code that measures how long a send took needs it to.
  stub.epoch = 1788030000   -- 2026-08-29 12:20:00 UTC. Arbitrary, chosen once.
  _G.time = function() return stub.epoch end
  _G.date = function(fmt, t)
    fmt = fmt or "%c"
    if fmt:sub(1, 1) ~= "!" then fmt = "!" .. fmt end
    return os.date(fmt, t or stub.epoch)
  end

  -- Timers are QUEUED, not fired. The recorder coalesces its scans behind
  -- C_Timer.After, and a stub that ran callbacks immediately would hide whether
  -- that coalescing works at all. stub.RunTimers() is the test's clock.
  -- A frame clock. GetTime is high-resolution seconds-since-login, and the
  -- addon uses it to measure how long a send actually took — a thing time()
  -- cannot express, since a whole send fits inside one of its seconds.
  -- Advanced by RunTimers as each timer's delay elapses, so a paced queue
  -- reports a realistic duration here rather than zero.
  stub.clock = 0
  _G.GetTime = function() return stub.clock end

  _G.C_Timer = {
    After = function(delay, fn)
      stub.timers[#stub.timers + 1] = { delay = delay, fn = fn }
    end,
  }

  _G.SLASH_HODLOOTADVISOR1 = nil
  _G.SLASH_HODLOOTADVISOR2 = nil
  _G.SlashCmdList = {}

  _G.C_AddOns = { GetAddOnMetadata = function(_, key)
    if key == "Version" then return "test" end
  end }

  -- The THIRD return is the numeric classID, which is what EJ_SetLootFilter
  -- takes. The addon reads it as select(3, UnitClass("player")).
  _G.UnitClass = function(unit)
    if unit == "player" then
      return stub.player.className, stub.player.classToken, stub.player.classID or 3
    end
    local e = stub.UnitEntry and stub.UnitEntry(unit)
    if not e then return nil end
    return e.class, e.classToken, e.classID or 3
  end

  -- SavedVariables are account-wide, so which character is playing is part of a
  -- recorded run's identity. Swapping stub.player.name mid-test is how the
  -- alt-on-the-same-raid case is exercised.
  _G.UnitName = function(unit)
    if unit == "player" then return stub.player.name, stub.player.realm end
    local e = stub.UnitEntry and stub.UnitEntry(unit)
    if not e then return nil end
    return e.name, e.realm
  end
  _G.GetRealmName = function() return stub.player.realm end

  _G.GetSpecialization = function() return 1 end
  _G.GetSpecializationInfo = function() return stub.player.specId, stub.player.specName end

  -- Hero talent detection. Mirrors the shape Core reads: an active config, the
  -- class's sub-tree ids, and GetSubTreeInfo carrying name + isActive.
  _G.C_ClassTalents = {
    GetActiveConfigID = function() return 1 end,
    GetHeroTalentSpecsForClassSpec = function() return { 41, 42 } end,
  }
  _G.C_Traits = {
    GetSubTreeInfo = function(_, id)
      if id == 41 then
        return { name = stub.player.heroTree, isActive = stub.player.heroTree ~= nil }
      end
      return { name = "Sentinel", isActive = false }
    end,
  }

  _G.GetInventoryItemLink = function(unit, inv)
    local who = (unit == "player") and { equipped = stub.player.equipped }
                or (stub.UnitEntry and stub.UnitEntry(unit))
    -- Inspect data is only readable for the unit currently inspected, which is
    -- why ClearInspectPlayer matters and why a result must be filed before the
    -- next request goes out.
    if unit ~= "player" and stub.inspectTarget ~= unit then return nil end
    local e = who and who.equipped and who.equipped[inv]
    if not e then return nil end
    return stub.link(e.itemID, e.name or ("equipped " .. inv), e.bonusIDs)
  end

  _G.GetInventoryItemID = function(unit, inv)
    if unit ~= "player" then return nil end
    local e = stub.player.equipped[inv]
    return e and e.itemID or nil
  end

  -- ── Tooltips ──────────────────────────────────────────────────────────────
  --
  -- The registry the modern client exposes. stub.FireTooltip() plays the part of
  -- the client showing an item, so the addon's post-call runs for real.
  -- NOT a claim that this is the 12.1 API: Tooltip.lua probes for it and falls
  -- back, and only a live client settles which branch runs there.
  stub.tooltipCalls = {}
  stub.tooltipLines = {}
  _G.Enum = _G.Enum or {}
  _G.Enum.TooltipDataType = { Item = 0 }
  _G.TooltipDataProcessor = {
    AddTooltipPostCall = function(dataType, fn)
      stub.tooltipCalls[#stub.tooltipCalls + 1] = { dataType = dataType, fn = fn }
    end,
  }

  _G.GameTooltip = {
    AddLine = function(_, text, r, g, b)
      stub.tooltipLines[#stub.tooltipLines + 1] = { text = text, r = r, g = g, b = b }
    end,
    HookScript = function(_, which, fn)
      stub.tooltipHooks = stub.tooltipHooks or {}
      stub.tooltipHooks[which] = fn
    end,
    SetOwner = function() end,
    SetHyperlink = function() end,
    Show = function() end,
    Hide = function() end,
  }

  --- Play the client showing an item tooltip. Returns the lines the addon added.
  function stub.FireTooltip(itemID)
    stub.tooltipLines = {}
    for _, c in ipairs(stub.tooltipCalls) do
      c.fn(_G.GameTooltip, { id = itemID })
    end
    return stub.tooltipLines
  end

  -- ── The Encounter Journal ─────────────────────────────────────────────────
  --
  -- Modelled on what three LIVE probe runs established (HoD_Rules_Loot-Gear.txt,
  -- "THE ENCOUNTER JOURNAL IS A CLIENT-SIDE LOOT CATALOGUE"), including the two
  -- behaviours that made the real thing hard to read:
  --
  --  · loot lives on C_EncounterJournal.GetLootInfoByIndex; the EJ_-prefixed
  --    name is ABSENT, so a lookup keyed by it enumerates nothing.
  --  · EJ_SetLootFilter only takes effect when the encounter is (re-)selected
  --    AFTERWARDS. Setting it later reads back correctly and filters nothing.
  --
  -- The stub reproduces both, so code that gets the order wrong FAILS here
  -- rather than in a raid.
  -- Base item levels the CATALOGUE reports for dungeon items. Far below any
  -- current rung, exactly as a real base level is.
  stub.items = stub.items or {}
  stub.items[880002] = { ilvl = 200 }

  stub.journal = {
    tier = 13,
    selectedTier = 13, selectedInstance = nil, selectedEncounter = nil,
    filter = nil, appliedFilter = nil,
    instances = {
      { id = 1317, name = "The Tidebound Grotto", isRaid = true },
      { id = 1312, name = "Midnight",             isRaid = true },
      { id = 1304, name = "Murder Row",           isRaid = false },
      { id = 1322, name = "Altar of Fangs",       isRaid = false },
      { id = 1319, name = "Keystone Dungeons",    isRaid = false },
    },
    -- Instances that enumerate but hold no loot.
    noLoot = { [1319] = true },
    encounters = {
      [1317] = { { id = 2849, name = "Nymrissa Wavecaller" },
                 { id = 2894, name = "The Lost Explorers" } },
      [1312] = { { id = 2900, name = "Lu'ashal" } },
      [1304] = { { id = 2910, name = "Gebbo" } },
      -- TWO encounters, deliberately, with an item they SHARE. A Mythic+ run has
      -- one chest at the end, so the dungeon is the unit of loot and the pooled
      -- list must contain that item ONCE.
      [1322] = { { id = 2920, name = "Fangcaller Vex" },
                 { id = 2921, name = "The Brood Matron" } },
      [1319] = {},
    },
    -- classID 3 is the Hunter in this fixture; anything else sees fewer items.
    loot = {
      [2849] = {
        { itemID = 270160, name = "Sunfury Chestguard", icon = 1, slot = "Chest",
          armorType = "Mail", itemQuality = 4, classID = 3 },
        { itemID = 270161, name = "Voidscarred Greaves", icon = 2, slot = "Feet",
          armorType = "Plate", itemQuality = 4, classID = 1 },
        { itemID = 270162, name = "Tidecaller's Band", icon = 3, slot = "Finger",
          itemQuality = 4, displayAsVeryRare = true },
      },
      [2894] = {},
      [2900] = {},
      [2910] = {
        -- Deliberately unnamed: a COLD item cache, which is what the real API
        -- returns before the client has loaded the item.
        { itemID = 270999, icon = 9, itemQuality = 4 },
      },
      -- Dungeon loot, warm. Slot wording is the ADVENTURE GUIDE'S, not ours —
      -- "Two-Hand" and "Held In Off-hand" are what the real API answers, and
      -- mapping them is the thing that silently breaks if anyone "simplifies"
      -- ns.JournalSlot into a string transform.
      [2920] = {
        -- classID 3 is the fixture's Hunter. The MAIL hood is theirs; the LEATHER
        -- shoulder below belongs to someone else and is what Blizzard's filter
        -- removes. This mirrors the live bug exactly: a leather shoulder listed
        -- under Usable Only for a Warlock.
        { itemID = 880001, name = "Fangcaller's Hood", icon = 11, slot = "Head",
          armorType = "Mail", itemQuality = 4, classID = 3 },
        { itemID = 880006, name = "Snakeskin Spaulders", icon = 16, slot = "Shoulder",
          armorType = "Leather", itemQuality = 4, classID = 1 },
        -- ⚠️ CARRIES A CATALOGUE LINK, like every real Adventure Guide entry.
        -- The guide describes an item at its BASE level and knows nothing about
        -- key levels, so this link answers 200 — deliberately NOT the Mythic+
        -- drop level. Without a link here the fixture could not reproduce the
        -- bug at all: dungeon items showed ilvl 292 / Veteran in game while the
        -- tests passed, because the tests never handed the scorer a link.
        { itemID = 880002, name = "Broodfang Cleaver", icon = 12, slot = "Two-Hand",
          armorType = "Axe", itemQuality = 4, link = "|Hitem:880002|h[Broodfang Cleaver]|h" },
        { itemID = 880004, name = "Venomtouched Grimoire", icon = 14,
          slot = "Held In Off-hand", itemQuality = 4 },
        -- No slot at all: the guide does not always answer, and an item we
        -- cannot place must be LISTED but never scored or priced.
        { itemID = 880005, name = "Curious Fang", icon = 15, itemQuality = 4 },
      },
      [2921] = {
        { itemID = 880003, name = "Matron's Chitin Band", icon = 13, slot = "Finger",
          itemQuality = 4 },
        -- SHARED with the other boss. Pooling must not double it.
        { itemID = 880002, name = "Broodfang Cleaver", icon = 12, slot = "Two-Hand",
          armorType = "Axe", itemQuality = 4 },
      },
    },
  }

  local J = stub.journal
  _G.EJ_GetNumTiers = function() return 13 end
  _G.EJ_GetTierInfo = function(t) return (t == 13) and "Midnight" or ("Tier " .. tostring(t)) end
  _G.EJ_GetCurrentTier = function() return J.selectedTier end
  -- The real signature returns name, description, bgImage, ... — the third
  -- value is a texture FILE ID, NOT an instance id. Modelled exactly so that
  -- anything reading select(3, ...) as an id gets a plausible-looking number and
  -- is caught by the tests rather than in a raid.
  _G.EJ_GetInstanceInfo = function()
    return "Some Instance", "description", 4210987
  end
  _G.EJ_SelectTier = function(t) J.selectedTier = t end
  _G.EJ_GetInstanceByIndex = function(i, isRaid)
    local n = 0
    for _, inst in ipairs(J.instances) do
      if inst.isRaid == isRaid then
        n = n + 1
        if n == i then return inst.id, inst.name end
      end
    end
    return nil
  end
  _G.EJ_SelectInstance = function(id) J.selectedInstance = id end
  _G.EJ_GetEncounterInfoByIndex = function(i)
    local list = J.encounters[J.selectedInstance] or {}
    local e = list[i]
    if not e then return nil end
    -- name, description, encounterID, ...
    return e.name, nil, e.id
  end
  -- AN ENCOUNTER ONLY RESOLVES WITHIN ITS OWN INSTANCE. Modelled because it is
  -- what actually broke browsing in a live client: the loot read relied on the
  -- instance already being selected, and the restore step moved it, so the first
  -- encounter answered and every one after came back empty. Code that does not
  -- select its own instance now fails HERE.
  _G.EJ_SelectEncounter = function(id)
    local belongs = false
    for _, e in ipairs(J.encounters[J.selectedInstance] or {}) do
      if e.id == id then belongs = true end
    end
    J.selectedEncounter = belongs and id or nil
    -- THE ORDERING RULE: the filter in force at SELECT time is the one applied.
    J.appliedFilter = J.filter
  end
  _G.EJ_SetLootFilter = function(classID, specID)
    J.filter = { classID = classID, specID = specID }
  end
  _G.EJ_GetLootFilter = function()
    return J.filter and J.filter.classID, J.filter and J.filter.specID
  end
  _G.EJ_ResetLootFilter = function() J.filter, J.appliedFilter = nil, nil end

  -- A COLD CLIENT NAMES NOTHING — but it STILL FILTERS. Measured in a live
  -- client by /la journal: the probe filtered 17 items to 5 while every entry
  -- came back with an itemID and no name. An earlier version of this stub tied
  -- the two together, which would have baked a wrong belief into the harness and
  -- made it agree with wrong code. Set stub.journal.warm = true to play the
  -- client having caught up on NAMES only.
  J.warm = false

  local function visibleLoot()
    local all = J.loot[J.selectedEncounter] or {}
    local f = J.appliedFilter
    if not (f and f.classID) then return all end
    local out = {}
    for _, it in ipairs(all) do
      if it.classID == nil or it.classID == f.classID then out[#out + 1] = it end
    end
    return out
  end

  _G.EJ_GetNumLoot = function() return #visibleLoot() end
  -- NOTE the namespace: this is the one that exists on 12.1.
  _G.C_EncounterJournal = {
    GetLootInfoByIndex = function(i)
      local it = visibleLoot()[i]
      if not it then return nil end
      -- Cold: the id comes back and nothing else, the five-field entry the live
      -- probe mistook for the API's shape.
      if not J.warm then
        return { itemID = it.itemID, icon = it.icon, itemQuality = it.itemQuality,
                 encounterID = J.selectedEncounter }
      end
      return {
        itemID = it.itemID, name = it.name, link = it.link, icon = it.icon,
        slot = it.slot, armorType = it.armorType, itemQuality = it.itemQuality,
        displayAsVeryRare = it.displayAsVeryRare,
        encounterID = J.selectedEncounter,
      }
    end,
    -- A CONTAINER THAT HOLDS NOTHING. The real season list carries one —
    -- "Keystone Dungeons", 1319 — which enumerates like a dungeon and lists no
    -- loot. Modelled here so the strip's filter is tested against the case it
    -- exists for rather than against a list where everything has loot.
    InstanceHasLoot = function(id) return stub.journal.noLoot[id] ~= true end,
  }

  -- Items the addon asked the client to load. Item data is eventually
  -- consistent, so "did we go back for it" is a behaviour worth asserting.
  stub.requestedItems = {}

  _G.C_Item = {
    RequestLoadItemDataByID = function(itemID)
      stub.requestedItems[#stub.requestedItems + 1] = itemID
    end,
    -- Answers from the ilvl declared on the equipped entry, or from the link's
    -- own item id for a candidate drop we were handed.
    GetDetailedItemLevelInfo = function(link)
      local id = tonumber(tostring(link):match("|?H?item:(%d+)"))
      for _, e in pairs(stub.player.equipped) do
        if e.itemID == id then return e.ilvl end
      end
      -- The INSPECTED unit's gear too. Without this the whole inspect path
      -- reads every item as ilvl 0 and every stranger resolves as "answered
      -- with no gear" — a stub gap that looks exactly like the feature not
      -- working, which is the worst kind.
      local target = stub.inspectTarget and stub.UnitEntry and stub.UnitEntry(stub.inspectTarget)
      if target and target.equipped then
        for _, e in pairs(target.equipped) do
          if e.itemID == id then return e.ilvl end
        end
      end
      local it = id and stub.items[id]
      if it and it.ilvl then return it.ilvl end
      return stub.candidateIlvl or nil
    end,
    -- Accepts an itemID or a link, because the addon calls it both ways: the
    -- tier-piece count passes an id, the loot recorder passes the dropped link.
    GetItemInfo = function(idOrLink)
      local itemID = tonumber(idOrLink)
        or tonumber(tostring(idOrLink):match("|?H?item:(%d+)"))

      for _, e in pairs(stub.player.equipped) do
        if e.itemID == itemID then
          -- 17 returns; only setID (16th) is read by the addon.
          return e.name or "item", nil, 4, e.ilvl, 80, "Armor", "Mail", 1,
                 "INVTYPE", nil, 0, 4, 3, 1, 11, e.setID, false
        end
      end

      local it = itemID and stub.items[itemID]
      if it then
        return it.name, nil, it.quality or 4, it.ilvl or 0, 80,
               it.itemType or "Armor", it.subType or "Mail", 1,
               "INVTYPE", nil, 0, 4, 3, 1, 11, it.setID, false
      end
      return nil
    end,
  }

  -- ⚠️ A GLOBAL, not a C_Item member. GetItemInfoInstant is the SYNCHRONOUS
  -- one: it answers from the item id alone with no cache involved, which is what
  -- makes it usable for deciding whether a journal entry is even gear. Returns
  -- itemID, itemType, itemSubType, itemEquipLoc, icon, classID, subclassID —
  -- only classID (6th) is read by the addon.
  --
  -- stub.itemClass maps id -> classID so a test can sit a profession pattern (9)
  -- or housing decor (15) beside a real armour piece (4). Anything not listed
  -- answers 4, since nearly everything in the fixtures is gear.
  _G.GetItemInfoInstant = function(idOrLink)
    local itemID = tonumber(idOrLink)
      or tonumber(tostring(idOrLink):match("|?H?item:(%d+)"))
    if not itemID then return nil end
    local classID = (stub.itemClass or {})[itemID] or 4
    return itemID, "Armor", "Mail", "INVTYPE_CHEST", 0, classID, 3
  end

  _G.GetInstanceInfo = function()
    -- The full 8 returns: the 4th is the difficulty NAME and the 8th the
    -- instance id, both of which land in the loot export's SESSION line.
    return stub.instance.name, stub.instance.instanceType or "raid",
           stub.instance.difficultyID, stub.instance.difficultyName,
           20, 0, false, stub.instance.instanceID
  end

  _G.GetLootRollItemInfo = function(rollID)
    local r = stub.rolls[rollID]
    if not r then return nil end
    -- The 13 returns in Blizzard's documented order.
    return r.texture or 0, r.name, r.count or 1, r.quality or 4,
           r.bindOnPickUp ~= false, r.canNeed ~= false, r.canGreed ~= false,
           r.canDisenchant == true, r.reasonNeed, r.reasonGreed,
           r.reasonDisenchant, r.deSkillRequired, r.canTransmog == true
  end

  _G.GetLootRollItemLink = function(rollID)
    local r = stub.rolls[rollID]
    return r and r.link or nil
  end

  _G.GetLootRollTimeLeft = function(rollID)
    local r = stub.rolls[rollID]
    return r and r.timeLeft or 0
  end

  -- Group state + chat. `sent` captures everything the addon would say to the
  -- raid, which is the part that must never fire on its own.
  stub.inRaid, stub.inGroup, stub.instanceGroup = false, false, false

  -- IsInGroup takes an optional PARTY CATEGORY, and ignoring it is how an addon
  -- silently sends to the wrong channel in an LFG group: RAID and PARTY are not
  -- that group's channel, so the message goes nowhere with no error.
  _G.Enum = _G.Enum or {}
  _G.Enum.PartyCategory = { Home = 1, Instance = 2 }
  _G.LE_PARTY_CATEGORY_HOME, _G.LE_PARTY_CATEGORY_INSTANCE = 1, 2

  _G.IsInRaid = function() return stub.inRaid end
  _G.IsInGroup = function(category)
    if category == 2 then return stub.instanceGroup end
    if category == 1 then return (stub.inGroup or stub.inRaid) and not stub.instanceGroup end
    return stub.inGroup or stub.inRaid or stub.instanceGroup
  end
  _G.SendChatMessage = function(msg, channel)
    if #msg > 255 then
      error("SendChatMessage over 255 bytes would be rejected by the client")
    end
    stub.sent[#stub.sent + 1] = { msg = msg, channel = channel }
  end

  -- ── The group, and inspecting it ──────────────────────────────────────────
  --
  -- stub.group is a list of OTHER people standing here, each declaring what the
  -- client would answer about them:
  --   { name, class, classToken, guid, role, connected, inspectable,
  --     specId, specName, equipped = { [invSlot] = {itemID, ilvl} }, silent }
  --
  -- `inspectable = false` models out-of-range, and `silent = true` models the
  -- failure mode that has no callback at all: NotifyInspect succeeds and
  -- INSPECT_READY simply never fires. That one is not an edge case — it is what
  -- happens to anyone across the room — and a queue that does not time out
  -- stops dead on the first such person.

  stub.group = {}
  stub.inspectTarget = nil
  stub.inspectCalls = {}

  local function unitEntry(unit)
    if unit == "player" then
      return { name = stub.player.name, class = stub.player.className,
               classToken = stub.player.classToken, guid = "Player-self",
               connected = true, equipped = stub.player.equipped }
    end
    local i = tonumber(tostring(unit):match("^raid(%d+)$") or tostring(unit):match("^party(%d+)$"))
    if not i then return nil end
    if tostring(unit):match("^raid") then
      -- raid1 is the player themselves, matching the real client.
      if i == 1 then return unitEntry("player") end
      return stub.group[i - 1]
    end
    return stub.group[i]
  end
  stub.UnitEntry = unitEntry

  _G.GetNumGroupMembers = function()
    if stub.inRaid then return #stub.group + 1 end
    if stub.inGroup then return #stub.group + 1 end
    return 0
  end

  _G.UnitExists = function(unit) return unitEntry(unit) ~= nil end

  -- Guild membership per unit. Defaults to FALSE for group members, which is
  -- the LFR case — a stub that defaulted everyone to guildmates would make the
  -- auto-post gate pass in exactly the situation it exists to block, and the
  -- test would confirm a wrong theory rather than the code.
  _G.UnitIsInMyGuild = function(unit)
    if unit == "player" then return true end
    local e = unitEntry(unit)
    return (e and e.inGuild) == true
  end
  _G.UnitGUID = function(unit)
    local e = unitEntry(unit); return e and e.guid or nil
  end
  _G.UnitIsConnected = function(unit)
    local e = unitEntry(unit); return e and e.connected ~= false
  end
  _G.UnitGroupRolesAssigned = function(unit)
    local e = unitEntry(unit); return e and e.role or "NONE"
  end
  _G.CanInspect = function(unit)
    local e = unitEntry(unit); return e ~= nil and e.inspectable ~= false
  end
  _G.ClearInspectPlayer = function() stub.inspectTarget = nil end

  _G.NotifyInspect = function(unit)
    local e = unitEntry(unit)
    stub.inspectCalls[#stub.inspectCalls + 1] = unit
    if not e then return end
    stub.inspectTarget = unit
    -- The client answers ASYNCHRONOUSLY, so the reply is QUEUED as a timer
    -- rather than fired inline. Firing inline would let a queue that never
    -- handles the asynchrony pass this harness and fail in game.
    if e.silent then return end
    _G.C_Timer.After(0.1, function() stub.Fire("INSPECT_READY", e.guid) end)
  end

  _G.GetInspectSpecialization = function(unit)
    local e = unitEntry(unit)
    -- Answers 0 rather than nil when it has nothing — the real behaviour, and
    -- the reason a truthiness guard here is a bug.
    return (e and e.specId) or 0
  end
  _G.GetSpecializationInfoByID = function(specId)
    for _, e in ipairs(stub.group) do
      if e.specId == specId then return specId, e.specName end
    end
    if specId == stub.player.specId then return specId, stub.player.specName end
    return nil
  end

  -- ── Addon messages ────────────────────────────────────────────────────────
  --
  -- The transport comms actually runs on. Deliberately UNFORGIVING about the
  -- two things the real client is unforgiving about, because both fail
  -- invisibly in game:
  --   • an unregistered prefix means inbound messages are dropped before the
  --     addon sees them, which looks exactly like nobody else running it;
  --   • a body over 255 bytes is REJECTED, not truncated, so a chunking bug
  --     loses whole messages rather than the tail of one.
  --
  -- stub.wire is what makes two clients talk. It is nil by default, so the
  -- existing single-client tests send into the void exactly as a solo character
  -- does — and the loopback test sets it to hand each message to the other
  -- client's CHAT_MSG_ADDON handler.

  stub.registeredPrefixes = {}
  stub.addonSent = {}
  stub.wire = nil
  --- Force the next N sends to report a throttle, so the backoff path is
  --- exercised without waiting on a real client's rate limiter.
  stub.throttleNext = 0

  _G.Enum.SendAddonMessageResult = {
    -- ⚠️ SUCCESS IS ZERO, and zero is truthy in Lua. Real values, so the
    -- addon's result handling is tested against the trap rather than around it.
    Success = 0, InvalidPrefix = 1, InvalidMessage = 2, AddonMessageThrottle = 3,
    InvalidChatType = 4, NotInGroup = 5, TargetRequired = 6, GeneralError = 7,
  }

  _G.C_ChatInfo = {
    RegisterAddonMessagePrefix = function(prefix)
      if type(prefix) ~= "string" or #prefix > 15 then return false end
      stub.registeredPrefixes[prefix] = true
      return true
    end,

    SendAddonMessage = function(prefix, text, channel, target)
      if #tostring(text) > 255 then
        error(("addon message of %d bytes would be REJECTED by the client (limit 255)")
          :format(#tostring(text)))
      end

      local msg = {
        prefix = prefix, text = text, channel = channel, target = target,
        from = stub.active,
      }
      stub.addonSent[#stub.addonSent + 1] = msg
      if stub.active then
        stub.active.addonSent[#stub.active.addonSent + 1] = msg
      end

      if stub.throttleNext > 0 then
        stub.throttleNext = stub.throttleNext - 1
        return _G.Enum.SendAddonMessageResult.AddonMessageThrottle
      end

      if stub.wire then stub.wire(msg) end
      return _G.Enum.SendAddonMessageResult.Success
    end,
  }

  --- Hand one message to a client as the game would: swap to it, fire
  --- CHAT_MSG_ADDON, swap back. The sender name is the ORIGINATING client's
  --- character, which is the only thing the receiver has to identify them by.
  function stub.Deliver(msg, toClient)
    if not stub.registeredPrefixes[msg.prefix] then return false end
    local previous = stub.active
    stub.Use(toClient)
    local sender = msg.from and msg.from.player and msg.from.player.name or "?"
    stub.Fire("CHAT_MSG_ADDON", msg.prefix, msg.text, msg.channel, sender)
    stub.Use(previous)
    return true
  end

  _G.C_LootHistory = {
    GetSortedDropsForEncounter = function(encounterID)
      return stub.lootHistory[encounterID] or {}
    end,
    GetInfoForEncounterDrop = function(encounterID, lootListID)
      for _, d in ipairs(stub.lootHistory[encounterID] or {}) do
        if d.lootListID == lootListID then return d end
      end
      return nil
    end,
  }
end

--- Fire every queued timer callback, oldest first, then clear the queue.
--- Deliberately manual: a raid night's roll window is minutes long and the
--- recorder's follow-up ladder runs out to four of them.
---
--- `maxDelay` fires only the timers due within that many seconds and LEAVES the
--- longer ones queued. Without it this scheduler ignores delay entirely, which
--- is fine for the recorder's ladder (order is all that matters there) and
--- wrong for anything that schedules a VERDICT after work it is judging: the
--- comms volume test queues a 30-second report alongside a queue that takes
--- seconds to drain, and running them in insertion order judges the work before
--- it happens.
---
--- ⚠️ THE FRESH QUEUE IS WRITTEN BACK TO THE CLIENT, and deferred timers go into
--- a LOCAL rather than into stub.timers. Both matter, and together they were an
--- unbounded loop.
---
--- Delivering a message swaps the active client and swaps back, and Use()
--- restores stub.timers from client.timers — so a swap in the middle of a drain
--- restored the table this function had already snapshotted and abandoned.
--- Every timer scheduled from then on was appended to the very list being
--- iterated, and the drain fed itself forever. It surfaced only once a test both
--- delivered messages AND queued a large number of them, which is exactly the
--- case the volume test is.
function stub.RunTimers(maxDelay)
  local queued = stub.timers
  local fresh = {}
  stub.timers = fresh
  if stub.active then stub.active.timers = fresh end

  local fired = 0
  for _, t in ipairs(queued) do
    if maxDelay and (t.delay or 0) > maxDelay then
      fresh[#fresh + 1] = t
    else
      fired = fired + 1
      stub.clock = stub.clock + (t.delay or 0)
      t.fn()
    end
  end
  return fired
end

--- One EncounterLootDropInfo, shaped as C_LootHistory returns it (Data Contract
--- §5). `rolls` is a list of { name, state, roll, isWinner }.
function stub.drop(lootListID, itemID, itemName, bonusIDs, rolls)
  local rollInfos, winner = {}, nil
  for _, r in ipairs(rolls or {}) do
    local info = {
      playerName = r.name, playerGUID = "Player-" .. r.name,
      playerClass = r.class or "HUNTER", isSelf = r.isSelf or false,
      state = r.state, isWinner = r.isWinner or false, roll = r.roll or 0,
    }
    rollInfos[#rollInfos + 1] = info
    if info.isWinner then winner = info end
  end
  return {
    lootListID = lootListID,
    itemHyperlink = stub.link(itemID, itemName, bonusIDs),
    playerRollState = 0, currentLeader = winner, isTied = false,
    winner = winner, allPassed = false, rollInfos = rollInfos,
    startTime = 0, duration = 60,
  }
end

--- Load the addon's files the way the .toc does — each chunk called with
--- (addonName, sharedNamespaceTable), which is exactly how WoW passes them.
function stub.LoadAddon(files)
  local ns = {}
  for _, path in ipairs(files) do
    local chunk, err = loadfile(path)
    if not chunk then error("could not load " .. path .. ": " .. tostring(err)) end
    chunk("HoDLootAdvisor", ns)
  end
  return ns
end

function stub.Slash(text)
  SlashCmdList["HODLOOTADVISOR"](text)
end

return stub
