-- test/package.lua — does the thing we would hand somebody actually work?
--
--   cd loot-advisor-addon
--   ./package.sh && lua test/package.lua dist/HoDLootAdvisor
--
-- ⚠️ THIS IS THE ONE FAILURE A DEVELOPER CANNOT SEE. Every other harness runs
-- against the working tree, where every file exists because it was written
-- there. A package is a SUBSET, and a file left out of it produces an addon
-- that works perfectly on this machine and errors on first load for everybody
-- else — discovered, if at all, by the person you asked to help you test.
--
-- So this loads the addon from the STAGED COPY rather than the source tree,
-- in .toc order, against the stub, and boots it. Anything the .toc names and
-- the package omits fails here instead of on someone else's screen.

package.path = "./?.lua;./test/?.lua;" .. package.path

local dir = arg and arg[1] or "dist/HoDLootAdvisor"

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

io.write("\n", ("─"):rep(72), "\n", "the packaged addon: " .. dir, "\n", ("─"):rep(72), "\n")

-- ── Read the packaged .toc ──────────────────────────────────────────────────

local tocPath = dir .. "/HoDLootAdvisor.toc"
local toc = io.open(tocPath, "r")
check("the package contains its .toc", toc ~= nil, tocPath)
if not toc then
  io.write("\nnothing to test — run ./package.sh first\n")
  os.exit(2)
end
local tocText = toc:read("*a")
toc:close()

-- ── The version has to be real ──────────────────────────────────────────────

local version = tocText:match("##%s*Version:%s*(%S+)")
check("the .toc declares a version", version ~= nil, version)
check("...and the packager token was substituted",
      version and not version:find("@"), version)

-- ⚠️ TWO CLIENTS BOTH REPORTING "dev" CANNOT BE TOLD APART, and the version
-- each peer announces over HELLO is exactly what a two-client test inspects.
-- A package that ships the raw token is worse than useless for that.
check("...so peers will announce something meaningful",
      version ~= "dev" and version ~= "@project-version@", version)

-- ── Every file it names must be present ─────────────────────────────────────

local files = {}
for line in tocText:gmatch("[^\r\n]+") do
  local f = line:match("^([%w_]+%.lua)%s*$")
  if f then files[#files + 1] = f end
end
check("the .toc lists Lua files", #files > 0, #files)

local missing = {}
for _, f in ipairs(files) do
  local fh = io.open(dir .. "/" .. f, "r")
  if fh then fh:close() else missing[#missing + 1] = f end
end
check("every file the .toc loads is in the package",
      #missing == 0, table.concat(missing, ", "))

-- Fonts are a LICENCE requirement, not an asset preference: the SIL licence has
-- to travel with the font software, and a correct path to a font nobody copied
-- looks identical in code while silently falling back to the game font.
for _, required in ipairs({
  "Media/fonts/OFL.txt", "Media/fonts/FONT-LICENSES.md",
  "Media/fonts/Khand-Medium.ttf", "Media/fonts/GeneralSans-Regular.ttf",
}) do
  local fh = io.open(dir .. "/" .. required, "r")
  check("ships " .. required, fh ~= nil)
  if fh then fh:close() end
end

-- ── And it has to boot ──────────────────────────────────────────────────────

stub.Install()
local realPrint = _G.print
_G.print = function() end

local loaded, err = pcall(function()
  local ns = {}
  for _, f in ipairs(files) do
    -- LoadWindow / RecordWindow / Panel build real frames and are excluded from
    -- the other harnesses for that reason; here we only need to know the FILE
    -- is present and parses, which the compile below establishes without
    -- running it.
    local chunk, loadErr = loadfile(dir .. "/" .. f)
    if not chunk then error(f .. ": " .. tostring(loadErr)) end
    if f ~= "LoadWindow.lua" and f ~= "RecordWindow.lua" and f ~= "Panel.lua" then
      chunk("HoDLootAdvisor", ns)
    end
  end
  return ns
end)
_G.print = realPrint

check("every packaged file compiles", loaded, err)

if loaded then
  local ns = _G.HoDLootAdvisor
  check("the addon namespace came up", ns ~= nil)
  check("the baked loot data loaded from the package",
        _G.HoDLootAdvisorData ~= nil)
  local summary = ns and ns.DataSummary()
  check("...and it carries real items", summary and summary.items > 0,
        summary and summary.items)
  -- Against the addon's OWN declaration, not a number repeated here: two copies
  -- of an expected schema is one of them going stale.
  check("...at the schema the addon expects",
        summary and ns and summary.schema == ns.EXPECTED_SCHEMA,
        summary and ("payload %s vs expected %s"):format(
          tostring(summary.schema), tostring(ns and ns.EXPECTED_SCHEMA)))
  check("comms is present in the package", ns and ns.Comms ~= nil)
  check("the roster scanner is present", ns and ns.Roster ~= nil)
end

-- ── Every Media file the code names is actually in the package ──────────────
-- ⚠️ A MISSING TEXTURE DRAWS NOTHING, SILENTLY. No error, no placeholder — the
-- mark or icon is simply absent, which looks like a feature that was never
-- built rather than a file that did not ship. Adding art means adding a path
-- string, and a path string is not checked by anything else here: the Lua
-- compiles fine whether or not the file exists.
--
-- Scanned out of the SOURCES rather than listed here, so new art is covered the
-- day it is referenced instead of the day somebody remembers this test.
do
  local root = arg[1] or "dist/HoDLootAdvisor"
  local refs, missing, scanned = 0, {}, 0
  local names = io.popen('ls "' .. root .. '"/*.lua 2>/dev/null')
  for file in names:lines() do
    scanned = scanned + 1
    local fh = io.open(file, "r")
    if fh then
      local body = fh:read("*a"); fh:close()
      -- "Interface\\AddOns\\HoDLootAdvisor\\Media\\..." as it appears in source.
      for path in body:gmatch('Interface\\\\AddOns\\\\HoDLootAdvisor\\\\([%w\\_%-%.]+)') do
        local rel = path:gsub('\\\\', '/')
        -- Only whole filenames; a bare directory prefix built at runtime is not
        -- a claim that a file exists.
        if rel:match('%.%w+$') then
          refs = refs + 1
          local f = io.open(root .. '/' .. rel, "rb")
          if f then f:close() else missing[#missing + 1] = rel end
        end
      end
    end
  end
  names:close()
  check("the package's Lua files were scanned for media paths", scanned > 0, scanned)
  check("...and they reference at least one media file", refs > 0, refs)
  check("every media file the code names is in the package",
        #missing == 0, table.concat(missing, ", "))
end

io.write("\n", ("═"):rep(72), "\n")
if #failures == 0 then
  io.write(("PASS — %d checks, the packaged copy\n"):format(checks))
  os.exit(0)
end
io.write(("FAIL — %d of %d checks\n\n"):format(#failures, checks))
for _, f in ipairs(failures) do io.write("  · ", f, "\n") end
os.exit(1)
