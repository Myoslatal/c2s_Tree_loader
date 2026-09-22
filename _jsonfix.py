import json, io
# RuntimeInitializeOnLoads: the bootstrap now lives INSIDE Assembly-CSharp
p = "RuntimeInitializeOnLoads.json"
t = open(p, encoding="utf-8").read()
n = t.count('"assemblyName":"CustomEventPackPlugin"')
t = t.replace('"assemblyName":"CustomEventPackPlugin"', '"assemblyName":"Assembly-CSharp"')
open(p, "w", encoding="utf-8").write(t)
print("RuntimeInitializeOnLoads: rewrote", n, "entry/entries to Assembly-CSharp")

# ScriptingAssemblies: drop the now-merged plugin assembly
q = "ScriptingAssemblies.json"
s = open(q, encoding="utf-8").read()
before = s.count("CustomEventPackPlugin.dll")
s = s.replace(',"CustomEventPackPlugin.dll"', "").replace('"CustomEventPackPlugin.dll",', "")
open(q, "w", encoding="utf-8").write(s)
print("ScriptingAssemblies: removed", before, "reference(s); remaining:", s.count("CustomEventPackPlugin.dll"))