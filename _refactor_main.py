import re
P = "_mod_tools/CustomEventPackEditor/main.lua"
lines = open(P, encoding="utf-8").read().split("\n")

def splice(a, b, new):          # 1-indexed inclusive
    global lines
    lines = lines[:a-1] + new.split("\n") + lines[b:]

# ---- (1) selftest block: 1541..1799 ----
assert lines[1541-1].startswith("--- Background images"), lines[1541-1]
assert lines[1799-1] == "end", lines[1799-1]
newbg = '''--- Background image: a pack has exactly ONE. It is copied into backgrounds/ and
--- recorded as pack.json's "background"; the game replaces its own backdrop with
--- it. No multi-image list, no per-image transform.
local function buildBgSteps(app)
  local steps = {}
  local function add(t) steps[#steps + 1] = t end
  local function rendered() return table.concat(ui.renderedText, string.char(10)) end
  --- A generated, guaranteed-valid PNG (the bundled sample icons are not
  --- loadable images, so they cannot prove the copy path).
  local function testPng()
    local path = "/tmp/c2s_smoke_background.png"
    if app.smoke.testPngPath then return app.smoke.testPngPath end
    local w, h = 200, 140
    local id = love.image.newImageData(w, h)
    id:mapPixel(function(x, y)
      local a = (math.floor(x / 20) + math.floor(y / 20)) % 2 == 0
      return a and 0.20 or 0.55, a and 0.40 or 0.80, a and 0.85 or 0.30, 1
    end)
    local bytes = id:encode("png"):getString()
    local f = io.open(path, "wb")
    if f then f:write(bytes) f:close() end
    app.smoke.testPngPath = path
    return path
  end

  add({ setup = function()
        app.view = "settings"
        app.dirty = false
        Pack.setBackground(app.pack, nil)
        app.graph:resetBackgroundCache()
        app.smoke.bgHad = Pack.hasBackground(app.pack)
      end })
  add({ check = function() return app.smoke.bgHad == false end,
      name = "background: a pack starts with no background" })

  add({ setup = function() app:setBackgroundFromFile(testPng()) end })
  add({ check = function()
        local rel = Pack.getBackground(app.pack)
        app.smoke.bgRel = rel
        return type(rel) == "string" and rel ~= ""
          and rel:sub(1, #Pack.BACKGROUNDS_DIR) == Pack.BACKGROUNDS_DIR
          and Pack.exists(Pack.join(app.pack.dir, rel))
      end, name = "background: picking an image copies it into backgrounds/ and sets 'background'",
      detail = function() return tostring(app.smoke.bgRel) end })
  add({ check = function() return app.pack.meta.backgrounds == nil end,
      name = "background: the legacy 'backgrounds' array is dropped (one spelling only)" })
  add({ setup = function()
        local rel = Pack.getBackground(app.pack)
        local function slurp(p)
          local f = io.open(p, "rb")
          if not f then return nil end
          local d = f:read("*a")
          f:close()
          return d
        end
        local a, b = slurp(testPng()), slurp(Pack.join(app.pack.dir, rel))
        app.smoke.bgSame = (a ~= nil and b ~= nil and #a == #b and a == b)
        local img = Pack.loadImage(rel)
        app.smoke.bgLoads = (img ~= nil and img:getWidth() > 0 and img:getHeight() > 0)
        app.smoke.bgW = img and img:getWidth() or -1
        app.smoke.bgH = img and img:getHeight() or -1
      end })
  add({ check = function() return app.smoke.bgSame end,
      name = "background: the copied png is byte-identical to the source" })
  add({ check = function() return app.smoke.bgLoads end,
      name = "background: the copied png decodes",
      detail = function() return string.format("%dx%d", app.smoke.bgW, app.smoke.bgH) end })
  add({ setup = function() app.graph:resetBackgroundCache() end })
  add({ check = function()
        local img = app.graph:backgroundImage(app.pack)
        return img.ok and img.w > 0 and img.h > 0
      end, name = "background: the canvas decodes and caches it" })
  add({ setup = function() app.view = "graph" end })
  add({ shot = "smoketest_background.png" })
  add({ check = function()
        local img = app.graph:backgroundImage(app.pack)
        local cw, ch = love.graphics.getDimensions()
        local s = math.max(cw / img.w, ch / img.h)
        app.smoke.bgCover = { w = img.w * s, h = img.h * s, cw = cw, ch = ch }
        return img.w * s >= cw - 0.5 and img.h * s >= ch - 0.5
      end, name = "background: drawn COVER (fills the viewport) like the game does",
      detail = function()
        local c = app.smoke.bgCover
        return string.format("%.0fx%.0f over %dx%d", c.w, c.h, c.cw, c.ch)
      end })
  add({ setup = function() app.view = "settings" end })
  add({ check = function() return rendered():find("背景", 1, true) ~= nil end,
      name = "background: the settings panel renders the background row" })
  add({ setup = function() app:clearBackground() end })
  add({ check = function() return Pack.hasBackground(app.pack) == false end,
      name = "background: clearing removes it from pack.json" })
end'''
splice(1541, 1799, newbg)
txt = "\n".join(lines)

