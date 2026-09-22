-- src/fonts.lua
-- CJK capable font discovery + a small sized-font cache.
--
-- Discovery order (first hit that really contains CJK glyphs wins):
--   1. /mis/zh-cn.ttf
--   2. **/NotoSansCJK*.ttc
--   3. **/wqy*.ttc (also wqy*.ttf)
--   4. **/DroidSansFallback*.ttf
-- plus a few extra CJK families as a last resort before falling back to the
-- built-in LÖVE font (which cannot render Chinese).
--
-- Font files are read with plain io and wrapped in a FileData, because the
-- packs (and the fonts) live outside the LÖVE virtual filesystem sandbox.

local Fonts = {}

local CHAR = string.char
local NL = CHAR(10)

local SIZES = {
  tiny = 11,
  small = 13,
  body = 15,
  title = 18,
  big = 22,
  huge = 30,
}

Fonts.SIZES = SIZES
Fonts.path = nil          -- absolute path of the loaded font (nil = built-in)
Fonts.label = "built-in"
Fonts.hasCJK = false
Fonts.attempts = {}       -- diagnostics for the help overlay / status bar

local cache = {}
local fontData = nil
local baseFont = nil

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'" .. CHAR(34) .. "'" .. CHAR(34) .. "'") .. "'"
end

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

Fonts.exists = exists

local function popenLines(cmd)
  local out = {}
  -- Windows has no /dev/null, no POSIX font tools, and io.popen flashes a console window, so the
  -- shell based font scan is skipped there entirely; LOVE falls back to its own font handling.
  if package.config:sub(1, 1) == "\\" then return out end
  local p = io.popen(cmd .. " 2>/dev/null")
  if not p then return out end
  for raw in p:lines() do
    local line = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then out[#out + 1] = line end
  end
  p:close()
  return out
end

--- Test for a directory. The old version shelled out to `test -d`, which does not exist on
--- Windows and made a console window flash on every call. Pack.stat is the shared, shell-free
--- implementation; the local fallback keeps this module usable if it is ever loaded on its own.
local function isDir(path)
  local ok, Pack = pcall(require, "src.pack")
  if ok and Pack and Pack.stat then return Pack.stat(path) == "dir" end
  local f = io.open(path, "rb")
  if f then f:close() end
  return false
end

--- Glob-like search: find <root> -maxdepth 4 -iname <pattern>
local function glob(root, pattern)
  if not isDir(root) then return {} end
  return popenLines("find " .. shellQuote(root) .. " -maxdepth 4 -iname " .. shellQuote(pattern) .. " | sort | head -6")
end

local PATTERN_ORDER = {
  "NotoSansCJK*.ttc",
  "NotoSansCJK*.otf",
  "NotoSansCJK*.ttf",
  "NotoSansSC*.otf",
  "NotoSansSC*.ttf",
  "wqy*.ttc",
  "wqy*.ttf",
  "DroidSansFallback*.ttf",
  "DroidSansFallbackFull.ttf",
  "SourceHanSans*.ttc",
  "SourceHanSans*.otf",
  "NotoSerifCJK*.ttc",
  "uming*.ttc",
  "ukai*.ttc",
}

--- Build the ordered candidate list.
function Fonts.candidates()
  local list = {}
  local seen = {}
  local function add(p)
    if p and p ~= "" and not seen[p] then
      seen[p] = true
      list[#list + 1] = p
    end
  end

  -- 0. Windows first. Every root below this block is a POSIX path and the whole search runs
  -- through `find` and fc-list, so a Windows build found no CJK font at all and rendered every
  -- Chinese glyph as a box. These are the fonts Windows itself ships; Microsoft YaHei is present
  -- on every Windows 7+ install regardless of the display language, so it leads the list.
  if package.config:sub(1, 1) == "\\" then
    local windir = os.getenv("WINDIR") or "C:\\Windows"
    local dirs = { windir .. "\\Fonts" }
    local localApp = os.getenv("LOCALAPPDATA")
    if localApp then dirs[#dirs + 1] = localApp .. "\\Microsoft\\Windows\\Fonts" end
    local names = {
      "msyh.ttc", "msyh.ttf", "msyhbd.ttc",   -- Microsoft YaHei (Simplified)
      "simhei.ttf", "simsun.ttc",             -- SimHei / SimSun
      "Deng.ttf", "simkai.ttf", "simfang.ttf",
      "msjh.ttc", "msjhbd.ttc",               -- Microsoft JhengHei (Traditional)
    }
    for _, d in ipairs(dirs) do
      for _, n in ipairs(names) do add(d .. "\\" .. n) end
    end
  end

  -- 1. explicit path first
  add("/mis/zh-cn.ttf")

  -- 2..4. glob the well known font roots, in pattern priority order
  local roots = { "/usr/share/fonts", "/usr/local/share/fonts", "/usr/share/fonts/truetype" }
  local home = os.getenv("HOME")
  if home then
    roots[#roots + 1] = home .. "/.fonts"
    roots[#roots + 1] = home .. "/.local/share/fonts"
  end
  roots[#roots + 1] = "/mis"

  for _, pattern in ipairs(PATTERN_ORDER) do
    for _, root in ipairs(roots) do
      for _, p in ipairs(glob(root, pattern)) do add(p) end
    end
  end
  return list
end

local function fontHasCJK(font)
  local ok, res = pcall(function() return font:hasGlyphs("深海勘探活动") end)
  if ok then return res and true or false end
  -- very old LÖVE: probe the glyph width instead
  local ok2, w = pcall(function() return font:getWidth("深") end)
  return ok2 and w and w > 1 or false
end

--- Load the first usable CJK font. Safe to call once at startup.
function Fonts.load()
  Fonts.attempts = {}
  local candidates = Fonts.candidates()
  for _, path in ipairs(candidates) do
    local data = readFile(path)
    if data and #data > 0 then
      local ok, fd = pcall(love.filesystem.newFileData, data, path:match("[^/\\]+$") or "font.ttf")
      if ok and fd then
        local ok2, font = pcall(love.graphics.newFont, fd, SIZES.body)
        if ok2 and font then
          local cjk = fontHasCJK(font)
          Fonts.attempts[#Fonts.attempts + 1] = path .. (cjk and "  [CJK ok]" or "  [no CJK glyphs]")
          if cjk then
            fontData = fd
            Fonts.path = path
            Fonts.label = path:match("[^/\\]+$") or path
            Fonts.hasCJK = true
            cache[SIZES.body] = font
            return true
          end
        else
          Fonts.attempts[#Fonts.attempts + 1] = path .. "  [load failed]"
        end
      end
    end
  end
  Fonts.path = nil
  Fonts.label = "LÖVE built-in (no CJK)"
  Fonts.hasCJK = false
  return false
end

--- Get a Font object for a size in pixels (created on demand and cached).
function Fonts.get(size)
  size = math.floor(size + 0.5)
  if size < 6 then size = 6 end
  local cached = cache[size]
  if cached then return cached end
  local font
  if fontData then
    local ok, res = pcall(love.graphics.newFont, fontData, size)
    if ok then font = res end
  end
  if not font then
    if not baseFont then baseFont = love.graphics.newFont(size) end
    font = love.graphics.newFont(size)
  end
  cache[size] = font
  return font
end

--- Named size lookup: Fonts.named("body")
function Fonts.named(name)
  return Fonts.get(SIZES[name] or SIZES.body)
end

function Fonts.describe()
  if Fonts.hasCJK then
    return "font: " .. Fonts.label
  end
  return "font: built-in (CJK glyphs missing!)"
end

return Fonts
