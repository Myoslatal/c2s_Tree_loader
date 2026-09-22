P = "_mod_tools/CustomEventPackEditor/src/ui.lua"
t = open(P, encoding="utf-8").read()

# record every widget that reports a click in this frame
old = """  local release = claimEvent("release", x, y, w, h, id)
  local clicked = false
  if release and ui.activeId == id then
    clicked = true
  end"""
new = """  local release = claimEvent("release", x, y, w, h, id)
  local clicked = false
  if release and ui.activeId == id then
    clicked = true
    -- DIAGNOSTIC: a single physical click must never activate two widgets. Record who
    -- reported a click and where the press landed, so endFrame can shout if it happens.
    ui.clickLog[#ui.clickLog + 1] = string.format("%s @press(%.0f,%.0f) ptr(%.0f,%.0f)",
      tostring(id), release.x, release.y, ui.mx, ui.my)
  end"""
assert t.count(old) == 1, ("A", t.count(old))
t = t.replace(old, new)

# reset the log each frame
old2 = "function ui.beginFrame(now)"
new2 = "function ui.beginFrame(now)\n  ui.clickLog = {}"
assert t.count(old2) == 1
t = t.replace(old2, new2)

# report at the end of the frame
old3 = "  ui.events = {}\n  ui.keys = {}"
new3 = """  if ui.clickLog and #ui.clickLog > 1 then
    print("[UI] ONE click activated " .. #ui.clickLog .. " widgets: " .. table.concat(ui.clickLog, " | "))
  end
  ui.events = {}
  ui.keys = {}"""
assert t.count(old3) == 1, ("C", t.count(old3))
t = t.replace(old3, new3)

# make sure the log exists before beginFrame ever runs
old4 = "ui.events = {}"
assert t.count(old4) == 1
t = t.replace(old4, "ui.events = {}\nui.clickLog = {}")
open(P, "w", encoding="utf-8").write(t)
print("click diagnostic added")