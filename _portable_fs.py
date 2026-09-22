import re

P = "_mod_tools/CustomEventPackEditor/src/pack.lua"
t = open(P, encoding="utf-8").read()

# 1. bring in LuaFileSystem (LÖVE bundles it)
old_head = "function Pack.basename(path)"
new_head = """-- LuaFileSystem. LOVE bundles it, and unlike a shell it also exists on Windows.
-- Everything below used to shell out (pwd / test -d / mkdir -p / ls -1ap / rm -rf). On Windows
-- those commands do not exist AND every single io.popen/os.execute made cmd.exe flash a console
-- window, so the editor spammed the screen with windows showing "test -d ..." and could not
-- create, list or delete anything.
local lfs = require("lfs")

Pack.lfs = lfs

function Pack.basename(path)"""
assert t.count(old_head) == 1
t = t.replace(old_head, new_head)

# 2. pwd -> lfs.currentdir()
old = """  local p = io.popen("pwd")
  if p then
    local dir = p:read("*l")
    p:close()
    if dir and dir ~= "" then candidates[#candidates + 1] = dir end
  end"""
new = """  local dir = lfs.currentdir()
  if dir and dir ~= "" then candidates[#candidates + 1] = dir end"""
assert t.count(old) == 1, ("pwd", t.count(old))
t = t.replace(old, new)

# 3. stat
old = """--- Returns "dir", "file" or nil.
function Pack.stat(path)
  if not path or path == "" then return nil end
  local p = io.popen("if [ -d " .. shellQuote(path) .. " ]; then echo dir; elif [ -f " .. shellQuote(path) .. " ]; then echo file; fi")
  if not p then return nil end
  local res = p:read("*l")
  p:close()
  if res == "dir" or res == "file" then return res end
  return nil
end"""
new = """--- Returns "dir", "file" or nil.
function Pack.stat(path)
  if not path or path == "" then return nil end
  local mode = lfs.attributes(path, "mode")
  if mode == "directory" then return "dir" end
  if mode == "file" then return "file" end
  return nil
end"""
assert t.count(old) == 1, ("stat", t.count(old))
t = t.replace(old, new)

# 4. mkdirp (lfs.mkdir only makes ONE level, so walk down)
old = """function Pack.mkdirp(path)
  if Pack.stat(path) == "dir" then return true end
  os.execute("mkdir -p " .. shellQuote(path))
  return Pack.stat(path) == "dir"
end"""
new = """function Pack.mkdirp(path)
  if Pack.stat(path) == "dir" then return true end
  if not path or path == "" then return false end
  path = tostring(path)
  local acc, i = "", 1
  local drive = path:match("^(%a:)[/\\\\]")        -- keep a Windows drive prefix
  if drive then acc = drive i = 3
  elseif path:sub(1, 1) == "/" then acc = "/" i = 2 end
  while i <= #path do
    local j = path:find("[/\\\\]", i)
    local part = j and path:sub(i, j - 1) or path:sub(i)
    if part ~= "" then
      acc = (acc == "" or acc == "/") and (acc .. part) or (acc .. "/" .. part)
      if lfs.attributes(acc, "mode") ~= "directory" then lfs.mkdir(acc) end
    end
    if not j then break end
    i = j + 1
  end
  return Pack.stat(path) == "dir"
end

--- Recursively delete a file or directory. Replaces `rm -rf`, which does not exist on Windows
--- and opened a console window on every call.
function Pack.removeTree(path)
  local mode = lfs.attributes(path, "mode")
  if mode == nil then return true end
  if mode == "directory" then
    for name in lfs.dir(path) do
      if name ~= "." and name ~= ".." then Pack.removeTree(Pack.join(path, name)) end
    end
    return lfs.rmdir(path) and true or false
  end
  return os.remove(path) ~= nil
end"""
assert t.count(old) == 1, ("mkdirp", t.count(old))
t = t.replace(old, new)

# 5. listDir
old = """  local p = io.popen("ls -1ap " .. shellQuote(path) .. " 2>/dev/null")
  if not p then return out end
  for line in p:lines() do
    if line ~= "" and line ~= "./" and line ~= "../" then
      local isDir = line:sub(-1) == "/"
      local name = isDir and line:sub(1, -2) or line
      out[#out + 1] = { name = name, path = Pack.join(path, name), dir = isDir }
    end
  end
  p:close()"""
new = """  local ok, iter, dir = pcall(lfs.dir, path)
  if not ok then return out end
  for name in iter, dir do
    if name ~= "." and name ~= ".." then
      local full = Pack.join(path, name)
      out[#out + 1] = { name = name, path = full,
                        dir = lfs.attributes(full, "mode") == "directory" }
    end
  end"""
assert t.count(old) == 1, ("listDir", t.count(old))
t = t.replace(old, new)
open(P, "w", encoding="utf-8").write(t)
print("pack.lua ported to lfs")