P = "_mod_tools/CustomEventPackEditor/main.lua"
t = open(P, encoding="utf-8").read()

old = 'local Selftest = require("src.selftest")'
new = """-- A RELEASE build ships src/build.lua containing { release = true }, written by
-- _mod_tools/package_editor_win.sh. In that build the self test and the smoke test are fully
-- disabled and src/selftest.lua is not even packaged: those harnesses assert against the source
-- tree layout (they look for a sibling CustomEvents/ folder) and they drop _selftest_* scratch
-- directories next to the executable - neither belongs in something handed to a user.
-- The development tree has no src/build.lua, so `love . --selftest` keeps working there.
local RELEASE = false
do
  local ok, build = pcall(require, "src.build")
  if ok and type(build) == "table" and build.release then RELEASE = true end
end

local Selftest = (not RELEASE) and require("src.selftest") or nil"""
assert t.count(old) == 1, ("selftest require", t.count(old))
t = t.replace(old, new)

pairs_ = [
  ('  if flags["--selftest"] then', '  if not RELEASE and flags["--selftest"] then'),
  ('  app.noConfig = flags["--smoketest"] ~= nil', '  app.noConfig = (not RELEASE) and flags["--smoketest"] ~= nil'),
  ('  if flags["--smoketest"] then', '  if not RELEASE and flags["--smoketest"] then'),
  ('  ui.endFrame()\n  self:smokeStep()', '  ui.endFrame()\n  if not RELEASE then self:smokeStep() end'),
]
for a, b in pairs_:
    assert t.count(a) == 1, (a, t.count(a))
    t = t.replace(a, b)
open(P, "w", encoding="utf-8").write(t)
print("release gate installed")