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
    raise SystemExit("not found: " + name)

tree = block("TreeDefinition")
gen  = block("GenEventDto")
print("TreeDefinition:", len(tree), "lines")
print("GenEventDto:", len(gen), "lines")

src = open("_mod_tools/CustomEventPack/CustomEventPackPlugin.cs", encoding="utf-8").read().split("\n")
# insert right before the first 'internal class BackgroundDef' so the model types stay together
idx = next(i for i,l in enumerate(src) if "class BackgroundDef" in l)
add = ["    // ---- recovered from the working build after an editing accident ----"] + \
      ["    " + l if l.strip() else l for l in tree] + [""] + \
      ["    " + l if l.strip() else l for l in gen] + [""]
src[idx:idx] = add
open("_mod_tools/CustomEventPack/CustomEventPackPlugin.cs","w",encoding="utf-8").write("\n".join(src))
print("inserted at line", idx+1, "file now", len(src), "lines")
