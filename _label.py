P = "_mod_tools/CustomEventPackEditor/src/settings.lua"
t = open(P, encoding="utf-8").read()
a = '  local cy = section("背景图 background", x, y, w, height,\n    "游戏内会用它替换原本的背景")\n'
b = '  local cy = section("背景图 background", x, y, w, height,\n    "暂未使用：游戏内不渲染背景")\n'
assert t.count(a) == 1, ("A", t.count(a))
t = t.replace(a, b)
a2 = '''  ui.text(x + 10, cy, rel or "（未设置：游戏内显示原本的背景）",
    { font = "tiny", color = rel and ui.theme.text or ui.theme.textFaint })
'''
b2 = '''  ui.text(x + 10, cy, rel or "（未设置）",
    { font = "tiny", color = rel and ui.theme.text or ui.theme.textFaint })
  ui.text(x + 10, cy + 15, "游戏内目前不渲染背景，树和连线画在纯色上最清晰",
    { font = "tiny", color = ui.theme.textFaint })
'''
assert t.count(a2) == 1, ("B", t.count(a2))
t = t.replace(a2, b2)
open(P, "w", encoding="utf-8").write(t)
print("settings.lua updated")
