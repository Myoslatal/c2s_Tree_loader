P = "_mod_tools/CustomEventPackEditor/src/graph.lua"
t = open(P, encoding="utf-8").read()

# 1. add the per-type radius helper
old = """function Graph:radius()
  return MAX(8, MIN(90, NODE_RADIUS_WORLD * self.zoom))
end"""
new = """function Graph:radius()
  return MAX(8, MIN(90, NODE_RADIUS_WORLD * self.zoom))
end

--- Radius for ONE node. Generators keep the full size; every other type is drawn at a
--- third of it, which is how the game renders them (measured in-game: a Generator's frame
--- circle is 6.798 world units across, a Research/Trophy node a third of that).
local NON_GENERATOR_SCALE = 1 / 3

function Graph:nodeRadius(node)
  local r = self:radius()
  if node and node.type and node.type ~= "Generator" then
    return MAX(3, r * NON_GENERATOR_SCALE)
  end
  return r
end"""
assert t.count(old) == 1, ("A", t.count(old))
t = t.replace(old, new)

# 2. hit testing must use the same per-node radius, or clicks land where nothing is drawn
old = """  local r = self:radius()
  local nodes = pack.tree.nodes
  for i = #nodes, 1, -1 do
    local n = nodes[i]
    local sx, sy = self:worldToScreen(n.position.x, n.position.y)"""
new = """  local nodes = pack.tree.nodes
  for i = #nodes, 1, -1 do
    local n = nodes[i]
    local r = self:nodeRadius(n)
    local sx, sy = self:worldToScreen(n.position.x, n.position.y)"""
assert t.count(old) == 1, ("B", t.count(old))
t = t.replace(old, new)

# 3. edges inset from each end by that end\'s own radius
old = """          local r = self:radius()
          local ux, uy = dx / len, dy / len
          local x1, y1 = sx + ux * r, sy + uy * r
          local x2, y2 = nx - ux * r, ny - uy * r"""
new = """          local rs = self:nodeRadius(src)
          local rt = self:nodeRadius(node)
          local ux, uy = dx / len, dy / len
          local x1, y1 = sx + ux * rs, sy + uy * rs
          local x2, y2 = nx - ux * rt, ny - uy * rt"""
assert t.count(old) == 1, ("C", t.count(old))
t = t.replace(old, new)

# 4. drawNode
old = """function Graph:drawNode(pack, node, selected, hovered, isStart)
  local sx, sy = self:worldToScreen(node.position.x, node.position.y)
  local r = self:radius()"""
new = """function Graph:drawNode(pack, node, selected, hovered, isStart)
  local sx, sy = self:worldToScreen(node.position.x, node.position.y)
  local r = self:nodeRadius(node)"""
assert t.count(old) == 1, ("D", t.count(old))
t = t.replace(old, new)

open(P, "w", encoding="utf-8").write(t)
print("node sizing: non-Generator at 1/3")