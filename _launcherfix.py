P = "_mod_tools/launch_modded.sh"
t = open(P, encoding="utf-8").read()
old = """( cd "$M" && HOME=/home/forin "$PATCHER" "$BASE" "$LIVE" "$SPEC" "$M" ) || {
  echo "[launcher] PATCH FAILED - restoring"; exit 1; }"""
new = old + """

# ---- 1b. merge the plugin INTO the patched assembly ----
# The mod now ships as ONE dll: the CustomEventPack types are merged into Assembly-CSharp,
# so ScriptingAssemblies.json no longer needs a plugin entry and RuntimeInitializeOnLoads
# points the Bootstrap entry at Assembly-CSharp.
ILR="$HOME/.nuget/packages/ilrepack/2.0.44/tools/ILRepack.exe"
if [ -f "$PLUGIN" ] && [ -f "$ILR" ]; then
  ( cd "$M" && HOME=/home/forin dotnet "$ILR" /out:"$LIVE.merged" /lib:. "$LIVE" "$PLUGIN" ) >/dev/null || {
    echo "[launcher] MERGE FAILED"; exit 1; }
  mv -f "$LIVE.merged" "$LIVE"
  echo "[launcher] merged the plugin into Assembly-CSharp"
else
  echo "[launcher] WARNING: $PLUGIN or ILRepack missing - plugin NOT embedded"
fi"""
assert t.count(old) == 1, t.count(old)
t = t.replace(old, new)
open(P, "w", encoding="utf-8").write(t)
print("launcher now merges the plugin")