import re
dec = open("/tmp/recovered/CustomEventPackPlugin.decompiled.cs", encoding="utf-8-sig").read().split("\n")

wanted = ["DisableLeaderboard", "MaybeAdvanceStage", "MaybeShowOutro",
          "RetryEventBackground", "DelayedBackdropDump", "ResetOutro"]

def method_block(name):
    # a method declaration line, then brace matching
    for i, line in enumerate(dec):
        if not re.search(r"\b" + name + r"\s*\(", line): continue
        if line.strip().startswith("//"): continue
        j = i
        # find the opening brace
        while j < len(dec) and "{" not in dec[j]:
            j += 1
            if j - i > 12: break
        if j >= len(dec) or "{" not in dec[j]: continue
        out = []; depth = 0; started = False
        for k in range(i, len(dec)):
            out.append(dec[k])
            depth += dec[k].count("{") - dec[k].count("}")
            if "{" in dec[k]: started = True
            if started and depth <= 0:
                return out
    return None

src = open("_mod_tools/CustomEventPack/CustomEventPackPlugin.cs", encoding="utf-8").read().split("\n")
# insert at the end of the PackLoader class: just before 'internal static class EventContent'
idx = next(i for i,l in enumerate(src) if "class EventContent" in l)
# walk back to the closing brace of PackLoader
while idx > 0 and src[idx-1].strip() == "": idx -= 1
if src[idx-1].strip() == "}": idx -= 1
add = []
for nm in wanted:
    b = method_block(nm)
    if b is None:
        print("  !! not found:", nm); continue
    add += ["        // ---- recovered from the working build ----"]
    add += ["    " + l if l.strip() else l for l in b]
    add += [""]
    print("  +", nm, len(b), "lines")
src[idx:idx] = add
open("_mod_tools/CustomEventPack/CustomEventPackPlugin.cs","w",encoding="utf-8").write("\n".join(src))
print("file now", len(src), "lines")
