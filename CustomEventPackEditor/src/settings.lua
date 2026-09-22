-- src/settings.lua
-- The pack settings screen: pack.json basics, intro / outro, currencies,
-- localization overrides, the full missions editor and the editor preferences
-- (UI scale).
--
-- Every list that can grow has its own scroll region nested inside the page
-- scroll region, so a pack with dozens of ranks / currencies / overrides stays
-- reachable. The mouse wheel is routed to the innermost list under the cursor
-- and bubbles out to the page when that list is already at its end.

local Pack = require("src.pack")
local ui = require("src.ui")
local json = require("src.json")
local Fonts = require("src.fonts")

local Settings = {}

local ROW = 28          -- logical row height of the list editors
local TIGHT = 24        -- logical height of a compact field

local function mark(app, msg)
  app.dirty = true
  if msg then app:setStatus(msg) end
end

local function section(title, x, y, w, height, tip)
  ui.rect("fill", x, y, w, height, ui.theme.panel)
  ui.rect("line", x, y, w, height, ui.theme.border)
  ui.rect("fill", x + 1, y + 1, w - 2, 26, ui.theme.panelAlt)
  ui.text(x + 10, y + 6, title, { font = "small", color = ui.theme.accent })
  if tip then ui.text(x + w - ui.textW(tip, "tiny") - 10, y + 8, tip, { font = "tiny", color = ui.theme.textFaint }) end
  return y + 34
end

local function fieldLabel(x, y, text)
  ui.text(x, y + 6, text, { font = "small", color = ui.theme.textDim })
end

local function getString(tbl, key)
  local v = tbl[key]
  if type(v) == "string" then return v end
  if type(v) == "number" then return tostring(v) end
  return ""
end

--- Text field bound to pack.meta[key]; only writes when the user edits it.
local function metaString(app, key, x, y, w, placeholder, label, labelW)
  local meta = app.pack.meta
  if label then fieldLabel(x, y, label) x = x + (labelW or ui.LABEL_W) w = w - (labelW or ui.LABEL_W) end
  local value, changed = ui.textField("meta." .. key, x, y, w, TIGHT, getString(meta, key), { placeholder = placeholder })
  if changed then
    meta[key] = value
    mark(app, "pack.json " .. key .. " 已修改")
  end
end

local function metaNumber(app, key, x, y, w, opts, label, labelW)
  local meta = app.pack.meta
  if label then fieldLabel(x, y, label) x = x + (labelW or ui.LABEL_W) w = w - (labelW or ui.LABEL_W) end
  local value = tonumber(meta[key]) or 0
  local v, changed = ui.numberField("meta." .. key, x, y, w, TIGHT, value, opts or {})
  if changed then
    meta[key] = v
    mark(app, "pack.json " .. key .. " = " .. ui.fmtNum(v))
  end
end

--------------------------------------------------------------------------------
-- Editor preferences (UI scale)
--------------------------------------------------------------------------------

local PRESETS = { 0.75, 1.0, 1.25, 1.5, 2.0 }

