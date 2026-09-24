// ---------------------------------------------------------------------------
// CustomEventPackPlugin - recovered from the compiled build with ilspycmd after
// an editing accident destroyed the hand-written source. This is the exact code
// that produced the verified-working Managed/CustomEventPackPlugin.dll.
// ---------------------------------------------------------------------------
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text;
using I2.Loc;
using Newtonsoft.Json.Linq;
using TMPro;
using UnityEngine;
using UnityEngine.EventSystems;
using UnityEngine.SceneManagement;
using UnityEngine.TextCore;
using UnityEngine.UI;

namespace CustomEventPack
{

public static class Bootstrap
{
	private static bool _installed;

	public static void Install()
	{
		if (_installed)
		{
			return;
		}

		// The custom UI text is built with TMP_Settings.defaultFontAsset, and the game ships a
		// default TMP font with no CJK glyphs - so on a machine without FontReplacer every
		// string this mod writes renders as nothing at all: the interface appears, wordless.
		// FontReplacer swaps in a runtime font built from StreamingAssets/zh-cn.ttf. It is folded
		// into this same assembly, but reflection is used so the two plugins ALSO still work as
		// separate dlls, and so a missing FontReplacer warns instead of crashing.
		try
		{
			Type fr = Type.GetType("FontReplacerPlugin.FontReplacerBootstrap");
			if (fr == null)
			{
				foreach (Assembly asm in AppDomain.CurrentDomain.GetAssemblies())
				{
					fr = asm.GetType("FontReplacerPlugin.FontReplacerBootstrap");
					if (fr != null) break;
				}
			}
			if (fr != null)
			{
				MethodInfo mi = fr.GetMethod("Install", BindingFlags.Public | BindingFlags.Static);
				if (mi != null)
				{
					mi.Invoke(null, null);
					Log.Info("FontReplacer bootstrapped (CJK text available)");
				}
				else Log.Warn("FontReplacerBootstrap.Install not found");
			}
			else Log.Warn("FontReplacer is not installed; CJK text will not render");
		}
		catch (Exception e) { Log.Warn("FontReplacer bootstrap failed: " + e.Message); }
		_installed = true;
		try
		{
			GameObject gameObject = new GameObject("CustomEventPackHost");
			UnityEngine.Object.DontDestroyOnLoad(gameObject);
			gameObject.AddComponent<Host>();
			Log.Info("installed; pack roots: " + string.Join(" | ", PackLoader.Roots.ToArray()));
		}
		catch (Exception ex)
		{
			UnityEngine.Debug.LogError("[CustomEventPack] Install failed: " + ex);
		}
	}
}
internal static class Log
{
	private const string P = "[CustomEventPack] ";

	public static void Info(string m)
	{
		UnityEngine.Debug.Log("[CustomEventPack] " + m);
	}

	public static void Warn(string m)
	{
		UnityEngine.Debug.LogWarning("[CustomEventPack] " + m);
	}

	public static void Error(string m)
	{
		UnityEngine.Debug.LogError("[CustomEventPack] " + m);
	}

	public static void Error(string m, Exception e)
	{
		UnityEngine.Debug.LogError("[CustomEventPack] " + m + " :: " + e);
	}
}
internal class Host : MonoBehaviour
{
	internal static Host Instance;

	private List<Pack> _packs = new List<Pack>();

	private GameObject _panel;

	private RectTransform _listContent;

	private TextMeshProUGUI _status;

	private bool _open;

	private float _rescanTimer;

	private readonly List<GameObject> _rows = new List<GameObject>();

	private static Font _font;

	private GameObject _canvas;

	private int _nanoStatsAt;
	private int _nanoStatsLogged;

