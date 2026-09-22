P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
t = open(P, encoding="utf-8").read()
lines = t.split("\n")
start = next(i for i, l in enumerate(lines) if l.strip() == "public static void HideBackdrop()")
# find the closing brace of the method by depth counting
depth = 0
end = None
for i in range(start, len(lines)):
    depth += lines[i].count("{") - lines[i].count("}")
    if i > start and depth == 0:
        end = i
        break
assert end is not None
new_method = """\tpublic static void HideBackdrop()
\t{
\t\t_ticks++;
\t\t// Sweep CONTINUOUSLY instead of once. The old version latched a static bool the first
\t\t// time it ran, but leaving and re-entering the event builds a NEW backdrop, so the
\t\t// second visit kept its background. Keyed off unscaled time so the sweep rate does not
\t\t// change with the (unlocked) framerate.
\t\tfloat now = Time.unscaledTime;
\t\tif (now < _bgNextSweep) return;
\t\t_bgNextSweep = now + 1f;
\t\ttry
\t\t{
\t\t\tstring[] backdropTex = new string[2] { "pink donut", "tree_background" };
\t\t\tint n = 0;
\t\t\tforeach (Renderer r in Resources.FindObjectsOfTypeAll<Renderer>())
\t\t\t{
\t\t\t\tif (r == null || !r.gameObject.activeInHierarchy) continue;
\t\t\t\tif (r is LineRenderer) continue;      // never touch the connections
\t\t\t\tif (!r.enabled) continue;            // already off
\t\t\t\tstring tn = "";
\t\t\t\tMeshRenderer mr = r as MeshRenderer;
\t\t\t\tSpriteRenderer sr = r as SpriteRenderer;
\t\t\t\tif (mr != null && mr.material != null && mr.material.mainTexture != null) tn = mr.material.mainTexture.name.ToLowerInvariant();
\t\t\t\telse if (sr != null && sr.sprite != null) tn = sr.sprite.name.ToLowerInvariant();
\t\t\t\tif (tn == "") continue;
\t\t\t\t// NEVER match the tree own art: frameCircle / TileFrameLifeFormCircle are the node
\t\t\t\t// frames and icons, and matching those once buried the nodes behind the backdrop.
\t\t\t\tif (tn.Contains("frame") || tn.Contains("icon") || tn.Contains("node")) continue;
\t\t\t\tbool isBg = false;
\t\t\t\tforeach (string w in backdropTex) if (tn.Contains(w)) { isBg = true; break; }
\t\t\t\tif (!isBg) continue;
\t\t\t\tr.enabled = false;
\t\t\t\tn++;
\t\t\t}
\t\t\tif (n > 0) Log.Info("BACKDROP: disabled " + n + " background renderer(s) so nothing can cover the tree");
\t\t}
\t\tcatch (Exception e) { Log.Error("HideBackdrop", e); }
\t}"""
lines[start:end+1] = new_method.split("\n")
t = "\n".join(lines)
old_field = "\tprivate static bool _bgHidden;      // background switched off, once\n\tprivate static int _bgHideAt;"
assert t.count(old_field) == 1, t.count(old_field)
t = t.replace(old_field, "\tprivate static float _bgNextSweep;   // next backdrop sweep time")
open(P, "w", encoding="utf-8").write(t)
print("HideBackdrop is now a continuous sweep")