-- ---------------------------------------------------------------- source path fix --
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
        local dir = src:match("^(.*)[\\/][^\\/]*$")
        if dir and dir ~= "" then src = dir end
      end
      memo = src
      return src
    end
  end
end

-- main.lua
-- Cell to Singularity - custom exploration event pack editor.
-- Single window LÖVE 11.5 desktop app.
--
--   love .                 run the editor
--   love . --selftest      head-less JSON / pack round trip test, prints PASS/FAIL
--   love . --smoketest     boot, drive a few frames, save a screenshot, quit

local Pack = require("src.pack")
local ui = require("src.ui")
local Fonts = require("src.fonts")
local Graph = require("src.graph")
local Inspector = require("src.inspector")
local Settings = require("src.settings")
local Validate = require("src.validate")
local FileBrowser = require("src.filebrowser")
-- A RELEASE build ships src/build.lua containing { release = true }, written by
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

local Selftest = (not RELEASE) and require("src.selftest") or nil
local json = require("src.json")
local Config = require("src.config")

local FLOOR, MIN, MAX = math.floor, math.min, math.max
local NL = string.char(10)

local App = {}
App.__index = App

--------------------------------------------------------------------------------
-- App state
--------------------------------------------------------------------------------

function App.new()
  local self = setmetatable({}, App)
  self.root = Pack.workspaceRoot()
  self.pack = nil
  self.selection = {}
  self.selectionSet = {}
  self.primaryUid = nil
  self.dirty = false
  self.view = "graph"
  self.status = "就绪"
  self.banner = nil
  self.packs = {}
  self.showSidebar = true
  self.showInspector = true
  self.showHelp = false
  self.modal = nil
  self.newPack = nil
  self.graph = Graph.new()
  self.problems = {}
  self.counts = { error = 0, warn = 0, info = 0 }
  self.validateTimer = 0
  self.smoke = nil
  self.pathDraft = ""
  self.canvas = { x = 0, y = 0, w = 10, h = 10 }
  self.uiScale = 1
  self.configPath = nil
  self.noConfig = false          -- set by --smoketest: never touch editor.cfg
  self.effSidebar = true         -- panels that actually fit this frame
  self.effInspector = true
  self.zoomBar = { x = 0, y = 0, w = 0, h = 0 }
  self.bannerRect = { x = 0, y = 0, w = 0, h = 0 }
  return self
end

function App:setStatus(msg)
  if not msg then return end
  self.status = msg
end

function App:error(msg)
  self.banner = { text = tostring(msg), level = "error" }
  self.status = "错误: " .. tostring(msg)
  print("[error] " .. tostring(msg))
end

function App:info(msg)
  self.banner = { text = tostring(msg), level = "info" }
  self.status = tostring(msg)
end

--------------------------------------------------------------------------------
-- Selection
--------------------------------------------------------------------------------

