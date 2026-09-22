import json
d = json.load(open("CustomEvents/SamplePack/tree.json", encoding="utf-8"))
for n in d["nodes"]:
    p = n.get("position", {})
    print("%-16s x=%7.2f y=%7.2f" % (n["uid"], p.get("x", 0), p.get("y", 0)))