	/// <summary>
	/// Runs in EVERY scene (this object is DontDestroyOnLoad), unlike the event-only hooks.
	/// Dumps what the nanobot bonus pipeline actually sees, so "no bonuses" can be traced to
	/// the gate (UsesSharedBoostTimerForCurrentSimulation) or to the per-upgrade item lists.
	/// </summary>
	internal void NanoStatsProbe()
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
				+ " activeDuration=" + n.GetActiveDuration().TotalSeconds.ToString("F2"));
		}
		catch (Exception e) { Log.Error("NanoStats", e); }
	}

	private void Awake()
	{
		Instance = this;
		try
		{
			Rescan();
		}
		catch (Exception e)
		{
			Log.Error("initial scan failed", e);
		}
		try
		{
			EnsureCanvas();
		}
		catch (Exception e2)
		{
			Log.Error("UI build failed", e2);
		}
		try
		{
			SceneManager.sceneLoaded += delegate
			{
				try
				{
					EnsureCanvas();
				}
				catch
				{
				}
			};
		}
		catch
		{
		}
		StartCoroutine(SelfTest());
	}

	private IEnumerator SelfTest()
	{
		float t = 0f;
		while (t < 30f && (Singleton<LteServer>.instance == null || Singleton<LteServer>.instance.masterLteData == null))
		{
			t += Time.unscaledDeltaTime;
			yield return null;
		}
		yield return new WaitForSecondsRealtime(1f);
		try
		{
			Rescan();
			Log.Info("self-test: found " + _packs.Count + " pack(s)");
			foreach (Pack p in _packs)
			{
				Log.Info("  - " + p.FolderName + " | title='" + p.Title + "' | nodes=" + p.NodeCount + " | valid=" + p.Valid + (p.Valid ? "" : (" | error=" + p.Error)) + " | tree=" + p.TreePath);
				if (!p.Valid)
				{
					continue;
				}
				try
				{
					TreeDefinition treeDefinition = TreeDefinition.Load(p.TreePath);
					string text = GameJson.Build(treeDefinition, out var how);
					Log.Info("    generated game json via " + how + ": " + text.Length + " chars, startNode=" + treeDefinition.StartNode);
					Log.Info("    " + GameJson.RoundTrip(text, treeDefinition.Nodes.Count));
					Log.Info("    json head: " + text.Substring(0, Math.Min(320, text.Length)));
					Log.Info("    icons found: " + treeDefinition.Nodes.Count((TreeNodeDef n) => File.Exists(Path.Combine(p.Dir, "icons", n.Uid + ".png")) || File.Exists(Path.Combine(p.Dir, n.Uid + ".png"))) + "/" + treeDefinition.Nodes.Count);
				}
				catch (Exception e)
				{
					Log.Error("    build failed", e);
				}
			}
			LteServer instance = Singleton<LteServer>.instance;
			if (instance != null && instance.masterLteData != null)
			{
				MasterLtEDatabase masterLteData = instance.masterLteData;
				LTEData lTEData = masterLteData.FindLteData("import");
				Lte_PrefabData lte_PrefabData = masterLteData.FindLtePrefabData("import");
				Log.Info("self-test: built-in import LTE data = " + ((lTEData == null) ? "MISSING" : ("ok, loadMode=" + lTEData.loadMode.ToString() + " rankData=" + ((lTEData.rankData == null) ? "null" : "ok"))) + " ; import prefab = " + ((lte_PrefabData == null) ? "MISSING" : ("ok, tree=" + ((lte_PrefabData.treeData == null) ? "null" : lte_PrefabData.treeData.name))));
				Log.Info("self-test: LteServer state=" + LteServer.state.ToString() + " loadedData=" + ((instance.loadedData == null) ? "null" : instance.loadedData.LTE_Name));
				Log.Info("self-test: masterLteData has " + ((masterLteData.lteData != null) ? masterLteData.lteData.Count : 0) + " LTEData, " + ((masterLteData.ltePrefabData != null) ? masterLteData.ltePrefabData.Count : 0) + " Lte_PrefabData [" + ((masterLteData.ltePrefabData == null) ? "" : string.Join(",", (from x in masterLteData.ltePrefabData
					where x != null
					select x.lteName).ToArray())) + "]");
			}
			else
			{
				Log.Warn("self-test: LteServer/masterLteData unavailable after 30s");
			}
		}
		catch (Exception e2)
		{
			Log.Error("self-test", e2);
		}
		try
		{
			string want = Environment.GetEnvironmentVariable("CUSTOM_EVENT_PACK");
			if (!string.IsNullOrEmpty(want))
			{
				Pack pack = _packs.FirstOrDefault((Pack x) => string.Equals(x.FolderName, want, StringComparison.OrdinalIgnoreCase) || string.Equals(x.Id, want, StringComparison.OrdinalIgnoreCase));
				if (pack == null)
				{
					Log.Error("CUSTOM_EVENT_PACK='" + want + "' matched no pack");
					yield break;
				}
				Log.Info("auto-loading pack '" + pack.FolderName + "' on request");
				LoadPack(pack);
			}
		}
		catch (Exception e3)
		{
			Log.Error("auto-load", e3);
		}
	}

	private static bool _serverClockForced;

	/// <summary>
	/// Make LteServer's connection gate pass and settle the custom event in the ACTIVE window.
	///
	/// The game's exploration banner enters through ExplorationBanner.OpenEventPreview ->
	/// LteServer.DisplayLteStatus, whose first statement is
	///     if (!ServerConnectedAndHasTime()) { warn; return; }
	/// and the hub keeps rendering "Connecting..." for as long as LteServer.state is
	/// SERVER_LOADING. Both wait on a PlayFab server-time round trip this install never
	/// completes: lastServerDateTime stays DateTime.MinValue and gotInitialTimeRequest never
	/// becomes true, so the custom exploration could never be opened from the game's banner.
	///
	/// A custom pack is entirely local - the tree is staged under generated-tree/json.json and
	/// registered as loadMode=PersistentData - so the clock and the event window are simply
	/// filled in here. The fields are private, hence the reflection.
	/// </summary>
	private static void ForceServerClock()
	{
		if (_serverClockForced) return;
		try
		{
			LteServer s = Singleton<LteServer>.instance;
			if (s == null || s.masterLteData == null) return;
			DateTime now = DateTime.UtcNow;
			Type lt = typeof(LteServer);
			System.Reflection.BindingFlags inst = System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance;
			System.Reflection.BindingFlags stat = System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static;
			lt.GetField("lastServerDateTime", inst)?.SetValue(s, now);
			lt.GetField("lastPullLocalDateTime", inst)?.SetValue(s, now);
			lt.GetField("timeSinceServerPull", inst)?.SetValue(s, 0f);
			lt.GetField("gotInitialTimeRequest", inst)?.SetValue(s, true);
			lt.GetField("serverHasTimeInfo", stat)?.SetValue(null, true);

			// LteServer.lte is the server-side record for the active event. On this install it
			// never arrives (there is no server event for this account), and the hub UI reads it
			// WITHOUT a null check - TabButtonExploration.FixedUpdate does
			//     Constants.ParseVersionNumber(Singleton<LteServer>.instance.lte.req);
			// every physics frame, which throws and stops that whole UI element from ever
			// refreshing. So build the record the custom event needs.
			System.Reflection.MemberInfo lteMember =
				(System.Reflection.MemberInfo)lt.GetField("lte", inst) ?? (System.Reflection.MemberInfo)lt.GetProperty("lte", inst);
			object lte = null;
			if (lteMember is System.Reflection.FieldInfo lf) lte = lf.GetValue(s);
			else if (lteMember is System.Reflection.PropertyInfo lp) lte = lp.GetValue(s, null);
			if (lte == null && lteMember != null)
			{
				Type wt = lteMember is System.Reflection.FieldInfo lf2 ? lf2.FieldType : ((System.Reflection.PropertyInfo)lteMember).PropertyType;
				lte = Activator.CreateInstance(wt);
				if (lteMember is System.Reflection.FieldInfo lf3) lf3.SetValue(s, lte);
				else ((System.Reflection.PropertyInfo)lteMember).SetValue(s, lte, null);
				Log.Info("LteServer.lte was null - created the server event record for the custom pack");
			}
			if (lte != null)
			{
				Type wt = lte.GetType();
				wt.GetField("id", inst)?.SetValue(lte, "import");
				wt.GetField("name", inst)?.SetValue(lte, "import");
				wt.GetField("req", inst)?.SetValue(lte, "0.0.0");
				wt.GetField("promoDateTime", inst)?.SetValue(lte, now.AddYears(-1));
				wt.GetField("startDateTime", inst)?.SetValue(lte, now.AddDays(-1));
				wt.GetField("endDateTime", inst)?.SetValue(lte, now.AddYears(10));
			}

			// state is public static, but writing it through the enum avoids depending on
			// whether EventServerState is nested in LteServer or top level
			System.Reflection.FieldInfo stateField = lt.GetField("state", stat);
			if (stateField != null)
				stateField.SetValue(null, Enum.Parse(stateField.FieldType, "ACTIVE"));

			// TabButtonExploration and EventDoorController read LteServer.loadedData from
			// FixedUpdate once the state is no longer SERVER_LOADING, and throw every other
			// frame while it is null. Point it at the persistent 'import' event - the same
			// thing EnterEvent does on entry, but in time for the hub UI.
			if (s.loadedData == null)
				s.loadedData = s.masterLteData.FindLteData("import");
			// LteServer.DoesPlayerNeedReset() compares loadedData.savedEventId (what the save
			// recorded) against the active event id. They never match here, so every launch took
			// InitGame's <Reset> branch: SaveSystem.ResetEventProgression() wiped the event's
			// progress and a TransitionUIEventIntro cutscene was instantiated. That is what left
			// the hub controls un-initialised - TabButtonExploration and EventDoorController gate
			// their setup on EventController.state, which only becomes RUNNING at the end of the
			// flow the reset interrupts. Record the id so InitGame takes <Regular>.
			if (s.loadedData != null)
				s.loadedData.GetType().GetField("savedEventId", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public)?.SetValue(s.loadedData, "import");
			ClearForceReset(s, "ForceServerClock");

			_serverClockForced = true;
			Log.Info("server clock forced open: ServerConnectedAndHasTime() now passes and state=ACTIVE, so the exploration banner is no longer stuck at Connecting");
		}
		catch (Exception e) { Log.Error("ForceServerClock", e); }
	}

	private float _connectScanTimer;
	private readonly System.Collections.Generic.HashSet<string> _connectSeen = new System.Collections.Generic.HashSet<string>();

	/// <summary>
	/// Runtime probe for the "Connecting..." screen.
	///
	/// The string does not exist in any assembly and there is no i2 localisation term for it -
	/// the only occurrence in the whole install is a TextMeshPro placeholder ("Enter text...",
	/// "Connecting...", "Error message here.") inside resources.assets. So rather than keep
	/// guessing which controller shows it, this walks every live text component and reports the
	/// GameObject path, its components and its parent chain, which names the UI that owns it.
	/// </summary>
	private void ScanConnectingText()
	{
		_connectScanTimer += Time.unscaledDeltaTime;
		if (_connectScanTimer < 4f) return;
		_connectScanTimer = 0f;
		try
		{
			int seen = 0;
			foreach (TMP_Text t in UnityEngine.Object.FindObjectsOfType<TMP_Text>(true))
			{
				if (t == null || string.IsNullOrEmpty(t.text)) continue;
				seen++;
				if (t.text.IndexOf("Connect", StringComparison.OrdinalIgnoreCase) < 0) continue;
				ReportConnectText(t.gameObject, t.text);
			}
			foreach (UnityEngine.UI.Text u in UnityEngine.Object.FindObjectsOfType<UnityEngine.UI.Text>(true))
			{
				if (u == null || string.IsNullOrEmpty(u.text)) continue;
				seen++;
				if (u.text.IndexOf("Connect", StringComparison.OrdinalIgnoreCase) < 0) continue;
				ReportConnectText(u.gameObject, u.text);
			}
			if (_connectSeen.Count == 0)
				Log.Info("connect-scan: " + seen + " live text component(s), none showing a Connect* string");
		}
		catch (Exception e) { Log.Error("ScanConnectingText", e); }
	}

	private void ReportConnectText(GameObject go, string text)
	{
		string path = PathOf(go.transform);
		if (!_connectSeen.Add(path + "|" + text)) return;
		Log.Info("CONNECT-TEXT '" + text.Replace('\n', ' ') + "'");
		Log.Info("    object  : " + path + "  activeSelf=" + go.activeSelf + " activeInHierarchy=" + go.activeInHierarchy);
		Component[] comps = go.GetComponents<Component>();
		string[] names = new string[comps.Length];
		for (int i = 0; i < comps.Length; i++) names[i] = (comps[i] == null ? "(missing script)" : comps[i].GetType().FullName);
		Log.Info("    has     : " + string.Join(", ", names));
		Transform p = go.transform.parent;
		System.Collections.Generic.List<string> chain = new System.Collections.Generic.List<string>();
		while (p != null && chain.Count < 8) { chain.Add(p.name + (p.gameObject.activeSelf ? "" : "[off]")); p = p.parent; }
		Log.Info("    parents : " + string.Join(" < ", chain));
	}

	private static string PathOf(Transform t)
	{
		string s = t.name;
		Transform p = t.parent;
		while (p != null) { s = p.name + "/" + s; p = p.parent; }
		return s;
	}

	/// <summary>
	/// Keep LteServer out of SERVER_LOADING and release any deferred EventController.InitGame.
	///
	/// "Connecting..." is Controller/LTEventUI/IPhoneXAdjust/HudCanvasGroup/Preloader/Text (TMP).
	/// EventController.Awake() shows it and then does
	///     if (LteServer.state != SERVER_LOADING) InitGame();
	///     else LteServer.LteServerReadyCallBack += InitGame;
	/// and Preloader.SetActive(false) is the last statement of the StartGame() coroutine that
	/// InitGame() eventually launches. On this install the PlayFab server-time handshake never
	/// completes, LteServer.Start() keeps re-entering SERVER_LOADING, and nothing ever fires
	/// LteServerReadyCallBack - so InitGame is queued forever and the preloader stays up.
	/// Two things are therefore needed: stop the state being SERVER_LOADING, and run the
	/// callbacks that were already parked against it.
	/// </summary>
	private void NudgeLteReady()
	{
		try
		{
			if (Singleton<LteServer>.instance == null) return;
			if (LteServer.state.ToString() == "SERVER_LOADING")
			{
				System.Reflection.FieldInfo sf = typeof(LteServer).GetField("state",
					System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static);
				if (sf != null) sf.SetValue(null, Enum.Parse(sf.FieldType, "ACTIVE"));
			}
			System.Action cb = LteServer.LteServerReadyCallBack;
			if (cb != null && LteServer.state.ToString() != "SERVER_LOADING")
			{
				LteServer.LteServerReadyCallBack = null;
				Log.Info("releasing deferred EventController.InitGame (" + cb.GetInvocationList().Length + " listener(s)) - this is what unblocks the Connecting preloader");
				ClearForceReset(Singleton<LteServer>.instance, "just before the deferred InitGame");
				cb();
			}
		}
		catch (Exception e) { Log.Error("NudgeLteReady", e); }
	}

	private bool _nodesSignalled;
	private bool _preloaderHidden;
	private float _signalledAt;

	/// <summary>
	/// Raise Preloader.bLoadComplete once the custom tree's nodes are actually built.
	///
	/// Preloader.AnimationExit() is the routine that retires the "Connecting..." overlay:
	///     while ((!bLoadComplete && !bStartViewReady) || totalLinesShown < 10) yield return null;
	/// bStartViewReady is raised only by the primary-simulation flows (EARTH view, ascension,
	/// reality reboot) which the event scene never runs, and bLoadComplete is raised at the end
	/// of the game's node-spawn loop. A custom pack builds its tree through
	/// treebuilder.InitBuildFromTree() instead, so neither flag is ever raised and the overlay
	/// never animates away.
	///
	/// The nodes genuinely are built by the time this fires (post-load fixup and the sprite
	/// binder have both run), so this raises exactly the flag whose meaning is "node spawning
	/// finished". Nothing else is touched - not TransitionUI.bLoadComplete, not bStartViewReady,
	/// and the overlay object is not touched at all, so AnimationExit() runs its normal course.
	/// </summary>
	private void SignalNodesBuilt()
	{
		if (_nodesSignalled) return;
		try
		{
			if (!GameScene.IsEventScene()) return;
			EventController ec = EventController.instance;
			if (ec == null || ec.eventPrefabData == null || ec.eventPrefabData.treeData == null) return;
			ItemInfo[] nodes = ec.eventPrefabData.treeData.nodes;
			if (nodes == null || nodes.Length <= 2) return;
			Preloader.bLoadComplete = true;
			_nodesSignalled = true;
			_signalledAt = Time.realtimeSinceStartup;
			Log.Info("signalled Preloader.bLoadComplete (" + nodes.Length + " node(s) built) - lets Preloader.AnimationExit() retire the Connecting overlay through its own animation");
		}
		catch (Exception e) { Log.Error("SignalNodesBuilt", e); }
	}

	/// <summary>
	/// Run the statement EventController.StartGame() ends on: Preloader.SetActive(false).
	///
	/// Preloader.AnimationExit() only fades its canvas group to zero alpha and raises isExit -
	/// it never deactivates the GameObject, so "Connecting..." stays an active object on screen.
	/// StartGame() is what hides it, but StartGame() never reaches its last statement on this
	/// install. This runs that same statement once the exit animation has had its ~2s to
	/// finish, and touches nothing else.
	/// </summary>
	/// <summary>
	/// LteServer.DoesPlayerNeedReset() is:
	///     if (bForceReset) return true;
	///     if (SAVED_EVENT_ID != lte.name) return true;
	///     return false;
	/// and the log shows SAVED_EVENT_ID == LTEname == "import2147483615", so the name comparison
	/// already passes - bForceReset is the only thing still forcing a reset. ForceEvent(id, true)
	/// sets it while entering the event. While it is set, InitGame takes the <Reset> branch:
	/// SaveSystem.ResetEventProgression() wipes the event's progress and a TransitionUIEventIntro
	/// cutscene is instantiated, which is what leaves EventController.state at NOT_LOADED and the
	/// hub controls un-initialised. Clear it immediately before InitGame runs.
	/// </summary>
	private static void ClearForceReset(LteServer s, string at)
	{
		if (s == null) return;
		try
		{
			System.Reflection.FieldInfo f = typeof(LteServer).GetField("bForceReset",
				System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public);
			if (f == null) { Log.Warn("bForceReset field not found"); return; }
			bool was = true.Equals(f.GetValue(s));
			f.SetValue(s, false);
			if (was) Log.Info("cleared LteServer.bForceReset (at " + at + ") - InitGame now takes <Regular> instead of wiping event progress");
		}
		catch (Exception e) { Log.Error("ClearForceReset", e); }
	}

	private static bool _standaloneLaunched;
	private TreeDefinition _stagedTree;
	private string _stagedPackName;

	/// <summary>
	/// Stage-1 debug entry. Set CUSTOM_EXPLORER_STANDALONE=1 to build the standalone explorer for
	/// the first available pack, without going through LteServer/EventController at all. This is
	/// deliberately opt-in so the existing path stays untouched while the renderer is debugged.
	/// </summary>
	private void DebugStandaloneExplorer()
	{
		if (_standaloneLaunched) return;
		try
		{
			string flag = Environment.GetEnvironmentVariable("CUSTOM_EXPLORER_STANDALONE");
			if (string.IsNullOrEmpty(flag) || flag == "0") return;
			_standaloneLaunched = true;
			if (PackLoader.Roots == null || PackLoader.Roots.Count == 0) { Log.Warn("standalone explorer: no pack roots found"); return; }
			// Roots are the CustomEvents root folders; packs are subdirectories under them.
			string dir = null;
			foreach (string root in PackLoader.Roots)
			{
				if (!Directory.Exists(root)) continue;
				foreach (string sub in Directory.GetDirectories(root))
				{
					// a pack is a folder holding tree.json (the tree) plus pack.json (its metadata)
					if (File.Exists(Path.Combine(sub, "tree.json"))) { dir = sub; break; }
				}
				if (dir != null) break;
			}
			if (dir == null) { Log.Warn("standalone explorer: no pack subfolder with tree.json under " + string.Join(" | ", PackLoader.Roots.ToArray())); return; }
			string jsonPath = Path.Combine(dir, "tree.json");
			Log.Info("standalone explorer: using pack folder " + dir);
			TreeDefinition tree = TreeDefinition.Load(jsonPath);
			if (tree == null || tree.Nodes == null || tree.Nodes.Count == 0)
			{
				Log.Warn("standalone explorer: tree parsed but has no nodes (count=" + ((tree == null || tree.Nodes == null) ? "null" : tree.Nodes.Count.ToString()) + ")");
				return;
			}
			CustomExplorer.Launch(tree, Path.GetFileName(dir));
		}
		catch (Exception e) { Log.Error("DebugStandaloneExplorer", e); }
	}

	private float _diagTimer;

	/// <summary>
	/// Report the objects EventController.StartGame() dereferences, and the EventController.state
	/// that every hub control gates its initialisation on.
	///
	/// StartGame() is the only place that sets state = RUNNING, and until it does,
	/// TabButtonExploration/EventDoorController skip their initialisation entirely. StartGame()
	/// dereferences GameController.UI.black, Singleton&lt;LteServer&gt;.instance.loadedData and
	/// loadedData.treeStartNode before it can get there, so whichever of those is false is the
	/// statement the coroutine died on.
	/// </summary>
	private void DiagnoseStartGame()
	{
		_diagTimer += Time.unscaledDeltaTime;
		if (_diagTimer < 5f) return;
		_diagTimer = 0f;
		try
		{
			if (EventController.instance == null) return;
			LteServer s = Singleton<LteServer>.instance;
			bool hasLte = s != null && s.lte != null;
			bool hasLoaded = s != null && s.loadedData != null;
			string startNode = hasLoaded ? (s.loadedData.treeStartNode ?? "(null)") : "(no loadedData)";
			Log.Info("diag state=" + EventController.state
				+ " | GameController.UI=" + (GameController.UI != null)
				+ " lte=" + hasLte
				+ " loadedData=" + hasLoaded
				+ " treeStartNode='" + startNode + "'"
				+ " eventPrefabData=" + (EventController.instance.eventPrefabData != null)
				+ " (state stays NOT_LOADED until StartGame() reaches its end)");
		}
		catch (Exception e) { Log.Error("DiagnoseStartGame", e); }
	}

	private void DismissPreloaderObject()
	{
		if (_preloaderHidden || !_nodesSignalled) return;
		if (Time.realtimeSinceStartup - _signalledAt < 8f) return;
		try
		{
			GameObject go = GameObject.Find("Controller/LTEventUI/IPhoneXAdjust/HudCanvasGroup/Preloader");
			if (go != null && go.activeSelf)
			{
				go.SetActive(false);
				_preloaderHidden = true;
				Log.Info("Preloader.SetActive(false) - same statement EventController.StartGame() ends on");
			}
		}
		catch (Exception e) { Log.Error("DismissPreloaderObject", e); }
	}

	private void Update()
	{
		NanoStatsProbe();
		// Option C: the live-ops state faking (ForceServerClock / NudgeLteReady /
		// SignalNodesBuilt / ClearForceReset / DismissPreloaderObject) is gone. The standalone
		// explorer needs none of it, and every one of those hooks broke something downstream.
		DebugStandaloneExplorer();
		DiagnoseStartGame();
		ScanConnectingText();
		_rescanTimer += Time.unscaledDeltaTime;
		if (_rescanTimer > 5f)
		{
			_rescanTimer = 0f;
			try
			{
				Rescan();
				if (_open)
				{
					Rebuild();
				}
			}
			catch
			{
			}
		}
		try
		{
			if (Input.GetKeyDown(KeyCode.F9))
			{
				Toggle();
			}
		}
		catch
		{
		}
		if (PackLoader.CustomEventActive)
		{
			if (EventController.instance == null)
			{
				PackLoader.CustomEventActive = false;
				return;
			}
			PackLoader.DisableLeaderboard();
			PackLoader.MaybeAdvanceStage();
			PackLoader.MaybeShowOutro();
			PackLoader.RetryEventBackground();
			PackLoader.DelayedBackdropDump(Time.unscaledDeltaTime);
		}
	}

	internal void Rescan()
	{
		_packs = PackLoader.Discover();
	}

	internal void Toggle()
	{
		_open = !_open;
		if (_open)
		{
			Rescan();
			Show();
		}
		else
		{
			Hide();
		}
	}

	private void Show()
	{
		BuildPanel();
		if (_panel != null)
		{
			_panel.SetActive(value: true);
		}
		Rebuild();
	}

	private void Hide()
	{
		if (_panel != null)
		{
			_panel.SetActive(value: false);
		}
	}

	private static Font UiFont()
	{
		if (_font != null)
		{
			return _font;
		}
		try
		{
			_font = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
		}
		catch
		{
		}
		if (_font == null)
		{
			try
			{
				_font = Resources.GetBuiltinResource<Font>("Arial.ttf");
			}
			catch
			{
			}
		}
		return _font;
	}

	private static GameObject MakeCanvas()
	{
		GameObject obj = new GameObject("CustomEventPackCanvas");
		UnityEngine.Object.DontDestroyOnLoad(obj);
		Canvas canvas = obj.AddComponent<Canvas>();
		canvas.renderMode = RenderMode.ScreenSpaceOverlay;
		canvas.sortingOrder = 32000;
		CanvasScaler canvasScaler = obj.AddComponent<CanvasScaler>();
		canvasScaler.uiScaleMode = CanvasScaler.ScaleMode.ScaleWithScreenSize;
		canvasScaler.referenceResolution = new Vector2(1920f, 1080f);
		canvasScaler.matchWidthOrHeight = 0.5f;
		obj.AddComponent<GraphicRaycaster>();
		if (UnityEngine.Object.FindObjectOfType<EventSystem>() == null)
		{
			GameObject obj2 = new GameObject("CustomEventPackEventSystem");
			UnityEngine.Object.DontDestroyOnLoad(obj2);
			obj2.AddComponent<EventSystem>();
			obj2.AddComponent<StandaloneInputModule>();
		}
		return obj;
	}

	private static RectTransform MakePanel(Transform parent, string name, Color bg, Vector2 anchorMin, Vector2 anchorMax, Vector2 offsetMin, Vector2 offsetMax)
	{
		GameObject gameObject = new GameObject(name, typeof(RectTransform), typeof(CanvasRenderer), typeof(Image));
		RectTransform component = gameObject.GetComponent<RectTransform>();
		component.SetParent(parent, worldPositionStays: false);
		component.anchorMin = anchorMin;
		component.anchorMax = anchorMax;
		component.offsetMin = offsetMin;
		component.offsetMax = offsetMax;
		gameObject.GetComponent<Image>().color = bg;
		return component;
	}

	internal static TextMeshProUGUI MakeText(Transform parent, string name, string text, float size, TextAlignmentOptions align, Color color)
	{
		GameObject obj = new GameObject(name, typeof(RectTransform));
		obj.GetComponent<RectTransform>().SetParent(parent, worldPositionStays: false);
		TextMeshProUGUI textMeshProUGUI = obj.AddComponent<TextMeshProUGUI>();
		textMeshProUGUI.text = text;
		textMeshProUGUI.fontSize = size;
		textMeshProUGUI.alignment = align;
		textMeshProUGUI.color = color;
		textMeshProUGUI.raycastTarget = false;
		textMeshProUGUI.enableWordWrapping = false;
		try
		{
			if (TMP_Settings.defaultFontAsset != null)
			{
				textMeshProUGUI.font = TMP_Settings.defaultFontAsset;
			}
		}
		catch
		{
		}
		return textMeshProUGUI;
	}

	internal static Button MakeButton(Transform parent, string name, string label, Color bg, Vector2 size, Vector2 pos, Action onClick)
	{
		GameObject obj = new GameObject(name, typeof(RectTransform), typeof(CanvasRenderer), typeof(Image), typeof(Button));
		RectTransform component = obj.GetComponent<RectTransform>();
		component.SetParent(parent, worldPositionStays: false);
		Vector2 anchorMin = (component.anchorMax = new Vector2(0.5f, 0.5f));
		component.anchorMin = anchorMin;
		component.pivot = new Vector2(0.5f, 0.5f);
		component.sizeDelta = size;
		component.anchoredPosition = pos;
		Image component2 = obj.GetComponent<Image>();
		component2.color = bg;
		Button component3 = obj.GetComponent<Button>();
		component3.targetGraphic = component2;
		ColorBlock colors = component3.colors;
		colors.normalColor = Color.white;
		colors.highlightedColor = new Color(1.15f, 1.15f, 1.15f, 1f);
		colors.pressedColor = new Color(0.8f, 0.8f, 0.8f, 1f);
		component3.colors = colors;
		RectTransform rectTransform = MakeText(component, "Label", label, 26f, TextAlignmentOptions.Center, Color.white).rectTransform;
		rectTransform.anchorMin = Vector2.zero;
		rectTransform.anchorMax = Vector2.one;
		rectTransform.offsetMin = Vector2.zero;
		rectTransform.offsetMax = Vector2.zero;
		if (onClick != null)
		{
			component3.onClick.AddListener(delegate
			{
				try
				{
					onClick();
				}
				catch (Exception e)
				{
					Log.Error("button handler", e);
				}
			});
		}
		return component3;
	}

	private void EnsureCanvas()
	{
		if (!(_canvas != null))
		{
			_canvas = MakeCanvas();
			RectTransform component = MakeButton(_canvas.transform, "LauncherBtn", "自定义勘探活动", new Color(0.1f, 0.45f, 0.65f, 0.92f), new Vector2(260f, 62f), Vector2.zero, Toggle).GetComponent<RectTransform>();
			Vector2 anchorMin = (component.anchorMax = new Vector2(0f, 0f));
			component.anchorMin = anchorMin;
			component.pivot = new Vector2(0f, 0f);
			component.anchoredPosition = new Vector2(24f, 24f);
		}
	}

	private void BuildPanel()
	{
		EnsureCanvas();
		if (_panel != null)
		{
			return;
		}
		RectTransform rectTransform = MakePanel(_canvas.transform, "Panel", new Color(0.06f, 0.09f, 0.13f, 0.97f), new Vector2(0.5f, 0.5f), new Vector2(0.5f, 0.5f), Vector2.zero, Vector2.zero);
		rectTransform.sizeDelta = new Vector2(860f, 620f);
		rectTransform.anchoredPosition = Vector2.zero;
		_panel = rectTransform.gameObject;
		RectTransform rectTransform2 = MakeText(rectTransform, "Title", "自定义勘探活动包", 36f, TextAlignmentOptions.Center, Color.white).rectTransform;
		rectTransform2.anchorMin = new Vector2(0f, 1f);
		rectTransform2.anchorMax = new Vector2(1f, 1f);
		rectTransform2.pivot = new Vector2(0.5f, 1f);
		rectTransform2.offsetMin = new Vector2(0f, -66f);
		rectTransform2.offsetMax = new Vector2(0f, -10f);
		RectTransform rectTransform3 = MakePanel(rectTransform, "Viewport", new Color(0f, 0f, 0f, 0.35f), new Vector2(0f, 0f), new Vector2(1f, 1f), new Vector2(24f, 108f), new Vector2(-24f, -78f));
		rectTransform3.gameObject.AddComponent<RectMask2D>();
		GameObject gameObject = new GameObject("Content", typeof(RectTransform));
		_listContent = gameObject.GetComponent<RectTransform>();
		_listContent.SetParent(rectTransform3, worldPositionStays: false);
		_listContent.anchorMin = new Vector2(0f, 1f);
		_listContent.anchorMax = new Vector2(1f, 1f);
		_listContent.pivot = new Vector2(0.5f, 1f);
		_listContent.anchoredPosition = Vector2.zero;
		_listContent.sizeDelta = new Vector2(0f, 0f);
		ScrollRect scrollRect = rectTransform.gameObject.AddComponent<ScrollRect>();
		scrollRect.viewport = rectTransform3;
		scrollRect.content = _listContent;
		scrollRect.horizontal = false;
		scrollRect.vertical = true;
		scrollRect.movementType = ScrollRect.MovementType.Clamped;
		scrollRect.scrollSensitivity = 40f;
		_status = MakeText(rectTransform, "Status", "", 20f, TextAlignmentOptions.Left, new Color(0.75f, 0.85f, 0.95f));
		RectTransform rectTransform4 = _status.rectTransform;
		rectTransform4.anchorMin = new Vector2(0f, 0f);
		rectTransform4.anchorMax = new Vector2(1f, 0f);
		rectTransform4.pivot = new Vector2(0.5f, 0f);
		rectTransform4.offsetMin = new Vector2(26f, 76f);
		rectTransform4.offsetMax = new Vector2(-26f, 76f);
		rectTransform4.sizeDelta = new Vector2(-52f, 30f);
		_status.enableWordWrapping = true;
		MakeButton(rectTransform, "Rescan", "重新扫描", new Color(0.22f, 0.33f, 0.45f, 1f), new Vector2(158f, 52f), new Vector2(-380f, -270f), delegate
		{
			Rescan();
			Rebuild();
		});
		MakeButton(rectTransform, "OpenDir", "打开目录", new Color(0.22f, 0.33f, 0.45f, 1f), new Vector2(158f, 52f), new Vector2(-220f, -270f), OpenPackDir);
		MakeButton(rectTransform, "ImportZip", "导入 ZIP", new Color(0.30f, 0.36f, 0.20f, 1f), new Vector2(158f, 52f), new Vector2(-60f, -270f), delegate
		{
			if (_browseMode) ExitBrowse(); else EnterBrowse();
		});
		MakeButton(rectTransform, "Close", "关闭", new Color(0.45f, 0.18f, 0.18f, 1f), new Vector2(158f, 52f), new Vector2(300f, -270f), Toggle);
		MakeButton(rectTransform, "ReloadActive", "重载当前包", new Color(0.16f, 0.42f, 0.28f, 1f), new Vector2(200f, 52f), new Vector2(120f, -270f), delegate
		{
			if (PackLoader.LastLoaded != null)
			{
				LoadPack(PackLoader.LastLoaded);
			}
			else
			{
				SetStatus("还没有加载过任何包。");
			}
		});
	}

	/// <summary>
	/// Import every .zip dropped into a pack root: extract it into that same root so
	/// it lands as CustomEvents/&lt;PackName&gt;/ (the archives produced by the editor's
	/// "发布 ZIP" have exactly that top-level folder), then move the archive to
	/// CustomEvents/imported/ so it is never imported twice. Returns how many packs
	/// were imported.
	/// </summary>
	private static int ImportPendingZips(out string report)
	{
		int imported = 0;
		System.Text.StringBuilder sb = new System.Text.StringBuilder();
		foreach (string root in PackLoader.Roots)
		{
			try
			{
				if (!Directory.Exists(root)) continue;
				string[] zips = Directory.GetFiles(root, "*.zip", SearchOption.TopDirectoryOnly);
				if (zips.Length == 0) continue;
				foreach (string zip in zips)
				{
					try
					{
						string name = Path.GetFileNameWithoutExtension(zip);
						System.IO.Compression.ZipFile.ExtractToDirectory(zip, root);
						// The .zip is only a delivery vehicle - once its contents are in
						// CustomEvents/ it is pure clutter, so it is deleted, not archived.
						File.Delete(zip);
						imported++;
						sb.Append("已导入 ").Append(name).Append("; ");
						Log.Info("imported pack zip " + zip + " -> " + root);
					}
					catch (Exception e)
					{
						sb.Append("失败 ").Append(Path.GetFileName(zip)).Append(": ").Append(e.Message).Append("; ");
						Log.Error("import " + zip, e);
					}
				}
			}
			catch (Exception e) { Log.Error("ImportPendingZips", e); }
		}
		SweepImportedDirs();
		report = imported > 0
			? ("已导入 " + imported + " 个包。" + sb + "重启后生效。")
			: ("没有找到 .zip。请把勘探包的 zip 放到 " + string.Join(" 或 ", PackLoader.Roots.ToArray()) + " 后再点此按钮。");
		return imported;
	}

	/// <summary>
	/// Relaunch the game, then quit this instance. The pack scan runs at startup, so
	/// a restart is what actually makes an imported pack show up in the list.
	/// </summary>
	private static void RestartGame()
	{
		try
		{
			string exe = Path.GetFullPath(Path.Combine(Application.dataPath, "..", "CellToSingularity.exe"));
			if (File.Exists(exe))
			{
				System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(exe)
				{
					WorkingDirectory = Path.GetDirectoryName(exe),
					UseShellExecute = false
				});
				Log.Info("restarting the game: " + exe);
			}
			else Log.Warn("restart: exe not found at " + exe);
		}
		catch (Exception e) { Log.Error("RestartGame", e); }
		Application.Quit();
	}

	private void OpenPackDir()
	{
		try
		{
			string text = PackLoader.Roots.FirstOrDefault(Directory.Exists) ?? PackLoader.Roots[0];
			Directory.CreateDirectory(text);
			Application.OpenURL("file://" + text.Replace("\\", "/"));
			SetStatus("目录: " + text);
		}
		catch (Exception e)
		{
			Log.Error("OpenPackDir", e);
		}
	}

	private void SetStatus(string s)
	{
		if (_status != null)
		{
			_status.text = s;
		}
	}

	private void Rebuild()
	{
		if (_listContent == null)
		{
			return;
		}
		foreach (GameObject row in _rows)
		{
			if (row != null)
			{
				UnityEngine.Object.Destroy(row);
			}
		}
		_rows.Clear();
		if (_browseMode)
		{
			RebuildBrowseRows();
			return;
		}
		if (_packs.Count == 0)
		{
			SetStatus("未找到任何活动包。请把包目录放到: " + string.Join("  或  ", PackLoader.Roots.ToArray()));
			return;
		}
		float num = -8f;
		for (int i = 0; i < _packs.Count; i++)
		{
			Pack pack = _packs[i];
			float y = 86f;
			RectTransform rectTransform = MakePanel(_listContent, "Row" + i, new Color(1f, 1f, 1f, 0.06f), new Vector2(0f, 1f), new Vector2(1f, 1f), Vector2.zero, Vector2.zero);
			rectTransform.pivot = new Vector2(0.5f, 1f);
			rectTransform.sizeDelta = new Vector2(-12f, y);
			rectTransform.anchoredPosition = new Vector2(0f, num);
			_rows.Add(rectTransform.gameObject);
			string text = pack.Title + "   [" + pack.FolderName + "]";
			if (!pack.Valid)
			{
				text += "   <color=#ff8888>无效</color>";
			}
			RectTransform rectTransform2 = MakeText(rectTransform, "Name", text, 27f, TextAlignmentOptions.Left, Color.white).rectTransform;
			rectTransform2.anchorMin = new Vector2(0f, 0.45f);
			rectTransform2.anchorMax = new Vector2(1f, 1f);
			rectTransform2.offsetMin = new Vector2(16f, 0f);
			rectTransform2.offsetMax = new Vector2(-190f, -2f);
			RectTransform rectTransform3 = MakeText(rectTransform, "Sub", pack.Subtitle, 20f, TextAlignmentOptions.Left, new Color(0.72f, 0.8f, 0.9f)).rectTransform;
			rectTransform3.anchorMin = new Vector2(0f, 0f);
			rectTransform3.anchorMax = new Vector2(1f, 0.5f);
			rectTransform3.offsetMin = new Vector2(16f, 4f);
			rectTransform3.offsetMax = new Vector2(-190f, 0f);
			Pack captured = pack;
			RectTransform component = MakeButton(rectTransform, "Load", pack.Valid ? "加载" : "错误", new Color(0.13f, 0.5f, 0.32f, 1f), new Vector2(140f, 56f), Vector2.zero, delegate
			{
				LoadPack(captured);
			}).GetComponent<RectTransform>();
			Vector2 anchorMin = (component.anchorMax = new Vector2(1f, 0.5f));
			component.anchorMin = anchorMin;
			component.pivot = new Vector2(1f, 0.5f);
			component.anchoredPosition = new Vector2(-16f, 0f);
			num -= 98f;
		}
		_listContent.sizeDelta = new Vector2(0f, Mathf.Abs(num) + 12f);
		SetStatus("共 " + _packs.Count + " 个活动包。点击“加载”进入该勘探活动。");
	}

	// ------------------------------------------------------------ in-game file browser --
	// The "导入 ZIP" button opens a browser instead of scanning for archives: the user
	// navigates to wherever the .zip actually is and picks it. There is no
	// System.Windows.Forms in the game's Managed folder, so no native file dialog is
	// available - the pack list window doubles as the browser (each row's right-hand
	// button becomes "进入" for a directory and "导入" for a .zip).
	private bool _browseMode;
	private string _browseDir;

	private void EnterBrowse()
	{
		_browseMode = true;
		_browseDir = PackLoader.Roots.FirstOrDefault(Directory.Exists) ?? PackLoader.Roots[0];
		try { Directory.CreateDirectory(_browseDir); } catch { }
		Rebuild();
	}

	private void ExitBrowse()
	{
		_browseMode = false;
		Rebuild();
	}

	private void BrowseTo(string dir)
	{
		_browseDir = dir;
		Rebuild();
	}

	private void RebuildBrowseRows()
	{
		List<string> dirs = new List<string>();
		List<string> zips = new List<string>();
		try
		{
			dirs.AddRange(Directory.GetDirectories(_browseDir));
			zips.AddRange(Directory.GetFiles(_browseDir, "*.zip", SearchOption.TopDirectoryOnly));
			dirs.Sort(StringComparer.OrdinalIgnoreCase);
			zips.Sort(StringComparer.OrdinalIgnoreCase);
		}
		catch (Exception e)
		{
			SetStatus("无法读取目录: " + e.Message);
			return;
		}
		float num = -8f;
		// first row: go up (and, at the very top, back to the pack list)
		num = AddBrowseRow(num, "[..]  上级目录", "浏览其它位置", delegate
		{
			string parent = Path.GetDirectoryName(_browseDir.TrimEnd('/', '\\'));
			if (string.IsNullOrEmpty(parent)) ExitBrowse(); else BrowseTo(parent);
		});
		num = AddBrowseRow(num, "[×]  返回活动包列表", "退出文件浏览器", ExitBrowse);
		foreach (string d in dirs)
		{
			string captured = d;
			num = AddBrowseRow(num, "[目录]  " + Path.GetFileName(d), d, delegate { BrowseTo(captured); });
		}
		foreach (string z in zips)
		{
			string captured = z;
			long kb = 0;
			try { kb = new FileInfo(z).Length / 1024L; } catch { }
			num = AddBrowseRow(num, "[ZIP]  " + Path.GetFileName(z), kb + " KB — 点右侧“导入”解压并重启", delegate { ImportZipFile(captured); });
		}
		_listContent.sizeDelta = new Vector2(0f, Mathf.Abs(num) + 12f);
		SetStatus("浏览: " + _browseDir + "  —  选一个 .zip 导入，或点“上级目录”换位置。");
	}

	private float AddBrowseRow(float y, string title, string sub, Action onClick)
	{
		float h = 86f;
		RectTransform rectTransform = MakePanel(_listContent, "Browse" + _rows.Count, new Color(1f, 1f, 1f, 0.06f), new Vector2(0f, 1f), new Vector2(1f, 1f), Vector2.zero, Vector2.zero);
		rectTransform.pivot = new Vector2(0.5f, 1f);
		rectTransform.sizeDelta = new Vector2(-12f, h);
		rectTransform.anchoredPosition = new Vector2(0f, y);
		_rows.Add(rectTransform.gameObject);
		RectTransform t1 = MakeText(rectTransform, "Name", title, 27f, TextAlignmentOptions.Left, Color.white).rectTransform;
		t1.anchorMin = new Vector2(0f, 0.45f); t1.anchorMax = new Vector2(1f, 1f);
		t1.offsetMin = new Vector2(16f, 0f); t1.offsetMax = new Vector2(-190f, -2f);
		RectTransform t2 = MakeText(rectTransform, "Sub", sub, 20f, TextAlignmentOptions.Left, new Color(0.72f, 0.8f, 0.9f)).rectTransform;
		t2.anchorMin = new Vector2(0f, 0f); t2.anchorMax = new Vector2(1f, 0.5f);
		t2.offsetMin = new Vector2(16f, 4f); t2.offsetMax = new Vector2(-190f, 0f);
		bool isZip = title.StartsWith("[ZIP]");
		RectTransform btn = MakeButton(rectTransform, "Act", isZip ? "导入" : "进入", isZip ? new Color(0.30f, 0.36f, 0.20f, 1f) : new Color(0.13f, 0.5f, 0.32f, 1f), new Vector2(140f, 56f), Vector2.zero, onClick).GetComponent<RectTransform>();
		Vector2 amin = (btn.anchorMax = new Vector2(1f, 0.5f));
		btn.anchorMin = amin; btn.pivot = new Vector2(1f, 0.5f); btn.anchoredPosition = new Vector2(-16f, 0f);
		return y - 98f;
	}

	/// <summary>
	/// Remove every temporary "imported" folder under the pack roots. Earlier builds
	/// moved the consumed .zip into CustomEvents/imported/ to avoid importing it
	/// twice; the archive is deleted now, so that folder is only ever a leftover and
	/// is swept after each import. Best-effort: a locked folder is retried next time.
	/// </summary>
	private static void SweepImportedDirs()
	{
		foreach (string root in PackLoader.Roots)
		{
			try
			{
				string dir = Path.Combine(root, "imported");
				if (Directory.Exists(dir))
				{
					Directory.Delete(dir, recursive: true);
					Log.Info("removed temporary folder " + dir);
				}
			}
			catch (Exception e) { Log.Warn("SweepImportedDirs: " + e.Message); }
		}
	}

	/// <summary>Extract the chosen .zip into the pack root, then restart the game.</summary>
	private void ImportZipFile(string zip)
	{
		try
		{
			string root = PackLoader.Roots.FirstOrDefault(Directory.Exists) ?? PackLoader.Roots[0];
			Directory.CreateDirectory(root);
			string name = Path.GetFileNameWithoutExtension(zip);
			System.IO.Compression.ZipFile.ExtractToDirectory(zip, root);
			// The .zip is only a delivery vehicle - once its contents are in
			// CustomEvents/ it is pure clutter, so it is deleted, not archived.
			File.Delete(zip);
			SweepImportedDirs();
			Log.Info("imported pack zip " + zip + " -> " + root + " (archive removed)");
			SetStatus("已导入 " + name + "，正在重启游戏…");
			RestartGame();
		}
		catch (Exception e)
		{
			Log.Error("ImportZipFile", e);
			SetStatus("导入失败: " + e.Message);
		}
	}

	internal void LoadPack(Pack pack)
	{
		// Option C: route straight to the standalone explorer. No LteServer, no EventController,
		// no event scene - the pack's own tree.json is rendered directly. This replaces the old
		// PackLoader.Load -> EnterEvent chain that had to fake the live-ops state machine.
		try
		{
			TreeDefinition tree = TreeDefinition.Load(pack.TreePath);
			if (tree != null && tree.Nodes != null && tree.Nodes.Count > 0)
			{
				SetStatus("已加载: " + pack.Title);
				Hide();
				_open = false;
				_stagedTree = tree;
				_stagedPackName = string.IsNullOrEmpty(pack.FolderName) ? pack.Id : pack.FolderName;
				// good tree: fall THROUGH to PackLoader.Load -> EnterEvent so the game's own
				// EventController renders it with the original exploration UI and logic.
			}
			else
			{
				// only a damaged/empty tree falls back to the standalone viewer
				Log.Warn("tree at " + pack.TreePath + " has no nodes - using the standalone viewer");
				CustomExplorer.Launch(tree, string.IsNullOrEmpty(pack.FolderName) ? pack.Id : pack.FolderName);
				return;
			}
		}
		catch (Exception e) { Log.Error("standalone route failed", e); }
		if (!PackLoader.Load(pack, out var error))
		{
			SetStatus("加载失败: " + error);
			Log.Error("load failed: " + error);
		}
		else
		{
			SetStatus("已加载: " + pack.Title + "，正在进入活动场景…");
			Hide();
			_open = false;
		}
	}
}
internal class Pack
{
	public string Dir;