function App:syncSelection()
  self.selectionSet = {}
  for _, uid in ipairs(self.selection) do self.selectionSet[uid] = true end
  if #self.selection == 0 then
    self.primaryUid = nil
  elseif not self.selectionSet[self.primaryUid] then
    self.primaryUid = self.selection[#self.selection]
  end
end

function App:setSelection(list)
  self.selection = {}
  for _, uid in ipairs(list) do self.selection[#self.selection + 1] = uid end
  self.primaryUid = self.selection[#self.selection]
  self:syncSelection()
end

function App:toggleSelection(uid)
  local found = false
  for i, u in ipairs(self.selection) do
    if u == uid then
      table.remove(self.selection, i)
      found = true
      break
    end
  end
  if not found then self.selection[#self.selection + 1] = uid end
  self.primaryUid = uid
  self:syncSelection()
end

function App:replaceSelection(oldUid, newUid)
  for i, u in ipairs(self.selection) do
    if u == oldUid then self.selection[i] = newUid end
  end
  if self.primaryUid == oldUid then self.primaryUid = newUid end
  self:syncSelection()
end

function App:deleteSelected()
  if not self.pack or #self.selection == 0 then
    self:setStatus("没有选中任何节点")
    return
  end
  local n = 0
  local removedRefs, removedReqs = 0, 0
  for _, uid in ipairs(self.selection) do
    local cleaned, err = Pack.removeNode(self.pack, uid)
    if cleaned then
      n = n + 1
      removedRefs = removedRefs + cleaned.effects
      removedReqs = removedReqs + cleaned.requirements
    else
      self:error(err)
    end
  end
  self:setSelection({})
  self.dirty = true
  self:setStatus(string.format("删除 %d 个节点（同时清理了 %d 条特效、%d 条前置）",
    n, removedRefs, removedReqs))
end

--------------------------------------------------------------------------------
-- Pack lifecycle
--------------------------------------------------------------------------------

function App:rescan()
  self.packs = Pack.scan(Pack.defaultRoots(self.root))
  self:setStatus("扫描到 " .. #self.packs .. " 个活动包")
end

function App:openPack(dir)
  local pack, err = Pack.load(dir)
  if not pack then
    self:error("打开失败: " .. tostring(err))
    return false
  end
  if self.dirty then
    self:info("注意：上一个包有未保存的修改，已被丢弃")
  end
  self.pack = pack
    Pack.setImageRoot(pack.dir)
  self.dirty = false
  for _, w in ipairs(pack.warnings or {}) do
    self:error("tree.json 警告: " .. w)
  end
  self:setSelection({})
  self.graph:invalidateIcons()
  self.needsFit = true
  -- a freshly opened pack starts at the top of every list
  for _, id in ipairs({ "settings", "set.missions", "set.currencies", "set.localization",
    "set.intro", "set.outro", "set.preview", "inspector", "sidebar.list", "validate.list" }) do
    local st = ui.state[id]
    if st then
      st.scroll = 0
      st.hscroll = 0
    end
  end
  self.pathDraft = dir
  self.banner = nil
  self:setStatus("已打开 " .. Pack.basename(dir) .. "（" .. #pack.tree.nodes .. " 个节点）")
  self:validate(true)
  return true
end

function App:save()
  if not self.pack then
    self:setStatus("没有打开的包")
    return false
  end
  local ok, err = Pack.save(self.pack)
  if not ok then
    self:error("保存失败: " .. tostring(err))
    return false
  end
  self.dirty = false
  self.graph:invalidateIcons()
  self:setStatus("已保存 " .. self.pack.treePath)
  self:validate(true)
  return true
end

function App:saveAs(dir)
  if not self.pack then return false end
  local ok, err = Pack.save(self.pack, dir)
  if not ok then
    self:error("另存失败: " .. tostring(err))
    return false
  end
  self.dirty = false
  self.graph:invalidateIcons()
  self:setStatus("已另存到 " .. dir)
  self:rescan()
  return true
end

function App:createPack(parent, id, title)
  if not parent or parent == "" then
    self:error("请选择父目录")
    return false
  end
  local dir = Pack.join(parent, id)
  local pack, err = Pack.newPack(dir, id, title)
  if not pack then
    self:error("新建失败: " .. tostring(err))
    return false
  end
  self:rescan()
  return self:openPack(dir)
end

--------------------------------------------------------------------------------
-- Modal helpers
--------------------------------------------------------------------------------

function App:openBrowser(opts)
  self.modal = FileBrowser.new(opts)
end

function App:openIconPicker(uid)
  self:openBrowser({
    mode = "image",
    title = "为 " .. uid .. " 选择图标",
    path = self.pack and self.pack.dir or self.root,
    onAccept = function(file)
      local path, err = Pack.assignIcon(self.pack, uid, file)
      if not path then
        self:error("设置图标失败: " .. tostring(err))
        return
      end
      self.graph:invalidateIcons()
      self.dirty = true
      self:setStatus("图标已更新 " .. Pack.basename(path))
    end,
  })
end

--- Pick an image and copy it into the pack folder; cb(relativeName)
function App:pickFileToPack(cb)
  if not self.pack then return end
  self:openBrowser({
    mode = "image",
    title = "选择要复制进包里的图片",
    path = self.pack.dir,
    onAccept = function(file)
      local name = Pack.basename(file)
      local dst = Pack.join(self.pack.dir, name)
      if file ~= dst then
        local ok, err = Pack.copyFile(file, dst)
        if not ok then
          self:error("复制失败: " .. tostring(err))
          return
        end
      end
      self.dirty = true
      if cb then cb(name) end
    end,
  })
end

--------------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------------

function App:validate(force)
  if not self.pack then
    self.problems = {}
    self.counts = { error = 0, warn = 0, info = 0 }
    return
  end
  local problems, counts = Validate.run(self.pack)
  self.problems = problems
  self.counts = counts
end

--------------------------------------------------------------------------------
-- Per-frame update
--------------------------------------------------------------------------------

--- Is a Ctrl key held? (overridable so tests can exercise the guards)
function App:ctrlDown()
  if self.ctrlOverride ~= nil then return self.ctrlOverride end
  return love.keyboard.isDown("lctrl", "rctrl")
end

function App:update(dt)
  self.validateTimer = self.validateTimer + dt
  if self.validateTimer > 0.5 then
    self.validateTimer = 0
    self:validate()
  end

  -- WASD pans the canvas. Disabled while a text field has focus (the letter
  -- belongs to the field then), while a modal is open, and while Ctrl is held
  -- (Ctrl+D / Ctrl+A keep working).
  local ctrl = self:ctrlDown()
  if ui.focus or self.modal or self.showHelp or self.newPack or ctrl then
    self.graph:clearPanKeys()
    return
  end
  local fast = self.panFastOverride
  if fast == nil then fast = love.keyboard.isDown("lshift", "rshift") end
  self.graph:updatePan(dt, fast)
end

--------------------------------------------------------------------------------
-- Editor preferences (editor.cfg) and the global UI scale
--------------------------------------------------------------------------------

function App:loadConfig()
  self.configPath = Config.defaultPath(love.filesystem.getSource())
  if self.noConfig then
    ui.setScale(self.uiScale)
    return
  end
  local cfg = Config.load(self.configPath)
  self.uiScale = Config.normalizeScale(cfg.ui_scale or 1)
  ui.setScale(self.uiScale)
  if type(cfg.sidebar) == "boolean" then self.showSidebar = cfg.sidebar end
  if type(cfg.inspector) == "boolean" then self.showInspector = cfg.inspector end
  if cfg.view == "graph" or cfg.view == "settings" or cfg.view == "validate" then self.view = cfg.view end
  self.lastPack = type(cfg.last_pack) == "string" and cfg.last_pack or nil
  self.graph.panSpeed = math.max(200, math.min(3000, tonumber(cfg.pan_speed) or self.graph.panSpeed))
end

function App:saveConfig()
  if self.noConfig or not self.configPath then return end
  Config.save(self.configPath, {
    ui_scale = self.uiScale,
    sidebar = self.showSidebar,
    inspector = self.showInspector,
    view = self.view,
    last_pack = self.pack and self.pack.dir or self.lastPack or "",
    pan_speed = self.graph.panSpeed,
  })
end

--- Canvas pan speed in PHYSICAL pixels per second (WASD; Shift multiplies it).
function App:setPanSpeed(v)
  v = math.max(200, math.min(3000, math.floor(((tonumber(v) or 900) / 50) + 0.5) * 50))
  if v == self.graph.panSpeed then return end
  self.graph.panSpeed = v
  self:saveConfig()
  self:setStatus(string.format("画布平移速度 %d px/s（WASD 平移，Shift x%d）", v, self.graph.panFastScale))
end

--- Change the global UI scale. Fonts are re-rasterised at the new pixel size
--- (they are cached per pixel size), panel sizes and widget metrics follow
--- because every ui.* coordinate is scaled by ui.s().
function App:setUIScale(v)
  v = Config.normalizeScale(v)
  if math.abs(v - self.uiScale) < 0.005 then return end
  self.uiScale = v
  ui.setScale(v)
  self:saveConfig()
  self:setStatus(string.format("界面缩放 %d%%（Ctrl+0 复位，Ctrl+加号/减号调整）",
    math.floor(v * 100 + 0.5)))
end

--- Ctrl/Cmd + wheel: zoom the whole editor UI. The world point under the
--- cursor on the canvas, and the content under the cursor inside a scroll
--- region, both stay anchored while the scale changes.
function App:wheelUIScale(dy)
  local a = self.uiScale
  local b = Config.normalizeScale(a * (1.06 ^ dy))
  if math.abs(b - a) < 0.0001 then return end
  local px, py = ui.wheelX * a, ui.wheelY * a          -- physical cursor position
  local anchored = self:canvasAccepts(px, py)
  local wx, wy
  if anchored then wx, wy = self.graph:screenToWorld(px, py) end

  -- keep the row that is under the cursor under the cursor: a logical position
  -- L is drawn at (L - scroll) * scale, so scroll must become
  -- scroll + Y * (1/a - 1/b) to hold the pixel row Y fixed
  local adjustY = py * (1 / a - 1 / b)
  local adjustX = px * (1 / a - 1 / b)
  for _, r in ipairs(ui.prevRegions or {}) do
    if ui.rectContains(r.x, r.y, r.w, r.h, ui.wheelX, ui.wheelY) then
      local st = ui.stateFor(r.id)
      st.scroll = (st.scroll or 0) + adjustY
      st.hscroll = (st.hscroll or 0) + adjustX
    end
  end

  self.uiScale = b
  ui.setScale(b)
  self:layout()

  if anchored then
    local sx, sy = self.graph:worldToScreen(wx, wy)
    self.graph.camx = self.graph.camx + (sx - px) / self.graph.zoom
    self.graph.camy = self.graph.camy - (sy - py) / self.graph.zoom
  end
  self:saveConfig()
  self:setStatus(string.format("界面缩放 %d%%（Ctrl+滚轮 / Ctrl+加减号 / Ctrl+0 复位）",
    math.floor(b * 100 + 0.5)))
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

--- Compute every panel rect ONCE per frame, in logical units, with explicit
--- gutters. Panels therefore never share pixels: the canvas is whatever is left
--- between the side panels, and panels are dropped (sidebar first) when the
--- window is too narrow for the minimum widths.
function App:layout()
  local W, H = ui.dims()
  local gutter = 1
  local topH = 44
  local statusH = 26
  local bodyY = topH + gutter
  local bodyH = math.max(80, H - bodyY - statusH - gutter)

  local minCanvas = 220
  local minInspector = 260
  local sidebarW = self.showSidebar and 240 or 0
  local rightW = self.showInspector and 430 or 0

  if sidebarW + rightW + minCanvas + gutter * 2 > W then
    sidebarW = 0
  end
  local avail = W - sidebarW - minCanvas - gutter * 2
  if rightW > avail then rightW = math.max(0, avail) end
  if rightW < minInspector then rightW = 0 end

  self.effSidebar = sidebarW > 0
  self.effInspector = rightW > 0

  self.top = { x = 0, y = 0, w = W, h = topH }
  self.sidebar = { x = 0, y = bodyY, w = sidebarW, h = bodyH }
  self.right = { x = W - rightW, y = bodyY, w = rightW, h = bodyH }
  local cx = sidebarW + (sidebarW > 0 and gutter or 0)
  local cw = (W - rightW - (rightW > 0 and gutter or 0)) - cx
  self.canvas = { x = cx, y = bodyY, w = math.max(60, cw), h = bodyH }
  self.statusBar = { x = 0, y = H - statusH, w = W, h = statusH }
  self.zoomBar = { x = self.canvas.x + self.canvas.w - 320, y = self.canvas.y + self.canvas.h - 36, w = 312, h = 28 }
  self.bannerRect = { x = self.canvas.x + 10, y = self.canvas.y + 8, w = self.canvas.w - 20, h = 30 }

  -- the renderer works in physical pixels
  self.graph.vx, self.graph.vy = ui.s(self.canvas.x), ui.s(self.canvas.y)
  self.graph.vw, self.graph.vh = ui.s(self.canvas.w), ui.s(self.canvas.h)
end

--- Panel rects that are actually drawn this frame (used by the overlap test).
function App:panelRects()
  local list = {
    { name = "top", r = self.top },
    { name = "canvas", r = self.canvas },
    { name = "status", r = self.statusBar },
  }
  if self.effSidebar then list[#list + 1] = { name = "sidebar", r = self.sidebar } end
  if self.effInspector and self.view == "graph" then
    list[#list + 1] = { name = "inspector", r = self.right }
  end
  return list
end

--- Returns a description of the first overlapping pair, or nil when the layout
--- is clean.
function App:panelsOverlap()
  local list = self:panelRects()
  for i = 1, #list do
    for j = i + 1, #list do
      local a, b = list[i].r, list[j].r
      if a.w > 0 and b.w > 0 and a.h > 0 and b.h > 0
        and a.x < b.x + b.w and b.x < a.x + a.w
        and a.y < b.y + b.h and b.y < a.y + a.h then
        return list[i].name .. " overlaps " .. list[j].name
      end
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- Canvas input routing
--------------------------------------------------------------------------------

--- Is the shared pointer (the same source the wheel routing uses) over the
--- canvas? Keeping this on ui.mx/ui.my means the keyboard pan modifier, the
--- wheel routing and hover all agree on one coordinate source.
function App:pointerOverCanvas()
  return self:canvasAccepts(ui.mx * ui.scale, ui.my * ui.scale)
end

--- x, y are PHYSICAL mouse coordinates; the layout lives in logical units.
function App:canvasAccepts(x, y)
  if self.modal or self.newPack or self.showHelp then return false end
  -- the canvas is only interactive in the graph view: clicks in the settings /
  -- validation views must not reach it (they used to clear the node selection)
  if self.view ~= "graph" then return false end
  local lx, ly = ui.toLogical(x, y)
  local c = self.canvas
  if lx < c.x or lx >= c.x + c.w or ly < c.y or ly >= c.y + c.h then return false end
  if ui.blocksPoint(lx, ly) then return false end
  -- on-canvas chrome swallows its own clicks
  local z = self.zoomBar
  if z.w > 0 and ui.rectContains(z.x, z.y, z.w, z.h, lx, ly) then return false end
  if self.banner then
    local b = self.bannerRect
    if ui.rectContains(b.x, b.y, b.w, b.h, lx, ly) then return false end
  end
  return true
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

--- Publish the currently open pack as a .zip into <workspace>/dist/.
--- Saves first so the archive always matches what is on screen.
function App:publishZip()
  if not self.pack then self:error("没有打开的包"); return end
  if self.dirty then
    local ok, err = pcall(function() self:save() end)
    if not ok then self:error("保存失败，未发布: " .. tostring(err)); return end
  end
  local name = Pack.basename(self.pack.dir)
  local out = Pack.join(Pack.join(self.root, "dist"), name .. ".zip")
  local path, err = Pack.exportZip(self.pack.dir, out)
  if not path then self:error("发布失败: " .. tostring(err)); return end
  local kb = (Pack.fileSize(path) or 0) / 1024
  self:setStatus(string.format("已发布 %s（%.1f KB）", path, kb))
end

function App:drawTopBar()
  local t = self.top
  ui.rect("fill", t.x, t.y, t.w, t.h, ui.theme.panel)
  ui.rect("line", t.x, t.y, t.w, t.h, ui.theme.border)
  local compact = t.w < 980
  local x = 10
  local y = 9
  if ui.button("tb.new", x, y, compact and 64 or 92, 26, compact and "新建" or "新建 (Ctrl+N)",
    { tip = "新建活动包 (Ctrl+N)" }) then self:openNewPackDialog() end
  x = x + (compact and 68 or 96)
  if ui.button("tb.open", x, y, compact and 64 or 92, 26, compact and "打开" or "打开 (Ctrl+O)",
    { tip = "打开活动包目录 (Ctrl+O)" }) then
    self:openBrowser({
      mode = "dir",
      title = "打开活动包（进入包含 tree.json 的目录）",
      path = self.pack and self.pack.dir or Pack.join(self.root, "CustomEvents"),
      onAccept = function(dir) self:openPack(dir) end,
    })
  end
  x = x + (compact and 68 or 96)
  if ui.button("tb.save", x, y, compact and 64 or 92, 26,
    self.dirty and "● 保存" or (compact and "保存" or "保存 (Ctrl+S)"),
    { accent = self.dirty, disabled = self.pack == nil, tip = "Ctrl+S 写入 tree.json 与 pack.json" }) then
    self:save()
  end
  x = x + (compact and 68 or 96)
  if t.w >= 1150 then
    if ui.button("tb.saveas", x, y, 96, 26, "另存为…", { disabled = self.pack == nil }) then
      self:openBrowser({
        mode = "dir",
        title = "另存到哪个目录（会写入 tree.json 与 pack.json）",
        path = self.root,
        onAccept = function(dir) self:saveAs(dir) end,
      })
    end
    x = x + 106
  end
  if t.w >= 1050 then
    if ui.button("tb.publish", x, y, 96, 26, "发布 ZIP", {
      disabled = self.pack == nil,
      tip = "把当前活动包打包为 .zip（输出到 dist/，解压即得 CustomEvents/<包名>/）",
    }) then
      self:publishZip()
    end
    x = x + 106
  end

  local tabs = {
    { id = "graph", label = "图谱" },
    { id = "settings", label = "活动设置" },
    { id = "validate", label = string.format("校验 %d/%d", self.counts.error, self.counts.warn) },
  }
  for _, tab in ipairs(tabs) do
    local w = ui.textW(tab.label, "small") + 26
    local active = self.view == tab.id
    if ui.button("tb.tab." .. tab.id, x, y, w, 26, tab.label, {
      bg = active and ui.theme.accentSoft or ui.theme.panelAlt,
      tip = tab.id == "validate" and "错误 / 警告数量" or nil,
    }) then
      self.view = tab.id
      if tab.id == "validate" then self:validate(true) end
    end
    if active then ui.rect("fill", x, y + 26, w, 3, ui.theme.accent) end
    x = x + w + 6
  end

  -- right side
  local rx = t.w - 12
  local function rightButton(id, label, w, tip, onClick)
    rx = rx - w
    if ui.button(id, rx, y, w, 26, label, { tip = tip }) then onClick() end
    rx = rx - 6
  end
  rightButton("tb.help", compact and "帮助" or "帮助 F1", compact and 56 or 76, "快捷键一览 (F1)",
    function() self.showHelp = not self.showHelp end)
  if t.w >= 780 then
    rightButton("tb.insp", compact and "检查器" or "检查器 Tab", compact and 68 or 88, "显示 / 隐藏右侧检查器",
      function() self.showInspector = not self.showInspector end)
  end
  if t.w >= 900 then
    rightButton("tb.side", "侧栏", 56, "显示 / 隐藏左侧活动包列表", function() self.showSidebar = not self.showSidebar end)
  end

  local name = self.pack and (self.pack.tree.title ~= "" and self.pack.tree.title or Pack.basename(self.pack.dir)) or "（未打开）"
  if self.dirty then name = name .. " ●" end
  if rx - 10 > x + 20 then
    ui.text(x + 10, y + 6, name, { w = rx - x - 20, align = "right", font = "small",
      color = self.pack and ui.theme.text or ui.theme.textFaint })
  end
end

function App:drawSidebar()
  local s = self.sidebar
  if s.w <= 0 then return end
  ui.rect("fill", s.x, s.y, s.w, s.h, ui.theme.panelDeep)
  ui.rect("line", s.x, s.y, s.w, s.h, ui.theme.border)
  local cy = s.y + 8
  ui.text(s.x + 10, cy, "活动包（" .. #self.packs .. "）", { font = "small", color = ui.theme.accent })
  if ui.button("sb.refresh", s.x + s.w - 70, cy - 4, 60, 22, "重新扫描") then
    self:rescan()
  end
  cy = cy + 24

  local listH = s.h - 130
  ui.beginScroll("sidebar.list", s.x + 4, cy, s.w - 8, listH, #self.packs * 46 + 8)
  for i, item in ipairs(self.packs) do
    local ry = cy + 4 + (i - 1) * 46
    local isCurrent = self.pack and self.pack.dir == item.dir
    local hovered, held, clicked = ui.clickable("sb.pack." .. i, s.x + 6, ry, s.w - 18, 42)
    ui.rect("fill", s.x + 6, ry, s.w - 18, 42,
      isCurrent and ui.theme.accentSoft or (hovered and ui.theme.panelAlt or ui.theme.panel))
    ui.rect("line", s.x + 6, ry, s.w - 18, 42, isCurrent and ui.theme.accent or ui.theme.border)
    ui.text(s.x + 12, ry + 5, item.title ~= "" and item.title or item.name,
      { font = "small", color = item.ok and ui.theme.text or ui.theme.danger })
    ui.text(s.x + 12, ry + 23, item.ok and (item.name .. " · " .. item.nodeCount .. " 节点")
      or ("无效: " .. tostring(item.err)):sub(1, 40),
      { font = "tiny", color = item.ok and ui.theme.textFaint or ui.theme.danger })
    if clicked then self:openPack(item.dir) end
  end
  ui.endScroll()
  cy = cy + listH + 6

  ui.text(s.x + 10, cy, "按路径打开", { font = "small", color = ui.theme.textDim })
  cy = cy + 20
  local draft, changed, committed = ui.textField("sb.path", s.x + 10, cy, s.w - 20, 24,
    self.pathDraft, { placeholder = "/path/to/PackFolder" })
  if changed then self.pathDraft = draft end
  if committed then self:openPack(self.pathDraft) end
  cy = cy + 28
  if ui.button("sb.openpath", s.x + 10, cy, s.w - 20, 24, "打开这个目录") then
    self:openPack(self.pathDraft)
  end
  cy = cy + 30
  ui.text(s.x + 10, cy, "工作区: " .. self.root, { font = "tiny", color = ui.theme.textFaint })
end

function App:drawInspector()
  local r = self.right
  if r.w <= 0 then return end
  ui.rect("fill", r.x, r.y, r.w, r.h, ui.theme.panel)
  ui.rect("line", r.x, r.y, r.w, r.h, ui.theme.border)
  ui.rect("fill", r.x + 1, r.y + 1, r.w - 2, 26, ui.theme.panelAlt)
  ui.text(r.x + 10, r.y + 7, "节点检查器", { font = "small", color = ui.theme.accent })
  -- same shape mapping as the canvas, so the header shows what the node looks like
  local selNode = self.primaryUid and self.pack and Pack.nodeByUid(self.pack, self.primaryUid) or nil
  if selNode then
    local shape = Graph.shapeFor(selNode.type)
    local col = Graph.TYPE_COLORS[selNode.type] or ui.theme.textDim
    local chipX = r.x + 18 + ui.textW("节点检查器", "small")
    love.graphics.setColor(col[1], col[2], col[3], 1)
    Graph.traceShape("fill", shape, ui.s(chipX), ui.s(r.y + 14), ui.s(7))
    love.graphics.setLineJoin("bevel")
    Graph.traceShape("line", shape, ui.s(chipX), ui.s(r.y + 14), ui.s(7))
    love.graphics.setLineJoin("miter")
    love.graphics.setColor(1, 1, 1, 1)
    ui.text(chipX + 12, r.y + 7, selNode.type .. " · " .. (Graph.SHAPE_LABEL[shape] or shape),
      { font = "tiny", color = ui.theme.textDim })
  end
  if self.primaryUid then
    ui.text(r.x + 2, r.y + 7, self.primaryUid, { align = "right", w = r.w - 14, font = "tiny", color = ui.theme.textFaint })
  end
  Inspector.draw(self, r.x, r.y + 28, r.w, r.h - 28)
end

function App:drawValidate(vx, vw)
  local c = { x = vx or self.canvas.x, y = self.canvas.y, w = vw or self.canvas.w, h = self.canvas.h }
  ui.rect("fill", c.x, c.y, c.w, c.h, ui.theme.bg)
  local cy = c.y + 12
  ui.text(c.x + 16, cy, "校验结果", { font = "big", color = ui.theme.text })
  ui.text(c.x + 16 + ui.textW("校验结果", "big") + 16, cy + 10,
    string.format("%d 错误 · %d 警告 · %d 提示", self.counts.error, self.counts.warn, self.counts.info),
    { font = "small", color = ui.theme.textDim })
  if ui.button("val.recheck", c.x + c.w - 120, cy, 100, 26, "重新校验") then
    self:validate(true)
    self:setStatus("已重新校验")
  end
  cy = cy + 44

  if not self.pack then
    ui.text(c.x + 16, cy, "没有打开任何包", { font = "small", color = ui.theme.textDim })
    return
  end
  if #self.problems == 0 then
    ui.text(c.x + 16, cy, "✔ 没有发现问题，这个包可以进游戏了。", { font = "title", color = ui.theme.ok })
    return
  end

  local rowH = 34
  local listH = c.h - (cy - c.y) - 12
  -- long messages are reachable with Shift+wheel: the list has a content width
  local maxRowW = 0
  for _, p in ipairs(self.problems) do
    maxRowW = math.max(maxRowW, ui.textW(p.msg, "small") + 96)
  end
  ui.beginScroll("validate.list", c.x + 8, cy, c.w - 16, listH, #self.problems * rowH + 8, maxRowW)
  for i, p in ipairs(self.problems) do
    local ry = cy + 4 + (i - 1) * rowH
    local col = p.level == "error" and ui.theme.danger or (p.level == "warn" and ui.theme.warn or ui.theme.textFaint)
    local hovered, held, clicked = ui.clickable("val." .. i, c.x + 8, ry, c.w - 24, rowH - 2)
    ui.rect("fill", c.x + 8, ry, c.w - 24, rowH - 2, hovered and ui.theme.panelAlt or ui.theme.panel)
    ui.rect("fill", c.x + 8, ry, 4, rowH - 2, col)
    local tag = p.level == "error" and "错误" or (p.level == "warn" and "警告" or "提示")
    ui.text(c.x + 20, ry + 8, tag, { font = "small", color = col })
    ui.pushClip(c.x + 70, ry, math.max(c.w - 100, maxRowW), rowH)
    ui.text(c.x + 70, ry + 8, p.msg, { font = "small", color = ui.theme.text })
    ui.popClip()
    if clicked then
      if p.uid and Pack.nodeByUid(self.pack, p.uid) then
        self.view = "graph"
        self:setSelection({ p.uid })
        self.graph:centerOn(self.pack, p.uid)
        self:setStatus("定位到 " .. p.uid)
      else
        self.view = "settings"
        self:setStatus("这条问题和 pack.json 有关")
      end
    end
  end
  ui.endScroll()
end

--- Discoverable canvas zoom: -/+ , fit-to-view and a live readout.
function App:drawZoomBar()
  local z = self.zoomBar
  local g = self.graph
  ui.rect("fill", z.x, z.y, z.w, z.h, { 0.05, 0.06, 0.08 }, 0.88)
  ui.rect("line", z.x, z.y, z.w, z.h, ui.theme.border)
  local ccx = ui.s(self.canvas.x + self.canvas.w / 2)
  local ccy = ui.s(self.canvas.y + self.canvas.h / 2)
  if ui.button("zoom.out", z.x + 4, z.y + 3, 26, 22, "−", { tip = "缩小画布（滚轮也可以）" }) then
    g:wheel(ccx, ccy, -2)
  end
  ui.rect("fill", z.x + 33, z.y + 3, 76, 22, ui.theme.panelDeep)
  ui.rect("line", z.x + 33, z.y + 3, 76, 22, ui.theme.border)
  ui.text(z.x + 33, z.y + 7, string.format("%.1f px/u", g.zoom),
    { align = "center", w = 76, font = "tiny", color = ui.theme.text })
  if ui.button("zoom.in", z.x + 112, z.y + 3, 26, 22, "＋", { tip = "放大画布（滚轮也可以）" }) then
    g:wheel(ccx, ccy, 2)
  end
  if ui.button("zoom.fit", z.x + 142, z.y + 3, 50, 22, "适应",
    { tip = "缩放到刚好看见全部节点 (Ctrl+F)" }) then
    if self.pack then g:fit(self.pack) end
    self:setStatus("已缩放到全部节点")
  end
  -- always-on affordance for creating a node (shortcut: N / Insert)
  if ui.button("canvas.newnode", z.x + 200, z.y + 3, 108, 22, "＋ 新建节点",
    { accent = true, disabled = self.pack == nil, tip = "新建一个节点 (N)：默认落在下一层，自动选中并聚焦 uid" }) then
    self:newNode()
  end
end

function App:drawStatusBar()
  local s = self.statusBar
  ui.rect("fill", s.x, s.y, s.w, s.h, ui.theme.panel)
  ui.rect("line", s.x, s.y, s.w, s.h, ui.theme.border)
  local y = s.y + 5
  local right = string.format("节点 %d  |  %d 错误 %d 警告  |  %s",
    self.pack and #self.pack.tree.nodes or 0, self.counts.error, self.counts.warn, Fonts.label)
  local rightW = ui.textW(right, "small") + 14
  local leftMax = math.max(60, s.w - rightW - 20)

  -- three zones, each clipped, so long paths or status texts can never collide
  ui.pushClip(10, s.y, leftMax - 10, s.h)
  ui.text(10, y, self.status, { font = "small", color = ui.theme.text })
  ui.popClip()

  local mid = self.pack and (self.pack.dir .. "/" .. Pack.basename(self.pack.treePath or "tree.json")) or "（未打开文件）"
  local cx = leftMax + 10
  local cw = s.w - rightW - cx - 10
  if cw > 140 then
    ui.pushClip(cx, s.y, cw, s.h)
    ui.text(cx, y, mid, { w = cw, align = "center", font = "small", color = ui.theme.textFaint })
    ui.popClip()
  end

  ui.text(0, y, right, { align = "right", w = s.w - 10, font = "small",
    color = self.counts.error > 0 and ui.theme.danger or ui.theme.textDim })
end

function App:drawBanner()
  if not self.banner then return end
  local b = self.bannerRect
  local col = self.banner.level == "error" and ui.theme.danger or ui.theme.accent
  ui.rect("fill", b.x, b.y, b.w, b.h, { 0.10, 0.06, 0.08 }, 0.96)
  ui.rect("line", b.x, b.y, b.w, b.h, col)
  ui.pushClip(b.x + 2, b.y, b.w - 34, b.h)
  ui.text(b.x + 10, b.y + 7, self.banner.text, { font = "small", color = col })
  ui.popClip()
  if ui.button("banner.x", b.x + b.w - 28, b.y + 4, 22, 22, "×") then
    self.banner = nil
  end
end

function App:drawHelp()
  local W, H = love.graphics.getDimensions()
  local w, h = 720, 560
  local x, y = FLOOR((W - w) / 2), FLOOR((H - h) / 2)
  ui.setModalRect(x, y, w, h)
  ui.beginModalPass()
  ui.drawModalScrim()
  ui.rect("fill", x, y, w, h, ui.theme.panel)
  ui.rect("line", x, y, w, h, ui.theme.borderLight)
  ui.rect("fill", x + 1, y + 1, w - 2, 34, ui.theme.panelAlt)
  ui.text(x + 14, y + 9, "快捷键与操作说明", { font = "title", color = ui.theme.text })

  local rows = {
    { "Ctrl+S", "保存 tree.json + pack.json" },
    { "Ctrl+Shift+S", "另存为（选择目录）" },
    { "Ctrl+O", "打开活动包目录" },
    { "Ctrl+N", "新建活动包" },
    { "Ctrl+R", "重新扫描活动包目录" },
    { "Ctrl+D", "复制当前节点" },
    { "Tab", "显示 / 隐藏右侧检查器" },
    { "Ctrl+B", "背景编辑模式：在画布后面放参考图，左键拖动图片对齐节点；再按一次退出" },
    { "Ctrl+Shift+B", "显示 / 隐藏左侧活动包列表（原来的 Ctrl+B）" },
    { "F1 / Esc", "开关这个帮助面板" },
    { "Delete", "删除选中的节点（并清理引用）" },
    { "方向键", "按 1 个世界单位微调选中节点（Shift = 10）" },
    { "", "" },
    { "左键拖动节点", "移动节点：默认吸附到 1 个世界单位，按住 Shift 为 0.1 精细" },
    { "左键拖动空白", "框选（Shift 加选）" },
    { "Shift+左键点节点", "加选 / 取消选择" },
    { "中键 / 右键 / 空格+左键拖动", "平移画布（拖动）" },
    { "W A S D", "平移画布：W 上 / A 左 / S 下 / D 右；屏幕速度与缩放无关，按住 Shift 快 3 倍" },
    { "N / Insert", "新建节点：落在下一层（y = 层数 x 22，x 之字形），自动选中并聚焦 uid 输入框" },
    { "", "" },
    { "滚轮（画布上）", "以光标为中心缩放画布；画布上的世界坐标保持不动" },
    { "滚轮（面板上）", "滚动光标下的那个列表；到顶/到底后交给外层" },
    { "Ctrl + 滚轮", "缩放整个编辑器界面 0.75x–2.0x（光标下的内容保持不动）" },
    { "Shift + 滚轮", "左右滚动（该面板可横向滚动时），否则照常上下滚动" },
    { "Ctrl + 加号 / 减号 / 0", "界面放大 / 缩小 / 复位 100%" },
    { "Ctrl+F / 画布右下角「适应」", "画布缩放到刚好看见全部节点" },
    { "拖动滚动条 / 点击轨道", "跳转到任意位置（每个可滚动面板都有）" },
    { "", "" },
    { "可见区域框", "以 startNode 为锚点画出游戏里大约 100x58 世界单位的可视范围" },
    { "requiredCount", "一律写 0：整棵树开局可见。写 >0 会让节点推迟出现，编辑器会警告。" },
    { "位置", "世界单位。树往上长：起始节点 y=0，之后每层 y = 层数 x 22，x 控制在 ±40 内。" },
    { "节点形状", "Generator = 圆形，Research = 六边形，Trophy = 星形；图标裁在形状内，点击判定用外接圆" },
    { "任务阶段 (missions)", "pack.json 里的 missions 是「阶段」；任务面板一次只显示一个阶段，完成当前阶段后进入下一个" },
    { "任务条目 = 任务卡", "任务面板上的一个条目就是一张卡：同一阶段里【相邻】且 prizeType 与 prizeID 都相同的任务会并成一个条目" },
    { "看哪个数字", "任务编辑器顶部「游戏中任务面板显示：N 个任务条目 (0/N)」才是玩家看到的数量，其他数字都不是" },
    { "平移", "中键拖动 / 右键拖动 / 空格+左键拖动 / WASD；卡住了按 Ctrl+F 或「适应」一定回得来" },
  }
  local cy = y + 48
  for _, r in ipairs(rows) do
    if r[1] == "" then
      cy = cy + 8
    else
      ui.text(x + 20, cy, r[1], { font = "small", color = ui.theme.accent })
      ui.text(x + 210, cy, r[2], { font = "small", color = ui.theme.text })
      cy = cy + 22
    end
  end
  ui.text(x + 20, y + h - 54, "字体: " .. Fonts.label .. (Fonts.hasCJK and "" or "  ⚠ 没有找到中文字体，中文会显示为空白"),
    { font = "tiny", color = Fonts.hasCJK and ui.theme.textFaint or ui.theme.warn })
  local found = {}
  for i = 1, MIN(3, #Fonts.attempts) do found[#found + 1] = Fonts.attempts[i] end
  if #found > 0 then
    ui.text(x + 20, y + h - 38, "字体探测: " .. table.concat(found, "   "), { font = "tiny", color = ui.theme.textFaint })
  end
  if ui.button("help.close", x + w - 110, y + h - 40, 96, 28, "关闭 (Esc)", { accent = true }) then
    self.showHelp = false
  end
  ui.endModalPass()
end

function App:openNewPackDialog()
  self.newPack = {
    parent = Pack.join(self.root, "CustomEvents"),
    id = "newpack",
    title = "新的勘探活动",
  }
  -- put the caret straight into the name field so typing works immediately
  ui.focus = "np.id"
  ui.stateFor("np.id").caret = #self.newPack.id + 1
end

function App:drawNewPackDialog()
  local W, H = love.graphics.getDimensions()
  local w, h = 620, 250
  local x, y = FLOOR((W - w) / 2), FLOOR((H - h) / 2)
  ui.setModalRect(x, y, w, h)
  ui.beginModalPass()
  ui.drawModalScrim()
  ui.rect("fill", x, y, w, h, ui.theme.panel)
  ui.rect("line", x, y, w, h, ui.theme.borderLight)
  ui.rect("fill", x + 1, y + 1, w - 2, 34, ui.theme.panelAlt)
  ui.text(x + 14, y + 9, "新建活动包", { font = "title", color = ui.theme.text })
  local np = self.newPack
  local cy = y + 50
  ui.text(x + 16, cy + 6, "父目录", { font = "small", color = ui.theme.textDim })
  local parent, pchanged = ui.textField("np.parent", x + 96, cy, w - 220, 24, np.parent, {})
  if pchanged then np.parent = parent end
  if ui.button("np.browse", x + w - 116, cy, 100, 24, "浏览…") then
    local keep = np
    self:openBrowser({
      mode = "dir",
      title = "选择父目录",
      path = np.parent,
      onAccept = function(dir) keep.parent = dir end,
    })
  end
  cy = cy + 32
  ui.text(x + 16, cy + 6, "id（目录名）", { font = "small", color = ui.theme.textDim })
  local id, ichanged = ui.textField("np.id", x + 96, cy, w - 116, 24, np.id, { placeholder = "newpack" })
  if ichanged then np.id = id end
  cy = cy + 32
  ui.text(x + 16, cy + 6, "标题", { font = "small", color = ui.theme.textDim })
  local title, tchanged = ui.textField("np.title", x + 96, cy, w - 116, 24, np.title, {})
  if tchanged then np.title = title end
  cy = cy + 40
  ui.text(x + 16, cy, "将创建: " .. Pack.join(np.parent, np.id) .. "（含 tree.json、pack.json、icons/）",
    { font = "tiny", color = ui.theme.textFaint })
  if ui.button("np.cancel", x + w - 220, y + h - 44, 96, 28, "取消") then
    self.newPack = nil
  end
  if ui.button("np.create", x + w - 116, y + h - 44, 100, 28, "创建", { accent = true }) then
    np.confirm = true
  end
  -- Enter in any field confirms too
  if np.confirm then
    local np2 = self.newPack
    self.newPack = nil
    ui.focus = nil
    self:createPack(np2.parent, np2.id, np2.title)
  end
  ui.endModalPass()
end

-- Background image (a pack has exactly ONE; it replaces the game's backdrop)
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



--------------------------------------------------------------------------------
-- New node
--------------------------------------------------------------------------------

--- Create a node using the pack's default row/zig-zag convention, select it and
--- put the caret in the inspector's uid field so it can be renamed immediately.
--- Switches to the graph view first if another view is showing.
function App:newNode()
  if not self.pack then
    self:error("没有打开的包：先新建或打开一个活动包")
    return nil
  end
  if self.view ~= "graph" then self.view = "graph" end
  local uid = Pack.nextNodeUid(self.pack)
  local node = Pack.addNode(self.pack, { uid = uid, afterUid = self.primaryUid })
  if not node then return nil end
  self.dirty = true
  self.showInspector = true
  self:setSelection({ node.uid })
  self.graph:centerOn(self.pack, node.uid)
  -- focus the uid field so renaming is one keystroke away
  local st = ui.stateFor("insp.uid")
  st.draft = node.uid
  st.uidFor = node.uid
  ui.focus = "insp.uid.field"
  ui.stateFor("insp.uid.field").caret = #node.uid + 1
  self:setStatus(string.format("新建节点 %s（第 %d 层，y = %d）",
    node.uid, math.floor(node.position.y / Pack.ROW_STEP + 0.5), node.position.y))
  return node
end

function App:draw()
  self:layout()
  if self.needsFit and self.pack then
    self.needsFit = false
    self.graph:fit(self.pack)
  end
  ui.beginFrame(love.timer.getTime())

  -- declare the modal rect before anything else so the widgets behind it
  -- ignore the pointer this frame
  local W, H = ui.dims()
  if self.showHelp then
    ui.setModalRect(FLOOR((W - 720) / 2), FLOOR((H - 560) / 2), 720, 560)
  elseif self.newPack then
    ui.setModalRect(FLOOR((W - 620) / 2), FLOOR((H - 250) / 2), 620, 250)
  elseif self.modal then
    ui.setModalRect(FLOOR((W - self.modal.w) / 2), FLOOR((H - self.modal.h) / 2), self.modal.w, self.modal.h)
  end

  ui.rect("fill", 0, 0, W, H, ui.theme.bg)

  -- every panel is clipped to its own rect so nothing can bleed into a
  -- neighbour even if a widget is too wide
  ui.pushClip(self.top.x, self.top.y, self.top.w, self.top.h)
  self:drawTopBar()
  ui.popClip()

  if self.effSidebar then
    ui.pushClip(self.sidebar.x, self.sidebar.y, self.sidebar.w, self.sidebar.h)
    self:drawSidebar()
    ui.popClip()
  end

  -- the graph keeps the inspector next to it; the full screen editors use the
  -- whole width so forms and mission rows are not squeezed
  if self.view == "graph" then
    self.graph:draw(self)
    ui.pushClip(self.canvas.x, self.canvas.y, self.canvas.w, self.canvas.h)
    self:drawZoomBar()
    self:drawBanner()
    ui.popClip()
    if self.effInspector then
      ui.pushClip(self.right.x, self.right.y, self.right.w, self.right.h)
      self:drawInspector()
      ui.popClip()
    end
  elseif self.view == "settings" then
    ui.pushClip(self.canvas.x, self.canvas.y, W - self.canvas.x, self.canvas.h)
    Settings.draw(self, self.canvas.x, self.canvas.y, W - self.canvas.x, self.canvas.h)
    ui.popClip()
  else
    ui.pushClip(self.canvas.x, self.canvas.y, W - self.canvas.x, self.canvas.h)
    self:drawValidate(self.canvas.x, W - self.canvas.x)
    ui.popClip()
  end

  ui.pushClip(self.statusBar.x, self.statusBar.y, self.statusBar.w, self.statusBar.h)
  self:drawStatusBar()
  ui.popClip()

  if self.showHelp then self:drawHelp() end
  if self.newPack then self:drawNewPackDialog() end
  if self.modal then
    ui.beginModalPass()
    ui.drawModalScrim()
    self.modal:draw(W, H)
    ui.endModalPass()
    if self.modal.done then self.modal = nil end
  end

  -- Wheel that no scroll region consumed: Ctrl/Cmd zooms the whole UI, plain
  -- wheel over the canvas zooms the canvas. ui.wheelX/Y are logical, the canvas
  -- works in physical pixels, so convert exactly once here.
  if ui.wheel ~= 0 and not ui.wheelConsumed then
    if ui.wheelCtrl then
      self:wheelUIScale(ui.wheel)
    else
      local px, py = ui.wheelX * ui.scale, ui.wheelY * ui.scale
      if self:canvasAccepts(px, py) then
        self.graph:wheel(px, py, ui.wheel)
      end
    end
  end

  ui.endFrame()
  if not RELEASE then self:smokeStep() end
end

--------------------------------------------------------------------------------
-- Smoke test
--------------------------------------------------------------------------------

local function smokeCheck(name, ok, detail)
  print(string.format("%s  uitest: %s%s", ok and "PASS" or "FAIL", name,
    (not ok and detail) and ("  --  " .. tostring(detail)) or ""))
  return ok
end

local function regionById(id)
  for _, r in ipairs(ui.prevRegions or {}) do
    if r.id == id then return r end
  end
  return nil
end

--- A deliberately large pack (8 ranks x 4 missions) used to prove that the
--- missions editor really scrolls when the content is taller than the screen.
local function writeBigPack(dir)
  Pack.removeTree(dir)
  Pack.mkdirp(Pack.join(dir, "icons"))
  local tree = {
    name = "bigpack", title = "大任务包", startNode = "n1", gridView = false,
    nodes = json.array(
      {
        uid = "n1", title = "起始节点", description = "", type = "Generator",
        position = { x = 0, y = 0, z = 0 },
        cost = Pack.normalizeCurve(1), production = Pack.normalizeCurve(1),
        effects = json.array(), requirements = json.array(),
      },
      {
        -- deliberately broken + long so the validation list needs horizontal
        -- scrolling (Shift+wheel) to read the whole message
        uid = "n2_with_a_deliberately_long_identifier", title = "坏节点", description = "",
        type = "Research", position = { x = 22, y = 22, z = 0 },
        cost = Pack.normalizeCurve(5), production = Pack.normalizeCurve(0),
        effects = json.array(),
        requirements = json.array({
          requiredUid = "this_prerequisite_does_not_exist_anywhere_in_this_pack_at_all",
          requiredCount = 0, lineType = "NORM", hidden = false,
        }),
      }),
  }
  Pack.writeFile(Pack.join(dir, "tree.json"),
    json.encode(tree, { indent = 2, keyOrder = Pack.TREE_KEY_ORDER }) .. NL)
  local ranks = json.markArray({})
  for r = 1, 8 do
    local missions = json.markArray({})
    for m = 1, 4 do
      missions[m] = json.markObject({
        type = "Collect", reqItemId = "n1", reqAmount = m * 5,
        prizeType = "Darwinium", prizeAmount = m, hidden = false, treeType = "NONE",
      })
    end
    ranks[r] = json.markObject({ title = "任务组 " .. r, targetHrs = r, missions = missions })
  end
  -- a hand-built rank that exercises the game's card merge rule: the first two
  -- missions share (Darwinium, 5) so they collapse into one card -> 4 missions,
  -- 3 cards. The third one differs and the fourth starts a new run.
  ranks[#ranks + 1] = json.markObject({
    title = "合并测试", targetHrs = 2,
    missions = json.array(
      json.markObject({ type = "Collect", reqItemId = "n1", reqAmount = 1, prizeType = "Darwinium", prizeID = "5", prizeAmount = 5 }),
      json.markObject({ type = "Collect", reqItemId = "n1", reqAmount = 2, prizeType = "Darwinium", prizeID = "5", prizeAmount = 5 }),
      json.markObject({ type = "Collect", reqItemId = "n1", reqAmount = 3, prizeType = "Stardust", prizeID = "50", prizeAmount = 50 }),
      json.markObject({ type = "Collect", reqItemId = "n1", reqAmount = 4, prizeType = "Darwinium", prizeID = "5", prizeAmount = 5 })
    ),
  })
  local meta = json.markObject({
    id = "bigpack", title = "大任务包", tree = "tree.json", icons = "icons",
    currencyCount = 1, intro = json.array("第一句"), outro = json.array("结束语"),
    missions = ranks,
  })
  Pack.writeFile(Pack.join(dir, "pack.json"),
    json.encode(meta, { indent = 2, keyOrder = Pack.PACK_KEY_ORDER }) .. NL)
  return dir
end

--- Verify the invariant behind the "text misaligns while scrolling" bug: for
--- every widget inside a scroll region, the rect it is DRAWN at (read back from
--- the live graphics transform) must equal the rect hit testing uses, and it
--- must be inside the region's scissor. Runs at any UI scale.
local function auditCheck(label, regionId)
  local n, bad, unscrolled, unclipped = 0, nil, 0, 0
  for _, w in ipairs(ui.debugWidgets) do
    if not regionId or w.region == regionId then
      n = n + 1
      if math.abs(w.dx) > 1 or math.abs(w.dy) > 1 then bad = w end
      if (w.scroll or 0) <= 0 and (w.scrollX or 0) <= 0 then unscrolled = unscrolled + 1 end
      if not w.clipped then unclipped = unclipped + 1 end
    end
  end
  smokeCheck(string.format("%s: %d widgets draw exactly where they are hit", label, n),
    n > 0 and bad == nil,
    bad and string.format("%s dx=%.1f dy=%.1f", tostring(bad.id), bad.dx, bad.dy))
  smokeCheck(label .. ": the region was scrolled while auditing", n > 0 and unscrolled == 0,
    tostring(unscrolled) .. " widgets with no scroll offset")
  smokeCheck(label .. ": every widget is inside the region scissor", n > 0 and unclipped == 0,
    tostring(unclipped) .. " unclipped widgets")
  return n
end

--- Drive WASD through the REAL key callbacks and measure what the camera did.
--- Returns the world-space distance moved (asserting the direction on the way).
local function wasdPanCheck(app, key, expectDX, expectDY, scale, zoom, frames, dt, fast)
  local g = app.graph
  app:setUIScale(scale)
  if zoom then g.zoom = zoom end
  ui.focus = nil
  app.panFastOverride = fast and true or false
  g:clearPanKeys()
  g.camx, g.camy = 0, 0
  frames = frames or 30
  dt = dt or (1 / 60)
  love.keypressed(key, nil, false)
  local held = g.panKeys[key] == true
  for _ = 1, frames do app:update(dt) end
  love.keyreleased(key, nil, false)
  app.panFastOverride = nil
  local mx, my = g.camx, g.camy
  local function dirOK(v, want)
    if want == 0 then return math.abs(v) < 1e-9 end
    return (want > 0 and v > 0.001) or (want < 0 and v < -0.001)
  end
  local dist = math.sqrt(mx * mx + my * my)
  local dirName = (expectDY > 0 and "up") or (expectDY < 0 and "down")
    or (expectDX < 0 and "left") or "right"
  smokeCheck(string.format("WASD %s pans %s (UI scale %.2fx, zoom %.0f)", key:upper(), dirName, scale, g.zoom),
    held and dirOK(mx, expectDX) and dirOK(my, expectDY) and dist > 0.01,
    string.format("held=%s dx=%.4f dy=%.4f dist=%.4f", tostring(held), mx, my, dist))
  return dist
end

--- One text-field probe: real click, real typing, real backspace. Covers every
--- kind of text field the editor has (see buildFieldProbes).
local function buildFieldProbes(app)
  local pack = app.pack
  local node = pack and pack.tree.nodes[2]
  local list = {}
  local function add(name, view, id, getter, text, expect)
    list[#list + 1] = {
      name = name, view = view, id = id, get = getter, text = text or "Z",
      expect = expect or function(b) return tostring(b) .. (text or "Z") end,
    }
  end
  local function num(b, t) return tonumber(tostring(b) .. (t or "7")) end
  if node then
    add("inspector title", "graph", "insp.title", function() return node.title end)
    add("inspector description (multiline)", "graph", "insp.desc", function() return node.description end)
    add("inspector numeric position", "graph", "insp.px", function() return node.position.x end, "7",
      function(b) return num(b, "7") end)
    add("inspector uid draft", "graph", "insp.uid.field",
      function() return ui.stateFor("insp.uid").draft end)
  end
  add("sidebar path box", "graph", "sb.path", function() return app.pathDraft end)
  add("pack.json id", "settings", "meta.id", function() return pack.meta.id end)
  add("intro line", "settings", "meta.intro.1", function() return pack.meta.intro[1] end)
  add("currency name", "settings", "cur.name.1", function() return pack.meta.currencies[1].name end)
  add("mission target amount", "settings", "mis.1_1.t1.amount",
    function() return pack.meta.missions[1].missions[1].targets[1].amount end, "7",
    function(b) return num(b, "7") end)
  return list
end

--- Click a widget by the id the UI registered (real mouse callbacks).
local function clickWidget(id)
  local st = ui.stateFor(id)
  local r = st and st.rect
  if not r then return false end
  local cx, cy = ui.s(r.x + r.w / 2), ui.s(r.y + r.h / 2)
  love.mousemoved(cx, cy, 0, 0)
  love.mousepressed(cx, cy, 1)
  love.mousereleased(cx, cy, 1)
  return true
end

--- The editing-key script: typing, Backspace, Delete, Home/End, Left/Right and
--- Ctrl+Backspace on the inspector title field, one step per frame.
local function buildEditSteps(app, node)
  local id = "insp.title"
  local function caret() return ui.stateFor(id).caret end
  return {
    { setup = function() app.view = "graph" node.title = "" end },
    { click = id },
    { check = function() return ui.focus == id end, name = "clicking the title field focuses it",
      detail = function() return "focus=" .. tostring(ui.focus) end },
    { type = "abc" },
    { check = function() return node.title == "abc" end, name = "typing abc" },
    { shot = "smoketest_textfield.png" },
    { key = "backspace" },
    { check = function() return node.title == "ab" end, name = "backspace removes the character before the caret" },
    { key = "home" },
    { check = function() return caret() == 1 end, name = "Home moves the caret to the start" },
    { key = "delete" },
    { check = function() return node.title == "b" end, name = "Delete removes the character after the caret" },
    { key = "end" },
    { check = function() return caret() == 2 end, name = "End moves the caret to the end" },
    { setup = function() node.title = "" end },
    { type = "深海勘探" },
    { check = function() return node.title == "深海勘探" end, name = "multi-byte (CJK) typing" },
    { key = "backspace" },
    { check = function() return node.title == "深海勘" end,
      name = "backspace removes ONE whole CJK character (no broken bytes)",
      detail = function() return node.title .. " (" .. #node.title .. " bytes)" end },
    { key = "left" },
    { check = function() return caret() == 7 and node.title == "深海勘" end,
      name = "Left moves the caret across a whole multi-byte character (3 bytes)",
      detail = function() return "caret=" .. tostring(caret()) end },
    { key = "delete" },
    { check = function() return node.title == "深海" end, name = "Delete after Left removes that CJK character" },
    { setup = function() node.title = "hello world" end },
    { key = "end" },
    { setup = function() ui.modifierOverride = { ctrl = true } end },
    { key = "backspace" },
    { check = function() return node.title == "hello " end, name = "Ctrl+Backspace deletes a whole word",
      detail = function() return string.format("%q", node.title) end },
    { setup = function() ui.modifierOverride = nil node.title = "" end },
    { key = "end" },
    { setup = function() ui.focus = nil end },
  }
end

--- Background image: a pack has exactly ONE. It is copied into backgrounds/ and
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

  return steps
end

--- New-node action: button + shortcut, through real callbacks.
local function buildNodeSteps(app)
  local steps = {}
  local function add(t) steps[#steps + 1] = t end
  local function newNode() return app.primaryUid and Pack.nodeByUid(app.pack, app.primaryUid) or nil end

  add({ setup = function() app.view = "graph" end })
  add({ check = function()
        return table.concat(ui.renderedText, string.char(10)):find("＋ 新建节点", 1, true) ~= nil
      end, name = "new node: the toolbar button is rendered in the graph view" })
  add({ setup = function() app.smoke.nodeCount = #app.pack.tree.nodes end })
  add({ key = "n" })
  add({ check = function()
        return #app.pack.tree.nodes == app.smoke.nodeCount + 1 and newNode() ~= nil
          and newNode().uid:match("^node_%d+$") ~= nil
      end, name = "new node: N adds exactly one node with a fresh node_N uid and selects it",
      detail = function() return tostring(app.primaryUid) .. " total=" .. #app.pack.tree.nodes end })
  add({ check = function()
        local n = newNode()
        local row = math.floor(n.position.y / Pack.ROW_STEP + 0.5)
        return n.position.y == row * Pack.ROW_STEP and row >= 1 and math.abs(n.position.x) <= 40
      end, name = "new node: position follows the default convention (y = row * 22, zig-zag x)",
      detail = function()
        local n = newNode()
        return string.format("x=%s y=%s", tostring(n.position.x), tostring(n.position.y))
      end })
  add({ check = function() return ui.focus == "insp.uid.field" end,
      name = "new node: the inspector uid field is focused for renaming",
      detail = function() return tostring(ui.focus) end })
  add({ key = "n" })
  add({ check = function()
        local seen = {}
        for _, n in ipairs(app.pack.tree.nodes) do
          if seen[n.uid] then return false end
          seen[n.uid] = true
        end
        return true
      end, name = "new node: uids stay unique after another node" })
  add({ setup = function() app.smoke.nodeCount = #app.pack.tree.nodes end })
  add({ click = "canvas.newnode" })
  add({ check = function() return #app.pack.tree.nodes == app.smoke.nodeCount + 1 end,
      name = "new node: the toolbar button adds a node too",
      detail = function() return tostring(#app.pack.tree.nodes) end })
  add({ setup = function()
        local removed = 0
        for i = 1, 6 do
          local uid = "node_" .. i
          if Pack.nodeByUid(app.pack, uid) then
            Pack.removeNode(app.pack, uid)
            removed = removed + 1
          end
        end
        app:setSelection({})
        app.dirty = false
        ui.focus = nil
      end })
  return steps
end

--- The New Project dialog, driven exactly like a user: real click on 新建, real
--- clicks into its fields, real typing and real Backspace.
local function buildDialogSteps(app)
  local steps = {}
  local function add(t) steps[#steps + 1] = t end
  local function np() return app.newPack end

  add({ setup = function() app.view = "graph" app:openNewPackDialog() end })
  add({ check = function() return np() ~= nil end, name = "new-pack dialog: opens from the 新建 button" })
  add({ check = function() return ui.focus == "np.id" end,
      name = "new-pack dialog: the name field is focused on open",
      detail = function() return tostring(ui.focus) end })
  add({ shot = "smoketest_newpack_dialog.png" })

  local fields = { "np.id", "np.parent", "np.title" }
  for _, id in ipairs(fields) do
    add({ click = id })
    add({ check = function() return ui.focus == id end,
      name = "new-pack dialog: clicking " .. id .. " focuses it",
      detail = function() return tostring(ui.focus) end })
    add({ setup = function() app.smoke.dlgBefore = nil end })
    add({ setup = function()
          local d = np()
          app.smoke.dlgBefore = d and ((id == "np.id" and d.id) or (id == "np.parent" and d.parent) or d.title) or ""
        end })
    add({ type = "abc" })
    add({ check = function()
          local d = np()
          if not d then return false end
          local now = (id == "np.id" and d.id) or (id == "np.parent" and d.parent) or d.title
          return now == app.smoke.dlgBefore .. "abc"
        end, name = "new-pack dialog: typing works in " .. id,
        detail = function()
          local d = np()
          return d and tostring((id == "np.id" and d.id) or (id == "np.parent" and d.parent) or d.title) or "dialog closed"
        end })
    add({ key = "backspace" })
    add({ check = function()
          local d = np()
          if not d then return false end
          local now = (id == "np.id" and d.id) or (id == "np.parent" and d.parent) or d.title
          return now == app.smoke.dlgBefore .. "ab"
        end, name = "new-pack dialog: BACKSPACE works in " .. id,
        detail = function()
          local d = np()
          return d and tostring((id == "np.id" and d.id) or (id == "np.parent" and d.parent) or d.title) or "dialog closed"
        end })
  end

  -- WASD / space in a modal field must type, never pan
  add({ click = "np.title" })
  add({ setup = function() app.smoke.panBefore = { app.graph.camx, app.graph.camy } end })
  add({ key = "w" })
  add({ type = "w" })
  add({ key = "space" })
  add({ type = " " })
  add({ check = function()
        return app.graph.camx == app.smoke.panBefore[1] and app.graph.camy == app.smoke.panBefore[2]
      end, name = "new-pack dialog: WASD/space do not pan the canvas while it is open" })

  add({ key = "escape" })
  add({ check = function() return np() == nil end, name = "new-pack dialog: Escape cancels" })

  -- Enter confirms and really creates the pack
  add({ setup = function()
        app.smoke.origDir = app.pack and app.pack.dir or nil
        app:openNewPackDialog()
        app.newPack.parent = "/tmp/c2s_editor_newpack"
        app.newPack.id = "smoke_new"
        app.newPack.title = "冒烟新建"
      end })
  add({ click = "np.id" })
  add({ key = "return" })
  add({ check = function() return np() == nil end, name = "new-pack dialog: Enter confirms" })
  add({ check = function() return Pack.exists("/tmp/c2s_editor_newpack/smoke_new/tree.json") end,
      name = "new-pack dialog: Enter actually created the pack" })
  add({ setup = function()
        Pack.removeTree("/tmp/c2s_editor_newpack")
        if app.smoke.origDir then app:openPack(app.smoke.origDir) end
        ui.focus = nil
      end })
  return steps
end

--- Drive the REAL LÖVE callbacks the way the runtime does: move the pointer,
--- then deliver a wheel notch. Tests must go through this (or the raw
--- love.mousemoved/love.wheelmoved pair), never through ui.wheelmoved directly,
--- so the pointer source and the callback signature stay covered.
local function realWheel(px, py, dx, dy)
  love.mousemoved(px, py, 0, 0)
  love.wheelmoved(dx or 0, dy or 0)
end

--- Drag the canvas with the real LÖVE mouse callbacks and assert the camera
--- moved by exactly the physical mouse delta, whatever the UI scale is.
local function panCheck(app, label, button, expectScale, useSpace)
  local g = app.graph
  local px = ui.s(app.canvas.x + app.canvas.w * 0.5)
  local py = ui.s(app.canvas.y + app.canvas.h * 0.5)
  local camx, camy, zoom = g.camx, g.camy, g.zoom
  local wx, wy = g:screenToWorld(px, py)
  love.mousemoved(px, py, 0, 0)
  local consumedAtPress = false
  if useSpace then
    love.keypressed("space", nil, false)
    consumedAtPress = ui.spaceConsumed
  end
  love.mousepressed(px, py, button)
  local dragging = g.drag ~= nil and g.drag.mode == "pan"
  love.mousemoved(px + 60, py + 40, 60, 40)
  love.mousereleased(px + 60, py + 40, button)
  if useSpace then love.keyreleased("space", nil, false) end

  local dx = camx - g.camx
  local dy = g.camy - camy
  smokeCheck(string.format("%s pans the canvas (UI scale %.2fx)", label, expectScale),
    dragging and math.abs(dx - 60 / zoom) < 0.01 and math.abs(dy - 40 / zoom) < 0.01,
    string.format("dragging=%s dx=%.4f want %.4f, dy=%.4f want %.4f",
      tostring(dragging), dx, 60 / zoom, dy, 40 / zoom))
  -- the world point that was under the cursor must follow the cursor
  local nx, ny = g:screenToWorld(px + 60, py + 40)
  smokeCheck(label .. " keeps the grabbed point under the cursor",
    math.abs(nx - wx) < 0.01 and math.abs(ny - wy) < 0.01,
    string.format("%.4f,%.4f vs %.4f,%.4f", nx, ny, wx, wy))
  smokeCheck(label .. " leaves the node selection intact", app.primaryUid ~= nil,
    tostring(app.primaryUid))
  smokeCheck(label .. " opens no context menu, modal or help overlay",
    app.modal == nil and app.newPack == nil and app.showHelp == false)
  if useSpace then
    smokeCheck("space is released again after the pan", g.spaceDown == false,
      tostring(g.spaceDown))
    smokeCheck("space during a canvas pan is never typed into a widget",
      consumedAtPress == true, tostring(consumedAtPress))
  end
end

--- Does any string the UI rendered label a stage with 级? (The missions editor
--- must never do that - the player counts 任务条目, not stages.)
local function renderedStageLabelsUseCi()
  for _, s in ipairs(ui.renderedText) do
    if s:find("第%s*%d+%s*级") then return true end
    if s:find("阶段", 1, true) and s:find("级", 1, true) then return true end
  end
  return false
end

--- Panels must never swallow the middle/right buttons: they belong to the canvas
--- pan and to LÖVE, not to widgets.
local function panButtonOwnershipCheck(app)
  local r = regionById("inspector")
  if not r then return end
  local px, py = ui.s(r.x + r.w / 2), ui.s(r.y + r.h / 2)
  for _, button in ipairs({ 2, 3 }) do
    ui.activeId = nil
    love.mousepressed(px, py, button)
    smokeCheck(string.format("button %d over a panel is not claimed by a widget", button),
      ui.activeId == nil, tostring(ui.activeId))
    love.mousereleased(px, py, button)
  end
end

--- A 3-rank pack where each rank has exactly 2 cards: the game only shows rank
--- 1 on entry, so the headline must say 2 - not 3 (ranks) and not 6 (missions).
local function writeProgressionPack(dir)
  Pack.removeTree(dir)
  Pack.mkdirp(Pack.join(dir, "icons"))
  local tree = {
    name = "progpack", title = "进度包", startNode = "p1", gridView = false,
    nodes = json.array({
      uid = "p1", title = "起始", description = "", type = "Generator",
      position = { x = 0, y = 0, z = 0 },
      cost = Pack.normalizeCurve(1), production = Pack.normalizeCurve(1),
      effects = json.array(), requirements = json.array(),
    }),
  }
  Pack.writeFile(Pack.join(dir, "tree.json"),
    json.encode(tree, { indent = 2, keyOrder = Pack.TREE_KEY_ORDER }) .. NL)
  local ranks = json.array()
  for r = 1, 3 do
    local missions = json.array()
    for m = 1, 2 do
      missions[m] = json.markObject({
        type = "Collect", reqItemId = "p1", reqAmount = m,
        prizeType = (m == 1) and "Darwinium" or "Stardust", prizeID = tostring(m),
        prizeAmount = m, hidden = false, treeType = "NONE",
      })
    end
    ranks[r] = json.markObject({ title = "第 " .. r .. " 段", targetHrs = r, missions = missions })
  end
  local meta = json.markObject({
    id = "progpack", title = "进度包", tree = "tree.json", icons = "icons",
    currencyCount = 1, intro = json.array("开场"), outro = json.array("结束"), missions = ranks,
  })
  Pack.writeFile(Pack.join(dir, "pack.json"),
    json.encode(meta, { indent = 2, keyOrder = Pack.PACK_KEY_ORDER }) .. NL)
  return dir
end

--- Frame-by-frame text-field probe machine (one phase per frame so the queued
--- events are consumed by a real draw in between).
function App:stepFieldProbes()
  local s = self.smoke
  local p = s.probes[s.probeIdx]
  if not p then return false end
  s.probePhase = (s.probePhase or 0) + 1
  local phase = s.probePhase

  if phase == 1 then
    if p.view then self.view = p.view end
  elseif phase == 2 then
    local st = ui.stateFor(p.id)
    local rect = st and st.rect
    if not rect then
      smokeCheck("field probe: " .. p.name .. " is on screen", false, "no rect for " .. p.id)
      s.probeIdx = s.probeIdx + 1
      s.probePhase = 0
      return true
    end
    p.before = p.get()
    local cx, cy = ui.s(rect.x + rect.w / 2), ui.s(rect.y + rect.h / 2)
    love.mousemoved(cx, cy, 0, 0)
    love.mousepressed(cx, cy, 1)
    love.mousereleased(cx, cy, 1)
  elseif phase == 3 then
    smokeCheck("field probe: clicking focuses " .. p.name, ui.focus == p.id, tostring(ui.focus))
    love.textinput(p.text)
  elseif phase == 4 then
    local got = p.get()
    smokeCheck("field probe: typing works in " .. p.name, got == p.expect(p.before),
      string.format("%s -> %s (expected %s)", tostring(p.before), tostring(got),
        tostring(p.expect(p.before))))
    love.keypressed("backspace", nil, false)
  elseif phase == 5 then
    local got = p.get()
    smokeCheck("field probe: backspace works in " .. p.name, got == p.before,
      string.format("%s (expected %s)", tostring(got), tostring(p.before)))
    ui.focus = nil
    s.probeIdx = s.probeIdx + 1
    s.probePhase = 0
  end
  return true
end

function App:stepEditSteps(listName, idxName)
  local s = self.smoke
  listName = listName or "editSteps"
  idxName = idxName or "editIdx"
  local step = s[listName][s[idxName]]
  if not step then return false end
  s[idxName] = s[idxName] + 1
  if step.setup then step.setup()
  elseif step.probe then step.probe()
  elseif step.click then
    if not clickWidget(step.click) then
      smokeCheck("editing: " .. step.click .. " is on screen", false, "no rect")
    end
  elseif step.type then love.textinput(step.type)
  elseif step.shot then self:smokeShot(step.shot, false)
  elseif step.key then
    if step.ctrl then self.ctrlOverride = true end
    love.keypressed(step.key, nil, false)
    if step.ctrl then self.ctrlOverride = nil end
  elseif step.check then
    smokeCheck("editing: " .. step.name, step.check(), step.detail and step.detail() or nil)
  end
  return true
end

function App:smokeStep()
  local s = self.smoke
  if not s then return end
  s.frames = s.frames + 1
  if s.probes and self:stepFieldProbes() then return end
  if s.editSteps and self:stepEditSteps() then return end
  if s.nodeSteps and self:stepEditSteps("nodeSteps", "nodeIdx") then return end
  if s.bgSteps and self:stepEditSteps("bgSteps", "bgIdx") then return end
  if s.dialogSteps and self:stepEditSteps("dialogSteps", "dialogIdx") then return end
  local g = self.graph

  if s.frames == 8 then
    local n = self.pack and self.pack.tree.nodes[2]
    if n then
      local sx, sy = g:worldToScreen(n.position.x, n.position.y)
      s.nodeUid = n.uid
      s.startX, s.startY = n.position.x, n.position.y
      s.screenX, s.screenY = sx, sy
      love.mousemoved(sx, sy, 0, 0)
      love.mousepressed(sx, sy, 1)
      love.mousereleased(sx, sy, 1)
    end
  elseif s.frames == 10 then
    smokeCheck("canvas click selects the node under the cursor",
      self.primaryUid == s.nodeUid, tostring(self.primaryUid))
  elseif s.frames == 12 then
    local wx1, wy1 = g:screenToWorld(s.screenX, s.screenY)
    local wx2, wy2 = g:screenToWorld(s.screenX + 40, s.screenY + 20)
    s.expectX = math.floor(s.startX + (wx2 - wx1) + 0.5)
    s.expectY = math.floor(s.startY + (wy2 - wy1) + 0.5)
    love.mousepressed(s.screenX, s.screenY, 1)
    love.mousemoved(s.screenX + 40, s.screenY + 20, 40, 20)
    love.mousereleased(s.screenX + 40, s.screenY + 20, 1)
  elseif s.frames == 14 then
    local n = Pack.nodeByUid(self.pack, s.nodeUid)
    smokeCheck("dragging a node writes integer world coordinates",
      n and n.position.x == s.expectX and n.position.y == s.expectY,
      n and (n.position.x .. "," .. n.position.y .. " expected " .. s.expectX .. "," .. s.expectY))
    smokeCheck("drag marks the pack dirty", self.dirty == true)
    if n then n.position.x, n.position.y = s.startX, s.startY end
    self.dirty = false
  elseif s.frames == 16 then
    self.view = "settings"
  elseif s.frames == 20 then
    self:smokeShot("smoketest_settings.png", false)
  elseif s.frames == 26 then
    self.view = "validate"
    self:validate(true)
  elseif s.frames == 30 then
    self:smokeShot("smoketest_validate.png", false)
  elseif s.frames == 36 then
    self.view = "graph"
  elseif s.frames == 46 then
    local mx, my = self.canvas.x + 200, self.canvas.y + 200
    local wx, wy = g:screenToWorld(mx, my)
    g:wheel(mx, my, 3)
    local wx2, wy2 = g:screenToWorld(mx, my)
    smokeCheck("zoom keeps the world point under the cursor",
      math.abs(wx - wx2) < 0.01 and math.abs(wy - wy2) < 0.01,
      string.format("%.3f,%.3f vs %.3f,%.3f", wx, wy, wx2, wy2))
  elseif s.frames == 48 then
    g:fit(self.pack)
    smokeCheck("validation runs without errors", type(self.problems) == "table",
      "#problems=" .. #self.problems)
    smokeCheck("start node resolves", Pack.nodeByUid(self.pack, self.pack.tree.startNode) ~= nil)
  elseif s.frames == 52 then
    self.showHelp = true
  elseif s.frames == 54 then
    self:smokeShot("smoketest_help.png", false)
    smokeCheck("help overlay opens", self.showHelp == true)
  elseif s.frames == 56 then
    self.showHelp = false
    self:openIconPicker("deepsea_rov")
    smokeCheck("file browser modal opens", self.modal ~= nil)
  elseif s.frames == 58 then
    self:smokeShot("smoketest_browser.png", false)
    smokeCheck("file browser lists the pack folder", self.modal ~= nil and #self.modal.entries > 0,
      self.modal and ("entries=" .. #self.modal.entries))
    if self.modal then self.modal:cancel() self.modal = nil end
  elseif s.frames == 62 then
    self:smokeShot("smoketest.png", false)
  elseif s.frames == 64 then
    -- full "new pack" GUI flow, written to a scratch folder outside the repo
    s.tmpParent = "/tmp/c2s_editor_smoke"
    Pack.removeTree(s.tmpParent)
    local created = self:createPack(s.tmpParent, "SmokePack", "冒烟测试包")
    smokeCheck("new pack created through the GUI", created == true and self.pack ~= nil)
    smokeCheck("new pack starts with a single node",
      self.pack and #self.pack.tree.nodes == 1, self.pack and tostring(#self.pack.tree.nodes))
  elseif s.frames == 66 then
    self:setSelection({ self.pack.tree.nodes[1].uid })
    self:validate(true)
    smokeCheck("new pack validates without crashing", type(self.problems) == "table")
  elseif s.frames == 68 then
    self:deleteSelected()
    self:validate(true)
  elseif s.frames == 69 then
    self.view = "validate"
  elseif s.frames == 70 then
    smokeCheck("deleting the last node leaves an empty tree",
      self.pack and #self.pack.tree.nodes == 0, self.pack and tostring(#self.pack.tree.nodes))
    smokeCheck("empty tree is reported as an error", self.counts.error > 0)
    self:smokeShot("smoketest_errors.png", false)
  elseif s.frames == 71 then
    self:openPack("/nonexistent/pack/dir")
    smokeCheck("opening a bad path shows an error banner instead of crashing",
      self.banner ~= nil and self.pack ~= nil)
  elseif s.frames == 72 then
    Pack.removeTree(s.tmpParent)
    self.view = "graph"
    self:openPack(s.dir)
    smokeCheck("reopening the sample pack works", self.pack ~= nil and #self.pack.tree.nodes == 7)
    smokeCheck("sample pack has no validation errors", self.counts.error == 0)
  elseif s.frames == 73 then
    self:setSelection({ self.pack.tree.nodes[2].uid })
  elseif s.frames == 74 then
    -- open the inspector type dropdown through a real click
    local rect = ui.state["insp.type"] and ui.state["insp.type"].rect
    s.dropRect = rect
    if rect then
      love.mousemoved(rect.x + 20, rect.y + 10, 0, 0)
      love.mousepressed(rect.x + 20, rect.y + 10, 1)
      love.mousereleased(rect.x + 20, rect.y + 10, 1)
    end
  elseif s.frames == 75 then
    smokeCheck("clicking a dropdown opens its popup",
      ui.popupOwner == "insp.type" and ui.popupRect ~= nil, tostring(ui.popupOwner))
    -- pick the third entry (Trophy) from the popup list
    local pr = ui.popupRect
    local rect = s.dropRect
    if pr and rect then
      local iy = pr.y + 1 + 2 * rect.h + rect.h / 2
      s.wantType = "Trophy"
      love.mousemoved(pr.x + 20, iy, 0, 0)
      love.mousepressed(pr.x + 20, iy, 1)
      love.mousereleased(pr.x + 20, iy, 1)
    end
  elseif s.frames == 76 then
    local n = Pack.nodeByUid(self.pack, self.primaryUid)
    smokeCheck("picking a dropdown entry updates the model",
      n ~= nil and n.type == "Trophy", n and tostring(n.type))
    smokeCheck("the popup closes after picking", ui.popupOwner == nil, tostring(ui.popupOwner))
    if n then n.type = "Generator" end
    self.dirty = false
    self:smokeShot("smoketest_dropdown.png", false)
  elseif s.frames == 80 then
    s.bigDir = writeBigPack("/tmp/c2s_editor_smoke_big")
    local ok = self:openPack(s.bigDir)
    smokeCheck("8 ranks x 4 missions pack opens", ok == true and self.pack ~= nil)
    smokeCheck("pack really has 9 ranks of 4 missions",
      type(self.pack.meta.missions) == "table" and #self.pack.meta.missions == 9
      and #self.pack.meta.missions[8].missions == 4,
      tostring(#(self.pack.meta.missions or {})))
    -- the game merges CONSECUTIVE missions with equal (prizeType, prizeID)
    local mergeRank = self.pack.meta.missions[9]
    local mergeCards = Pack.countMissionCards(mergeRank)
    smokeCheck("mission card count follows the game merge rule (A,A,B,A -> 3 cards)",
      #mergeRank.missions == 4 and mergeCards == 3,
      string.format("%d missions -> %d cards", #mergeRank.missions, mergeCards))
    smokeCheck("merged runs are reported for the validation panel",
      #Pack.mergedMissionRuns(mergeRank) == 1,
      tostring(#Pack.mergedMissionRuns(mergeRank)))
    local warned = false
    for _, p in ipairs(self.problems) do
      if p.field == "missions" and tostring(p.msg):find("张卡片", 1, true) then warned = true end
    end
    smokeCheck("validation warns about merged task cards", warned)
    -- node shapes are a pure mapping, so assert it directly too
    local shapeIds = {}
    for _, t in ipairs(Pack.TYPES) do
      local s = Graph.shapeFor(t)
      smokeCheck("node type " .. t .. " maps to shape '" .. tostring(s) .. "'", s ~= nil and s ~= "")
      shapeIds[s] = (shapeIds[s] or 0) + 1
    end
    smokeCheck("every node type has a distinct shape id",
      shapeIds.circle == 1 and shapeIds.hexagon == 1 and shapeIds.star == 1,
      json.encode(shapeIds, { indent = 0 }))
    local sample = Pack.load(s.dir)
    local trophy = nil
    if sample then
      for _, n in ipairs(sample.tree.nodes) do
        if n.type == "Trophy" then trophy = n end
      end
    end
    smokeCheck("a Trophy node in the sample pack reports the star shape",
      trophy ~= nil and Graph.shapeFor(trophy.type) == "star",
      trophy and Graph.shapeFor(trophy.type) or "no trophy node")
    self:setSelection({})
  elseif s.frames == 82 then
    self.view = "settings"
  elseif s.frames == 84 then
    local r = regionById("set.missions")
    s.misRegion = r
    smokeCheck("missions editor has its own scroll region", r ~= nil and r.max > 0,
      r and ("max=" .. tostring(r.max)))
    smokeCheck("missions content is taller than the screen", r ~= nil and r.max > 400,
      r and tostring(r.max))
  elseif s.frames == 86 then
    local r = regionById("set.missions") or s.misRegion
    if r then
      realWheel(ui.s(r.x + r.w / 2), ui.s(r.y + r.h / 2), 0, -3)
    end
  elseif s.frames == 87 then
    smokeCheck("wheel routes to the list under the cursor, not globally",
      ui.wheelTarget == "set.missions", tostring(ui.wheelTarget))
    smokeCheck("missions list scrolled", (ui.state["set.missions"].scroll or 0) > 0,
      tostring(ui.state["set.missions"].scroll))
    smokeCheck("page behind the list did not scroll",
      (ui.state["settings"].scroll or 0) == 0, tostring(ui.state["settings"].scroll))
    smokeCheck("plain wheel does not change the UI scale",
      math.abs(self.uiScale - 1.0) < 0.001, tostring(self.uiScale))
    ui.state["set.missions"].scroll = 100000
  elseif s.frames == 88 then
    local st = ui.state["set.missions"]
    smokeCheck("scroll offset is clamped to the content height",
      math.abs((st.scroll or 0) - (st.max or 0)) < 0.001,
      string.format("%s vs %s", tostring(st.scroll), tostring(st.max)))
    smokeCheck("the last mission rank is reachable", (st.scroll or 0) > 400,
      tostring(st.scroll))
    self:smokeShot("smoketest_missions.png", false)
  elseif s.frames == 89 then
    local st = ui.state["set.missions"]
    st.scroll = (st.max or 0) * 0.5          -- audit from the middle of the list
  elseif s.frames == 90 then
    auditCheck("missions @1.0x", "set.missions")
  elseif s.frames == 91 then
    self.view = "validate"
    love.window.setMode(900, 600, { resizable = true })
  elseif s.frames == 92 then
    local r = regionById("validate.list")
    s.valRegion = r
    smokeCheck("validation list is horizontally scrollable for long messages",
      r ~= nil and (r.maxH or 0) > 0, r and ("maxH=" .. tostring(r.maxH)))
    if r then
      s.valScrollBefore = ui.state["validate.list"].scroll or 0
      ui.modifierOverride = { shift = true }
      realWheel(ui.s(r.x + r.w / 2), ui.s(r.y + r.h / 2), 0, -3)
    end
  elseif s.frames == 93 then
    ui.modifierOverride = nil
    local st = ui.state["validate.list"]
    smokeCheck("Shift+wheel scrolls sideways", (st.hscroll or 0) > 0,
      "hscroll=" .. tostring(st.hscroll))
    smokeCheck("Shift+wheel does not also scroll vertically",
      (st.scroll or 0) == (s.valScrollBefore or 0),
      tostring(st.scroll) .. " vs " .. tostring(s.valScrollBefore))
    self:smokeShot("smoketest_hscroll.png", false)
  elseif s.frames == 94 then
    self.view = "settings"
    self:setUIScale(1.5)
  elseif s.frames == 95 then
    local st = ui.state["set.missions"]
    st.scroll = (st.max or 0) * 0.5
  elseif s.frames == 96 then
    auditCheck("missions @1.5x", "set.missions")
    self:smokeShot("smoketest_missions_scale15.png", false)
  elseif s.frames == 97 then
    self:setUIScale(0.75)
  elseif s.frames == 98 then
    local st = ui.state["set.missions"]
    st.scroll = (st.max or 0) * 0.5
  elseif s.frames == 99 then
    auditCheck("missions @0.75x", "set.missions")
    self:setUIScale(1.0)
  elseif s.frames == 100 then
    local r = regionById("set.missions")
    s.ctrlScaleBefore = self.uiScale
    s.ctrlScrollBefore = ui.state["set.missions"].scroll or 0
    s.ctrlPy = ui.s(r and (r.y + r.h / 2) or 300)
    ui.modifierOverride = { ctrl = true }
    if r then realWheel(ui.s(r.x + r.w / 2), s.ctrlPy, 0, 2) end
  elseif s.frames == 101 then
    ui.modifierOverride = nil
    local a, b = s.ctrlScaleBefore or 1, self.uiScale
    local actual = ui.state["set.missions"].scroll or 0
    local expected = (s.ctrlScrollBefore or 0) + (s.ctrlPy or 0) * (1 / a - 1 / b)
    smokeCheck("Ctrl+wheel zooms the whole UI scale", b > a,
      string.format("%.2f -> %.2f", a, b))
    smokeCheck("Ctrl+wheel is not treated as a normal wheel notch",
      math.abs(actual - ((s.ctrlScrollBefore or 0) + 96)) > 1, string.format("%.1f", actual))
    smokeCheck("Ctrl+wheel keeps the row under the cursor anchored",
      math.abs(actual - expected) < 2, string.format("%.1f vs %.1f", actual, expected))
    self:setUIScale(1.0)
  elseif s.frames == 102 then
    self.view = "graph"
    self:setSelection({ self.pack.tree.nodes[2].uid })
  elseif s.frames == 103 then
    local pw, ph = love.graphics.getDimensions()
    smokeCheck("window resized to 900x600", pw == 900 and ph == 600, pw .. "x" .. ph)
    smokeCheck("no panels overlap at 900x600", self:panelsOverlap() == nil,
      tostring(self:panelsOverlap()))
    smokeCheck("canvas keeps a usable width at 900x600", self.canvas.w >= 60,
      tostring(self.canvas.w))
    smokeCheck("inspector is still visible at 900x600", self.effInspector == true)
    self:smokeShot("smoketest_900x600.png", false)
  elseif s.frames == 104 then
    local r = regionById("inspector")
    s.inspRegion = r
    smokeCheck("inspector column is a scroll region with overflow on a small window",
      r ~= nil and r.max > 0, r and ("max=" .. tostring(r.max)))
    if r then
      realWheel(ui.s(r.x + r.w / 2), ui.s(r.y + r.h / 2), 0, -3)
    end
  elseif s.frames == 105 then
    smokeCheck("wheel scrolls the inspector column",
      ui.wheelTarget == "inspector" and (ui.state["inspector"].scroll or 0) > 0,
      tostring(ui.wheelTarget) .. " scroll=" .. tostring(ui.state["inspector"].scroll))
    s.barScrollBefore = ui.state["inspector"].scroll
    local r = regionById("inspector") or s.inspRegion
    if r then
      local barW = 7
      local thumbH = math.max(24, r.h * (r.h / (r.h + r.max)))
      local thumbY = r.y + (r.h - thumbH) * (r.scroll / r.max)
      s.barX, s.barY = r.x + r.w - barW / 2, thumbY + thumbH / 2
      love.mousemoved(ui.s(s.barX), ui.s(s.barY), 0, 0)
      love.mousepressed(ui.s(s.barX), ui.s(s.barY), 1)
    end
  elseif s.frames == 106 then
    love.mousemoved(ui.s(s.barX), ui.s(s.barY + 60), 0, ui.s(60))
  elseif s.frames == 107 then
    love.mousereleased(ui.s(s.barX), ui.s(s.barY + 60), 1)
    local st = ui.state["inspector"]
    smokeCheck("dragging the scrollbar thumb scrolls the panel",
      (st.scroll or 0) > (s.barScrollBefore or 0),
      string.format("%s -> %s", tostring(s.barScrollBefore), tostring(st.scroll)))
    auditCheck("inspector @1.0x", "inspector")
    self:smokeShot("smoketest_inspector_small.png", false)
  elseif s.frames == 108 then
    self:setUIScale(1.5)
  elseif s.frames == 109 then
    smokeCheck("no panels overlap at 1.5x on the small window", self:panelsOverlap() == nil,
      tostring(self:panelsOverlap()))
    smokeCheck("font atlas rebuilt at the scaled pixel size",
      ui.font("body"):getHeight() > Fonts.get(Fonts.SIZES.body):getHeight(),
      ui.font("body"):getHeight() .. " vs " .. Fonts.get(Fonts.SIZES.body):getHeight())
    auditCheck("inspector @1.5x", "inspector")
    self:smokeShot("smoketest_scale15_small.png", false)
  elseif s.frames == 110 then
    local px = ui.s(self.canvas.x + self.canvas.w * 0.4)
    local py = ui.s(self.canvas.y + self.canvas.h * 0.5)
    local wx, wy = self.graph:screenToWorld(px, py)
    s.canvasAnchor = { px = px, py = py, wx = wx, wy = wy }
    ui.modifierOverride = { ctrl = true }
    realWheel(px, py, 0, 2)
  elseif s.frames == 111 then
    ui.modifierOverride = nil
    local an = s.canvasAnchor
    local wx, wy = self.graph:screenToWorld(an.px, an.py)
    smokeCheck("Ctrl+wheel keeps the canvas world point under the cursor",
      math.abs(wx - an.wx) < 0.05 and math.abs(wy - an.wy) < 0.05,
      string.format("%.3f,%.3f vs %.3f,%.3f", wx, wy, an.wx, an.wy))
    self:setUIScale(0.75)
  elseif s.frames == 112 then
    smokeCheck("no panels overlap at 0.75x on the small window", self:panelsOverlap() == nil,
      tostring(self:panelsOverlap()))
    auditCheck("inspector @0.75x", "inspector")
  elseif s.frames == 113 then
    self:setUIScale(1.5)
    love.window.setMode(1500, 950, { resizable = true })
  elseif s.frames == 114 then
    smokeCheck("all three panels fit again on the large window at 1.5x",
      self.effSidebar == true and self.effInspector == true,
      tostring(self.effSidebar) .. "/" .. tostring(self.effInspector))
    smokeCheck("no panels overlap at 1.5x on the large window", self:panelsOverlap() == nil,
      tostring(self:panelsOverlap()))
    self.view = "settings"
    local st = ui.state["set.missions"]
    st.scroll = (st.max or 0) * 0.45
  elseif s.frames == 115 then
    auditCheck("missions @1.5x on the large window", "set.missions")
    self:smokeShot("smoketest_missions_scale15.png", false)
  elseif s.frames == 116 then
    self.view = "graph"
    self:smokeShot("smoketest_scale15.png", false)
  elseif s.frames == 117 then
    self:setUIScale(1.0)
    Pack.removeTree(s.bigDir)
    self.view = "graph"
    self:openPack(s.dir)
    smokeCheck("back to the sample pack", self.pack ~= nil and #self.pack.tree.nodes == 7,
      self.pack and tostring(#self.pack.tree.nodes))
    smokeCheck("sample pack still has no validation errors", self.counts.error == 0,
      tostring(self.counts.error))
  elseif s.frames == 119 then
    -- editor.cfg persistence (the smoke test normally never touches it)
    self.configPath = Config.defaultPath(love.filesystem.getSource())
    self.noConfig = false
    self:setUIScale(1.25)
    local text = Config.load(self.configPath)
    smokeCheck("editor.cfg is written when the UI scale changes", text.ui_scale == 1.25,
      tostring(text.ui_scale))
  elseif s.frames == 121 then
    self.uiScale = 1
    ui.setScale(1)
    self:loadConfig()
    smokeCheck("editor.cfg is read back on startup", math.abs(self.uiScale - 1.25) < 0.001,
      tostring(self.uiScale))
    os.remove(self.configPath)
    self.noConfig = true
    self:setUIScale(1.0)
    smokeCheck("editor.cfg removed again by the test", not Pack.exists(self.configPath))
    self.view = "settings"      -- show the bundled pack's missions editor
  elseif s.frames == 123 then
    smokeCheck("no panels overlap after the whole resize/scale round trip",
      self:panelsOverlap() == nil, tostring(self:panelsOverlap()))
    smokeCheck("the draw/hit audit used a real graphics transform probe",
      ui.auditTransformOk == true, tostring(ui.auditTransformOk))
    smokeCheck("smoke test never left editor.cfg behind", self.noConfig == true)
    -- the bundled SamplePack is the fixture the user compares against the game:
    -- 3 ranks and 6 missions in the file, but the player only ever sees the
    -- FIRST rank's task groups, which is 2.
    local sprog = Pack.missionProgression(self.pack.meta)
    local stotal = 0
    for _, lv in ipairs(sprog.levels) do stotal = stotal + lv.missions end
    -- assert on what the editor RENDERS, not on internal data
    local rendered = table.concat(ui.renderedText, string.char(10))
    -- The bundled pack is edited over time, so the numbers are derived from the
    -- file; the strict "not the stage count / not the mission total" assertions
    -- live on the synthetic 3-stage pack below, where they are unambiguous.
    local panelText = Pack.missionPanelText(self.pack.meta)
    local panelCount = Pack.missionPanelCount(self.pack.meta)
    local stage1 = Pack.countMissionCards(self.pack.meta.missions[1])
    smokeCheck("sample pack: editor renders the game's panel line",
      rendered:find(panelText, 1, true) ~= nil, "expected: " .. panelText)
    smokeCheck("sample pack: panel count comes from stage 1 only",
      panelCount == stage1 and stage1 > 0,
      string.format("panel=%d stage1=%d stages=%d fileMissions=%d", panelCount, stage1,
        sprog.rankCount, stotal))
    smokeCheck("sample pack: panel count never exceeds the file's mission total",
      panelCount <= stotal, string.format("panel=%d total=%d", panelCount, stotal))
    smokeCheck("sample pack: the editor never renders 第 2 级 / 第 3 级",
      rendered:find("第 2 级", 1, true) == nil and rendered:find("第 3 级", 1, true) == nil,
      "found a stage labelled with 级")
    smokeCheck("sample pack: no rendered label calls a stage 级",
      not renderedStageLabelsUseCi() and rendered:find("任务等级", 1, true) == nil,
      "some rendered label uses 级 / 任务等级 for a stage")
    smokeCheck("sample pack: stage 1 is labelled as the one shown first",
      rendered:find("阶段 1", 1, true) ~= nil
      and rendered:find("游戏中首先显示", 1, true) ~= nil,
      "stage 1 is not labelled as the one shown first")
    smokeCheck("sample pack: later stages are labelled as unlocking in order",
      rendered:find("完成阶段 1 后进入", 1, true) ~= nil
      and rendered:find("完成阶段 2 后进入", 1, true) ~= nil,
      "stage 2/3 are not labelled as unlocking in order")
    smokeCheck("sample pack: the editor never says a stage will not be shown",
      rendered:find("不会被显示", 1, true) == nil and rendered:find("不会显示", 1, true) == nil,
      "found exclusion wording in the rendered missions editor")
    self:smokeShot("smoketest_missions_sample.png", false)
  -- ---------------------------------------------------------------------
  -- Regression: the REAL wheel path. No ui.wheelmoved() shortcuts here -
  -- the pointer is moved with love.mousemoved and the notch is delivered
  -- through love.wheelmoved, exactly like LÖVE does at runtime.
  -- ---------------------------------------------------------------------
  elseif s.frames == 125 then
    self:setUIScale(1.0)
    love.window.setMode(900, 600, { resizable = true })
    self.view = "graph"
    self:setSelection({ self.pack.tree.nodes[2].uid })
  elseif s.frames == 127 then
    local r = regionById("inspector")
    smokeCheck("real wheel @1.0x: the inspector column overflows", r ~= nil and r.max > 0,
      r and ("max=" .. tostring(r.max)))
    if r then
      s.rwX, s.rwY = ui.s(r.x + r.w / 2), ui.s(r.y + r.h / 2)
      -- start from the middle so a notch always has room to move
      local st = ui.state["inspector"]
      st.scroll = (st.max or 0) * 0.5
      s.rwBefore = st.scroll
      love.mousemoved(s.rwX, s.rwY, 0, 0)
      love.wheelmoved(0, -3)
    end
  elseif s.frames == 128 then
    smokeCheck("plain wheel over a side panel scrolls it (real callback, 1.0x)",
      (ui.state["inspector"].scroll or 0) > (s.rwBefore or 0),
      string.format("%.1f -> %.1f", s.rwBefore or 0, ui.state["inspector"].scroll or 0))
    self:setUIScale(1.5)
  elseif s.frames == 129 then
    local r = regionById("inspector")
    if r then
      local st = ui.state["inspector"]
      st.scroll = (st.max or 0) * 0.5
      s.rwBefore = st.scroll
      love.mousemoved(ui.s(r.x + r.w / 2), ui.s(r.y + r.h / 2), 0, 0)
      love.wheelmoved(0, -3)
    end
  elseif s.frames == 130 then
    smokeCheck("plain wheel over a side panel scrolls it (real callback, 1.5x)",
      (ui.state["inspector"].scroll or 0) > (s.rwBefore or 0),
      string.format("%.1f -> %.1f", s.rwBefore or 0, ui.state["inspector"].scroll or 0))
    self:setUIScale(0.75)
  elseif s.frames == 131 then
    local r = regionById("inspector")
    if r then
      local st = ui.state["inspector"]
      st.scroll = (st.max or 0) * 0.5
      s.rwBefore = st.scroll
      love.mousemoved(ui.s(r.x + r.w / 2), ui.s(r.y + r.h / 2), 0, 0)
      love.wheelmoved(0, -3)
    end
  elseif s.frames == 132 then
    smokeCheck("plain wheel over a side panel scrolls it (real callback, 0.75x)",
      (ui.state["inspector"].scroll or 0) > (s.rwBefore or 0),
      string.format("%.1f -> %.1f", s.rwBefore or 0, ui.state["inspector"].scroll or 0))
    -- and the canvas: the same real path must zoom it, not a panel
    s.zoomBefore = self.graph.zoom
    s.panelBefore = ui.state["inspector"].scroll or 0
    love.mousemoved(ui.s(self.canvas.x + self.canvas.w / 2), ui.s(self.canvas.y + self.canvas.h / 2), 0, 0)
    love.wheelmoved(0, 3)
  elseif s.frames == 133 then
    smokeCheck("plain wheel over the canvas zooms it (real callback)",
      self.graph.zoom > (s.zoomBefore or 0),
      string.format("%.3f -> %.3f", s.zoomBefore or 0, self.graph.zoom))
    smokeCheck("plain wheel over the canvas does not scroll a panel",
      (ui.state["inspector"].scroll or 0) == (s.panelBefore or 0),
      tostring(ui.state["inspector"].scroll) .. " vs " .. tostring(s.panelBefore))
    -- Ctrl+wheel through the real path still scales the UI
    s.scaleBefore = self.uiScale
    ui.modifierOverride = { ctrl = true }
    love.mousemoved(s.rwX, s.rwY, 0, 0)
    love.wheelmoved(0, 2)
  elseif s.frames == 134 then
    ui.modifierOverride = nil
    smokeCheck("Ctrl+wheel through the real path scales the UI",
      self.uiScale > (s.scaleBefore or 1),
      string.format("%.2f -> %.2f", s.scaleBefore or 1, self.uiScale))
    self:setUIScale(1.0)
    self.view = "graph"
  elseif s.frames == 135 then
    -- the positive Shift+wheel case ran on the 8-rank pack (frame 92); here we
    -- pin the documented fall-through: a panel with no horizontal room must
    -- still scroll vertically on Shift+wheel
    local r = regionById("inspector")
    if r then
      local st = ui.state["inspector"]
      st.scroll = (st.max or 0) * 0.5
      s.fallBefore = st.scroll
      ui.modifierOverride = { shift = true }
      realWheel(ui.s(r.x + r.w / 2), ui.s(r.y + r.h / 2), 0, -3)
    end
  elseif s.frames == 136 then
    ui.modifierOverride = nil
    smokeCheck("Shift+wheel falls through to vertical when there is no horizontal room",
      (ui.state["inspector"].scroll or 0) > (s.fallBefore or 0),
      string.format("%.1f -> %.1f", s.fallBefore or 0, ui.state["inspector"].scroll or 0))
  elseif s.frames == 138 then
    smokeCheck("no panels overlap after the real-wheel regression pass",
      self:panelsOverlap() == nil, tostring(self:panelsOverlap()))
  -- ---------------------------------------------------------------------
  -- Regression: canvas panning through the REAL mouse callbacks, at three
  -- UI scales, with a node selected, for all three documented bindings.
  -- ---------------------------------------------------------------------
  elseif s.frames == 140 then
    self:setUIScale(1.0)
    love.window.setMode(1500, 950, { resizable = true })
    self.view = "graph"
    self:setSelection({ self.pack.tree.nodes[2].uid })
  elseif s.frames == 142 then
    panCheck(self, "middle-drag", 3, 1.0)
  elseif s.frames == 143 then
    self:setUIScale(1.5)
  elseif s.frames == 144 then
    panCheck(self, "right-drag", 2, 1.5)
  elseif s.frames == 145 then
    self:setUIScale(0.75)
  elseif s.frames == 146 then
    -- space must be consumed before it can reach a focused text field ...
    local keepFocus = ui.focus
    love.mousemoved(ui.s(self.canvas.x + 100), ui.s(self.canvas.y + 100), 0, 0)
    ui.focus = "smoke.fake"
    love.keypressed("space", nil, false)
    smokeCheck("space over the canvas does not reach a focused text field",
      #ui.keys == 0, tostring(#ui.keys) .. " queued key(s)")
    love.keyreleased("space", nil, false)
    ui.keys = {}
    -- ... but over a panel it still belongs to the focused field
    love.mousemoved(ui.s(self.canvas.x - 40), ui.s(self.canvas.y + 100), 0, 0)
    love.keypressed("space", nil, false)
    smokeCheck("space over a panel still reaches the focused text field",
      #ui.keys == 1, tostring(#ui.keys) .. " queued key(s)")
    ui.keys = {}
    ui.focus = keepFocus
    panCheck(self, "space+left-drag", 1, 0.75, true)
    panButtonOwnershipCheck(self)
  elseif s.frames == 147 then
    self:setUIScale(1.0)
    -- extreme zoom: all the way in, pan, all the way out, then recover
    self.graph.zoom = 90
    panCheck(self, "middle-drag at max zoom", 3, 1.0)
  elseif s.frames == 148 then
    self.graph.zoom = 1.2
    panCheck(self, "middle-drag at min zoom", 3, 1.0)
    -- deliberately lose the tree, then recover with the escape hatch
    self.graph.camx, self.graph.camy, self.graph.zoom = 90000, -90000, 1.2
    self.graph:fit(self.pack)            -- exactly what Ctrl+F / 适应 do
    local allVisible = true
    for _, n in ipairs(self.pack.tree.nodes) do
      local sx, sy = self.graph:worldToScreen(n.position.x, n.position.y)
      if sx < self.canvas.x - 1 or sx > self.canvas.x + self.canvas.w + 1
        or sy < self.canvas.y - 1 or sy > self.canvas.y + self.canvas.h + 1 then
        allVisible = false
      end
    end
    smokeCheck("fit recovers every node after a runaway pan", allVisible,
      string.format("cam=%.0f,%.0f zoom=%.2f", self.graph.camx, self.graph.camy, self.graph.zoom))
    smokeCheck("fit leaves a sane zoom", self.graph.zoom > 0.5 and self.graph.zoom < 90,
      tostring(self.graph.zoom))
  elseif s.frames == 152 then
    smokeCheck("no panels overlap after the pan regression pass",
      self:panelsOverlap() == nil, tostring(self:panelsOverlap()))
  -- ---------------------------------------------------------------------
  -- Mission progression: the game shows ONE rank at a time, so the headline
  -- must be the first rank's card count.
  -- ---------------------------------------------------------------------
  elseif s.frames == 154 then
    s.progDir = writeProgressionPack("/tmp/c2s_editor_smoke_prog")
    self:openPack(s.progDir)
    self.view = "settings"
    self:validate(true)
  elseif s.frames == 156 then
    local prog = Pack.missionProgression(self.pack.meta)
    local total = 0
    for _, lv in ipairs(prog.levels) do total = total + lv.missions end
    smokeCheck("3-rank pack: the progression sees all three ranks",
      prog.rankCount == 3 and #prog.levels == 3, tostring(prog.rankCount))
    smokeCheck("3-rank pack: only rank 1 is current and it has 2 cards",
      prog.current == prog.levels[1] and prog.current.cards == 2,
      tostring(prog.current and prog.current.cards))
    smokeCheck("3-rank pack: panel line is 2 entries, not 3 stages and not 6 missions",
      Pack.missionPanelText(self.pack.meta) == "游戏中任务面板显示：2 个任务条目 (0/2)"
      and prog.current.cards ~= prog.rankCount and prog.current.cards ~= total,
      string.format("%s | stages=%d total=%d", Pack.missionPanelText(self.pack.meta),
        prog.rankCount, total))
    smokeCheck("3-rank pack: later stages are labelled as unlocking in order",
      tostring(Pack.missionStageLabel(self.pack.meta, 2)):find("完成阶段 1 后进入", 1, true) ~= nil
      and tostring(Pack.missionStageLabel(self.pack.meta, 3)):find("完成阶段 2 后进入", 1, true) ~= nil,
      Pack.missionStageLabel(self.pack.meta, 2) .. " | " .. Pack.missionStageLabel(self.pack.meta, 3))
    self:smokeShot("smoketest_missions_progression.png", false)
  elseif s.frames == 158 then
    Pack.removeTree(s.progDir)
    self:openPack(s.dir)
    self.view = "graph"
  elseif s.frames == 160 then
    smokeCheck("no panels overlap after the progression pass",
      self:panelsOverlap() == nil, tostring(self:panelsOverlap()))
  -- ---------------------------------------------------------------------
  -- WASD canvas panning, driven through the real key callbacks.
  -- ---------------------------------------------------------------------
  elseif s.frames == 162 then
    self.view = "graph"
    wasdPanCheck(self, "w", 0, 1, 1.0)
    wasdPanCheck(self, "s", 0, -1, 1.0)
    wasdPanCheck(self, "a", -1, 0, 1.0)
    wasdPanCheck(self, "d", 1, 0, 1.0)
  elseif s.frames == 164 then
    -- screen-space speed: the same on-screen motion at any zoom
    local d5 = wasdPanCheck(self, "d", 1, 0, 1.0, 5)
    local d30 = wasdPanCheck(self, "d", 1, 0, 1.0, 30)
    smokeCheck("WASD panning is screen-space (same pixels per second at any zoom)",
      math.abs(d5 * 5 - d30 * 30) < 0.02 * math.max(d5 * 5, d30 * 30),
      string.format("%.1f px @zoom 5 vs %.1f px @zoom 30", d5 * 5, d30 * 30))
    -- frame-rate independence: 30 steps of 1/60 vs 15 steps of 1/30
    local f60 = wasdPanCheck(self, "d", 1, 0, 1.0, 12, 30, 1 / 60)
    local f30 = wasdPanCheck(self, "d", 1, 0, 1.0, 12, 15, 1 / 30)
    smokeCheck("WASD panning is frame-rate independent (dt based)",
      math.abs(f60 - f30) < 0.05 * math.max(f60, f30),
      string.format("%.4f world @60fps vs %.4f world @30fps", f60, f30))
  elseif s.frames == 166 then
    wasdPanCheck(self, "d", 1, 0, 0.75)
    wasdPanCheck(self, "a", -1, 0, 1.5)
  elseif s.frames == 168 then
    -- a focused text field owns the letters: no panning, but the key is queued
    local g = self.graph
    ui.focus = "smoke.fake"
    g:clearPanKeys()
    local beforeX, beforeY = g.camx, g.camy
    love.keypressed("d", nil, false)
    local started = g.panKeys.d == true
    for _ = 1, 20 do self:update(1 / 60) end
    love.keyreleased("d", nil, false)
    smokeCheck("WASD does not pan while a text field has focus",
      (not started) and g.camx == beforeX and g.camy == beforeY,
      string.format("panKey=%s cam %.4f,%.4f -> %.4f,%.4f", tostring(started), beforeX, beforeY,
        g.camx, g.camy))
    smokeCheck("the letter still reaches the focused text field", #ui.keys == 1, tostring(#ui.keys))
    ui.keys = {}
    ui.focus = nil
  elseif s.frames == 170 then
    local slow = wasdPanCheck(self, "d", 1, 0, 1.0)
    local fast = wasdPanCheck(self, "d", 1, 0, 1.0, nil, nil, nil, true)
    smokeCheck("Shift makes WASD panning faster", fast > slow * 2,
      string.format("slow=%.4f fast=%.4f (x%.2f)", slow, fast, fast / slow))
  elseif s.frames == 172 then
    -- Ctrl+W/A/S/D stays a shortcut instead of panning
    local g = self.graph
    self.ctrlOverride = true
    g:clearPanKeys()
    local beforeX, beforeY = g.camx, g.camy
    love.keypressed("d", nil, false)
    local started = g.panKeys.d == true
    for _ = 1, 10 do self:update(1 / 60) end
    love.keyreleased("d", nil, false)
    self.ctrlOverride = nil
    smokeCheck("Ctrl+WASD does not pan (Ctrl shortcuts keep working)",
      (not started) and g.camx == beforeX and g.camy == beforeY, tostring(started))
    -- arrow-key nudging is untouched
    self:setSelection({ self.pack.tree.nodes[2].uid })
    local node = Pack.nodeByUid(self.pack, self.primaryUid)
    local x0, y0 = node.position.x, node.position.y
    love.keypressed("right", nil, false)
    smokeCheck("arrow keys still nudge the selected node",
      node.position.x == x0 + 1 and node.position.y == y0,
      string.format("%s,%s -> %s,%s", x0, y0, node.position.x, node.position.y))
    love.keypressed("left", nil, false)
    local x1 = node.position.x
    love.keypressed("d", nil, false)
    love.keyreleased("d", nil, false)
    smokeCheck("W/A/S/D never moves a node (it pans the canvas)",
      node.position.x == x1, tostring(node.position.x))
    self.dirty = false
  elseif s.frames == 174 then
    smokeCheck("no panels overlap after the WASD pass",
      self:panelsOverlap() == nil, tostring(self:panelsOverlap()))
    -- ---------------------------------------------------------------
    -- Multi-target missions (the bundled stage-1 first mission uses 2 targets)
    -- ---------------------------------------------------------------
    local m1 = self.pack.meta.missions[1].missions[1]
    s.m1 = m1
    s.targets = Pack.missionTargets(m1)
    smokeCheck("multi-target: bundled mission 1 declares 2 collect targets",
      #s.targets == 2, tostring(#s.targets))
    smokeCheck("multi-target: 2 targets but one prize is still ONE card for the stage",
      Pack.countMissionCards(self.pack.meta.missions[1]) ==
        Pack.missionProgression(self.pack.meta).levels[1].cards,
      tostring(Pack.countMissionCards(self.pack.meta.missions[1])))
    smokeCheck("multi-target: stage target total counts every mission's targets",
      Pack.stageTargetCount(self.pack.meta.missions[1]) >= 2,
      tostring(Pack.stageTargetCount(self.pack.meta.missions[1])))
    self.view = "settings"
  elseif s.frames == 176 then
    -- count the target rows the editor actually rendered for mission 1
    local rows = 0
    for _, w in ipairs(ui.debugWidgets) do
      if type(w.id) == "string" and w.id:find("^mis%.1_1%.t%d+%.item$") then rows = rows + 1 end
    end
    smokeCheck("multi-target: the editor renders one item row per target",
      rows == 2, tostring(rows) .. " rendered target rows")
    -- adding a third target through the same call the UI uses, then save it
    local m1 = s.m1
    local targets = s.targets
    targets[3] = { item = "deepsea_vent", amount = 5 }
    Pack.setMissionTargets(m1, targets)
    local tmp = "/tmp/c2s_editor_targets.json"
    json.writeFile(tmp, json.encode(self.pack.meta, { indent = 2, keyOrder = Pack.PACK_KEY_ORDER }))
    local back = json.decodeFile(tmp)
    local b1 = back.missions[1].missions[1]
    smokeCheck("multi-target: 3 targets save as a targets array of 3",
      type(b1.targets) == "table" and #b1.targets == 3, json.encode(b1.targets, { indent = 0 }))
    smokeCheck("multi-target: the flat fields are dropped in the multi form",
      b1.reqItemId == nil and b1.reqAmount == nil,
      tostring(b1.reqItemId) .. "/" .. tostring(b1.reqAmount))
    -- a mission with a single flat target must round-trip unchanged
    local m2 = self.pack.meta.missions[1].missions[2]
    local b2 = back.missions[1].missions[2]
    smokeCheck("multi-target: a flat single-target mission round-trips flat",
      type(m2.targets) ~= "table" and b2.targets == nil and b2.reqItemId == m2.reqItemId
      and b2.reqAmount == m2.reqAmount,
      string.format("%s/%s -> %s/%s targets=%s", tostring(m2.reqItemId), tostring(m2.reqAmount),
        tostring(b2.reqItemId), tostring(b2.reqAmount), tostring(b2.targets)))
    os.remove(tmp)
    -- restore the in-memory mission and move on to the text-field probes
    Pack.setMissionTargets(m1, { targets[1], targets[2] })
    s.probes = buildFieldProbes(self)
    s.probeIdx = 1
    s.probePhase = 0
  end
  if s.probes and s.probeIdx > #s.probes and not s.probesDone then
    s.probesDone = true
    smokeCheck("field probes: every text field kind was exercised",
      s.probeIdx > #s.probes, string.format("%d probes", #s.probes))
    s.editSteps = buildEditSteps(self, self.pack.tree.nodes[2])
    s.editIdx = 1
  end
  if s.editSteps and s.editIdx > #s.editSteps and not s.nodeSteps then
    s.nodeSteps = buildNodeSteps(self)
    s.nodeIdx = 1
  end
  if s.nodeSteps and s.nodeIdx > #s.nodeSteps and not s.bgSteps then
    s.bgSteps = buildBgSteps(self)
    s.bgIdx = 1
  end
  if s.bgSteps and s.bgIdx > #s.bgSteps and not s.dialogSteps then
    s.dialogSteps = buildDialogSteps(self)
    s.dialogIdx = 1
  end
  if s.editSteps and s.editIdx > #s.editSteps and s.dialogSteps
    and s.dialogIdx > #s.dialogSteps and not s.editDone then
    s.editDone = true
    -- the config test above writes editor.cfg; make sure nothing recreated it
    if app and app.noConfig then
      os.remove(Config.defaultPath(love.filesystem.getSource()))
    end
    smokeCheck("smoke test left no editor.cfg behind",
      not Pack.exists(Config.defaultPath(love.filesystem.getSource())))
    smokeCheck("editing: every editing-key step ran", true)
    smokeCheck("no panels overlap after the field-editing pass",
      self:panelsOverlap() == nil, tostring(self:panelsOverlap()))
    love.event.quit(0)
  end
  -- Frame budget for the whole smoke chain. One step runs per frame, so this has to
  -- cover every probe + edit + node + background + dialog step; at 900 the chain
  -- silently quit before the background stage ever ran.
  if s.frames > 3000 then love.event.quit(0) end
end

--- Capture the framebuffer to <appdir>/<name> (LÖVE's own save dir would hide it).
function App:smokeShot(name, quit)
  love.graphics.captureScreenshot(function(imageData)
    local ok, fd = pcall(function() return imageData:encode("png", name) end)
    if ok and fd then
      local path = Pack.join(love.filesystem.getSource(), name)
      local bytes = fd:getString()
      local f = io.open(path, "wb")
      if f then
        f:write(bytes)
        f:close()
        print("smoketest screenshot: " .. path .. " (" .. #bytes .. " bytes, " ..
          imageData:getWidth() .. "x" .. imageData:getHeight() .. ")")
      else
        print("smoketest: cannot write " .. path)
      end
    else
      print("smoketest: encode failed: " .. tostring(fd))
    end
    if quit then love.event.quit(0) end
  end)
end

--------------------------------------------------------------------------------
-- LÖVE callbacks
--------------------------------------------------------------------------------

local app

--- Keys that pan the canvas while held.
local PAN_KEYS = { w = true, a = true, s = true, d = true }

local function startsWith(s, prefix)
  return s:sub(1, #prefix) == prefix
end

local function argFlags(a, b)
  local flags = {}
  local function scan(t)
    if type(t) ~= "table" then return end
    for _, v in pairs(t) do
      if type(v) == "string" and startsWith(v, "--") then flags[v] = true end
    end
  end
  scan(a)
  scan(b)
  return flags
end

local function findSamplePack()
  local candidates = {
    Pack.join(Pack.workspaceRoot(), "CustomEvents/SamplePack"),
    Pack.join(love.filesystem.getSource(), "../../CustomEvents/SamplePack"),
  }
  for _, dir in ipairs(candidates) do
    if Pack.exists(Pack.join(dir, "tree.json")) then return dir end
  end
  return nil
end

function love.load(args)
  local flags = argFlags(arg, args)

  if not RELEASE and flags["--selftest"] then
    local failed, total = Selftest.run()
    io.stdout:flush()
    love.event.quit(failed == 0 and 0 or 1)
    return
  end

  love.keyboard.setKeyRepeat(true)   -- hold backspace/arrows to repeat in text fields

  Fonts.load()
  app = App.new()
  app.noConfig = (not RELEASE) and flags["--smoketest"] ~= nil
  app:loadConfig()
  app:layout()

  app:rescan()
  local sample = findSamplePack()
  if sample then
    app:openPack(sample)
  elseif #app.packs > 0 and app.packs[1].ok then
    app:openPack(app.packs[1].dir)
  end
  if not RELEASE and flags["--smoketest"] then
    ui.debugAudit = true      -- record draw-vs-hit rects for the assertions
    ui.debugLabels = true     -- record every rendered string for the assertions
    app.smoke = { frames = 0, dir = sample }
    print(string.format("smoketest: pack=%s nodes=%d problems=%d font=%s",
      app.pack and app.pack.dir or "none",
      app.pack and #app.pack.tree.nodes or 0,
      #app.problems, Fonts.label))
  end
end

function love.update(dt)
  if not app then return end
  app:update(dt)
end

function love.draw()
  if not app then return end
  app:draw()
end

function love.mousepressed(x, y, button, istouch, presses)
  if not app then return end
  ui.mousepressed(x, y, button)
  if app:canvasAccepts(x, y) then
    app.graph:mousepressed(app, x, y, button)
  end
end

function love.mousemoved(x, y, dx, dy, istouch)
  if not app then return end
  ui.mousemoved(x, y, dx, dy)
  if app.graph.drag then
    app.graph:mousemoved(app, x, y, dx, dy)
  elseif app:canvasAccepts(x, y) then
    app.graph:mousemoved(app, x, y, dx, dy)
  else
    app.graph.hoverUid = nil
  end
end

function love.mousereleased(x, y, button, istouch, presses)
  if not app then return end
  ui.mousereleased(x, y, button)
  if app.graph.drag then
    app.graph:mousereleased(app, x, y, button)
  end
end

function love.wheelmoved(x, y)
  if not app then return end
  -- LÖVE reports the wheel MOVEMENT here (never a position). ui reads the
  -- cursor through the shared pointer, in the same space as the region rects.
  ui.wheelmoved(x, y)
end

function love.keypressed(key, scancode, isrepeat)
  if not app then return end

  -- modals first
  if key == "escape" then
    if app.modal then
      app.modal:cancel()
      app.modal = nil
    elseif app.newPack then
      app.newPack = nil
    elseif app.showHelp then
      app.showHelp = false
    end
    return
  end
  -- A modal dialog owns the keyboard: keys still reach the focused field inside
  -- it (so backspace/Delete/Home/End/arrows work there), but nothing else - no
  -- global shortcut, no canvas pan - fires behind the dialog.
  if app.modal or app.newPack then
    -- Return confirms the New Project dialog (never a blur: clicking between
    -- fields must not create the pack)
    if app.newPack and (key == "return" or key == "kpenter") then
      app.newPack.confirm = true
    end
    if ui.focus then ui.keypressed(key) end
    return
  end
  if key == "f1" then
    app.showHelp = not app.showHelp
    return
  end
  if app.showHelp then return end

  -- Space is the pan modifier while the pointer is over the canvas. It is
  -- consumed here so it cannot reach a focused text field or any widget.
  if key == "space" then
    if app:pointerOverCanvas() then
      app.graph.spaceDown = true
      ui.spaceConsumed = true
      return
    end
  end

  -- N / Insert creates a node (never while a text field owns the keyboard)
  if (key == "n" or key == "insert") and not ui.focus and not app:ctrlDown() then
    app:newNode()
    return
  end

  -- WASD pans the canvas. With a focused text field the letter must reach the
  -- field instead (love.textinput types it), and Ctrl+W/A/S/D stays a shortcut.
  if PAN_KEYS[key] and not ui.focus and not app:ctrlDown() then
    app.graph:setPanKey(key, true)
    return
  end

  local ctrl = app:ctrlDown()
  local shift = love.keyboard.isDown("lshift", "rshift")

  -- global UI scale
  if ctrl and (key == "=" or key == "kp+" or key == "+") then
    app:setUIScale(app.uiScale + 0.05)
    return
  end
  if ctrl and (key == "-" or key == "kp-") then
    app:setUIScale(app.uiScale - 0.05)
    return
  end
  if ctrl and (key == "0" or key == "kp0") then
    app:setUIScale(1.0)
    return
  end
  -- zoom the canvas to fit every node
  if ctrl and key == "f" then
    if app.pack then
      app.graph:fit(app.pack)
      app:setStatus("已缩放到全部节点")
    end
    return
  end

  if ctrl and key == "s" then
    if shift then
      app:openBrowser({ mode = "dir", title = "另存为", path = app.root,
        onAccept = function(dir) app:saveAs(dir) end })
    else
      app:save()
    end
    return
  end
  if ctrl and key == "o" then
    app:openBrowser({
      mode = "dir",
      title = "打开活动包（进入包含 tree.json 的目录）",
      path = app.pack and app.pack.dir or Pack.join(app.root, "CustomEvents"),
      onAccept = function(dir) app:openPack(dir) end,
    })
    return
  end
  if ctrl and key == "n" then
    app:openNewPackDialog()
    return
  end
  if ctrl and key == "r" then
    app:rescan()
    return
  end
  if ctrl and key == "b" and shift then
    app.showSidebar = not app.showSidebar
    app:setStatus(app.showSidebar and "显示左侧活动包列表" or "隐藏左侧活动包列表")
    return
  end
  if ctrl and key == "d" then
    if app.pack and app.primaryUid then
      local copy = Pack.duplicateNode(app.pack, app.primaryUid)
      if copy then
        app:setSelection({ copy.uid })
        app.dirty = true
        app:setStatus("复制出 " .. copy.uid)
      end
    end
    return
  end
  if key == "tab" then
    app.showInspector = not app.showInspector
    return
  end

  -- while a text field has focus every other key belongs to it
  if ui.focus then
    ui.keypressed(key)
    return
  end

  if key == "delete" or key == "backspace" then
    -- never delete node after node from a held key
    if not isrepeat then app:deleteSelected() end
    return
  end
  local nudge = ({ up = { 0, 1 }, down = { 0, -1 }, left = { -1, 0 }, right = { 1, 0 } })[key]
  if nudge and app.pack and #app.selection > 0 then
    local step = shift and 10 or 1
    for _, uid in ipairs(app.selection) do
      local n = Pack.nodeByUid(app.pack, uid)
      if n then
        n.position.x = n.position.x + nudge[1] * step
        n.position.y = n.position.y + nudge[2] * step
      end
    end
    app.dirty = true
    app:setStatus("微调 " .. #app.selection .. " 个节点 " .. step .. " 单位")
  end
end

function love.textinput(text)
  if not app then return end
  -- a space that armed the canvas pan modifier must not be typed anywhere
  if ui.spaceConsumed and text == " " then return end
  ui.textinput(text)
end

function love.keyreleased(key, scancode)
  if not app then return end
  if key == "space" then
    app.graph.spaceDown = false
    ui.spaceConsumed = false
  end
  if PAN_KEYS[key] then
    app.graph:setPanKey(key, false)
  end
end

--- Losing the window must not leave pan keys (or the space modifier) stuck.
function love.focus(f)
  if not app then return end
  if not f then
    app.graph:clearPanKeys()
    app.graph.spaceDown = false
    ui.spaceConsumed = false
  end
end

function love.resize(w, h)
  if app then
    app:layout()
    app:setStatus("窗口 " .. w .. "x" .. h)
  end
end

function love.quit()
  if app then app:saveConfig() end
end
