-- Tooltip.lua — a targeted item announces itself everywhere you meet it
--
-- The panel can only mark items you are looking at IN the panel. The point of a
-- target is that you are going after it out in the world — in a dungeon, at a
-- vendor, in a chat link, in the Adventure Guide — which is exactly where the
-- panel is not. So the flag is appended to the item's own tooltip instead, and
-- then it reaches every one of those places for free.
--
-- ⚠️ PROBED, NOT ASSUMED. Retail exposes a tooltip post-call registry, and this
-- file expects to find it — but two wrong API recollections have already cost
-- real time on this project (LOOT_HISTORY_AUTO_SHOW does not exist;
-- GetSpecialization silently answered 0 for eighteen logins), so nothing here
-- states that it is present. It looks, records WHICH mechanism answered, and
-- falls back to the older hook if the modern one is absent. If NEITHER is there,
-- the addon loses a nicety and nothing else — every other surface still marks
-- targets, and `/la status` reports that the tooltip line is unavailable rather
-- than leaving it mysteriously silent.
--
-- BIS will append here too, once it exists. The line is deliberately built from
-- a LIST of sources rather than a single string, so "BIS ITEM" is one more entry
-- and not a rewrite.

local ADDON_NAME, ns = ...

local Tooltip = {}
ns.Tooltip = Tooltip

local GOLD = { 0.953, 0.773, 0.420 }

--- How the line got attached, or nil if it could not be. Reported by /la status:
--- a feature that silently does not work is indistinguishable from one that is
--- broken, which is the same lesson the silent-decline rule came from.
Tooltip.method = nil

--- Everything we have to say about an item, in display order. Each entry is
--- { text, r, g, b }. Empty means add nothing at all — never an empty line.
local function linesFor(itemID)
  if not itemID then return nil end
  local out = {}

  if ns.Targets and ns.Targets.Has(itemID) then
    out[#out + 1] = { text = "Targeted", r = GOLD[1], g = GOLD[2], b = GOLD[3] }
  end

  -- Quality: the grade and the BIS listing, for THIS character's spec. Read from
  -- the namespace rather than taken as arguments for exactly the reason the note
  -- above anticipated — the answer depends on who is looking.
  local data = ns.Data and ns.Data()
  local char = ns.ResolveCharacter and ns.ResolveCharacter()
  if data and data.rankings and char and char.className and char.specName then
    local q = ns.Scoring.resolveQuality(
      data.rankings, itemID, char.className, char.specName, char.heroTree,
      ns.CurrentContentScope and ns.CurrentContentScope() or nil)

    if q then
      -- EVERY context is named, not just the strongest. "Raid BIS" and "M+ BIS"
      -- are worth the same 40 points, so collapsing them to whichever sorted
      -- first would tell an M+ player their trinket is a raid pick and nothing
      -- else. The scorer still consumes only the strongest — this is the label.
      if q.bis then
        local names = {}
        for _, ctx in ipairs(q.contexts or { q.bis }) do
          names[#names + 1] = (ns.BIS_LONG or {})[ctx] or ctx
        end
        table.sort(names)
        out[#out + 1] = { text = table.concat(names, " · "),
                          r = GOLD[1], g = GOLD[2], b = GOLD[3] }
      end

      -- The grade is shown ALONGSIDE a BIS listing rather than replaced by it.
      -- The scorer takes only the strongest of the two, but a reader looking at
      -- a trinket wants both facts, and they can genuinely disagree — a C-graded
      -- item can still be somebody's best available in that slot.
      if q.grade then
        local label = q.grade == "defensive"
          and "Defensive trinket"
          or ("Grade %s"):format(q.grade:upper())
        out[#out + 1] = { text = label, r = 0.78, g = 0.78, b = 0.85 }
      end

      -- The drop to chase and the piece you end up with are DIFFERENT ITEMS
      -- under the 12.1 catalyst, which is the entire reason this line exists.
      if q.catalysesInto then
        local name = GetItemInfo and GetItemInfo(q.catalysesInto)
        -- ASCII "->", not the arrow glyph. WoW's tooltip font has no U+2192 and
        -- renders it as a missing-glyph box, which is what shipped and what the
        -- first screenshot showed. Keep every user-facing string in this addon
        -- to characters the game font actually has.
        out[#out + 1] = {
          text = ("Catalyse target -> %s"):format(name or ("item:" .. q.catalysesInto)),
          r = 0.60, g = 0.80, b = 0.60,
        }
      end
    end
  end

  if #out == 0 then return nil end
  return out
end

--- Append our lines to a tooltip that is showing `itemID`.
local function decorate(tip, itemID)
  local lines = linesFor(itemID)
  if not lines then return end
  for _, l in ipairs(lines) do
    -- Prefixed so it is unmistakably ours in a stack of addon tooltip lines.
    tip:AddLine(("|cffF3C56B[LA]|r %s"):format(l.text), l.r, l.g, l.b)
  end
end

--- Pull the item id out of whatever the tooltip is currently showing.
local function itemIDFrom(tip, data)
  -- The modern processor hands the id straight over.
  if data and data.id then return data.id end
  -- The older path exposes only the link.
  local getItem = tip and tip.GetItem
  if getItem then
    local ok, _, link = pcall(getItem, tip)
    if ok and link then
      local id = link:match("|Hitem:(%d+)")
      if id then return tonumber(id) end
    end
  end
  return nil
end

function Tooltip.Start()
  -- 1. THE MODERN REGISTRY. Present on current retail; the whole reason this
  -- reaches bags, vendors, the auction house and the Adventure Guide alike
  -- rather than just GameTooltip.
  local processor = _G.TooltipDataProcessor
  local dataType = _G.Enum and _G.Enum.TooltipDataType and _G.Enum.TooltipDataType.Item
  if processor and type(processor.AddTooltipPostCall) == "function" and dataType then
    local ok = pcall(processor.AddTooltipPostCall, dataType, function(tip, data)
      -- Guarded because this runs on EVERY item tooltip in the game. An error
      -- here would be blamed on whatever the player was hovering.
      pcall(decorate, tip, itemIDFrom(tip, data))
    end)
    if ok then
      Tooltip.method = "TooltipDataProcessor"
      return Tooltip.method
    end
  end

  -- 2. THE OLDER HOOK, for a client without the registry. Covers GameTooltip
  -- only, which is most of what matters and is honestly less than the above.
  if _G.GameTooltip and GameTooltip.HookScript then
    local ok = pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetItem", function(tip)
      pcall(decorate, tip, itemIDFrom(tip, nil))
    end)
    if ok then
      Tooltip.method = "OnTooltipSetItem"
      return Tooltip.method
    end
  end

  -- 3. NEITHER. Recorded rather than shrugged off — see the header.
  Tooltip.method = nil
  if ns.Diagnostics then
    ns.Diagnostics.Note("tooltipUnavailable", {
      hasProcessor = _G.TooltipDataProcessor ~= nil,
      hasEnum = (_G.Enum and _G.Enum.TooltipDataType) ~= nil,
      hasGameTooltip = _G.GameTooltip ~= nil,
    })
  end
  return nil
end
