-- Targets.lua — "I'm going after this"
--
-- A manual flag a raider puts on items they want. It answers the one question
-- neither half of this addon can compute: the heuristic answers "is this an
-- upgrade", a sim answers "how much is it worth", and NEITHER can answer "do I
-- want it". Once bidding is real that is the question — a raider may pass on a
-- bigger upgrade to save priority for something they actually care about.
--
-- TWO RULES SHAPE THE WHOLE FILE (HoD_LootAddon_Experience.md §9.1):
--
-- 1. PER CHARACTER, deliberately unlike the account-wide loot log. A Hunter's
--    targets are meaningless on a Paladin. This lives in
--    SavedVariablesPerCharacter rather than a hand-rolled namespace inside the
--    account file, because a per-character file cannot leak across characters
--    through a keying bug — which is a failure mode this project has already
--    paid for once, when account-wide run identity silently merged two
--    characters' loot into one run.
--
-- 2. DISPLAYED, NEVER SCORED. Nothing in here may reach the scorer. If a target
--    added points, the ranking would conflate "how big an upgrade" with "how
--    much they want it" and become trivially gameable — everyone targets
--    everything. Same reasoning that killed off-spec pricing in EPGP: don't
--    create a category the system has to police; make the signal visible and let
--    buy-in do the work.
--
-- The BROADCAST half (reserved message type TGT) rides on comms, which is not
-- built. Nothing here depends on it: the local half is complete on its own, and
-- targets flow raider -> runner -> raiders when it lands, which is the one place
-- the data direction reverses.

local ADDON_NAME, ns = ...

local Targets = {}
ns.Targets = Targets

local DB_DEFAULTS = {
  schema = 1,
  items  = {},   -- [itemID] = { name, icon, slot, source, added }
}

--- The per-character saved table. Created on first use rather than at load, so
--- a character who never flags anything never grows a file.
function Targets.DB()
  HoDLootAdvisorCharDB = HoDLootAdvisorCharDB or {}
  local db = HoDLootAdvisorCharDB
  for k, v in pairs(DB_DEFAULTS) do
    if db[k] == nil then
      if type(v) == "table" then db[k] = {} else db[k] = v end
    end
  end
  return db
end

function Targets.Has(itemID)
  itemID = tonumber(itemID)
  if not itemID then return false end
  return Targets.DB().items[itemID] ~= nil
end

--- `meta` is a display CACHE, not the record: the itemID is the record. Names
--- and icons are re-resolvable from the client at any time, and a cold cache
--- means we may be flagging something we cannot yet name — which must not stop
--- the flag from being set.
function Targets.Add(itemID, meta)
  itemID = tonumber(itemID)
  if not itemID then return false end
  meta = meta or {}

  local db = Targets.DB()
  local existing = db.items[itemID]
  db.items[itemID] = {
    name   = meta.name or (existing and existing.name),
    icon   = meta.icon or (existing and existing.icon),
    slot   = meta.slot or (existing and existing.slot),
    source = meta.source or (existing and existing.source),
    added  = (existing and existing.added) or time(),
  }
  return true
end

function Targets.Remove(itemID)
  itemID = tonumber(itemID)
  if not itemID then return false end
  local db = Targets.DB()
  if not db.items[itemID] then return false end
  db.items[itemID] = nil
  return true
end

--- Returns `true` if the item is now targeted, `false` if it was just cleared.
function Targets.Toggle(itemID, meta)
  if Targets.Has(itemID) then
    Targets.Remove(itemID)
    return false
  end
  Targets.Add(itemID, meta)
  return true
end

function Targets.Count()
  local n = 0
  for _ in pairs(Targets.DB().items) do n = n + 1 end
  return n
end

--- Every target, newest flag first. A stable order matters more than the
--- particular one: a list that reshuffles between refreshes cannot be clicked.
function Targets.List()
  local out = {}
  for itemID, rec in pairs(Targets.DB().items) do
    out[#out + 1] = {
      itemID = itemID, name = rec.name, icon = rec.icon,
      slot = rec.slot, source = rec.source, added = rec.added or 0,
    }
  end
  table.sort(out, function(a, b)
    if a.added ~= b.added then return a.added > b.added end
    return (a.name or tostring(a.itemID)) < (b.name or tostring(b.itemID))
  end)
  return out
end

function Targets.Clear()
  local n = Targets.Count()
  Targets.DB().items = {}
  return n
end

--- Fill in anything flagged before the client could name it. Item data is
--- eventually consistent — the same rule the loot recorder and the journal
--- browse both follow — so a target added from a cold cache is re-asked rather
--- than left displaying its id forever.
function Targets.ResolveNames()
  local db = Targets.DB()
  local pending = 0
  -- The SAME resolution path the loot recorder uses. C_Item first, the global
  -- as the fallback — not a style choice: two places reading item data two
  -- different ways is how they come to disagree about whether an item is known.
  local getInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo

  for itemID, rec in pairs(db.items) do
    if not rec.name then
      local name, _, _, _, _, _, _, _, _, icon
      local ok = pcall(function()
        name, _, _, _, _, _, _, _, _, icon = getInfo(itemID)
      end)
      if ok and name then
        rec.name = name
        rec.icon = rec.icon or icon
      else
        pending = pending + 1
        local req = C_Item and C_Item.RequestLoadItemDataByID
        if req then pcall(req, itemID) end
      end
    end
  end
  return pending
end

-- ---------------------------------------------------------------------------
-- Slash reporting
-- ---------------------------------------------------------------------------

function Targets.Command(rest)
  local sub = (rest or ""):match("^%s*(%S*)"):lower()

  if sub == "clear" then
    local n = Targets.Clear()
    ns.Print(("cleared %d target%s for this character."):format(n, n == 1 and "" or "s"))
    if ns.Panel then ns.Panel.Refresh() end
    return
  end

  Targets.ResolveNames()
  local list = Targets.List()
  if #list == 0 then
    ns.Print("no targets flagged on this character.")
    ns.Line("Right-click an item in the panel to flag it. Targets are PER CHARACTER.")
    return
  end

  ns.Print(("%d target%s on %s:"):format(#list, #list == 1 and "" or "s", UnitName("player") or "?"))
  for _, t in ipairs(list) do
    ns.Line(("|cffF3C56B%s|r%s"):format(
      t.name or ("item:" .. t.itemID),
      t.source and (" |cff888888· " .. t.source .. "|r") or ""))
  end
end
