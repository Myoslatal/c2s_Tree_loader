-- src/json.lua
-- A JSON encoder/decoder written from scratch for this editor.
-- No external libraries, no luajson, no LÖVE dependency (pure Lua 5.1 / 5.3+).
--
-- Design notes
--   * UTF-8 is passed through untouched. Only the mandatory characters are
--     escaped on output (quote, backslash, control bytes < 0x20).
--   * \uXXXX escapes are decoded (surrogate pairs included) into UTF-8 bytes.
--   * JSON null decodes to the sentinel json.null so that null values survive a
--     decode -> encode round trip instead of silently disappearing.
--   * Arrays are distinguished from objects with a metatable marker, so an
--     empty array stays [] while an empty object stays {}.
--   * The encoder is deterministic: keys are emitted in a caller supplied order
--     (opts.keyOrder), remaining keys alphabetically.
--
-- NOTE: this file deliberately contains no backslash escape sequences other
-- than the ones built from string.char, which keeps the source encoding-proof.

local json = {}

local CHAR = string.char
local BYTE = string.byte
local SUB = string.sub
local REP = string.rep
local FMT = string.format
local CONCAT = table.concat
local FLOOR = math.floor
local ABS = math.abs

local NL = CHAR(10)
local CR = CHAR(13)
local TAB = CHAR(9)
local BS = CHAR(92)   -- backslash
local QUOTE = CHAR(34)

json.NL = NL
json.BACKSLASH = BS

--- Sentinel for JSON null.
json.null = setmetatable({}, { __jsontype = "null", __tostring = function() return "null" end })

function json.isNull(v)
  return v == json.null
end

local ARRAY_MT = { __jsontype = "array" }
local OBJECT_MT = { __jsontype = "object" }

--- Mark a table so the encoder always emits it as a JSON array (even when empty).
--- Called with extra arguments it behaves like json.array(...) instead, so
--- markArray(a, b, c) can never silently drop b and c.
function json.markArray(t, ...)
  if select("#", ...) > 0 then
    return json.array(t, ...)
  end
  return setmetatable(t or {}, ARRAY_MT)
end

--- Mark a table so the encoder always emits it as a JSON object.
function json.markObject(t)
  return setmetatable(t or {}, OBJECT_MT)
end

--- Create a new empty array-marked table, optionally filled with the values.
function json.array(...)
  local t = setmetatable({}, ARRAY_MT)
  local n = select("#", ...)
  for i = 1, n do t[i] = select(i, ...) end
  return t
end

local function jsonType(t)
  local mt = getmetatable(t)
  if mt then return mt.__jsontype end
  return nil
end

function json.isArray(t)
  local jt = jsonType(t)
  if jt == "array" then return true end
  if jt == "object" or jt == "null" then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  if n == 0 then return false end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true
end

--------------------------------------------------------------------------------
-- Decoder
--------------------------------------------------------------------------------

local ESC_IN = {
  [QUOTE] = QUOTE,
  [BS] = BS,
  ["/"] = "/",
  ["b"] = CHAR(8),
  ["f"] = CHAR(12),
  ["n"] = NL,
  ["r"] = CR,
  ["t"] = TAB,
}

local function utf8Encode(cp)
  if cp < 0x80 then
    return CHAR(cp)
  elseif cp < 0x800 then
    return CHAR(0xC0 + FLOOR(cp / 0x40), 0x80 + (cp % 0x40))
  elseif cp < 0x10000 then
    return CHAR(0xE0 + FLOOR(cp / 0x1000), 0x80 + (FLOOR(cp / 0x40) % 0x40), 0x80 + (cp % 0x40))
  end
  return CHAR(0xF0 + FLOOR(cp / 0x40000), 0x80 + (FLOOR(cp / 0x1000) % 0x40),
              0x80 + (FLOOR(cp / 0x40) % 0x40), 0x80 + (cp % 0x40))
end

local function makeError(str, pos, msg)
  local line, col = 1, 1
  local limit = pos - 1
  if limit > #str then limit = #str end
  for i = 1, limit do
    if SUB(str, i, i) == NL then
      line = line + 1
      col = 1
    else
      col = col + 1
    end
  end
  return FMT("JSON error at line %d col %d: %s", line, col, msg)
