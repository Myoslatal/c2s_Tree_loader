-- src/validate.lua
-- Pack validation. Every problem carries the offending node uid (when there is
-- one) so the UI can jump straight to it.

local Pack = require("src.pack")

local Validate = {}

local function add(list, level, msg, uid, field)
  list[#list + 1] = { level = level, msg = msg, uid = uid, field = field }
end

local function isBuiltinEffect(uid)
  for _, k in ipairs(Pack.BUILTIN_EFFECT_TARGETS) do
    if k == uid then return true end
  end
  return false
end

local function distanceFromStart(pack, node, startNode)
  if not startNode then return 0 end
  local dx = node.position.x - startNode.position.x
  local dy = node.position.y - startNode.position.y
  return math.sqrt(dx * dx + dy * dy)
end

--- Run every check. Returns problems (array), counts ({error,warn,info}).
function Validate.run(pack)
  local problems = {}
  local counts = { error = 0, warn = 0, info = 0 }

  if not pack then
    add(problems, "error", "没有打开任何活动包", nil, nil)
    counts.error = 1
    return problems, counts
  end

  local nodes = pack.tree.nodes
  local byUid = {}
  local startNode = nil

  if #nodes == 0 then
    add(problems, "error", "树里一个节点都没有（tree.json 的 nodes 为空）", nil, nil)
  end

  -- uid checks
  for i, n in ipairs(nodes) do
    if n.uid == nil or n.uid == "" then
      add(problems, "error", "第 " .. i .. " 个节点没有 uid", nil, "uid")
    elseif byUid[n.uid] then
      add(problems, "error", "uid 重复：" .. n.uid .. "（第二次出现在第 " .. i .. " 个节点）", n.uid, "uid")
    else
      byUid[n.uid] = n
    end
  end

  -- start node
  if pack.tree.startNode == nil or pack.tree.startNode == "" then
    add(problems, "warn", "没有设置 startNode（起始节点）", nil, "startNode")
  else
    startNode = byUid[pack.tree.startNode]
    if not startNode then
      add(problems, "error", "startNode 指向了不存在的节点：" .. pack.tree.startNode, nil, "startNode")
    end
  end

  -- when startNode is broken we still want the layout checks to mean something:
  -- fall back to the first node as the origin of the tree
  local origin = startNode or nodes[1]

  -- per node checks
  for _, n in ipairs(nodes) do
    local label = (n.uid ~= "" and n.uid) or ("(无 uid #" .. tostring(n) .. ")")
    local shown = n.title ~= "" and (n.title .. " [" .. label .. "]") or label

    if n.title == "" then
      add(problems, "warn", "节点没有标题：" .. label, n.uid, "title")
    end

    -- requirements
    local seenReq = {}
    for _, r in ipairs(n.requirements) do
      if r.requiredUid == "" then
        add(problems, "error", shown .. " 有一条前置连线没有填 requiredUid", n.uid, "requirements")
      elseif not byUid[r.requiredUid] then
        add(problems, "error", shown .. " 的前置指向了不存在的节点：" .. r.requiredUid, n.uid, "requirements")
      end
      if r.requiredUid == n.uid then
        add(problems, "warn", shown .. " 的前置指向了自己（自环）", n.uid, "requirements")
      end
      if seenReq[r.requiredUid] then
        add(problems, "warn", shown .. " 重复引用了同一个前置：" .. r.requiredUid, n.uid, "requirements")
      end
      seenReq[r.requiredUid] = true
      if (r.requiredCount or 0) > 0 then
        add(problems, "warn",
          shown .. " 的 requiredCount = " .. tostring(r.requiredCount) ..
          "（>0 时该节点在玩家拥有 " .. tostring(r.requiredCount) .. " 个前置之前完全不会出现；" ..
          "除非要做逐步解锁，否则一律写 0）", n.uid, "requiredCount")
      end
    end

    -- effects
    for _, e in ipairs(n.effects) do
      if e.targetUid == "" then
        add(problems, "warn", shown .. " 有一条特效没有填 targetUid", n.uid, "effects")
      elseif not byUid[e.targetUid] and not isBuiltinEffect(e.targetUid) then
        add(problems, "error", shown .. " 的特效指向了不存在的节点：" .. e.targetUid, n.uid, "effects")
      end
      if byUid[e.targetUid] == nil and isBuiltinEffect(e.targetUid) then
        -- built in effect keys are fine
      end
      if e.targetUid == n.uid then
        add(problems, "warn", shown .. " 的特效指向了自己：" .. e.targetUid, n.uid, "effects")
      end
    end

    -- layout
    if origin and n ~= origin then
      local d = distanceFromStart(pack, n, origin)
      if d > Pack.FAR_DISTANCE then
        add(problems, "warn", string.format("%s 距离起始节点 %.0f 个世界单位（超过 %d，很可能在屏幕外）",
          shown, d, Pack.FAR_DISTANCE), n.uid, "position")
      end
    end
    if n.position.y < 0 then
      add(problems, "warn", string.format("%s 的 y = %.0f 是负数：树会向下长，镜头上方会空掉", shown, n.position.y),
        n.uid, "position")
    end
    if math.abs(n.position.x) > 40 then
      add(problems, "info", string.format("%s 的 x = %.0f 超出建议范围 ±40（拖动时画面会左右乱跑）",
        shown, n.position.x), n.uid, "position")
    end
    if #n.requirements == 0 and n ~= origin then
      add(problems, "info", shown .. " 没有任何前置连线（孤立节点）", n.uid, "requirements")
    end

    -- icons
    if n.uid ~= "" and not Pack.iconExists(pack, n.uid) then
      add(problems, "info", shown .. " 缺少图标 icons/" .. n.uid .. ".png（游戏里会显示空白）", n.uid, "icon")
    end

    -- cost sanity
    local allZero = true
    for _, k in ipairs(Pack.COST_KEYS) do
      if (n.cost[k] or 0) ~= 0 then allZero = false break end
    end
    if allZero then
      add(problems, "info", shown .. " 的 cost 全是 0（免费节点）", n.uid, "cost")
    end
  end

  if #nodes > 60 then
    add(problems, "info", "节点数量较多（" .. #nodes .. " 个），游戏内可能需要大量拖动才能看全", nil, nil)
  end

  -- pack.json checks
  local meta = pack.meta or {}
  local currencyCount = tonumber(meta.currencyCount) or 0
  local currencies = type(meta.currencies) == "table" and meta.currencies or {}
  if currencyCount > 0 and #currencies > 0 and #currencies < currencyCount then
    add(problems, "warn", "pack.json 的 currencyCount = " .. currencyCount ..
      "，但 currencies 只定义了 " .. #currencies .. " 个", nil, "currencies")
  end
  if type(meta.title) ~= "string" or meta.title == "" then
    add(problems, "warn", "pack.json 缺少 title（活动标题）", nil, "title")
  end
  if type(meta.intro) ~= "table" or #meta.intro == 0 then
    add(problems, "info", "pack.json 没有写 intro 开场白（游戏会使用默认开场白）", nil, "intro")
  end

  if type(meta.missions) == "table" then
    -- Background image: the pack's single background (or the legacy array's first
    -- visible entry). Only the file's existence can go wrong now - there is no
    -- per-image scale/opacity/position any more.
    local bg = Pack.getBackground(pack)
    if bg then
      if not Pack.exists(Pack.join(pack.dir, bg)) then
        add(problems, "warn", string.format("背景图片不存在：%s（画布上不会显示背景）", bg),
          nil, "background")
      end
    end

    -- The panel shows one stage at a time; stages unlock in order
    if #meta.missions > 1 then
      local prog = Pack.missionProgression(meta)
      add(problems, "info", string.format(
        "包里写了 %d 个%s：任务面板一次只显示一个阶段，进入活动时是第 1 个阶段的 %d 个%s，" ..
        "完成当前阶段后自动进入下一个阶段",
        prog.rankCount, Pack.STAGE_WORD, prog.current and prog.current.cards or 0, Pack.ENTRY_WORD),
        nil, "missions")
    end
    for ri, rank in ipairs(meta.missions) do
      if type(rank) ~= "table" then
        add(problems, "error", "missions 第 " .. ri .. " 项不是对象", nil, "missions")
      else
        local rankTitle = tostring(rank.title or ("第 " .. ri .. " 组"))
        if type(rank.missions) ~= "table" or #rank.missions == 0 then
          add(problems, "warn", "任务组「" .. rankTitle .. "」里没有任何任务", nil, "missions")
        else
          -- the game shows one card per run of equal (prizeType, prizeID)
          local cards = Pack.countMissionCards(rank)
          local merged = Pack.mergedMissionRuns(rank)
          if #merged > 0 then
            local parts = {}
            for _, run in ipairs(merged) do
              parts[#parts + 1] = string.format("第 %d-%d 条（%s）", run.first, run.last,
                Pack.prizeLabel(run.prizeType, run.prizeID))
            end
            add(problems, "warn", string.format(
              "任务组「%s」写了 %d 条任务，但游戏里只会显示 %d 张卡片：%s 奖励相同且相邻，" ..
              "MissionController.RefreshMissionGroups() 会把它们并成一张卡",
              rankTitle, #rank.missions, cards, table.concat(parts, "、")), nil, "missions")
          end
          for mi, m in ipairs(rank.missions) do
            if type(m) ~= "table" then
              add(problems, "error", "任务组「" .. rankTitle .. "」第 " .. mi .. " 个任务不是对象", nil, "missions")
            else
              local where = "任务组「" .. rankTitle .. "」第 " .. mi .. " 个任务"
              local known = false
              for _, t in ipairs(Pack.MISSION_TYPES) do
                if t == m.type then known = true break end
              end
              if not known then
                add(problems, "warn", where .. " 的 type = " .. tostring(m.type) .. " 不是已知类型", nil, "missions")
              end
              local knownPrize = false
              for _, t in ipairs(Pack.PRIZE_TYPES) do
                if t == m.prizeType then knownPrize = true break end
              end
              if not knownPrize then
                add(problems, "warn", where .. " 的 prizeType = " .. tostring(m.prizeType) .. " 不是已知奖励", nil, "missions")
              end
              -- collect targets: accept the multi-target array and the flat pair
              local targets = Pack.missionTargets(m)
              for ti, t in ipairs(targets) do
                if t.item == "" then
                  add(problems, "warn", string.format("%s 的第 %d 个收集目标没有填 item", where, ti),
                    nil, "missions")
                elseif not byUid[t.item] then
                  add(problems, "warn", string.format(
                    "%s 的第 %d 个收集目标 item = %s 不是本包里的节点 uid（永远不会完成）",
                    where, ti, tostring(t.item)), nil, "missions")
                end
                if (t.amount or 0) <= 0 then
                  add(problems, "warn", string.format(
                    "%s 的第 %d 个收集目标 amount = %s（<= 0，永远不会完成）",
                    where, ti, tostring(t.amount)), nil, "missions")
                end
              end
            end
          end
        end
      end
    end
  end

  for _, p in ipairs(problems) do
    counts[p.level] = (counts[p.level] or 0) + 1
  end
  return problems, counts
end

return Validate
