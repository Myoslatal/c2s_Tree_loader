import re

G = "_mod_tools/CustomEventPackEditor/src/graph.lua"
g = open(G, encoding="utf-8").read()

g = g.replace("""    bgMode = false,        -- Ctrl+B background-edit mode
    bgSelected = nil,      -- index of the selected background
    bgDrag = nil,          -- active drag { index, wx, wy, x, y }
""", "")

g = g.replace("""  local hint = self.bgMode
    and "背景编辑模式：左键拖动图片 · Ctrl+B 退出 · 滚轮缩放"
    or "中键/右键/空格+拖动 或 WASD 平移 · N 新建节点 · Ctrl+F 适应"
""", """  local hint = "中键/右键/空格+拖动 或 WASD 平移 · N 新建节点 · Ctrl+F 适应"
""")

s = g.index("--- Values + world rect of one background.")
e = g.index("function Graph:draw(app)", s)
newg = '''--- Draw the pack's background across the whole viewport.
---
--- COVER, not fit: the game replaces its own backdrop with this image and fills
--- the view with it, cropping whatever overflows. Matching that here means the
--- editor preview shows what the run will actually look like. There is no
--- position / scale / opacity to edit any more - a pack has exactly ONE
--- background and the game decides the framing.
function Graph:drawBackground(pack)
  local img = self:backgroundImage(pack)
  if not img.ok then return end
  local cw, ch = love.graphics.getDimensions()
  local s = MAX(cw / img.w, ch / img.h)
  local w, h = img.w * s, img.h * s
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(img.image, (cw - w) / 2, (ch - h) / 2, 0, s, s)
end

'''
g = g[:s] + newg + g[e:]

g = g.replace("""function Graph:backgroundImage(pack, file)
  local key = tostring(pack and pack.dir or "") .. "|" .. tostring(file)""",
"""function Graph:backgroundImage(pack)
  local file = Pack.getBackground(pack)
  if not file then
    return { ok = false, image = nil, w = 0, h = 0 }
  end
  local key = tostring(pack and pack.dir or "") .. "|" .. tostring(file)""")

g = g.replace("""    local path = Pack.join(pack.dir, file)
    if file ~= "" and Pack.exists(path) then""",
"""    local path = Pack.join(pack.dir, file)
    if Pack.exists(path) then""")

g = g.replace("  if pack then self:drawBackgrounds(pack) end",
              "  if pack then self:drawBackground(pack) end")
open(G, "w", encoding="utf-8").write(g)
left = re.findall(r"bgMode|bgSelected|bgDrag|backgroundsRaw|backgroundAt|bgHit|drawBackgrounds|backgroundRect", g)
print("B. graph.lua done; leftover refs:", left)
