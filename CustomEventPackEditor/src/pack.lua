-- src/pack.lua
-- The pack data model: directory discovery, tree.json / pack.json loading,
-- normalization into an editor friendly shape, mutation helpers and saving.
--
-- Everything here is pure Lua (io/os only) so it can also run under plain lua
-- for the head-less round trip test.

local json = require("src.json")

local Pack = {}

local CHAR = string.char
local BS = CHAR(92)
local NL = CHAR(10)

Pack.COST_KEYS = { "a", "b", "c", "d", "e", "f", "g", "h" }
Pack.TYPES = { "Generator", "Research", "Trophy" }
Pack.LINE_TYPES = { "NONE", "NORM", "THICK", "SPECIAL" }
Pack.MISSION_TYPES = { "Collect", "Spend", "Photo", "Cost", "Rank" }
Pack.PRIZE_TYPES = {
  "Lootbox", "Unlock", "Card", "Stardust", "DarkMatter", "Darwinium", "Doober",
  "Badge", "Entropy", "Leaderboard_currency", "Idea", "LevelPoint", "Metabit", "Knowledge",
}
Pack.TREE_TYPES = { "NONE", "EVO", "CIV" }
Pack.BUILTIN_EFFECT_TARGETS = { "effect_evo_tap", "effect_evo_offer" }

-- World unit layout constants (see CustomEvents/README.md)
Pack.ROW_STEP = 22          -- vertical distance between two rows
Pack.COL_STEP = 22          -- horizontal zig-zag offset
Pack.VIEW_W = 100           -- approximate in-game visible area, world units
Pack.VIEW_H = 58
Pack.FAR_DISTANCE = 150     -- "probably off screen" warning threshold

-- Deterministic key order for pretty printing (see json.encode opts.keyOrder)
Pack.TREE_KEY_ORDER = {
  "uid", "name", "title", "description", "type", "startNode", "gridView",
  "position", "cost", "production", "effects", "requirements", "nodes",
  "x", "y", "z",
  "a", "b", "c", "d", "e", "f", "g", "h",
  "targetUid", "prodBoost", "requiredUid", "requiredCount", "lineType", "hidden",
}

Pack.PACK_KEY_ORDER = {
  "id", "title", "subtitle", "tree", "icons", "currencyCount", "banner", "button",
  "intro", "outro", "currencies", "tapHint", "resourceName", "resourceIcon",
  "localization",
  "missions", "targetHrs", "treeData",
  "name", "icon",
  "type", "reqItemId", "reqAmount", "prizeType", "prizeAmount", "hidden", "treeType",
}

local NODE_ALIASES = {
  uid = true, id = true, key = true,
  title = true, description = true, desc = true,
  type = true, kind = true,
  position = true, cost = true, production = true,
  effects = true, requirements = true,
}

--------------------------------------------------------------------------------
-- Small filesystem helpers (plain io: packs live outside the LÖVE sandbox)
--------------------------------------------------------------------------------

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'" .. CHAR(34) .. "'" .. CHAR(34) .. "'") .. "'"
end
Pack.shellQuote = shellQuote

function Pack.join(a, b)
  if not a or a == "" then return b end
  if not b or b == "" then return a end
  if a:sub(-1) == "/" then return a .. b end
  return a .. "/" .. b
end

function Pack.dirname(path)
  return (tostring(path):gsub("/[^/]*$", ""))
end

-- ------------------------------------------------------------------ filesystem layer --
-- Everything here used to shell out (pwd / test -d / mkdir -p / ls -1ap / rm -rf). On Windows
-- those commands do not exist AND every io.popen/os.execute made cmd.exe flash a console window,
-- so the editor spammed the screen with windows showing "test -d ..." and could neither list,
-- create nor delete anything. Windows now goes through the LOVE API, which has no shell involved.
--
-- LOVE cannot be used unconditionally: love.filesystem.getInfo returns nil for paths outside the
-- game and save directories (probed), which is exactly where every user pack lives, so the POSIX
-- branch keeps the shell behaviour that the native test suite is written against.
local IS_WINDOWS = package.config:sub(1, 1) == "\\"
Pack.isWindows = IS_WINDOWS

--- "dir", "file" or nil, without ever spawning a process on Windows.
function Pack.stat(path)
  if not path or path == "" then return nil end
  if IS_WINDOWS then
    local info = love.filesystem.getInfo(path)
    if info then return info.type == "directory" and "dir" or "file" end
    local ok, items = pcall(love.filesystem.getDirectoryItems, path)
    if ok and type(items) == "table" and #items >= 0 and love.filesystem.getInfo(path) then
      return "dir"
    end
    local f = io.open(path, "rb")
    if f then f:close() return "file" end
    return nil
  end
  local p = io.popen("if [ -d " .. shellQuote(path) .. " ]; then echo dir; elif [ -f " .. shellQuote(path) .. " ]; then echo file; fi")
  if not p then return nil end
  local res = p:read("*l")
  p:close()
  if res == "dir" or res == "file" then return res end
  return nil
end

function Pack.basename(path)
  return (tostring(path):match("[^/]*$"))
end

