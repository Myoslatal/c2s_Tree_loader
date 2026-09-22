import re
P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
t = open(P, encoding="utf-8").read()

# a one-shot method on PatchHooks that pushes the backdrop behind everything
anchor = "\tpublic static class PatchHooks\n\t{\n"
assert t.count(anchor) == 1, t.count(anchor)
fields = anchor + '''\t\tprivate static bool _sunk;          // backdrop pushed behind the tree once
\t\tprivate static int _sinkAt;

'''
t = t.replace(anchor, fields)

# add the method just before 'public static void UnlockFramerate'
m = "\t\tpublic static void UnlockFramerate()"
assert t.count(m) == 1
method = '''\t\t/// <summary>
\t\t/// Push the event backdrop BEHIND everything else. Measured on the live scene:
\t\t/// LineConnection draws at sortingOrder -3, the nodes and arcs at 0..3, and the
\t\t/// backdrop ('Pink Donut', 'Dark Purple BG', the circle sprites) ALSO at 0. The
\t\t/// backdrop only loses the depth fight because it is semi-transparent, so the
\t\t/// connecting lines currently show through it. Give the backdrop a very low
\t\t/// sortingOrder and the lines are never covered again, whatever the art does.
\t\t/// Injected into EventController.Update.
\t\t/// </summary>
\t\tpublic static void SinkBackdrop()
\t\t{
\t\t\t_ticks++;
\t\t\tif (_sunk) return;
\t\t\tif (_ticks < 240) return;
\t\t\tif (_sinkAt == 0) { _sinkAt = _ticks; return; }          // let the tree come up
\t\t\tif (_ticks - _sinkAt < 180) return;
\t\t\t_sunk = true;
\t\t\ttry
\t\t\t{
\t\t\t\tstring[] backdropTex = new string[4] { "pink donut", "tree_background", "circle", "fetus" };
\t\t\t\tint n = 0;
\t\t\t\tforeach (Renderer r in Resources.FindObjectsOfTypeAll<Renderer>())
\t\t\t\t{
\t\t\t\t\tif (r == null || !r.gameObject.activeInHierarchy) continue;
\t\t\t\t\tif (r is LineRenderer) continue;                     // never touch the connections
\t\t\t\t\tstring tn = "";
\t\t\t\t\tMeshRenderer mr = r as MeshRenderer;
\t\t\t\t\tSpriteRenderer sr = r as SpriteRenderer;
\t\t\t\t\tif (mr != null && mr.material != null && mr.material.mainTexture != null) tn = mr.material.mainTexture.name.ToLowerInvariant();
\t\t\t\t\telse if (sr != null && sr.sprite != null) tn = sr.sprite.name.ToLowerInvariant();
\t\t\t\t\tif (tn == "") continue;
\t\t\t\t\tbool isBg = false;
\t\t\t\t\tforeach (string w in backdropTex) if (tn.Contains(w)) { isBg = true; break; }
\t\t\t\t\tif (!isBg) continue;
\t\t\t\t\tif (r.sortingOrder > -50) r.sortingOrder = -100;
\t\t\t\t\tn++;
\t\t\t\t}
\t\t\t\tLog.Info("BACKDROP: pushed " + n + " backdrop renderer(s) to sortingOrder -100 so the lines draw on top");
\t\t\t}
\t\t\tcatch (Exception e) { Log.Error("SinkBackdrop", e); }
\t\t}

'''
t = t.replace(m, method + m)
open(P, "w", encoding="utf-8").write(t)
print("SinkBackdrop added")

Q = "_mod_tools/patches.txt"
pt = open(Q, encoding="utf-8").read()
pt = pt.rstrip("\n") + "\n\n# Keep the event backdrop behind the tree so it can never cover the connection lines.\ncall EventController Update CustomEventPackPlugin CustomEventPack.PatchHooks SinkBackdrop\n"
open(Q, "w", encoding="utf-8").write(pt)
print("directive added")
