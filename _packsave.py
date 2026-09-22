P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
t = open(P, encoding="utf-8").read()

helper = """\t// ------------------------------------------------------------------ per-pack save
\t// The game keeps ONE event save (SaveFile.eventItems / SaveFile.eventRanks) and every
\t// event shares it, so two custom packs overwrote each other\'s progress. The live save is
\t// serialised with the game\'s own SaveFileJSON and filed per pack id, then restored when
\t// that pack is entered again. Only the two EVENT fields are copied back - restoring the
\t// whole SaveFile would roll back main-simulation progress too.
\tprivate static string _savePackId;

\tinternal static string SaveDir
\t{
\t\tget { return System.IO.Path.Combine(Application.persistentDataPath, "CustomEventSaves"); }
\t}

\tprivate static string SavePath(string packId)
\t{
\t\tSystem.Text.StringBuilder sb = new System.Text.StringBuilder();
\t\tforeach (char c in packId)
\t\t{
\t\t\tsb.Append((char.IsLetterOrDigit(c) || c == \'_\' || c == \'-\') ? c : \'_\');
\t\t}
\t\treturn System.IO.Path.Combine(SaveDir, sb.ToString() + ".json");
\t}

\tinternal static void SwitchPackSave(Pack pack)
\t{
\t\tstring want = ((pack == null || string.IsNullOrEmpty(pack.Id)) ? "default" : pack.Id);
\t\tif (_savePackId == null)
\t\t{
\t\t\t// first pack entry this session: the save currently in memory belongs to whichever
\t\t\t// pack was last played, so remember that instead of assuming it is already ours.
\t\t\t_savePackId = PlayerPrefs.GetString("cepack_active_save", "");
\t\t}
\t\tif (want == _savePackId) return;
\t\ttry
\t\t{
\t\t\tif (!string.IsNullOrEmpty(_savePackId))
\t\t\t{
\t\t\t\tSystem.IO.Directory.CreateDirectory(SaveDir);
\t\t\t\tstring blob = JsonUtility.ToJson(new SaveFileJSON(SaveSystem.save));
\t\t\t\tSystem.IO.File.WriteAllText(SavePath(_savePackId), blob, System.Text.Encoding.UTF8);
\t\t\t\tLog.Info("SAVE: stashed pack \'" + _savePackId + "\' (" + blob.Length + " chars)");
\t\t\t}
\t\t\t_savePackId = want;
\t\t\tPlayerPrefs.SetString("cepack_active_save", want);
\t\t\tstring path = SavePath(want);
\t\t\tif (System.IO.File.Exists(path))
\t\t\t{
\t\t\t\tSaveFileJSON json = JsonUtility.FromJson<SaveFileJSON>(System.IO.File.ReadAllText(path, System.Text.Encoding.UTF8));
\t\t\t\tSaveFile tmp = ((json == null) ? null : json.ToSaveFile());
\t\t\t\tif (tmp != null)
\t\t\t\t{
\t\t\t\t\tSaveSystem.save.eventItems = tmp.eventItems;
\t\t\t\t\tSaveSystem.save.eventRanks = tmp.eventRanks;
\t\t\t\t\tLog.Info("SAVE: restored pack \'" + want + "\' (eventItems=" + tmp.eventItems.Count + ", eventRanks=" + tmp.eventRanks.Count + ")");
\t\t\t\t}
\t\t\t}
\t\t\telse
\t\t\t{
\t\t\t\t// a pack nobody has played yet must NOT inherit the previous pack\'s run
\t\t\t\tSaveSystem.save.eventItems.Clear();
\t\t\t\tSaveSystem.save.eventRanks.Clear();
\t\t\t\tLog.Info("SAVE: pack \'" + want + "\' is new; its event save starts empty");
\t\t\t}
\t\t}
\t\tcatch (Exception e) { Log.Error("SwitchPackSave(" + want + ")", e); }
\t}

\tinternal static void MaybeShowOutro()"""

anchor = "\tinternal static void MaybeShowOutro()"
assert t.count(anchor) == 1, t.count(anchor)
t = t.replace(anchor, helper)

# hook it in just before the event is entered
old = """\t\t\tLastLoaded = pack;
\t\t\tCustomEventActive = true;
\t\t\tResetOutro();
\t\t\tEnterEvent(lTEData);"""
new = """\t\t\tLastLoaded = pack;
\t\t\tCustomEventActive = true;
\t\t\tResetOutro();
\t\t\tSwitchPackSave(pack);
\t\t\tEnterEvent(lTEData);"""
assert t.count(old) == 1, ("hook", t.count(old))
t = t.replace(old, new)
open(P, "w", encoding="utf-8").write(t)
print("per-pack save added")