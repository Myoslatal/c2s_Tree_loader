P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
t = open(P, encoding="utf-8").read()
lines = t.split("\n")
# line 106 (1-based) is the Update I added -> rename it
assert lines[105].strip() == "private void Update()", lines[105]
lines[105] = lines[105].replace("private void Update()", "internal void NanoStatsProbe()")
# line 245 is the real Host.Update -> call the probe from it
assert lines[244].strip() == "private void Update()", lines[244]
assert lines[245].strip() == "{", lines[245]
lines.insert(246, "\t\tNanoStatsProbe();")
open(P, "w", encoding="utf-8").write("\n".join(lines))
print("renamed + wired")