-- src/inspector.lua
-- Right hand node inspector: uid + rename, text fields, type dropdown, the
-- a..h cost / production grids, effects, requirements, start node picker and
-- icon assignment.

local Pack = require("src.pack")
local ui = require("src.ui")

local Inspector = {}

local function mark(app, msg)
  app.dirty = true
  if msg then app:setStatus(msg) end
end

local function labelAt(x, y, text, tip)
  ui.text(x, y + 6, text, { font = "small", color = ui.theme.textDim })
  if tip then
    local w = ui.textW(text, "small")
    ui.rect("fill", x + w + 4, y + 8, 12, 12, ui.theme.panelDeep)
    ui.rect("line", x + w + 4, y + 8, 12, 12, ui.theme.border)
    ui.text(x + w + 6, y + 7, "?", { font = "tiny", color = ui.theme.textDim })
    if ui.hover(x, y, w + 20, 26) then ui.tooltip = tip end
  end
end

--- How many other nodes point at this one (requirements + effects).
local function refCount(pack, node)
  local n = 0
  for _, other in ipairs(pack.tree.nodes) do
    for _, r in ipairs(other.requirements) do
      if r.requiredUid == node.uid then n = n + 1 end
    end
    for _, e in ipairs(other.effects) do
      if e.targetUid == node.uid then n = n + 1 end
    end
  end
  return n
end

