-- src/ui.lua
-- A small immediate mode widget toolkit built directly on LÖVE 11.5 drawing.
--
-- COORDINATE MODEL
--   Every ui.* function takes **logical** units. ui.scale (0.75 - 2.0) converts
--   them to physical pixels through ui.s(), and fonts are re-rasterised at the
--   scaled pixel size by Fonts.get(). Mouse and wheel events are converted to
--   logical units on the way in, so hit testing always compares like with like.
--   Raw love.graphics code (the graph canvas) works in physical pixels and must
--   convert with ui.s()/ui.toLogical() at the boundary.
--
-- Life cycle inside one frame:
--   love.mousepressed / keypressed / textinput / wheelmoved / mousemoved
--      -> queue events (already converted to logical units)
--   love.draw:
--      ui.beginFrame()            (reads the mouse, resets per frame state)
--      ... build widgets ...      (they consume queued events in draw order)
--      ui.endFrame()              (deferred popups, tooltips, clears queues)
--
-- Pointer priority is draw order: the first widget that claims an event wins.
-- Modals block everything outside their rect, dropdown popups block the widgets
-- drawn after them. The mouse wheel is routed to the innermost scroll region
-- under the cursor, and bubbles outwards when that region cannot scroll further.

local Fonts = require("src.fonts")

local ui = {}

local CHAR = string.char
local BYTE = string.byte
local SUB = string.sub
local FLOOR = math.floor
local MIN, MAX, ABS = math.min, math.max, math.abs

ui.scale = 1

ui.theme = {
  bg          = { 0.075, 0.082, 0.098 },
  canvas      = { 0.098, 0.108, 0.130 },
  panel       = { 0.128, 0.140, 0.168 },
  panelAlt    = { 0.160, 0.174, 0.208 },
  panelDeep   = { 0.098, 0.108, 0.132 },
  border      = { 0.235, 0.255, 0.310 },
  borderLight = { 0.330, 0.360, 0.430 },
  text        = { 0.905, 0.920, 0.950 },
  textDim     = { 0.590, 0.620, 0.680 },
  textFaint   = { 0.400, 0.430, 0.490 },
  accent      = { 0.290, 0.620, 0.960 },
  accentSoft  = { 0.200, 0.360, 0.560 },
  danger      = { 0.920, 0.360, 0.360 },
  dangerSoft  = { 0.480, 0.200, 0.200 },
  warn        = { 0.960, 0.730, 0.300 },
  ok          = { 0.330, 0.800, 0.520 },
  generator   = { 0.290, 0.760, 0.620 },
  research    = { 0.360, 0.620, 0.960 },
  trophy      = { 0.960, 0.760, 0.320 },
  select      = { 1.000, 1.000, 1.000 },
}

ui.ROW = 26
ui.PAD = 8
ui.LABEL_W = 96

-- ---------------------------------------------------------------- scale ----

--- Scale a logical length to physical pixels.
function ui.s(v)
  return FLOOR((v or 0) * ui.scale + 0.5)
end

--- Physical pixels -> logical units.
function ui.toLogical(x, y)
  return x / ui.scale, y / ui.scale
end

--- Logical size of the window.
function ui.dims()
  local w, h = love.graphics.getDimensions()
  return w / ui.scale, h / ui.scale
end

function ui.setScale(scale)
  ui.scale = scale
  ui.ROW = ui.s(26)
  ui.PAD = ui.s(8)
  ui.LABEL_W = ui.s(96)
end

--- Content coordinates -> screen (logical) coordinates. THE single place the
--- scroll offset is applied outside of the graphics transform.
function ui.toScreen(x, y)
  return x - ui.scrollOffsetX, y - ui.scrollOffset
end

--- THE conversion from LÖVE's physical pixel coordinates (love.mouse.getPosition,
--- love.mousemoved) into the logical space that scroll region rects live in.
--- Hover, wheel routing, canvas zoom and the UI-scale anchor all read the
--- pointer through this one function.
function ui.setPointer(physicalX, physicalY)
  ui.mx, ui.my = ui.toLogical(physicalX, physicalY)
  return ui.mx, ui.my
end

--- Pointer position in region space (logical units).
function ui.pointer()
  return ui.mx, ui.my
end

-- ---------------------------------------------------------------- state ----

ui.mx, ui.my = 0, 0
ui.dx, ui.dy = 0, 0
ui.events = {}
ui.keys = {}
ui.texts = {}
ui.wheel = 0
ui.wheelH = 0
ui.wheelX, ui.wheelY = 0, 0
ui.wheelCtrl = false
ui.wheelShift = false
ui.modifierOverride = nil   -- tests can force the modifier state
ui.spaceConsumed = false    -- set while space arms the canvas pan modifier
ui.wheelConsumed = false
ui.wheelTarget = nil
ui.wheelTargetComputed = false
ui.focus = nil
ui.activeId = nil
ui.hoverId = nil
ui.state = {}
ui.deferred = {}
ui.scrollStack = {}
ui.frameRegions = {}
ui.prevRegions = {}
ui.clipStack = {}
ui.modalRect = nil
ui.inModalPass = false
ui.popupRect = nil
ui.popupOwner = nil
ui.pointerClaimed = false
ui.tooltip = nil
ui.now = 0
-- Total scroll offset (logical) of the scroll regions currently open.
-- Drawing applies it ONCE through love.graphics.translate; every hit test and
-- every clip goes through ui.toScreen(), so there is exactly one place per
-- direction where the offset is applied.
ui.scrollOffset = 0
ui.scrollOffsetX = 0

-- widget audit (only when ui.debugAudit is on): records where each widget is
-- actually drawn versus where hit testing thinks it is
ui.debugAudit = false
ui.debugWidgets = {}

-- When on, every string drawn through ui.text is recorded so tests can assert
-- on what the UI really rendered (not on internal data).
ui.debugLabels = false
ui.renderedText = {}

function ui.stateFor(id)
  local st = ui.state[id]
  if not st then
    st = {}
    ui.state[id] = st
  end
  return st
