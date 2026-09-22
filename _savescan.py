import re
P = ("/mis/SteamLibrary/steamapps/compatdata/977400/pfx/drive_c/users/steamuser"
     "/AppData/LocalLow/Computer Lunch/Cell to Singularity/savedGames2.gd")
raw = open(P, "rb").read()
strs = re.findall(rb"[ -~]{3,40}", raw)
seen = []
for s in strs:
    t = s.decode("ascii")
    if t not in seen:
        seen.append(t)
pat = re.compile(r"time|capsule|offline|bonus|boost|multipl|day|speed|warp", re.I)
hits = [k for k in seen if pat.search(k)]
print("=== 时间/加成相关 (%d 个) ===" % len(hits))
for k in hits:
    print("  " + k)