end

local parseValue

local WHITESPACE = "[" .. CHAR(32) .. TAB .. NL .. CR .. "]"

local function skipSpace(str, i)
  local _, last = str:find("^" .. WHITESPACE .. "*", i)
  return (last or (i - 1)) + 1
end

local function parseString(str, i)
  -- str:sub(i,i) is the opening quote
  local out = {}
  local n = 0
  i = i + 1
  while true do
    local c = SUB(str, i, i)
    if c == "" then
      return nil, nil, "unterminated string"
    elseif c == QUOTE then
      return CONCAT(out), i + 1
    elseif c == BS then
      local e = SUB(str, i + 1, i + 1)
      local mapped = ESC_IN[e]
      if mapped then
        n = n + 1
        out[n] = mapped
        i = i + 2
      elseif e == "u" then
        local hex = SUB(str, i + 2, i + 5)
        if #hex < 4 or hex:find("[^0-9a-fA-F]") then
          return nil, nil, "invalid unicode escape"
        end
        local cp = tonumber(hex, 16)
        i = i + 6
        if cp >= 0xD800 and cp <= 0xDBFF then
          -- high surrogate: try to pair it with the following low surrogate
          if SUB(str, i, i + 1) == BS .. "u" then
            local hex2 = SUB(str, i + 2, i + 5)
            if #hex2 == 4 and not hex2:find("[^0-9a-fA-F]") then
              local lo = tonumber(hex2, 16)
              if lo >= 0xDC00 and lo <= 0xDFFF then
                cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                i = i + 6
              end
            end
          end
        end
        n = n + 1
        out[n] = utf8Encode(cp)
      else
        return nil, nil, "invalid escape sequence"
      end
    else
      -- consume a run of ordinary bytes at once
      local stop = str:find("[" .. QUOTE .. BS .. "]", i)
      if not stop then
        return nil, nil, "unterminated string"
      end
      n = n + 1
      out[n] = SUB(str, i, stop - 1)
      i = stop
    end
  end
end

local function parseNumber(str, i)
  local s, e = str:find("^-?%d+%.?%d*[eE][-+]?%d+", i)
  if not s then
    s, e = str:find("^-?%d+%.?%d*", i)
  end
  if not s then
    return nil, nil, "invalid number"
  end
  local text = SUB(str, s, e)
  local num = tonumber(text)
  if not num then
    return nil, nil, "invalid number '" .. text .. "'"
  end
  return num, e + 1
end

local function parseArray(str, i, depth)
  local arr = setmetatable({}, ARRAY_MT)
  local n = 0
  i = skipSpace(str, i + 1)
  if SUB(str, i, i) == "]" then
    return arr, i + 1
  end
  while true do
    local v, ni, err = parseValue(str, i, depth + 1)
    if err then return nil, nil, err end
    n = n + 1
    arr[n] = v
    i = skipSpace(str, ni)
    local c = SUB(str, i, i)
    if c == "," then
      i = skipSpace(str, i + 1)
    elseif c == "]" then
      return arr, i + 1
    else
      return nil, nil, "expected ',' or ']' in array"
    end
  end
end

local function parseObject(str, i, depth)
  local obj = setmetatable({}, OBJECT_MT)
  i = skipSpace(str, i + 1)
  if SUB(str, i, i) == "}" then
    return obj, i + 1
  end
  while true do
    if SUB(str, i, i) ~= QUOTE then
      return nil, nil, "expected string key in object"
    end
    local key, ni, err = parseString(str, i)
    if err then return nil, nil, err end
    i = skipSpace(str, ni)
    if SUB(str, i, i) ~= ":" then
      return nil, nil, "expected ':' after object key"
    end
    i = skipSpace(str, i + 1)
    local v
    v, ni, err = parseValue(str, i, depth + 1)
    if err then return nil, nil, err end
    obj[key] = v
    i = skipSpace(str, ni)
    local c = SUB(str, i, i)
    if c == "," then
      i = skipSpace(str, i + 1)
    elseif c == "}" then
      return obj, i + 1
    else
      return nil, nil, "expected ',' or '}' in object"
    end
  end
