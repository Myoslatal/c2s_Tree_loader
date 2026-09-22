-- tests/roundtrip.lua
-- Plain lua entry point:   lua tests/roundtrip.lua
-- (the same suite also runs inside LÖVE via:  love . --selftest)

package.path = "./?.lua;./?/init.lua;" .. package.path

local Selftest = require("src.selftest")
local failed = Selftest.run()
os.exit(failed == 0 and 0 or 1)
