import re
P = ("/mis/SteamLibrary/steamapps/compatdata/977400/pfx/drive_c/users/steamuser"
     "/AppData/LocalLow/Computer Lunch/Cell to Singularity/savedGames2.gd")
raw = open(P, encoding="utf-8", errors="replace").read()
print("size", len(raw))
print("head:", raw[:160].replace(chr(10), " | "))
for key in ("totalTimeCurSim", "offlineTimeCurSim", "totalTimePlayed", "offlineTime"):
    for m in re.finditer(re.escape(key), raw):
        s = max(0, m.start() - 30)
        print(key, "->", repr(raw[s:m.start() + len(key) + 60]))
        break