import re
dec = open("/tmp/recovered/CustomEventPackPlugin.decompiled.cs", encoding="utf-8-sig").read().split("\n")
srctxt = open("_mod_tools/CustomEventPack/CustomEventPackPlugin.cs", encoding="utf-8").read()

def block_at(i):
    out = []
    for j in range(i, len(dec)):
        out.append(dec[j])
        if dec[j].rstrip() == "}" and len(out) > 1:
            return out
    return out

missing = []
for i, line in enumerate(dec):
    m = re.match(r"\s*(internal|public)\s+(static\s+)?(sealed\s+)?(class|enum|struct)\s+(\w+)", line)
    if not m: continue
    name = m.group(5)
    if re.search(r"\b(class|enum|struct)\s+" + name + r"\b", srctxt): continue
    missing.append((name, i))

print("missing:", [n for n,_ in missing])
src = srctxt.split("\n")
idx = next(i for i,l in enumerate(src) if "class BackgroundDef" in l)
add = ["    // ---- types recovered from the working build after an editing accident ----"]
for name, i in missing:
    b = block_at(i)
    add += ["    " + l if l.strip() else l for l in b] + [""]
    print("  +", name, len(b), "lines")
src[idx:idx] = add
open("_mod_tools/CustomEventPack/CustomEventPackPlugin.cs","w",encoding="utf-8").write("\n".join(src))
print("file now", len(src), "lines")
