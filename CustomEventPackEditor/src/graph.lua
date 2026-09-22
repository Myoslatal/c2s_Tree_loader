-- src/graph.lua
-- The node graph canvas: camera (pan / zoom to cursor), grid, the in-game
-- visible-area guide, requirement edges, draggable nodes with icon thumbnails,
-- rubber band selection.

local Pack = require("src.pack")
local uiModule = require("src.ui")
local Fonts = require("src.fonts")

local Graph = {}
Graph.__index = Graph

local FLOOR, MIN, MAX, ABS = math.floor, math.min, math.max, math.abs
local CHAR = string.char

-- The canvas works in PHYSICAL pixels: it has its own zoom and its own
-- viewport, so it must not go through the logical->physical UI scaler. This
-- shim keeps the drawing calls below readable while drawing in raw pixels.
-- Chrome (legend, hints) is sized with ui.scale so it follows the UI scale.
local clipStack = {}

local function uiFont(name)
  return Fonts.get((Fonts.SIZES[name] or Fonts.SIZES.body) * uiModule.scale)
end

local ui = setmetatable({
  theme = uiModule.theme,
  scale = 1,          -- refreshed in Graph:draw
  font = uiFont,
  setFont = function(name) love.graphics.setFont(uiFont(name)) end,
  textW = function(str, name) return uiFont(name or "body"):getWidth(str) end,
  pushClip = function(x, y, w, h)
    local prev = { love.graphics.getScissor() }
    clipStack[#clipStack + 1] = prev
    love.graphics.intersectScissor(FLOOR(x), FLOOR(y), MAX(1, FLOOR(w)), MAX(1, FLOOR(h)))
  end,
  popClip = function()
    local prev = table.remove(clipStack)
    if not prev or not prev[1] then
      love.graphics.setScissor()
    else
      love.graphics.setScissor(prev[1], prev[2], prev[3], prev[4])
    end
  end,
  rect = function(mode, x, y, w, h, color, alpha)
    if alpha then love.graphics.setColor(color[1], color[2], color[3], alpha)
    else love.graphics.setColor(color[1], color[2], color[3], 1) end
    love.graphics.rectangle(mode, FLOOR(x) + 0.5, FLOOR(y) + 0.5, MAX(1, FLOOR(w)), MAX(1, FLOOR(h)))
  end,
  text = function(x, y, str, opt)
    opt = opt or {}
    love.graphics.setFont(uiFont(opt.font or "body"))
    local c = opt.color or uiModule.theme.text
    love.graphics.setColor(c[1], c[2], c[3], opt.alpha or 1)
    if opt.w then
      love.graphics.printf(str, FLOOR(x), FLOOR(y), FLOOR(opt.w),
        opt.align == "center" and "center" or (opt.align == "right" and "right" or "left"))
    else
      love.graphics.print(str, FLOOR(x), FLOOR(y))
    end
  end,
}, { __index = uiModule })

Graph.TYPE_COLORS = {
  Generator = ui.theme.generator,
  Research = ui.theme.research,
  Trophy = ui.theme.trophy,
}

Graph.TYPE_LETTER = {
  Generator = "G",
  Research = "R",
  Trophy = "T",
}

-- Node type -> drawn shape. Kept as data so the inspector, the legend, the
-- canvas and the tests all agree on one mapping.
Graph.SHAPE_BY_TYPE = {
  Generator = "circle",
  Research = "hexagon",
  Trophy = "star",
}

Graph.SHAPE_LABEL = {
  circle = "圆形",
  hexagon = "六边形",
  star = "星形",
}

--- Shape id used for a node type (never nil).
function Graph.shapeFor(nodeType)
  return Graph.SHAPE_BY_TYPE[nodeType] or "circle"
end

--- Trace one node shape in PHYSICAL pixels. mode is "fill" or "line".
--- The icon stencil, the fill, the ring, the selection glow and the legend
--- swatches all go through this so every shape stays consistent.
function Graph.traceShape(mode, shape, x, y, r)
  if shape == "hexagon" then
    local pts = {}
    for i = 0, 5 do
      local a = -math.pi / 2 + i * math.pi / 3
      pts[#pts + 1] = x + math.cos(a) * r
      pts[#pts + 1] = y + math.sin(a) * r
    end
    love.graphics.polygon(mode, pts)
  elseif shape == "star" then
    local pts = {}
    local inner = r * 0.46
    for i = 0, 9 do
      local a = -math.pi / 2 + i * math.pi / 5
      local rr = (i % 2 == 0) and r or inner
      pts[#pts + 1] = x + math.cos(a) * rr
      pts[#pts + 1] = y + math.sin(a) * rr
    end
    love.graphics.polygon(mode, pts)
  else
    love.graphics.circle(mode, x, y, r)
  end
end

function Graph.new()
  return setmetatable({
    zoom = 11,
    camx = 0,
    camy = 30,
    vx = 0, vy = 0, vw = 100, vh = 100,
    drag = nil,
    hoverUid = nil,
    spaceDown = false,
    showGrid = true,
    showBounds = true,
    showLabels = true,
    showEffects = true,
    icons = {},
    lastError = nil,
    -- background images (pack.meta.backgrounds)
    bgImages = {},         -- file -> { ok, image, w, h }
    -- WASD panning state
    panKeys = {},
    panVel = 0,
    panDirX = 0,
    panDirY = 0,
    panSpeed = 900,        -- PHYSICAL pixels per second on screen
    panFastScale = 3,      -- Shift multiplier
  }, Graph)
end

--------------------------------------------------------------------------------
-- WASD keyboard panning
--------------------------------------------------------------------------------

--- Press / release one pan key ("w", "a", "s", "d").
function Graph:setPanKey(key, down)
  self.panKeys[key] = down or nil
end

function Graph:clearPanKeys()
  self.panKeys = {}
  self.panVel = 0
end

function Graph:isPanning()
  return self.panVel > 0.001
end

--- Move the camera from the held WASD keys.
---   * speed is in PHYSICAL screen pixels per second and the world delta is
---     speed / zoom, so the motion feels identical at every zoom level;
---   * the camera lives in world units and the canvas is physical pixels, so
---     this is independent of ui.scale as well;
---   * dt based with exponential smoothing, so it is frame-rate independent and
---     starts/stops smoothly.
function Graph:updatePan(dt, fast)
  local dx, dy = 0, 0
  if self.panKeys.w then dy = dy + 1 end   -- W = camera up (world +y is up)
  if self.panKeys.s then dy = dy - 1 end
  if self.panKeys.a then dx = dx - 1 end
  if self.panKeys.d then dx = dx + 1 end
  local moving = (dx ~= 0 or dy ~= 0)

  local k = 1 - math.exp(-dt * 12)                    -- frame-rate independent ramp
  self.panVel = self.panVel + ((moving and 1 or 0) - self.panVel) * k
  if self.panVel < 0.001 then
    self.panVel = 0
    if not moving then return end
  end

  if moving then
    local len = math.sqrt(dx * dx + dy * dy)          -- no faster diagonals
    dx, dy = dx / len, dy / len
    self.panDirX, self.panDirY = dx, dy
  else
    dx, dy = self.panDirX, self.panDirY               -- glide to a stop
  end

  local speed = self.panSpeed * (fast and self.panFastScale or 1)
  local step = speed * self.panVel * dt / self.zoom
  local limit = 1e5
  self.camx = MAX(-limit, MIN(limit, self.camx + dx * step))
  self.camy = MAX(-limit, MIN(limit, self.camy + dy * step))
end

-- ------------------------------------------------------------- camera -----

function Graph:center()
  return self.vx + self.vw / 2, self.vy + self.vh / 2
end

function Graph:worldToScreen(wx, wy)
  local cx, cy = self:center()
  return cx + (wx - self.camx) * self.zoom, cy - (wy - self.camy) * self.zoom
end

function Graph:screenToWorld(sx, sy)
  local cx, cy = self:center()
  return self.camx + (sx - cx) / self.zoom, self.camy - (sy - cy) / self.zoom
end

--- Radius of a node's circle in WORLD units.
--- Measured from the running game (NODEPROBE in the plugin): the game consumes the pack's
--- position values as world units 1:1 - pack (0,0) rendered at world (0.19,-0.48) and pack
--- (-23,14) at (-23.42,14.15) - and draws a node's "frame" circle 6.798 units across (a 1.28
--- unit sprite at lossyScale 5.31). So the in-game node radius is 6.798 / 2 = 3.4 units.
--- This used to be 4.2, which drew every node about 24% larger than the game does.
local NODE_RADIUS_WORLD = 3.4

function Graph:radius()
  return MAX(8, MIN(90, NODE_RADIUS_WORLD * self.zoom))
end

--- Radius for ONE node. Generators keep the full size; every other type is drawn at a
--- third of it, which is how the game renders them (measured in-game: a Generator's frame
--- circle is 6.798 world units across, a Research/Trophy node a third of that).
local NON_GENERATOR_SCALE = 1 / 3

function Graph:nodeRadius(node)
  local r = self:radius()
  if node and node.type and node.type ~= "Generator" then
    return MAX(3, r * NON_GENERATOR_SCALE)
  end
  return r
end

function Graph:wheel(mx, my, dy)
  local wx, wy = self:screenToWorld(mx, my)
  local factor = 1.12 ^ dy
  self.zoom = MAX(1.2, MIN(90, self.zoom * factor))
  local cx, cy = self:center()
  self.camx = wx - (mx - cx) / self.zoom
  self.camy = wy + (my - cy) / self.zoom
end

--- Frame all nodes (plus the in-game view rectangle) with a margin.
function Graph:fit(pack)
  if not pack or #pack.tree.nodes == 0 then
    self.zoom = 11
    self.camx, self.camy = 0, 30
    return
  end
  local minX, maxX = 1e9, -1e9
  local minY, maxY = 1e9, -1e9
  for _, n in ipairs(pack.tree.nodes) do
    minX = MIN(minX, n.position.x)
    maxX = MAX(maxX, n.position.x)
    minY = MIN(minY, n.position.y)
    maxY = MAX(maxY, n.position.y)
  end
  local start = Pack.nodeByUid(pack, pack.tree.startNode)
  if start then
    minX = MIN(minX, start.position.x - Pack.VIEW_W / 2)
    maxX = MAX(maxX, start.position.x + Pack.VIEW_W / 2)
    minY = MIN(minY, start.position.y - 8)
    maxY = MAX(maxY, start.position.y + Pack.VIEW_H - 8)
  end
  local marginX, marginY = 14, 14
  local spanX = MAX(1, (maxX - minX) + marginX * 2)
  local spanY = MAX(1, (maxY - minY) + marginY * 2)
  self.camx = (minX + maxX) / 2
  self.camy = (minY + maxY) / 2
  self.zoom = MAX(1.2, MIN(40, MIN(self.vw / spanX, self.vh / spanY)))
end

function Graph:centerOn(pack, uid)
  local node = Pack.nodeByUid(pack, uid)
  if not node then return end
  self.camx = node.position.x
  self.camy = node.position.y
end

-- -------------------------------------------------------------- icons -----

function Graph:invalidateIcons()
  self.icons = {}
end

function Graph:icon(pack, uid)
  if not pack then return nil end
  local path = Pack.iconPath(pack, uid)
  if not path then return nil end
  local entry = self.icons[uid]
  if entry and entry.path == path then
    return entry.image
  end
  local img, err = Pack.loadImage(path)
  if not img then
    self.lastError = "图标解码失败 " .. Pack.basename(path) .. ": " .. tostring(err)
    self.icons[uid] = { path = path, image = nil }
    return nil
  end
  self.icons[uid] = { path = path, image = img }
  return img
end

-- ---------------------------------------------------------- hit testing ---

--- Hit testing uses the BOUNDING CIRCLE of the node shape (radius r) for every
--- type. Every shape is inscribed in that circle, so nothing that is drawn is
--- unclickable and the click behaviour is unchanged from the circle-only era;
--- the corners/notches just have a little slack.
function Graph:hitTest(pack, mx, my)
  if not pack then return nil end
  local nodes = pack.tree.nodes
  for i = #nodes, 1, -1 do
    local n = nodes[i]
    local r = self:nodeRadius(n)
    local sx, sy = self:worldToScreen(n.position.x, n.position.y)
    local dx, dy = mx - sx, my - sy
    if dx * dx + dy * dy <= r * r then
      return n, sx, sy
    end
  end
  return nil
end

-- ------------------------------------------------------------ drawing -----

local function setColor(c, a)
  if a then love.graphics.setColor(c[1], c[2], c[3], a)
  else love.graphics.setColor(c[1], c[2], c[3], 1) end
end

local function dashedLine(x1, y1, x2, y2, dash, gap)
  local dx, dy = x2 - x1, y2 - y1
  local len = math.sqrt(dx * dx + dy * dy)
  if len <= 0 then return end
  local ux, uy = dx / len, dy / len
  local pos = 0
  while pos < len do
    local stop = MIN(pos + dash, len)
    love.graphics.line(x1 + ux * pos, y1 + uy * pos, x1 + ux * stop, y1 + uy * stop)
    pos = stop + gap
  end
end

local function arrowHead(x1, y1, x2, y2, size)
  local dx, dy = x2 - x1, y2 - y1
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then return end
  local ux, uy = dx / len, dy / len
  local px, py = -uy, ux
  local bx, by = x2 - ux * size, y2 - uy * size
  love.graphics.polygon("fill",
    x2, y2,
    bx + px * size * 0.55, by + py * size * 0.55,
    bx - px * size * 0.55, by - py * size * 0.55)
end

function Graph:drawGrid()
  local x0, y0 = self:screenToWorld(self.vx, self.vy + self.vh)
  local x1, y1 = self:screenToWorld(self.vx + self.vw, self.vy)
  local step = 10
  if self.zoom < 3 then step = 50 elseif self.zoom < 6 then step = 20 end

  ui.pushClip(self.vx, self.vy, self.vw, self.vh)
  local startX = FLOOR(x0 / step) * step
  local startY = FLOOR(y0 / step) * step
  for wx = startX, x1 + step, step do
    local sx = self:worldToScreen(wx, 0)
    local major = (wx % (step * 5) == 0)
    setColor(ui.theme.border, major and 0.55 or 0.22)
    love.graphics.line(FLOOR(sx) + 0.5, self.vy, FLOOR(sx) + 0.5, self.vy + self.vh)
  end
  for wy = startY, y1 + step, step do
    local _, sy = self:worldToScreen(0, wy)
    local major = (wy % (step * 5) == 0)
    setColor(ui.theme.border, major and 0.55 or 0.22)
    love.graphics.line(self.vx, FLOOR(sy) + 0.5, self.vx + self.vw, FLOOR(sy) + 0.5)
  end
  -- axes
  local ax = self:worldToScreen(0, 0)
  local _, ay = self:worldToScreen(0, 0)
  setColor(ui.theme.borderLight, 0.75)
  love.graphics.line(FLOOR(ax) + 0.5, self.vy, FLOOR(ax) + 0.5, self.vy + self.vh)
  love.graphics.line(self.vx, FLOOR(ay) + 0.5, self.vx + self.vw, FLOOR(ay) + 0.5)

  -- world unit ruler hint along the bottom
  local stepPx = step * self.zoom
  if stepPx > 26 then
    setColor(ui.theme.textFaint, 0.9)
    ui.setFont("tiny")
    local x = FLOOR(x0 / step) * step
    while x <= x1 do
      local sx = self:worldToScreen(x, 0)
      if sx > self.vx + 4 and sx < self.vx + self.vw - 4 then
        love.graphics.print(tostring(x), FLOOR(sx) + 2, self.vy + self.vh - 14)
      end
      x = x + step * 5
    end
  end
  ui.popClip()
end

function Graph:drawBounds(pack)
  if not self.showBounds then return end
  local start = pack and Pack.nodeByUid(pack, pack.tree.startNode) or nil
  local ox, oy = 0, 0
  if start then ox, oy = start.position.x, start.position.y end
  local x0, y0 = ox - Pack.VIEW_W / 2, oy - 8
  local x1, y1 = ox + Pack.VIEW_W / 2, oy + Pack.VIEW_H - 8
  local sx0, sy1 = self:worldToScreen(x0, y0)
  local sx1, sy0 = self:worldToScreen(x1, y1)
  local w, h = sx1 - sx0, sy1 - sy0

  setColor(ui.theme.accent, 0.055)
  love.graphics.rectangle("fill", sx0, sy0, w, h)
  setColor(ui.theme.accent, 0.65)
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", sx0, sy0, w, h)
  love.graphics.setLineWidth(1)

  -- corner ticks so the box stays readable when it is huge
  ui.setFont("tiny")
  setColor(ui.theme.accent, 0.95)
  local label = string.format("游戏可见区域 %d x %d 世界单位", Pack.VIEW_W, Pack.VIEW_H)
  local tw = ui.textW(label, "tiny")
  love.graphics.print(label, FLOOR(sx0 + (w - tw) / 2), FLOOR(sy0) - 15)
end

function Graph:drawEdges(pack, selection)
  local zoom = self.zoom
  for _, node in ipairs(pack.tree.nodes) do
    local nx, ny = self:worldToScreen(node.position.x, node.position.y)
    for _, req in ipairs(node.requirements) do
      local src = Pack.nodeByUid(pack, req.requiredUid)
      if src then
        local sx, sy = self:worldToScreen(src.position.x, src.position.y)
        local dx, dy = nx - sx, ny - sy
        local len = math.sqrt(dx * dx + dy * dy)
        if len > 0.001 then
          local rs = self:nodeRadius(src)
          local rt = self:nodeRadius(node)
          local ux, uy = dx / len, dy / len
          local x1, y1 = sx + ux * rs, sy + uy * rs
          local x2, y2 = nx - ux * rt, ny - uy * rt
          local lt = req.lineType or "NORM"
          local alpha = req.hidden and 0.35 or 1
          if lt == "NONE" then
            setColor(ui.theme.textFaint, 0.5 * alpha)
            love.graphics.setLineWidth(1)
            dashedLine(x1, y1, x2, y2, 3, 5)
          elseif lt == "THICK" then
            setColor(ui.theme.borderLight, alpha)
            love.graphics.setLineWidth(MAX(3, 0.42 * zoom))
            love.graphics.line(x1, y1, x2, y2)
            setColor(ui.theme.textDim, alpha)
            arrowHead(x1, y1, x2, y2, 9)
          elseif lt == "SPECIAL" then
            setColor(ui.theme.warn, alpha)
            love.graphics.setLineWidth(2)
            love.graphics.line(x1, y1, x2, y2)
            arrowHead(x1, y1, x2, y2, 10)
          else
            setColor(ui.theme.borderLight, alpha)
            love.graphics.setLineWidth(2)
            love.graphics.line(x1, y1, x2, y2)
            arrowHead(x1, y1, x2, y2, 8)
          end
          love.graphics.setLineWidth(1)
        end
      end
    end
  end

  -- outgoing effects of the selected node
  if self.showEffects and selection and #selection > 0 then
    for _, uid in ipairs(selection) do
      local node = Pack.nodeByUid(pack, uid)
      if node then
        local nx, ny = self:worldToScreen(node.position.x, node.position.y)
        for _, eff in ipairs(node.effects) do
          local dst = Pack.nodeByUid(pack, eff.targetUid)
          if dst then
            local tx, ty = self:worldToScreen(dst.position.x, dst.position.y)
            setColor({ 0.72, 0.45, 0.95 }, 0.85)
            love.graphics.setLineWidth(2)
            dashedLine(nx, ny, tx, ty, 6, 5)
            love.graphics.setLineWidth(1)
          end
        end
      end
    end
  end
end

function Graph:drawNode(pack, node, selected, hovered, isStart)
  local sx, sy = self:worldToScreen(node.position.x, node.position.y)
  local r = self:nodeRadius(node)
  local col = Graph.TYPE_COLORS[node.type] or ui.theme.textDim
  local shape = Graph.shapeFor(node.type)

  if selected then
    setColor(ui.theme.select, 0.16)
    Graph.traceShape("fill", shape, sx, sy, r + 9)
  end

  local img = self:icon(pack, node.uid)

  -- icon clipped to the node shape
  love.graphics.stencil(function() Graph.traceShape("fill", shape, sx, sy, r) end, "replace", 1)
  love.graphics.setStencilTest("greater", 0)
  setColor(col, 0.28)
  Graph.traceShape("fill", shape, sx, sy, r)
  if img then
    local iw, ih = img:getDimensions()
    local scale = (r * 2) / MAX(iw, ih)
    love.graphics.setColor(1, 1, 1, selected and 1 or 0.92)
    love.graphics.draw(img, sx - iw * scale / 2, sy - ih * scale / 2, 0, scale, scale)
  end
  love.graphics.setStencilTest()
  love.graphics.setColor(1, 1, 1, 1)

  if not img then
    ui.setFont(r > 30 and "title" or "small")
    setColor(col, 0.95)
    local letter = Graph.TYPE_LETTER[node.type] or "?"
    local f = love.graphics.getFont()
    love.graphics.printf(letter, sx - r, sy - f:getHeight() / 2, r * 2, "center")
  end

  -- ring, following the node's shape
  setColor(col, 1)
  love.graphics.setLineWidth(selected and 3 or 2)
  love.graphics.setLineJoin("bevel")
  Graph.traceShape("line", shape, sx, sy, r)
  love.graphics.setLineJoin("miter")
  love.graphics.setLineWidth(1)

  -- start node badge
  if isStart then
    setColor(ui.theme.warn, 1)
    love.graphics.setLineWidth(2)
    love.graphics.setLineJoin("bevel")
    Graph.traceShape("line", shape, sx, sy, r + 4)
    love.graphics.setLineJoin("miter")
    love.graphics.setLineWidth(1)
    local bx, by = sx + r * 0.72, sy - r * 0.72
    love.graphics.circle("fill", bx, by, MAX(6, r * 0.22))
    ui.setFont("tiny")
    setColor({ 0.05, 0.05, 0.06 }, 1)
    local f = love.graphics.getFont()
    love.graphics.printf("S", bx - 8, by - f:getHeight() / 2, 16, "center")
  end

  if hovered then
    setColor(ui.theme.select, 0.5)
    love.graphics.setLineWidth(1)
    love.graphics.setLineJoin("bevel")
    Graph.traceShape("line", shape, sx, sy, r + 7)
    love.graphics.setLineJoin("miter")
  end

  -- label
  if self.showLabels and r > 11 then
    local fontName = r > 34 and "body" or (r > 19 and "small" or "tiny")
    local font = uiFont(fontName)
    local text = node.title ~= "" and node.title or node.uid
    local tw = font:getWidth(text)
    local ly = sy + r + 4
    local maxW = MIN(self.vw - 8, tw + 14)
    ui.pushClip(self.vx, self.vy, self.vw, self.vh)
    setColor({ 0.04, 0.05, 0.07 }, 0.72)
    love.graphics.rectangle("fill", FLOOR(sx - maxW / 2), FLOOR(ly), FLOOR(maxW), font:getHeight() + 4)
    setColor(selected and ui.theme.select or ui.theme.text, 0.96)
    love.graphics.setFont(font)
    love.graphics.printf(text, FLOOR(sx - maxW / 2) + 7, FLOOR(ly) + 2, FLOOR(maxW - 14), "center")
    ui.popClip()
  end
  love.graphics.setColor(1, 1, 1, 1)
end

function Graph:drawLegend()
  local u = ui.scale
  -- The legend sits bottom-left and the zoom controls bottom-right: hide the
  -- legend when the canvas is too narrow for both so they can never overlap.
  if self.vw < uiModule.s(460) then return end
  local x, y = self.vx + 12 * u, self.vy + self.vh - 78 * u
  ui.rect("fill", x - 6 * u, y - 6 * u, 200 * u, 74 * u, { 0.05, 0.06, 0.08 }, 0.72)
  ui.rect("line", x - 6 * u, y - 6 * u, 200 * u, 74 * u, ui.theme.border)
  ui.setFont("tiny")
  -- shape -> type legend
  local items = {
    { "Generator 产出 · 圆形", ui.theme.generator, "circle" },
    { "Research 研究 · 六边形", ui.theme.research, "hexagon" },
    { "Trophy 奖杯 · 星形", ui.theme.trophy, "star" },
  }
  for i, it in ipairs(items) do
    setColor(it[2])
    Graph.traceShape("fill", it[3], x + 6 * u, y + (4 + (i - 1) * 16) * u, 5 * u)
    setColor(ui.theme.textDim)
    ui.text(x + 18 * u, y + (-3 + (i - 1) * 16) * u, it[1], { font = "tiny", color = ui.theme.textDim })
  end
  setColor(ui.theme.borderLight)
  love.graphics.setLineWidth(MAX(1, 2 * u))
  love.graphics.line(x, y + 52 * u, x + 22 * u, y + 52 * u)
  love.graphics.setLineWidth(1)
  ui.text(x + 30 * u, y + 46 * u, "NORM", { font = "tiny", color = ui.theme.textDim })
  setColor(ui.theme.warn)
  love.graphics.setLineWidth(MAX(1, 2 * u))
  love.graphics.line(x + 80 * u, y + 52 * u, x + 100 * u, y + 52 * u)
  love.graphics.setLineWidth(1)
  ui.text(x + 106 * u, y + 46 * u, "SPECIAL", { font = "tiny", color = ui.theme.textDim })
  local hint = "中键/右键/空格+拖动 或 WASD 平移 · N 新建节点 · Ctrl+F 适应"
  if self.spaceDown or self:isPanning() then hint = "平移中…" end
  ui.text(x, y + 62 * u, hint, { font = "tiny", color = ui.theme.textFaint })
end

--------------------------------------------------------------------------------
-- Background images (drawn behind the grid, edges and nodes)
--------------------------------------------------------------------------------

--- Cached image for one background entry; missing files are remembered.
function Graph:backgroundImage(pack)
  local file = Pack.getBackground(pack)
  if not file then
    return { ok = false, image = nil, w = 0, h = 0 }
  end
  local key = tostring(pack and pack.dir or "") .. "|" .. tostring(file)
  local e = self.bgImages[key]
  if e == nil then
    e = { ok = false, image = nil, w = 200, h = 120 }
    local path = Pack.join(pack.dir, file)
    if Pack.exists(path) then
      local img = Pack.loadImage(file)
      if img then
        img:setFilter("linear", "linear")
        e = { ok = true, image = img, w = img:getWidth(), h = img:getHeight() }
      end
    end
    self.bgImages[key] = e
  end
  return e
end

function Graph:resetBackgroundCache()
  self.bgImages = {}
end

--- Draw the pack's background across the whole viewport.
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

function Graph:draw(app)
  local pack = app.pack
  ui.scale = uiModule.scale
  ui.rect("fill", self.vx, self.vy, self.vw, self.vh, ui.theme.canvas)
  ui.pushClip(self.vx, self.vy, self.vw, self.vh)

  if pack then self:drawBackground(pack) end
  if self.showGrid then self:drawGrid() end
  if pack then
    self:drawBounds(pack)
    self:drawEdges(pack, app.selection)
    local r = self:radius()
    for _, node in ipairs(pack.tree.nodes) do
      local selected = app.selectionSet[node.uid] or false
      local hovered = self.hoverUid == node.uid
      self:drawNode(pack, node, selected, hovered, pack.tree.startNode == node.uid)
    end
  else
    ui.text(self.vx + self.vw / 2 - 200, self.vy + self.vh / 2 - 20,
      "没有打开任何活动包", { align = "center", w = 400, font = "title", color = ui.theme.textDim })
    ui.text(self.vx + self.vw / 2 - 260, self.vy + self.vh / 2 + 12,
      "Ctrl+O 打开一个包目录，或 Ctrl+N 新建一个包", { align = "center", w = 520, font = "small", color = ui.theme.textFaint })
  end

  -- rubber band
  if self.drag and self.drag.mode == "band" then
    local x0 = MIN(self.drag.sx, self.drag.x)
    local y0 = MIN(self.drag.sy, self.drag.y)
    local w = ABS(self.drag.x - self.drag.sx)
    local h = ABS(self.drag.y - self.drag.sy)
    ui.rect("fill", x0, y0, w, h, ui.theme.accent, 0.14)
    ui.rect("line", x0, y0, w, h, ui.theme.accent, 0.8)
  end

  self:drawLegend()
  ui.rect("line", self.vx, self.vy, self.vw, self.vh, ui.theme.border)
  ui.popClip()
end

-- -------------------------------------------------------------- input -----

local function snapValue(v, fine)
  if fine then
    return FLOOR(v * 10 + 0.5) / 10
  end
  return FLOOR(v + 0.5)
end

function Graph:mousepressed(app, mx, my, button)
  local pack = app.pack
  if button == 2 or button == 3 or (button == 1 and self.spaceDown) then
    self.drag = { mode = "pan", sx = mx, sy = my, camx = self.camx, camy = self.camy }
    return true
  end
  if button ~= 1 then return false end

  local node = pack and self:hitTest(pack, mx, my) or nil
  if node then
    local shift = love.keyboard.isDown("lshift", "rshift")
    if shift then
      app:toggleSelection(node.uid)
    elseif not app.selectionSet[node.uid] then
      app:setSelection({ node.uid })
    end
    local starts = {}
    for _, uid in ipairs(app.selection) do
      local n = Pack.nodeByUid(pack, uid)
      if n then starts[uid] = { x = n.position.x, y = n.position.y } end
    end
    self.drag = {
      mode = "node",
      sx = mx, sy = my,
      starts = starts,
      primary = node.uid,
      moved = false,
    }
    return true
  end

  local shift = love.keyboard.isDown("lshift", "rshift")
  if not shift then app:setSelection({}) end
  self.drag = { mode = "band", sx = mx, sy = my, x = mx, y = my }
  return true
end

function Graph:mousemoved(app, mx, my, dx, dy)
  local pack = app.pack
  if not self.drag then
    local node = pack and self:hitTest(pack, mx, my) or nil
    self.hoverUid = node and node.uid or nil
    return false
  end

  if self.drag.mode == "pan" then
    -- dx/dy are PHYSICAL pixels (as love.mousemoved reports them) and zoom is
    -- physical pixels per world unit, so the pan is independent of ui.scale.
    -- The camera is clamped to a generous box so a runaway drag can never lose
    -- the tree; Ctrl+F / the fit button always recovers regardless.
    local limit = 1e5
    self.camx = MAX(-limit, MIN(limit, self.drag.camx - dx / self.zoom))
    self.camy = MAX(-limit, MIN(limit, self.drag.camy + dy / self.zoom))
    return true
  elseif self.drag.mode == "node" then
    local fine = love.keyboard.isDown("lshift", "rshift")
    local wx, wy = self:screenToWorld(mx, my)
    local sx, sy = self:screenToWorld(self.drag.sx, self.drag.sy)
    local ddx, ddy = wx - sx, wy - sy
    local primaryStart = self.drag.starts[self.drag.primary]
    if not primaryStart then return true end
    local px = snapValue(primaryStart.x + ddx, fine)
    local py = snapValue(primaryStart.y + ddy, fine)
    local adx, ady = px - primaryStart.x, py - primaryStart.y
    if adx ~= 0 or ady ~= 0 then self.drag.moved = true end
    for uid, start in pairs(self.drag.starts) do
      local n = Pack.nodeByUid(pack, uid)
      if n then
        if uid == self.drag.primary then
          n.position.x, n.position.y = px, py
        else
          n.position.x = snapValue(start.x + adx, fine)
          n.position.y = snapValue(start.y + ady, fine)
        end
      end
    end
    if self.drag.moved then
      app.dirty = true
      app:setStatus(string.format("移动节点到 x=%.4g y=%.4g%s", px, py, fine and "（精细 0.1）" or ""))
    end
    return true
  elseif self.drag.mode == "band" then
    self.drag.x, self.drag.y = mx, my
    return true
  end
  return false
end

function Graph:mousereleased(app, mx, my, button)
  if not self.drag then return false end
  local drag = self.drag
  self.drag = nil
  if drag.mode == "band" and app.pack then
    local x0, y0 = MIN(drag.sx, drag.x), MIN(drag.sy, drag.y)
    local x1, y1 = MAX(drag.sx, drag.x), MAX(drag.sy, drag.y)
    if (x1 - x0) > 3 or (y1 - y0) > 3 then
      local picked = {}
      for _, n in ipairs(app.pack.tree.nodes) do
        local sx, sy = self:worldToScreen(n.position.x, n.position.y)
        if sx >= x0 and sx <= x1 and sy >= y0 and sy <= y1 then
          picked[#picked + 1] = n.uid
        end
      end
      local shift = love.keyboard.isDown("lshift", "rshift")
      if shift then
        for _, uid in ipairs(picked) do app:toggleSelection(uid) end
      else
        app:setSelection(picked)
      end
      app:setStatus("框选了 " .. #picked .. " 个节点")
    end
  elseif drag.mode == "node" then
    if not drag.moved then
      -- treated as a plain click, selection already happened on press
    end
  end
  return true
end

return Graph
