-- test/export-real.lua — build an export from the REAL SavedVariables.
--
--   cd loot-advisor-addon
--   lua test/export-real.lua [path/to/HoDLootAdvisor.lua] > test/export-real.txt
--
-- Loads the addon against the stubbed client exactly as smoke.lua does, then
-- swaps the live SavedVariables table in as ns.db and calls the addon's OWN
-- Record.Export(). The point is that nothing here re-implements the format:
-- the bytes this prints are the bytes /la export would put in the EditBox, so
-- feeding them to app/lib/loot-export.ts tests the real pair end to end.
--
-- Diagnostic output goes to stderr so stdout stays a clean export.

package.path = "./?.lua;./test/?.lua;" .. package.path

local stub = require("wow-stub")
stub.Install()

local ns = stub.LoadAddon({
  "LootData.lua", "Scoring.lua", "Core.lua", "Settings.lua", "Payload.lua",
  "Diagnostics.lua", "Journal.lua", "Targets.lua", "Tooltip.lua",
  "Record.lua", "Loot.lua",
})

local path = arg[1] or
  "/Applications/World of Warcraft/_retail_/WTF/Account/AELWYN/SavedVariables/HoDLootAdvisor.lua"

local env = {}
local chunk, err = loadfile(path, "t", env)
if not chunk then
  io.stderr:write("could not read SavedVariables: ", tostring(err), "\n")
  os.exit(2)
end
chunk()

local live = env.HoDLootAdvisorDB
if not live or not live.loot then
  io.stderr:write("no HoDLootAdvisorDB.loot in ", path, "\n")
  os.exit(2)
end

-- Swap the real saved table in wholesale. Record reads ns.db.loot.sessions.
ns.db = live

local sessions = live.loot.sessions or {}
io.stderr:write(("loaded %d session(s) from %s\n"):format(#sessions, path))
for i, s in ipairs(sessions) do
  io.stderr:write(("  [%d] %s  %s  %s  kind=%s  items=%d\n"):format(
    i, tostring(s.date), tostring(s.instance), tostring(s.difficulty),
    tostring(s.kind or "guild"), #(s.items or {})))
end

-- Default scope: guild sessions only, which is what "Export Guild Loot" sends.
local mode = arg[2]
local opts = {}
if mode == "personal" then opts.kind = "personal"
elseif mode and tonumber(mode) then opts.index = tonumber(mode) end

local text, count = ns.Record.Export(opts)
if not text then
  io.stderr:write("Record.Export returned nothing (no matching sessions with items)\n")
  os.exit(1)
end

io.stderr:write(("exported %d item row(s), %d bytes\n"):format(count, #text))
io.write(text, "\n")