end

local MAX_DEPTH = 200

parseValue = function(str, i, depth)
  if depth > MAX_DEPTH then
    return nil, nil, "nesting too deep"
  end
  i = skipSpace(str, i)
  local c = SUB(str, i, i)
  if c == "" then
    return nil, nil, "unexpected end of input"
  elseif c == "{" then
    return parseObject(str, i, depth)
  elseif c == "[" then
    return parseArray(str, i, depth)
  elseif c == QUOTE then
    return parseString(str, i)
  elseif c == "t" then
    if SUB(str, i, i + 3) == "true" then return true, i + 4 end
    return nil, nil, "invalid literal"
  elseif c == "f" then
    if SUB(str, i, i + 4) == "false" then return false, i + 5 end
    return nil, nil, "invalid literal"
  elseif c == "n" then
    if SUB(str, i, i + 3) == "null" then return json.null, i + 4 end
    return nil, nil, "invalid literal"
  end
  return parseNumber(str, i)
end

--- Decode a JSON document. Returns (value) or (nil, errorMessage).
function json.decode(str)
  if type(str) ~= "string" then
    return nil, "JSON input is not a string"
  end
  -- strip a UTF-8 BOM if the file carries one
  if SUB(str, 1, 3) == CHAR(0xEF, 0xBB, 0xBF) then
    str = SUB(str, 4)
  end
  local ok, value, pos, err = pcall(function()
    local v, p, e = parseValue(str, 1, 0)
    return v, p, e
  end)
  if not ok then
    return nil, "JSON error: " .. tostring(value)
  end
  if err then
    return nil, makeError(str, pos or 1, err)
  end
  local i = skipSpace(str, pos)
  if i <= #str then
    return nil, makeError(str, i, "trailing content after JSON value")
  end
  return value
end

--- Decode, raising an error on failure (handy inside pcall).
function json.decodeOrError(str)
  local v, err = json.decode(str)
  if err then error(err, 2) end
  return v
end

--------------------------------------------------------------------------------
-- Encoder
--------------------------------------------------------------------------------

local ESC_OUT = {
  [BYTE(QUOTE)] = BS .. QUOTE,
  [BYTE(BS)] = BS .. BS,
  [8] = BS .. "b",
  [9] = BS .. "t",
  [10] = BS .. "n",
  [12] = BS .. "f",
  [13] = BS .. "r",
}

local function encodeString(s)
  local out = { QUOTE }
  local n = 1
  local plainStart = 1
  local len = #s
  for i = 1, len do
    local b = BYTE(s, i)
    if b < 32 or b == 34 or b == 92 then
      if i > plainStart then
        n = n + 1
        out[n] = SUB(s, plainStart, i - 1)
      end
      plainStart = i + 1
      n = n + 1
      out[n] = ESC_OUT[b] or (BS .. "u" .. FMT("%04x", b))
    end
  end
  if len >= plainStart then
    n = n + 1
    out[n] = SUB(s, plainStart, len)
  end
  n = n + 1
  out[n] = QUOTE
  return CONCAT(out)
end

local function encodeNumber(n)
  if n ~= n then
    error("cannot encode NaN", 0)
  end
  if n == math.huge or n == -math.huge then
    error("cannot encode infinity", 0)
  end
  if n == FLOOR(n) and ABS(n) < 1e15 then
    return FMT("%d", n)
  end
  local s = FMT("%.14g", n)
  if tonumber(s) ~= n then s = FMT("%.17g", n) end
  if tonumber(s) ~= n then s = FMT("%.20g", n) end
  return s
end

local function sortedKeys(t, opts)
  local keys = {}
  local rank
  if opts.keyOrder then
    rank = {}
    for i = 1, #opts.keyOrder do
      if rank[opts.keyOrder[i]] == nil then rank[opts.keyOrder[i]] = i end
    end
  end
  for k in pairs(t) do
    local tk = type(k)
    if tk == "string" then
      keys[#keys + 1] = k
    elseif tk == "number" then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta == "string" end
    if ta == "number" then return a < b end
    local ra = rank and rank[a]
    local rb = rank and rank[b]
    if ra and rb then return ra < rb end
    if ra then return true end
    if rb then return false end
    return a < b
  end)
  return keys
