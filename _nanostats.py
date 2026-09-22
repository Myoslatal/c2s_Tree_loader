P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
t = open(P, encoding="utf-8").read()
old = "	private void Awake()"
assert t.count(old) == 1, t.count(old)
new = '''	private int _nanoStatsAt;
	private int _nanoStatsLogged;

	/// <summary>
	/// Runs in EVERY scene (this object is DontDestroyOnLoad), unlike the event-only hooks.
	/// Dumps what the nanobot bonus pipeline actually sees, so "no bonuses" can be traced to
	/// the gate (UsesSharedBoostTimerForCurrentSimulation) or to the per-upgrade item lists.
	/// </summary>
	private void Update()
	{
		if (_nanoStatsLogged >= 8) return;
		if (Time.frameCount < _nanoStatsAt + 180) return;
		_nanoStatsAt = Time.frameCount;
		_nanoStatsLogged++;
		try
		{
			NanobotUpgradeStats n = UpgradeStatsManager.nanobots;
			if (n == null) { Log.Info("NANOSTATS: UpgradeStatsManager.nanobots is null"); return; }
			Log.Info("NANOSTATS mainSim=" + GameScene.IsMainSim()
				+ " eventScene=" + GameScene.IsEventScene()
				+ " dinoSim=" + GameScene.IsDinosaurSim()
				+ " shared=" + AutomationManager.UsesSharedBoostTimerForCurrentSimulation()
				+ " | eventUnlocked=" + NanobotUpgradeStats.EventNanobotsUnlocked
				+ " mesoUnlocked=" + NanobotUpgradeStats.MesozoicNanobotsUnlocked
				+ " beyondUnlocked=" + NanobotUpgradeStats.BeyondNanobotsUnlocked
				+ " | tapPowerScale=" + n.GetTapPowerScale().ToString("F4")
				+ " nanoTapPowerScale=" + n.GetNanobotTapPowerScale().ToString("F4")
				+ " tapRate=" + n.GetTapRatePerSecond().ToString("F4")
				+ " activeDuration=" + n.GetActiveDuration().ToString("F2"));
		}
		catch (Exception e) { Log.Error("NanoStats", e); }
	}

	private void Awake()'''
t = t.replace(old, new)
open(P, "w", encoding="utf-8").write(t)
print("Host.Update probe added")
