import re
P = ("/mis/SteamLibrary/steamapps/compatdata/977400/pfx/drive_c/users/steamuser"
     "/AppData/LocalLow/Computer Lunch/Cell to Singularity/savedGames2.gd")
raw = open(P, "rb").read()
# .NET binary serialization stores strings as: 0x06 <7-bit length> <bytes>
keys = []
i = 0
while i < len(raw) - 1:
    if raw[i] == 0x06:
        n = raw[i + 1]
        if 0 < n < 0x80 and i + 2 + n <= len(raw):
            try:
                s = raw[i + 2:i + 2 + n].decode("ascii")
                if s.isprintable() and len(s) > 1:
                    keys.append(s)
                    i += 2 + n
                    continue
            except UnicodeDecodeError:
                pass
    i += 1
seen = []
for k in keys:
    if k not in seen:
        seen.append(k)
time_like = [k for k in seen if re.search(r"time|capsule|offline|bonus|boost|multipl", k, re.I)]
print("=== 时间/加成相关字段 ===")
for k in time_like:
    print(" ", k)
print()
print("=== 这些字段的值 ===")
for k in time_like:
    m = re.search(re.escape(k.encode()).decode() + "", "")
for k in time_like:
    idx = raw.find(k.encode())
    if idx >= 0:
        after = raw[idx + len(k):idx + len(k) + 24]
        nxt = after[0] if after else 0
        val = after[1:1 + nxt] if nxt < 0x80 else b""
        try: print(f"  {k} = {val.decode('ascii')}")
        except Exception: print(f"  {k} = ?")