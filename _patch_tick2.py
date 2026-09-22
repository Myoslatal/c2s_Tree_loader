p = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
src = open(p, encoding="utf-8").read().split("\n")
s = next(i for i,l in enumerate(src) if "READ-ONLY PROBE" in l)
e = next(i for i,l in enumerate(src) if 'catch (Exception e) { Log.Error("PROBE", e); }' in l)
print("replacing lines", s+1, "..", e+1)

new = r'''            // ================= EVENT BACKDROP =================
            // Shows the pack's background image inside the run.
            //
            // HOW THIS WAS FOUND - do NOT repeat the hunt:
            //   * The visible backdrop is NOT EventController.treeBG; that points at
            //     'hitBoxDragArea' (587x526) while the real one is 'Dark Purple BG' (1143x1026).
            //   * The scene layers several LTE_*_tree_background textures; replacing ALL of them
            //     changed nothing, and disabling both known backdrops changed nothing either.
            //   * The object that actually paints the red backdrop is 'Pink Donut': a MeshRenderer
            //     whose huge Circle mesh fills the view (bounds 133x124 against a ~44x73 unit
            //     visible area at its distance), textured 'Pink Donut' and tinted red by
            //     Unlit/VertexColorAlpha.
            //   * It was identified in ONE run by casting rays from the camera through the screen
            //     centre and listing every Renderer whose bounds they cross, nearest first. Guessing
            //     by object name / material name / texture name failed for many attempts; the ray
            //     probe is the technique that works. Reuse it if another event template differs.
            //
            // The fix overwrites the TEXTURE ASSET IN PLACE. Texture2D.LoadImage writes into the
            // existing texture object, so every holder - including the ones we cannot enumerate -
            // shows the pack art, while the shader, render queue and draw order stay untouched and
            // the tree nodes keep drawing on top. LoadImage also succeeds on isReadable=false
            // textures (verified), which is why this works on imported assets.
            //
            // GATED on the backdrop existing (it only appears after the intro cutscene) and BOUNDED
            // to a couple of passes: an earlier per-frame version leaked ~8 MB/s and crashed the box.
            if (_bgApplied) return;
            if (!_backdropSeen)
            {
                foreach (var r0 in Resources.FindObjectsOfTypeAll<MeshRenderer>())
                {
                    if (r0 == null || !r0.gameObject.activeInHierarchy) continue;
                    if (r0.bounds.size.x > 1000f) { _backdropSeen = true; break; }
                }
                if (!_backdropSeen) return;              // tree view not up yet - keep waiting
                _bgAt = _ticks;
                return;
            }
            if (_ticks - _bgAt < 180) return;            // let the intro/camera settle (~3s)
            _bgApplied = true;
            try
            {
                var packB = PackLoader.LastLoaded;
                string imgB = null;
                if (packB != null && packB.Backgrounds != null)
                    foreach (var b in packB.Backgrounds)
                        if (b.Visible && b.File != null && File.Exists(b.File)) { imgB = b.File; break; }
                if (imgB == null) return;

                byte[] bytesB = File.ReadAllBytes(imgB);
                // 'tree_background' covers the other event templates; 'pink donut' / the two circle
                // sprites are the fetus-womb template this event borrows its tree from.
                string[] targets = {
                    "tree_background", "pink donut", "fetus circle", "mother circle"
                };
                int okB = 0;
                foreach (var t in Resources.FindObjectsOfTypeAll<Texture2D>())
                {
                    if (t == null) continue;
                    string tn = t.name.ToLowerInvariant();
                    bool want = false;
                    foreach (var tg in targets) if (tn.Contains(tg)) { want = true; break; }
                    if (!want) continue;
                    // never touch sprite atlases or UI atlases
                    if (tn.StartsWith("sactx") || tn.Contains("atlas") || tn.Contains("sdf")) continue;
                    try
                    {
                        bool ok3 = t.LoadImage(bytesB);
                        Log.Info("BG: texture '" + t.name + "' " + t.width + "x" + t.height +
                                 " readable=" + t.isReadable + " -> " + (ok3 ? "REPLACED" : "returned false"));
                        if (ok3) okB++;
                    }
                    catch (Exception eB) { Log.Warn("BG: '" + t.name + "' failed: " + eB.Message); }
                }
                Log.Info("BG: applied the pack background to " + okB + " texture(s)");
            }
            catch (Exception e) { Log.Error("BG", e); }'''.split("\n")

out = src[:s] + new + src[e+1:]
open(p, "w", encoding="utf-8").write("\n".join(out))
print("done, now", len(out), "lines")
