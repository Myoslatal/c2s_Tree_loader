import re, io

# ---------------- A. pack.lua : single-background API ----------------
P = "_mod_tools/CustomEventPackEditor/src/pack.lua"
src = open(P, encoding="utf-8").read()
start = src.index("-- Backgrounds (pack-level optional array")
start = src.rindex("---", 0, start)          # include the leading doc dash line
end = src.index("--- Unique file name inside the pack's backgrounds/ folder.")
new = '''-- Background (pack-level SINGLE image, replaces the game's own backdrop)
--------------------------------------------------------------------------------

Pack.BACKGROUNDS_DIR = "backgrounds"
Pack.BACKGROUND_MAX_BYTES = 16 * 1024 * 1024

--- Relative path of the pack's single background image, or nil when unset.
--- The legacy "backgrounds" array (first visible entry) is still accepted so packs
--- written by older editor builds keep loading; it is migrated on save.
function Pack.getBackground(pack)
  local meta = pack and pack.meta
  if not meta then return nil end
  if type(meta.background) == "string" and meta.background ~= "" then return meta.background end
  local list = meta.backgrounds
  if type(list) == "table" then
    for _, e in ipairs(list) do
      if type(e) == "table" and type(e.file) == "string" and e.file ~= "" and e.visible ~= false then
        return e.file
      end
    end
  end
  return nil
end

--- Set (or clear, by passing nil/"") the single background. Always drops the
--- legacy array so a pack never carries both spellings.
function Pack.setBackground(pack, rel)
  local meta = pack.meta
  meta.backgrounds = nil
  if rel == nil or rel == "" then meta.background = nil else meta.background = rel end
  return meta.background
end

function Pack.hasBackground(pack)
  return Pack.getBackground(pack) ~= nil
end

'''
src = src[:start] + new + src[end:]
open(P, "w", encoding="utf-8").write(src)
print("A. pack.lua rewritten")

# ---------------- B. graph.lua : draw the single background, no edit mode ----------------
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

# replace backgroundRect / bgHit / drawBackgrounds with a single cover draw
s = g.index("--- Values + world rect of one background.")
e = g.index("--------------------------------------------------------------------------------", s)
newg = '''--- Draw the pack's background across the whole viewport.
---
--- COVER, not fit: the game replaces its own backdrop with this image and fills
--- the view with it, cropping whatever overflows. Matching that here means the
--- editor preview shows what the run will actually look like. There is no
--- position/scale/opacity to edit any more - the pack has exactly one background
--- and the game decides the framing.
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

# backgroundImage now takes the pack only (single file)
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
print("B. graph.lua rewritten")
print("   leftover bg refs:", len(re.findall(r"bgMode|bgSelected|bgDrag|backgroundsRaw|backgroundAt|bgHit|drawBackgrounds", g)))
