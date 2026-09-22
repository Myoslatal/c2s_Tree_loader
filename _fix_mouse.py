import re
P = "_mod_tools/CustomEventPackEditor/main.lua"
t = open(P, encoding="utf-8").read()

a = '''  if app:canvasAccepts(x, y) then
    if app.graph.bgMode then
      app:bgMousePressed(x, y, button)
    else
      app.graph:mousepressed(app, x, y, button)
    end
  end
end'''
b = '''  if app:canvasAccepts(x, y) then
    app.graph:mousepressed(app, x, y, button)
  end
end'''
assert t.count(a) == 1
t = t.replace(a, b)

a = '''  if app.graph.drag then
    app.graph:mousemoved(app, x, y, dx, dy)
  elseif app.graph.bgDrag then
    app:bgMouseMoved(x, y)
  elseif app:canvasAccepts(x, y) then
    if app.graph.bgMode then
      app:bgMouseMoved(x, y)
    else
      app.graph:mousemoved(app, x, y, dx, dy)
    end
  else'''
b = '''  if app.graph.drag then
    app.graph:mousemoved(app, x, y, dx, dy)
  elseif app:canvasAccepts(x, y) then
    app.graph:mousemoved(app, x, y, dx, dy)
  else'''
assert t.count(a) == 1
t = t.replace(a, b)

a = '''  if app.graph.drag then
    app.graph:mousereleased(app, x, y, button)
  elseif app.graph.bgDrag then
    app:bgMouseReleased(x, y, button)
  end
end'''
b = '''  if app.graph.drag then
    app.graph:mousereleased(app, x, y, button)
  end
end'''
assert t.count(a) == 1
t = t.replace(a, b)

open(P, "w", encoding="utf-8").write(t)
left = re.findall(r"bgMode|bgSelected|bgDrag|backgroundsRaw|backgroundAt|backgroundCount|addBackground|removeBackground|moveBackground|fitBackground|drawBackgroundPanel|backgroundPanelRect|toggleBackgroundMode|bgHit|bgMouse", t)
print("leftover:", left)
