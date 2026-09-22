P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
t = open(P, encoding="utf-8").read()

# 1. helper
anchor = "	internal static void MaybeShowOutro()"
assert t.count(anchor) == 1, t.count(anchor)
helper = '''	/// <summary>
	/// Mission.reqItem is a PLAIN field - the game does NOT derive it from reqItemId, and
	/// MissionController.UpdateMission dereferences it unconditionally
	/// ("mission.currentTrackedValue = Math.Max(0.0, mission.reqItem.owned)"). The game fills
	/// it in MissionController.AddMission(), which WE never call, so every mission we build
	/// had reqItem == null: UpdateMission threw a NullReferenceException on the first mission
	/// every FixedUpdate (so no mission was ever marked complete and no reward could be
	/// claimed), and Mission.InitUI() - which binds the claim button - never ran either.
	/// Resolve it here and again when the missions are handed to the controller, because at
	/// pack-parse time the ItemInfo sheets may not be loaded yet.
	/// </summary>
	internal static void ResolveMissionReqItems(Mission[] missions)
	{
		if (missions == null) return;
		int fixedCount = 0;
		foreach (Mission m in missions)
		{
			if (m == null || m.reqItem != null) continue;
			if (string.IsNullOrEmpty(m.reqItemId)) continue;
			try
			{
				m.reqItem = ItemInfo.FindItem(m.reqItemId);
				if (m.reqItem != null) fixedCount++;
				else Log.Warn("mission '" + m.reqItemId + "' has no ItemInfo; its reward cannot be tracked");
			}
			catch (Exception e) { Log.Error("ResolveMissionReqItems(" + m.reqItemId + ")", e); }
		}
		if (fixedCount > 0) Log.Info("MISSIONS: resolved reqItem for " + fixedCount + " mission(s)");
	}

'''
t = t.replace(anchor, helper + anchor)

# 2. call where missions are handed to the controller
old = '''				if (rank.missions != null)
				{
					missionController._missions = rank.missions;
				}
				missionController.RefreshMissionGroups();'''
new = '''				if (rank.missions != null)
				{
					missionController._missions = rank.missions;
					ResolveMissionReqItems(rank.missions);
				}
				missionController.RefreshMissionGroups();'''
assert t.count(old) == 1, t.count(old)
t = t.replace(old, new)

# 3. call right after building them
old2 = "			rank.missions = list.ToArray();"
assert t.count(old2) == 1, t.count(old2)
t = t.replace(old2, "			rank.missions = list.ToArray();\n			ResolveMissionReqItems(rank.missions);")

open(P, "w", encoding="utf-8").write(t)
print("plugin patched")
