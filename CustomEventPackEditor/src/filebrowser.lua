-- src/filebrowser.lua
-- A small built-in file browser modal (LÖVE has no native file dialog).
-- Two modes: "dir" (pick a folder) and "image" (pick a png/jpg).

local Pack = require("src.pack")
local ui = require("src.ui")

local FileBrowser = {}
FileBrowser.__index = FileBrowser

local function splitPath(path)
  local parts = {}
  for part in tostring(path):gmatch("[^/]+") do parts[#parts + 1] = part end
  return parts
end

function FileBrowser.new(opts)
  opts = opts or {}
  local self = setmetatable({}, FileBrowser)
  self.mode = opts.mode or "dir"
  self.title = opts.title or "选择文件夹"
  self.path = opts.path or Pack.workspaceRoot()
  self.entries = {}
  self.selected = nil
  self.onAccept = opts.onAccept
  self.onCancel = opts.onCancel
  self.done = false
  self.pathDraft = self.path
  self.error = nil
  self.w = 880
  self.h = 600
  self:refresh()
  return self
end

function FileBrowser:refresh()
  if Pack.stat(self.path) ~= "dir" then
    self.error = "目录不存在: " .. tostring(self.path)
    self.entries = {}
    return
  end
  self.error = nil
  local all = Pack.listDir(self.path)
  local out = {}
  for _, e in ipairs(all) do
    local keep = e.dir
    if not keep and self.mode == "image" then
      local ext = e.name:match("%.([%w]+)$")
      ext = ext and ext:lower() or ""
      keep = (ext == "png" or ext == "jpg" or ext == "jpeg")
    elseif not keep and self.mode == "dir" then
      keep = false
    end
    if keep then out[#out + 1] = e end
  end
  self.entries = out
  self.selected = nil
end

function FileBrowser:enter(path)
  self.path = path
  self.pathDraft = path
  self.scroll = 0
  self:refresh()
end

function FileBrowser:accept(path)
  self.done = true
  if self.onAccept then self.onAccept(path) end
end

function FileBrowser:cancel()
  self.done = true
  if self.onCancel then self.onCancel() end
end

function FileBrowser:draw(screenW, screenH)
  local w, h = self.w, self.h
  local x = math.floor((screenW - w) / 2)
  local y = math.floor((screenH - h) / 2)
  ui.setModalRect(x, y, w, h)

  ui.rect("fill", x, y, w, h, ui.theme.panel)
  ui.rect("line", x, y, w, h, ui.theme.borderLight)
  ui.rect("fill", x + 1, y + 1, w - 2, 30, ui.theme.panelAlt)
  ui.text(x + 12, y + 8, self.title, { font = "title", color = ui.theme.text })

  -- path row
  local py = y + 42
  if ui.button("fb.up", x + 12, py, 34, 26, "↑", { tip = "上一层目录" }) then
    local parent = Pack.dirname(self.path)
    if parent ~= "" and parent ~= self.path then self:enter(parent) end
  end
  local draft, changed, committed = ui.textField("fb.path", x + 52, py, w - 200, 26, self.pathDraft,
    { placeholder = "/path/to/folder" })
  if changed then self.pathDraft = draft end
  if committed then self:enter(self.pathDraft) end
  if ui.button("fb.go", x + w - 140, py, 60, 26, "跳转") then
    self:enter(self.pathDraft)
  end
  if ui.button("fb.root", x + w - 76, py, 64, 26, "工作区", { tip = "回到工作区根目录" }) then
    self:enter(Pack.workspaceRoot())
  end

  -- quick links
  local qy = py + 32
  local qx = x + 12
  local roots = Pack.defaultRoots()
  local quickLabels = { "工作区 CustomEvents", "StreamingAssets", "游戏存档目录", "存档目录 2", "存档目录 3" }
  for i, root in ipairs(roots) do
    if i <= 3 then
      local label = quickLabels[i] or ("目录 " .. i)
      local bw = ui.textW(label, "small") + 18
      if ui.button("fb.q" .. i, qx, qy, bw, 22, label, { tip = root }) then
        self:enter(root)
      end
      qx = qx + bw + 6
    end
  end

  -- listing
  local ly = qy + 30
  local lh = h - (ly - y) - 60
  local rowH = 24
  local contentH = #self.entries * rowH + 4
  ui.rect("fill", x + 12, ly, w - 24, lh, ui.theme.panelDeep)
  ui.rect("line", x + 12, ly, w - 24, lh, ui.theme.border)
  ui.beginScroll("fb.list", x + 13, ly + 1, w - 26, lh - 2, contentH)
  for i, e in ipairs(self.entries) do
    local ry = ly + 3 + (i - 1) * rowH
    local id = "fb.row." .. i
    local hovered, held, clicked = ui.clickable(id, x + 14, ry, w - 30, rowH - 2)
    if hovered or self.selected == e.path then
      ui.rect("fill", x + 14, ry, w - 30, rowH - 2,
        self.selected == e.path and ui.theme.accentSoft or ui.theme.panelAlt)
    end
    local label = (e.dir and "[目录] " or "       ") .. e.name
    ui.text(x + 20, ry + 3, label, {
      font = "small",
      color = e.dir and ui.theme.text or ui.theme.textDim,
    })
    if clicked then
      if e.dir then
        self:enter(e.path)
      else
        self.selected = e.path
      end
    end

  end
  ui.endScroll()

  -- footer
  local fy = y + h - 44
  if self.error then
    ui.text(x + 12, fy + 6, self.error, { font = "small", color = ui.theme.danger })
  elseif self.selected then
    ui.text(x + 12, fy + 6, "已选择: " .. Pack.basename(self.selected),
      { font = "small", color = ui.theme.ok })
  else
    local hint = self.mode == "image" and "单击选择一个图片文件" or "进入目标文件夹后点「选择此文件夹」"
    ui.text(x + 12, fy + 6, hint, { font = "small", color = ui.theme.textDim })
  end

  if ui.button("fb.cancel", x + w - 240, fy, 90, 28, "取消 (Esc)") then
    self:cancel()
  end
  local canAccept = (self.mode == "image") and self.selected ~= nil or (self.mode == "dir")
  local acceptLabel = self.mode == "image" and "使用此图片" or "选择此文件夹"
  if ui.button("fb.accept", x + w - 140, fy, 128, 28, acceptLabel, { accent = true, disabled = not canAccept }) then
    self:accept(self.mode == "image" and self.selected or self.path)
  end
  return self.done
end

return FileBrowser
