import shutil, sys, time
D = ("/mis/SteamLibrary/steamapps/compatdata/977400/pfx/drive_c/users/steamuser"
     "/AppData/LocalLow/Computer Lunch/Cell to Singularity")
P = D + "/savedGames2.gd"
DAYS = 14
SECONDS = DAYS * 86400           # 1209600
NEW = str(SECONDS)              # "1209600"

raw = open(P, "rb").read()
orig = bytes(raw)

def fix(buf, key, newval):
    """Point the string value that follows <key> at newval, fixing its length prefix."""
    changed = []
    pos = 0
    while True:
        i = buf.find(key.encode(), pos)
        if i < 0:
            break
        j = i + len(key)
        hit = None
        # the value is a length-prefixed ASCII number a few bytes after the key name
        for k in range(j, min(j + 20, len(buf))):
            n = buf[k]
            if not (0 < n < 0x80):
                continue
            seg = buf[k + 1:k + 1 + n]
            if len(seg) == n and seg and all(48 <= c <= 57 or c == 46 for c in seg):
                hit = (k, n, seg.decode())
                break
        if hit is None:
            pos = j
            continue
        k, n, old = hit
        new = newval.encode()
        buf = buf[:k] + bytes([len(new)]) + new + buf[k + 1 + n:]
        changed.append((key, old, newval))
        pos = k + 1 + len(new)
    return buf, changed

all_changes = []
for key in ("totalTimeCurSim", "offlineTimeCurSim"):
    raw, ch = fix(raw, key, NEW)
    all_changes += ch

if not all_changes:
    print("NOTHING CHANGED - aborting")
    sys.exit(1)

stamp = time.strftime("%Y%m%d_%H%M%S")
backup = D + "/savedGames2.gd.bak_" + stamp
shutil.copyfile(P, backup)
open(P, "wb").write(raw)

print("backup : " + backup)
print("save   : " + P + "  (%d -> %d bytes)" % (len(orig), len(raw)))
for key, old, new in all_changes:
    print("  %-20s %s -> %s  (%.2f days -> %.2f days)" % (key, old, new,
          float(old) / 86400, float(new) / 86400))