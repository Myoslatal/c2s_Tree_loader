T = chr(9)
P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
t = open(P, encoding="utf-8").read()
assert "PinImportEvent" not in t, "already present"

anchor = T + "private void Update()" + chr(10) + T + "{" + chr(10)
i = t.find(anchor)
assert i >= 0, "Host.Update not found"
body = i + len(anchor)

helper = chr(10).join([
  T + "private static bool _pinnedImport;",
  "",
  T + "/// <summary>",
  T + "/// Point LteServer.loadedData at the built-in persistent 'import' event as soon as the server",
  T + "/// object exists.",
  T + "///",
  T + "/// EnterEvent() already pinned it, but ONLY on the path through the launcher panel or the",
  T + "/// CUSTOM_EVENT_PACK environment variable. Entering by clicking the exploration banner in the",
  T + "/// game UI never goes through EnterEvent: it asks LteServer for the event, and while loadedData",
  T + "/// is still null - state SERVER_LOADING, which this account never leaves because the event",
  T + "/// prefab is server-delivered and absent - the game sits on Connecting forever. Pinning it",
  T + "/// here removes that ordering dependency.",
  T + "/// </summary>",
  T + "private static void PinImportEvent()",
  T + "{",
  T + T + "if (_pinnedImport) return;",
  T + T + "try",
  T + T + "{",
  T + T + T + "LteServer s = Singleton<LteServer>.instance;",
  T + T + T + "if (s == null || s.masterLteData == null) return;",
  T + T + T + "LTEData lte = s.masterLteData.FindLteData('import');",
  T + T + T + "if (lte == null) return;",
  T + T + T + "lte.loadMode = EventMode.PersistentData;",
  T + T + T + "if (s.loadedData == null || s.loadedData.LTE_Name != 'import')",
  T + T + T + "{",
  T + T + T + T + "s.loadedData = lte;",
  T + T + T + T + "Log.Info('pinned LteServer.loadedData to the persistent import event (server state was ' + LteServer.state.ToString() + '), so the exploration banner can be entered without the launcher');",
  T + T + T + "}",
  T + T + T + "_pinnedImport = true;",
  T + T + "}",
  T + T + "catch (Exception e)",
  T + T + "{",
  T + T + T + "Log.Error('PinImportEvent', e);",
  T + T + "}",
  T + "}",
  "",
])

t = t[:i] + helper + t[i:]
body += len(helper)
t = t[:body] + T + T + "PinImportEvent();" + chr(10) + t[body:]
open(P, "w", encoding="utf-8").write(t)
print("PinImportEvent installed; occurrences =", t.count("PinImportEvent"))