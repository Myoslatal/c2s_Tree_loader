import re
P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
t = open(P, encoding="utf-8").read()

# rename the concept: we are no longer reordering, we are hiding
t = t.replace("public static void SinkBackdrop()", "public static void HideBackdrop()")
t = t.replace('Log.Error("SinkBackdrop", e);', 'Log.Error("HideBackdrop", e);')

old = '''					if (r.sortingOrder > -50) r.sortingOrder = -100;
					if (r.sortingLayerName != "Default") r.sortingLayerName = "Default";
					n++;'''
new = '''					// Simply DO NOT RENDER it. Reordering only ever traded one occlusion for
					// another (sinking the backdrop once buried the node frames), and the art
					// is busy enough to swallow the connecting lines either way. With no
					// backdrop at all the tree reads perfectly.
					r.enabled = false;
					n++;'''
assert t.count(old) == 1, t.count(old)
t = t.replace(old, new)
t = t.replace('Log.Info("BACKDROP: pushed " + n + " backdrop renderer(s) to sortingOrder -100 so the lines draw on top");',
              'Log.Info("BACKDROP: disabled " + n + " background renderer(s) so nothing can cover the tree");')
open(P, "w", encoding="utf-8").write(t)
print("now hiding instead of reordering")

Q = "_mod_tools/patches.txt"
pt = open(Q, encoding="utf-8").read()
pt = pt.replace("CustomEventPack.PatchHooks SinkBackdrop", "CustomEventPack.PatchHooks HideBackdrop")
pt = pt.replace("# The event backdrop is drawn at the SAME sortingOrder (0) as the tree, and it only\n# stays out of the way because it is semi-transparent - so it can cover the connecting\n# lines. Push it far behind them, once, when the tree view is up.",
                "# The event backdrop is busy enough to swallow the connecting lines. Do not render it\n# at all; the tree reads perfectly against the camera's plain clear colour.")
open(Q, "w", encoding="utf-8").write(pt)
print("directive updated:", "HideBackdrop" in pt)
