import json
# put FontReplacer back the way it was: a separate, registered plugin. Its own Install() is the
# supported arrangement and folding it in breaks the CustomEventPack state machines.
p = "RuntimeInitializeOnLoads.json"
doc = json.loads(open(p, encoding="utf-8").read())
tpl = {"assemblyName": "FontReplacerPlugin", "nameSpace": "FontReplacerPlugin",
       "className": "FontReplacerBootstrap", "methodName": "Install", "isUnityClass": False}
for lt in (0, 1):
    e = dict(tpl); e["loadTypes"] = lt
    if not any(x.get("assemblyName") == "FontReplacerPlugin" and x.get("loadTypes") == lt
               for x in doc["root"]):
        doc["root"].append(e)
open(p, "w", encoding="utf-8").write(json.dumps(doc, separators=(",", ":")))
print("RuntimeInitializeOnLoads entries:", len(doc["root"]))

q = "ScriptingAssemblies.json"
doc2 = json.loads(open(q, encoding="utf-8").read())
names = doc2["names"] if isinstance(doc2, dict) and "names" in doc2 else doc2
if "FontReplacerPlugin.dll" not in names:
    names.append("FontReplacerPlugin.dll")
open(q, "w", encoding="utf-8").write(json.dumps(doc2, separators=(",", ":")))
print("ScriptingAssemblies entries:", len(names))