--- Absolute path of the workspace root (the folder that holds CustomEvents/).
--- Prefers the process working directory, then the folder above the LÖVE game
--- directory, and finally whichever candidate really contains CustomEvents/.
function Pack.workspaceRoot()
  local candidates = {}
  local dir = IS_WINDOWS and love.filesystem.getSource() or io.popen("pwd") and io.popen("pwd"):read("*l")
  if dir and dir ~= "" then candidates[#candidates + 1] = dir end
  if type(love) == "table" and love.filesystem and love.filesystem.getSource then
    local src = love.filesystem.getSource()
    if src then
      candidates[#candidates + 1] = src
      candidates[#candidates + 1] = Pack.dirname(Pack.dirname(src))
      candidates[#candidates + 1] = Pack.dirname(src)
    end
  end
  for _, c in ipairs(candidates) do
    if Pack.stat(Pack.join(c, "CustomEvents")) == "dir" then return c end
  end
  return candidates[1] or "."
end

function Pack.readFile(path)
  return json.readFile(path)
end

function Pack.writeFile(path, text)
  return json.writeFile(path, text)
end

function Pack.exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

function Pack.mkdirp(path)
  if Pack.stat(path) == "dir" then return true end
  if IS_WINDOWS then
    love.filesystem.createDirectory(path)   -- creates every missing parent level itself
    return Pack.stat(path) == "dir"
  end
  os.execute("mkdir -p " .. shellQuote(path))
  return Pack.stat(path) == "dir"
end

--- Recursively delete a file or directory. Replaces `rm -rf`, which does not exist on Windows
--- and opened a console window on every call.
function Pack.removeTree(path)
  if not IS_WINDOWS then
    if Pack.stat(path) == nil then return true end
    os.execute("rm -rf " .. shellQuote(path))
    return Pack.stat(path) == nil
  end
  local info = love.filesystem.getInfo(path)
  if not info then
    if io.open(path, "rb") then return os.remove(path) ~= nil end
    return true
  end
  if info.type == "directory" then
    local ok, items = pcall(love.filesystem.getDirectoryItems, path)
    if ok and type(items) == "table" then
      for _, name in ipairs(items) do Pack.removeTree(Pack.join(path, name)) end
    end
    return love.filesystem.remove(path) and true or false
  end
  return love.filesystem.remove(path) and true or false
end

--- List a directory: array of { name = <basename>, path = <full>, dir = <bool> }.
function Pack.listDir(path)
  local out = {}
  if not path or path == "" then return out end
  if IS_WINDOWS then
    local ok, items = pcall(love.filesystem.getDirectoryItems, path)
    if not ok or type(items) ~= "table" then return out end
    for _, name in ipairs(items) do
      local full = Pack.join(path, name)
      out[#out + 1] = { name = name, path = full, dir = Pack.stat(full) == "dir" }
    end
  else
    local p = io.popen("ls -1ap " .. shellQuote(path) .. " 2>/dev/null")
    if not p then return out end
    for line in p:lines() do
      if line ~= "" and line ~= "./" and line ~= "../" then
        local isDir = line:sub(-1) == "/"
        local name = isDir and line:sub(1, -2) or line
        out[#out + 1] = { name = name, path = Pack.join(path, name), dir = isDir }
      end
    end
    p:close()
  end
  table.sort(out, function(a, b)
    if a.dir ~= b.dir then return a.dir end
    return a.name:lower() < b.name:lower()
  end)
  return out
end

--- Binary-safe file copy (icons, background images). readFile/writeFile are
--- text helpers and would corrupt PNG bytes.
--- Image decoding from the REAL filesystem.
--- love.graphics.newImage only reads through love.filesystem (so a pack outside
--- the source/save directory can never be seen) and Pack.readFile is text-mode
--- (which corrupts PNG bytes). Both are why icons and background images never
--- loaded. Read the bytes ourselves and hand LÖVE decoded image data.
Pack.imageCache = {}
Pack.imageRoot = nil

--- Directory used to resolve pack-relative image paths (set when a pack opens).
function Pack.setImageRoot(dir)
  Pack.imageRoot = dir
  Pack.imageCache = {}
end

--- Load an image by absolute path, or by a path relative to the current pack.
--- Returns image or nil, reason; the real reason is printed once per path.
function Pack.loadImage(path)
  if type(path) ~= "string" or path == "" then return nil, "empty image path" end
  local abs = path
  if abs:sub(1, 1) ~= "/" then
    if not Pack.imageRoot then return nil, "no pack open for relative path " .. abs end
    abs = Pack.join(Pack.imageRoot, abs)
  end
  local cached = Pack.imageCache[abs]
  if cached then
    if cached.image then return cached.image end
    return nil, cached.err
  end
  local reason
  local f, oerr = io.open(abs, "rb")
  if not f then
    reason = string.format("cannot open %s (%s)", abs, tostring(oerr))
  else
    local bytes = f:read("*a")
    f:close()
    if not bytes or #bytes == 0 then
      reason = "empty file " .. abs
    else
      local ok, id = pcall(love.image.newImageData, bytes)
      if not ok or not id then
        local ok2, fd = pcall(love.filesystem.newFileData, bytes, Pack.basename(abs))
        if ok2 and fd then ok, id = pcall(love.image.newImageData, fd) end
      end
      if not ok or not id then
        reason = string.format("decode failed for %s: %s", abs, tostring(id))
      else
        local ok3, img = pcall(love.graphics.newImage, id)
        if not ok3 or not img then
          reason = string.format("newImage failed for %s: %s", abs, tostring(img))
        else
          img:setFilter("linear", "linear")
          Pack.imageCache[abs] = { image = img }
          return img
        end
      end
    end
  end
  Pack.imageCache[abs] = { err = reason }
  print("[image] " .. reason)
  return nil, reason
end

function Pack.copyFile(src, dst)
  local inp, err = io.open(src, "rb")
  if not inp then return nil, err or ("cannot open " .. tostring(src)) end
  local data = inp:read("*a")
  inp:close()
  if not data then return nil, "cannot read " .. tostring(src) end
  local out, werr = io.open(dst, "wb")
  if not out then return nil, werr or ("cannot write " .. tostring(dst)) end
  out:write(data)
  out:close()
  return true
end

--- Publish a pack directory as a .zip. Linux first ("先适配linux"), Windows later.
---
--- The archive must extract to a single <PackName>/ folder holding pack.json +
--- tree.json + assets - exactly the CustomEvents/<PackName>/ layout the plugin
--- loads, so dropping the extracted folder into CustomEvents/ just works. To get
--- that, `zip` runs from the pack's PARENT and zips the folder name, which stores
--- entries as <PackName>/tree.json instead of tree.json at the archive root.
---
--- Info-ZIP `zip` (present on every mainstream Linux); -X drops extra file
--- attributes so the archive is portable and reproducible. Returns (zipPath, nil)
--- on success, (nil, message) on failure.
function Pack.exportZip(srcDir, zipPath)
  if not srcDir or srcDir == "" then return nil, "未指定活动包目录" end
  if not zipPath or zipPath == "" then return nil, "未指定输出路径" end
  if Pack.stat(srcDir) ~= "dir" then return nil, "不是目录: " .. tostring(srcDir) end

  -- Refuse to write the archive inside the folder being archived: `zip` would try
  -- to include a file that is still growing and either duplicate or truncate it.
  local function norm(s) return (tostring(s):gsub("/+", "/"):gsub("/$", "")) end
  local src, out = norm(srcDir), norm(zipPath)
  if out == src or out:sub(1, #src + 1) == src .. "/" then
    return nil, "输出路径不能位于活动包目录内"
  end

  local parent = Pack.dirname(src)
  local folder = Pack.basename(src)
  local outDir = Pack.dirname(zipPath)
  if outDir and outDir ~= "" then pcall(Pack.mkdirp, outDir) end

  -- rm -f first: `zip` appends to an existing archive instead of replacing it.
  local cmd = "cd " .. shellQuote(parent) .. " && rm -f " .. shellQuote(zipPath)
    .. " && zip -r -q -X " .. shellQuote(zipPath) .. " " .. shellQuote(folder)
    .. " 2>&1; printf 'rc=%s' \"$?\""
  local p = io.popen(cmd)
  if not p then return nil, "无法启动 zip" end
  local outText = p:read("*a") or ""
  p:close()
  local rc = outText:match("rc=(%d+)")
  if rc ~= "0" then
    local msg = outText:gsub("rc=%d+$", ""):gsub("%s+$", "")
    return nil, (msg ~= "" and msg or ("zip 退出码 " .. tostring(rc)))
  end
  if Pack.stat(zipPath) ~= "file" then return nil, "zip 未生成输出文件" end
  return zipPath, nil
end

--- Size of a file in bytes (nil when unreadable) - shown after a publish so the
--- user can see what they got without leaving the editor.
function Pack.fileSize(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local n = f:seek("end")
  f:close()
  return n
end

--- Standard roots scanned for packs. The workspace CustomEvents folder comes first.
function Pack.defaultRoots(root)
  root = root or Pack.workspaceRoot()
  local roots = {
    Pack.join(root, "CustomEvents"),
    Pack.join(root, "StreamingAssets/CustomEvents"),
  }
  local home = os.getenv("HOME")
  if home then
    roots[#roots + 1] = home .. "/.local/share/unity3d/Computer Lunch/Cell to Singularity/CustomEvents"
    roots[#roots + 1] = home .. "/.config/unity3d/Computer Lunch/Cell to Singularity/CustomEvents"
    roots[#roots + 1] = home .. "/AppData/LocalLow/Computer Lunch/Cell to Singularity/CustomEvents"
  end
  return roots
end

--------------------------------------------------------------------------------
-- Normalization
--------------------------------------------------------------------------------

local function num(v, default)
  if type(v) == "number" then return v end
  if type(v) == "string" then
    local n = tonumber(v)
    if n then return n end
  end
  return default or 0
end
Pack.toNumber = num

local function str(v, default)
  if type(v) == "string" then return v end
  if type(v) == "number" then return tostring(v) end
  return default or ""
end

local function bool(v, default)
  if type(v) == "boolean" then return v end
  if v == 0 or v == 1 then return v == 1 end
  return default and true or false
end

--- cost / production: accept a bare number (= a) or a partial a..h table and
--- always return the full a..h object.
function Pack.normalizeCurve(v)
  local out = {}
  if type(v) == "number" then
    out.a = v
  elseif type(v) == "table" then
    for _, k in ipairs(Pack.COST_KEYS) do out[k] = num(v[k], 0) end
  end
  for _, k in ipairs(Pack.COST_KEYS) do
    if out[k] == nil then out[k] = 0 end
  end
  return out
end

--- True when only the a field is non zero (used by the inspector UI).
function Pack.curveIsSimple(c)
  for i = 2, #Pack.COST_KEYS do
    if (c[Pack.COST_KEYS[i]] or 0) ~= 0 then return false end
  end
  return true
end

local function normalizePosition(v)
  local x, y, z = 0, 0, 0
  if type(v) == "table" then
    if v.x ~= nil or v.y ~= nil then
      x, y, z = num(v.x, 0), num(v.y, 0), num(v.z, 0)
    else
      x, y, z = num(v[1], 0), num(v[2], 0), num(v[3], 0)
    end
  end
  return { x = x, y = y, z = z }
end

local function normalizeType(v)
  local t = str(v, "Generator")
  for _, known in ipairs(Pack.TYPES) do
    if known:lower() == t:lower() then return known end
  end
  return "Generator"
end

local LINE_TYPE_BY_INDEX = { [0] = "NONE", [1] = "NORM", [2] = "THICK", [3] = "SPECIAL" }

local function normalizeLineType(v)
  if type(v) == "number" then return LINE_TYPE_BY_INDEX[v] or "NORM" end
  local t = str(v, "NORM"):upper()
  for _, known in ipairs(Pack.LINE_TYPES) do
    if known == t then return known end
  end
  return "NORM"
end
Pack.normalizeLineType = normalizeLineType

local function normalizeEffect(raw)
  local e = { targetUid = "", prodBoost = 1 }
  local extra = {}
  if type(raw) == "table" then
    e.targetUid = str(raw.targetUid or raw.target or raw.uid, "")
    local boost = raw.prodBoost
    if boost == nil then boost = raw.boost end
    if boost == nil then boost = raw.production end
    if boost == nil then boost = raw.multiplier end
    e.prodBoost = num(boost, 1)
    for k, v in pairs(raw) do
      if k ~= "targetUid" and k ~= "target" and k ~= "uid" and k ~= "prodBoost"
        and k ~= "boost" and k ~= "production" and k ~= "multiplier" then
        extra[k] = json.copy(v)
      end
    end
  end
  e.extra = extra
  return e
end

local function normalizeRequirement(raw)
  local r = { requiredUid = "", requiredCount = 0, lineType = "NORM", hidden = false }
  local extra = {}
  if type(raw) == "string" then
    -- shorthand: a bare uid string means "own 1 of it" in the game format
    r.requiredUid = raw
    r.requiredCount = 1
    r.fromShorthand = true
    return r
  end
  if type(raw) == "table" then
    r.requiredUid = str(raw.requiredUid or raw.uid or raw.requirement, "")
    r.requiredCount = num(raw.requiredCount or raw.count or raw.amount, 0)
    r.lineType = normalizeLineType(raw.lineType or raw.line)
    r.hidden = bool(raw.hidden, false)
    for k, v in pairs(raw) do
      if k ~= "requiredUid" and k ~= "uid" and k ~= "requirement" and k ~= "requiredCount"
        and k ~= "count" and k ~= "amount" and k ~= "lineType" and k ~= "line" and k ~= "hidden" then
        extra[k] = json.copy(v)
      end
    end
  end
  r.extra = extra
  return r
end

local function normalizeNode(raw, index)
  if type(raw) ~= "table" then
    return nil, "节点 #" .. index .. " 不是对象"
  end
  local node = {}
  node.uid = str(raw.uid or raw.id or raw.key, "")
  node.title = str(raw.title, "")
  node.description = str(raw.description or raw.desc, "")
  node.type = normalizeType(raw.type or raw.kind)
  node.position = normalizePosition(raw.position)
  node.cost = Pack.normalizeCurve(raw.cost)
  node.production = Pack.normalizeCurve(raw.production)
  node.effects = {}
  if type(raw.effects) == "table" then
    for _, e in ipairs(raw.effects) do
      node.effects[#node.effects + 1] = normalizeEffect(e)
    end
  end
  node.requirements = {}
  if type(raw.requirements) == "table" then
    for _, r in ipairs(raw.requirements) do
      node.requirements[#node.requirements + 1] = normalizeRequirement(r)
    end
  end
  local extra = {}
  for k, v in pairs(raw) do
    if not NODE_ALIASES[k] then extra[k] = json.copy(v) end
  end
  node.extra = extra
  return node
end

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

function Pack.resolveTreePath(dir, meta)
  local candidates = {}
  if meta and type(meta.tree) == "string" and meta.tree ~= "" then
    candidates[#candidates + 1] = Pack.join(dir, meta.tree)
  end
  candidates[#candidates + 1] = Pack.join(dir, "tree.json")
  candidates[#candidates + 1] = Pack.join(dir, "json.json")
  for _, path in ipairs(candidates) do
    if Pack.exists(path) then return path end
  end
  return nil
end

--- Load a pack directory. Returns (pack) or (nil, errorMessage).
function Pack.load(dir)
  if not dir or dir == "" then return nil, "包目录为空" end
  if Pack.stat(dir) ~= "dir" then return nil, "目录不存在: " .. tostring(dir) end

  local packPath = Pack.join(dir, "pack.json")
  local meta, hasMeta = nil, false
  if Pack.exists(packPath) then
    local decoded, err = json.decodeFile(packPath)
    if not decoded then
      return nil, "pack.json 解析失败: " .. tostring(err)
    end
    meta = decoded
    hasMeta = true
  end

  local treePath = Pack.resolveTreePath(dir, meta)
  local treeRaw, inline = nil, false
  if treePath then
    local decoded, err = json.decodeFile(treePath)
    if not decoded then
      return nil, "tree.json 解析失败: " .. tostring(err)
    end
    treeRaw = decoded
  elseif meta and type(meta.treeData) == "table" then
    treeRaw = meta.treeData
    inline = true
  else
    return nil, "找不到 tree.json（也没有内联 treeData）"
  end

  if type(treeRaw) ~= "table" then
    return nil, "tree.json 的顶层不是一个对象"
  end
  if type(treeRaw.nodes) ~= "table" then
    return nil, "tree.json 缺少 nodes 数组"
  end

  local pack = {
    dir = dir,
    treePath = treePath,
    packPath = packPath,
    hasMeta = hasMeta,
    meta = meta or json.markObject({}),
    inlineTree = inline,
    iconIndex = {},
    warnings = {},
    dirty = false,
  }

  local nodes = {}
  for i, raw in ipairs(treeRaw.nodes) do
    local node, err = normalizeNode(raw, i)
    if not node then
      return nil, err
    end
    if node.uid == "" then
      pack.warnings[#pack.warnings + 1] = "节点 #" .. i .. " 缺少 uid"
    end
    nodes[#nodes + 1] = node
  end

  local treeExtra = {}
  for k, v in pairs(treeRaw) do
    if k ~= "name" and k ~= "title" and k ~= "startNode" and k ~= "gridView" and k ~= "nodes" then
      treeExtra[k] = json.copy(v)
    end
  end

  pack.tree = {
    name = str(treeRaw.name, Pack.basename(dir)),
    title = str(treeRaw.title, ""),
    startNode = str(treeRaw.startNode, ""),
    gridView = bool(treeRaw.gridView, false),
    nodes = nodes,
    extra = treeExtra,
  }

  Pack.refreshIcons(pack)
  return pack
end

function Pack.newPack(dir, id, title, subtitle)
  if Pack.stat(dir) == "file" then
    return nil, "同名文件已存在: " .. dir
  end
  if not Pack.mkdirp(Pack.join(dir, "icons")) then
    return nil, "无法创建目录: " .. dir
  end
  id = (id and id ~= "") and id or Pack.basename(dir)
  title = (title and title ~= "") and title or id

  local startUid = id .. "_start"
  local tree = {
    name = id,
    title = title,
    startNode = startUid,
    gridView = false,
    nodes = json.array({
      uid = startUid,
      title = "起始节点",
      description = "",
      type = "Generator",
      position = { x = 0, y = 0, z = 0 },
      cost = Pack.normalizeCurve(10),
      production = Pack.normalizeCurve(1),
      effects = json.array(),
      requirements = json.array(),
    }),
  }
  local meta = json.markObject({
    id = id,
    title = title,
    subtitle = subtitle or "",
    tree = "tree.json",
    icons = "icons",
    currencyCount = 1,
    intro = json.array(),
    outro = json.array(),
    currencies = json.array(),
  })

  local ok, err = json.writeFile(Pack.join(dir, "tree.json"),
    json.encode(tree, { indent = 2, keyOrder = Pack.TREE_KEY_ORDER }) .. NL)
  if not ok then return nil, err end
  ok, err = json.writeFile(Pack.join(dir, "pack.json"),
    json.encode(meta, { indent = 2, keyOrder = Pack.PACK_KEY_ORDER }) .. NL)
  if not ok then return nil, err end

  return Pack.load(dir)
end

--------------------------------------------------------------------------------
-- Serialization
--------------------------------------------------------------------------------

function Pack.nodeToTable(node)
  local out = {}
  for k, v in pairs(node.extra or {}) do out[k] = json.copy(v) end
  out.uid = node.uid
  out.title = node.title
  out.description = node.description
  out.type = node.type
  out.position = { x = node.position.x, y = node.position.y, z = node.position.z }
  out.cost = Pack.normalizeCurve(node.cost)
  out.production = Pack.normalizeCurve(node.production)

  local effects = json.markArray({})
  for i, e in ipairs(node.effects) do
    local t = {}
    for k, v in pairs(e.extra or {}) do t[k] = json.copy(v) end
    t.targetUid = e.targetUid
    t.prodBoost = e.prodBoost
    effects[i] = t
  end
  out.effects = effects

  local reqs = json.markArray({})
  for i, r in ipairs(node.requirements) do
    local t = {}
    for k, v in pairs(r.extra or {}) do t[k] = json.copy(v) end
    t.requiredUid = r.requiredUid
    t.requiredCount = r.requiredCount
    t.lineType = r.lineType
    t.hidden = r.hidden
    reqs[i] = t
  end
  out.requirements = reqs
  return out
end

function Pack.treeToTable(pack)
  local t = {}
  for k, v in pairs(pack.tree.extra or {}) do t[k] = json.copy(v) end
  t.name = pack.tree.name
  t.title = pack.tree.title
  t.startNode = pack.tree.startNode
  t.gridView = pack.tree.gridView
  local nodes = json.markArray({})
  for i, n in ipairs(pack.tree.nodes) do nodes[i] = Pack.nodeToTable(n) end
  t.nodes = nodes
  return t
end

function Pack.encodeTree(pack)
  return json.encode(Pack.treeToTable(pack), { indent = 2, keyOrder = Pack.TREE_KEY_ORDER })
end

function Pack.encodeMeta(pack)
  return json.encode(pack.meta, { indent = 2, keyOrder = Pack.PACK_KEY_ORDER })
end

--- Write tree.json (and pack.json when there is anything to write).
function Pack.save(pack, targetDir)
  local dir = targetDir or pack.dir
  if targetDir then
    if not Pack.mkdirp(Pack.join(dir, "icons")) then
      return nil, "无法创建目录: " .. dir
    end
  end

  local treePath = pack.treePath and Pack.join(dir, Pack.basename(pack.treePath)) or Pack.join(dir, "tree.json")
  local ok, err = json.writeFile(treePath, Pack.encodeTree(pack) .. NL)
  if not ok then return nil, err end
  pack.treePath = treePath

  local metaPath = Pack.join(dir, "pack.json")
  if pack.hasMeta or next(pack.meta) ~= nil then
    ok, err = json.writeFile(metaPath, Pack.encodeMeta(pack) .. NL)
    if not ok then return nil, err end
    pack.hasMeta = true
    pack.packPath = metaPath
  end

  pack.dir = dir
  pack.dirty = false
  Pack.refreshIcons(pack)
  return true
end

--------------------------------------------------------------------------------
-- Lookup helpers
--------------------------------------------------------------------------------

function Pack.nodeIndex(pack, uid)
  if not uid or uid == "" then return nil end
  for i, n in ipairs(pack.tree.nodes) do
    if n.uid == uid then return i end
  end
  return nil
end

function Pack.nodeByUid(pack, uid)
  local i = Pack.nodeIndex(pack, uid)
  return i and pack.tree.nodes[i] or nil
end

function Pack.allUids(pack)
  local out = {}
  for _, n in ipairs(pack.tree.nodes) do out[#out + 1] = n.uid end
  return out
end

function Pack.nodeCount(pack)
  return #pack.tree.nodes
end

--- Unique, filesystem safe uid derived from a base string.
function Pack.uniqueUid(pack, base)
  base = tostring(base or "node")
  base = base:gsub("[%s/]+", "_")
  if base == "" then base = "node" end
  if not Pack.nodeByUid(pack, base) then return base end
  local i = 2
  while Pack.nodeByUid(pack, base .. "_" .. i) do i = i + 1 end
  return base .. "_" .. i
end

--- Next free "node_N" uid, skipping any that already exist.
function Pack.nextNodeUid(pack)
  local i = 1
  while Pack.nodeByUid(pack, "node_" .. i) do i = i + 1 end
  return "node_" .. i
end

function Pack.validUid(uid)
  if type(uid) ~= "string" or uid == "" then return false, "uid 不能为空" end
  if uid == "." or uid == ".." then return false, "uid 不能是 . 或 .." end
  if uid:find("/", 1, true) or uid:find(BS, 1, true) then return false, "uid 不能包含斜杠" end
  if uid:find("[%c]") then return false, "uid 不能包含控制字符" end
  if uid:sub(1, 1) == "." then return false, "uid 不能以点开头" end
  return true
end

--------------------------------------------------------------------------------
-- Icons
--------------------------------------------------------------------------------

--- Rebuild uid -> absolute icon path from the icons/ folder and the pack root.
function Pack.refreshIcons(pack)
  local index = {}
  local function scan(dir)
    for _, entry in ipairs(Pack.listDir(dir)) do
      if not entry.dir then
        local base, ext = entry.name:match("^(.*)%.([%w]+)$")
        if base then
          ext = ext:lower()
          if ext == "png" or ext == "jpg" or ext == "jpeg" then
            if index[base] == nil or ext == "png" then
              index[base] = entry.path
            end
          end
        end
      end
    end
  end
  scan(Pack.join(pack.dir, "icons"))
  scan(pack.dir)
  pack.iconIndex = index
  return index
end

function Pack.iconPath(pack, uid)
  return pack.iconIndex and pack.iconIndex[uid] or nil
end

function Pack.iconExists(pack, uid)
  return Pack.iconPath(pack, uid) ~= nil
end

--- Copy a chosen image file to icons/<uid>.<ext>. Returns (path) or (nil, err).
function Pack.assignIcon(pack, uid, srcPath)
  local ok, err = Pack.validUid(uid)
  if not ok then return nil, err end
  if not Pack.exists(srcPath) then return nil, "文件不存在: " .. tostring(srcPath) end
  local ext = tostring(srcPath):match("%.([%w]+)$")
  ext = ext and ext:lower() or "png"
  if ext ~= "png" and ext ~= "jpg" and ext ~= "jpeg" then
    return nil, "只支持 png / jpg / jpeg 图标"
  end
  local iconsDir = Pack.join(pack.dir, "icons")
  if not Pack.mkdirp(iconsDir) then return nil, "无法创建 icons 目录" end
  -- drop any other extension for this uid so the mapping stays unambiguous
  for _, other in ipairs({ "png", "jpg", "jpeg" }) do
    if other ~= ext then
      local stale = Pack.join(iconsDir, uid .. "." .. other)
      if Pack.exists(stale) then os.remove(stale) end
    end
  end
  local dst = Pack.join(iconsDir, uid .. "." .. ext)
  local wok, werr = Pack.copyFile(srcPath, dst)
  if not wok then return nil, werr end
  Pack.refreshIcons(pack)
  return dst
end

function Pack.removeIcon(pack, uid)
  local path = Pack.iconPath(pack, uid)
  if path then
    os.remove(path)
    Pack.refreshIcons(pack)
    return true
  end
  return false
end

--------------------------------------------------------------------------------
-- Mutation
--------------------------------------------------------------------------------

function Pack.defaultPosition(pack)
  local maxRow = -1
  for _, n in ipairs(pack.tree.nodes) do
    local r = math.floor(n.position.y / Pack.ROW_STEP + 0.5)
    if r > maxRow then maxRow = r end
  end
  local row = maxRow + 1
  if row <= 0 then return 0, 0 end
  local x = (row % 2 == 1) and -Pack.COL_STEP or Pack.COL_STEP
  return x, row * Pack.ROW_STEP
end

function Pack.addNode(pack, opts)
  opts = opts or {}
  local x, y = Pack.defaultPosition(pack)
  local uid = Pack.uniqueUid(pack, opts.uid or "node")
  local node = {
    uid = uid,
    title = opts.title or "新节点",
    description = "",
    type = opts.type or "Generator",
    position = { x = opts.x or x, y = opts.y or y, z = 0 },
    cost = Pack.normalizeCurve(opts.cost or 10),
    production = Pack.normalizeCurve(opts.production or ((opts.type or "Generator") == "Generator" and 1 or 0)),
    effects = {},
    requirements = {},
    extra = {},
  }
  if opts.afterUid and Pack.nodeByUid(pack, opts.afterUid) then
    node.requirements[1] = {
      requiredUid = opts.afterUid, requiredCount = 0, lineType = "NORM", hidden = false, extra = {},
    }
  end
  pack.tree.nodes[#pack.tree.nodes + 1] = node
  if pack.tree.startNode == "" then pack.tree.startNode = uid end
  pack.dirty = true
  return node
end

--- Remove a node and every reference to it. Returns a summary table.
function Pack.removeNode(pack, uid)
  local idx = Pack.nodeIndex(pack, uid)
  if not idx then return nil, "找不到节点: " .. tostring(uid) end
  table.remove(pack.tree.nodes, idx)
  local cleaned = { effects = 0, requirements = 0, wasStart = false }
  for _, n in ipairs(pack.tree.nodes) do
    local e = {}
    for _, eff in ipairs(n.effects) do
      if eff.targetUid == uid then cleaned.effects = cleaned.effects + 1 else e[#e + 1] = eff end
    end
    n.effects = e
    local r = {}
    for _, req in ipairs(n.requirements) do
      if req.requiredUid == uid then cleaned.requirements = cleaned.requirements + 1 else r[#r + 1] = req end
    end
    n.requirements = r
  end
  if pack.tree.startNode == uid then
    cleaned.wasStart = true
    pack.tree.startNode = pack.tree.nodes[1] and pack.tree.nodes[1].uid or ""
  end
  pack.dirty = true
  return cleaned
end

--- Rename a node uid: renames icons/<uid>.png and rewrites every reference.
function Pack.renameNode(pack, oldUid, newUid)
  if oldUid == newUid then return true end
  local node = Pack.nodeByUid(pack, oldUid)
  if not node then return nil, "找不到节点: " .. tostring(oldUid) end
  local ok, err = Pack.validUid(newUid)
  if not ok then return nil, err end
  if Pack.nodeByUid(pack, newUid) then return nil, "uid 已存在: " .. newUid end

  node.uid = newUid
  for _, n in ipairs(pack.tree.nodes) do
    for _, eff in ipairs(n.effects) do
      if eff.targetUid == oldUid then eff.targetUid = newUid end
    end
    for _, req in ipairs(n.requirements) do
      if req.requiredUid == oldUid then req.requiredUid = newUid end
    end
  end
  if pack.tree.startNode == oldUid then pack.tree.startNode = newUid end

  local renamed = {}
  for _, dir in ipairs({ Pack.join(pack.dir, "icons"), pack.dir }) do
    for _, ext in ipairs({ "png", "jpg", "jpeg" }) do
      local from = Pack.join(dir, oldUid .. "." .. ext)
      if Pack.exists(from) then
        local to = Pack.join(dir, newUid .. "." .. ext)
        if os.rename(from, to) then
          renamed[#renamed + 1] = Pack.basename(to)
        end
      end
    end
  end
  pack.dirty = true
  Pack.refreshIcons(pack)
  return true, renamed
end

--- Duplicate a node (new uid, offset position). Returns the new node.
function Pack.duplicateNode(pack, uid)
  local src = Pack.nodeByUid(pack, uid)
  if not src then return nil, "找不到节点: " .. tostring(uid) end
  local copy = json.copy(Pack.nodeToTable(src))
  local node = normalizeNode(copy, 0)
  node.uid = Pack.uniqueUid(pack, uid .. "_copy")
  node.position.x = node.position.x + Pack.COL_STEP
  node.title = src.title
  pack.tree.nodes[#pack.tree.nodes + 1] = node
  pack.dirty = true
  return node
end

--- Same as metaArray but for JSON objects (localization maps).
function Pack.metaObject(pack, key)
  local v = pack.meta[key]
  if type(v) ~= "table" then
    v = json.markObject({})
    pack.meta[key] = v
  elseif getmetatable(v) == nil and json.isArray(v) then
    json.markObject(v)
  end
  return v
end

--------------------------------------------------------------------------------
-- Mission cards
--------------------------------------------------------------------------------

--- The game (MissionController.RefreshMissionGroups) merges **consecutive**
--- missions that share BOTH prizeType and prizeID into a single task card, so N
--- missions can show up as fewer than N cards. Returns (cardCount, runs) where
--- each run is { first, last, prizeType, prizeID } (1-based mission indexes).
function Pack.countMissionCards(rank)
  local runs = {}
  if type(rank) ~= "table" or type(rank.missions) ~= "table" then return 0, runs end
  local prevKey
  for i, raw in ipairs(rank.missions) do
    local m = type(raw) == "table" and raw or {}
    local key = tostring(m.prizeType or "") .. "|" .. tostring(m.prizeID or "")
    if i == 1 or key ~= prevKey then
      runs[#runs + 1] = { first = i, last = i, prizeType = m.prizeType, prizeID = m.prizeID }
    else
      runs[#runs].last = i
    end
    prevKey = key
  end
  return #runs, runs
end

--- Only the runs that actually swallowed more than one mission.
function Pack.mergedMissionRuns(rank)
  local _, runs = Pack.countMissionCards(rank)
  local out = {}
  for _, run in ipairs(runs) do
    if run.last > run.first then out[#out + 1] = run end
  end
  return out
end

--- What the player actually sees. TWO independent rules make the editor's
--- numbers differ from the game:
---   A) the game only builds task cards for the CURRENT rank - MissionController
---      sets _missions = currentRank.missions and then calls
---      RefreshMissionGroups(), and ranks unlock one after another;
---   B) consecutive missions with equal (prizeType, prizeID) merge into one card.
--- Returns { rankCount, current = levels[1], levels = { {index, missions, cards, title}, ... } }
function Pack.missionProgression(meta)
  local ranks = (type(meta) == "table" and type(meta.missions) == "table") and meta.missions or {}
  local out = { rankCount = #ranks, levels = {} }
  for i, rank in ipairs(ranks) do
    local n = (type(rank) == "table" and type(rank.missions) == "table") and #rank.missions or 0
    out.levels[i] = {
      index = i,
      missions = n,
      cards = Pack.countMissionCards(rank),
      title = (type(rank) == "table" and type(rank.title) == "string") and rank.title or "",
    }
  end
  out.current = out.levels[1]
  return out
end

--- Wording used across the missions editor. A "任务阶段" is a rank in the pack
--- file; a "任务条目" is one entry the player sees on the mission panel. The
--- words 级 / 等级 are deliberately NOT used for stages, so the stage count can
--- never be mistaken for the panel count again.
Pack.STAGE_WORD = "任务阶段"
Pack.ENTRY_WORD = "任务条目"

--- The number the game's mission panel shows. UIRank.RefreshView() renders
--- "completed/RequiredMissionGroups()", and RequiredMissionGroups() is
--- missionGroups.Count - the CURRENT rank's task cards. The panel shows one
--- stage at a time and on entering the event that is stage 1, so the headline
--- number is countMissionCards(stages[1]). Later stages are played too: the
--- injector plugin advances MissionController to the next rank once the current
--- stage's groups are complete.
function Pack.missionPanelCount(meta)
  local prog = Pack.missionProgression(meta)
  if prog.rankCount == 0 then return 0 end
  return prog.current.cards
end

--- Exactly what the panel shows on entering the event, e.g.
---   "游戏中任务面板显示：2 个任务条目 (0/2)"
--- (0 = completed at event start, 2 = RequiredMissionGroups()).
function Pack.missionPanelText(meta)
  local cards = Pack.missionPanelCount(meta)
  return string.format("游戏中任务面板显示：%d 个%s (0/%d)", cards, Pack.ENTRY_WORD, cards)
end

--- Short explanation under the panel number. Deliberately contains NO totals -
--- only the panel number may be read as "what the game shows".
function Pack.missionPanelNote(meta)
  local prog = Pack.missionProgression(meta)
  if prog.rankCount == 0 then
    return "还没有任务阶段：任务面板上不会出现任何任务条目。"
  end
  return string.format(
    "任务面板一次只显示一个%s，面板上的条目 = 当前阶段里相邻且 prizeType 与 prizeID 都相同的任务" ..
    "合并后的数量（MissionController.RefreshMissionGroups）；完成当前阶段后进入下一个阶段。",
    Pack.STAGE_WORD)
end

--- Header line of one stage - every stage is played, in order:
---   "阶段 1 · 2 条任务 → 2 个任务条目（游戏中首先显示）"
---   "阶段 2 · 2 条任务 → 2 个任务条目（完成阶段 1 后进入）"
---   "阶段 3 · 2 条任务 → 2 个任务条目（完成阶段 2 后进入）"
function Pack.missionStageLabel(meta, index)
  local prog = Pack.missionProgression(meta)
  local lv = prog.levels[index]
  if not lv then return "" end
  local state = (index == 1) and "游戏中首先显示"
    or string.format("完成阶段 %d 后进入", index - 1)
  return string.format("阶段 %d · %d 条任务 → %d 个%s（%s）",
    index, lv.missions, lv.cards, Pack.ENTRY_WORD, state)
end

------------------------------------------------------------------------------- Background (pack-level SINGLE image, replaces the game's own backdrop)
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

--- Unique file name inside the pack's backgrounds/ folder.
function Pack.uniqueBackgroundName(pack, name)
  name = Pack.basename(name or "background.png")
  local base, ext = name:match("^(.*)%.([%w]+)$")
  base = base or name
  ext = ext or "png"
  local dir = Pack.join(pack.dir, Pack.BACKGROUNDS_DIR)
  local candidate, n = name, 1
  while Pack.exists(Pack.join(dir, candidate)) do
    n = n + 1
    candidate = string.format("%s_%d.%s", base, n, ext)
  end
  return candidate
end

--- Collect targets of one mission. Accepts the new multi-target syntax
---   "targets": [ { "item": "uid", "amount": 20 }, ... ]
--- as well as the legacy flat pair reqItemId / reqAmount. Always returns an
--- array with at least one entry (possibly empty strings/zeros) so the editor
--- can always show a row for it.
function Pack.missionTargets(m)
  local out = {}
  if type(m) ~= "table" then return { { item = "", amount = 0 } } end
  if type(m.targets) == "table" and #m.targets > 0 then
    for _, t in ipairs(m.targets) do
      if type(t) == "table" then
        out[#out + 1] = {
          item = tostring(t.item or t.uid or t.reqItemId or ""),
          amount = tonumber(t.amount or t.reqAmount) or 0,
        }
      end
    end
  end
  if #out == 0 then
    out[1] = { item = tostring(m.reqItemId or ""), amount = tonumber(m.reqAmount) or 0 }
  end
  return out
end

--- Write the target list back. ONE target keeps the legacy flat form
--- (reqItemId / reqAmount, no "targets" key) so existing packs are not rewritten;
--- TWO or more use the "targets" array and drop the flat fields. Missions the
--- user never edits are not touched at all.
function Pack.setMissionTargets(m, list)
  if type(m) ~= "table" then return end
  if #list >= 2 then
    local arr = json.markArray({})
    for i, t in ipairs(list) do
      arr[i] = json.markObject({ item = t.item or "", amount = t.amount or 0 })
    end
    m.targets = arr
    m.reqItemId = nil
    m.reqAmount = nil
  else
    local t = list[1] or { item = "", amount = 0 }
    m.reqItemId = t.item or ""
    m.reqAmount = t.amount or 0
    m.targets = nil
  end
end

--- How many collect targets a mission declares (>= 1).
function Pack.missionTargetCount(m)
  return #Pack.missionTargets(m)
end

--- Total collect targets across one stage's missions.
function Pack.stageTargetCount(rank)
  local n = 0
  if type(rank) == "table" and type(rank.missions) == "table" then
    for _, m in ipairs(rank.missions) do n = n + Pack.missionTargetCount(m) end
  end
  return n
end

--- Human readable prize identity used in warnings/tooltips.
function Pack.prizeLabel(prizeType, prizeID)
  local t = (prizeType == nil or prizeType == "") and "(无 prizeType)" or tostring(prizeType)
  if prizeID == nil or prizeID == "" then return t end
  return t .. "/" .. tostring(prizeID)
end

--- Ensure a pack.json structure exists and return a field, creating containers.
function Pack.metaArray(pack, key)
  local v = pack.meta[key]
  if type(v) ~= "table" then
    v = json.markArray({})
    pack.meta[key] = v
  elseif getmetatable(v) == nil and not json.isArray(v) then
    json.markArray(v)
  end
  return v
end

--------------------------------------------------------------------------------
-- Scanning
--------------------------------------------------------------------------------

--- Scan roots for pack folders. Returns an array of entries:
---   { dir, name, title, nodeCount, ok, err }
function Pack.scan(roots)
  local found, seen = {}, {}
  for _, root in ipairs(roots) do
    if Pack.stat(root) == "dir" then
      for _, entry in ipairs(Pack.listDir(root)) do
        local name = entry.name
        if entry.dir and name:sub(1, 1) ~= "_" and name:sub(1, 1) ~= "." and not seen[entry.path] then
          seen[entry.path] = true
          local item = { dir = entry.path, name = name, title = name, nodeCount = 0 }
          local pack, err = Pack.load(entry.path)
          if pack then
            item.ok = true
            item.title = pack.tree.title ~= "" and pack.tree.title or name
            item.nodeCount = #pack.tree.nodes
          else
            item.ok = false
            item.err = err
          end
          found[#found + 1] = item
        end
      end
    end
  end
  table.sort(found, function(a, b)
    if a.ok ~= b.ok then return a.ok end
    return a.name:lower() < b.name:lower()
  end)
  return found
end

return Pack
