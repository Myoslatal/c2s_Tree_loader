import json
# Both plugins are folded into Assembly-CSharp now and bootstrap from the UnlockFramerate patch
# hook, so neither needs a registration entry. Leaving them would make Unity load the standalone
# assemblies as well and end up with two copies of every type.
p = "RuntimeInitializeOnLoads.json"
raw = open(p, encoding="utf-8").read()
doc = json.loads(raw)
before = len(doc["root"])
doc["root"] = [e for e in doc["root"]
               if e.get("assemblyName") not in ("CustomEventPackPlugin", "FontReplacerPlugin")]
open(p, "w", encoding="utf-8").write(json.dumps(doc, separators=(",", ":")))
print("RuntimeInitializeOnLoads:", before, "->", len(doc["root"]), "entries")

q = "ScriptingAssemblies.json"
doc2 = json.loads(open(q, encoding="utf-8").read())
names = doc2["names"] if isinstance(doc2, dict) and "names" in doc2 else doc2
n0 = len(names)
names[:] = [n for n in names if n not in ("CustomEventPackPlugin.dll", "FontReplacerPlugin.dll")]
open(q, "w", encoding="utf-8").write(json.dumps(doc2, separators=(",", ":")))
print("ScriptingAssemblies:", n0, "->", len(names), "entries")