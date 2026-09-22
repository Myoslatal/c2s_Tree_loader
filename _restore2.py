import re
dec = open("/tmp/recovered/CustomEventPackPlugin.decompiled.cs", encoding="utf-8-sig").read().split("\n")

def block(name):
    for i, line in enumerate(dec):
        if re.match(r"\s*(internal|public)\s+(sealed\s+)?class\s+" + name + r"\b", line):
            out = []
            for j in range(i, len(dec)):
                out.append(dec[j])
                if dec[j].rstrip() == "}" and len(out) > 1:
                    return out
    return None

src = open("_mod_tools/CustomEventPack/CustomEventPackPlugin.cs", encoding="utf-8").read().split("\n")
idx = next(i for i,l in enumerate(src) if "class BackgroundDef" in l)
add = []
for nm in ["TreeNodeDef", "GenNodeDto", "GenTargetDto", "NodeDefinition"]:
    b = block(nm)
    if b is None: continue
    add += ["    " + l if l.strip() else l for l in b] + [""]
    print("added", nm, len(b), "lines")
src[idx:idx] = add
open("_mod_tools/CustomEventPack/CustomEventPackPlugin.cs","w",encoding="utf-8").write("\n".join(src))
print("file now", len(src), "lines")
