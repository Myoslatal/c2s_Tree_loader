-- src/selftest.lua
-- Head-less test suite. Runs under plain lua AND under love --selftest.
--   * JSON decode -> encode -> decode deep equality on the bundled sample pack
--   * JSON edge cases (escapes, \u, surrogate pairs, numbers, empty containers)
--   * pack load / normalize / save / reload semantic round trip
--   * pack mutation helpers (add / rename / remove / references)
-- Prints PASS / FAIL lines and returns the number of failures.

local json = require("src.json")
local Pack = require("src.pack")

local Selftest = {}

local results = {}

local function check(name, ok, detail)
  results[#results + 1] = { name = name, ok = ok and true or false, detail = detail }
  if ok then
    print("PASS  " .. name)
  else
    print("FAIL  " .. name .. (detail and ("  --  " .. tostring(detail)) or ""))
  end
  return ok
end

local function checkEqual(name, a, b)
  local ok, why = json.deepEqual(a, b)
  return check(name, ok, why)
end

local function candidateDirs()
  local list = {}
  local source = nil
  if type(love) == "table" and love.filesystem and love.filesystem.getSource then
    source = love.filesystem.getSource()
  end
  if not source then
    local p = (Pack.lfs and io.open and nil) or nil -- replaced below
    if p then source = p:read("*l") p:close() end
  end
  if source then
    list[#list + 1] = source .. "/../../CustomEvents/SamplePack"
    list[#list + 1] = source .. "/../CustomEvents/SamplePack"
  end
  list[#list + 1] = "../../CustomEvents/SamplePack"
  list[#list + 1] = "../CustomEvents/SamplePack"
  list[#list + 1] = "CustomEvents/SamplePack"
  return list, source
end

local function findSample()
  local list = candidateDirs()
  for _, dir in ipairs(list) do
    if Pack.exists(Pack.join(dir, "tree.json")) then return dir end
  end
  return nil, list
end

local function appDir()
  if type(love) == "table" and love.filesystem and love.filesystem.getSource then
    return love.filesystem.getSource()
  end
  local p = (Pack.lfs and io.open and nil) or nil -- replaced below
  if p then
    local d = p:read("*l")
    p:close()
    return d
  end
  return "."
end

--------------------------------------------------------------------------------

local function testJSONBasics()
  -- scalars and containers
  checkEqual("json: scalars", json.decode('[1, 2.5, -3e2, true, false, null]'),
    { 1, 2.5, -300, true, false, json.null })
  checkEqual("json: nested object", json.decode('{"a":{"b":[1,{"c":"d"}]}}'),
    { a = { b = { 1, { c = "d" } } } })

  -- string escapes
  local escapes = json.decode('["line1' .. json.BACKSLASH .. 'nline2", "q' .. json.BACKSLASH ..
    json.BACKSLASH .. 'q", "tab' .. json.BACKSLASH .. 't!", "sl/ash"]')
  check("json: escape sequences", escapes[1] == "line1" .. json.NL .. "line2"
    and escapes[2] == "q" .. json.BACKSLASH .. "q"
    and escapes[3] == "tab" .. string.char(9) .. "!"
    and escapes[4] == "sl/ash",
    table.concat(escapes, " | "))

  -- \u escapes, including a surrogate pair
  local u = json.decode('["' .. json.BACKSLASH .. 'u6df1' .. json.BACKSLASH .. 'u6d77", "'
    .. json.BACKSLASH .. 'ud83c' .. json.BACKSLASH .. 'udf0a"]')
  check("json: backslash-u escapes", u[1] == "深海" and u[2] == "🌊",
    tostring(u[1]) .. " / " .. tostring(u[2]))

  -- UTF-8 passthrough
  local raw = '{"标题":"深海勘探","n":7}'
  local decoded = json.decode(raw)
  check("json: utf-8 passthrough", decoded["标题"] == "深海勘探" and decoded.n == 7)

  -- json.array(...) is a vararg constructor: json.array(a, b) -> [a, b]
  local built = json.array({ x = 1 }, { x = 2 })
  check("json: array constructor takes varargs", #built == 2 and built[1].x == 1 and built[2].x == 2,
    json.encode(built, { indent = 0 }))
  check("json: markArray with extra arguments keeps them all",
    #json.markArray({ x = 1 }, { x = 2 }, { x = 3 }) == 3 and json.isArray(json.markArray({ 1 }, { 2 })),
    json.encode(json.markArray({ x = 1 }, { x = 2 }), { indent = 0 }))
  check("json: single table element is not flattened",
    json.encode(json.array({ x = 1 }), { indent = 0 }) == '[{' .. json.NL .. '  "x": 1' .. json.NL .. '}]'
    or json.encode(json.array({ x = 1 }), { indent = 0 }) == '[{"x": 1}]',
    json.encode(json.array({ x = 1 }), { indent = 0 }))

  -- empty containers keep their identity
  local emptyA = json.decode('{"arr":[],"obj":{}}')
  local reA = json.encode(emptyA, { indent = 0 })
  check("json: empty array vs object", reA == '{"arr": [],"obj": {}}', reA)

  -- deterministic pretty printing
  local pretty = json.encode({ b = 1, a = { 2, 3 } }, { indent = 2 })
  check("json: pretty print", pretty == '{' .. json.NL .. '  "a": [' .. json.NL .. '    2,' ..
    json.NL .. '    3' .. json.NL .. '  ],' .. json.NL .. '  "b": 1' .. json.NL .. '}', pretty)

  -- number formatting round trips exactly
  local nums = { 0, 1, -1, 15, 0.5, -22.25, 1e15, 1 / 3, 12345678901234, 2 ^ 53 }
  local okNums = true
  local detail = nil
  for _, n in ipairs(nums) do
    local text = json.encode(n, { indent = 0 })
    local back = json.decode(text)
    if back ~= n then okNums = false detail = tostring(n) .. " -> " .. text .. " -> " .. tostring(back) end
  end
  check("json: number round trip", okNums, detail)

  -- malformed input must not raise
  local bad, err = json.decode('{"a": 1,}')
  check("json: rejects trailing comma", bad == nil and type(err) == "string", tostring(err))
  local bad2, err2 = json.decode('{"a" 1}')
  check("json: rejects missing colon", bad2 == nil and type(err2) == "string", tostring(err2))
  local bad3, err3 = json.decode("{")
  check("json: rejects truncated input", bad3 == nil and type(err3) == "string", tostring(err3))
  local never = json.decode("not json at all")
  check("json: rejects garbage", never == nil)
end

local function testRoundTripFile(path, label)
  local text, err = Pack.readFile(path)
  if not text then return check(label .. ": read", false, err) end
  local first, derr = json.decode(text)
  if not first then return check(label .. ": decode", false, derr) end
  local encoded, eerr = json.encodeSafe(first, { indent = 2 })
  if not encoded then return check(label .. ": encode", false, eerr) end
  local second, derr2 = json.decode(encoded)
  if not second then return check(label .. ": re-decode", false, derr2) end
  checkEqual(label .. ": decode -> encode -> decode deep equality", first, second)
  check(label .. ": encode is deterministic", json.encode(second, { indent = 2 }) == encoded)
  return true
end

local function testPackRoundTrip(sampleDir)
  local pack, err = Pack.load(sampleDir)
  if not check("pack: load sample", pack ~= nil, err) then return end
  check("pack: node count is 7", #pack.tree.nodes == 7, tostring(#pack.tree.nodes))
  check("pack: startNode", pack.tree.startNode == "deepsea_sonar", pack.tree.startNode)

  local sonar = Pack.nodeByUid(pack, "deepsea_sonar")
  check("pack: cost normalized to a..h", sonar ~= nil and sonar.cost.a == 15 and sonar.cost.h == 0
    and sonar.cost.d == 0, sonar and json.encode(sonar.cost, { indent = 0 }))
  check("pack: requirement defaults", sonar ~= nil and #sonar.requirements == 0)
  local rov = Pack.nodeByUid(pack, "deepsea_rov")
  check("pack: effect parsed", rov ~= nil and #rov.effects == 1 and rov.effects[1].targetUid == "deepsea_sonar"
    and rov.effects[1].prodBoost == 0.5)
  check("pack: requirement parsed", rov ~= nil and #rov.requirements == 1
    and rov.requirements[1].requiredCount == 0 and rov.requirements[1].lineType == "NORM")
  check("pack: icons indexed", Pack.iconExists(pack, "deepsea_sonar"),
    tostring(Pack.iconPath(pack, "deepsea_sonar")))

  -- encode stability without touching the original file
  local once = Pack.encodeTree(pack)
  local reparsed = json.decode(once)
  check("pack: encoded tree is valid json", reparsed ~= nil)
  local reloaded = { tree = nil }
  -- simulate save -> load by decoding the encoded text and re-encoding it
  local twice = json.encode(reparsed, { indent = 2, keyOrder = Pack.TREE_KEY_ORDER })
  checkEqual("pack: encode(decode(encode)) stable", json.decode(once), json.decode(twice))

  -- real write round trip inside a scratch directory
  local tmp = Pack.join(appDir(), "_selftest_tmp")
  if Pack.mkdirp(Pack.join(tmp, "icons")) then
    Pack.copyFile(Pack.join(sampleDir, "tree.json"), Pack.join(tmp, "tree.json"))
    Pack.copyFile(Pack.join(sampleDir, "pack.json"), Pack.join(tmp, "pack.json"))
    local copy, cerr = Pack.load(tmp)
    if check("pack: load scratch copy", copy ~= nil, cerr) then
      local beforeTree = Pack.encodeTree(copy)
      local beforeMeta = Pack.encodeMeta(copy)
      local ok, serr = Pack.save(copy)
      check("pack: save scratch copy", ok and true or false, serr)
      local reread, rerr = Pack.load(tmp)
      if check("pack: reload after save", reread ~= nil, rerr) then
        checkEqual("pack: tree semantically identical after save",
          json.decode(beforeTree), json.decode(Pack.encodeTree(reread)))
        checkEqual("pack: pack.json semantically identical after save",
          json.decode(beforeMeta), json.decode(Pack.encodeMeta(reread)))
      end
      -- file level checks: no BOM, valid utf-8, pretty printed
      local bytes = Pack.readFile(Pack.join(tmp, "tree.json")) or ""
      check("pack: saved file has no BOM", bytes:sub(1, 3) ~= string.char(0xEF, 0xBB, 0xBF))
      check("pack: saved file keeps chinese text", bytes:find("深海勘探", 1, true) ~= nil)
      check("pack: saved file is pretty printed", bytes:find(json.NL .. "  ", 1, true) ~= nil)
      check("pack: saved file ends with a newline", bytes:sub(-1) == json.NL)
    end
    Pack.removeTree(tmp)
  else
    check("pack: scratch dir", false, tmp)
  end
end

--- The "new pack" flow plus icon assignment, both writing to a scratch folder.
local function testNewPack(sampleDir)
  local tmp = Pack.join(appDir(), "_selftest_new")
  Pack.removeTree(tmp)
  local pack, err = Pack.newPack(tmp, "smokepack", "冒烟测试")
  if not check("newPack: creates a pack", pack ~= nil, err) then return end
  check("newPack: exactly one start node", #pack.tree.nodes == 1, tostring(#pack.tree.nodes))
  check("newPack: startNode points at that node", pack.tree.startNode == pack.tree.nodes[1].uid)
  check("newPack: tree.json on disk", Pack.exists(Pack.join(tmp, "tree.json")))
  check("newPack: pack.json on disk", Pack.exists(Pack.join(tmp, "pack.json")))
  check("newPack: icons/ folder on disk", Pack.stat(Pack.join(tmp, "icons")) == "dir")
  check("newPack: title survives a reload", (function()
    local again = Pack.load(tmp)
    return again ~= nil and again.tree.title == "冒烟测试"
  end)())

  -- add a node with the default row placement, save, reload
  local node = Pack.addNode(pack, { afterUid = pack.tree.startNode })
  check("newPack: addNode row 1 is y = 22", node.position.y == 22, tostring(node.position.y))
  Pack.save(pack)
  local reloaded = Pack.load(tmp)
  check("newPack: saved node survives a reload", reloaded ~= nil and #reloaded.tree.nodes == 2,
    reloaded and tostring(#reloaded.tree.nodes))

  -- icon assignment copies the file next to the pack
  local src = Pack.join(sampleDir, "icons/deepsea_sonar.png")
  local dst, ierr = Pack.assignIcon(reloaded, reloaded.tree.nodes[1].uid, src)
  check("newPack: assignIcon copies the png", dst ~= nil, ierr)
  check("newPack: icon is indexed after assignment",
    Pack.iconExists(reloaded, reloaded.tree.nodes[1].uid))
  check("newPack: icon file is a real png", (function()
    local data = Pack.readFile(dst)
    return data ~= nil and string.byte(data, 1) == 0x89 and data:sub(2, 4) == "PNG"
  end)())
  -- renaming the node must rename the icon with it
  local oldUid = reloaded.tree.nodes[1].uid
  Pack.renameNode(reloaded, oldUid, "renamed_start")
  check("newPack: rename moved the icon file",
    Pack.iconPath(reloaded, "renamed_start") ~= nil and Pack.iconPath(reloaded, oldUid) == nil,
    tostring(Pack.iconPath(reloaded, oldUid)) .. " / " .. tostring(Pack.iconPath(reloaded, "renamed_start")))
  check("newPack: removeIcon deletes it", Pack.removeIcon(reloaded, "renamed_start") == true
    and Pack.iconPath(reloaded, "renamed_start") == nil)
  Pack.removeTree(tmp)
end

local function testMutations(sampleDir)
  local pack = Pack.load(sampleDir)
  if not pack then return check("mutate: load", false) end
  local before = #pack.tree.nodes
  -- derive the expected row from the fixture instead of hard coding it
  local maxRow = -1
  for _, n in ipairs(pack.tree.nodes) do
    maxRow = math.max(maxRow, math.floor(n.position.y / Pack.ROW_STEP + 0.5))
  end
  local node = Pack.addNode(pack, { afterUid = "deepsea_abyss" })
  check("mutate: addNode appends", #pack.tree.nodes == before + 1)
  check("mutate: addNode default y = next row * 22", node.position.y == (maxRow + 1) * Pack.ROW_STEP,
    string.format("y=%s, expected %d", tostring(node.position.y), (maxRow + 1) * Pack.ROW_STEP))
  check("mutate: addNode lands above every existing node", (function()
    for _, n in ipairs(pack.tree.nodes) do
      if n ~= node and n.position.y >= node.position.y then return false end
    end
    return true
  end)())
  check("mutate: addNode links to selection", #node.requirements == 1
    and node.requirements[1].requiredUid == "deepsea_abyss"
    and node.requirements[1].requiredCount == 0)

  local newUid = node.uid
  local ok, err = Pack.renameNode(pack, newUid, "renamed_node")
  check("mutate: renameNode", ok and true or false, err)
  check("mutate: rename updated the node", Pack.nodeByUid(pack, "renamed_node") ~= nil)
  check("mutate: rename kept the count", #pack.tree.nodes == before + 1)

  -- references are rewritten
  local target = Pack.nodeByUid(pack, "renamed_node")
  Pack.addNode(pack, { uid = "referrer", x = 0, y = 400 })
  local referrer = Pack.nodeByUid(pack, "referrer")
  referrer.effects[1] = { targetUid = "renamed_node", prodBoost = 2, extra = {} }
  referrer.requirements[1] = { requiredUid = "renamed_node", requiredCount = 0, lineType = "NORM", hidden = false, extra = {} }
  Pack.renameNode(pack, "renamed_node", "final_node")
  check("mutate: rename rewrote effects", referrer.effects[1].targetUid == "final_node",
    referrer.effects[1].targetUid)
  check("mutate: rename rewrote requirements", referrer.requirements[1].requiredUid == "final_node",
    referrer.requirements[1].requiredUid)

  -- deletion cleans every reference
  local cleaned = Pack.removeNode(pack, "final_node")
  check("mutate: removeNode", cleaned ~= nil)
  check("mutate: remove cleaned references", #referrer.effects == 0 and #referrer.requirements == 0,
    json.encode({ effects = #referrer.effects, requirements = #referrer.requirements }, { indent = 0 }))
  check("mutate: removeNode dropped the node", Pack.nodeByUid(pack, "final_node") == nil)

  -- removing the start node re-points startNode
  Pack.removeNode(pack, "deepsea_sonar")
  check("mutate: startNode re-pointed", pack.tree.startNode ~= "" and pack.tree.startNode ~= "deepsea_sonar",
    pack.tree.startNode)
  check("mutate: uid validation rejects slashes", Pack.validUid("a/b") == false)
  check("mutate: uniqueUid avoids collisions", Pack.uniqueUid(pack, "deepsea_rov") == "deepsea_rov_2",
    Pack.uniqueUid(pack, "deepsea_rov"))
end

local function testValidation(sampleDir)
  local Validate = require("src.validate")

  -- the untouched sample must be clean
  local pack = Pack.load(sampleDir)
  local problems, counts = Validate.run(pack)
  check("validate: sample pack has no errors", counts.error == 0,
    json.encode({ problems = #problems }, { indent = 0 }))

  -- a deliberately broken pack must produce every kind of finding
  local function node(uid, x, y, reqs, effects)
    return {
      uid = uid, title = "T " .. uid, description = "", type = "Generator",
      position = { x = x or 0, y = y or 0, z = 0 },
      cost = Pack.normalizeCurve(1), production = Pack.normalizeCurve(1),
      effects = effects or {}, requirements = reqs or {}, extra = {},
    }
  end
  local broken = {
    dir = "/nonexistent/nowhere",
    iconIndex = {},
    meta = { title = "broken", intro = {}, currencies = { { name = "x" } }, currencyCount = 3,
      missions = { { title = "r", missions = { { type = "Nope", prizeType = "Nope", reqItemId = "ghost" } } } } },
    tree = {
      name = "broken", title = "broken", startNode = "ghost_start", gridView = false, extra = {},
      nodes = {
        node("dup", 0, 0),
        node("dup", 0, 22),
        node("", 0, 44),
        node("far", 0, 900, { { requiredUid = "ghost", requiredCount = 3, lineType = "NORM", hidden = false, extra = {} } }),
        node("selfref", 0, 66, { { requiredUid = "selfref", requiredCount = 0, lineType = "NORM", hidden = false, extra = {} } },
          { { targetUid = "ghost", prodBoost = 1, extra = {} } }),
      },
    },
  }
  local bproblems, bcounts = Validate.run(broken)
  check("validate: flags duplicate uids", bcounts.error > 0)
  check("validate: flags a missing startNode target", (function()
    for _, p in ipairs(bproblems) do
      if p.field == "startNode" and p.level == "error" then return true end
    end
    return false
  end)())
  check("validate: flags unknown requirement targets", (function()
    for _, p in ipairs(bproblems) do
      if p.uid == "far" and p.field == "requirements" then return true end
    end
    return false
  end)())
  check("validate: warns about requiredCount > 0", (function()
    for _, p in ipairs(bproblems) do
      if p.field == "requiredCount" then return true end
    end
    return false
  end)())
  check("validate: warns about nodes far from the start node", (function()
    for _, p in ipairs(bproblems) do
      if p.uid == "far" and p.field == "position" and p.level == "warn" then return true end
    end
    return false
  end)())
  check("validate: reports missing icons as info", bcounts.info > 0)
  check("validate: warns about the self reference", (function()
    for _, p in ipairs(bproblems) do
      if p.uid == "selfref" then return true end
    end
    return false
  end)())
  check("validate: checks pack.json missions", (function()
    for _, p in ipairs(bproblems) do
      if p.field == "missions" then return true end
    end
    return false
  end)())
  check("validate: nil pack does not crash", (function()
    local p, c = Validate.run(nil)
    return type(p) == "table" and c.error == 1
  end)())
end

--- Broken packs must produce an error message, never a crash.
local function testMalformed()
  local tmp = Pack.join(appDir(), "_selftest_bad")
  Pack.removeTree(tmp)
  Pack.mkdirp(tmp)

  local pack, err = Pack.load(Pack.join(tmp, "does_not_exist"))
  check("malformed: missing directory is rejected", pack == nil and type(err) == "string", err)

  pack, err = Pack.load(tmp)
  check("malformed: empty directory is rejected", pack == nil and type(err) == "string", err)

  Pack.writeFile(Pack.join(tmp, "tree.json"), '{ "nodes": [ { "uid": "a", } ] }')
  pack, err = Pack.load(tmp)
  check("malformed: invalid json is rejected with a message",
    pack == nil and type(err) == "string" and err:find("解析失败", 1, true) ~= nil, err)

  Pack.writeFile(Pack.join(tmp, "tree.json"), '{ "name": "x" }')
  pack, err = Pack.load(tmp)
  check("malformed: tree without nodes is rejected", pack == nil and type(err) == "string", err)

  Pack.writeFile(Pack.join(tmp, "tree.json"), '[1, 2, 3]')
  pack, err = Pack.load(tmp)
  check("malformed: array at the top level is rejected", pack == nil and type(err) == "string", err)

  Pack.writeFile(Pack.join(tmp, "tree.json"), '{ "nodes": [ 42, { "uid": "ok" } ] }')
  pack, err = Pack.load(tmp)
  check("malformed: non object node is rejected", pack == nil and type(err) == "string", err)

  -- a valid but odd tree still loads, with warnings instead of a crash
  Pack.writeFile(Pack.join(tmp, "tree.json"),
    '{ "nodes": [ { "uid": "a", "cost": 5, "position": [3, 4], "requirements": ["b"] } ] }')
  pack, err = Pack.load(tmp)
  check("malformed: scalar cost and array position are accepted", pack ~= nil, err)
  if pack then
    check("malformed: scalar cost becomes a..h", pack.tree.nodes[1].cost.a == 5
      and pack.tree.nodes[1].cost.h == 0)
    check("malformed: array position becomes x/y", pack.tree.nodes[1].position.x == 3
      and pack.tree.nodes[1].position.y == 4)
    check("malformed: string requirement means count 1",
      pack.tree.nodes[1].requirements[1].requiredCount == 1)
  end

  Pack.writeFile(Pack.join(tmp, "pack.json"), '{ broken')
  Pack.writeFile(Pack.join(tmp, "tree.json"), '{ "nodes": [] }')
  pack, err = Pack.load(tmp)
  check("malformed: broken pack.json is reported", pack == nil and type(err) == "string", err)

  Pack.removeTree(tmp)
end

--- The game's mission-card merge rule (MissionController.RefreshMissionGroups
--- merges CONSECUTIVE missions with equal prizeType AND prizeID).
local function testMissionCards()
  local function rank(list) return { title = "r", missions = list } end
  local function m(t, id, amount)
    return { type = "Collect", prizeType = t, prizeID = id, prizeAmount = amount or 1 }
  end

  local cards, runs = Pack.countMissionCards(rank({ m("A", "1"), m("A", "1"), m("B", "1"), m("A", "1") }))
  check("missions: A,A,B,A -> 3 cards", cards == 3, tostring(cards))
  check("missions: runs are reported in order",
    #runs == 3 and runs[1].first == 1 and runs[1].last == 2
    and runs[2].first == 3 and runs[2].last == 3 and runs[3].first == 4 and runs[3].last == 4,
    json.encode(runs, { indent = 0 }))
  check("missions: only merged runs are flagged", #Pack.mergedMissionRuns(rank(
    { m("A", "1"), m("A", "1"), m("B", "1"), m("A", "1") })) == 1)

  check("missions: same prizeType with a different prizeID does not merge",
    (Pack.countMissionCards(rank({ m("A", "1"), m("A", "2") }))) == 2)
  check("missions: same prizeID with a different prizeType does not merge",
    (Pack.countMissionCards(rank({ m("A", "1"), m("B", "1") }))) == 2)
  check("missions: missing prizeID counts as equal",
    (Pack.countMissionCards(rank({ m("A", nil), m("A", nil) }))) == 1)
  check("missions: four identical missions are one card",
    (Pack.countMissionCards(rank({ m("A", "1"), m("A", "1"), m("A", "1"), m("A", "1") }))) == 1)
  check("missions: no missions is zero cards", (Pack.countMissionCards(rank({}))) == 0)
  check("missions: a malformed rank is zero cards", (Pack.countMissionCards(nil)) == 0)
  -- Rule A: the game only ever shows ONE rank, so the headline number is the
  -- FIRST rank's card count - not the rank count and not the total missions.
  local meta = { missions = {
    { title = "a", missions = { m("A", "1"), m("B", "1") } },   -- 2 cards
    { title = "b", missions = { m("A", "1"), m("A", "1") } },   -- 1 card
    { title = "c", missions = { m("A", "1"), m("B", "1") } },   -- 2 cards
  } }
  local prog = Pack.missionProgression(meta)
  check("missions: progression reports every rank", prog.rankCount == 3 and #prog.levels == 3,
    tostring(prog.rankCount))
  check("missions: only the first rank is current at event start",
    prog.current == prog.levels[1] and prog.current.cards == 2, tostring(prog.current and prog.current.cards))
  check("missions: panel text is exactly the game's 0/N string",
    Pack.missionPanelText(meta) == "游戏中任务面板显示：2 个任务条目 (0/2)", Pack.missionPanelText(meta))
  check("missions: panel count is the first stage's entries, not stages or missions",
    Pack.missionPanelCount(meta) == 2 and Pack.missionPanelCount(meta) ~= prog.rankCount
    and Pack.missionPanelCount(meta) ~= 6, tostring(Pack.missionPanelCount(meta)))
  check("missions: stage labels never call a stage 级",
    Pack.missionStageLabel(meta, 1):find("级", 1, true) == nil
    and Pack.missionStageLabel(meta, 2):find("级", 1, true) == nil
    and Pack.missionStageLabel(meta, 3):find("级", 1, true) == nil,
    Pack.missionStageLabel(meta, 1) .. " | " .. Pack.missionStageLabel(meta, 2))
  check("missions: every stage is labelled as played, in order",
    Pack.missionStageLabel(meta, 1) == "阶段 1 · 2 条任务 → 2 个任务条目（游戏中首先显示）"
    and Pack.missionStageLabel(meta, 2) == "阶段 2 · 2 条任务 → 1 个任务条目（完成阶段 1 后进入）"
    and Pack.missionStageLabel(meta, 3) == "阶段 3 · 2 条任务 → 2 个任务条目（完成阶段 2 后进入）",
    Pack.missionStageLabel(meta, 1) .. " | " .. Pack.missionStageLabel(meta, 2) .. " | "
    .. Pack.missionStageLabel(meta, 3))
  check("missions: no label claims a stage will be dropped",
    Pack.missionStageLabel(meta, 2):find("不会", 1, true) == nil
    and Pack.missionPanelNote(meta):find("不会", 1, true) == nil,
    Pack.missionStageLabel(meta, 2) .. " | " .. Pack.missionPanelNote(meta))
  check("missions: the note carries no total that could be misread as the panel count",
    Pack.missionPanelNote(meta):find("共", 1, true) == nil
    and Pack.missionPanelNote(meta):find("级", 1, true) == nil
    and Pack.missionPanelNote(meta):find("阶段", 1, true) ~= nil,
    Pack.missionPanelNote(meta))
  check("missions: an empty pack still produces a panel line",
    Pack.missionPanelText({}) == "游戏中任务面板显示：0 个任务条目 (0/0)", Pack.missionPanelText({}))
  -- the bundled SamplePack is the fixture the user compares against the game
  local samplePack = Pack.load(Pack.join(appDir(), "../../CustomEvents/SamplePack"))
  if samplePack and type(samplePack.meta.missions) == "table" then
    local sprog = Pack.missionProgression(samplePack.meta)
    local stotal = 0
    for _, lv in ipairs(sprog.levels) do stotal = stotal + lv.missions end
    -- The bundled pack is edited over time, so derive the expectation from the
    -- file and assert the RULE; the strict "not the stage count / not the mission
    -- total" checks live on the synthetic pack above, where they are unambiguous.
    local samplePanel = Pack.missionPanelCount(samplePack.meta)
    local sampleStage1 = Pack.countMissionCards(samplePack.meta.missions[1])
    check("missions: SamplePack panel line matches stage 1's entry count",
      samplePanel == sampleStage1 and samplePanel > 0
      and Pack.missionPanelText(samplePack.meta)
        == string.format("游戏中任务面板显示：%d 个任务条目 (0/%d)", sampleStage1, sampleStage1),
      string.format("panel=%d stage1=%d stages=%d fileMissions=%d text=%s", samplePanel, sampleStage1,
        sprog.rankCount, stotal, Pack.missionPanelText(samplePack.meta)))
    check("missions: SamplePack panel count never exceeds the file's mission total",
      samplePanel <= stotal, string.format("panel=%d total=%d", samplePanel, stotal))
    check("missions: no SamplePack stage label uses 级",
      Pack.missionStageLabel(samplePack.meta, 1):find("级", 1, true) == nil
      and Pack.missionStageLabel(samplePack.meta, 2):find("级", 1, true) == nil
      and Pack.missionStageLabel(samplePack.meta, 3):find("级", 1, true) == nil,
      Pack.missionStageLabel(samplePack.meta, 2))
  end

  check("missions: prize labels are readable",
    Pack.prizeLabel("Darwinium", "5") == "Darwinium/5"
    and Pack.prizeLabel("Darwinium", nil) == "Darwinium"
    and Pack.prizeLabel(nil, nil) == "(无 prizeType)",
    Pack.prizeLabel("Darwinium", "5"))
end

--- Multi-target mission syntax + the flat/array save rule.
local function testMissionTargets()
  -- new syntax
  local multi = { type = "Collect", targets = {
    { item = "a", amount = 20 }, { item = "b", amount = 10 },
  }, prizeType = "Darwinium", prizeID = "5" }
  local t = Pack.missionTargets(multi)
  check("targets: multi-target array reads back in order",
    #t == 2 and t[1].item == "a" and t[1].amount == 20 and t[2].item == "b" and t[2].amount == 10,
    json.encode(t, { indent = 0 }))
  check("targets: target count", Pack.missionTargetCount(multi) == 2)

  -- legacy flat form
  local flat = { type = "Collect", reqItemId = "sonar", reqAmount = 20 }
  local f = Pack.missionTargets(flat)
  check("targets: flat form reads as a one-entry list",
    #f == 1 and f[1].item == "sonar" and f[1].amount == 20, json.encode(f, { indent = 0 }))
  check("targets: an empty mission still yields one row",
    #Pack.missionTargets({}) == 1 and Pack.missionTargets({})[1].item == "")

  -- alias tolerance
  local alias = { type = "Collect", targets = { { uid = "x", reqAmount = 3 } } }
  local at = Pack.missionTargets(alias)
  check("targets: aliases (uid/reqAmount) are accepted", at[1].item == "x" and at[1].amount == 3,
    json.encode(at, { indent = 0 }))

  -- save rule: 1 target stays flat, 2+ becomes an array
  local m = { type = "Collect", reqItemId = "old", reqAmount = 7 }
  Pack.setMissionTargets(m, { { item = "one", amount = 1 } })
  check("targets: one target saves back in the flat form",
    m.reqItemId == "one" and m.reqAmount == 1 and m.targets == nil,
    json.encode(m, { indent = 0 }))
  Pack.setMissionTargets(m, { { item = "one", amount = 1 }, { item = "two", amount = 2 } })
  check("targets: two targets save as a targets array and drop the flat fields",
    type(m.targets) == "table" and #m.targets == 2 and m.reqItemId == nil and m.reqAmount == nil,
    json.encode(m, { indent = 0 }))
  Pack.setMissionTargets(m, { { item = "one", amount = 1 } })
  check("targets: going back to one target restores the flat form",
    m.reqItemId == "one" and m.targets == nil, json.encode(m, { indent = 0 }))

  -- the bundled pack: stage 1's first mission uses 2 targets, and the card count
  -- still treats the whole mission as ONE card
  local pack = Pack.load(Pack.join(appDir(), "../../CustomEvents/SamplePack"))
  if pack and type(pack.meta.missions) == "table" then
    local stage1 = pack.meta.missions[1]
    local m1 = stage1.missions[1]
    check("targets: bundled stage-1 mission 1 has 2 targets",
      Pack.missionTargetCount(m1) == 2, tostring(Pack.missionTargetCount(m1)))
    check("targets: a 2-target mission is still ONE card",
      Pack.countMissionCards(stage1) == Pack.missionProgression(pack.meta).levels[1].cards,
      tostring(Pack.countMissionCards(stage1)))
    check("targets: stage target total covers every mission",
      Pack.stageTargetCount(stage1) >= 4, tostring(Pack.stageTargetCount(stage1)))
    -- re-encoding must not change the form of untouched missions
    local encoded = json.encode(pack.meta, { indent = 2, keyOrder = Pack.PACK_KEY_ORDER })
    local back = json.decode(encoded)
    local b1 = back.missions[1].missions[1]
    local b2 = back.missions[1].missions[2]
    check("targets: untouched multi-target mission keeps its array",
      type(b1.targets) == "table" and #b1.targets == 2 and b1.reqItemId == nil,
      json.encode(b1, { indent = 0 }))
    check("targets: untouched flat mission stays flat",
      b2.targets == nil and b2.reqItemId == m1.reqItemId or b2.reqItemId ~= nil,
      json.encode(b2, { indent = 0 }))
  end
end

--- editor.cfg parsing / clamping / persistence.
local function testConfig()
  local Config = require("src.config")

  local parsed = Config.parse("# comment" .. json.NL .. "ui_scale=1.25" .. json.NL ..
    "sidebar=false" .. json.NL .. "view=settings" .. json.NL .. "last_pack=/tmp/x" .. json.NL .. "broken line")
  check("config: parses key=value lines", parsed.ui_scale == 1.25 and parsed.sidebar == false
    and parsed.view == "settings" and parsed.last_pack == Pack.tempPath("x"),
    json.encode(parsed, { indent = 0 }))
  check("config: ignores comments and junk", parsed["# comment"] == nil)

  local text = Config.serialize({ ui_scale = 2, sidebar = true, view = "graph" })
  local again = Config.parse(text)
  check("config: serialize -> parse round trip", again.ui_scale == 2 and again.sidebar == true
    and again.view == "graph", text)

  check("config: scale is clamped to the supported range",
    Config.normalizeScale(0.1) == 0.75 and Config.normalizeScale(9) == 2.0
    and Config.normalizeScale(1.234) == 1.23 and Config.normalizeScale(nil) == 1,
    tostring(Config.normalizeScale(1.234)))

  local path = Pack.join(appDir(), "_selftest.cfg")
  os.remove(path)
  check("config: load of a missing file returns an empty table",
    next(Config.load(path)) == nil)
  local ok = Config.save(path, { ui_scale = 1.5, view = "settings" })
  check("config: saves to disk", ok == true)
  local back = Config.load(path)
  check("config: reloads what was saved", back.ui_scale == 1.5 and back.view == "settings",
    json.encode(back, { indent = 0 }))
  os.remove(path)
end

--------------------------------------------------------------------------------

--- Run every test. Returns the number of failures.
function Selftest.run()
  results = {}
  print("=== CustomEventPackEditor self test ===")
  local sampleDir, tried = findSample()
  if not sampleDir then
    check("locate ../CustomEvents/SamplePack", false, table.concat(tried or {}, " , "))
  else
    print("sample pack: " .. sampleDir)
    testJSONBasics()
    testRoundTripFile(Pack.join(sampleDir, "tree.json"), "tree.json")
    testRoundTripFile(Pack.join(sampleDir, "pack.json"), "pack.json")
    testPackRoundTrip(sampleDir)
    testMutations(sampleDir)
    testValidation(sampleDir)
    testNewPack(sampleDir)
    testMalformed()
    testConfig()
    testMissionCards()
    testMissionTargets()
  end
  local failed = 0
  for _, r in ipairs(results) do
    if not r.ok then failed = failed + 1 end
  end
  print(string.format("=== %d checks, %d failed ===", #results, failed))
  if failed == 0 then
    print("SELFTEST: PASS")
  else
    print("SELFTEST: FAIL")
  end
  return failed, #results
end

Selftest.results = function() return results end

return Selftest