end

function ui.resetState()
  ui.state = {}
  ui.focus = nil
  ui.activeId = nil
end

-- ------------------------------------------------------------- events -----

function ui.mousepressed(x, y, button)
  local lx, ly = ui.toLogical(x, y)
  ui.events[#ui.events + 1] = { kind = "press", x = lx, y = ly, button = button }
end

function ui.mousereleased(x, y, button)
  local lx, ly = ui.toLogical(x, y)
  ui.events[#ui.events + 1] = { kind = "release", x = lx, y = ly, button = button }
end

function ui.mousemoved(x, y, dx, dy)
  ui.setPointer(x, y)
  ui.dx = ui.dx + (dx or 0) / ui.scale
  ui.dy = ui.dy + (dy or 0) / ui.scale
end

function ui.keypressed(key)
  ui.keys[#ui.keys + 1] = { key = key, claimed = false }
end

function ui.textinput(text)
  ui.texts[#ui.texts + 1] = { text = text, claimed = false }
end

--- Modifier state for the wheel. Read from the keyboard (NOT from the wheel
--- event) so it works no matter what the platform reports for the event itself.
function ui.wheelModifiers()
  if ui.modifierOverride then
    return ui.modifierOverride.ctrl and true or false, ui.modifierOverride.shift and true or false
  end
  local ctrl = love.keyboard.isDown("lctrl", "rctrl", "lgui", "rgui")
  local shift = love.keyboard.isDown("lshift", "rshift")
  return ctrl, shift
end

--- A wheel notch. LÖVE hands the callback the wheel MOVEMENT, never a cursor
--- position, so the position is always taken from the shared pointer
--- (ui.pointer(), in region space) - passing coordinates in here is impossible.
function ui.wheelmoved(dx, dy)
  ui.wheel = ui.wheel + (dy or 0)
  ui.wheelH = ui.wheelH + (dx or 0)
  ui.wheelX, ui.wheelY = ui.pointer()
  ui.wheelCtrl, ui.wheelShift = ui.wheelModifiers()
end

local function rectContains(x, y, w, h, px, py)
  return px >= x and px < x + w and py >= y and py < y + h
end
ui.rectContains = rectContains

--- Is a point blocked by a modal or by an open dropdown popup?
function ui.pointBlocked(px, py, ownerId)
  if ui.modalRect and not ui.inModalPass then
    if not rectContains(ui.modalRect.x, ui.modalRect.y, ui.modalRect.w, ui.modalRect.h, px, py) then
      return true
    end
  end
  if ui.popupRect and ownerId ~= ui.popupOwner then
    if rectContains(ui.popupRect.x, ui.popupRect.y, ui.popupRect.w, ui.popupRect.h, px, py) then
      return true
    end
  end
  return false
end

--- True when an overlay (modal / popup) covers the point. Used by the canvas.
function ui.blocksPoint(px, py)
  if ui.modalRect and rectContains(ui.modalRect.x, ui.modalRect.y, ui.modalRect.w, ui.modalRect.h, px, py) then
    return true
  end
  if ui.popupRect and rectContains(ui.popupRect.x, ui.popupRect.y, ui.popupRect.w, ui.popupRect.h, px, py) then
    return true
  end
  return false
end

--- Consume the first unclaimed event of a kind inside the rect.
local function claimEvent(kind, x, y, w, h, ownerId)
  local sx, sy = ui.toScreen(x, y)
  if ui.pointBlocked(sx, sy, ownerId) then return nil end
  for _, ev in ipairs(ui.events) do
    if not ev.claimed and ev.kind == kind and ev.button == 1
      and rectContains(sx, sy, w, h, ev.x, ev.y) then
      ev.claimed = true
      return ev
    end
  end
  return nil
end

local function pressTaken(x, y)
  for _, ev in ipairs(ui.events) do
    if ev.kind == "press" and ev.claimed and rectContains(x, y, 1, 1, ev.x, ev.y) then return true end
  end
  return false
end

function ui.hover(x, y, w, h, ownerId)
  if ui.pointBlocked(ui.mx, ui.my, ownerId) then return false end
  local sx, sy = ui.toScreen(x, y)
  return rectContains(sx, sy, w, h, ui.mx, ui.my)
end

--- Standard clickable behaviour. Returns hovered, held, clicked.
function ui.clickable(id, x, y, w, h)
  ui.auditWidget(id, x, y, w, h)
  local sx, sy = ui.toScreen(x, y)
  ui.stateFor(id).rect = { x = sx, y = sy, w = w, h = h }
  local blocked = ui.pointBlocked(ui.mx, ui.my, id)
  local hovered = (not blocked) and rectContains(sx, sy, w, h, ui.mx, ui.my) or false

  local press = claimEvent("press", x, y, w, h, id)
  if press then
    ui.activeId = id
    if not ui.focus or ui.focus ~= id then ui.focus = nil end
  end

  local release = claimEvent("release", x, y, w, h, id)
  local clicked = false
  if release and ui.activeId == id then
    clicked = true
  end
  for _, ev in ipairs(ui.events) do
    if ev.kind == "release" and ev.claimed and ui.activeId == id
      and not rectContains(sx, sy, w, h, ev.x, ev.y) then
      ui.activeId = nil
    end
  end

  local held = (ui.activeId == id)
  if hovered then ui.hoverId = id end
  return hovered, held, clicked
end

function ui.pressIn(id, x, y, w, h)
  ui.auditWidget(id, x, y, w, h)
  local rx, ry = ui.toScreen(x, y)
  ui.stateFor(id).rect = { x = rx, y = ry, w = w, h = h }
  if ui.pointBlocked(ui.mx, ui.my, id) then return false end
  if pressTaken(ui.mx, ui.my) then return false end
  x, y = rx, ry
  local ev = claimEvent("press", x, y, w, h, id)
  if ev then return true end
  return false
end

--- Record where a widget is DRAWN (through the live graphics transform) and
--- where hit testing thinks it is (ui.toScreen + ui.s). Any divergence shows up
--- as a non zero dx/dy in ui.debugWidgets; the smoke test asserts it stays 0.
function ui.auditWidget(id, x, y, w, h)
  if not ui.debugAudit then return end
  local sx, sy = ui.toScreen(x, y)
  local ok, drawnX, drawnY = pcall(love.graphics.transformPoint, ui.s(x), ui.s(y))
  ui.auditTransformOk = ok and true or false
  if not ok then drawnX, drawnY = ui.s(sx), ui.s(sy) end
  local sc = { love.graphics.getScissor() }
  local region = ui.scrollStack[#ui.scrollStack]
  ui.debugWidgets[#ui.debugWidgets + 1] = {
    id = id, x = x, y = y, w = w, h = h,
    hitX = ui.s(sx), hitY = ui.s(sy),
    drawX = drawnX, drawY = drawnY,
    dx = drawnX - ui.s(sx), dy = drawnY - ui.s(sy),
    clipped = sc[1] ~= nil,
    scissor = sc[1] and { sc[1], sc[2], sc[3], sc[4] } or nil,
    region = region and region.id or nil,
    depth = #ui.scrollStack,
    scroll = ui.scrollOffset, scrollX = ui.scrollOffsetX,
  }
end

--- Click test for hand drawn rows inside a possibly scrolled panel.
--- Claims the press so the row wins over anything drawn later.
function ui.clickedRow(x, y, w, h)
  local sx, sy = ui.toScreen(x, y)
  for _, ev in ipairs(ui.events) do
    if ev.kind == "press" and ev.button == 1 and not ev.claimed
      and rectContains(sx, sy, w, h, ev.x, ev.y) then
      ev.claimed = true
      return true
    end
  end
  return false
end

function ui.releasedAnywhere()
  for _, ev in ipairs(ui.events) do
    if ev.kind == "release" then return true end
  end
  return false
end

-- -------------------------------------------------------------- fonts -----

--- Fonts are rasterised at size * ui.scale (a real atlas rebuild, not a
--- stretched bitmap) and cached per pixel size by src/fonts.lua.
function ui.font(size)
  if type(size) == "string" then
    return Fonts.get(Fonts.SIZES[size] * ui.scale)
  end
  return Fonts.get((size or Fonts.SIZES.body) * ui.scale)
end

function ui.setFont(size)
  love.graphics.setFont(ui.font(size))
end

-- -------------------------------------------------------------- clip ------

function ui.pushClip(x, y, w, h)
  local prev = { love.graphics.getScissor() }
  ui.clipStack[#ui.clipStack + 1] = prev
  local sx, sy = ui.toScreen(x, y)
  love.graphics.intersectScissor(ui.s(sx), ui.s(sy), MAX(1, ui.s(w)), MAX(1, ui.s(h)))
end

function ui.popClip()
  local prev = table.remove(ui.clipStack)
  if not prev or not prev[1] then
    love.graphics.setScissor()
  else
    love.graphics.setScissor(prev[1], prev[2], prev[3], prev[4])
  end
end

-- ------------------------------------------------------------ drawing -----

local function setColor(c, a)
  if a then
    love.graphics.setColor(c[1], c[2], c[3], a)
  else
    love.graphics.setColor(c[1], c[2], c[3], 1)
  end
end
ui.setColor = setColor

function ui.rect(mode, x, y, w, h, color, alpha)
  setColor(color, alpha)
  love.graphics.rectangle(mode, ui.s(x) + 0.5, ui.s(y) + 0.5, MAX(1, ui.s(w)), MAX(1, ui.s(h)))
end

function ui.frame(x, y, w, h, fill, border, title)
  if fill then ui.rect("fill", x, y, w, h, fill) end
  if border then ui.rect("line", x, y, w, h, border) end
  if title then
    ui.text(x + 8, y + 5, title, { font = "small", color = ui.theme.textDim })
  end
end

function ui.panel(x, y, w, h, title)
  ui.rect("fill", x, y, w, h, ui.theme.panel)
  ui.rect("line", x, y, w, h, ui.theme.border)
  local top = y
  if title then
    ui.rect("fill", x + 1, y + 1, w - 1, 24, ui.theme.panelAlt)
    ui.text(x + 9, y + 6, title, { font = "small", color = ui.theme.textDim })
    top = y + 25
  end
  return x + 1, top + 1, w - 2, (y + h) - top - 2
end

function ui.text(x, y, str, opt)
  opt = opt or {}
  if ui.debugLabels and type(str) == "string" then
    ui.renderedText[#ui.renderedText + 1] = str
  end
  local font = ui.font(opt.font or "body")
  love.graphics.setFont(font)
  setColor(opt.color or ui.theme.text, opt.alpha)
  local px, py = ui.s(x), ui.s(y)
  if opt.w then
    local pw = ui.s(opt.w)
    if opt.align == "center" then
      love.graphics.printf(str, px, py, pw, "center")
    elseif opt.align == "right" then
      love.graphics.printf(str, px, py, pw, "right")
    else
      love.graphics.printf(str, px, py, pw, "left")
    end
  else
    love.graphics.print(str, px, py)
  end
end

--- Width of a string in LOGICAL units.
function ui.textW(str, font)
  return ui.font(font or "body"):getWidth(str) / ui.scale
end

--- Naive but UTF-8 safe word wrap (breaks on spaces, then on characters).
--- width is in logical units.
function ui.wrap(str, width, fontName)
  local font = ui.font(fontName or "body")
  local limit = ui.s(width)
  local lines = {}
  for _, paragraph in ipairs(ui.splitLines(str)) do
    if paragraph == "" then
      lines[#lines + 1] = ""
    else
      local current = ""
      for rawChunk in paragraph:gmatch("[^ ]+") do
        local chunk = rawChunk
        local candidate = current == "" and chunk or (current .. " " .. chunk)
        if font:getWidth(candidate) <= limit then
          current = candidate
        else
          if current ~= "" then lines[#lines + 1] = current end
          while font:getWidth(chunk) > limit do
            local cut = 1
            while cut < #chunk and font:getWidth(chunk:sub(1, cut + 1)) <= limit do cut = cut + 1 end
            lines[#lines + 1] = chunk:sub(1, cut)
            chunk = chunk:sub(cut + 1)
          end
          current = chunk
        end
      end
      lines[#lines + 1] = current
    end
  end
  return lines
end

function ui.splitLines(str)
  local NL = CHAR(10)
  local lines = {}
  local pos = 1
  while true do
    local s, e = str:find(NL, pos, true)
    if not s then
      lines[#lines + 1] = str:sub(pos)
      break
    end
    lines[#lines + 1] = str:sub(pos, s - 1)
    pos = e + 1
  end
  return lines
end

-- ------------------------------------------------------------ widgets -----

function ui.label(x, y, str, opt)
  opt = opt or {}
  ui.text(x, y, str, opt)
  return ui.textW(str, opt.font)
end

function ui.button(id, x, y, w, h, label, opt)
  opt = opt or {}
  local hovered, held, clicked = ui.clickable(id, x, y, w, h)
  local bg = opt.bg or ui.theme.panelAlt
  local border = ui.theme.border
  if opt.accent then
    bg = hovered and { 0.34, 0.66, 1.0 } or ui.theme.accent
  end
  if opt.danger then
    bg = hovered and { 0.72, 0.28, 0.28 } or ui.theme.dangerSoft
    border = ui.theme.danger
  end
  if held then bg = { bg[1] * 0.8, bg[2] * 0.8, bg[3] * 0.8 } end
  local edge = opt.accent and ui.theme.accent or border
  if opt.disabled then
    bg = ui.theme.panelDeep
    edge = ui.theme.border
  end
  ui.rect("fill", x, y, w, h, bg)
  ui.rect("line", x, y, w, h, edge)
  local fg = opt.fg or ui.theme.text
  if opt.accent then fg = { 0.05, 0.07, 0.10 } end
  if opt.disabled then fg = ui.theme.textFaint end
  local font = ui.font(opt.font or "small")
  ui.text(x, y + (ui.s(h) - font:getHeight()) / 2 / ui.scale - 1, label,
    { align = "center", w = w, font = opt.font or "small", color = fg })
  if opt.tip and hovered then ui.tooltip = opt.tip end
  if opt.disabled then return false end
  return clicked
end

function ui.checkbox(id, x, y, label, value)
  local size = 16
  local w = size + 6 + ui.textW(label, "small")
  local hovered, held, clicked = ui.clickable(id, x, y, w, 20)
  ui.rect("fill", x, y + 1, size, size, hovered and ui.theme.panelAlt or ui.theme.panelDeep)
  ui.rect("line", x, y + 1, size, size, ui.theme.border)
  if value then
    setColor(ui.theme.accent)
    love.graphics.rectangle("fill", ui.s(x + 4), ui.s(y + 5), ui.s(size - 8), ui.s(size - 8))
  end
  ui.text(x + size + 6, y + 2, label, { font = "small", color = ui.theme.text })
  if clicked then return not value end
  return value
end

-- ------------------------------------------------------------ editing -----

local function prevCharIndex(s, i)
  if i <= 1 then return 1 end
  local j = i - 1
  while j > 1 do
    local b = BYTE(s, j)
    if b >= 0x80 and b < 0xC0 then j = j - 1 else break end
  end
  return j
end

local function nextCharIndex(s, i)
  local n = #s
  if i > n then return n + 1 end
  local j = i + 1
  while j <= n do
    local b = BYTE(s, j)
    if b >= 0x80 and b < 0xC0 then j = j + 1 else break end
  end
  return j
end
ui.prevCharIndex = prevCharIndex
ui.nextCharIndex = nextCharIndex

--- Ctrl held? (respects the test override used by the wheel/pan tests)
function ui.ctrlHeld()
  if ui.modifierOverride then return ui.modifierOverride.ctrl and true or false end
  return love.keyboard.isDown("lctrl", "rctrl")
end

--- Start of the word before the caret (Ctrl+Backspace / Ctrl+Delete).
--- Words are separated by spaces and common punctuation; CJK runs count as one
--- word until a separator.
local function prevWordIndex(s, i)
  local j = prevCharIndex(s, i)
  local function isSep(c) return c == "" or c:find("[%s%p]") ~= nil end
  while j > 1 and isSep(SUB(s, j, j)) do j = prevCharIndex(s, j) end
  while j > 1 do
    local p = prevCharIndex(s, j)
    if isSep(SUB(s, p, p)) then break end
    j = p
  end
  return j
end

local function nextWordIndex(s, i)
  local n = #s
  local j = i
  local function isSep(c) return c == "" or c:find("[%s%p]") ~= nil end
  while j <= n and isSep(SUB(s, j, j)) do j = nextCharIndex(s, j) end
  while j <= n and not isSep(SUB(s, j, j)) do j = nextCharIndex(s, j) end
  return j
end
ui.prevWordIndex = prevWordIndex
ui.nextWordIndex = nextWordIndex

local function lineBounds(s, caret)
  local NL = CHAR(10)
  local startPos = 1
  local lineNo = 1
  while true do
    local s1, e1 = s:find(NL, startPos, true)
    if not s1 or caret <= s1 then
      local lineEnd = s1 and (s1 - 1) or #s
      return startPos, lineEnd, lineNo
    end
    startPos = e1 + 1
    lineNo = lineNo + 1
  end
end

function ui.fmtNum(v)
  if type(v) ~= "number" then return tostring(v or 0) end
  if v ~= v then return "0" end
  if v == FLOOR(v) and ABS(v) < 1e15 then return string.format("%d", v) end
  local s = string.format("%.6f", v)
  s = s:gsub("0+$", ""):gsub("%.$", "")
  return s
end

--- Text field. Returns value, changed, committed (enter/blur).
function ui.textField(id, x, y, w, h, value, opt)
  opt = opt or {}
  value = value or ""
  local st = ui.stateFor(id)
  local font = ui.font(opt.font or "small")
  local hovered = ui.hover(x, y, w, h, id)
  local changed, committed = false, false

  if ui.pressIn(id, x, y, w, h) then
    ui.focus = id
    st.caret = #value + 1
    st.scrollx = 0
    st.selectAll = true
  end

  if ui.focus == id then
    if st.caret == nil then st.caret = #value + 1 end
    if st.caret > #value + 1 then st.caret = #value + 1 end
    local caret = st.caret

    for _, ev in ipairs(ui.keys) do
      if not ev.claimed then
        local k = ev.key
        local handled = true
        if k == "backspace" then
          if caret > 1 then
            -- Ctrl+Backspace deletes the whole word before the caret
            local p = ui.ctrlHeld() and prevWordIndex(value, caret) or prevCharIndex(value, caret)
            value = value:sub(1, p - 1) .. value:sub(caret)
            caret = p
            changed = true
          end
        elseif k == "delete" then
          if caret <= #value then
            local n = ui.ctrlHeld() and nextWordIndex(value, caret) or nextCharIndex(value, caret)
            value = value:sub(1, caret - 1) .. value:sub(n)
            changed = true
          end
        elseif k == "left" then
          caret = prevCharIndex(value, caret)
        elseif k == "right" then
          caret = nextCharIndex(value, caret)
        elseif k == "home" then
          caret = lineBounds(value, caret)
        elseif k == "end" then
          local _, e = lineBounds(value, caret)
          caret = e + 1
        elseif k == "up" and opt.multiline then
          local s0, _, no = lineBounds(value, caret)
          if no > 1 then
            local prevStart, prevEnd = lineBounds(value, s0 - 1)
            caret = MIN(prevStart + (caret - s0), prevEnd + 1)
          end
        elseif k == "down" and opt.multiline then
          local s0, e0 = lineBounds(value, caret)
          if e0 < #value then
            local nextStart, nextEnd = lineBounds(value, e0 + 2)
            caret = MIN(nextStart + (caret - s0), nextEnd + 1)
          end
        elseif k == "return" or k == "kpenter" then
          if opt.multiline then
            value = value:sub(1, caret - 1) .. CHAR(10) .. value:sub(caret)
            caret = caret + 1
            changed = true
          else
            committed = true
            ui.focus = nil
          end
        elseif k == "escape" then
          ui.focus = nil
        elseif k == "tab" then
          handled = false
        elseif k == "a" and love.keyboard.isDown("lctrl", "rctrl") then
          st.selectAll = true
        else
          handled = false
        end
        if handled then ev.claimed = true end
      end
    end

    for _, ev in ipairs(ui.texts) do
      if not ev.claimed then
        local text = ev.text:gsub("[%z\1-\31]", "")
        if opt.numeric then
          text = text:gsub("[^%d%.%-eE]", "")
        end
        if text ~= "" then
          local clean = true
          if opt.maxlen and #value + #text > opt.maxlen then clean = false end
          if clean then
            value = value:sub(1, caret - 1) .. text .. value:sub(caret)
            caret = caret + #text
            changed = true
          end
          ev.claimed = true
        end
      end
    end

    st.caret = caret

    -- blur when clicking outside (the click stays unclaimed so the widget
    -- under the cursor still receives it in the same frame)
    for _, ev in ipairs(ui.events) do
      if ev.kind == "press" and not ev.claimed then
        if not rectContains(x, y, w, h, ev.x, ev.y) then
          ui.focus = nil
          committed = true
        end
      end
    end
  end

  local focused = ui.focus == id
  local bg = opt.bg or (focused and ui.theme.panelDeep or (hovered and ui.theme.panelAlt or ui.theme.panelDeep))
  ui.rect("fill", x, y, w, h, bg)
  ui.rect("line", x, y, w, h, focused and ui.theme.accent or ui.theme.border)

  local padX = 5
  local inner = ui.s(w) - ui.s(padX) * 2
  local caretPos = st.caret or (#value + 1)
  local caretX = font:getWidth(value:sub(1, caretPos - 1))
  if focused then
    st.scrollx = st.scrollx or 0
    if caretX - st.scrollx > inner then st.scrollx = caretX - inner end
    if caretX - st.scrollx < 0 then st.scrollx = caretX end
  else
    st.scrollx = 0
  end

  ui.pushClip(x + 2, y + 1, w - 4, h - 2)
  local ty = y + (ui.s(h) - font:getHeight()) / 2 / ui.scale - 1
  if value == "" and opt.placeholder and not focused then
    ui.text(x + padX, ty, opt.placeholder, { font = opt.font or "small", color = ui.theme.textFaint })
  else
    local lh = (font:getHeight() + 2) / ui.scale
    local startY = ty
    if opt.multiline then
      local s0, _, no = lineBounds(value, caretPos)
      local lineTop = (no - 1) * lh
      st.scrolly = st.scrolly or 0
      if focused then
        if lineTop - st.scrolly > h - lh then st.scrolly = lineTop - (h - lh) end
        if lineTop - st.scrolly < 0 then st.scrolly = lineTop end
      end
      startY = ty - st.scrolly
      local lines = ui.splitLines(value)
      for i, line in ipairs(lines) do
        ui.text(x + padX - (st.scrollx or 0) / ui.scale, startY + (i - 1) * lh, line,
          { font = opt.font or "small", color = ui.theme.text })
      end
    else
      ui.text(x + padX - (st.scrollx or 0) / ui.scale, ty, value,
        { font = opt.font or "small", color = ui.theme.text })
    end
    if focused and (ui.now % 1) < 0.55 then
      local _, _, no = lineBounds(value, caretPos)
      local caretLine = opt.multiline and no or 1
      setColor(ui.theme.text)
      love.graphics.rectangle("fill",
        ui.s(x + padX) + FLOOR(caretX - (st.scrollx or 0)) + 0.5,
        ui.s(ty) + FLOOR((caretLine - 1) * (font:getHeight() + 2)
          - (opt.multiline and (st.scrolly or 0) * ui.scale or 0)) + 1,
        MAX(1, ui.s(1)), font:getHeight() - 1)
    end
  end
  ui.popClip()

  if opt.tip and hovered then ui.tooltip = opt.tip end
  return value, changed, committed
end

--- Numeric field with arrow key stepping. Returns value, changed, committed.
function ui.numberField(id, x, y, w, h, value, opt)
  opt = opt or {}
  local st = ui.stateFor(id)
  if ui.focus ~= id then
    st.text = ui.fmtNum(value)
  elseif st.text == nil then
    st.text = ui.fmtNum(value)
  end
  if ui.focus == id then
    local step = opt.step or 1
    for _, ev in ipairs(ui.keys) do
      if not ev.claimed and (ev.key == "up" or ev.key == "down") and not opt.multiline then
        local delta = (ev.key == "up") and step or -step
        if love.keyboard.isDown("lshift", "rshift") then delta = delta * 10 end
        local cur = tonumber(st.text) or value or 0
        local nv = cur + delta
        if opt.int then nv = FLOOR(nv + 0.5) end
        if opt.min and nv < opt.min then nv = opt.min end
        if opt.max and nv > opt.max then nv = opt.max end
        st.text = ui.fmtNum(nv)
        ev.claimed = true
        return nv, true, false
      end
    end
  end

  local text, changed, committed = ui.textField(id, x, y, w, h, st.text or ui.fmtNum(value),
    { numeric = true, font = opt.font or "small", placeholder = opt.placeholder, tip = opt.tip })
  if changed then st.text = text end
  if committed then st.text = nil end
  if changed then
    local n = tonumber(text)
    if n == nil then
      return value, false, false
    end
    if opt.int then n = FLOOR(n + 0.5) end
    if opt.min and n < opt.min then n = opt.min end
    if opt.max and n > opt.max then n = opt.max end
    return n, true, false
  end
  return value, false, committed
end

-- ------------------------------------------------------------ dropdown ----

local function dropdownLabel(item)
  if type(item) == "table" then return tostring(item.label or item.value or "") end
  return tostring(item)
end

local function dropdownValue(item)
  if type(item) == "table" then return item.value ~= nil and item.value or item.label end
  return item
end

function ui.dropdown(id, x, y, w, h, value, items, opt)
  opt = opt or {}
  local st = ui.stateFor(id)
  st.rect = { x = x, y = y, w = w, h = h }
  local hovered, held, clicked = ui.clickable(id, x, y, w, h)
  local current = dropdownLabel(value)
  for _, it in ipairs(items) do
    if dropdownValue(it) == value then current = dropdownLabel(it) end
  end

  if clicked then
    st.open = not st.open
    if st.open then
      ui.popupOwner = id
    elseif ui.popupOwner == id then
      ui.popupOwner = nil
      ui.popupRect = nil
    end
  end

  local isOpen = st.open and ui.popupOwner == id
  ui.rect("fill", x, y, w, h, hovered and ui.theme.panelAlt or ui.theme.panelDeep)
  ui.rect("line", x, y, w, h, isOpen and ui.theme.accent or ui.theme.border)
  ui.pushClip(x + 1, y + 1, w - 22, h - 2)
  ui.text(x + 6, y + (ui.s(h) - ui.font("small"):getHeight()) / 2 / ui.scale - 1, current,
    { font = "small", color = opt.color or ui.theme.text })
  ui.popClip()
  setColor(ui.theme.textDim)
  local ax, ay = ui.s(x + w - 12), ui.s(y + h / 2 - 1)
  love.graphics.polygon("fill", ax - ui.s(4), ay - ui.s(2), ax + ui.s(4), ay - ui.s(2), ax, ay + ui.s(3))

  local maxVisible = opt.maxVisible or 12
  local itemH = opt.itemH or h
  local visible = MIN(#items, maxVisible)
  local popupH = visible * itemH + 2
  local px, py = x, y + h + 1
  local _, logicalH = ui.dims()
  if py + popupH > logicalH - 4 then
    py = MAX(2, y - popupH - 1)
  end
  if isOpen then
    local offX, offY = ui.scrollOffsetX, ui.scrollOffset
    px, py = px - offX, py - offY
    ui.popupRect = { x = px, y = py, w = w, h = popupH }
    ui.defer(function()
      ui.rect("fill", px, py, w, popupH, ui.theme.panelDeep)
      ui.rect("line", px, py, w, popupH, ui.theme.accent)
      local scroll = st.scroll or 0
      if ui.wheelTarget == id and ui.wheel ~= 0 then
        scroll = scroll - ui.wheel * 3
        ui.wheelConsumed = true
      end
      local maxScroll = MAX(0, #items - visible)
      scroll = MAX(0, MIN(maxScroll, scroll))
      st.scroll = scroll
      ui.pushClip(px + 1, py + 1, w - 2, popupH - 2)
      for i = 1, visible do
        local idx = i + scroll
        local it = items[idx]
        if it then
          local iy = py + 1 + (i - 1) * itemH
          local ihover = ui.mx >= px and ui.mx < px + w and ui.my >= iy and ui.my < iy + itemH
          if ihover then ui.rect("fill", px + 1, iy, w - 2, itemH, ui.theme.accentSoft) end
          if opt.swatch then
            local col = opt.swatch(dropdownValue(it))
            if col then
              setColor(col)
              love.graphics.rectangle("fill", ui.s(px + 5), ui.s(iy + itemH / 2 - 5), ui.s(10), ui.s(10))
            end
          end
          ui.text(px + (opt.swatch and 20 or 7),
            iy + (ui.s(itemH) - ui.font("small"):getHeight()) / 2 / ui.scale - 1,
            dropdownLabel(it), { font = "small", color = ui.theme.text })
          -- click to choose: driven purely by the event coordinates
          if ui.events then
            for _, ev in ipairs(ui.events) do
              if ev.kind == "press" and ev.button == 1 and not ev.claimed
                and rectContains(px + 1, iy, w - 2, itemH, ev.x, ev.y) then
                ev.claimed = true
                st.open = false
                ui.popupOwner = nil
                ui.popupRect = nil
                if opt.onSelect then opt.onSelect(dropdownValue(it)) end
                st.picked = dropdownValue(it)
              end
            end
          end
        end
      end
      ui.popClip()
      if #items > visible then
        local barH = (popupH - 2) * visible / #items
        local barY = py + 1 + (popupH - 2 - barH) * (scroll / MAX(1, #items - visible))
        ui.rect("fill", px + w - 4, barY, 3, barH, ui.theme.borderLight)
      end
    end)
  end
  return st.picked
end

-- -------------------------------------------------------------- scroll ----

--- Remember the real content height measured during the previous frame.
function ui.scrollContentHeight(id, measured)
  ui.stateFor(id).measured = measured
end

--- Pick the scroll region that owns the wheel for this frame: the innermost
--- region under the cursor that can still move, bubbling outwards otherwise.
local function computeWheelTarget()
  ui.wheelTargetComputed = true
  ui.wheelTarget = nil
  -- Ctrl/Cmd + wheel belongs to the application (global UI scale), never to a
  -- scroll region
  if ui.wheelCtrl then return end
  if (ui.wheel == 0 and ui.wheelH == 0) or #ui.prevRegions == 0 then return end
  local wx, wy = ui.wheelX, ui.wheelY
  local candidates = {}
  for _, r in ipairs(ui.prevRegions) do
    if rectContains(r.x, r.y, r.w, r.h, wx, wy) then
      local allowed = true
      if ui.modalRect then
        allowed = rectContains(ui.modalRect.x, ui.modalRect.y, ui.modalRect.w, ui.modalRect.h, wx, wy)
      end
      if allowed then candidates[#candidates + 1] = r end
    end
  end
  if #candidates == 0 then return end
  table.sort(candidates, function(a, b)
    if a.depth ~= b.depth then return a.depth > b.depth end
    return a.order > b.order
  end)
  local dir = ui.wheel > 0 and -1 or 1
  local wantHorizontal = ui.wheelShift and ui.wheel ~= 0
  for _, r in ipairs(candidates) do
    -- Shift + wheel scrolls sideways when this region has horizontal room,
    -- otherwise it falls through to the normal vertical behaviour
    if wantHorizontal and (r.maxH or 0) > 0 then
      local canH = false
      if dir < 0 and (r.hscroll or 0) > 0 then canH = true end
      if dir > 0 and (r.hscroll or 0) < (r.maxH or 0) then canH = true end
      if canH then
        ui.wheelTarget = r.id
        return
      end
    end
    local canMove = false
    if (r.max or 0) > 0 then
      if dir < 0 and (r.scroll or 0) > 0 then canMove = true end
      if dir > 0 and (r.scroll or 0) < (r.max or 0) then canMove = true end
    end
    if canMove then
      ui.wheelTarget = r.id
      return
    end
  end
  ui.wheelTarget = candidates[1].id
end

--- Start a clipped, scrollable region. Returns the current scroll offset.
function ui.beginScroll(id, x, y, w, h, contentH, contentW)
  if not ui.wheelTargetComputed then computeWheelTarget() end
  local st = ui.stateFor(id)
  if st.measured and st.measured > 0 then contentH = st.measured end
  local maxScroll = MAX(0, contentH - h)
  local maxH = MAX(0, (contentW or w) - w)
  st.scroll = st.scroll or 0
  st.hscroll = st.hscroll or 0
  if ui.wheelTarget == id then
    if ui.wheel ~= 0 then
      if ui.wheelShift and maxH > 0 then
        st.hscroll = st.hscroll - ui.wheel * 48
      else
        st.scroll = st.scroll - ui.wheel * 48
      end
      ui.wheelConsumed = true
    end
    if ui.wheelH ~= 0 and maxH > 0 then
      st.hscroll = st.hscroll - ui.wheelH * 48
      ui.wheelConsumed = true
    end
  end
  st.scroll = MAX(0, MIN(maxScroll, st.scroll))
  st.hscroll = MAX(0, MIN(maxH, st.hscroll))
  st.max = maxScroll
  st.maxH = maxH
  st.h = h
  st.contentH = contentH
  local region = {
    id = id, x = x, y = y, w = w, h = h, depth = #ui.scrollStack + 1,
    order = #ui.frameRegions + 1, scroll = st.scroll, max = maxScroll,
    hscroll = st.hscroll, maxH = maxH,
  }
  ui.frameRegions[#ui.frameRegions + 1] = region
  ui.scrollStack[#ui.scrollStack + 1] = region
  ui.pushClip(x, y, w, h)
  love.graphics.push()
  love.graphics.translate(-ui.s(st.hscroll), -ui.s(st.scroll))
  region.scrollAtOpen = st.scroll
  region.hscrollAtOpen = st.hscroll
  ui.scrollOffset = ui.scrollOffset + st.scroll
  ui.scrollOffsetX = ui.scrollOffsetX + st.hscroll
  return st.scroll
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function ui.endScroll()
  local s = table.remove(ui.scrollStack)
  love.graphics.pop()
  if s then
    ui.scrollOffset = ui.scrollOffset - (s.scrollAtOpen or 0)
    ui.scrollOffsetX = ui.scrollOffsetX - (s.hscrollAtOpen or 0)
  end
  ui.popClip()
  if not s then return end

  local st = ui.stateFor(s.id)
  s.scroll = st.scroll
  s.hscroll = st.hscroll

  -- horizontal scrollbar along the bottom edge (Shift+wheel / drag)
  if s.maxH and s.maxH > 0 then
    local barH = 7
    local by = s.y + s.h - barH
    local trackX, trackW = s.x, s.w
    local thumbW = MAX(24, trackW * (trackW / (trackW + s.maxH)))
    local thumbX = trackX + (trackW - thumbW) * (clamp(st.hscroll, 0, s.maxH) / s.maxH)
    local hid = "ui.sbarh." .. tostring(s.id)
    ui.rect("fill", trackX, by, trackW, barH, ui.theme.panelDeep)
    local hHovered, hHeld = ui.clickable(hid, thumbX, by, thumbW, barH)
    if hHeld then
      if ui.dx ~= 0 then
        st.hscroll = clamp(st.hscroll + ui.dx * (trackW + s.maxH) / MAX(1, trackW), 0, s.maxH)
      end
    end
    if ui.clickable(hid .. ".track", trackX, by, trackW, barH) then
      local frac = (ui.mx - trackX - thumbW / 2) / MAX(1, trackW - thumbW)
      st.hscroll = clamp(frac * s.maxH, 0, s.maxH)
    end
    local thumbX2 = trackX + (trackW - thumbW) * (clamp(st.hscroll, 0, s.maxH) / s.maxH)
    ui.rect("fill", thumbX2, by, thumbW, barH, hHovered and ui.theme.accent or ui.theme.borderLight)
  end

  if s.max <= 0 then return end

  local barW = 7
  local bx = s.x + s.w - barW
  local trackY, trackH = s.y, s.h
  local thumbH = MAX(24, trackH * (trackH / (trackH + s.max)))
  local thumbY = trackY + (trackH - thumbH) * (clamp(st.scroll, 0, s.max) / s.max)

  local id = "ui.sbar." .. tostring(s.id)
  ui.rect("fill", bx, trackY, barW, trackH, ui.theme.panelDeep)
  local hovered, held = ui.clickable(id, bx, thumbY, barW, thumbH)
  if held then
    -- use the accumulated pointer delta so dragging works no matter where the
    -- press landed and regardless of how the pointer is driven
    st.barDrag = true
    if ui.dy ~= 0 then
      st.scroll = clamp(st.scroll + ui.dy * (trackH + s.max) / MAX(1, trackH), 0, s.max)
    end
  else
    st.barDrag = false
  end
  if ui.clickable(id .. ".track", bx, trackY, barW, trackH) then
    local frac = (ui.my - trackY - thumbH / 2) / MAX(1, trackH - thumbH)
    st.scroll = clamp(frac * s.max, 0, s.max)
  end
  local thumbY2 = trackY + (trackH - thumbH) * (clamp(st.scroll, 0, s.max) / s.max)
  ui.rect("fill", bx, thumbY2, barW, thumbH, hovered and ui.theme.accent or ui.theme.borderLight)
end

function ui.defer(fn)
  ui.deferred[#ui.deferred + 1] = fn
end

-- ---------------------------------------------------------- life cycle ----

function ui.beginFrame(now)
  ui.now = now or (love.timer and love.timer.getTime() or 0)
  ui.deferred = {}
  ui.scrollStack = {}
  ui.frameRegions = {}
  ui.clipStack = {}
  ui.wheelConsumed = false
  ui.wheelTarget = nil
  ui.wheelTargetComputed = false
  ui.scrollOffset = 0
  ui.scrollOffsetX = 0
  ui.debugWidgets = {}
  ui.renderedText = {}
  ui.hoverId = nil
  ui.tooltip = nil
  -- sample the wheel modifiers once per frame, from the keyboard state
  local wctrl, wshift = ui.wheelModifiers()
  ui.wheelCtrl = ui.wheelCtrl or wctrl
  ui.wheelShift = ui.wheelShift or wshift
  ui.setPointer(love.mouse.getPosition())
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setLineStyle("rough")
  love.graphics.setLineWidth(1)
end

function ui.endFrame()
  for _, fn in ipairs(ui.deferred) do
    fn()
  end
  ui.deferred = {}
  ui.prevRegions = ui.frameRegions

  if ui.tooltip then
    local font = ui.font("small")
    local lines = ui.wrap(ui.tooltip, 420, "small")
    local w = 0
    for _, l in ipairs(lines) do w = MAX(w, font:getWidth(l)) end
    local pad = ui.s(8)
    local lineH = font:getHeight() + ui.s(2)
    local boxW, boxH = w + pad * 2, #lines * lineH + pad
    local sw, sh = love.graphics.getDimensions()
    local tx = MIN(ui.s(ui.mx) + ui.s(14), sw - boxW - ui.s(10))
    local ty = MIN(ui.s(ui.my) + ui.s(18), sh - boxH - ui.s(10))
    love.graphics.setColor(0.05, 0.06, 0.08, 0.96)
    love.graphics.rectangle("fill", tx, ty, boxW, boxH)
    love.graphics.setColor(ui.theme.borderLight)
    love.graphics.rectangle("line", tx, ty, boxW, boxH)
    love.graphics.setFont(font)
    love.graphics.setColor(ui.theme.text)
    for i, l in ipairs(lines) do
      love.graphics.print(l, tx + pad, ty + pad / 2 + (i - 1) * lineH)
    end
  end

  ui.events = {}
  ui.keys = {}
  ui.texts = {}
  ui.wheel = 0
  ui.wheelH = 0
  ui.wheelCtrl = false
  ui.wheelShift = false
  -- the pointer delta is cleared at the END of the frame: events arrive before
  -- love.draw, so widgets must be able to read it during the frame
  ui.dx, ui.dy = 0, 0
  if not love.keyboard.isDown("space") then
    ui.spaceConsumed = false
  end
  ui.modalRect = nil
  ui.inModalPass = false
end

--- Mark the rectangle of a modal that is about to be drawn later this frame.
function ui.setModalRect(x, y, w, h)
  ui.modalRect = { x = x, y = y, w = w, h = h }
end

function ui.beginModalPass()
  ui.inModalPass = true
  ui.popupRect = nil
end

function ui.endModalPass()
  ui.inModalPass = false
end

--- Dim everything behind a modal (physical screen space).
function ui.drawModalScrim()
  local w, h = love.graphics.getDimensions()
  love.graphics.setColor(0, 0, 0, 0.55)
  love.graphics.rectangle("fill", 0, 0, w, h)
end

return ui
