import re
P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
src = open(P, encoding="utf-8").read().split("\n")

# 1) remove the bad insertion (the call-site fragment + its comment)
start = next(i for i,l in enumerate(src) if "recovered from the working build" in l and "----" in l)
end = start
while end < len(src) and "internal void Rescan()" not in src[end]:
    end += 1
# step back over the blank line / closing braces that belonged to the original file
print("removing lines", start+1, "..", end)
src = src[:start] + src[end:]

# 2) extract the REAL declarations from the decompiled source (members are at exactly one tab)
dec = open("/tmp/recovered/CustomEventPackPlugin.decompiled.cs", encoding="utf-8-sig").read().split("\n")
wanted = ["DisableLeaderboard", "MaybeAdvanceStage", "MaybeShowOutro",
          "RetryEventBackground", "DelayedBackdropDump", "ResetOutro"]

def decl_block(name):
    for i, line in enumerate(dec):
        if not re.match(r"\t(internal|public|private|protected)\b.*\b" + name + r"\s*\(", line):
            continue
        if line.rstrip().endswith(";"): continue          # abstract / extern
        out = []; depth = 0; started = False
        for k in range(i, len(dec)):
            out.append(dec[k])
            depth += dec[k].count("{") - dec[k].count("}")
            if "{" in dec[k]: started = True
            if started and depth <= 0: return out
    return None

# append inside PackLoader: just before 'internal static class EventContent'
idx = next(i for i,l in enumerate(src) if "class EventContent" in l)
while idx > 0 and src[idx-1].strip() == "": idx -= 1
add = []
for nm in wanted:
    b = decl_block(nm)
    if b is None:
        print("  !! still not found:", nm); continue
    add += ["        // ---- recovered from the working build ----"]
    add += ["    " + l if l.strip() else l for l in b]
    add += [""]
    print("  +", nm, len(b), "lines")
src[idx:idx] = add
open(P, "w", encoding="utf-8").write("\n".join(src))
print("file now", len(src), "lines")