	public string FolderName;

	public string TreePath;

	public string ManifestPath;

	public string Id;

	public string Title;

	public string Subtitle;

	public string BannerPath;

	public string ButtonPath;

	public int CurrencyCount = -1;

	public string[] IntroLines;

	public string[] OutroLines;

	public List<CurrencyDef> Currencies = new List<CurrencyDef>();

	public string TapHint;

	public string ResourceName;

	public string ResourceIcon;

	public string CurrencySpriteFrom;

	public List<BackgroundDef> Backgrounds = new List<BackgroundDef>();

	// The pack's SINGLE background image (pack.json "background"), resolved to an
	// absolute path. The legacy "backgrounds" array is still honoured for packs
	// written by older editor builds; this field wins when both are present.
	public string Background;

	public List<KeyValuePair<string, string>> Localization = new List<KeyValuePair<string, string>>();

	public List<RankDef> Ranks = new List<RankDef>();

	public bool Valid;

	public string Error = "";

	public int NodeCount;
}
internal class BackgroundDef
{
	public string File;

	public bool Visible = true;
}
internal class CurrencyDef
{
	public string Name = "";

	public string Icon;
}
internal class RankDef
{
	public string Title = "Rank 1";

	public double TargetHrs = 1.0;

	public List<MissionDef> Missions = new List<MissionDef>();
}
internal class MissionDef
{
	public string Type = "Collect";

	public string ReqItemId = "";

	public double ReqAmount = 1.0;

	public string PrizeType = "Darwinium";

	public string PrizeId = "";

	public double PrizeAmount = 1.0;

	public bool Hidden;

	public string TreeType = "NONE";

	public List<KeyValuePair<string, double>> Targets = new List<KeyValuePair<string, double>>();
}
internal static class PackLoader
{
	internal static Pack LastLoaded;

	internal static bool CustomEventActive;

	private const string TERM_SOURCE_NAME = "cepack_terms";

	private const string EVENT_SOURCE_NAME = "i2_lte_EventImport";

	private static LanguageSourceData _termSource;

	internal static readonly List<KeyValuePair<string, string>> PendingTerms = new List<KeyValuePair<string, string>>();

	private static bool _outroShown;

	private static string _lastProbe;

	private static string _lastDump;

	private static int _bgTries;

	private static bool _bgDone;

	private static float _bgAge;

	private static bool _bgDumped;

	internal static List<string> Roots
	{
		get
		{
			List<string> list = new List<string>();
			try
			{
				list.Add(Path.Combine(Application.persistentDataPath, "CustomEvents"));
			}
			catch
			{
			}
			try
			{
				list.Add(Path.Combine(Application.dataPath, "CustomEvents"));
			}
			catch
			{
			}
			try
			{
				list.Add(Path.Combine(Application.streamingAssetsPath, "CustomEvents"));
			}
			catch
			{
			}
			return list;
		}
	}

	internal static string GameTreeDir => Path.Combine(Application.persistentDataPath, "generated-tree");

	internal static void AddTermPublic(string key, string value)
	{
		AddTerm(key, value);
	}

	private static void AddTerm(string key, string value)
	{
		if (!string.IsNullOrEmpty(key))
		{
			PendingTerms.Add(new KeyValuePair<string, string>(key, value ?? ""));
		}
	}

	private static LanguageSourceData MakeSource(string goName)
	{
		LanguageSourceData languageSourceData = LocalizationManager.Sources.Find((LanguageSourceData s) => s != null && s.ownerObject != null && s.ownerObject.name == goName);
		if (languageSourceData != null)
		{
			return languageSourceData;
		}
		GameObject gameObject = new GameObject(goName);
		UnityEngine.Object.DontDestroyOnLoad(gameObject);
		gameObject.AddComponent<LanguageSource>();
		return LocalizationManager.Sources.Find((LanguageSourceData s) => s != null && s.ownerObject != null && s.ownerObject.name == goName);
	}

	private static LanguageSourceData GetTermSource()
	{
		if (_termSource != null)
		{
			return _termSource;
		}
		_termSource = MakeSource("cepack_terms");
		try
		{
			if (_termSource != null && LocalizationManager.Sources.IndexOf(_termSource) > 0)
			{
				LocalizationManager.Sources.Remove(_termSource);
				LocalizationManager.Sources.Insert(0, _termSource);
				Log.Info("term source promoted to index 0 (overrides take priority)");
			}
		}
		catch (Exception ex)
		{
			Log.Warn("promoting term source: " + ex.Message);
		}
		if (_termSource != null && (_termSource.mLanguages == null || _termSource.mLanguages.Count == 0))
		{
			LanguageSourceData languageSourceData = LocalizationManager.Sources.Find((LanguageSourceData s) => s != null && s != _termSource && s.mLanguages != null && s.mLanguages.Count > 0);
			if (languageSourceData != null)
			{
				foreach (LanguageData mLanguage in languageSourceData.mLanguages)
				{
					if (mLanguage != null)
					{
						_termSource.AddLanguage(mLanguage.Name, mLanguage.Code);
					}
				}
			}
		}
		return _termSource;
	}

	internal static void FlushTerms()
	{
		try
		{
			LanguageSourceData termSource = GetTermSource();
			if (termSource == null)
			{
				Log.Warn("term source unavailable");
				return;
			}
			int num = ((termSource.mLanguages != null) ? termSource.mLanguages.Count : 0);
			if (num == 0)
			{
				termSource.AddLanguage("English", "en");
				num = ((termSource.mLanguages != null) ? termSource.mLanguages.Count : 0);
			}
			if (num == 0)
			{
				Log.Warn("term source has no languages");
				return;
			}
			int num2 = 0;
			foreach (KeyValuePair<string, string> pendingTerm in PendingTerms)
			{
				TermData termData = termSource.AddTerm(pendingTerm.Key, eTermType.Text, SaveSource: false);
				if (termData != null && termData.Languages != null)
				{
					int num3 = Math.Min(num, termData.Languages.Length);
					for (int i = 0; i < num3; i++)
					{
						termData.Languages[i] = pendingTerm.Value;
					}
					num2++;
				}
			}
			termSource.UpdateDictionary(force: true);
			Log.Info("terms flushed: " + num2 + " term(s) x " + num + " language(s)");
		}
		catch (Exception ex)
		{
			Log.Warn("FlushTerms: " + ex.Message);
		}
	}

	private static DialogCollection MakeDialog(string prefix, string[] lines, string fallback)
	{
		DialogCollection dialogCollection = ScriptableObject.CreateInstance<DialogCollection>();
		dialogCollection.name = "cepack_dialog_" + prefix;
		int num = ((lines == null || lines.Length == 0) ? 1 : lines.Length);
		if (lines == null || lines.Length == 0)
		{
			lines = new string[1] { fallback };
		}
		Dialog dialog = new Dialog
		{
			dialog = new string[num]
		};
		for (int i = 0; i < num; i++)
		{
			string text = "cepack_" + prefix + "_" + i;
			AddTerm(text, lines[i]);
			dialog.dialog[i] = text;
		}
		dialogCollection.dialogCollection = new Dialog[1] { dialog };
		return dialogCollection;
	}

	internal static List<Pack> Discover()
	{
		List<Pack> list = new List<Pack>();
		HashSet<string> hashSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
		foreach (string root in Roots)
		{
			if (!Directory.Exists(root))
			{
				continue;
			}
			string[] directories;
			try
			{
				directories = Directory.GetDirectories(root);
			}
			catch
			{
				continue;
			}
			Array.Sort(directories, StringComparer.OrdinalIgnoreCase);
			string[] array = directories;
			foreach (string text in array)
			{
				string fileName = Path.GetFileName(text);
				if (!fileName.StartsWith("_") && !fileName.StartsWith(".") && hashSet.Add(fileName))
				{
					list.Add(Inspect(text));
				}
			}
		}
		return list;
	}

	private static Pack Inspect(string dir)
	{
		Pack pack = new Pack
		{
			Dir = dir,
			FolderName = Path.GetFileName(dir),
			ManifestPath = Path.Combine(dir, "pack.json"),
			TreePath = null,
			Id = Path.GetFileName(dir),
			Title = Path.GetFileName(dir),
			Subtitle = ""
		};
		try
		{
			if (File.Exists(pack.ManifestPath))
			{
				JObject jObject = JObject.Parse(File.ReadAllText(pack.ManifestPath));
				pack.Id = Str(jObject, "id") ?? pack.Id;
				pack.Title = Str(jObject, "title") ?? Str(jObject, "name") ?? pack.Title;
				pack.Subtitle = Str(jObject, "subtitle") ?? Str(jObject, "description") ?? "";
				if (TryInt(jObject, "currencyCount", out var v))
				{
					pack.CurrencyCount = v;
				}
				string text = Str(jObject, "banner");
				if (!string.IsNullOrEmpty(text))
				{
					pack.BannerPath = Resolve(dir, text);
				}
				string text2 = Str(jObject, "button") ?? Str(jObject, "icon");
				if (!string.IsNullOrEmpty(text2))
				{
					pack.ButtonPath = Resolve(dir, text2);
				}
				pack.IntroLines = ReadLines(jObject, "intro");
				pack.OutroLines = ReadLines(jObject, "outro");
				pack.TapHint = Str(jObject, "tapHint");
				pack.CurrencySpriteFrom = Str(jObject, "currencySpriteFrom");
				if (jObject["backgrounds"] is JArray jArray)
				{
					foreach (JToken item in jArray)
					{
						if (item == null || item.Type != JTokenType.Object)
						{
							continue;
						}
						BackgroundDef backgroundDef = new BackgroundDef();
						string text3 = Str((JObject)item, "file");
						if (!string.IsNullOrEmpty(text3))
						{
							backgroundDef.File = Resolve(dir, text3);
						}
						JToken jToken = item["visible"];
						if (jToken != null)
						{
							try
							{
								backgroundDef.Visible = jToken.Value<bool>();
							}
							catch
							{
							}
						}
						if (backgroundDef.File != null)
						{
							pack.Backgrounds.Add(backgroundDef);
						}
					}
				}
				string bgOne = Str(jObject, "background");
				if (!string.IsNullOrEmpty(bgOne))
				{
					pack.Background = Resolve(dir, bgOne);
				}
				pack.ResourceName = Str(jObject, "resourceName");
				string text4 = Str(jObject, "resourceIcon");
				if (!string.IsNullOrEmpty(text4))
				{
					pack.ResourceIcon = Resolve(dir, text4);
				}
				if (jObject["currencies"] is JArray jArray2)
				{
					foreach (JToken item2 in jArray2)
					{
						if (item2 == null)
						{
							continue;
						}
						CurrencyDef currencyDef = new CurrencyDef();
						if (item2.Type == JTokenType.String)
						{
							currencyDef.Name = item2.ToString();
						}
						else
						{
							currencyDef.Name = Str((JObject)item2, "name") ?? "";
							string text5 = Str((JObject)item2, "icon");
							if (!string.IsNullOrEmpty(text5))
							{
								currencyDef.Icon = Resolve(dir, text5);
							}
						}
						pack.Currencies.Add(currencyDef);
					}
				}
				if (jObject["localization"] is JObject jObject2)
				{
					foreach (JProperty item3 in jObject2.Properties())
					{
						pack.Localization.Add(new KeyValuePair<string, string>(item3.Name, (item3.Value != null) ? item3.Value.ToString() : ""));
					}
				}
				if (jObject["missions"] is JArray jArray3)
				{
					foreach (JToken item4 in jArray3)
					{
						if (item4 == null)
						{
							continue;
						}
						if (item4.Type != JTokenType.Object)
						{
							RankDef rankDef = new RankDef();
							rankDef.Missions.Add(ParseMission((JObject)item4));
							pack.Ranks.Add(rankDef);
							continue;
						}
						JObject jObject3 = (JObject)item4;
						RankDef rankDef2 = new RankDef();
						rankDef2.Title = Str(jObject3, "title") ?? Str(jObject3, "name") ?? ("Rank " + (pack.Ranks.Count + 1));
						if (TryDouble(jObject3["targetHrs"] ?? jObject3["hours"], out var v2))
						{
							rankDef2.TargetHrs = v2;
						}
						if ((jObject3["missions"] ?? jObject3["tasks"]) is JArray jArray4)
						{
							foreach (JToken item5 in jArray4)
							{
								if (item5 is JObject)
								{
									rankDef2.Missions.Add(ParseMission((JObject)item5));
								}
							}
						}
						pack.Ranks.Add(rankDef2);
					}
				}
				string text6 = Str(jObject, "tree");
				if (!string.IsNullOrEmpty(text6))
				{
					pack.TreePath = Resolve(dir, text6);
				}
				JToken jToken2 = jObject["treeData"] ?? jObject["treeDefinition"];
				if (pack.TreePath == null && jToken2 is JObject)
				{
					pack.TreePath = Path.Combine(dir, "pack.json#treeData");
				}
			}
			if (pack.TreePath == null)
			{
				string[] array = new string[3] { "tree.json", "json.json", "tree.jsonc" };
				foreach (string path in array)
				{
					string text7 = Path.Combine(dir, path);
					if (File.Exists(text7))
					{
						pack.TreePath = text7;
						break;
					}
				}
			}
			if (pack.TreePath == null)
			{
				string text8 = Directory.GetFiles(dir, "*.json").FirstOrDefault((string f) => !string.Equals(Path.GetFileName(f), "pack.json", StringComparison.OrdinalIgnoreCase));
				if (text8 != null)
				{
					pack.TreePath = text8;
				}
			}
			if (pack.TreePath == null)
			{
				pack.Error = "找不到 tree.json";
				return pack;
			}
			TreeDefinition treeDefinition = TreeDefinition.Load(pack.TreePath);
			pack.NodeCount = treeDefinition.Nodes.Count;
			if (!string.IsNullOrEmpty(treeDefinition.Title) && pack.Title == pack.FolderName)
			{
				pack.Title = treeDefinition.Title;
			}
			pack.Subtitle += ((pack.NodeCount > 0) ? ("  ·  " + pack.NodeCount + " 个节点") : "");
			pack.Valid = treeDefinition.Validate(out pack.Error);
		}
		catch (Exception ex)
		{
			pack.Error = ex.Message;
			pack.Valid = false;
		}
		return pack;
	}

	private static string Resolve(string dir, string rel)
	{
		try
		{
			if (Path.IsPathRooted(rel))
			{
				return rel;
			}
			return Path.GetFullPath(Path.Combine(dir, rel));
		}
		catch
		{
			return null;
		}
	}

	private static string[] ReadLines(JObject o, string key)
	{
		JToken jToken = o[key];
		if (jToken == null || jToken.Type == JTokenType.Null)
		{
			return null;
		}
		if (jToken.Type == JTokenType.String)
		{
			return new string[1] { jToken.ToString() };
		}
		if (jToken.Type == JTokenType.Array)
		{
			return ((JArray)jToken).Select((JToken x) => x.ToString()).ToArray();
		}
		return null;
	}

	private static MissionDef ParseMission(JObject o)
	{
		MissionDef missionDef = new MissionDef();
		missionDef.Type = Str(o, "type") ?? "Collect";
		missionDef.ReqItemId = Str(o, "reqItemId") ?? Str(o, "item") ?? "";
		if (TryDouble(o["reqAmount"] ?? o["amount"], out var v))
		{
			missionDef.ReqAmount = v;
		}
		missionDef.PrizeType = Str(o, "prizeType") ?? "Darwinium";
		missionDef.PrizeId = Str(o, "prizeID") ?? Str(o, "prizeId") ?? "";
		if (TryDouble(o["prizeAmount"], out v))
		{
			missionDef.PrizeAmount = v;
		}
		missionDef.TreeType = Str(o, "treeType") ?? "NONE";
		if ((o["targets"] ?? o["requires"]) is JArray jArray)
		{
			foreach (JToken item in jArray)
			{
				if (item == null)
				{
					continue;
				}
				if (item.Type == JTokenType.String)
				{
					missionDef.Targets.Add(new KeyValuePair<string, double>(item.ToString(), 1.0));
					continue;
				}
				string text = Str((JObject)item, "item") ?? Str((JObject)item, "reqItemId") ?? Str((JObject)item, "uid");
				double v2 = 1.0;
				TryDouble(item["amount"] ?? item["reqAmount"], out v2);
				if (!string.IsNullOrEmpty(text))
				{
					missionDef.Targets.Add(new KeyValuePair<string, double>(text, v2));
				}
			}
		}
		JToken jToken = o["hidden"];
		if (jToken != null)
		{
			try
			{
				missionDef.Hidden = jToken.Value<bool>();
			}
			catch
			{
			}
		}
		return missionDef;
	}

	internal static string Str(JObject o, string key)
	{
		JToken jToken = o[key];
		if (jToken != null && jToken.Type != JTokenType.Null)
		{
			return jToken.ToString();
		}
		return null;
	}

	internal static bool TryInt(JObject o, string key, out int v)
	{
		v = 0;
		JToken jToken = o[key];
		if (jToken == null || jToken.Type == JTokenType.Null)
		{
			return false;
		}
		try
		{
			v = jToken.Value<int>();
			return true;
		}
		catch
		{
			return false;
		}
	}

	internal static bool TryDouble(JToken t, out double v)
	{
		v = 0.0;
		if (t == null || t.Type == JTokenType.Null)
		{
			return false;
		}
		if (t.Type == JTokenType.Float || t.Type == JTokenType.Integer)
		{
			try
			{
				v = t.Value<double>();
				return true;
			}
			catch
			{
				return false;
			}
		}
		if (t.Type == JTokenType.String)
		{
			return double.TryParse(t.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out v);
		}
		return false;
	}

