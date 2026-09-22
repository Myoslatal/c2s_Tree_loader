import re, io
dec = open("/tmp/recovered/CustomEventPackPlugin.decompiled.cs", encoding="utf-8-sig").read().split("\n")

def extract(start_idx):
    # start_idx: 0-based index of the line declaring the class
    depth = 0; started = False; out = []
    for i in range(start_idx, len(dec)):
        line = dec[i]
        out.append(line)
        depth += line.count("{") - line.count("}")
        if "{" in line: started = True
        if started and depth <= 0:
            return out
    return out

names = ["TreeDefinition", "GenEventDto", "NodeDefinition", "TargetDefinition", "BackgroundDef", "CurrencyDef"]
chunks = []
seen = set()
for i, line in enumerate(dec):
    m = re.match(r"\s*(internal|public)?\s*(sealed\s+)?class\s+(\w+)", line)
    if m and m.group(3) in names and m.group(3) not in seen:
        seen.add(m.group(3))
        chunks.append("\n".join(extract(i)))
        print("extracted", m.group(3), "from line", i+1)
for c in chunks:
    print("---")
    print(c.split(chr(10))[0])
print("TOTAL CHARS", sum(len(c) for c in chunks))
open("/tmp/recovered_extract.cs","w",encoding="utf-8").write("\n\n".join(chunks))
