P = "_mod_tools/CustomEventPackEditor/src/pack.lua"
t = open(P, encoding="utf-8").read()

# replace the lfs-based header I added earlier with a LOVE-API based one
old = """-- LuaFileSystem. LOVE bundles it, and unlike a shell it also exists on Windows.
-- Everything below used to shell out (pwd / test -d / mkdir -p / ls -1ap / rm -rf). On Windows
-- those commands do not exist AND every single io.popen/os.execute made cmd.exe flash a console
-- window, so the editor spammed the screen with windows showing "test -d ..." and could not
-- create, list or delete anything.
local lfs = require("lfs")

Pack.lfs = lfs

function Pack.basename(path)"""
new = """-- ------------------------------------------------------------------ filesystem layer --
-- Everything here used to shell out (pwd / test -d / mkdir -p / ls -1ap / rm -rf). On Windows
-- those commands do not exist AND every io.popen/os.execute made cmd.exe flash a console window,
-- so the editor spammed the screen with windows showing "test -d ..." and could neither list,
-- create nor delete anything. Windows now goes through the LOVE API, which has no shell involved.
--
-- LOVE cannot be used unconditionally: love.filesystem.getInfo returns nil for paths outside the
-- game and save directories (probed), which is exactly where every user pack lives, so the POSIX
-- branch keeps the shell behaviour that the native test suite is written against.
local IS_WINDOWS = package.config:sub(1, 1) == "\\\\"
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

function Pack.basename(path)"""
assert t.count(old) == 1, ("header", t.count(old))
t = t.replace(old, new)

# remove my earlier stat override (the later definition would shadow the new one)
old_stat = """--- Returns "dir", "file" or nil.
function Pack.stat(path)
  if not path or path == "" then return nil end
  local mode = lfs.attributes(path, "mode")
  if mode == "directory" then return "dir" end
  if mode == "file" then return "file" end
  return nil
end

"""
assert t.count(old_stat) == 1, ("old stat", t.count(old_stat))
t = t.replace(old_stat, "")

# mkdirp
old_mk = t[t.index("function Pack.mkdirp(path)"):t.index("--- Recursively delete a file or directory.")]
new_mk = """function Pack.mkdirp(path)
  if Pack.stat(path) == "dir" then return true end
  if IS_WINDOWS then
    love.filesystem.createDirectory(path)   -- creates every missing parent level itself
    return Pack.stat(path) == "dir"
  end
  os.execute("mkdir -p " .. shellQuote(path))
  return Pack.stat(path) == "dir"
end

"""
t = t.replace(old_mk, new_mk)

# removeTree
old_rm = t[t.index("--- Recursively delete a file or directory."):t.index("--- List a directory:")]
new_rm = """--- Recursively delete a file or directory. Replaces `rm -rf`, which does not exist on Windows
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

"""
t = t.replace(old_rm, new_rm)

# listDir
old_ls = t[t.index('  local ok, iter, dir = pcall(lfs.dir, path)'):t.index('  table.sort(out, function(a, b)')]
new_ls = """  if IS_WINDOWS then
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
"""
t = t.replace(old_ls, new_ls)

# workspaceRoot pwd
t = t.replace('  local dir = lfs.currentdir()',
              '  local dir = IS_WINDOWS and love.filesystem.getSource() or io.popen("pwd") and io.popen("pwd"):read("*l")')

open(P, "w", encoding="utf-8").write(t)
print("pack.lua: hybrid filesystem layer installed")