	internal static bool Load(Pack pack, out string error)
	{
		error = "";
		try
		{
			TreeDefinition treeDefinition = TreeDefinition.Load(pack.TreePath);
			if (!treeDefinition.Validate(out error))
			{
				return false;
			}
			string gameTreeDir = GameTreeDir;
			Directory.CreateDirectory(gameTreeDir);
			string text = GameJson.Build(treeDefinition, out var how);
			string text2 = Path.Combine(gameTreeDir, "json.json");
			File.WriteAllText(text2, text, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
			string text3 = GameJson.RoundTrip(text, treeDefinition.Nodes.Count);
			Log.Info("staged tree (" + treeDefinition.Nodes.Count + " nodes, encoding=" + how + ") -> " + text2);
			Log.Info("staged tree verification: " + text3);
			if (!text3.EndsWith("OK"))
			{
				error = "树的 JSON 无法被游戏反序列化: " + text3;
				return false;
			}
			string[] files = Directory.GetFiles(gameTreeDir, "*.png");
			foreach (string path in files)
			{
				try
				{
					File.Delete(path);
				}
				catch
				{
				}
			}
			Log.Info("staged " + StageIcons(pack, treeDefinition, gameTreeDir) + " icon(s) -> " + gameTreeDir);
			LTEData lTEData = EnsureImportEvent(pack, treeDefinition);
			if (lTEData == null)
			{
				error = "无法准备 import 事件数据";
				return false;
			}
			FlushTerms();
			try
			{
				ApplyPresentation(pack, lTEData, treeDefinition);
			}
			catch (Exception ex)
			{
				Log.Warn("presentation: " + ex.Message);
			}
			LastLoaded = pack;
			CustomEventActive = true;
			ResetOutro();
			SwitchPackSave(pack);
			EnterEvent(lTEData);
			return true;
		}
		catch (Exception ex2)
		{
			error = ex2.Message;
			Log.Error("Load", ex2);
			return false;
		}
	}

	private static int StageIcons(Pack pack, TreeDefinition tree, string dir)
	{
		int num = 0;
		foreach (TreeNodeDef node in tree.Nodes)
		{
			string text = FindIcon(pack, node.Uid);
			if (text == null)
			{
				continue;
			}
			string text2 = Path.Combine(dir, node.Uid + ".png");
			try
			{
				if (string.Equals(Path.GetExtension(text), ".png", StringComparison.OrdinalIgnoreCase))
				{
					File.Copy(text, text2, overwrite: true);
					goto IL_009c;
				}
				Texture2D texture2D = new Texture2D(2, 2, TextureFormat.RGBA32, mipChain: false);
				if (!texture2D.LoadImage(File.ReadAllBytes(text)))
				{
					UnityEngine.Object.Destroy(texture2D);
					continue;
				}
				File.WriteAllBytes(text2, texture2D.EncodeToPNG());
				UnityEngine.Object.Destroy(texture2D);
				goto IL_009c;
				IL_009c:
				num++;
			}
			catch (Exception ex)
			{
				Log.Warn("icon '" + node.Uid + "' failed: " + ex.Message);
			}
		}
		return num;
	}

	private static string FindIcon(Pack pack, string uid)
	{
		string[] array = new string[3] { ".png", ".jpg", ".jpeg" };
		foreach (string item in new List<string>
		{
			Path.Combine(pack.Dir, "icons"),
			Path.Combine(pack.Dir, "Icons"),
			pack.Dir
		})
		{
			string[] array2 = array;
			foreach (string text in array2)
			{
				string text2 = Path.Combine(item, uid + text);
				if (File.Exists(text2))
				{
					return text2;
				}
			}
		}
		return null;
	}

	internal static void EnsureLangSource()
	{
		try
		{
			LanguageSourceData src = MakeSource("i2_lte_EventImport");
			Log.Info("i2 source 'i2_lte_EventImport' -> " + ((src != null) ? "ok" : "FAILED"));
			if (src == null || (src.mLanguages != null && src.mLanguages.Count != 0))
			{
				return;
			}
			LanguageSourceData languageSourceData = LocalizationManager.Sources.Find((LanguageSourceData s) => s != null && s != src && s.mLanguages != null && s.mLanguages.Count > 0);
			if (languageSourceData != null)
			{
				foreach (LanguageData mLanguage in languageSourceData.mLanguages)
				{
					if (mLanguage != null)
					{
						src.AddLanguage(mLanguage.Name, mLanguage.Code);
					}
				}
			}
			Log.Info("event source languages seeded: " + ((src.mLanguages != null) ? src.mLanguages.Count : 0));
		}
		catch (Exception e)
		{
			Log.Error("EnsureLangSource", e);
		}
	}


	internal static void RegisterCustomEvent(Pack pack, TreeDefinition tree)
	{
		LteServer.openedfromDebug = true;
		TreeGenPlayer.TestActive = true;
		LteServer server = Singleton<LteServer>.instance;
		System.Reflection.BindingFlags flags = System.Reflection.BindingFlags.Instance
			| System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public;

		// 1. forcedEvent through the ENUM overload, so its ToString() is an exact event id.
		LteServer.ForceEvent(LteServer.EventId.import);

		// 2. make lte.id and savedEventId agree with whatever forcedEvent resolved to.
		string eventId = null;
		try
		{
			System.Reflection.FieldInfo fe = typeof(LteServer).GetField("forcedEvent", flags);
			if (fe != null && server != null) eventId = Convert.ToString(fe.GetValue(server));
		}
		catch (Exception e) { Log.Warn("forcedEvent read: " + e.Message); }
		if (string.IsNullOrEmpty(eventId)) eventId = LteServer.EventId.import.ToString();

		if (server != null)
		{
			System.Reflection.MemberInfo lteMember =
				(System.Reflection.MemberInfo)typeof(LteServer).GetField("lte", flags)
				?? (System.Reflection.MemberInfo)typeof(LteServer).GetProperty("lte", flags);
			object lte = null;
			System.Reflection.FieldInfo lf = lteMember as System.Reflection.FieldInfo;
			System.Reflection.PropertyInfo lp = lteMember as System.Reflection.PropertyInfo;
			if (lf != null) lte = lf.GetValue(server);
			else if (lp != null) lte = lp.GetValue(server, null);
			if (lte == null && lteMember != null)
			{
				Type wt2 = lf != null ? lf.FieldType : lp.PropertyType;
				lte = Activator.CreateInstance(wt2);
				if (lf != null) lf.SetValue(server, lte); else lp.SetValue(server, lte, null);
				Log.Info("created LteServer.lte - the server event record was null");
			}
			if (lte != null)
			{
				Type wt = lte.GetType();
				wt.GetField("id", flags)?.SetValue(lte, eventId);
				wt.GetField("name", flags)?.SetValue(lte, eventId);
				wt.GetField("savedEventId", flags)?.SetValue(lte, eventId);
				wt.GetField("req", flags)?.SetValue(lte, "0.0.0");
				DateTime now = DateTime.UtcNow;
				wt.GetField("promoDateTime", flags)?.SetValue(lte, now.AddYears(-1));
				wt.GetField("startDateTime", flags)?.SetValue(lte, now.AddDays(-1));
				wt.GetField("endDateTime", flags)?.SetValue(lte, now.AddYears(10));
			}
		}
		// 3. declare the server state resolved. A local pack involves no server, but
		// EventController.Awake() branches on it:
		//     if (LteServer.state != SERVER_LOADING) InitGame();
		//     else LteServerReadyCallBack += InitGame;   // only a live server fires this
		// Left at SERVER_LOADING the whole event parks on that callback forever and the
		// "Connecting..." preloader never goes away. This is declaring readiness for local
		// content, not faking a value the game depends on being server-derived.
		try
		{
			// NB: LteServer.state is STATIC - it needs BindingFlags.Static (the instance-only
			// flags above make GetField return null and this block silently does nothing).
			System.Reflection.FieldInfo stateField = typeof(LteServer).GetField("state",
				System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public);
			if (stateField != null)
			{
				object cur = stateField.GetValue(null);
				if (Convert.ToString(cur) == "SERVER_LOADING")
				{
					stateField.SetValue(null, Enum.Parse(stateField.FieldType, "ACTIVE"));
					Log.Info("LteServer.state SERVER_LOADING -> ACTIVE (local pack needs no server; this is what lets InitGame run instead of waiting on the server-ready callback)");
				}
			}
		}
		catch (Exception e) { Log.Warn("state resolve: " + e.Message); }

		// 4. bForceReset was computed inside ForceReloadEventParams() BEFORE the ids were
		// synced above, so it is a stale true. Re-run it now that lte.id == forcedEvent:
		//     bForceReset = lte.id != forcedEvent.ToString();   // now false
		try { LteServer.ForceReloadEventParams(); } catch (Exception e) { Log.Warn("re-resolve: " + e.Message); }

		// 5. Resolve Mission.reqItem for EVERY rank's missions up front. The game fills this
		// plain field in MissionController.AddMission(), which we never call for the FIRST rank
		// (ResolveMissionReqItems was only ever invoked from MaybeAdvanceStage, i.e. when
		// advancing to the NEXT rank). With reqItem == null, MissionGroup.GetIcon() throws
		//     return reqItem.icon;			// NullReferenceException
		// from MissionController.UpdateMission(), which is called by InitGame() two statements
		// BEFORE StartCoroutine(DelayStartGame()). That aborts InitGame, StartGame never runs,
		// EventController.state stays NOT_LOADED and the "Connecting..." preloader never closes.
		try
		{
			int resolvedRanks = 0;
			RankRule rule = (server != null && server.loadedData != null) ? server.loadedData.rankData : null;
			if (rule != null && rule.ranks != null)
			{
				foreach (Rank rk in rule.ranks)
				{
					if (rk == null || rk.missions == null) continue;
					ResolveMissionReqItems(rk.missions);
					resolvedRanks++;
				}
			}
			Log.Info("resolved Mission.reqItem across " + resolvedRanks + " rank(s) before InitGame");
		}
		catch (Exception e) { Log.Warn("resolve reqItem: " + e.Message); }

		Log.Info("registered custom event id='" + eventId + "' consistently (lte.id == forcedEvent, so bForceReset is false by construction)");
	}

	internal static LTEData EnsureImportEvent(Pack pack, TreeDefinition tree)
	{
		LteServer instance = Singleton<LteServer>.instance;
		if (instance == null)
		{
			Log.Error("LteServer.instance is null");
			return null;
		}
		MasterLtEDatabase masterLteData = instance.masterLteData;
		if (masterLteData == null)
		{
			Log.Error("masterLteData is null");
			return null;
		}
		if (masterLteData.lteData == null)
		{
			masterLteData.lteData = new List<LTEData>();
		}
		LTEData lte = masterLteData.FindLteData("import");
		if (lte == null)
		{
			Log.Warn("no built-in 'import' LTEData; synthesising one");
			lte = ScriptableObject.CreateInstance<LTEData>();
			lte.name = "LTEData_import_custom";
			lte.LTE_Name = "import";
			masterLteData.lteData.Add(lte);
		}
		string text = (string.IsNullOrEmpty(pack.Title) ? tree.Title : pack.Title);
		AddTerm("cepack_event_title", tree.Title);
		AddTerm("cepack_event_subject", text);
		AddTerm("cepack_event_logline", pack.Subtitle);
		foreach (TreeNodeDef node in tree.Nodes)
		{
			AddTerm(node.Uid, node.Title);
			AddTerm(node.Uid + "_desc", node.Description);
		}
		lte.loadMode = EventMode.PersistentData;
		lte.titleTxt = "cepack_event_title";
		lte.subjectTxt = "cepack_event_subject";
		lte.loglineKey = "cepack_event_logline";
		if (lte.rankData == null)
		{
			lte.rankData = FindTemplateRankRule(masterLteData);
		}
		if (lte.currencyCount <= 0)
		{
			lte.currencyCount = 2;
		}
		if (lte.maxBenchmarkScore <= 0)
		{
			lte.maxBenchmarkScore = 1000;
		}
		if (string.IsNullOrEmpty(lte.bgm))
		{
			lte.bgm = "bgm06";
		}
		Log.Info("LTE fields: titleTxt='" + lte.titleTxt + "' subjectTxt='" + lte.subjectTxt + "' loglineKey='" + lte.loglineKey + "' currencyCount=" + lte.currencyCount + " bgm='" + lte.bgm + "' rankData=" + ((lte.rankData == null) ? "null" : "ok") + " buttonIcon=" + ((lte.buttonIcon == null) ? "null" : "ok") + " keyArtBanner=" + ((lte.keyArtBanner == null) ? "null" : "ok"));
		if (lte.currencyOne == null || lte.currencyTwo == null)
		{
			try
			{
				LTEData lTEData = masterLteData.lteData.Find((LTEData d) => d != null && (object)d != lte && d.currencyOne != null && !string.IsNullOrEmpty(pack.CurrencySpriteFrom) && string.Equals(d.LTE_Name, pack.CurrencySpriteFrom, StringComparison.OrdinalIgnoreCase));
				if (lTEData == null)
				{
					lTEData = masterLteData.lteData.FirstOrDefault((LTEData d) => d != null && (object)d != lte && d.currencyOne != null);
				}
				if (lTEData != null)
				{
					if (lte.currencyOne == null)
					{
						lte.currencyOne = lTEData.currencyOne;
						lte.currencyOneKey = lTEData.currencyOneKey;
					}
					if (lte.currencyTwo == null)
					{
						lte.currencyTwo = lTEData.currencyTwo;
						lte.currencyTwoKey = lTEData.currencyTwoKey;
					}
					Log.Info("borrowed currency icons from '" + lTEData.LTE_Name + "'" + (string.IsNullOrEmpty(pack.CurrencySpriteFrom) ? " (auto)" : " (requested)"));
				}
				else
				{
					Log.Warn("no donor LTEData with currency sprites; bank icons will show the game's fallback tag");
				}
			}
			catch (Exception ex)
			{
				Log.Warn("currency icons: " + ex.Message);
			}
		}
		EventContent.ApplyCurrencies(pack, lte);
		EventContent.ApplyMissions(pack, lte);
		EventContent.ApplyLocalisation(pack);
		EnsureLangSource();
		Lte_PrefabData lte_PrefabData = masterLteData.FindLtePrefabData("import");
		if (lte_PrefabData == null)
		{
			if (!(Environment.GetEnvironmentVariable("CUSTOM_EVENT_PACK_SYNTH") != "0"))
			{
				Log.Warn("no 'import' Lte_PrefabData and synthesis disabled");
				return lte;
			}
			Lte_PrefabData lte_PrefabData2 = null;
			try
			{
				Lte_PrefabData[] array = Resources.LoadAll<Lte_PrefabData>("");
				Log.Info("Resources Lte_PrefabData: " + array.Length + " [" + string.Join(",", (from x in array
					where x != null
					select x.lteName).ToArray()) + "]");
				lte_PrefabData2 = array.FirstOrDefault((Lte_PrefabData x) => x != null && x.lteName == "import");
			}
			catch (Exception ex2)
			{
				Log.Warn("Resources Lte_PrefabData probe: " + ex2.Message);
			}
			if (lte_PrefabData2 == null)
			{
				try
				{
					if (masterLteData.ltePrefabData != null)
					{
						// Borrow the JAMES WEBB event's scene so the custom event looks like an
						// official one. Falling back to "the first entry with tree data" gave the
						// fetus-womb presentation (red 'Pink Donut' backdrop), which is what the
						// whole custom-background hunt was fighting.
						lte_PrefabData2 = masterLteData.ltePrefabData.FirstOrDefault((Lte_PrefabData x) => x != null && x.lteName == "webb");
						Log.Info("template: master ltePrefabData = [" + string.Join(", ",
							masterLteData.ltePrefabData.Where((Lte_PrefabData x) => x != null)
								.Select((Lte_PrefabData x) => x.lteName + (x.treeData != null ? "*" : "")).ToArray()) + "]");
						if (lte_PrefabData2 != null)
						{
							Log.Info("template: using the James Webb event scene");
						}
						else
						{
							lte_PrefabData2 = masterLteData.ltePrefabData.FirstOrDefault((Lte_PrefabData x) => x != null && x.treeData != null);
							Log.Warn("template: no 'webb' prefab data, falling back to '" +
							         ((lte_PrefabData2 != null) ? lte_PrefabData2.lteName : "none") + "'");
						}
					}
				}
				catch
				{
				}
			}
			Log.Warn("synthesising 'import' Lte_PrefabData (template=" + ((lte_PrefabData2 == null) ? "none" : lte_PrefabData2.lteName) + ")");
			LTE_Tree lTE_Tree = ScriptableObject.CreateInstance<LTE_Tree>();
			lTE_Tree.name = "EventImport";
			lTE_Tree.nodes = new ItemInfo[0];
			Lte_PrefabData lte_PrefabData3 = ScriptableObject.CreateInstance<Lte_PrefabData>();
			lte_PrefabData3.name = "Lte_PrefabData_import_custom";
			lte_PrefabData3.lteName = "import";
			lte_PrefabData3.treeData = lTE_Tree;
			lte_PrefabData3.startScene = MakeDialog("intro", pack.IntroLines, "「" + text + "」勘探开始");
			lte_PrefabData3.endScene = MakeDialog("outro", pack.OutroLines, "「" + text + "」勘探完成");
			TreeNodeDef treeNodeDef = tree.Nodes.LastOrDefault((TreeNodeDef n) => n.Category == CategoryType.TROPHY) ?? ((tree.Nodes.Count > 0) ? tree.Nodes[tree.Nodes.Count - 1] : null);
			if (treeNodeDef != null)
			{
				lte_PrefabData3.finalCSInfo = treeNodeDef.Uid;
			}
			if (lte_PrefabData2 != null)
			{
				lte_PrefabData3.gardenObj = lte_PrefabData2.gardenObj;
				lte_PrefabData3.treeBackground = lte_PrefabData2.treeBackground;
				lte_PrefabData3.treeObject = lte_PrefabData2.treeObject;
				Log.Info("borrowed presentation from '" + lte_PrefabData2.lteName + "'");
			}
			if (masterLteData.ltePrefabData == null)
			{
				masterLteData.ltePrefabData = new List<Lte_PrefabData>();
			}
			masterLteData.ltePrefabData.Add(lte_PrefabData3);
		}
		else
		{
			if (lte_PrefabData.startScene == null)
			{
				lte_PrefabData.startScene = MakeDialog("intro", pack.IntroLines, "「" + text + "」勘探开始");
			}
			if (lte_PrefabData.endScene == null)
			{
				lte_PrefabData.endScene = MakeDialog("outro", pack.OutroLines, "「" + text + "」勘探完成");
			}
			if (string.IsNullOrEmpty(lte_PrefabData.finalCSInfo))
			{
				TreeNodeDef treeNodeDef2 = tree.Nodes.LastOrDefault((TreeNodeDef n) => n.Category == CategoryType.TROPHY) ?? ((tree.Nodes.Count > 0) ? tree.Nodes[tree.Nodes.Count - 1] : null);
				if (treeNodeDef2 != null)
				{
					lte_PrefabData.finalCSInfo = treeNodeDef2.Uid;
				}
			}
			Log.Info("import prefab from master db: startScene=" + ((lte_PrefabData.startScene == null) ? "null" : "ok") + " endScene=" + ((lte_PrefabData.endScene == null) ? "null" : "ok"));
		}
		return lte;
	}

	private static RankRule FindTemplateRankRule(MasterLtEDatabase db)
	{
		try
		{
			if (db.lteData != null)
			{
				foreach (LTEData lteDatum in db.lteData)
				{
					if (lteDatum != null && lteDatum.rankData != null && lteDatum.rankData.ranks != null && lteDatum.rankData.ranks.Length != 0)
					{
						return lteDatum.rankData;
					}
				}
			}
		}
		catch
		{
		}
		RankRule rankRule = ScriptableObject.CreateInstance<RankRule>();
		rankRule.name = "RankRule_custom";
		rankRule.ranks = new Rank[1];
		rankRule.ranks[0] = new Rank
		{
			title = "Rank 1",
			targetHrs = 1f,
			missions = new Mission[0]
		};
		return rankRule;
	}

	private static void ApplyPresentation(Pack pack, LTEData lte, TreeDefinition tree)
	{
		if (pack.CurrencyCount > 0)
		{
			lte.currencyCount = pack.CurrencyCount;
		}
		if (!string.IsNullOrEmpty(tree.Title))
		{
			lte.titleTxt = "lte_import_title";
		}
		if (!string.IsNullOrEmpty(pack.BannerPath))
		{
			Sprite sprite = LoadSpriteFile(pack.BannerPath);
			if (sprite != null)
			{
				lte.keyArtBanner = sprite;
				Log.Info("banner applied: " + pack.BannerPath + " (" + sprite.rect.width + "x" + sprite.rect.height + ")");
			}
			else
			{
				Log.Warn("banner not loadable: " + pack.BannerPath);
			}
		}
		if (!string.IsNullOrEmpty(pack.ButtonPath))
		{
			Sprite sprite2 = LoadSpriteFile(pack.ButtonPath);
			if (sprite2 != null)
			{
				lte.buttonIcon = sprite2;
				Log.Info("button icon applied: " + pack.ButtonPath + " (" + sprite2.rect.width + "x" + sprite2.rect.height + ")");
			}
			else
			{
				Log.Warn("button icon not loadable: " + pack.ButtonPath);
			}
		}
	}

	private static Sprite LoadSpriteFile(string path)
	{
		if (!File.Exists(path))
		{
			return null;
		}
		Texture2D texture2D = new Texture2D(2, 2, TextureFormat.RGBA32, mipChain: false);
		if (!texture2D.LoadImage(File.ReadAllBytes(path)))
		{
			UnityEngine.Object.Destroy(texture2D);
			return null;
		}
		return Sprite.Create(texture2D, new Rect(0f, 0f, texture2D.width, texture2D.height), new Vector2(0.5f, 0.5f));
	}

	private static void EnterEvent(LTEData lte)
	{
		LteServer instance = Singleton<LteServer>.instance;
		try
		{
			LteServer.openedfromDebug = true;
			TreeGenPlayer.TestActive = true;
			ItemInfo.ClearLoadedImages();
			SceneManager.sceneLoaded -= OnSceneLoaded;
			SceneManager.sceneLoaded += OnSceneLoaded;
			RegisterCustomEvent(null, null);
			TreeGenPlayer.LoadEventScene("import");
		}
		catch (Exception ex)
		{
			Log.Warn("LoadEventScene failed (" + ex.Message + "), falling back to manual entry");
			try
			{
				LteServer.ForceEvent(LteServer.EventId.import);
				LteServer.ForceReloadEventParams();
				SceneManager.LoadScene("EventGame");
			}
			catch (Exception e)
			{
				Log.Error("manual entry failed", e);
				return;
			}
		}
		try
		{
			if (instance != null && (instance.loadedData == null || instance.loadedData.LTE_Name != "import"))
			{
				Log.Warn("loadedData was not 'import' after force-reload; pinning it directly");
				instance.loadedData = lte;
			}
		}
		catch (Exception e2)
		{
			Log.Error("pinning loadedData", e2);
		}
		if (Host.Instance != null)
		{
			Host.Instance.StartCoroutine(PostLoadFixup(null));
		}
	}

	private static void OnSceneLoaded(Scene scene, LoadSceneMode mode)
	{
		try
		{
			if (CustomEventActive && TreeIsReady())
			{
				SpriteBinder.Bind();
				DisableLeaderboard();
				Log.Info("bound sprites in sceneLoaded ('" + scene.name + "') before Start");
			}
		}
		catch (Exception ex)
		{
			Log.Warn("sceneLoaded bind: " + ex.Message);
		}
	}

	private static bool TreeIsReady()
	{
		try
		{
			EventController instance = EventController.instance;
			if (instance == null || instance.eventPrefabData == null || instance.eventPrefabData.treeData == null)
			{
				return false;
			}
			ItemInfo[] nodes = instance.eventPrefabData.treeData.nodes;
			return nodes != null && nodes.Length > 2;
		}
		catch
		{
			return false;
		}
	}

	private static IEnumerator PostLoadFixup(TreeDefinition tree)
	{
		float t = 0f;
		while (t < 20f && !TreeIsReady())
		{
			t += Time.unscaledDeltaTime;
			yield return null;
		}
		try
		{
			SpriteBinder.Bind();
			DisableLeaderboard();
		}
		catch (Exception ex)
		{
			Log.Warn("early bind: " + ex.Message);
		}
		yield return null;
		try
		{
			Pack lastLoaded = LastLoaded;
			if (lastLoaded == null)
			{
				yield break;
			}
			TreeDefinition treeDefinition = TreeDefinition.Load(lastLoaded.TreePath);
			Lte_PrefabData lte_PrefabData = ((EventController.instance != null) ? EventController.instance.eventPrefabData : null);
			if (lte_PrefabData == null || lte_PrefabData.treeData == null)
			{
				yield break;
			}
			ItemInfo[] nodes = lte_PrefabData.treeData.nodes;
			if (nodes != null)
			{
				ItemInfo[] array = nodes;
				foreach (ItemInfo n in array)
				{
					if (n == null)
					{
						continue;
					}
					TreeNodeDef treeNodeDef = treeDefinition.Nodes.FirstOrDefault((TreeNodeDef x) => x.Uid == n.type);
					if (treeNodeDef != null)
					{
						CategoryType category = treeNodeDef.Category;
						if (n.category != category)
						{
							n.category = category;
						}
					}
				}
			}
			Dictionary<string, int> dictionary = new Dictionary<string, int>();
			if (nodes != null)
			{
				ItemInfo[] array = nodes;
				foreach (ItemInfo itemInfo in array)
				{
					if (itemInfo != null)
					{
						string key = itemInfo.category.ToString();
						dictionary[key] = ((!dictionary.ContainsKey(key)) ? 1 : (dictionary[key] + 1));
					}
				}
			}
			if (nodes != null)
			{
				ItemInfo[] array = nodes;
				foreach (ItemInfo n2 in array)
				{
					if (n2 != null && treeDefinition.Nodes.Any((TreeNodeDef d) => d.Uid == n2.type))
					{
						string[] obj = new string[8] { "  node ", n2.type, " pos=", null, null, null, null, null };
						Vector3 position = n2.position;
						obj[3] = position.ToString();
						obj[4] = " cat=";
						obj[5] = n2.category.ToString();
						obj[6] = " sprite=";
						obj[7] = n2.SpriteIndex.ToString();
						Log.Info(string.Concat(obj));
					}
				}
			}
			Log.Info("post-load fixup applied: " + ((nodes != null) ? nodes.Length : 0) + " nodes, categories=" + string.Join(",", dictionary.Select((KeyValuePair<string, int> kv) => kv.Key + ":" + kv.Value).ToArray()) + ", startNode=" + ((EventController.instance != null && EventController.instance.eventPrefabData != null) ? EventController.instance.eventPrefabData.lteName : "?"));
			FlushTerms();
			SpriteBinder.Bind();
			DisableLeaderboard();
			TapHintRewriter.Install(lastLoaded);
			ApplyEventBackground(lastLoaded);
		}
		catch (Exception ex2)
		{
			Log.Warn("post-load fixup: " + ex2.Message);
		}
		for (int i2 = 0; i2 < 3; i2++)
		{
			yield return new WaitForSecondsRealtime(1.5f);
			try
			{
				SpriteBinder.Bind();
				DisableLeaderboard();
			}
			catch
			{
			}
		}
		if (Environment.GetEnvironmentVariable("CUSTOM_EVENT_PACK_AUTOACCEPT") == "1")
		{
			for (int i2 = 0; i2 < 40; i2++)
			{
				TransitionUIEventIntro transitionUIEventIntro = null;
				try
				{
					transitionUIEventIntro = UnityEngine.Object.FindObjectOfType<TransitionUIEventIntro>();
				}
				catch
				{
				}
				if (transitionUIEventIntro != null)
				{
					try
					{
						transitionUIEventIntro.AcceptBtnClicked();
						Log.Info("intro auto-accepted");
					}
					catch (Exception ex3)
					{
						Log.Warn("auto-accept: " + ex3.Message);
					}
					break;
				}
				yield return new WaitForSecondsRealtime(0.5f);
			}
		}
		string environmentVariable = Environment.GetEnvironmentVariable("CUSTOM_EVENT_PACK_SHOT");
		if (string.IsNullOrEmpty(environmentVariable))
		{
			yield break;
		}
		float result = 8f;
		float.TryParse(environmentVariable, NumberStyles.Float, CultureInfo.InvariantCulture, out result);
		if (result < 1f)
		{
			result = 8f;
		}
		yield return new WaitForSecondsRealtime(result);
		for (int i2 = 0; i2 < 3; i2++)
		{
			string text = Path.Combine(Application.persistentDataPath, "cepack_shot" + (i2 + 1) + ".png");
			try
			{
				File.Delete(text);
			}
			catch
			{
			}
			ScreenCapture.CaptureScreenshot(text);
			Log.Info("screenshot -> " + text);
			if (i2 < 2)
			{
				yield return new WaitForSecondsRealtime(15f);
			}
		}
	}

	/// <summary>A 1x1 quad mesh facing -Z (i.e. back towards the camera it is parented to).</summary>
	internal static Mesh MakeQuadMesh()
	{
		Mesh mesh = new Mesh();
		mesh.name = "cepack_quad";
		mesh.vertices = new Vector3[4]
		{
			new Vector3(-0.5f, -0.5f, 0f),
			new Vector3(0.5f, -0.5f, 0f),
			new Vector3(0.5f, 0.5f, 0f),
			new Vector3(-0.5f, 0.5f, 0f)
		};
		mesh.uv = new Vector2[4]
		{
			new Vector2(0f, 0f),
			new Vector2(1f, 0f),
			new Vector2(1f, 1f),
			new Vector2(0f, 1f)
		};
		mesh.normals = new Vector3[4] { Vector3.back, Vector3.back, Vector3.back, Vector3.back };
		mesh.triangles = new int[6] { 0, 2, 1, 0, 3, 2 };
		mesh.RecalculateBounds();
		return mesh;
	}

	/// <summary>Unlit material. Uses a texture when given one, a flat colour otherwise.</summary>
	internal static Material MakeUnlit(Texture2D tex, Color col)
	{
		Shader shader = null;
		string[] wanted = (tex != null)
			? new string[3] { "Unlit/Texture", "Sprites/Default", "UI/Default" }
			: new string[3] { "Unlit/Color", "Sprites/Default", "UI/Default" };
		foreach (string sn in wanted)
		{
			shader = Shader.Find(sn);
			if (shader != null)
			{
				break;
			}
		}
		if (shader == null)
		{
			shader = Shader.Find("Unlit/Texture");
		}
		Material material = new Material(shader);
		if (tex != null)
		{
			material.mainTexture = tex;
		}
		material.color = col;
		return material;
	}

	/// <summary>
	/// A full-view quad parented to the camera at distance z. Parenting makes the size
	/// exact for ANY camera: at distance d a perspective camera sees
	/// 2*d*tan(fov/2) vertically, times the aspect horizontally, so the quad covers the
	/// viewport regardless of which camera renders and what its fov happens to be.
	/// </summary>
	internal static GameObject MakeViewQuad(Camera cam, string name, float z, float w, float h, Material mat)
	{
		GameObject go = new GameObject(name);
		go.layer = cam.gameObject.layer;
		MeshFilter mf = go.AddComponent<MeshFilter>();
		mf.sharedMesh = MakeQuadMesh();
		MeshRenderer mr = go.AddComponent<MeshRenderer>();
		mr.sharedMaterial = mat;
		mr.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
		mr.receiveShadows = false;
		// +Z is where the camera looks, so the quad must face back towards it
		go.transform.SetParent(cam.transform, false);
		go.transform.localPosition = new Vector3(0f, 0f, z);
		go.transform.localRotation = Quaternion.Euler(0f, 180f, 0f);
		go.transform.localScale = new Vector3(w, h, 1f);
		return go;
	}

	internal static void ApplyEventBackground(Pack pack)
	{
		if (pack.Backgrounds == null || pack.Backgrounds.Count == 0)
		{
			return;
		}
		try
		{
			string text = null;
			foreach (BackgroundDef background in pack.Backgrounds)
			{
				if (background.Visible && background.File != null && File.Exists(background.File))
				{
					text = background.File;
					break;
				}
			}
			Camera[] allCameras = Camera.allCameras;
			foreach (Camera camera in allCameras)
			{
				if (camera != null)
				{
					Log.Info("  PROBE cam '" + camera.name + "' depth=" + camera.depth + " mask=0x" + camera.cullingMask.ToString("X8") + " targetTex=" + ((camera.targetTexture == null) ? "null" : (camera.targetTexture.name + " " + camera.targetTexture.width + "x" + camera.targetTexture.height)) + " rect=" + camera.rect.ToString() + " clear=" + camera.clearFlags.ToString() + " bg=" + camera.backgroundColor.ToString());
				}
			}
			RenderTexture[] array = Resources.FindObjectsOfTypeAll<RenderTexture>();
			foreach (RenderTexture renderTexture in array)
			{
				if (renderTexture != null)
				{
					Log.Info("  PROBE rt '" + renderTexture.name + "' " + renderTexture.width + "x" + renderTexture.height + " fmt=" + renderTexture.format.ToString() + " active=" + renderTexture.IsCreated());
				}
			}
			Transform[] array2 = Resources.FindObjectsOfTypeAll<Transform>();
			foreach (Transform transform in array2)
			{
				if (!(transform == null) && transform.gameObject.scene.name != null)
				{
					int layer = transform.gameObject.layer;
					if (layer == 9 || layer == 5)
					{
						MeshRenderer component = transform.GetComponent<MeshRenderer>();
						SpriteRenderer component2 = transform.GetComponent<SpriteRenderer>();
						string text2 = ((component != null && component.material != null && component.material.mainTexture != null) ? component.material.mainTexture.name : ((component2 != null && component2.sprite != null) ? component2.sprite.name : "-"));
						Log.Info("  PROBE layer" + layer + " '" + transform.gameObject.name + "' active=" + transform.gameObject.activeInHierarchy + " tex=" + text2 + ((component != null) ? (" bounds=" + component.bounds.size.ToString()) : ""));
					}
				}
			}
			foreach (BackgroundDef background2 in pack.Backgrounds)
			{
				Log.Info("  PROBE pack bg '" + background2.File + "' visible=" + background2.Visible);
			}
		}
		catch (Exception e)
		{
			Log.Error("ApplyEventBackground", e);
		}
	}

	internal static void MaybeAdvanceStage()
	{
		if (!CustomEventActive)
		{
			return;
		}
		try
		{
			MissionController missionController = ((EventController.instance != null) ? EventController.instance.missionController : null);
			if (missionController == null || missionController.rankRule == null || missionController.rankRule.Length < 2 || missionController.currentRank == null)
			{
				return;
			}
			int num = -1;
			for (int i = 0; i < missionController.rankRule.Length; i++)
			{
				if (missionController.rankRule[i] == missionController.currentRank)
				{
					num = i;
					break;
				}
			}
			if (num < 0 || num >= missionController.rankRule.Length - 1)
			{
				return;
			}
			bool flag = Environment.GetEnvironmentVariable("CUSTOM_EVENT_PACK_FORCE_ADVANCE") == "1";
			int num2 = missionController.RequiredMissionGroups();
			if (flag || (num2 > 0 && missionController.currentRank.completed >= num2))
			{
				Rank rank = (missionController.currentRank = missionController.rankRule[num + 1]);
				missionController.rankLevel = num + 2;
				if (rank.missions != null)
				{
					missionController._missions = rank.missions;
					ResolveMissionReqItems(rank.missions);
				}
				missionController.RefreshMissionGroups();
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
				_lastProbe = null;
				_lastDump = null;
				Log.Info("ADVANCED to stage " + (num + 2) + "/" + missionController.rankRule.Length + " '" + rank.title + "' -> " + ((missionController.missionGroups == null) ? (-1) : missionController.missionGroups.Count) + " task group(s)" + (flag ? " [forced]" : ""));
			}
		}
		catch (Exception e)
		{
			Log.Error("MaybeAdvanceStage", e);
		}
	}

	private static bool _nodeProbeDone;

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
				if (sn.Contains("framecircle")) frames.Add(sr);
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
			foreach (Renderer fr in frames)
			{
				Transform root = fr.transform.root;
				Log.Info("NODEPROBE layers of " + root.name + ":");
				foreach (SpriteRenderer s2 in root.GetComponentsInChildren<SpriteRenderer>(true))
				{
					Log.Info("   " + s2.transform.name + " sprite=" + ((s2.sprite == null) ? "null" : s2.sprite.name)
						+ " size=(" + s2.bounds.size.x.ToString("F2") + "x" + s2.bounds.size.y.ToString("F2") + ")"
						+ " enabled=" + s2.enabled);
				}
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

	/// <summary>
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
	/// <summary>
	/// The game's own lootbox ids are the EVENT_DINO_LOOTBOX_1/2/3 constants
	/// ("dino_lootbox_1" .. "dino_lootbox_3"); LootBoxController.infoDict is built from its
	/// Inspector `infoList` and only knows those. A Lootbox prize whose prizeID is not one of
	/// them makes GetInfo() return null and MissionGroup.GetIcon() throw on `.sprite`, which
	/// aborts InitGame() before the StartGame coroutine - the event never starts and the
	/// "Connecting..." preloader stays up. Resolve a custom prizeID to a real vanilla lootbox
	/// instead of downgrading the declared prizeType.
	/// </summary>
	internal static string ResolveVanillaLootboxId(string wanted)
	{
		try
		{
			LootBoxController lb = LootBoxController.instance;
			System.Reflection.FieldInfo fi = (lb != null) ? typeof(LootBoxController).GetField("infoDict",
				System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public) : null;
			System.Collections.IDictionary dict = (fi != null) ? (fi.GetValue(lb) as System.Collections.IDictionary) : null;
			if (dict != null)
			{
				if (!string.IsNullOrEmpty(wanted) && dict.Contains(wanted)) return wanted;   // already valid
				foreach (object k in dict.Keys) { string s = k as string; if (!string.IsNullOrEmpty(s)) return s; }
			}
		}
		catch (Exception e) { Log.Warn("ResolveVanillaLootboxId: " + e.Message); }
		return "dino_lootbox_1";   // the game's first built-in lootbox id
	}

	internal static void ResolveMissionReqItems(Mission[] missions)
	{
		if (missions == null) return;
		int fixedCount = 0;
		foreach (Mission m in missions)
		{
			if (m == null) continue;
			// MissionGroup.GetIcon() is `return reqItem.icon;` with no null check and is reached
			// from InitGame() via CheckMissionProgress -> UpdateMission -> Refresh. A single null
			// reqItem aborts InitGame before StartCoroutine(DelayStartGame()), so the event never
			// starts and the preloader stays up. reqItem must therefore NEVER be left null.
			if (m.reqItem != null) { fixedCount++; continue; }
			try
			{
				if (!string.IsNullOrEmpty(m.reqItemId)) m.reqItem = ItemInfo.FindItem(m.reqItemId);
				if (m.reqItem == null && !string.IsNullOrEmpty(m.prizeID)) m.reqItem = ItemInfo.FindItem(m.prizeID);
				Log.Info("MISSIONREQ '" + m.reqItemId + "' prize='" + m.prizeID + "' found=" + (m.reqItem != null)
					+ (m.reqItem == null ? " (will fall back so GetIcon cannot NRE)" : ""));
				if (m.reqItem == null) m.reqItem = ItemInfo.FindItem("stat_entropy");
				if (m.reqItem != null) fixedCount++;
				else Log.Warn("mission '" + m.reqItemId + "' has no ItemInfo at all");
			}
			catch (Exception e) { Log.Error("ResolveMissionReqItems(" + m.reqItemId + ")", e); }
		}
		if (fixedCount > 0) Log.Info("MISSIONS: resolved reqItem for " + fixedCount + " mission(s)");
	}

	// ------------------------------------------------------------------ per-pack save
	// The game keeps ONE event save (SaveFile.eventItems / SaveFile.eventRanks) and every
	// event shares it, so two custom packs overwrote each other's progress. The live save is
	// serialised with the game's own SaveFileJSON and filed per pack id, then restored when
	// that pack is entered again. Only the two EVENT fields are copied back - restoring the
	// whole SaveFile would roll back main-simulation progress too.
	private static string _savePackId;

	internal static string SaveDir
	{
		get { return System.IO.Path.Combine(Application.persistentDataPath, "CustomEventSaves"); }
	}

	private static string SavePath(string packId)
	{
		System.Text.StringBuilder sb = new System.Text.StringBuilder();
		foreach (char c in packId)
		{
			sb.Append((char.IsLetterOrDigit(c) || c == '_' || c == '-') ? c : '_');
		}
		return System.IO.Path.Combine(SaveDir, sb.ToString() + ".json");
	}

	internal static void SwitchPackSave(Pack pack)
	{
		string want = ((pack == null || string.IsNullOrEmpty(pack.Id)) ? "default" : pack.Id);
		if (_savePackId == null)
		{
			// first pack entry this session: the save currently in memory belongs to whichever
			// pack was last played, so remember that instead of assuming it is already ours.
			_savePackId = PlayerPrefs.GetString("cepack_active_save", "");
		}
		if (want == _savePackId) return;
		try
		{
			if (!string.IsNullOrEmpty(_savePackId))
			{
				System.IO.Directory.CreateDirectory(SaveDir);
				string blob = JsonUtility.ToJson(new Cells.SaveMagic.Impl.SaveFileJSON(SaveSystem.save));
				System.IO.File.WriteAllText(SavePath(_savePackId), blob, System.Text.Encoding.UTF8);
				Log.Info("SAVE: stashed pack '" + _savePackId + "' (" + blob.Length + " chars)");
			}
			_savePackId = want;
			PlayerPrefs.SetString("cepack_active_save", want);
			string path = SavePath(want);
			if (System.IO.File.Exists(path))
			{
				Cells.SaveMagic.Impl.SaveFileJSON json = JsonUtility.FromJson<Cells.SaveMagic.Impl.SaveFileJSON>(System.IO.File.ReadAllText(path, System.Text.Encoding.UTF8));
				SaveFile tmp = ((json == null) ? null : json.ToSaveFile());
				if (tmp != null)
				{
					SaveSystem.save.eventItems = tmp.eventItems;
					SaveSystem.save.eventRanks = tmp.eventRanks;
					Log.Info("SAVE: restored pack '" + want + "' (eventItems=" + tmp.eventItems.Count + ", eventRanks=" + tmp.eventRanks.Count + ")");
				}
			}
			else
			{
				// a pack nobody has played yet must NOT inherit the previous pack's run
				SaveSystem.save.eventItems.Clear();
				SaveSystem.save.eventRanks.Clear();
				Log.Info("SAVE: pack '" + want + "' is new; its event save starts empty");
			}
		}
		catch (Exception e) { Log.Error("SwitchPackSave(" + want + ")", e); }
	}

	internal static void MaybeShowOutro()
	{
		if (!CustomEventActive || _outroShown)
		{
			return;
		}
		try
		{
			EventController instance = EventController.instance;
			MissionController missionController = ((instance != null) ? instance.missionController : null);
			if (missionController == null)
			{
				return;
			}
			Rank[] rankRule = missionController.rankRule;
			Rank currentRank = missionController.currentRank;
			int num = -1;
			if (rankRule != null && currentRank != null)
			{
				for (int i = 0; i < rankRule.Length; i++)
				{
					if (rankRule[i] == currentRank)
					{
						num = i;
						break;
					}
				}
			}
			string text = "rankIdx=" + num + "/" + ((rankRule == null) ? (-1) : (rankRule.Length - 1)) + " groups=" + ((missionController.missionGroups == null) ? (-1) : missionController.missionGroups.Count) + " rankCompleted=" + (currentRank?.completed ?? (-1)) + " rankCollected=" + (currentRank?.collected ?? (-1)) + " allComplete=" + MissionController.allMissionsComplete + " allCollected=" + MissionController.allMissionsCollected;
			if (text != _lastProbe)
			{
				_lastProbe = text;
				Log.Info("mission state: " + text);
			}
			try
			{
				double num2 = ((num < 0) ? 1 : (num + 1));
				if (Math.Abs(missionController.rankLevel - num2) > 0.001)
				{
					Log.Info("rankLevel " + missionController.rankLevel + " -> " + num2 + " (was stale dino value; event UI reads this field)");
					missionController.rankLevel = num2;
				}
			}
			catch (Exception ex)
			{
				Log.Warn("rankLevel fix: " + ex.Message);
			}
			try
			{
				EventController instance2 = EventController.instance;
				LTEData lTEData = ((Singleton<LteServer>.instance != null) ? Singleton<LteServer>.instance.loadedData : null);
				LTE_Master_Rule lTE_Master_Rule = ((Singleton<LteServer>.instance != null && Singleton<LteServer>.instance.masterLteData != null) ? Singleton<LteServer>.instance.masterLteData.masterRankRule : null);
				int num3 = -1;
				try
				{
					if (lTE_Master_Rule != null && currentRank != null)
					{
						foreach (RankRule lteRankRule in lTE_Master_Rule.lteRankRules)
						{
							if (lteRankRule != null && lteRankRule.ranks != null && lteRankRule.ranks.Length != 0 && lteRankRule.ranks[0].title == currentRank.title)
							{
								num3 = lteRankRule.ranks.Length;
								break;
							}
						}
					}
				}
				catch
				{
				}
				string text2 = "rankRule=" + ((rankRule == null) ? (-1) : rankRule.Length) + " rankLevel=" + missionController.rankLevel + " curTitle='" + ((currentRank == null) ? "null" : currentRank.title) + "' curMissions=" + ((currentRank == null || currentRank.missions == null) ? (-1) : currentRank.missions.Length) + " groups=" + ((missionController.missionGroups == null) ? (-1) : missionController.missionGroups.Count) + " GetTotalMission=" + instance2.GetTotalMission() + " LoadRankRule=" + ((instance2.LoadRankRule == null || instance2.LoadRankRule.ranks == null) ? (-1) : instance2.LoadRankRule.ranks.Length) + " FindRuleLen=" + num3 + " masterRules=" + ((lTE_Master_Rule == null || lTE_Master_Rule.lteRankRules == null) ? (-1) : lTE_Master_Rule.lteRankRules.Count) + " lteRankData=" + ((lTEData == null || lTEData.rankData == null || lTEData.rankData.ranks == null) ? (-1) : lTEData.rankData.ranks.Length) + " saveEventRanks=" + ((SaveSystem.save == null || SaveSystem.save.eventRanks == null) ? (-1) : SaveSystem.save.eventRanks.Count);
				if (text2 != _lastDump)
				{
					_lastDump = text2;
					Log.Info("RANK DUMP: " + text2);
				}
			}
			catch (Exception ex2)
			{
				Log.Warn("rank dump: " + ex2.Message);
			}
			bool flag = Environment.GetEnvironmentVariable("CUSTOM_EVENT_PACK_FORCE_OUTRO") == "1";
			if ((!flag && num >= 0 && rankRule != null && num != rankRule.Length - 1) || (!flag && !MissionController.allMissionsComplete && !MissionController.allMissionsCollected))
			{
				return;
			}
			if (flag)
			{
				Log.Warn("FORCE_OUTRO: bypassing completion gates (rankIdx=" + num + ")");
			}
			if (!TapHintRewriter.IsBusy)
			{
				TransitionUIEventIntro transitionUIEventIntro = Resources.Load<TransitionUIEventIntro>("ui/LteTransitionEvent");
				if (transitionUIEventIntro == null)
				{
					Log.Warn("outro prefab 'ui/LteTransitionEvent' not found");
					return;
				}
				_outroShown = true;
				UnityEngine.Object.Instantiate(transitionUIEventIntro).Load(TransitionUIEventIntro.EventStoryChapter.OUTRO, null);
				Log.Info("all missions complete on the last rank -> ending cutscene shown (" + text + ")");
			}
		}
		catch (Exception e)
		{
			Log.Error("MaybeShowOutro", e);
		}
	}

	internal static void ResetOutro()
	{
		_outroShown = false;
		_lastProbe = null;
		_bgTries = 0;
		_bgDone = false;
		_bgAge = 0f;
		_bgDumped = false;
	}

	internal static void DelayedBackdropDump(float dt)
	{
		if (_bgDumped || !CustomEventActive)
		{
			return;
		}
		_bgAge += dt;
		if (_bgAge < 35f)
		{
			return;
		}
		_bgDumped = true;
		try
		{
			Log.Info("=== DELAYED BACKDROP DUMP (tree view should be up now) ===");
			MeshRenderer[] array = Resources.FindObjectsOfTypeAll<MeshRenderer>();
			foreach (MeshRenderer meshRenderer in array)
			{
				if (!(meshRenderer == null) && meshRenderer.gameObject.activeInHierarchy)
				{
					string text = ((meshRenderer.material != null && meshRenderer.material.mainTexture != null) ? meshRenderer.material.mainTexture.name : "null");
					Log.Info("  TREE MR '" + meshRenderer.gameObject.name + "' mat='" + ((meshRenderer.material != null) ? meshRenderer.material.name : "?") + "' tex=" + text + " bounds=" + meshRenderer.bounds.size.ToString());
				}
			}
			SpriteRenderer[] array2 = Resources.FindObjectsOfTypeAll<SpriteRenderer>();
			foreach (SpriteRenderer spriteRenderer in array2)
			{
				if (!(spriteRenderer == null) && spriteRenderer.gameObject.activeInHierarchy)
				{
					Log.Info("  TREE SR '" + spriteRenderer.gameObject.name + "' sprite=" + ((spriteRenderer.sprite == null) ? "null" : spriteRenderer.sprite.name) + " bounds=" + spriteRenderer.bounds.size.ToString());
				}
			}
		}
		catch (Exception ex)
		{
			Log.Warn("delayed dump: " + ex.Message);
		}
	}

	internal static void RetryEventBackground()
	{
		if (!_bgDone && _bgTries < 40)
		{
			_bgTries++;
			EventController instance = EventController.instance;
			if (!(instance == null) && !(instance.treeBG == null) && instance.treeBG.gameObject.activeInHierarchy)
			{
				_bgDone = true;
				Log.Info("tree backdrop became active on try " + _bgTries + " -> applying");
				ApplyEventBackground(LastLoaded);
			}
		}
	}

	internal static void DisableLeaderboard()
	{
		try
		{
			SegmentedLeaderboardManager instance = SegmentedLeaderboardManager.instance;
			if (!(instance == null) && (instance.inEventScene || !string.IsNullOrEmpty(instance.boardName)))
			{
				instance.inEventScene = false;
				instance.boardName = "";
				Log.Info("segmented leaderboard disabled for this custom event");
			}
		}
		catch (Exception ex)
		{
			Log.Warn("leaderboard: " + ex.Message);
		}
	}
}
/// <summary>
/// Stage 1 of the standalone loader (Option C): render a custom exploration pack without
/// touching the game's live-ops systems at all.
///
/// The previous architecture pretended the pack was a server-delivered LTE event, which meant
/// faking one server-state field after another (server clock, loadedData, savedEventId,
/// bForceReset, the ready callback, the preloader flags) and every fake broke something else
/// downstream. This class references none of that: no LteServer, no EventController, no
/// GameController, no scene load. It builds a canvas, places one control per TreeNodeDef at the
/// pack's own coordinates, and handles clicks itself.
/// </summary>
internal class CustomExplorer : MonoBehaviour
{
	internal const float NodeSize = 96f;
	internal const float Scale = 24f;

	private Canvas _canvas;
	private readonly Dictionary<string, ExplorerNode> _byUid = new Dictionary<string, ExplorerNode>();
	private readonly ExplorerState _state = new ExplorerState();
	private Transform _window;
	private TreeDefinition _stagedTree;
	private string _stagedPackName;
	private RectTransform _content;

	/// <summary>
	/// The explorer is a framed window (title bar + close button) rather than a full-screen
	/// overlay, so the game's own UI stays visible around it.
	/// </summary>
	private Transform BuildWindow(Transform canvasRoot, string packName, string title)
	{
		GameObject window = new GameObject("ExplorerWindow");
		window.transform.SetParent(canvasRoot, false);
		RectTransform wrt = window.AddComponent<RectTransform>();
		wrt.anchorMin = new Vector2(0.5f, 0.5f);
		wrt.anchorMax = new Vector2(0.5f, 0.5f);
		wrt.pivot = new Vector2(0.5f, 0.5f);
		wrt.anchoredPosition = Vector2.zero;
		wrt.sizeDelta = new Vector2(960f, 620f);
		UnityEngine.UI.Image frame = window.AddComponent<UnityEngine.UI.Image>();
		frame.color = new Color(0.07f, 0.10f, 0.14f, 0.94f);

		GameObject titleGo = new GameObject("WindowTitle");
		titleGo.transform.SetParent(window.transform, false);
		RectTransform trt = titleGo.AddComponent<RectTransform>();
		trt.anchorMin = new Vector2(0f, 1f);
		trt.anchorMax = new Vector2(1f, 1f);
		trt.pivot = new Vector2(0.5f, 1f);
		trt.anchoredPosition = new Vector2(0f, -8f);
		trt.sizeDelta = new Vector2(0f, 40f);
		UnityEngine.UI.Text titleText = titleGo.AddComponent<UnityEngine.UI.Text>();
		titleText.text = string.IsNullOrEmpty(title) ? ("自定义勘探 - " + packName) : title;
		titleText.alignment = TextAnchor.MiddleCenter;
		titleText.fontSize = 24;
		titleText.color = Color.white;

		GameObject closeGo = new GameObject("Close");
		closeGo.transform.SetParent(window.transform, false);
		RectTransform crt = closeGo.AddComponent<RectTransform>();
		crt.anchorMin = new Vector2(1f, 1f);
		crt.anchorMax = new Vector2(1f, 1f);
		crt.pivot = new Vector2(1f, 1f);
		crt.anchoredPosition = new Vector2(-10f, -8f);
		crt.sizeDelta = new Vector2(44f, 36f);
		UnityEngine.UI.Image closeBg = closeGo.AddComponent<UnityEngine.UI.Image>();
		closeBg.color = new Color(0.55f, 0.18f, 0.18f, 1f);
		UnityEngine.UI.Button closeBtn = closeGo.AddComponent<UnityEngine.UI.Button>();
		closeBtn.onClick.AddListener(Close);
		GameObject closeLabel = new GameObject("X");
		closeLabel.transform.SetParent(closeGo.transform, false);
		RectTransform clrt = closeLabel.AddComponent<RectTransform>();
		clrt.anchorMin = Vector2.zero;
		clrt.anchorMax = Vector2.one;
		clrt.offsetMin = Vector2.zero;
		clrt.offsetMax = Vector2.zero;
		UnityEngine.UI.Text closeText = closeLabel.AddComponent<UnityEngine.UI.Text>();
		closeText.text = "X";
		closeText.alignment = TextAnchor.MiddleCenter;
		closeText.fontSize = 20;
		closeText.color = Color.white;

		GameObject content = new GameObject("ExplorerContent");
		content.transform.SetParent(window.transform, false);
		RectTransform cnt = content.AddComponent<RectTransform>();
		cnt.anchorMin = new Vector2(0f, 0f);
		cnt.anchorMax = new Vector2(1f, 1f);
		cnt.offsetMin = new Vector2(16f, 16f);
		cnt.offsetMax = new Vector2(-16f, -56f);
		return window.transform;
	}

	internal void Close()
	{
		_state.Save();
		Destroy(gameObject);
	}

	/// <summary>Entry point: build a standalone exploration view for a loaded pack.</summary>
	internal static CustomExplorer Launch(TreeDefinition tree, string packName)
	{
		GameObject go = new GameObject("CustomExplorer");
		DontDestroyOnLoad(go);
		CustomExplorer ex = go.AddComponent<CustomExplorer>();
		ex.Build(tree, packName);
		return ex;
	}

	private void Build(TreeDefinition tree, string packName)
	{
		Log.Info("standalone explorer: pack '" + packName + "', " + tree.Nodes.Count + " node(s), grid=" + tree.GridView + " (no LteServer, no EventController)");

		GameObject canvasGo = new GameObject("ExplorerCanvas");
		canvasGo.transform.SetParent(transform, false);
		_canvas = canvasGo.AddComponent<Canvas>();
		_canvas.renderMode = RenderMode.ScreenSpaceCamera;
		_canvas.sortingOrder = 40;
		canvasGo.AddComponent<UnityEngine.UI.CanvasScaler>();
		canvasGo.AddComponent<UnityEngine.UI.GraphicRaycaster>();

		_window = BuildWindow(_canvas.transform, packName, tree.Title);
		_content = _window.Find("ExplorerContent") as RectTransform;
		if (UnityEngine.EventSystems.EventSystem.current == null)
		{
			GameObject es = new GameObject("ExplorerEventSystem");
			es.transform.SetParent(transform, false);
			es.AddComponent<UnityEngine.EventSystems.EventSystem>();
			es.AddComponent<UnityEngine.EventSystems.StandaloneInputModule>();
		}

		float minX = 1f, maxX = -1f, minY = 1f, maxY = -1f;
		bool any = false;
		foreach (TreeNodeDef n in tree.Nodes)
		{
			if (!any) { minX = maxX = n.Position.x; minY = maxY = n.Position.y; any = true; }
			if (n.Position.x < minX) minX = n.Position.x;
			if (n.Position.x > maxX) maxX = n.Position.x;
			if (n.Position.y < minY) minY = n.Position.y;
			if (n.Position.y > maxY) maxY = n.Position.y;
		}
		Vector2 centre = any ? new Vector2((minX + maxX) * 0.5f, (minY + maxY) * 0.5f) : Vector2.zero;

		foreach (TreeNodeDef n in tree.Nodes)
		{
			ExplorerNode node = ExplorerNode.Create(_content, n, centre, _state);
			if (!string.IsNullOrEmpty(n.Uid) && !_byUid.ContainsKey(n.Uid)) _byUid.Add(n.Uid, node);
		}
		Log.Info("standalone explorer: built " + _byUid.Count + " control(s), centre=" + centre + " span=(" + (maxX - minX) + "," + (maxY - minY) + ")");
	}

	internal void OnNodeClicked(string uid)
	{
		ExplorerNode node;
		if (uid == null || !_byUid.TryGetValue(uid, out node)) return;
		node.OnTapped();
				_state.Save();
		Log.Info("standalone explorer: tapped '" + uid + "' (" + node.Def.Title + ") progress=" + node.Progress.ToString("0.##"));
	}
}

/// <summary>One tappable node of the standalone explorer. Pure Unity UI, no game types.</summary>
internal class ExplorerNode : MonoBehaviour, UnityEngine.EventSystems.IPointerClickHandler
{
	internal TreeNodeDef Def;
	internal ExplorerState State;
	internal double Progress;
	private UnityEngine.UI.Image _image;

	internal static ExplorerNode Create(Transform parent, TreeNodeDef def, Vector2 centre, ExplorerState state)
	{
		GameObject go = new GameObject("node_" + (def.Uid ?? "?"));
		go.transform.SetParent(parent, false);
		ExplorerNode node = go.AddComponent<ExplorerNode>();
		node.Def = def;
		node.State = state;
		node.Progress = state == null ? 0.0 : state.Get(def.Uid);

		RectTransform rt = go.AddComponent<RectTransform>();
		rt.sizeDelta = new Vector2(CustomExplorer.NodeSize, CustomExplorer.NodeSize);
		rt.anchoredPosition = new Vector2((def.Position.x - centre.x) * CustomExplorer.Scale, (def.Position.y - centre.y) * CustomExplorer.Scale);

		node._image = go.AddComponent<UnityEngine.UI.Image>();
		node._image.color = node.Tint();

		GameObject labelGo = new GameObject("title");
		labelGo.transform.SetParent(go.transform, false);
		RectTransform lrt = labelGo.AddComponent<RectTransform>();
		lrt.anchorMin = new Vector2(0f, 0f);
		lrt.anchorMax = new Vector2(1f, 0f);
		lrt.pivot = new Vector2(0.5f, 1f);
		lrt.anchoredPosition = new Vector2(0f, -4f);
		lrt.sizeDelta = new Vector2(0f, 30f);
		UnityEngine.UI.Text label = labelGo.AddComponent<UnityEngine.UI.Text>();
		label.text = string.IsNullOrEmpty(def.Title) ? def.Uid : def.Title;
		label.alignment = TextAnchor.UpperCenter;
		label.fontSize = 14;
		label.color = Color.white;
		return node;
	}

	private Color Tint()
	{
		switch (Def.Category)
		{
		case CategoryType.UPGRADE: return new Color(0.25f, 0.55f, 0.95f);
		case CategoryType.TROPHY: return new Color(0.95f, 0.80f, 0.25f);
		default: return new Color(0.35f, 0.80f, 0.45f);
		}
	}

	internal void OnTapped()
	{
		double gain = (State != null ? State.TapMultiplier : 1.0);
		if (State != null) State.Add(Def.Uid, gain);
		Progress += gain;
		if (_image != null)
		{
			float t = Mathf.Clamp01((float)Progress / 10f);
			_image.color = Color.Lerp(Tint(), Color.white, t * 0.5f);
		}
	}

	public void OnPointerClick(UnityEngine.EventSystems.PointerEventData eventData)
	{
		CustomExplorer ex = GetComponentInParent<CustomExplorer>();
		if (ex != null) ex.OnNodeClicked(Def.Uid);
	}
}

/// <summary>
/// Stage-2 gameplay state for the standalone explorer: per-node progress, currency totals and a
/// per-pack save file. Deliberately self-contained - it persists to CustomEventSaves/&lt;id&gt;.json
/// (the same folder the earlier per-pack save work used) and knows nothing about SaveSystem.
/// </summary>
internal class ExplorerState
{
	internal string PackId = "pack";
	internal double[] Currency = new double[8];
	internal readonly Dictionary<string, double> NodeProgress = new Dictionary<string, double>();
	internal double TapMultiplier = 1.0;

	private string SavePath
	{
		// Deliberately NOT <id>.json: that name is taken by the game's own per-pack save
		// (hundreds of KB). The explorer writes its own small record alongside it.
		get { return Path.Combine(Application.persistentDataPath, "CustomEventSaves", PackId + ".explorer.json"); }
	}

	internal void Load()
	{
		try
		{
			if (!File.Exists(SavePath)) return;
			JObject o = JObject.Parse(File.ReadAllText(SavePath));
			JArray cur = o["currency"] as JArray;
			if (cur != null)
				for (int i = 0; i < Currency.Length && i < cur.Count; i++) Currency[i] = (double)cur[i];
			JObject prog = o["progress"] as JObject;
			if (prog != null)
				foreach (JProperty p in prog.Properties()) NodeProgress[p.Name] = (double)p.Value;
			if (o["tapMultiplier"] != null) TapMultiplier = (double)o["tapMultiplier"];
			Log.Info("explorer state: loaded " + NodeProgress.Count + " node(s) of progress from " + Path.GetFileName(SavePath));
		}
		catch (Exception e) { Log.Warn("explorer state load: " + e.Message); }
	}

	internal void Save()
	{
		try
		{
			Directory.CreateDirectory(Path.GetDirectoryName(SavePath));
			JObject o = new JObject();
			JArray cur = new JArray();
			foreach (double c in Currency) cur.Add(c);
			o["currency"] = cur;
			JObject prog = new JObject();
			foreach (KeyValuePair<string, double> kv in NodeProgress) prog[kv.Key] = kv.Value;
			o["progress"] = prog;
			o["tapMultiplier"] = TapMultiplier;
			File.WriteAllText(SavePath, o.ToString());
		}
		catch (Exception e) { Log.Warn("explorer state save: " + e.Message); }
	}

	internal double Get(string uid)
	{
		double v;
		return (uid != null && NodeProgress.TryGetValue(uid, out v)) ? v : 0.0;
	}

	internal void Add(string uid, double amount)
	{
		if (uid == null) return;
		NodeProgress[uid] = Get(uid) + amount;
	}
}

internal class TreeNodeDef
{
	public string Uid;

	public string Title = "";

	public string Description = "";

	public string Type = "Research";

	public Vector3 Position;

	public double[] Cost = new double[8];

	public double[] Production = new double[8];

	public List<Tuple<string, double>> Effects = new List<Tuple<string, double>>();

	public List<Tuple<string, double, string, bool>> Requirements = new List<Tuple<string, double, string, bool>>();

	public CategoryType Category
	{
		get
		{
			switch ((Type ?? "").Trim().ToLowerInvariant())
			{
			case "generator":
			case "upgrade":
				return CategoryType.UPGRADE;
			case "trophy":
				return CategoryType.TROPHY;
			default:
				return CategoryType.RESEARCH;
			}
		}
	}
}
internal class TreeDefinition
{
	public string Name = "custom";

	public string Title = "";

	public string StartNode = "";

	public bool GridView;

	public List<TreeNodeDef> Nodes = new List<TreeNodeDef>();

	internal static TreeDefinition Load(string path)
	{
		string json;
		if (path.EndsWith("#treeData", StringComparison.Ordinal))
		{
			JObject jObject = JObject.Parse(File.ReadAllText(path.Substring(0, path.Length - "#treeData".Length)));
			json = ((jObject["treeData"] != null) ? jObject["treeData"].ToString() : ((jObject["treeDefinition"] != null) ? jObject["treeDefinition"].ToString() : "{}"));
		}
		else
		{
			json = File.ReadAllText(path);
		}
		JObject jObject2 = JObject.Parse(json);
		TreeDefinition treeDefinition = new TreeDefinition();
		treeDefinition.Name = PackLoader.Str(jObject2, "name") ?? "custom";
		treeDefinition.Title = PackLoader.Str(jObject2, "title") ?? "";
		treeDefinition.StartNode = PackLoader.Str(jObject2, "startNode") ?? "";
		JToken jToken = jObject2["gridView"];
		if (jToken != null && jToken.Type != JTokenType.Null)
		{
			try
			{
				treeDefinition.GridView = jToken.Value<bool>();
			}
			catch
			{
			}
		}
		foreach (JToken item3 in (jObject2["nodes"] as JArray) ?? throw new InvalidDataException("tree 缺少 nodes 数组"))
		{
			if (item3 == null || item3.Type != JTokenType.Object)
			{
				continue;
			}
			TreeNodeDef treeNodeDef = new TreeNodeDef();
			treeNodeDef.Uid = PackLoader.Str((JObject)item3, "uid") ?? PackLoader.Str((JObject)item3, "id") ?? PackLoader.Str((JObject)item3, "key");
			if (string.IsNullOrEmpty(treeNodeDef.Uid))
			{
				continue;
			}
			treeNodeDef.Title = PackLoader.Str((JObject)item3, "title") ?? treeNodeDef.Uid;
			treeNodeDef.Description = PackLoader.Str((JObject)item3, "description") ?? PackLoader.Str((JObject)item3, "desc") ?? "";
			treeNodeDef.Type = PackLoader.Str((JObject)item3, "type") ?? PackLoader.Str((JObject)item3, "kind") ?? "Research";
			treeNodeDef.Position = ReadVector(item3["position"]);
			treeNodeDef.Cost = ReadCry(item3["cost"]);
			treeNodeDef.Production = ReadCry(item3["production"] ?? item3["income"]);
			if (item3["effects"] is JArray jArray)
			{
				foreach (JToken item4 in jArray)
				{
					if (item4 == null)
					{
						continue;
					}
					if (item4.Type == JTokenType.String)
					{
						treeNodeDef.Effects.Add(Tuple.Create(item4.ToString(), 0.0));
						continue;
					}
					string text = PackLoader.Str((JObject)item4, "targetUid") ?? PackLoader.Str((JObject)item4, "target") ?? PackLoader.Str((JObject)item4, "uid");
					double v = 0.0;
					string[] array = new string[5] { "prodBoost", "boost", "production", "multiplier", "value" };
					foreach (string key in array)
					{
						if (PackLoader.TryDouble(item4[key], out v))
						{
							break;
						}
					}
					if (!string.IsNullOrEmpty(text))
					{
						treeNodeDef.Effects.Add(Tuple.Create(text, v));
					}
				}
			}
			JToken jToken2 = item3["requirements"] ?? item3["requires"];
			if (jToken2 is JArray)
			{
				foreach (JToken item5 in (JArray)jToken2)
				{
					if (item5 == null)
					{
						continue;
					}
					if (item5.Type == JTokenType.String)
					{
						treeNodeDef.Requirements.Add(Tuple.Create(item5.ToString(), 0.0, "NORM", item4: false));
						continue;
					}
					string text2 = PackLoader.Str((JObject)item5, "requiredUid") ?? PackLoader.Str((JObject)item5, "uid") ?? PackLoader.Str((JObject)item5, "id");
					double v2 = 0.0;
					PackLoader.TryDouble(item5["requiredCount"] ?? item5["count"], out v2);
					string item = PackLoader.Str((JObject)item5, "lineType") ?? "NORM";
					bool item2 = false;
					JToken jToken3 = item5["hidden"];
					if (jToken3 != null)
					{
						try
						{
							item2 = jToken3.Value<bool>();
						}
						catch
						{
						}
					}
					if (!string.IsNullOrEmpty(text2))
					{
						treeNodeDef.Requirements.Add(Tuple.Create(text2, v2, item, item2));
					}
				}
			}
			treeDefinition.Nodes.Add(treeNodeDef);
		}
		if (string.IsNullOrEmpty(treeDefinition.StartNode) && treeDefinition.Nodes.Count > 0)
		{
			TreeNodeDef treeNodeDef2 = treeDefinition.Nodes.FirstOrDefault((TreeNodeDef x) => x.Requirements.Count == 0);
			treeDefinition.StartNode = ((treeNodeDef2 != null) ? treeNodeDef2.Uid : treeDefinition.Nodes[0].Uid);
		}
		if (string.IsNullOrEmpty(treeDefinition.Title))
		{
			treeDefinition.Title = treeDefinition.Name;
		}
		return treeDefinition;
	}

	private static Vector3 ReadVector(JToken tok)
	{
		if (tok == null)
		{
			return Vector3.zero;
		}
		if (tok.Type == JTokenType.Object)
		{
			double v = 0.0;
			double v2 = 0.0;
			double v3 = 0.0;
			PackLoader.TryDouble(tok["x"], out v);
			PackLoader.TryDouble(tok["y"], out v2);
			PackLoader.TryDouble(tok["z"], out v3);
			return new Vector3((float)v, (float)v2, (float)v3);
		}
		if (tok.Type == JTokenType.Array)
		{
			JArray jArray = (JArray)tok;
			double v4 = 0.0;
			double v5 = 0.0;
			if (jArray.Count > 0)
			{
				PackLoader.TryDouble(jArray[0], out v4);
			}
			if (jArray.Count > 1)
			{
				PackLoader.TryDouble(jArray[1], out v5);
			}
			return new Vector3((float)v4, (float)v5, 0f);
		}
		return Vector3.zero;
	}

	private static double[] ReadCry(JToken tok)
	{
		double[] array = new double[8];
		if (tok == null)
		{
			return array;
		}
		if (tok.Type == JTokenType.Float || tok.Type == JTokenType.Integer || tok.Type == JTokenType.String)
		{
			if (PackLoader.TryDouble(tok, out var v))
			{
				array[0] = v;
			}
			return array;
		}
		if (tok.Type == JTokenType.Object)
		{
			for (int i = 0; i < 8; i++)
			{
				if (PackLoader.TryDouble(tok[((char)(97 + i)).ToString()], out var v2))
				{
					array[i] = v2;
				}
			}
		}
		return array;
	}

	internal bool Validate(out string error)
	{
		error = "";
		if (Nodes.Count == 0)
		{
			error = "nodes 为空";
			return false;
		}
		HashSet<string> hashSet = new HashSet<string>(Nodes.Select((TreeNodeDef n) => n.Uid), StringComparer.Ordinal);
		if (hashSet.Count != Nodes.Count)
		{
			error = "存在重复的 uid";
			return false;
		}
		if (string.IsNullOrEmpty(StartNode) || !hashSet.Contains(StartNode))
		{
			error = "startNode 不存在于 nodes 中: " + StartNode;
			return false;
		}
		foreach (TreeNodeDef node in Nodes)
		{
			foreach (Tuple<string, double, string, bool> requirement in node.Requirements)
			{
				if (!hashSet.Contains(requirement.Item1))
				{
					error = "节点 " + node.Uid + " 依赖了不存在的节点: " + requirement.Item1;
					return false;
				}
			}
			foreach (Tuple<string, double> effect in node.Effects)
			{
				if (effect.Item1 != "effect_evo_tap" && effect.Item1 != "effect_evo_offer" && !hashSet.Contains(effect.Item1))
				{
					error = "节点 " + node.Uid + " 的特效目标不存在: " + effect.Item1;
					return false;
				}
			}
		}
		return true;
	}
}
[Serializable]
internal class GenEventDto
{
	public string name;

	public string title;

	public string startNode;

	public bool gridView;

	public GenNodeDto[] nodes;
}
[Serializable]
internal class GenNodeDto
{
	public string uid;

	public string title;

	public string description;

	public string type;

	public Cry cost;

	public Cry production;

	public GenReqDto[] requirements;

	public GenEffectDto[] effects;

	public Vector3 position;
}
[Serializable]
internal class GenReqDto
{
	public string requiredUid;

	public int requiredCount;

	public string lineType;

	public bool hidden;
}
[Serializable]
internal class GenEffectDto
{
	public string targetUid;

	public float prodBoost;
}
internal static class SpriteBinder
{
	private static FieldInfo _loadedIndividual;

	private static FieldInfo _spriteIndexField;

	private static FieldInfo _spriteReferenceField;

	private static MethodInfo _setSpriteIndex;

	private static FieldInfo _resolverSprites;

	private static bool _ready;

	private static void InitReflection()
	{
		if (_ready)
		{
			return;
		}
		_ready = true;
		try
		{
			Type typeFromHandle = typeof(ItemInfo);
			_loadedIndividual = typeFromHandle.GetField("loadedIndividual", BindingFlags.Static | BindingFlags.NonPublic);
			_spriteIndexField = typeFromHandle.GetField("_spriteIndex", BindingFlags.Instance | BindingFlags.NonPublic);
			_spriteReferenceField = typeFromHandle.GetField("_spriteReference", BindingFlags.Instance | BindingFlags.NonPublic);
			_setSpriteIndex = typeFromHandle.GetMethod("SetSpriteIndex", BindingFlags.Instance | BindingFlags.NonPublic);
			_resolverSprites = typeof(ItemSpriteResolver).GetField("sprites", BindingFlags.Static | BindingFlags.NonPublic);
			Log.Info("sprite reflection: loadedIndividual=" + (_loadedIndividual != null) + " _spriteIndex=" + (_spriteIndexField != null) + " SetSpriteIndex=" + (_setSpriteIndex != null) + " resolver.sprites=" + (_resolverSprites != null));
		}
		catch (Exception e)
		{
			Log.Error("sprite reflection", e);
		}
	}

	internal static void Bind()
	{
		InitReflection();
		try
		{
			string gameTreeDir = PackLoader.GameTreeDir;
			if (!Directory.Exists(gameTreeDir))
			{
				Log.Warn("sprite binder: no staging dir");
				return;
			}
			string[] files = Directory.GetFiles(gameTreeDir, "*.png");
			Array.Sort(files, StringComparer.OrdinalIgnoreCase);
			Sprite[] array = new Sprite[files.Length];
			Dictionary<string, int> dictionary = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
			for (int i = 0; i < files.Length; i++)
			{
				string fileNameWithoutExtension = Path.GetFileNameWithoutExtension(files[i]);
				array[i] = TreeGenPlayer.LoadSprite(files[i]);
				dictionary[fileNameWithoutExtension] = i;
			}
			ItemInfo.ClearLoadedImages();
			_loadedIndividual?.SetValue(null, array);
			if (_resolverSprites != null && _resolverSprites.GetValue(null) is Dictionary<ItemSpriteReference, Sprite> dictionary2)
			{
				for (int j = 0; j < files.Length; j++)
				{
					string fileNameWithoutExtension2 = Path.GetFileNameWithoutExtension(files[j]);
					if (!string.IsNullOrEmpty(fileNameWithoutExtension2) && !(array[j] == null))
					{
						dictionary2[ItemSpriteReference.Content("LTE_import", fileNameWithoutExtension2)] = array[j];
					}
				}
			}
			Lte_PrefabData lte_PrefabData = ((EventController.instance != null) ? EventController.instance.eventPrefabData : null);
			ItemInfo[] array2 = ((lte_PrefabData != null && lte_PrefabData.treeData != null) ? lte_PrefabData.treeData.nodes : null);
			int num = 0;
			if (array2 != null)
			{
				ItemInfo[] array3 = array2;
				foreach (ItemInfo itemInfo in array3)
				{
					if (itemInfo == null || string.IsNullOrEmpty(itemInfo.type) || !dictionary.TryGetValue(itemInfo.type, out var value))
					{
						continue;
					}
					_spriteReferenceField?.SetValue(itemInfo, default(ItemSpriteReference));
					_spriteIndexField?.SetValue(itemInfo, value);
					if (_setSpriteIndex != null)
					{
						try
						{
							_setSpriteIndex.Invoke(itemInfo, new object[1] { value });
						}
						catch
						{
						}
					}
					num++;
				}
			}
			Log.Info("sprite binder: " + array.Length + " icon(s) staged, " + num + " node(s) bound");
		}
		catch (Exception e)
		{
			Log.Error("sprite binder", e);
		}
	}
}
internal static class TmpSprites
{
	private static TMP_SpriteAsset _asset;

	private static bool _published;

	private static Texture2D _atlas;

	private static int _nextX;

	private static int _rowH;

	private static FieldInfo _fGlyph;

	private static FieldInfo _fChar;

	internal static TMP_SpriteAsset Asset
	{
		get
		{
			if (_asset != null)
			{
				return _asset;
			}
			string text = "atlas";
			try
			{
				_atlas = new Texture2D(1024, 256, TextureFormat.RGBA32, mipChain: false);
				_atlas.SetPixels32(new Color32[262144]);
				_atlas.Apply();
				text = "CreateInstance";
				_asset = ScriptableObject.CreateInstance<TMP_SpriteAsset>();
				if (_asset == null)
				{
					Log.Error("TMP_SpriteAsset.CreateInstance returned null");
					return null;
				}
				text = "name";
				_asset.name = "cepack_sprites";
				text = "spriteSheet";
				_asset.spriteSheet = _atlas;
				text = "material";
				Shader shader = Shader.Find("TextMeshPro/Sprite");
				if (shader == null)
				{
					Log.Warn("shader 'TextMeshPro/Sprite' not found; sprite tags may not render");
				}
				else
				{
					Material material = new Material(shader);
					material.SetTexture(ShaderUtilities.ID_MainTex, _atlas);
					_asset.material = material;
				}
				text = "tables";
				if (!EnsureTables(_asset))
				{
					Log.Error("TMP sprite tables unavailable");
					return null;
				}
				Log.Info("tmp sprite asset created (shader=" + (shader != null) + ")");
			}
			catch (Exception e)
			{
				Log.Error("TmpSprites init failed at step '" + text + "'", e);
				_asset = null;
			}
			return _asset;
		}
	}

	internal static string Tag(string spriteName)
	{
		return "<sprite name=\"" + spriteName + "\">";
	}

	private static bool EnsureTables(TMP_SpriteAsset a)
	{
		try
		{
			Type typeFromHandle = typeof(TMP_SpriteAsset);
			if (_fGlyph == null)
			{
				_fGlyph = typeFromHandle.GetField("m_GlyphTable", BindingFlags.Instance | BindingFlags.NonPublic) ?? typeFromHandle.GetField("m_SpriteGlyphTable", BindingFlags.Instance | BindingFlags.NonPublic);
			}
			if (_fChar == null)
			{
				_fChar = typeFromHandle.GetField("m_SpriteCharacterTable", BindingFlags.Instance | BindingFlags.NonPublic);
			}
			if (_fGlyph == null || _fChar == null)
			{
				Log.Error("TMP table fields not found");
				return false;
			}
			if (_fGlyph.GetValue(a) == null)
			{
				_fGlyph.SetValue(a, new List<TMP_SpriteGlyph>());
			}
			if (_fChar.GetValue(a) == null)
			{
				_fChar.SetValue(a, new List<TMP_SpriteCharacter>());
			}
			return true;
		}
		catch (Exception e)
		{
			Log.Error("EnsureTables", e);
			return false;
		}
	}

	private static List<TMP_SpriteGlyph> Glyphs(TMP_SpriteAsset a)
	{
		return (List<TMP_SpriteGlyph>)_fGlyph.GetValue(a);
	}

	private static List<TMP_SpriteCharacter> Chars(TMP_SpriteAsset a)
	{
		return (List<TMP_SpriteCharacter>)_fChar.GetValue(a);
	}

	internal static string Register(string desiredName, Texture2D tex, out Sprite sprite, bool publish = false)
	{
		sprite = null;
		TMP_SpriteAsset asset = Asset;
		if (asset == null || tex == null)
		{
			return null;
		}
		try
		{
			int num = Mathf.Min(tex.width, 256);
			int num2 = Mathf.Min(tex.height, 256);
			if (_nextX + num > _atlas.width)
			{
				_nextX = 0;
				_rowH += num2 + 2;
			}
			if (_rowH + num2 > _atlas.height)
			{
				Log.Warn("sprite atlas full");
				return null;
			}
			Color[] pixels = tex.GetPixels(0, 0, num, num2);
			_atlas.SetPixels(_nextX, _rowH, num, num2, pixels);
			_atlas.Apply();
			List<TMP_SpriteGlyph> list = Glyphs(asset);
			List<TMP_SpriteCharacter> list2 = Chars(asset);
			int count = list.Count;
			sprite = Sprite.Create(rect: new Rect(_nextX, _rowH, num, num2), texture: _atlas, pivot: new Vector2(0.5f, 0.5f), pixelsPerUnit: 100f, extrude: 0u, meshType: SpriteMeshType.FullRect);
			TMP_SpriteGlyph tMP_SpriteGlyph = new TMP_SpriteGlyph
			{
				index = (uint)count,
				metrics = new GlyphMetrics(num, num2, 0f, num2, num),
				glyphRect = new GlyphRect(_nextX, _rowH, num, num2),
				scale = 1f,
				atlasIndex = 0,
				sprite = sprite
			};
			string text = Sanitize(desiredName);
			TMP_SpriteCharacter item = new TMP_SpriteCharacter((uint)(57344 + count), tMP_SpriteGlyph)
			{
				name = text
			};
			list.Add(tMP_SpriteGlyph);
			list2.Add(item);
			try
			{
				asset.UpdateLookupTables();
			}
			catch (Exception ex)
			{
				Log.Warn("UpdateLookupTables: " + ex.Message);
			}
			_nextX += num + 2;
			_rowH = Mathf.Max(_rowH, 0);
			if (publish)
			{
				Publish();
			}
			return text;
		}
		catch (Exception e)
		{
			Log.Error("TmpSprites.Register", e);
			return null;
		}
	}

	internal static void Publish()
	{
		try
		{
			if (_asset == null)
			{
				return;
			}
			int num = 0;
			TMP_SpriteAsset[] array = Resources.FindObjectsOfTypeAll<TMP_SpriteAsset>();
			foreach (TMP_SpriteAsset tMP_SpriteAsset in array)
			{
				if (!(tMP_SpriteAsset == null) && (object)tMP_SpriteAsset != _asset)
				{
					if (tMP_SpriteAsset.fallbackSpriteAssets == null)
					{
						tMP_SpriteAsset.fallbackSpriteAssets = new List<TMP_SpriteAsset>();
					}
					if (!tMP_SpriteAsset.fallbackSpriteAssets.Contains(_asset))
					{
						tMP_SpriteAsset.fallbackSpriteAssets.Add(_asset);
						num++;
					}
				}
			}
			TMP_SpriteAsset defaultSpriteAsset = TMP_Settings.defaultSpriteAsset;
			if (defaultSpriteAsset != null)
			{
				if (defaultSpriteAsset.fallbackSpriteAssets == null)
				{
					defaultSpriteAsset.fallbackSpriteAssets = new List<TMP_SpriteAsset>();
				}
				if (!defaultSpriteAsset.fallbackSpriteAssets.Contains(_asset))
				{
					defaultSpriteAsset.fallbackSpriteAssets.Add(_asset);
					num++;
				}
			}
			if (!_published || num > 0)
			{
				_published = true;
				Log.Info("tmp sprite asset published to " + num + " sprite asset(s)");
			}
		}
		catch (Exception ex)
		{
			Log.Warn("TmpSprites.Publish: " + ex.Message);
		}
	}

	private static string Sanitize(string s)
	{
		if (string.IsNullOrEmpty(s))
		{
			return "cepack_sprite";
		}
		StringBuilder stringBuilder = new StringBuilder();
		foreach (char c in s)
		{
			if (char.IsLetterOrDigit(c) || c == '_' || c == '-')
			{
				stringBuilder.Append(c);
			}
		}
		if (stringBuilder.Length <= 0)
		{
			return "cepack_sprite";
		}
		return stringBuilder.ToString();
	}

	internal static bool TryRepaintExistingSprite(string spriteName, string pngPath)
	{
		if (string.IsNullOrEmpty(spriteName) || string.IsNullOrEmpty(pngPath) || !File.Exists(pngPath))
		{
			return false;
		}
		try
		{
			Texture2D texture2D = new Texture2D(2, 2, TextureFormat.RGBA32, mipChain: false);
			if (!texture2D.LoadImage(File.ReadAllBytes(pngPath)))
			{
				UnityEngine.Object.Destroy(texture2D);
				return false;
			}
			int num = 0;
			TMP_SpriteAsset[] array = Resources.FindObjectsOfTypeAll<TMP_SpriteAsset>();
			foreach (TMP_SpriteAsset tMP_SpriteAsset in array)
			{
				if (tMP_SpriteAsset == null)
				{
					continue;
				}
				List<TMP_SpriteCharacter> list = SafeChars(tMP_SpriteAsset);
				if (list == null)
				{
					continue;
				}
				foreach (TMP_SpriteCharacter item in list)
				{
					if (item == null)
					{
						continue;
					}
					num++;
					if (string.Equals(item.name, spriteName, StringComparison.Ordinal))
					{
						Texture2D texture2D2 = tMP_SpriteAsset.spriteSheet as Texture2D;
						if (texture2D2 == null)
						{
							Log.Warn("repaint '" + spriteName + "': spriteSheet is not a Texture2D");
							return false;
						}
						if (!texture2D2.isReadable)
						{
							Log.Warn("repaint '" + spriteName + "': atlas " + texture2D2.width + "x" + texture2D2.height + " is NOT readable - cannot repaint");
							return false;
						}
						if (!(item.glyph is TMP_SpriteGlyph { glyphRect: var glyphRect }))
						{
							Log.Warn("repaint '" + spriteName + "': glyph missing");
							return false;
						}
						if (glyphRect.width <= 0 || glyphRect.height <= 0)
						{
							Log.Warn("repaint '" + spriteName + "': empty glyph rect");
							return false;
						}
						Color[] colors = ScaleTo(texture2D, glyphRect.width, glyphRect.height);
						texture2D2.SetPixels(glyphRect.x, glyphRect.y, glyphRect.width, glyphRect.height, colors);
						texture2D2.Apply();
						Log.Info("repainted sprite '" + spriteName + "' slot " + glyphRect.width + "x" + glyphRect.height + " at (" + glyphRect.x + "," + glyphRect.y + ") in atlas " + texture2D2.width + "x" + texture2D2.height);
						return true;
					}
				}
			}
			Log.Warn("repaint '" + spriteName + "': name not found in " + num + " sprite character(s)");
			return false;
		}
		catch (Exception e)
		{
			Log.Error("TryRepaintExistingSprite", e);
			return false;
		}
	}

	private static List<TMP_SpriteCharacter> SafeChars(TMP_SpriteAsset a)
	{
		try
		{
			if (_fChar == null)
			{
				Type typeFromHandle = typeof(TMP_SpriteAsset);
				_fChar = typeFromHandle.GetField("m_SpriteCharacterTable", BindingFlags.Instance | BindingFlags.NonPublic);
				_fGlyph = typeFromHandle.GetField("m_GlyphTable", BindingFlags.Instance | BindingFlags.NonPublic) ?? typeFromHandle.GetField("m_SpriteGlyphTable", BindingFlags.Instance | BindingFlags.NonPublic);
			}
			return (_fChar != null) ? (_fChar.GetValue(a) as List<TMP_SpriteCharacter>) : null;
		}
		catch
		{
			return null;
		}
	}

	private static Color[] ScaleTo(Texture2D src, int w, int h)
	{
		Color[] array = new Color[w * h];
		for (int i = 0; i < h; i++)
		{
			int y = Mathf.Clamp(Mathf.RoundToInt(((float)i + 0.5f) * (float)src.height / (float)h), 0, src.height - 1);
			for (int j = 0; j < w; j++)
			{
				int x = Mathf.Clamp(Mathf.RoundToInt(((float)j + 0.5f) * (float)src.width / (float)w), 0, src.width - 1);
				array[i * w + j] = src.GetPixel(x, y);
			}
		}
		return array;
	}

	internal static string RegisterFile(string path, string desiredName)
	{
		if (string.IsNullOrEmpty(path) || !File.Exists(path))
		{
			return null;
		}
		try
		{
			Texture2D texture2D = new Texture2D(2, 2, TextureFormat.RGBA32, mipChain: false);
			if (!texture2D.LoadImage(File.ReadAllBytes(path)))
			{
				UnityEngine.Object.Destroy(texture2D);
				return null;
			}
			Sprite sprite;
			return Register(desiredName, texture2D, out sprite);
		}
		catch (Exception ex)
		{
			Log.Warn("RegisterFile " + path + ": " + ex.Message);
			return null;
		}
	}
}
public static class PatchHooks
{
	private static int _ticks;

	private static int _hintLogged;

	private static int _repaints;

	private static Texture2D _bgTex;

	private static GameObject _bgLayer;

	private static bool _probeDone;

	private static bool _backdropSeen;

	private static int _probeAt;

	private static float _bgNextSweep;   // next backdrop sweep time

	/// <summary>
	/// Stop rendering the event background entirely. Measured on the live scene, the
	/// backdrop ("Pink Donut", the "LTE_*_tree_background" meshes) is drawn at the SAME
	/// sortingOrder as the tree and is busy enough to swallow the connecting lines.
	/// Reordering only traded one occlusion for another, so do not draw it at all.
	/// The tree then reads perfectly against the camera's plain clear colour.
	/// Injected into EventController.Update.
	/// </summary>
	private static int _nanoAt;
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

	/// <summary>
	/// Rewrite the event-leaderboard "next rank" hint.
	///
	/// Vanilla (SegLeaderboardDisplay.Start()) writes
	///     seg_increase_score / seg_score_away  =  "收集 {0} 即可达到 {1}"
	/// where {0} is the score gap to the LAST seat of the next segment up and {1} is
	/// that segment's localised name. The mod replaces it with the two-gap format
	///     距离前<N>名 {gap}，距离上一名 {gapAbove}
	///
	/// Both gaps are recomputed here from the same cohort list vanilla reads:
	///   gap     = cohort[rankGroups[i-1].breakPoint - 1].score - myInfo.score
	///           = what is still missing to take the last seat of the segment above.
	///   gapAbove= cohort[myInfo.sorted_rank - 2].score - myInfo.score
	///           = what is still missing to overtake the single player above me.
	///
	/// Injected at the END of Start() (appendcall) rather than its head (call): Start()
	/// ASSIGNS the text, so a head injection would simply be overwritten again.
	/// Vanilla also Destroy()s nextRankObject whenever it has nothing to say (top
	/// segment, unknown own rank, already ahead). Those rows keep an empty text, and an
	/// empty text is the signal here to leave the hint alone.
	/// </summary>
	public static void RewriteNextRankHint()
	{
		try
		{
			// One-shot diagnostics. The first version of this hook logged ONLY on exception,
			// which made a silent early-return indistinguishable from the hook never running
			// at all. Every early return now reports why it gave up.
			bool loud = System.Threading.Interlocked.Increment(ref _hintLogged) <= 4;
			SegLeaderboardDisplay d = UnityEngine.Object.FindObjectOfType<SegLeaderboardDisplay>();
			if (loud) Log.Info("HINT display=" + (d != null)
				+ " nextRankText=" + (d != null && d.nextRankText != null)
				+ " text=[" + ((d != null && d.nextRankText != null) ? d.nextRankText.text : "<n/a>") + "]");
			if (d == null || d.nextRankText == null) return;

			SegmentedLeaderboardManager slm0 = SegmentedLeaderboardManager.instance;
			if (loud) Log.Info("HINT slm=" + (slm0 != null)
				+ " myInfo=" + (slm0 != null && slm0.myInfo != null)
				+ " cohort=" + ((slm0 != null && slm0.cohort != null) ? slm0.cohort.Count.ToString() : "<null>")
				+ " groups=" + ((slm0 != null && slm0.rankGroups != null) ? slm0.rankGroups.Length.ToString() : "<null>"));

			if (string.IsNullOrEmpty(d.nextRankText.text))
			{
				if (loud) Log.Info("HINT vanilla left the text empty -> skipped (row was Destroy()ed)");
				return;
			}
			if (loud) Log.Info("HINT vanilla text=[" + d.nextRankText.text + "] -> rewriting");

			SegmentedLeaderboardManager slm = SegmentedLeaderboardManager.instance;
			if (slm == null || slm.myInfo == null || slm.cohort == null || slm.rankGroups == null) return;

			// Locate my segment: the hint is only meaningful when there is one above it.
			int i = -1;
			for (int k = 0; k < slm.rankGroups.Length; k++)
				if (slm.rankGroups[k] == slm.myRankGroup) { i = k; break; }
			if (i <= 0) return;

			SegLeaderboardRankGroup above = slm.rankGroups[i - 1];
			string icon = "<voffset=-0.3em><size=22>" + Calculator.eventCurrencyText + "</size></voffset>";
			string s = "";

			// 距离前<N>名 ---- the last seat of the segment above, i.e. rank == breakPoint.
			int seat = above.breakPoint - 1;                       // cohort index of that seat
			if (seat >= 0 && seat < slm.cohort.Count)
			{
				int gap = slm.cohort[seat].score - slm.myInfo.score;
				if (gap > 0) s = "距离前" + above.breakPoint + "名" + icon + gap;
			}

			// 距离上一名 ---- cohort is sorted by score descending, so my own row is at
			// index sorted_rank-1 and the player above me at sorted_rank-2.
			int aboveIdx = slm.myInfo.sorted_rank - 2;
			if (aboveIdx >= 0 && aboveIdx < slm.cohort.Count)
			{
				int gap = slm.cohort[aboveIdx].score - slm.myInfo.score;
				if (gap > 0)
				{
					if (s != "") s += "，";
					s += "距离上一名" + icon + gap;
				}
			}

			if (s != "") d.nextRankText.text = s;
		}
		catch (Exception e) { Log.Error("RewriteNextRankHint", e); }
	}

	public static void HideBackdrop()
	{
		_ticks++;
		// Sweep CONTINUOUSLY instead of once. The old version latched a static bool the first
		// time it ran, but leaving and re-entering the event builds a NEW backdrop, so the
		// second visit kept its background. Keyed off unscaled time so the sweep rate does not
		// change with the (unlocked) framerate.
		float now = Time.unscaledTime;
		if (now < _bgNextSweep) return;
		_bgNextSweep = now + 1f;
		try
		{
			string[] backdropTex = new string[2] { "pink donut", "tree_background" };
			int n = 0;
			foreach (Renderer r in Resources.FindObjectsOfTypeAll<Renderer>())
			{
				if (r == null || !r.gameObject.activeInHierarchy) continue;
				if (r is LineRenderer) continue;      // never touch the connections
				if (!r.enabled) continue;            // already off
				string tn = "";
				MeshRenderer mr = r as MeshRenderer;
				SpriteRenderer sr = r as SpriteRenderer;
				if (mr != null && mr.material != null && mr.material.mainTexture != null) tn = mr.material.mainTexture.name.ToLowerInvariant();
				else if (sr != null && sr.sprite != null) tn = sr.sprite.name.ToLowerInvariant();
				if (tn == "") continue;
				// NEVER match the tree own art: frameCircle / TileFrameLifeFormCircle are the node
				// frames and icons, and matching those once buried the nodes behind the backdrop.
				if (tn.Contains("frame") || tn.Contains("icon") || tn.Contains("node")) continue;
				bool isBg = false;
				foreach (string w in backdropTex) if (tn.Contains(w)) { isBg = true; break; }
				if (!isBg) continue;
				r.enabled = false;
				n++;
			}
			if (n > 0) Log.Info("BACKDROP: disabled " + n + " background renderer(s) so nothing can cover the tree");
		}
		catch (Exception e) { Log.Error("HideBackdrop", e); }
	}

	public static void UnlockFramerate()
	{
		// This hook is the mod's entry point once the plugin has been FOLDED into
		// Assembly-CSharp: Unity's RuntimeInitializeOnLoads.json lookup only fires for entries
		// naming the plugin assembly, and after folding there is no such assembly. The game calls
		// this from UIQualitySettings.SetGraphicsQuality very early, so bootstrapping from here is
		// reliable. Install() is idempotent.
		try { Bootstrap.Install(); } catch (Exception e) { Log.Error("bootstrap from patch hook failed: " + e.Message); }
		try
		{
			QualitySettings.SetQualityLevel(1, applyExpensiveChanges: true);
			QualitySettings.vSyncCount = 0;
			Application.targetFrameRate = -1;
			Log.Info("patch hook: framerate unlocked (vSync=0, targetFrameRate=-1)");
		}
		catch (Exception e)
		{
			Log.Error("UnlockFramerate", e);
		}
	}

	public static void Tick()
	{
		_ticks++;
		if (_ticks < 240 || _repaints >= 60 || _ticks % 120 != 0)
		{
			return;
		}
		_repaints++;
		if (_probeDone)
		{
			return;
		}
		if (!_backdropSeen)
		{
			MeshRenderer[] array = Resources.FindObjectsOfTypeAll<MeshRenderer>();
			foreach (MeshRenderer meshRenderer in array)
			{
				if (!(meshRenderer == null) && meshRenderer.gameObject.activeInHierarchy && meshRenderer.bounds.size.x > 1000f)
				{
					_backdropSeen = true;
					break;
				}
			}
			if (_backdropSeen)
			{
				_probeAt = _ticks;
				Log.Info("PROBE: backdrop present at tick " + _ticks + ", letting it settle");
			}
		}
		else
		{
			if (_ticks - _probeAt < 180)
			{
				return;
			}
			_probeDone = true;
			try
			{
				Pack lastLoaded = PackLoader.LastLoaded;
				string text = null;
				if (lastLoaded != null)
				{
					// A pack has ONE background ("background" in pack.json). The legacy
					// "backgrounds" array is only a fallback so packs written by older
					// editor builds keep working.
					if (!string.IsNullOrEmpty(lastLoaded.Background) && File.Exists(lastLoaded.Background))
					{
						text = lastLoaded.Background;
					}
					else if (lastLoaded.Backgrounds != null)
					{
						foreach (BackgroundDef background in lastLoaded.Backgrounds)
						{
							if (background.Visible && background.File != null && File.Exists(background.File))
							{
								text = background.File;
								break;
							}
						}
					}
				}
				Texture2D[] array3;
				if (text != null)
				{
					byte[] data = File.ReadAllBytes(text);
					// "tree_background" covers the other event templates; "pink donut" and the two
					// circle sprites are the fetus-womb template this event borrows its tree from.
					string[] array2 = new string[4] { "tree_background", "pink donut", "fetus circle", "mother circle" };
					int num = 0;
					array3 = Resources.FindObjectsOfTypeAll<Texture2D>();
					foreach (Texture2D texture2D in array3)
					{
						if (texture2D == null)
						{
							continue;
						}
						string text2 = texture2D.name.ToLowerInvariant();
						bool flag = false;
						string[] array4 = array2;
						foreach (string text3 in array4)
						{
							if (text2 == text3 || text2 == text3 + " (instance)")
							{
								flag = true;
								break;
							}
						}
						if (!flag)
						{
							continue;
						}
						try
						{
							bool flag2 = texture2D.LoadImage(data);
							Log.Info("BG FIX: texture '" + texture2D.name + "' " + texture2D.width + "x" + texture2D.height + " readable=" + texture2D.isReadable + " -> " + (flag2 ? "REPLACED" : "returned false"));
							if (flag2)
							{
								num++;
							}
						}
						catch (Exception ex)
						{
							Log.Warn("BG FIX: '" + texture2D.name + "' FAILED: " + ex.Message);
						}
					}
					Log.Info("BG FIX: " + num + " backdrop texture(s) replaced");
				}
				// ---- OUR OWN LAYER, BETWEEN THE NODES AND THE BACKDROP --------------------
				// This is what finally replaced painting/hunting the game's own backdrop.
				// The probe measured the tree nodes at 250-259 units from the camera and the
				// original backdrop at 370, so a quad at 320 is guaranteed to draw BEHIND
				// every node and IN FRONT of whatever paints the original background - no
				// need to know what that object is. A flat black quad sits 1 unit further
				// back so any transparency in the art still hides the original.
				if (text != null)
				{
					try
					{
						Camera camQ = Camera.main;
						if (camQ != null)
						{
							float d = 320f;
							float qh = 2f * d * Mathf.Tan(camQ.fieldOfView * 0.5f * ((float)Math.PI / 180f)) * 1.2f;
							float qw = qh * (float)Screen.width / (float)Screen.height;
							Texture2D art = new Texture2D(2, 2, TextureFormat.RGBA32, false);
							art.LoadImage(File.ReadAllBytes(text));
							art.wrapMode = TextureWrapMode.Clamp;
							PackLoader.MakeViewQuad(camQ, "cepack_bg_black", d + 1f, qw, qh, PackLoader.MakeUnlit(null, Color.black));
							PackLoader.MakeViewQuad(camQ, "cepack_bg_image", d, qw, qh, PackLoader.MakeUnlit(art, Color.white));
							Log.Info("BG QUAD: cam='" + camQ.name + "' fov=" + camQ.fieldOfView.ToString("F1") +
							         " d=" + d + " size=" + qw.ToString("F0") + "x" + qh.ToString("F0") +
							         " screen=" + Screen.width + "x" + Screen.height);
						}
						else
						{
							Log.Warn("BG QUAD: Camera.main is null");
						}
					}
					catch (Exception eQ)
					{
						Log.Error("BG QUAD", eQ);
					}
				}
				Camera camP = Camera.main;
				Log.Info("PROBE: screen=" + Screen.width + "x" + Screen.height + " cam='" + ((camP != null) ? camP.name : "none") + "' fov=" + ((camP != null) ? camP.fieldOfView.ToString("F1") : "-") + " ortho=" + ((camP != null) ? camP.orthographic.ToString() : "-"));
				int num2 = 0;
				array3 = Resources.FindObjectsOfTypeAll<Texture2D>();
				foreach (Texture2D texture2D2 in array3)
				{
					if (!(texture2D2 == null) && texture2D2.width >= 512)
					{
						Log.Info("PROBE tex '" + texture2D2.name + "' " + texture2D2.width + "x" + texture2D2.height + " fmt=" + texture2D2.format.ToString() + " readable=" + texture2D2.isReadable + " mips=" + texture2D2.mipmapCount);
						if (++num2 >= 40)
						{
							break;
						}
					}
				}
				Log.Info("PROBE: " + num2 + " large texture(s)");
				float[] array5 = new float[5] { 0.2f, 0.35f, 0.5f, 0.65f, 0.8f };
				for (int i = 0; i < array5.Length; i++)
				{
					float num3 = array5[i];
					if (camP == null)
					{
						break;
					}
					Ray ray = camP.ScreenPointToRay(new Vector3((float)Screen.width * num3, (float)Screen.height * 0.5f, 0f));
					List<Renderer> list = new List<Renderer>();
					Renderer[] array6 = Resources.FindObjectsOfTypeAll<Renderer>();
					foreach (Renderer renderer in array6)
					{
						if (!(renderer == null) && renderer.gameObject.activeInHierarchy && renderer.bounds.IntersectRay(ray))
						{
							list.Add(renderer);
						}
					}
					list.Sort((Renderer a, Renderer b) => Vector3.Distance(camP.transform.position, a.bounds.center).CompareTo(Vector3.Distance(camP.transform.position, b.bounds.center)));
					Log.Info("PROBE ray x=" + num3.ToString("F2") + " hits=" + list.Count);
					for (int num4 = 0; num4 < list.Count && num4 < 8; num4++)
					{
						Renderer renderer2 = list[num4];
						string text4 = "-";
						MeshRenderer meshRenderer2 = renderer2 as MeshRenderer;
						SpriteRenderer spriteRenderer = renderer2 as SpriteRenderer;
						if (meshRenderer2 != null && meshRenderer2.material != null && meshRenderer2.material.mainTexture != null)
						{
							text4 = meshRenderer2.material.mainTexture.name;
						}
						else if (spriteRenderer != null && spriteRenderer.sprite != null)
						{
							text4 = spriteRenderer.sprite.name;
						}
						string text5 = renderer2.gameObject.name;
						Transform parent = renderer2.transform.parent;
						for (int num5 = 0; num5 < 3; num5++)
						{
							if (!(parent != null))
							{
								break;
							}
							text5 = parent.name + "/" + text5;
							parent = parent.parent;
						}
						Log.Info("PROBE   #" + num4 + " " + renderer2.GetType().Name + " '" + text5 + "' tex=" + text4 + " layer=" + renderer2.gameObject.layer + " dist=" + Vector3.Distance(camP.transform.position, renderer2.bounds.center).ToString("F0") + " sorting=" + renderer2.sortingOrder);
					}
				}
			}
			catch (Exception e)
			{
				Log.Error("PROBE", e);
			}
			try
			{
				Log.Info("=== PATCH HOOK: EventController.Update reached (tick " + _ticks + ") ===");
				EventController instance = EventController.instance;
				if (instance != null && instance.treeBG != null)
				{
					Log.Info("  hook treeBG='" + instance.treeBG.gameObject.name + "' active=" + instance.treeBG.gameObject.activeInHierarchy + " mat='" + ((instance.treeBG.material != null) ? instance.treeBG.material.name : "?") + "'");
				}
				MeshRenderer[] array = Resources.FindObjectsOfTypeAll<MeshRenderer>();
				foreach (MeshRenderer meshRenderer3 in array)
				{
					if (meshRenderer3 == null || !meshRenderer3.gameObject.activeInHierarchy)
					{
						continue;
					}
					Vector3 size = meshRenderer3.bounds.size;
					if (Mathf.Max(size.x, size.y) < 200f)
					{
						continue;
					}
					string text6 = ((meshRenderer3.material != null && meshRenderer3.material.mainTexture != null) ? meshRenderer3.material.mainTexture.name : "null");
					string text7 = meshRenderer3.gameObject.name;
					Transform parent2 = meshRenderer3.transform.parent;
					for (int num6 = 0; num6 < 3; num6++)
					{
						if (!(parent2 != null))
						{
							break;
						}
						text7 = parent2.name + "/" + text7;
						parent2 = parent2.parent;
					}
					string[] obj = new string[12]
					{
						"  hook BIG MR path='",
						text7,
						"' mat='",
						(meshRenderer3.material != null) ? meshRenderer3.material.name : "?",
						"' shader='",
						(meshRenderer3.material != null && meshRenderer3.material.shader != null) ? meshRenderer3.material.shader.name : "?",
						"' tex=",
						text6,
						" layer=",
						meshRenderer3.gameObject.layer.ToString(),
						" bounds=",
						null
					};
					Vector3 vector = size;
					obj[11] = vector.ToString();
					Log.Info(string.Concat(obj));
				}
			}
			catch (Exception e2)
			{
				Log.Error("PatchHooks.Tick", e2);
			}
		}
	}
}
internal static class EventContent
{
	internal static void ApplyCurrencies(Pack pack, LTEData lte)
	{
		if (pack.Currencies == null || pack.Currencies.Count == 0)
		{
			return;
		}
		try
		{
			int num = Mathf.Min(4, pack.Currencies.Count);
			if (lte.currencyCount <= 0 || pack.CurrencyCount <= 0)
			{
				lte.currencyCount = num;
			}
			for (int i = 0; i < num; i++)
			{
				CurrencyDef currencyDef = pack.Currencies[i];
				if (!string.IsNullOrEmpty(currencyDef.Name))
				{
					string key = "cepack_currency_" + pack.Id + "_" + (i + 1);
					PackLoader.AddTermPublic(key, currencyDef.Name);
					SetCurrencyKey(lte, i, key);
				}
				if (!string.IsNullOrEmpty(currencyDef.Icon))
				{
					Sprite currencySprite = GetCurrencySprite(lte, i);
					string text = ((currencySprite != null) ? currencySprite.name : null);
					if (string.IsNullOrEmpty(text))
					{
						Log.Warn("currency " + (i + 1) + " has no sprite slot to repaint");
					}
					else if (!TmpSprites.TryRepaintExistingSprite(text, currencyDef.Icon))
					{
						Log.Warn("currency " + (i + 1) + " icon '" + currencyDef.Icon + "' could not be applied to slot '" + text + "'");
					}
				}
			}
			Log.Info("currencies applied: " + num + " (count=" + lte.currencyCount + ")");
		}
		catch (Exception e)
		{
			Log.Error("ApplyCurrencies", e);
		}
	}

	private static Sprite GetCurrencySprite(LTEData lte, int i)
	{
		return i switch
		{
			0 => lte.currencyOne, 
			1 => lte.currencyTwo, 
			2 => lte.currencyThree, 
			3 => lte.currencyFour, 
			_ => null, 
		};
	}

	private static void SetCurrencyKey(LTEData lte, int i, string key)
	{
		switch (i)
		{
		case 0:
			lte.currencyOneKey = key;
			break;
		case 1:
			lte.currencyTwoKey = key;
			break;
		case 2:
			lte.currencyThreeKey = key;
			break;
		case 3:
			lte.currencyFourKey = key;
			break;
		}
	}

	private static void SetCurrencySprite(LTEData lte, int i, Sprite s)
	{
		switch (i)
		{
		case 0:
			lte.currencyOne = s;
			break;
		case 1:
			lte.currencyTwo = s;
			break;
		case 2:
			lte.currencyThree = s;
			break;
		case 3:
			lte.currencyFour = s;
			break;
		}
	}

	internal static void ApplyLocalisation(Pack pack)
	{
		try
		{
			if (!string.IsNullOrEmpty(pack.TapHint))
			{
				PackLoader.AddTermPublic("w_tap_to_earn", pack.TapHint);
			}
			if (!string.IsNullOrEmpty(pack.ResourceName))
			{
				PackLoader.AddTermPublic("lte_fetus_nutrients", pack.ResourceName);
				PackLoader.AddTermPublic("lte_import_resource", pack.ResourceName);
			}
			foreach (KeyValuePair<string, string> item in pack.Localization)
			{
				PackLoader.AddTermPublic(item.Key, item.Value);
			}
			Log.Info("localisation overrides queued: " + (pack.Localization.Count + ((!string.IsNullOrEmpty(pack.TapHint)) ? 1 : 0) + ((!string.IsNullOrEmpty(pack.ResourceName)) ? 2 : 0)));
		}
		catch (Exception ex)
		{
			Log.Warn("ApplyLocalisation: " + ex.Message);
		}
	}

	internal static void ApplyMissions(Pack pack, LTEData lte)
	{
		if (pack.Ranks == null || pack.Ranks.Count == 0)
		{
			return;
		}
		try
		{
			RankRule rankRule = ScriptableObject.CreateInstance<RankRule>();
			rankRule.name = "cepack_rankrule_" + pack.Id;
			rankRule.ranks = new Rank[pack.Ranks.Count];
			int num = 0;
			for (int i = 0; i < pack.Ranks.Count; i++)
			{
				RankDef rankDef = pack.Ranks[i];
				Rank rank = new Rank();
				rank.title = (string.IsNullOrEmpty(rankDef.Title) ? ("Rank " + (i + 1)) : rankDef.Title);
				rank.targetHrs = (float)rankDef.TargetHrs;
				List<Mission> list = new List<Mission>();
				foreach (MissionDef mission4 in rankDef.Missions)
				{
					foreach (KeyValuePair<string, double> item in (mission4.Targets.Count > 0) ? mission4.Targets : new List<KeyValuePair<string, double>>
					{
						new KeyValuePair<string, double>(mission4.ReqItemId, mission4.ReqAmount)
					})
					{
						MissionDef missionDef = new MissionDef
						{
							Type = mission4.Type,
							ReqItemId = item.Key,
							ReqAmount = item.Value,
							PrizeType = mission4.PrizeType,
							PrizeId = mission4.PrizeId,
							PrizeAmount = mission4.PrizeAmount,
							Hidden = mission4.Hidden,
							TreeType = mission4.TreeType
						};
						Mission mission = new Mission();
						mission.type = ParseEnum(missionDef.Type, Mission.MissionType.Collect);
						mission.treeType = ParseEnum(missionDef.TreeType, Mission.TreeType.NONE);
						mission.prizeType = ParseEnum(missionDef.PrizeType, MissionGroup.PrizeType.Darwinium);
						mission.prizeAmount = missionDef.PrizeAmount;
						string text = missionDef.PrizeId;
						// MissionGroup.GetIcon() is `switch (prizeType)` where EVERY branch dereferences an
						// external lookup keyed by prizeID. We do NOT downgrade the pack's declared prizeType
						// ("我们不应该降级") - instead prizeID is resolved to something the game can actually
						// look up, keeping the declared type intact:
						//   Lootbox -> one of the game's OWN lootbox ids ("dino_lootbox_1/2/3"), so
						//              LootBoxController.GetInfo(prizeID) returns a real LootboxInfo and
						//              `.sprite` cannot throw. An unknown prizeID makes GetInfo() log
						//              "Could not find lootbox id" and return null -> NRE in Refresh() ->
						//              InitGame aborts before StartCoroutine(DelayStartGame()) and the
						//              "Connecting..." preloader is never hidden.
						//   other   -> the mission's own (real) item id when the pack omits prizeID.
						if (mission.prizeType == MissionGroup.PrizeType.Lootbox)
						{
							// Resolve the reward to the game's own "罗吉特" (Logit) currency. DooberStore
							// tracks it as ItemInfo "stat_doober" (doobers = ItemInfo.FindItem("stat_doober"),
							// alongside its logitOrigins / buyLogit / selectedLogitPrize members), and
							// MissionGroup.GetIcon() renders it with
							//     case PrizeType.Doober: return ItemInfo.FindItem("stat_doober").icon;
							// which dereferences NO prizeID lookup, so it cannot throw. The Lootbox branch
							// it replaces is `LootBoxController.instance.GetInfo(prizeID).sprite`, and a
							// custom prizeID makes GetInfo() return null -> NRE in Refresh() -> InitGame
							// aborts before StartCoroutine(DelayStartGame()) -> "Connecting..." never closes.
							Log.Info("mission prize Lootbox '" + text + "' -> the vanilla '罗吉特' (Logit) currency (PrizeType.Doober / stat_doober)");
							mission.prizeType = MissionGroup.PrizeType.Doober;
							text = "stat_doober";
						}
						else if (string.IsNullOrEmpty(text))
						{
							text = missionDef.ReqItemId;
							Log.Info("mission prize '" + missionDef.PrizeType + "' had no prizeID; using the mission item '" + text + "'");
						}
						MissionGroup.PrizeType prizeType = mission.prizeType;
						if ((uint)prizeType > 2u && prizeType != MissionGroup.PrizeType.Badge && string.IsNullOrEmpty(text))
						{
							text = ((long)Math.Round(missionDef.PrizeAmount)).ToString(CultureInfo.InvariantCulture);
						}
						if (mission.prizeType == MissionGroup.PrizeType.Darwinium && !int.TryParse(text, out var _))
						{
							text = Mathf.Max(1, (int)Math.Round(missionDef.PrizeAmount)).ToString(CultureInfo.InvariantCulture);
							Log.Warn("mission prize Darwinium had a non-numeric prizeID; using '" + text + "'");
						}
						mission.prizeID = text ?? "";
						mission.reqItemId = missionDef.ReqItemId ?? "";
						mission.reqAmount = missionDef.ReqAmount;
						mission.hidden = missionDef.Hidden;
						mission.active = true;
						mission.missionOrderID = num++;
						list.Add(mission);
					}
				}
				rank.missions = list.ToArray();   // reqItem is resolved when handed to the controller
				rankRule.ranks[i] = rank;
			}
			if (rankRule.ranks.Length == 0 || rankRule.ranks[0].missions == null)
			{
				Log.Warn("mission list empty; keeping the built-in rank data");
				return;
			}
			lte.rankData = rankRule;
			try
			{
				Badge_Info badge_Info = ((Singleton<LteServer>.instance != null && Singleton<LteServer>.instance.masterLteData != null) ? Singleton<LteServer>.instance.masterLteData.badgeData : null);
				if (badge_Info != null && badge_Info.badgeInfos != null && badge_Info.badgeInfos.Count > 0)
				{
					List<string> list2 = new List<string>();
					foreach (Badge_Info.Badge badgeInfo in badge_Info.badgeInfos)
					{
						if (badgeInfo != null && !string.IsNullOrEmpty(badgeInfo.info) && !list2.Contains(badgeInfo.info))
						{
							list2.Add(badgeInfo.info);
						}
					}
					int num2 = 0;
					Rank[] ranks = rankRule.ranks;
					for (int j = 0; j < ranks.Length; j++)
					{
						Mission[] missions = ranks[j].missions;
						foreach (Mission mission2 in missions)
						{
							if (mission2.prizeType == MissionGroup.PrizeType.Badge && (string.IsNullOrEmpty(mission2.prizeID) || !list2.Contains(mission2.prizeID)))
							{
								Log.Warn("badge prize id '" + mission2.prizeID + "' is not a real badge; using '" + list2[0] + "'");
								mission2.prizeID = list2[0];
								num2++;
							}
						}
					}
					if (num2 > 0)
					{
						Log.Info("badge prizes corrected: " + num2);
					}
					Log.Info("valid badge ids (" + list2.Count + "): " + string.Join(",", list2.Take(24).ToArray()) + ((list2.Count > 24) ? ", ..." : ""));
				}
				else
				{
					Log.Warn("badgeData unavailable; Badge prizes cannot be validated");
				}
			}
			catch (Exception ex)
			{
				Log.Warn("badge validation: " + ex.Message);
			}
			try
			{
				LTE_Master_Rule lTE_Master_Rule = ((Singleton<LteServer>.instance != null && Singleton<LteServer>.instance.masterLteData != null) ? Singleton<LteServer>.instance.masterLteData.masterRankRule : null);
				if (lTE_Master_Rule != null)
				{
					if (lTE_Master_Rule.lteRankRules == null)
					{
						lTE_Master_Rule.lteRankRules = new List<RankRule>();
					}
					if (!lTE_Master_Rule.lteRankRules.Contains(rankRule))
					{
						lTE_Master_Rule.lteRankRules.Add(rankRule);
						Log.Info("registered custom RankRule '" + rankRule.ranks[0].title + "' in the master rule list (" + lTE_Master_Rule.lteRankRules.Count + " entries) so the exploration banner can build");
					}
				}
				else
				{
					Log.Warn("masterRankRule unavailable; the exploration banner may still NRE");
				}
			}
			catch (Exception ex2)
			{
				Log.Warn("registering master rank rule: " + ex2.Message);
			}
			try
			{
				int num3 = ((rankRule.ranks != null) ? rankRule.ranks.Length : 0);
				SaveFile save = SaveSystem.save;
				if (save != null && save.eventRanks != null && num3 > 0 && save.eventRanks.Count < num3)
				{
					int count = save.eventRanks.Count;
					while (save.eventRanks.Count < num3)
					{
						save.eventRanks.Add(new RankSaveData());
					}
					Log.Info("padded save.eventRanks " + count + " -> " + save.eventRanks.Count + " to match " + num3 + " rank(s)");
				}
				if (save != null)
				{
					Log.Info("rank sources: rankRule=" + num3 + " save.eventRanks=" + ((save.eventRanks == null) ? (-1) : save.eventRanks.Count) + " lte.rankData.ranks=" + ((lte.rankData != null && lte.rankData.ranks != null) ? lte.rankData.ranks.Length : (-1)));
				}
			}
			catch (Exception ex3)
			{
				Log.Warn("rank save padding: " + ex3.Message);
			}
			for (int l = 0; l < rankRule.ranks.Length; l++)
			{
				int num4 = 0;
				string text2 = null;
				Mission[] missions = rankRule.ranks[l].missions;
				foreach (Mission mission3 in missions)
				{
					string text3 = mission3.prizeType.ToString() + "|" + mission3.prizeID;
					if (text3 != text2)
					{
						num4++;
						text2 = text3;
					}
				}
				Log.Info("  rank[" + l + "] '" + rankRule.ranks[l].title + "': " + rankRule.ranks[l].missions.Length + " mission(s) -> " + num4 + " task card(s) (grouped by prizeType+prizeID)");
			}
			Log.Info("missions applied: " + rankRule.ranks.Length + " rank(s), " + num + " mission(s)");
		}
		catch (Exception e)
		{
			Log.Error("ApplyMissions", e);
		}
	}

	private static T ParseEnum<T>(string s, T fallback) where T : struct
	{
		if (string.IsNullOrEmpty(s))
		{
			return fallback;
		}
		if (Enum.TryParse<T>(s, ignoreCase: true, out var result))
		{
			return result;
		}
		return fallback;
	}
}
internal class TapHintRewriter : MonoBehaviour
{
	private readonly List<TMP_Text> _targets = new List<TMP_Text>();

	private string _phrase;

	private string _replacement;

	private float _life = 25f;

	internal static bool IsBusy => UnityEngine.Object.FindObjectOfType<TapHintRewriter>() != null;

	internal static void Install(Pack pack)
	{
		if (string.IsNullOrEmpty(pack.ResourceName) && string.IsNullOrEmpty(pack.TapHint) && string.IsNullOrEmpty(pack.ResourceIcon))
		{
			return;
		}
		try
		{
			GameObject obj = new GameObject("CepackTapHint");
			UnityEngine.Object.DontDestroyOnLoad(obj);
			TapHintRewriter tapHintRewriter = obj.AddComponent<TapHintRewriter>();
			string text = (tapHintRewriter._phrase = (string.IsNullOrEmpty(pack.TapHint) ? LocalizationManager.GetTranslation("w_tap_to_earn") : pack.TapHint));
			string text2 = pack.ResourceName ?? "";
			tapHintRewriter._replacement = "<color=yellow>" + text + "</color> " + text2;
			Log.Info("tap hint rewriter armed: '" + tapHintRewriter._replacement + "'");
		}
		catch (Exception ex)
		{
			Log.Warn("TapHintRewriter.Install: " + ex.Message);
		}
	}

	private void Update()
	{
		_life -= Time.unscaledDeltaTime;
		if (_life <= 0f)
		{
			UnityEngine.Object.Destroy(base.gameObject);
		}
		else
		{
			if (Time.frameCount % 20 != 0)
			{
				return;
			}
			try
			{
				if (_targets.Count == 0)
				{
					Scan();
				}
				foreach (TMP_Text target in _targets)
				{
					if (!(target == null))
					{
						string text = target.text;
						if (!string.IsNullOrEmpty(text) && text.Contains(_phrase) && !text.Contains(_replacement))
						{
							target.text = _replacement;
						}
					}
				}
			}
			catch
			{
			}
		}
	}

	private void Scan()
	{
		_targets.Clear();
		TMP_Text[] array = Resources.FindObjectsOfTypeAll<TMP_Text>();
		foreach (TMP_Text tMP_Text in array)
		{
			if (!(tMP_Text == null) && !string.IsNullOrEmpty(tMP_Text.text) && tMP_Text.text.Contains(_phrase))
			{
				_targets.Add(tMP_Text);
			}
		}
		if (_targets.Count > 0)
		{
			Log.Info("tap hint targets found: " + _targets.Count);
		}
	}
}
internal static class GameJson
{
	internal static GenEventDto ToDto(TreeDefinition t)
	{
		GenEventDto genEventDto = new GenEventDto
		{
			name = t.Name,
			title = t.Title,
			startNode = t.StartNode,
			gridView = t.GridView,
			nodes = new GenNodeDto[t.Nodes.Count]
		};
		for (int i = 0; i < t.Nodes.Count; i++)
		{
			TreeNodeDef treeNodeDef = t.Nodes[i];
			GenNodeDto genNodeDto = new GenNodeDto
			{
				uid = treeNodeDef.Uid,
				title = treeNodeDef.Title,
				description = treeNodeDef.Description,
				type = treeNodeDef.Type,
				cost = new Cry(treeNodeDef.Cost[0], treeNodeDef.Cost[1], treeNodeDef.Cost[2], treeNodeDef.Cost[3], treeNodeDef.Cost[4], treeNodeDef.Cost[5], treeNodeDef.Cost[6], treeNodeDef.Cost[7]),
				production = new Cry(treeNodeDef.Production[0], treeNodeDef.Production[1], treeNodeDef.Production[2], treeNodeDef.Production[3], treeNodeDef.Production[4], treeNodeDef.Production[5], treeNodeDef.Production[6], treeNodeDef.Production[7]),
				position = treeNodeDef.Position,
				requirements = new GenReqDto[treeNodeDef.Requirements.Count],
				effects = new GenEffectDto[treeNodeDef.Effects.Count]
			};
			for (int j = 0; j < treeNodeDef.Requirements.Count; j++)
			{
				Tuple<string, double, string, bool> tuple = treeNodeDef.Requirements[j];
				genNodeDto.requirements[j] = new GenReqDto
				{
					requiredUid = tuple.Item1,
					requiredCount = (int)tuple.Item2,
					lineType = tuple.Item3,
					hidden = tuple.Item4
				};
			}
			for (int k = 0; k < treeNodeDef.Effects.Count; k++)
			{
				Tuple<string, double> tuple2 = treeNodeDef.Effects[k];
				genNodeDto.effects[k] = new GenEffectDto
				{
					targetUid = tuple2.Item1,
					prodBoost = (float)tuple2.Item2
				};
			}
			genEventDto.nodes[i] = genNodeDto;
		}
		return genEventDto;
	}

	private static string CryJson(double[] v)
	{
		Cry cry;
		try
		{
			cry = new Cry(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]);
		}
		catch
		{
			cry = new Cry(v[0]);
		}
		string text = JsonUtility.ToJson(cry);
		if (string.IsNullOrEmpty(text) || text == "{}")
		{
			StringBuilder stringBuilder = new StringBuilder();
			stringBuilder.Append("{\"_a\":").Append(Num(v[0])).Append(",\"backingA\":{\"mantissa\":")
				.Append(Num(v[0]))
				.Append(",\"exponent\":0}")
				.Append(",\"_b\":")
				.Append(Num(v[1]))
				.Append(",\"backingB\":{\"mantissa\":")
				.Append(Num(v[1]))
				.Append(",\"exponent\":0}");
			for (int i = 2; i < 8; i++)
			{
				stringBuilder.Append(",\"").Append((char)(97 + i)).Append("\":")
					.Append(Num(v[i]));
			}
			stringBuilder.Append('}');
			return stringBuilder.ToString();
		}
		return text;
	}

	private static string Num(double d)
	{
		if (double.IsNaN(d) || double.IsInfinity(d))
		{
			return "0";
		}
		return d.ToString("R", CultureInfo.InvariantCulture);
	}

	private static void Str(StringBuilder sb, string s)
	{
		sb.Append('"');
		if (s != null)
		{
			foreach (char c in s)
			{
				switch (c)
				{
				case '"':
					sb.Append("\\\"");
					continue;
				case '\\':
					sb.Append("\\\\");
					continue;
				case '\n':
					sb.Append("\\n");
					continue;
				case '\r':
					sb.Append("\\r");
					continue;
				case '\t':
					sb.Append("\\t");
					continue;
				}
				if (c < ' ')
				{
					StringBuilder stringBuilder = sb.Append("\\u");
					int num = c;
					stringBuilder.Append(num.ToString("x4"));
				}
				else
				{
					sb.Append(c);
				}
			}
		}
		sb.Append('"');
	}

	internal static string RoundTrip(string json, int expected)
	{
		try
		{
			GeneratedEvent generatedEvent = JsonUtility.FromJson<GeneratedEvent>(json);
			if (generatedEvent == null)
			{
				return "FromJson<GeneratedEvent> returned null";
			}
			int num = ((generatedEvent.nodes == null) ? (-1) : generatedEvent.nodes.Length);
			return "FromJson<GeneratedEvent> -> " + num + " node(s), expected " + expected + ((num == expected) ? " : OK" : " : MISMATCH");
		}
		catch (Exception ex)
		{
			return "FromJson<GeneratedEvent> threw: " + ex.GetType().Name + ": " + ex.Message;
		}
	}

	internal static string Build(TreeDefinition t, out string how)
	{
		try
		{
			string text = JsonUtility.ToJson(ToDto(t), prettyPrint: true);
			if (!string.IsNullOrEmpty(text) && text.Length > 16 && text.Contains("\"nodes\""))
			{
				how = "JsonUtility(dto)";
				return text;
			}
		}
		catch (Exception ex)
		{
			Log.Warn("JsonUtility(dto) failed: " + ex.Message);
		}
		how = "manual";
		return BuildManual(t);
	}

	internal static string BuildManual(TreeDefinition t)
	{
		StringBuilder stringBuilder = new StringBuilder();
		stringBuilder.Append("{\"name\":");
		Str(stringBuilder, t.Name);
		stringBuilder.Append(",\"title\":");
		Str(stringBuilder, t.Title);
		stringBuilder.Append(",\"startNode\":");
		Str(stringBuilder, t.StartNode);
		stringBuilder.Append(",\"gridView\":").Append(t.GridView ? "true" : "false");
		stringBuilder.Append(",\"nodes\":[");
		for (int i = 0; i < t.Nodes.Count; i++)
		{
			TreeNodeDef treeNodeDef = t.Nodes[i];
			if (i > 0)
			{
				stringBuilder.Append(',');
			}
			stringBuilder.Append("{\"uid\":");
			Str(stringBuilder, treeNodeDef.Uid);
			stringBuilder.Append(",\"title\":");
			Str(stringBuilder, treeNodeDef.Title);
			stringBuilder.Append(",\"description\":");
			Str(stringBuilder, treeNodeDef.Description);
			stringBuilder.Append(",\"type\":");
			Str(stringBuilder, treeNodeDef.Type);
			stringBuilder.Append(",\"cost\":").Append(CryJson(treeNodeDef.Cost));
			stringBuilder.Append(",\"production\":").Append(CryJson(treeNodeDef.Production));
			stringBuilder.Append(",\"position\":{\"x\":").Append(Num(treeNodeDef.Position.x)).Append(",\"y\":")
				.Append(Num(treeNodeDef.Position.y))
				.Append(",\"z\":")
				.Append(Num(treeNodeDef.Position.z))
				.Append('}');
			stringBuilder.Append(",\"requirements\":[");
			for (int j = 0; j < treeNodeDef.Requirements.Count; j++)
			{
				Tuple<string, double, string, bool> tuple = treeNodeDef.Requirements[j];
				if (j > 0)
				{
					stringBuilder.Append(',');
				}
				stringBuilder.Append("{\"requiredUid\":");
				Str(stringBuilder, tuple.Item1);
				stringBuilder.Append(",\"requiredCount\":").Append(((int)tuple.Item2).ToString(CultureInfo.InvariantCulture));
				stringBuilder.Append(",\"lineType\":");
				Str(stringBuilder, NormalizeLineType(tuple.Item3));
				stringBuilder.Append(",\"hidden\":").Append(tuple.Item4 ? "true" : "false").Append('}');
			}
			stringBuilder.Append("],\"effects\":[");
			for (int k = 0; k < treeNodeDef.Effects.Count; k++)
			{
				Tuple<string, double> tuple2 = treeNodeDef.Effects[k];
				if (k > 0)
				{
					stringBuilder.Append(',');
				}
				stringBuilder.Append("{\"targetUid\":");
				Str(stringBuilder, tuple2.Item1);
				stringBuilder.Append(",\"prodBoost\":").Append(Num(tuple2.Item2)).Append('}');
			}
			stringBuilder.Append("]}");
		}
		stringBuilder.Append("]}");
		return stringBuilder.ToString();
	}

	private static string NormalizeLineType(string lt)
	{
		if (string.IsNullOrEmpty(lt))
		{
			return "NORM";
		}
		switch (lt.Trim().ToUpperInvariant())
		{
		case "0":
		case "NONE":
			return "NONE";
		case "1":
		case "NORM":
		case "NORMAL":
			return "NORM";
		case "2":
		case "THICK":
			return "THICK";
		case "3":
		case "SPECIAL":
			return "SPECIAL";
		default:
			return "NORM";
		}
	}
}

}