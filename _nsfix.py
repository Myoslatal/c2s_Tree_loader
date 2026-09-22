P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
t = open(P, encoding="utf-8").read()
n = t.count("SaveFileJSON")
t = t.replace("new SaveFileJSON(", "new Cells.SaveMagic.Impl.SaveFileJSON(")
t = t.replace("JsonUtility.FromJson<SaveFileJSON>(", "JsonUtility.FromJson<Cells.SaveMagic.Impl.SaveFileJSON>(")
open(P, "w", encoding="utf-8").write(t)
print("qualified", n, "references")