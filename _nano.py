P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
t = open(P, encoding="utf-8").read()

# --- mission: run the game's own per-mission wiring ---
old = '''				missionController.RefreshMissionGroups();
				_lastProbe = null;'''
new = '''				missionController.RefreshMissionGroups();
				// The game's own rank switch (PrestigeAllRank) does MORE than the two calls
				// above: InitMissionUI(), then one AddMission() per mission - which binds
				// reqItem, the mission's own UI and its tracked value - then uirank.Init().
				// We only ever replaced the mission array, so the reward could never be claimed.
				if (rank.missions != null)
				{
					foreach (Mission mm in rank.missions)
					{
						try { missionController.AddMission(mm); }
						catch (Exception e2) { Log.Error("AddMission(" + ((mm == null) ? "null" : mm.reqItemId) + ")", e2); }
					}
				}
				_lastProbe = null;'''
assert t.count(old) == 1, t.count(old)
t = t.replace(old, new)

# --- nanobot runtime probe ---
anchor = "	public static void HideBackdrop()"
assert t.count(anchor) == 1
probe = '''	private static int _nanoAt;
	private static int _nanoLogged;

	/// <summary>
	/// Diagnostic: dump the nanobot state machine a few times so the cooldown patch can be
	/// checked against what the game actually does, instead of reading IL.
	/// </summary>
	internal static void NanoProbe()
	{
		if (_nanoLogged >= 6) return;
		if (_ticks < _nanoAt + 300) return;
		_nanoAt = _ticks;
		_nanoLogged++;
		try
		{
			BoostTimerManager btm = UnityEngine.Object.FindObjectOfType<BoostTimerManager>();
			string st = (btm == null) ? "?" : btm.state.ToString();
			float reset = 0f;
			try { reset = UpgradeStatsManager.nanobots.GetNanobotResetTimer_Seconds(); } catch { }
			Log.Info("NANOPROBE state=" + st
				+ " timer=" + BoostTimerManager.timer.ToString("F2")
				+ " resetSeconds=" + reset.ToString("F2")
				+ " nanoTimerPref=" + PlayerPrefs.GetFloat("nanoTimer").ToString("F2")
				+ " nanoStatePref=" + PlayerPrefs.GetInt("nano_state"));
		}
		catch (Exception e) { Log.Error("NanoProbe", e); }
	}

'''
t = t.replace(anchor, probe + anchor)
t = t.replace("			PackLoader.NodeProbe();", "			PackLoader.NodeProbe();\n\t\t\tNanoProbe();")
open(P, "w", encoding="utf-8").write(t)
print("mission AddMission + nanobot probe added")
