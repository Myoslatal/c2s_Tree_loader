import re

# ---------------- D. validate.lua ----------------
V = "_mod_tools/CustomEventPackEditor/src/validate.lua"
v = open(V, encoding="utf-8").read()
s = v.index("    -- Background images: missing file / bad scale / bad opacity")
e = v.index("    -- The panel shows one stage at a time; stages unlock in order")
newv = '''    -- Background image: the pack's single background (or the legacy array's first
    -- visible entry). Only the file's existence can go wrong now - there is no
    -- per-image scale/opacity/position any more.
    local bg = Pack.getBackground(pack)
    if bg then
      if not Pack.exists(Pack.join(pack.dir, bg)) then
        add(problems, "warn", string.format("背景图片不存在：%s（画布上不会显示背景）", bg),
          nil, "background")
      end
    end

'''
v = v[:s] + newv + v[e:]
open(V, "w", encoding="utf-8").write(v)
print("D. validate.lua done;  leftovers:", re.findall(r"backgroundsRaw|backgroundAt|backgroundCount", v))

# ---------------- E. settings.lua ----------------
S = "_mod_tools/CustomEventPackEditor/src/settings.lua"
t = open(S, encoding="utf-8").read()

card = '''--- Background: exactly ONE image. The game replaces its own backdrop with it, so
--- there is nothing to position - the framing is the game's.
local function backgroundCard(app, x, y, w)
  local rel = Pack.getBackground(app.pack)
  local height = 96
  local cy = section("背景图 background", x, y, w, height,
    "游戏内会用它替换原本的背景")
  ui.text(x + 10, cy, rel or "（未设置：游戏内显示原本的背景）",
    { font = "tiny", color = rel and ui.theme.text or ui.theme.textFaint })
  cy = cy + 22
  if ui.button("bg.pick", x + 10, cy, 132, TIGHT, rel and "更换图片…" or "选择图片…",
    { accent = true, tip = "png / jpg，会复制到包的 backgrounds/ 目录" }) then
    app:pickBackgroundFile()
  end
  if rel then
    if ui.button("bg.clear", x + 150, cy, 96, TIGHT, "清除",
      { danger = true, tip = "只清除引用，文件保留在 backgrounds/" }) then
      app:clearBackground()
    end
  end
  return height
end

'''
anchor = "--- Draw the whole settings screen inside the rect."
assert t.count(anchor) == 1
t = t.replace(anchor, card + anchor)

old = '''  cy = cy + lineList(app, "outro", colA, cy, colW, "结束语 outro", "结束语…", math.min(rowsCap, 8)) + gap
'''
new = '''  cy = cy + lineList(app, "outro", colA, cy, colW, "结束语 outro", "结束语…", math.min(rowsCap, 8)) + gap
  cy = cy + backgroundCard(app, colA, cy, colW) + gap
'''
assert t.count(old) == 1
t = t.replace(old, new)
open(S, "w", encoding="utf-8").write(t)
print("E. settings.lua done")
