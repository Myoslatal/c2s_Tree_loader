-- src/config.lua
-- Tiny persisted settings file (plain "key=value" lines) stored next to the app.
-- Deliberately dependency free so it also runs outside LÖVE.

local Config = {}

local function trim(s)
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Parse "key=value" text into a table. Values are converted to numbers when
--- they look numeric, otherwise kept as strings.
function Config.parse(text)
  local out = {}
  if type(text) ~= "string" then return out end
  for line in text:gmatch("[^" .. string.char(10) .. "]+") do
    local clean = trim(line)
    if clean ~= "" and clean:sub(1, 1) ~= "#" and clean:sub(1, 1) ~= ";" then
      local key, value = clean:match("^([%w_%.%-]+)%s*=%s*(.*)$")
      if key then
        value = trim(value)
        local num = tonumber(value)
        if num ~= nil then
          out[key] = num
        elseif value == "true" then
          out[key] = true
        elseif value == "false" then
          out[key] = false
        else
          out[key] = value
        end
      end
    end
  end
  return out
end

--- Serialize a table to "key=value" lines (keys sorted for stable diffs).
function Config.serialize(tbl)
  local keys = {}
  for k in pairs(tbl) do
    if type(k) == "string" then keys[#keys + 1] = k end
  end
  table.sort(keys)
  local lines = { "# CustomEventPackEditor settings (safe to delete)" }
  for _, k in ipairs(keys) do
    local v = tbl[k]
    if type(v) == "boolean" then v = v and "true" or "false" end
    if type(v) == "string" then v = v:gsub("[" .. string.char(10) .. "=]", " ") end
    lines[#lines + 1] = k .. "=" .. tostring(v)
  end
  return table.concat(lines, string.char(10)) .. string.char(10)
end

function Config.load(path)
  local f = io.open(path, "rb")
  if not f then return {} end
  local text = f:read("*a")
  f:close()
  local ok, parsed = pcall(Config.parse, text)
  if not ok or type(parsed) ~= "table" then return {} end
  return parsed
end

function Config.save(path, tbl)
  local ok, text = pcall(Config.serialize, tbl)
  if not ok then return nil, text end
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(text)
  f:close()
  return true
end

--- Path of the settings file that lives next to the application.
function Config.defaultPath(appDir)
  return tostring(appDir) .. "/editor.cfg"
end

Config.MIN_SCALE = 0.75
Config.MAX_SCALE = 2.0

--- Clamp + snap a UI scale value to a sane step.
function Config.normalizeScale(v)
  v = tonumber(v) or 1
  v = math.floor(v * 100 + 0.5) / 100
  if v < Config.MIN_SCALE then v = Config.MIN_SCALE end
  if v > Config.MAX_SCALE then v = Config.MAX_SCALE end
  return v
end

return Config
