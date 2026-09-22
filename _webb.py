import re
P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
t = open(P, encoding="utf-8").read()

old = '''					if (masterLteData.ltePrefabData != null)
					{
						lte_PrefabData2 = masterLteData.ltePrefabData.FirstOrDefault((Lte_PrefabData x) => x != null && x.treeData != null);
					}'''
new = '''					if (masterLteData.ltePrefabData != null)
					{
						// Borrow the JAMES WEBB event's scene so the custom event looks like an
						// official one. Falling back to "the first entry with tree data" gave the
						// fetus-womb presentation (red 'Pink Donut' backdrop), which is what the
						// whole custom-background hunt was fighting.
						lte_PrefabData2 = masterLteData.ltePrefabData.FirstOrDefault((Lte_PrefabData x) => x != null && x.lteName == "webb");
						if (lte_PrefabData2 != null)
						{
							Log.Info("template: using the James Webb event scene");
						}
						else
						{
							lte_PrefabData2 = masterLteData.ltePrefabData.FirstOrDefault((Lte_PrefabData x) => x != null && x.treeData != null);
							Log.Warn("template: no 'webb' prefab data, falling back to '" +
							         ((lte_PrefabData2 != null) ? lte_PrefabData2.lteName : "none") + "'");
						}
					}'''
assert t.count(old) == 1
t = t.replace(old, new)
open(P, "w", encoding="utf-8").write(t)
print("plugin: prefers the webb scene")

# stop calling the background/debug hook
Q = "_mod_tools/patches.txt"
pt = open(Q, encoding="utf-8").read()
lines = []
for l in pt.split("\n"):
    if l.strip().startswith("call") and "PatchHooks" in l and "Tick" in l:
        lines.append("# Retired together with custom-background support: this hook existed to run the")
        lines.append("# backdrop probe/repaint inside the game loop. The event now borrows the James Webb")
        lines.append("# scene instead, so nothing needs to run per frame.")
        lines.append("# " + l)
        continue
    lines.append(l)
open(Q, "w", encoding="utf-8").write("\n".join(lines))
print("patches.txt: Tick hook retired")
