#!/usr/bin/env python3
"""Install / uninstall the CustomEventPack managed plugin.

Registers Managed/CustomEventPackPlugin.dll in ScriptingAssemblies.json and adds
RuntimeInitializeOnLoads.json entries so Unity calls CustomEventPack.Bootstrap.Install()
at startup. Assembly-CSharp.dll is never touched.
"""
import json, os, shutil, sys, pathlib

DATA = pathlib.Path(__file__).resolve().parent.parent
PLUGIN = "CustomEventPackPlugin.dll"
ASSEMBLY = "CustomEventPackPlugin"
NAMESPACE = "CustomEventPack"
CLASS = "Bootstrap"
METHOD = "Install"
# 0 = AfterSceneLoad, 1 = BeforeSceneLoad (Install is idempotent)
LOAD_TYPES = [0, 1]
BAK = ".cepack.bak"


def load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, separators=(",", ":"))


def install():
    sa_path = DATA / "ScriptingAssemblies.json"
    ri_path = DATA / "RuntimeInitializeOnLoads.json"
    dll = DATA / "Managed" / PLUGIN
    if not dll.exists():
        print("!! missing", dll, "- run build_customeventpack.sh first")
        return 1

    for p in (sa_path, ri_path):
        bak = pathlib.Path(str(p) + BAK)
        if not bak.exists():
            shutil.copy2(p, bak)
            print("backup ->", bak.name)

    sa = load(sa_path)
    if PLUGIN not in sa["names"]:
        sa["names"].append(PLUGIN)
        save(sa_path, sa)
        print("ScriptingAssemblies: added", PLUGIN)
    else:
        print("ScriptingAssemblies: already present")

    ri = load(ri_path)
    root = ri["root"]
    existing = {(e.get("assemblyName"), e.get("nameSpace"), e.get("className"),
                 e.get("methodName"), e.get("loadTypes")) for e in root}
    added = 0
    for lt in LOAD_TYPES:
        key = (ASSEMBLY, NAMESPACE, CLASS, METHOD, lt)
        if key in existing:
            continue
        root.append({"assemblyName": ASSEMBLY, "nameSpace": NAMESPACE,
                     "className": CLASS, "methodName": METHOD,
                     "loadTypes": lt, "isUnityClass": False})
        added += 1
    if added:
        save(ri_path, ri)
    print("RuntimeInitializeOnLoads: added %d entr(ies), total %d" % (added, len(root)))

    packs = DATA / "CustomEvents"
    packs.mkdir(exist_ok=True)
    print("pack root:", packs)
    return 0


def uninstall():
    sa_path = DATA / "ScriptingAssemblies.json"
    ri_path = DATA / "RuntimeInitializeOnLoads.json"
    sa = load(sa_path)
    if PLUGIN in sa["names"]:
        sa["names"].remove(PLUGIN)
        save(sa_path, sa)
        print("ScriptingAssemblies: removed", PLUGIN)
    ri = load(ri_path)
    before = len(ri["root"])
    ri["root"] = [e for e in ri["root"] if e.get("assemblyName") != ASSEMBLY]
    if len(ri["root"]) != before:
        save(ri_path, ri)
    print("RuntimeInitializeOnLoads: removed %d entry(ies)" % (before - len(ri["root"])))
    dll = DATA / "Managed" / PLUGIN
    if dll.exists():
        dll.unlink()
        print("deleted", dll.name)
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "install"
    sys.exit(install() if cmd == "install" else uninstall())
