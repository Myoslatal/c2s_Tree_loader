P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
t = open(P, encoding="utf-8").read()

# find Host.Update to append the one-shot pin
import re
m = re.search(r"(\tprivate void Update\(\)\n\t\{\n)", t)
assert m, "Host.Update not found"

snippet = ("\t\tPinImportEvent();\n")
t = t[:m.end(1)] + snippet + t[m.end(1):]

# add the method next to Update, inside the same class
anchor = "\tprivate void Update()\n\t{\n"
helper = """\tprivate static bool _pinnedImport;

\t/// <summary>
\t/// Point LteServer.loadedData at the built-in persistent 'import' event as soon as the server
\t/// object exists.
\t///
\t/// EnterEvent() already pinned it, but ONLY on the path that goes through the launcher panel or
\t/// the CUSTOM_EVENT_PACK environment variable. Entering by clicking the exploration banner in the
\t/// game UI does not go through EnterEvent: it asks LteServer for the event, and while loadedData
\t/// is still null (state SERVER_LOADING, which this account never leaves because the event prefab
\t/// is server-delivered and absent) the game sits on "Connecting" forever. Pinning it here removes
\t/// the ordering dependency, so the banner works without having to use the launcher first.
\t/// </summary>
\tprivate static void PinImportEvent()
\t{
\t\tif (_pinnedImport) return;
\t\ttry
\t\t{
\t\t\tLteServer s = Singleton<LteServer>.instance;
\t\t\tif (s == null || s.masterLteData == null) return;
\t\t\tLTEData lte = s.masterLteData.FindLteData("import");
\t\t\tif (lte == null) return;
\t\t\tlte.loadMode = EventMode.PersistentData;
\t\t\tif (s.loadedData == null || s.loadedData.LTE_Name != "import")
\t\t\t{
\t\t\t\ts.loadedData = lte;
\t\t\t\tLog.Info("pinned LteServer.loadedData to the persistent 'import' event (server state was " + LteServer.state.ToString() + "), so the exploration banner can be entered without the launcher");
\t\t\t}
\t\t\t_pinnedImport = true;
\t\t}
\t\tcatch (Exception e)
\t\t{
\t\t\tLog.Error("PinImportEvent", e);
\t\t}
\t}

"""
assert t.count(anchor) == 1, ("anchor", t.count(anchor))
t = t.replace(anchor, helper + anchor)
open(P, "w", encoding="utf-8").write(t)
print("PinImportEvent installed")