end

local encodeValue

encodeValue = function(v, opts, depth)
  local t = type(v)
  if v == nil or v == json.null then
    return "null"
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "number" then
    return encodeNumber(v)
  elseif t == "string" then
    return encodeString(v)
  elseif t ~= "table" then
    error("cannot encode value of type " .. t, 0)
  end

  local indent = opts.indent or 0
  local nl, pad, pad2 = "", "", ""
  if indent > 0 then
    nl = NL
    pad = REP(" ", indent * depth)
    pad2 = REP(" ", indent * (depth + 1))
  end

  if json.isArray(v) then
    local count = #v
    if count == 0 then return "[]" end
    local parts = {}
    for i = 1, count do
      parts[i] = pad2 .. encodeValue(v[i], opts, depth + 1)
    end
    return "[" .. nl .. CONCAT(parts, "," .. nl) .. nl .. pad .. "]"
  end

  local keys = sortedKeys(v, opts)
  if #keys == 0 then return "{}" end
  local parts = {}
  for i = 1, #keys do
    local k = keys[i]
    local keyText = type(k) == "number" and encodeString(tostring(k)) or encodeString(k)
    parts[i] = pad2 .. keyText .. ": " .. encodeValue(v[k], opts, depth + 1)
  end
  return "{" .. nl .. CONCAT(parts, "," .. nl) .. nl .. pad .. "}"
end

--- Encode a value to JSON text.
-- opts.indent   : spaces per level (default 2, 0 = compact)
-- opts.keyOrder : array of key names used as the preferred key order
function json.encode(value, opts)
  opts = opts or {}
  if opts.indent == nil then opts.indent = 2 end
  return encodeValue(value, opts, 0)
end

--- Encode without raising: returns (text) or (nil, errorMessage).
function json.encodeSafe(value, opts)
  local ok, res = pcall(json.encode, value, opts)
  if ok then return res end
  return nil, tostring(res)
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- Deep structural equality (metatables are ignored on purpose).
function json.deepEqual(a, b, path)
  path = path or "root"
  if a == b then return true end
  if a == json.null or b == json.null then return a == b end
  local ta, tb = type(a), type(b)
  if ta ~= tb then return false, path .. ": type " .. ta .. " ~= " .. tb end
  if ta ~= "table" then
    if ta == "number" then
      -- 1 and 1.0 must compare equal
      return a == b, path .. ": " .. tostring(a) .. " ~= " .. tostring(b)
    end
    return false, path .. ": " .. tostring(a) .. " ~= " .. tostring(b)
  end
  for k, v in pairs(a) do
    local ok, why = json.deepEqual(v, b[k], path .. "." .. tostring(k))
    if not ok then return false, why end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false, path .. "." .. tostring(k) .. ": missing on the left side"
    end
  end
  return true
end

--- Deep copy of a decoded JSON value (metatable markers are preserved).
function json.copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, val in pairs(v) do out[k] = json.copy(val) end
  local jt = jsonType(v)
  if jt == "array" then setmetatable(out, ARRAY_MT)
  elseif jt == "object" then setmetatable(out, OBJECT_MT) end
  return out
end

--- Read a file from an absolute path (plain io, works outside the LÖVE sandbox).
function json.readFile(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, "cannot open " .. tostring(path) .. ": " .. tostring(err) end
  local data = f:read("*a")
  f:close()
  if not data then return nil, "cannot read " .. tostring(path) end
  return data
end

--- Decode a JSON file from an absolute path. Returns (value) or (nil, error).
function json.decodeFile(path)
  local data, err = json.readFile(path)
  if not data then return nil, err end
  local value, derr = json.decode(data)
  if not value then return nil, tostring(path) .. ": " .. tostring(derr) end
  return value
end

--- Write text to an absolute path as UTF-8 without BOM.
function json.writeFile(path, text)
  local f, err = io.open(path, "wb")
  if not f then return nil, "cannot write " .. tostring(path) .. ": " .. tostring(err) end
  f:write(text)
  f:close()
  return true
end

return json