local function editorCard(app, x, y, w)
  local height = 150
  local cy = section("编辑器设置", x, y, w, height,
    string.format("已保存到 %s", Pack.basename(app.configPath or "editor.cfg")))
  ui.text(x + 10, cy + 6, "界面缩放", { font = "small", color = ui.theme.textDim })
  local bx = x + 96
  if ui.button("ui.minus", bx, cy, 30, TIGHT, "−", { tip = "缩小界面 (Ctrl+-)" }) then
    app:setUIScale(app.uiScale - 0.05)
  end
  ui.rect("fill", bx + 34, cy, 64, TIGHT, ui.theme.panelDeep)
  ui.rect("line", bx + 34, cy, 64, TIGHT, ui.theme.border)
  ui.text(bx + 34, cy + 5, string.format("%d%%", math.floor(app.uiScale * 100 + 0.5)),
    { align = "center", w = 64, font = "small", color = ui.theme.text })
  if ui.button("ui.plus", bx + 102, cy, 30, TIGHT, "＋", { tip = "放大界面 (Ctrl++)" }) then
    app:setUIScale(app.uiScale + 0.05)
  end
  if ui.button("ui.reset", bx + 138, cy, 78, TIGHT, "重置 100%", { tip = "Ctrl+0" }) then
    app:setUIScale(1.0)
  end
  cy = cy + TIGHT + 8
  local px = x + 10
  for _, v in ipairs(PRESETS) do
    local label = string.format("%d%%", math.floor(v * 100 + 0.5))
    local bw = ui.textW(label, "small") + 18
    local active = math.abs(app.uiScale - v) < 0.001
    if ui.button("ui.preset." .. label, px, cy, bw, TIGHT, label, {
      bg = active and ui.theme.accentSoft or ui.theme.panelAlt,
      tip = "切换到 " .. label,
    }) then
      app:setUIScale(v)
    end
    px = px + bw + 6
  end
  ui.text(px + 6, cy + 5, string.format("正文字号 %.0f px · 字体 %s", Fonts.SIZES.body * app.uiScale, Fonts.label),
    { font = "tiny", color = ui.theme.textFaint })
  cy = cy + TIGHT + 8
  ui.text(x + 10, cy, "快捷键 Ctrl+加号 / Ctrl+减号 / Ctrl+0；面板宽度与控件尺寸会一起缩放。",
    { font = "tiny", color = ui.theme.textFaint })
  cy = cy + TIGHT + 4
  ui.text(x + 10, cy + 5, "画布平移速度", { font = "small", color = ui.theme.textDim })
  if ui.button("pan.minus", x + 108, cy, 30, TIGHT, "−", { tip = "慢一点" }) then
    app:setPanSpeed(app.graph.panSpeed - 100)
  end
  ui.rect("fill", x + 142, cy, 92, TIGHT, ui.theme.panelDeep)
  ui.rect("line", x + 142, cy, 92, TIGHT, ui.theme.border)
  ui.text(x + 142, cy + 5, string.format("%d px/s", app.graph.panSpeed),
    { align = "center", w = 92, font = "tiny", color = ui.theme.text })
  if ui.button("pan.plus", x + 238, cy, 30, TIGHT, "＋", { tip = "快一点" }) then
    app:setPanSpeed(app.graph.panSpeed + 100)
  end
  ui.text(x + 276, cy + 5, "WASD 平移画布，Shift x3", { font = "tiny", color = ui.theme.textFaint })
  return height
end

--------------------------------------------------------------------------------
-- Basics
--------------------------------------------------------------------------------

local function basicsCard(app, x, y, w)
  local rows = 11
  local height = 40 + rows * 30
  local cy = section("基本信息 pack.json", x, y, w, height, "所有字段都是可选的")
  local labelW = 104
  metaString(app, "id", x + 10, cy, w - 20, "deepsea", "id", labelW) cy = cy + 30
  metaString(app, "title", x + 10, cy, w - 20, "深海勘探", "title", labelW) cy = cy + 30
  metaString(app, "subtitle", x + 10, cy, w - 20, "示例活动包", "subtitle", labelW) cy = cy + 30
  metaString(app, "tree", x + 10, cy, w - 20, "tree.json", "tree", labelW) cy = cy + 30
  metaString(app, "icons", x + 10, cy, w - 20, "icons", "icons", labelW) cy = cy + 30
  metaNumber(app, "currencyCount", x + 10, cy, w - 20, { step = 1, min = 0, max = 8, int = true },
    "currencyCount", labelW) cy = cy + 30
  metaString(app, "banner", x + 10, cy, w - 20, "banner.png", "banner", labelW) cy = cy + 30
  metaString(app, "button", x + 10, cy, w - 20, "button.png", "button", labelW) cy = cy + 30
  metaString(app, "tapHint", x + 10, cy, w - 20, "点击以赚钱", "tapHint", labelW) cy = cy + 30
  metaString(app, "resourceName", x + 10, cy, (w - 26) / 2, "深海样本", "resourceName", labelW)
  metaString(app, "resourceIcon", x + 10 + (w - 26) / 2 + 6, cy, (w - 26) / 2, "resource.png", nil, labelW)
  cy = cy + 30
  ui.text(x + 10, cy, "改动只会写入被编辑过的字段，未知字段原样保留。",
    { font = "tiny", color = ui.theme.textFaint })
  return height
end

--------------------------------------------------------------------------------
-- Line lists (intro / outro) — each list scrolls on its own
--------------------------------------------------------------------------------

