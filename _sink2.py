P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
t = open(P, encoding="utf-8").read()

old = '''				string[] backdropTex = new string[4] { "pink donut", "tree_background", "circle", "fetus" };
				int n = 0;
				foreach (Renderer r in Resources.FindObjectsOfTypeAll<Renderer>())
				{
					if (r == null || !r.gameObject.activeInHierarchy) continue;
					if (r is LineRenderer) continue;                     // never touch the connections
					string tn = "";
					MeshRenderer mr = r as MeshRenderer;
					SpriteRenderer sr = r as SpriteRenderer;
					if (mr != null && mr.material != null && mr.material.mainTexture != null) tn = mr.material.mainTexture.name.ToLowerInvariant();
					else if (sr != null && sr.sprite != null) tn = sr.sprite.name.ToLowerInvariant();
					if (tn == "") continue;
					bool isBg = false;
					foreach (string w in backdropTex) if (tn.Contains(w)) { isBg = true; break; }
					if (!isBg) continue;
					if (r.sortingOrder > -50) r.sortingOrder = -100;
					n++;
				}'''
new = '''				// ONLY the real backdrops. An earlier version also matched "circle" and
				// swallowed every node frame - 'frameCircle' and 'TileFrameLifeFormCircle'
				// are the tree's OWN art, so the nodes' frames and icons ended up behind
				// the backdrop instead of the other way round.
				string[] backdropTex = new string[2] { "pink donut", "tree_background" };
				int n = 0;
				foreach (Renderer r in Resources.FindObjectsOfTypeAll<Renderer>())
				{
					if (r == null || !r.gameObject.activeInHierarchy) continue;
					if (r is LineRenderer) continue;                     // never touch the connections
					string tn = "";
					MeshRenderer mr = r as MeshRenderer;
					SpriteRenderer sr = r as SpriteRenderer;
					if (mr != null && mr.material != null && mr.material.mainTexture != null) tn = mr.material.mainTexture.name.ToLowerInvariant();
					else if (sr != null && sr.sprite != null) tn = sr.sprite.name.ToLowerInvariant();
					if (tn == "") continue;
					// belt and braces: never touch node frames/icons/anything interactive
					if (tn.Contains("frame") || tn.Contains("icon") || tn.Contains("node")) continue;
					bool isBg = false;
					foreach (string w in backdropTex) if (tn.Contains(w)) { isBg = true; break; }
					if (!isBg) continue;
					if (r.sortingOrder > -50) r.sortingOrder = -100;
					if (r.sortingLayerName != "Default") r.sortingLayerName = "Default";
					n++;
				}'''
assert t.count(old) == 1, t.count(old)
t = t.replace(old, new)
open(P, "w", encoding="utf-8").write(t)
print("filter narrowed to the real backdrops only")
