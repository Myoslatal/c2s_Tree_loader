P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
t = open(P, encoding="utf-8").read()
old = '''			Log.Info("BACKDROP: disabled " + n + " background renderer(s) so nothing can cover the tree");'''
new = '''			Log.Info("BACKDROP: disabled " + n + " background renderer(s) so nothing can cover the tree");
			NodeProbe();'''
assert t.count(old) == 1
t = t.replace(old, new)

anchor = "	/// <summary>\n	/// Mission.reqItem is a PLAIN field"
assert t.count(anchor) == 1
probe = '''	private static bool _nodeProbeDone;

	/// <summary>
	/// One-shot geometry dump of the live tree, so the editor can draw its nodes at the same
	/// size the game does. Logs each node's world position and its rendered diameter, plus the
	/// distance to every other node, which is what the radius/spacing ratio is computed from.
	/// </summary>
	internal static void NodeProbe()
	{
		if (_nodeProbeDone) return;
		_nodeProbeDone = true;
		try
		{
			List<Renderer> frames = new List<Renderer>();
			foreach (Renderer r in Resources.FindObjectsOfTypeAll<Renderer>())
			{
				if (r == null || !r.gameObject.activeInHierarchy) continue;
				SpriteRenderer sr = r as SpriteRenderer;
				if (sr == null || sr.sprite == null) continue;
				string sn = sr.sprite.name.ToLowerInvariant();
				if (sn.Contains("framecircle") || sn == "circle") frames.Add(sr);
			}
			Log.Info("NODEPROBE: " + frames.Count + " node frame(s)");
			for (int i = 0; i < frames.Count; i++)
			{
				Vector3 p = frames[i].transform.position;
				float d = frames[i].bounds.size.x;
				Log.Info("NODEPROBE node " + i + " " + frames[i].transform.root.name
					+ " pos=(" + p.x.ToString("F2") + "," + p.y.ToString("F2") + ")"
					+ " diameter=" + d.ToString("F3")
					+ " pxPerUnitScale=(" + frames[i].transform.lossyScale.x.ToString("F4") + ")");
			}
			// spacing: nearest-neighbour distance for each node
			for (int i = 0; i < frames.Count; i++)
			{
				float best = 1e9f;
				for (int k = 0; k < frames.Count; k++)
				{
					if (k == i) continue;
					float dd = Vector3.Distance(frames[i].transform.position, frames[k].transform.position);
					if (dd < best) best = dd;
				}
				if (best < 1e8f)
					Log.Info("NODEPROBE nearest " + i + " = " + best.ToString("F3")
						+ "  ratio radius/spacing = " + ((frames[i].bounds.size.x * 0.5f) / best).ToString("F4"));
			}
		}
		catch (Exception e) { Log.Error("NodeProbe", e); }
	}

'''
t = t.replace(anchor, probe + anchor)
open(P, "w", encoding="utf-8").write(t)
print("probe added")