local function lineList(app, key, x, y, w, title, placeholder, maxRows)
  local list = Pack.metaArray(app.pack, key)
  local rows = math.max(1, #list)
  local contentH = rows * ROW + 4
  local listH = math.min(contentH, maxRows * ROW)
  local height = 34 + listH + 36
  local cy = section(title .. "（" .. #list .. " 行）", x, y, w, height)
  ui.beginScroll("set." .. key, x + 6, cy, w - 12, listH, contentH)
  for i = 1, #list do
    local ry = cy + (i - 1) * ROW
    local value, changed = ui.textField("meta." .. key .. "." .. i, x + 10, ry, w - 66, TIGHT,
      tostring(list[i] or ""), { placeholder = placeholder })
    if changed then
      list[i] = value
      mark(app, nil)
    end
    if ui.button("meta." .. key .. ".x" .. i, x + w - 50, ry, 30, TIGHT, "×", { danger = true, tip = "删除这一行" }) then
      table.remove(list, i)
      mark(app, "删除了一行 " .. key)
      break
    end
  end
  ui.scrollContentHeight("set." .. key, contentH)
  ui.endScroll()
  cy = cy + listH + 6
  if ui.button("meta." .. key .. ".add", x + 10, cy, w - 20, TIGHT, "＋ 添加一行") then
    list[#list + 1] = ""
    mark(app, "新增一行 " .. key)
  end
  return height
end

--------------------------------------------------------------------------------
-- Currencies
--------------------------------------------------------------------------------

local function currenciesCard(app, x, y, w, maxRows)
  local list = Pack.metaArray(app.pack, "currencies")
  local rows = math.max(1, #list)
  local contentH = rows * 30 + 4
  local listH = math.min(contentH, maxRows * 30)
  local height = 34 + listH + 36
  local cy = section("货币 currencies", x, y, w, height,
    "currencyCount = " .. tostring(tonumber(app.pack.meta.currencyCount) or 0))
  ui.beginScroll("set.currencies", x + 6, cy, w - 12, listH, contentH)
  if #list == 0 then
    ui.text(x + 12, cy + 6, "还没有定义货币", { font = "small", color = ui.theme.textFaint })
  end
  for i = 1, #list do
    local item = list[i]
    if type(item) ~= "table" then
      item = json.markObject({})
      list[i] = item
    end
    local ry = cy + (i - 1) * 30
    local name, changed = ui.textField("cur.name." .. i, x + 10, ry, w * 0.36, TIGHT,
      getString(item, "name"), { placeholder = "货币名称" })
    if changed then item.name = name mark(app, nil) end
    local icon, ichanged = ui.textField("cur.icon." .. i, x + 10 + w * 0.36 + 6, ry, w * 0.30, TIGHT,
      getString(item, "icon"), { placeholder = "currency1.png" })
    if ichanged then item.icon = icon mark(app, nil) end
    if ui.button("cur.pick." .. i, x + 10 + w * 0.66 + 12, ry, w * 0.34 - 92, TIGHT, "图片…",
      { tip = "从磁盘选一张图片复制进包目录，并填好文件名" }) then
      app:pickFileToPack(function(relPath)
        item.icon = relPath
        mark(app, "货币图标 -> " .. relPath)
      end)
    end
    if ui.button("cur.x." .. i, x + w - 50, ry, 30, TIGHT, "×", { danger = true }) then
      table.remove(list, i)
      mark(app, "删除了一种货币")
      break
    end
  end
  ui.scrollContentHeight("set.currencies", contentH)
  ui.endScroll()
  cy = cy + listH + 6
  if ui.button("cur.add", x + 10, cy, w - 20, TIGHT, "＋ 添加货币") then
    list[#list + 1] = json.markObject({ name = "新货币", icon = "" })
    mark(app, "新增一种货币")
  end
  return height
end

--------------------------------------------------------------------------------
-- Localization overrides
--------------------------------------------------------------------------------

local function localizationCard(app, x, y, w, maxRows)
  local map = Pack.metaObject(app.pack, "localization")
  local keys = {}
  for k in pairs(map) do keys[#keys + 1] = k end
  table.sort(keys)
  local rows = math.max(1, #keys)
  local contentH = rows * 46 + 4
  local listH = math.min(contentH, maxRows * 46)
  local height = 34 + listH + 36
  local cy = section("本地化覆盖 localization", x, y, w, height, "key / value 覆盖表")
  ui.beginScroll("set.localization", x + 6, cy, w - 12, listH, contentH)
  if #keys == 0 then
    ui.text(x + 12, cy + 6, "还没有覆盖项", { font = "small", color = ui.theme.textFaint })
  end
  for i, key in ipairs(keys) do
    local ry = cy + (i - 1) * 46
    ui.text(x + 12, ry, key, { font = "tiny", color = ui.theme.textDim })
    local value, changed = ui.textField("loc.v." .. i, x + 10, ry + 15, w - 68, TIGHT,
      tostring(map[key] or ""), { placeholder = "覆盖文本" })
    if changed then map[key] = value mark(app, nil) end
    if ui.button("loc.x." .. i, x + w - 50, ry + 15, 30, TIGHT, "×", { danger = true, tip = "删除这条覆盖" }) then
      map[key] = nil
      mark(app, "删除覆盖 " .. key)
      break
    end
  end
  ui.scrollContentHeight("set.localization", contentH)
  ui.endScroll()
  cy = cy + listH + 6
  local st = ui.stateFor("loc.new")
  st.key = st.key or ""
  local draft, changed = ui.textField("loc.new.key", x + 10, cy, w - 140, TIGHT, st.key, { placeholder = "新 key" })
  if changed then st.key = draft end
  if ui.button("loc.new.add", x + w - 126, cy, w - 136, TIGHT, "＋ 添加覆盖") then
    if st.key ~= "" then
      map[st.key] = map[st.key] or ""
      st.key = ""
      mark(app, "新增覆盖 key")
    end
  end
  return height
end

--------------------------------------------------------------------------------
-- Missions
--------------------------------------------------------------------------------

-- A mission row stacks vertically, so it works at any column width:
--   line 1: type dropdown + delete
--   line n: one row per collect target (item dropdown + amount + remove)
--   line:   "add target"
--   line:   prizeType / prizeAmount / treeType / hidden
--   hint
-- Height grows with the number of targets.
local MIS_ROW_HEAD = 32     -- type row
local MIS_ROW_TAIL = 50     -- add-target button + prize row + hint
local MIS_TARGET_H = 24

local function missionRowHeight(m)
  local n = math.max(1, #Pack.missionTargets(m))
  return MIS_ROW_HEAD + n * MIS_TARGET_H + MIS_ROW_TAIL
end

local function rankHeight(rank, rowW)
  local ms = (type(rank) == "table" and type(rank.missions) == "table") and rank.missions or {}
  -- +16 for the stage summary line under the stage header
  local h = 62 + 16
  if #ms == 0 then
    h = h + missionRowHeight(nil)
  else
    for _, m in ipairs(ms) do h = h + missionRowHeight(m) end
  end
  return h + 4
end

local function missionRow(app, pack, m, i, x, y, w)
  local uids = {}
  for _, n in ipairs(pack.tree.nodes) do
    uids[#uids + 1] = { value = n.uid, label = n.title ~= "" and (n.title .. "  ·  " .. n.uid) or n.uid }
  end
  local rowH = missionRowHeight(m)
  ui.rect("fill", x, y, w, rowH - 4, ui.theme.panelDeep)
  ui.rect("line", x, y, w, rowH - 4, ui.theme.border)

  local delW = 32
  ui.dropdown("mis." .. i .. ".type", x + 8, y + 6, math.max(96, math.min(160, w * 0.34)), 22,
    m.type or "Collect", Pack.MISSION_TYPES, {
      maxVisible = 8,
      onSelect = function(v) m.type = v mark(app, "任务类型 -> " .. v) end,
    })
  if ui.button("mis." .. i .. ".del", x + w - delW - 8, y + 6, delW, 22, "×", { danger = true }) then
    return "delete"
  end

  -- Collect targets. ONE target is saved in the legacy flat form
  -- (reqItemId / reqAmount); TWO or more are saved as the "targets" array.
  local targets = Pack.missionTargets(m)
  local ty = y + MIS_ROW_HEAD
  for ti = 1, #targets do
    local t = targets[ti]
    local amountW = 62
    local itemW = math.max(70, w - 46 - amountW - 8)
    ui.dropdown(string.format("mis.%s.t%d.item", i, ti), x + 8, ty, itemW, 22, t.item, uids, {
      maxVisible = 10,
      onSelect = function(v)
        t.item = v
        Pack.setMissionTargets(m, targets)
        mark(app, "收集目标 -> " .. v)
      end,
    })
    local amt, achanged = ui.numberField(string.format("mis.%s.t%d.amount", i, ti), x + 12 + itemW, ty,
      amountW, 22, t.amount, { step = 1, min = 0, int = true, tip = "需要收集的数量" })
    if achanged then
      t.amount = amt
      Pack.setMissionTargets(m, targets)
      mark(app, nil)
    end
    if ui.button(string.format("mis.%s.t%d.del", i, ti), x + w - 30, ty, 22, 22, "×",
      { danger = true, tip = "删除这个收集目标", disabled = #targets <= 1 }) then
      table.remove(targets, ti)
      Pack.setMissionTargets(m, targets)
      mark(app, "删除一个收集目标")
      break
    end
    ty = ty + MIS_TARGET_H
  end
  if ui.button("mis." .. i .. ".tadd", x + 8, ty, math.max(80, w - 16), 20, "＋ 收集目标",
    { tip = "一个任务可以有多个收集目标：2 个以上保存成 targets 数组，全部满足才拿到奖励" }) then
    targets[#targets + 1] = { item = "", amount = 1 }
    Pack.setMissionTargets(m, targets)
    mark(app, "新增一个收集目标（保存为 targets 数组）")
  end
  ty = ty + 24

  local prizeW = math.max(120, math.min(180, w * 0.42))
  ui.dropdown("mis." .. i .. ".prize", x + 8, ty, prizeW, 22, m.prizeType or "Darwinium", Pack.PRIZE_TYPES, {
    maxVisible = 8,
    onSelect = function(v) m.prizeType = v mark(app, "prizeType -> " .. v) end,
  })
  local prize, pchanged = ui.numberField("mis." .. i .. ".prizeamt", x + 16 + prizeW, ty, 74, 22,
    tonumber(m.prizeAmount) or 0, { step = 1, min = 0, int = true, tip = "奖励数量" })
  if pchanged then m.prizeAmount = prize mark(app, nil) end
  local treeX = x + 16 + prizeW + 82
  if treeX + 88 < x + w - 8 then
    ui.dropdown("mis." .. i .. ".tree", treeX, ty, 88, 22, m.treeType or "NONE", Pack.TREE_TYPES, {
      onSelect = function(v) m.treeType = v mark(app, "treeType -> " .. v) end,
    })
  end
  if treeX + 96 < x + w - 70 then
    local hidden = ui.checkbox("mis." .. i .. ".hidden", treeX + 96, ty + 2, "hidden", m.hidden == true)
    if hidden ~= (m.hidden == true) then m.hidden = hidden mark(app, nil) end
  end

  ui.text(x + 8, ty + 26, "type / 收集目标 item+amount / prizeType / prizeAmount / treeType / hidden",
    { font = "tiny", color = ui.theme.textFaint })
  return nil
end

local function missionsCard(app, x, y, w, maxListH)
  local pack = app.pack
  local list = Pack.metaArray(pack, "missions")
  local rowW = w - 44
  local contentH = 8
  for _, rank in ipairs(list) do contentH = contentH + rankHeight(rank, rowW) end
  local listH = math.min(contentH, maxListH)
  local height = 34 + 54 + listH + 40
  local cy = section("任务 missions（" .. #list .. " 个" .. Pack.STAGE_WORD .. "）", x, y, w, height,
    "stage / targetHrs / missions")
  -- THE number the player sees on the game's mission panel: biggest text here.
  -- Nothing else in this card may be read as "what the game shows".
  ui.text(x + 12, cy, Pack.missionPanelText(pack.meta), { font = "title", color = ui.theme.ok })
  ui.text(x + 12, cy + 28, Pack.missionPanelNote(pack.meta), { font = "tiny", color = ui.theme.textDim })
  cy = cy + 52
  ui.beginScroll("set.missions", x + 6, cy, w - 12, listH, contentH)
  if #list == 0 then
    ui.text(x + 12, cy + 6, "还没有" .. Pack.STAGE_WORD, { font = "small", color = ui.theme.textFaint })
  end
  local ry = cy + 4
  for ri = 1, #list do
    local rank = list[ri]
    if type(rank) ~= "table" then
      rank = json.markObject({})
      list[ri] = rank
    end
    local rh = rankHeight(rank, rowW)
    -- stages are played in order: the first is live, the rest unlock later
    local isCurrent = (ri == 1)
    ui.rect("fill", x + 10, ry, w - 32, rh - 6,
      isCurrent and { 0.17, 0.21, 0.27 } or { 0.11, 0.12, 0.15 })
    ui.rect("line", x + 10, ry, w - 32, rh - 6,
      isCurrent and ui.theme.accent or ui.theme.border)
    ui.text(x + 16, ry + 6, "阶段 " .. ri,
      { font = "small", color = isCurrent and ui.theme.accent or ui.theme.textDim })
    local title, tchanged = ui.textField("mis.r." .. ri .. ".title", x + 88, ry + 4, w * 0.42, TIGHT,
      getString(rank, "title"), { placeholder = "阶段标题" })
    if tchanged then rank.title = title mark(app, nil) end
    local hrsX = x + 88 + w * 0.42 + 8
    local hrs, hchanged = ui.numberField("mis.r." .. ri .. ".hrs", hrsX, ry + 4, 80, TIGHT,
      tonumber(rank.targetHrs) or 0, { step = 0.5, min = 0, tip = "目标小时数" })
    if hchanged then rank.targetHrs = hrs mark(app, nil) end
    if ui.button("mis.r." .. ri .. ".del", x + w - 108, ry + 4, 82, TIGHT, "删除该阶段", { danger = true }) then
      table.remove(list, ri)
      mark(app, "删除一个" .. Pack.STAGE_WORD)
      break
    end
    -- The game merges CONSECUTIVE missions with the same (prizeType, prizeID)
    -- into one task card, so the two numbers can differ. Show both.
    local missions = rank.missions
    if type(missions) ~= "table" then
      missions = json.markArray({})
      rank.missions = missions
    end
    local n_missions = #missions
    local cards = Pack.countMissionCards(rank)
    local countText = Pack.missionStageLabel(pack.meta, ri)
    local countCol = isCurrent and ui.theme.ok or ui.theme.textFaint
    if cards < n_missions then countCol = ui.theme.warn end
    ui.text(x + 16, ry + 32, countText, { font = "tiny", color = countCol })
    if cards < n_missions then
      ui.text(x + 24 + ui.textW(countText, "tiny"), ry + 32, "连续同奖励会被合并",
        { font = "tiny", color = ui.theme.warn })
    end
    if ui.hover(x + 16, ry + 32, ui.textW(countText, "tiny") + 60, 14) then
      ui.tooltip = "任务面板一次只显示一个" .. Pack.STAGE_WORD .. "（进入活动时是阶段 1），" ..
        "完成当前阶段的全部" .. Pack.ENTRY_WORD .. "后自动进入下一个阶段。" ..
        "\n同一" .. Pack.STAGE_WORD .. "里相邻且 prizeType 与 prizeID 都相同的任务会并成一个" ..
        Pack.ENTRY_WORD .. "，中间隔着别的奖励就不会合并。"
    end
    local my = ry + 34 + 16
    for mi = 1, #missions do
      if type(missions[mi]) ~= "table" then
        missions[mi] = json.markObject({})
      end
      local action = missionRow(app, pack, missions[mi], ri .. "_" .. mi, x + 16, my, w - 44)
      if action == "delete" then
        table.remove(missions, mi)
        mark(app, "删除任务")
        break
      end
      my = my + missionRowHeight(missions[mi])
    end
    if ui.button("mis.r." .. ri .. ".add", x + 16, my, 140, 22, "＋ 添加任务") then
      missions[#missions + 1] = json.markObject({
        type = "Collect", reqItemId = "", reqAmount = 1,
        prizeType = "Darwinium", prizeAmount = 1, hidden = false, treeType = "NONE",
      })
      mark(app, "新增任务")
    end
    ry = ry + rh
  end
  ui.scrollContentHeight("set.missions", contentH)
  ui.endScroll()
  cy = cy + listH + 6
  if ui.button("mis.add", x + 10, cy, w - 20, TIGHT, "＋ 添加" .. Pack.STAGE_WORD) then
    list[#list + 1] = json.markObject({ title = "新阶段", targetHrs = 1, missions = json.markArray({}) })
    mark(app, "新增一个" .. Pack.STAGE_WORD)
  end
  return height
end

--------------------------------------------------------------------------------

--- Background: exactly ONE image. The game replaces its own backdrop with it, so
--- there is nothing to position - the framing is the game's.
local function backgroundCard(app, x, y, w)
  local rel = Pack.getBackground(app.pack)
  local height = 96
  local cy = section("背景图 background", x, y, w, height,
    "暂未使用：游戏内不渲染背景")
  ui.text(x + 10, cy, rel or "（未设置）",
    { font = "tiny", color = rel and ui.theme.text or ui.theme.textFaint })
  ui.text(x + 10, cy + 15, "游戏内目前不渲染背景，树和连线画在纯色上最清晰",
    { font = "tiny", color = ui.theme.textFaint })
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

--- Draw the whole settings screen inside the rect.
function Settings.draw(app, x, y, w, h)
  local pack = app.pack
  if not pack then
    ui.text(x + 20, y + 20, "没有打开任何包", { font = "title", color = ui.theme.textDim })
    return
  end

  ui.beginScroll("settings", x, y, w, h, 2400)
  local top = y + 12
  local gap = 14
  -- two columns only when both really fit, otherwise stack them so nothing is
  -- pushed outside the panel (e.g. 900x600 at 150% UI scale)
  local twoCol = (w - 36 - gap) >= 2 * 320
  local colW = twoCol and ((w - 36 - gap) / 2) or (w - 28)
  local colA = x + 14
  local colB = twoCol and (colA + colW + gap) or colA
  local rowsCap = math.max(3, math.floor((h - 200) / ROW))
  local missionsCap = math.max(240, h - 150)

  local meta = pack.meta
  local cy = top
  cy = cy + editorCard(app, colA, cy, colW) + gap
  cy = cy + basicsCard(app, colA, cy, colW) + gap
  cy = cy + lineList(app, "intro", colA, cy, colW, "开场白 intro", "开场白第一句…", math.min(rowsCap, 8)) + gap
  cy = cy + lineList(app, "outro", colA, cy, colW, "结束语 outro", "结束语…", math.min(rowsCap, 8)) + gap
  cy = cy + backgroundCard(app, colA, cy, colW) + gap
  cy = cy + currenciesCard(app, colA, cy, colW, math.min(rowsCap, 8)) + gap
  cy = cy + localizationCard(app, colA, cy, colW, math.min(rowsCap, 8))
  local ay = cy

  local by = twoCol and top or (ay + gap)
  by = by + missionsCard(app, colB, by, colW, missionsCap) + gap

  local previewH = 220
  ui.rect("fill", colB, by, colW, previewH, ui.theme.panel)
  ui.rect("line", colB, by, colW, previewH, ui.theme.border)
  ui.text(colB + 10, by + 8, "当前 pack.json 预览（滚轮上下 / Shift+滚轮 左右）",
    { font = "small", color = ui.theme.accent })
  local text, err = json.encodeSafe(meta, { indent = 2, keyOrder = Pack.PACK_KEY_ORDER })
  if text then
    local lines = ui.splitLines(text)
    local contentH = #lines * 17 + 6
    local contentW = 0
    for _, l in ipairs(lines) do
      contentW = math.max(contentW, ui.textW(l, "tiny") + 16)
    end
    ui.beginScroll("set.preview", colB + 8, by + 28, colW - 16, previewH - 36, contentH, contentW)
    for i, l in ipairs(lines) do
      ui.text(colB + 12, by + 30 + (i - 1) * 17, l, { font = "tiny", color = ui.theme.textDim })
    end
    ui.scrollContentHeight("set.preview", contentH)
    ui.endScroll()
  else
    ui.text(colB + 10, by + 30, "编码失败: " .. tostring(err), { font = "small", color = ui.theme.danger })
  end
  by = by + previewH

  ui.scrollContentHeight("settings", math.max(ay, by) - y + 24)
  ui.endScroll()
end

return Settings
