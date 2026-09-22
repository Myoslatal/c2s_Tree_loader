P = "_mod_tools/CustomEventPackEditor/main.lua"
t = open(P, encoding="utf-8").read()
prologue = """-- ---------------------------------------------------------------- source path fix --
-- In a FUSED build (love.exe with the .love concatenated onto it - that is how the shipped
-- Windows CePackEditor.exe is made) love.filesystem.getSource() returns the path of the EXE
-- FILE, not of a directory. Every caller in this editor treats that value as a directory, so
-- paths came out as ".../CePackEditor.exe/../CustomEvents/..." and the sample pack, the config
-- file and the selftest scratch directories all failed to resolve (8 selftest failures, and a
-- draw-time crash in the smoke test). Normalise it once, here, before anything reads it.
do
  local raw = love and love.filesystem and love.filesystem.getSource
  if raw then
    local memo
    love.filesystem.getSource = function()
      if memo ~= nil then return memo end
      local src = raw()
      -- only .exe is rewritten: a fused build is the only case where this is a file, and
      -- matching on a bare extension would also mangle directories whose name contains a dot
      if type(src) == "string" and src:lower():match("%.exe$") then
        local dir = src:match("^(.*)[\\\\/][^\\\\/]*$")
        if dir and dir ~= "" then src = dir end
      end
      memo = src
      return src
    end
  end
end

"""
assert not t.startswith("-- ------"), "already patched"
open(P, "w", encoding="utf-8").write(prologue + t)
print("source path fix prepended to main.lua")