local function nodeItems(pack)
  local items = {}
  for _, n in ipairs(pack.tree.nodes) do
    items[#items + 1] = { value = n.uid, label = (n.title ~= "" and (n.title .. "  ·  " .. n.uid) or n.uid) }
  end
  return items
end

local function curveGrid(app, label, curve, x, y, w, tip)
  labelAt(x, y, label, tip)
  local gx = x + ui.LABEL_W
  local gw = w - ui.LABEL_W
  local cellW = (gw - 3 * 4) / 4
  local changedAny = false
  for i, k in ipairs(Pack.COST_KEYS) do
    local col = (i - 1) % 4
    local rowI = math.floor((i - 1) / 4)
    local cx = gx + col * (cellW + 4)
    local cy = y + rowI * 28
    ui.text(cx + 3, cy + 6, k, { font = "tiny", color = ui.theme.textFaint })
    local v, changed = ui.numberField("curve." .. label .. "." .. k, cx + 12, cy, cellW - 12, 24,
      curve[k] or 0, { step = 1, tip = tip })
    if changed then
      curve[k] = v
      changedAny = true
    end
  end
  return changedAny
end

--- Draw the inspector for the current selection inside the given rect.
function Inspector.draw(app, x, y, w, h)
  local pack = app.pack
  if not pack then
    ui.text(x + 16, y + 16, "没有打开的包", { font = "small", color = ui.theme.textDim })
    return
  end
  local node = app.primaryUid and Pack.nodeByUid(pack, app.primaryUid) or nil
  if not node then
    ui.text(x + 16, y + 16, "未选中节点", { font = "title", color = ui.theme.textDim })
    ui.text(x + 16, y + 46, "在画布上单击一个节点开始编辑。", { font = "small", color = ui.theme.textFaint })
    local tips = {
      "左键拖动 = 移动节点（Shift 精细 0.1）",
      "中键 / 右键 / 空格 + 拖动 = 平移画布",
      "滚轮 = 以光标为中心缩放",
      "左键在空白处拖动 = 框选",
      "Delete = 删除选中节点",
      "双击？ 没有双击，用下面的按钮吧",
    }
    for i, t in ipairs(tips) do
      ui.text(x + 16, y + 80 + (i - 1) * 22, "· " .. t, { font = "small", color = ui.theme.textDim })
    end
    return
  end

  local padX = x + 12
  local cw = w - 24
  local top = y + 8
  local contentH = 900 + #node.effects * 34 + #node.requirements * 62
    + #ui.splitLines(node.description) * 20
  ui.beginScroll("inspector", x, y, w, h, contentH)
  local cy = top

  -- ---------------------------------------------------------------- uid --
  ui.text(padX, cy, "uid（也是图标文件名）", { font = "small", color = ui.theme.textDim })
  cy = cy + 18
  local st = ui.stateFor("insp.uid")
  if st.uidFor ~= node.uid then
    st.uidFor = node.uid
    st.draft = node.uid
  end
  local draft, changed, committed = ui.textField("insp.uid.field", padX, cy, cw - 92, 24,
    st.draft or node.uid, { tip = "唯一 id。重命名会同时重命名 icons/<uid>.png 并更新所有引用。" })
  if changed then st.draft = draft end
  local doRename = ui.button("insp.uid.rename", padX + cw - 88, cy, 88, 24, "重命名",
    { tip = "应用新的 uid：重命名图标文件并改写全部引用" }) or committed
  if doRename then
    local newUid = st.draft or node.uid
    if newUid ~= node.uid then
      local ok, extra = Pack.renameNode(pack, node.uid, newUid)
      if ok then
        app:replaceSelection(node.uid, newUid)
        st.uidFor = newUid
        local renamed = (type(extra) == "table" and #extra > 0) and ("，图标已重命名为 " .. table.concat(extra, ", ")) or ""
        mark(app, "重命名 " .. newUid .. renamed)
        app.graph:invalidateIcons()
      else
        app:error("重命名失败: " .. tostring(extra))
        st.draft = node.uid
      end
    end
  end
  cy = cy + 30
  ui.text(padX, cy, "被 " .. refCount(pack, node) .. " 条前置 / 特效引用",
    { font = "tiny", color = ui.theme.textFaint })
  cy = cy + 18

  -- -------------------------------------------------------------- basics --
  labelAt(padX, cy, "标题", "游戏里显示在节点上方的名字")
  local title, tchanged = ui.textField("insp.title", padX + ui.LABEL_W, cy, cw - ui.LABEL_W, 24,
    node.title, { placeholder = "节点标题" })
  if tchanged then node.title = title mark(app, nil) end
  cy = cy + 30

  labelAt(padX, cy, "说明", "节点详情文本，支持多行")
  local desc, dchanged = ui.textField("insp.desc", padX + ui.LABEL_W, cy, cw - ui.LABEL_W, 74,
    node.description, { multiline = true, placeholder = "这个节点是什么？" })
  if dchanged then node.description = desc mark(app, nil) end
  cy = cy + 80

  labelAt(padX, cy, "类型", "Generator = 可重复购买的产出节点；Research = 一次性研究；Trophy = 奖杯")
  ui.dropdown("insp.type", padX + ui.LABEL_W, cy, cw - ui.LABEL_W, 24, node.type, Pack.TYPES, {
    swatch = function(v)
      return ({ Generator = ui.theme.generator, Research = ui.theme.research, Trophy = ui.theme.trophy })[v]
    end,
    onSelect = function(v) node.type = v mark(app, "类型 -> " .. v) end,
  })
  cy = cy + 32

  -- ------------------------------------------------------------ position --
  labelAt(padX, cy, "位置 (世界单位)", "游戏可见区域约 100x58；新节点默认 y = 层数 x 22，x 建议在 ±40 内")
  local px2, chx = ui.numberField("insp.px", padX + ui.LABEL_W, cy, (cw - ui.LABEL_W) / 2 - 4, 24,
    node.position.x, { step = 1 })
  if chx then node.position.x = px2 mark(app, "x -> " .. ui.fmtNum(px2)) end
  local py2, chy = ui.numberField("insp.py", padX + ui.LABEL_W + (cw - ui.LABEL_W) / 2 + 4, cy,
    (cw - ui.LABEL_W) / 2 - 4, 24, node.position.y, { step = 1 })
  if chy then node.position.y = py2 mark(app, "y -> " .. ui.fmtNum(py2)) end
  cy = cy + 26
  local row = math.floor(node.position.y / Pack.ROW_STEP + 0.5)
  ui.text(padX + ui.LABEL_W, cy, string.format("x=%.4g  y=%.4g  z=%.4g    第 %d 层（y = %d x %d）",
    node.position.x, node.position.y, node.position.z, row, row, Pack.ROW_STEP),
    { font = "tiny", color = ui.theme.textFaint })
  cy = cy + 20

  -- --------------------------------------------------------------- cost --
  if curveGrid(app, "造价 a..h", node.cost, padX, cy, cw,
    "玩家购买这个节点需要付出的资源。a 是最常用的档位。") then mark(app, nil) end
  cy = cy + 60
  if curveGrid(app, "产出 a..h", node.production, padX, cy, cw,
    "这个节点每秒产出的资源。Trophy / Research 通常都是 0。") then mark(app, nil) end
  cy = cy + 62

  -- ------------------------------------------------------------ effects --
  ui.rect("line", padX, cy, cw, 1, ui.theme.border)
  cy = cy + 8
  ui.text(padX, cy, "特效 effects（本节点购买后给目标节点加产）", { font = "small", color = ui.theme.accent })
  cy = cy + 20
  local items = nodeItems(pack)
  for i, eff in ipairs(node.effects) do
    local ey = cy
    ui.dropdown("insp.eff.t" .. i, padX, ey, cw - 116, 24, eff.targetUid, items, {
      maxVisible = 10,
      onSelect = function(v) eff.targetUid = v mark(app, "特效目标 -> " .. v) end,
    })
    local boost, bchanged = ui.numberField("insp.eff.b" .. i, padX + cw - 112, ey, 84, 24,
      eff.prodBoost, { step = 0.1, tip = "产出加成倍率" })
    if bchanged then eff.prodBoost = boost mark(app, nil) end
    if ui.button("insp.eff.x" .. i, padX + cw - 24, ey, 24, 24, "×", { danger = true, tip = "删除这条特效" }) then
      table.remove(node.effects, i)
      mark(app, "删除了一条特效")
      break
    end
    cy = cy + 28
  end
  if ui.button("insp.eff.add", padX, cy, cw, 24, "＋ 添加特效", { tip = "让这个节点给别的节点加产" }) then
    node.effects[#node.effects + 1] = {
      targetUid = pack.tree.nodes[1] and pack.tree.nodes[1].uid or "",
      prodBoost = 1,
      extra = {},
    }
    mark(app, "添加了一条特效")
  end
  cy = cy + 32

  -- ------------------------------------------------------- requirements --
  ui.rect("line", padX, cy, cw, 1, ui.theme.border)
  cy = cy + 8
  ui.text(padX, cy, "前置 requirements（连线与解锁条件）", { font = "small", color = ui.theme.accent })
  cy = cy + 20
  for i, req in ipairs(node.requirements) do
    local ry = cy
    ui.dropdown("insp.req.u" .. i, padX, ry, cw - 32, 24, req.requiredUid, items, {
      maxVisible = 10,
      onSelect = function(v) req.requiredUid = v mark(app, "前置 -> " .. v) end,
    })
    if ui.button("insp.req.x" .. i, padX + cw - 28, ry, 24, 24, "×", { danger = true, tip = "删除这条前置" }) then
      table.remove(node.requirements, i)
      mark(app, "删除了一条前置")
      break
    end
    ry = ry + 26
    local cnt, cchanged = ui.numberField("insp.req.c" .. i, padX, ry, 56, 22, req.requiredCount,
      { step = 1, min = 0, int = true,
        tip = "requiredCount = 0：整棵树开局可见（推荐）。>0：玩家拥有该数量的前置于节点才出现。" })
    if cchanged then req.requiredCount = cnt mark(app, nil) end
    ui.dropdown("insp.req.l" .. i, padX + 62, ry, 104, 22, req.lineType, Pack.LINE_TYPES, {
      onSelect = function(v) req.lineType = v mark(app, "lineType -> " .. v) end,
    })
    local hiddenNew = ui.checkbox("insp.req.h" .. i, padX + 174, ry + 1, "hidden", req.hidden)
    if hiddenNew ~= req.hidden then
      req.hidden = hiddenNew
      mark(app, nil)
    end
    if (req.requiredCount or 0) > 0 then
      ui.text(padX, ry + 24, "⚠ requiredCount > 0：该节点会推迟出现，通常应该写 0",
        { font = "tiny", color = ui.theme.warn })
      ry = ry + 14
    end
    cy = ry + 30
  end
  if ui.button("insp.req.add", padX, cy, cw, 24, "＋ 添加前置", { tip = "画一条从别的节点指向本节点的连线" }) then
    node.requirements[#node.requirements + 1] = {
      requiredUid = pack.tree.nodes[1] and pack.tree.nodes[1].uid or "",
      requiredCount = 0,
      lineType = "NORM",
      hidden = false,
      extra = {},
    }
    mark(app, "添加了一条前置（requiredCount 默认 0）")
  end
  cy = cy + 34

  -- -------------------------------------------------------------- icon ---
  ui.rect("line", padX, cy, cw, 1, ui.theme.border)
  cy = cy + 8
  ui.text(padX, cy, "图标 icons/" .. node.uid .. ".png", { font = "small", color = ui.theme.accent })
  cy = cy + 22
  local preview = 56
  ui.rect("fill", padX, cy, preview, preview, ui.theme.panelDeep)
  ui.rect("line", padX, cy, preview, preview, ui.theme.border)
  local img = app.graph and app.graph:icon(pack, node.uid) or nil
  if img then
    local iw, ih = img:getDimensions()
    local scale = (preview - 6) / math.max(iw, ih)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(img, padX + 3 + (preview - 6 - iw * scale) / 2,
      cy + 3 + (preview - 6 - ih * scale) / 2, 0, scale, scale)
  else
    ui.text(padX, cy + 20, "无图标", { align = "center", w = preview, font = "tiny", color = ui.theme.textFaint })
  end
  local bx = padX + preview + 8
  local bw = cw - preview - 8
  if ui.button("insp.icon.pick", bx, cy, bw, 24, "选择 / 替换图标…",
    { tip = "从磁盘选一个 png/jpg，复制成 icons/<uid>.png" }) then
    app:openIconPicker(node.uid)
  end
  if ui.button("insp.icon.clear", bx, cy + 28, bw / 2 - 3, 24, "清除图标",
    { danger = true, disabled = not Pack.iconExists(pack, node.uid) }) then
    Pack.removeIcon(pack, node.uid)
    app.graph:invalidateIcons()
    mark(app, "已清除图标")
  end
  if ui.button("insp.icon.focus", bx + bw / 2 + 3, cy + 28, bw / 2 - 3, 24, "定位到节点") then
    app.graph:centerOn(pack, node.uid)
    app:setStatus("画布居中到 " .. node.uid)
  end
  cy = cy + preview + 12
  if Pack.iconPath(pack, node.uid) then
    ui.text(padX, cy, Pack.iconPath(pack, node.uid), { font = "tiny", color = ui.theme.textFaint })
  end
  cy = cy + 20

  -- ------------------------------------------------------------ actions --
  ui.rect("line", padX, cy, cw, 1, ui.theme.border)
  cy = cy + 8
  local isStart = pack.tree.startNode == node.uid
  if ui.button("insp.start", padX, cy, cw, 26,
    isStart and "★ 已是起始节点 startNode" or "设为起始节点 startNode",
    { accent = not isStart, tip = "树的起点：游戏从这里开始，可见区域提示框也挂在这个节点上" }) then
    if not isStart then
      pack.tree.startNode = node.uid
      mark(app, "startNode -> " .. node.uid)
    end
  end
  cy = cy + 32
  if ui.button("insp.dup", padX, cy, cw / 2 - 3, 24, "复制节点") then
    local copy = Pack.duplicateNode(pack, node.uid)
    if copy then
      app:setSelection({ copy.uid })
      mark(app, "复制出 " .. copy.uid)
    end
  end
  if ui.button("insp.del", padX + cw / 2 + 3, cy, cw / 2 - 3, 24, "删除节点 (Del)", { danger = true }) then
    app:deleteSelected()
  end
  cy = cy + 34

  ui.scrollContentHeight("inspector", cy - top)
  ui.endScroll()
end

return Inspector