# ---- (2) Ctrl+B handler: keep the shift branch, drop background mode ----
old = '''  if ctrl and key == "b" then
    if shift then
      app.showSidebar = not app.showSidebar
      app:setStatus(app.showSidebar and "显示左侧活动包列表" or "隐藏左侧活动包列表")
    else
      app:toggleBackgroundMode()
    end
    return
  end'''
new = '''  if ctrl and key == "b" and shift then
    app.showSidebar = not app.showSidebar
    app:setStatus(app.showSidebar and "显示左侧活动包列表" or "隐藏左侧活动包列表")
    return
  end'''
assert txt.count(old) == 1, txt.count(old)
txt = txt.replace(old, new)

# ---- (3) the background-edit panel call ----
old = "    self:drawBackgroundPanel()\n"
assert txt.count(old) == 1
txt = txt.replace(old, "")

# ---- (4) the panel-swallows-click check ----
old = '''  local bp = self:backgroundPanelRect()
  if bp and ui.rectContains(bp.x, bp.y, bp.w, bp.h, lx, ly) then return false end
'''
assert txt.count(old) == 1
txt = txt.replace(old, "")

# ---- (5) the whole background section ----
lines = txt.split("\n")
a = next(i for i,l in enumerate(lines) if l.startswith("-- Background images")) - 1
b = next(i for i,l in enumerate(lines) if l.startswith("-- New node")) - 2
assert lines[a].startswith("---"), lines[a]
assert lines[a+1].startswith("-- Background images"), lines[a+1]
newsec = '''-- Background image (a pack has exactly ONE; it replaces the game's backdrop)
--------------------------------------------------------------------------------

--- Copy a picked image into the pack's backgrounds/ folder and make it THE
--- background. Replaces whatever was set before - there is only ever one.
function App:setBackgroundFromFile(src)
  local pack = self.pack
  if not pack then return nil end
  if type(src) ~= "string" or src == "" then return nil end
  local ext = (src:match("%.([%w]+)$") or ""):lower()
  if ext ~= "png" and ext ~= "jpg" and ext ~= "jpeg" then
    self:error("只支持 png / jpg / jpeg 背景图片")
    return nil
  end
  local dir = Pack.join(pack.dir, Pack.BACKGROUNDS_DIR)
  Pack.mkdirp(dir)
  local name = Pack.uniqueBackgroundName(pack, Pack.basename(src))
  local dst = Pack.join(dir, name)
  local ok, err = Pack.copyFile(src, dst)
  if not ok then
    self:error("复制背景图片失败: " .. tostring(err))
    return nil
  end
  Pack.setBackground(pack, Pack.BACKGROUNDS_DIR .. "/" .. name)
  self.graph:resetBackgroundCache()
  self.dirty = true
  self:setStatus("背景已设为 " .. name .. "（游戏内会替换原背景，Ctrl+S 保存）")
  return name
end

function App:pickBackgroundFile()
  local pack = self.pack
  if not pack then
    self:error("没有打开的包：先新建或打开一个活动包")
    return
  end
  self:openBrowser({
    mode = "image",
    title = "选择背景图片（png / jpg）",
    path = pack.dir,
    onAccept = function(file) self:setBackgroundFromFile(file) end,
  })
end

--- Drop the background reference. The file itself stays in backgrounds/.
function App:clearBackground()
  local pack = self.pack
  if not pack then return end
  if not Pack.hasBackground(pack) then
    self:setStatus("这个包还没有设置背景")
    return
  end
  Pack.setBackground(pack, nil)
  self.graph:resetBackgroundCache()
  self.dirty = true
  self:setStatus("已清除背景（文件仍保留在 backgrounds/）")
end

'''
lines = lines[:a] + newsec.split("\n") + lines[b:]
open(P, "w", encoding="utf-8").write("\n".join(lines))
print("main.lua refactored;", len(lines), "lines")
left = [l for l in lines if re.search(r"bgMode|bgSelected|bgDrag|backgroundsRaw|backgroundAt|backgroundCount|addBackground|removeBackground|moveBackground|fitBackground|drawBackgroundPanel|backgroundPanelRect|toggleBackgroundMode|bgHit", l)]
print("leftover refs:", len(left))
for l in left[:8]: print("   ", l.strip()[:90])
