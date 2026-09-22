import io
p = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
src = open(p, encoding="utf-8").read().split("\n")
# lines are 0-indexed here; replace 2494..2732 (1-indexed) inclusive
start, end = 2494, 2732
assert "SINGLE-HYPOTHESIS TEST" in src[start-1], src[start-1]
assert "catch (Exception e) { Log.Error(\"BG TEST\", e); }" in src[end-1], src[end-1]

new = r'''            // ================= READ-ONLY PROBE =================
            // Everything here only OBSERVES. Earlier experiments (repainting materials, swapping
            // shaders, cloning the backdrop, overwriting the tree_background texture assets) all
            // failed to change the red backdrop, and two of them damaged unrelated UI and leaked
            // native memory. The one question that actually matters is "which renderer owns the
            // red pixels?", so ask that directly instead of guessing again.
            //
            // GATED ON THE TREE VIEW ACTUALLY EXISTING. Previous passes ran at a fixed tick and
            // could fire before the backdrop was instantiated. That invalidated at least one
            // conclusion: a disable pass reported "2 active backdrop layer(s)" but the fallback
            // path meant 'Dark Purple BG' may never have been disabled at all.
            if (_probeDone) return;
            if (!_backdropSeen)
            {
                foreach (var r0 in Resources.FindObjectsOfTypeAll<MeshRenderer>())
                {
                    if (r0 == null || !r0.gameObject.activeInHierarchy) continue;
                    if (r0.bounds.size.x > 1000f) { _backdropSeen = true; break; }
                }
                if (!_backdropSeen) return;              // tree view not up yet - keep waiting
                _probeAt = _ticks;
                Log.Info("PROBE: backdrop present at tick " + _ticks + ", letting it settle");
                return;
            }
            if (_ticks - _probeAt < 180) return;         // ~3s so the intro/camera settle
            _probeDone = true;
            try
            {
                var camP = Camera.main;
                Log.Info("PROBE: screen=" + Screen.width + "x" + Screen.height +
                         " cam='" + (camP != null ? camP.name : "none") + "' fov=" +
                         (camP != null ? camP.fieldOfView.ToString("F1") : "-") + " ortho=" +
                         (camP != null ? camP.orthographic.ToString() : "-"));

                // (1) EVERY large texture in memory. The earlier in-place overwrite only touched
                //     names containing "tree_background"; if the red art comes from a differently
                //     named texture it was never a candidate. This lists them all.
                int texN = 0;
                foreach (var t in Resources.FindObjectsOfTypeAll<Texture2D>())
                {
                    if (t == null || t.width < 512) continue;
                    Log.Info("PROBE tex '" + t.name + "' " + t.width + "x" + t.height +
                             " fmt=" + t.format + " readable=" + t.isReadable + " mips=" + t.mipmapCount);
                    if (++texN >= 40) break;
                }
                Log.Info("PROBE: " + texN + " large texture(s)");

                // (2) WHICH RENDERER OWNS THE PIXELS. Cast a ray from the camera through several
                //     screen points (two of which are red in the screenshots) and list every
                //     renderer whose bounds the ray crosses, nearest first. This works for every
                //     renderer type and needs no colliders, so it also covers whatever exotic
                //     thing is drawing the backdrop.
                float[] xs = { 0.20f, 0.35f, 0.50f, 0.65f, 0.80f };
                foreach (var fx in xs)
                {
                    if (camP == null) break;
                    var ray = camP.ScreenPointToRay(new Vector3(Screen.width * fx, Screen.height * 0.5f, 0f));
                    var hits = new List<Renderer>();
                    foreach (var r in Resources.FindObjectsOfTypeAll<Renderer>())
                    {
                        if (r == null || !r.gameObject.activeInHierarchy) continue;
                        if (r.bounds.IntersectRay(ray)) hits.Add(r);
                    }
                    hits.Sort((a, b) => Vector3.Distance(camP.transform.position, a.bounds.center)
                                        .CompareTo(Vector3.Distance(camP.transform.position, b.bounds.center)));
                    Log.Info("PROBE ray x=" + fx.ToString("F2") + " hits=" + hits.Count);
                    for (int i = 0; i < hits.Count && i < 8; i++)
                    {
                        var h = hits[i];
                        string tn = "-";
                        var hm = h as MeshRenderer; var hs = h as SpriteRenderer;
                        if (hm != null && hm.material != null && hm.material.mainTexture != null) tn = hm.material.mainTexture.name;
                        else if (hs != null && hs.sprite != null) tn = hs.sprite.name;
                        string hp = h.gameObject.name;
                        var tp = h.transform.parent;
                        for (int d = 0; d < 3 && tp != null; d++) { hp = tp.name + "/" + hp; tp = tp.parent; }
                        Log.Info("PROBE   #" + i + " " + h.GetType().Name + " '" + hp + "' tex=" + tn +
                                 " layer=" + h.gameObject.layer + " dist=" +
                                 Vector3.Distance(camP.transform.position, h.bounds.center).ToString("F0") +
                                 " sorting=" + h.sortingOrder);
                    }
                }
            }
            catch (Exception e) { Log.Error("PROBE", e); }'''.split("\n")

out = src[:start-1] + new + src[end:]
open(p, "w", encoding="utf-8").write("\n".join(out))
print("replaced", end-start+1, "lines with", len(new))
