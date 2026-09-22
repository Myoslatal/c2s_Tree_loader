import re

IS_WIN = 'package.config:sub(1, 1) == "\\\\"'

# ---- 1. every `rm -rf` -> Pack.removeTree ----
total = 0
for P in ["_mod_tools/CustomEventPackEditor/main.lua",
          "_mod_tools/CustomEventPackEditor/src/selftest.lua"]:
    t = open(P, encoding="utf-8").read()
    src = t
    t, n1 = re.subn(r'os\.execute\("rm -rf " \.\. Pack\.shellQuote\(([^)]+)\)\)', r"Pack.removeTree(\1)", t)
    t, n2 = re.subn(r'os\.execute\("rm -rf ([^"]+)"\)', r'Pack.removeTree("\1")', t)
    if t != src:
        open(P, "w", encoding="utf-8").write(t)
    total += n1 + n2
    print(P, "->", n1 + n2, "replacement(s)")
print("total rm -rf:", total)

# ---- 2. fonts.lua: isDir and the popen font scan ----
P = "_mod_tools/CustomEventPackEditor/src/fonts.lua"
t = open(P, encoding="utf-8").read()

old = 'local function isDir(path)\n  local p = io.popen("test -d " .. shellQuote(path) .. " && echo y")\n  if not p then return false end\n  local res = p:read("*l")\n  p:close()\n  return res == "y"\nend'
new = """local lfsOk, lfs = pcall(require, "lfs")

--- Test for a directory without a shell. The old version shelled out to `test -d`, which does
--- not exist on Windows and made a console window flash on every call.
local function isDir(path)
  if not lfsOk then return false end
  return lfs.attributes(path, "mode") == "directory"
end"""
assert t.count(old) == 1, ("isDir", t.count(old))
t = t.replace(old, new)

old2 = 'local function popenLines(cmd)\n  local out = {}\n  local p = io.popen(cmd .. " 2>/dev/null")'
new2 = """local function popenLines(cmd)
  local out = {}
  -- Windows has no /dev/null, no POSIX font tools, and io.popen flashes a console window, so the
  -- shell based font scan is skipped there entirely; LOVE falls back to its own font handling.
  if %s then return out end
  local p = io.popen(cmd .. " 2>/dev/null")""" % IS_WIN
assert t.count(old2) == 1, ("popenLines", t.count(old2))
t = t.replace(old2, new2)
open(P, "w", encoding="utf-8").write(t)
print("fonts.lua ported")

# ---- 3. confirm nothing shells out any more ----
import subprocess, glob
left = subprocess.run(["grep","-rn","os.execute\\|io.popen","_mod_tools/CustomEventPackEditor/src","_mod_tools/CustomEventPackEditor/main.lua"],capture_output=True,text=True).stdout
print("remaining shell call sites:", len([l for l in left.split(chr(10)) if l.strip()]))
for l in left.split(chr(10)):
    if l.strip(): print("   ", l[:110])