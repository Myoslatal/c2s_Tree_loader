BS = chr(92)          # a single backslash, built without any escaping games
Q = chr(34)

P = "_mod_tools/CustomEventPackEditor/src/fonts.lua"
t = open(P, encoding="utf-8").read()

old = "  -- 1. explicit path first"
new = "\n".join([
  "  -- 0. Windows first. Every root below this block is a POSIX path and the whole search runs",
  "  -- through `find` and fc-list, so a Windows build found no CJK font at all and rendered every",
  "  -- Chinese glyph as a box. These are the fonts Windows itself ships; Microsoft YaHei is present",
  "  -- on every Windows 7+ install regardless of the display language, so it leads the list.",
  "  if package.config:sub(1, 1) == " + Q + BS + BS + Q + " then",
  "    local windir = os.getenv(" + Q + "WINDIR" + Q + ") or " + Q + "C:" + BS + BS + "Windows" + Q,
  "    local dirs = { windir .. " + Q + BS + BS + "Fonts" + Q + " }",
  "    local localApp = os.getenv(" + Q + "LOCALAPPDATA" + Q + ")",
  "    if localApp then dirs[#dirs + 1] = localApp .. " + Q + BS + BS + "Microsoft" + BS + BS + "Windows" + BS + BS + "Fonts" + Q + " end",
  "    local names = {",
  "      " + Q + "msyh.ttc" + Q + ", " + Q + "msyh.ttf" + Q + ", " + Q + "msyhbd.ttc" + Q + ",   -- Microsoft YaHei (Simplified)",
  "      " + Q + "simhei.ttf" + Q + ", " + Q + "simsun.ttc" + Q + ",             -- SimHei / SimSun",
  "      " + Q + "Deng.ttf" + Q + ", " + Q + "simkai.ttf" + Q + ", " + Q + "simfang.ttf" + Q + ",",
  "      " + Q + "msjh.ttc" + Q + ", " + Q + "msjhbd.ttc" + Q + ",               -- Microsoft JhengHei (Traditional)",
  "    }",
  "    for _, d in ipairs(dirs) do",
  "      for _, n in ipairs(names) do add(d .. " + Q + BS + BS + Q + " .. n) end",
  "    end",
  "  end",
  "",
  "  -- 1. explicit path first",
])
assert t.count(old) == 1, t.count(old)
open(P, "w", encoding="utf-8").write(t.replace(old, new, 1))
print("windows font candidates added")