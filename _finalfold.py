P = "_mod_tools/launch_modded.sh"
t = open(P, encoding="utf-8").read()
start = t.index("# ---- 1b. DISABLED: merging the plugin into Assembly-CSharp ----")
end = t.index('  echo "[launcher] WARNING: $PLUGIN or ILRepack missing - plugin NOT embedded"\nfi') + len('  echo "[launcher] WARNING: $PLUGIN or ILRepack missing - plugin NOT embedded"\nfi')
block = """# ---- 1b. fold the plugin INTO the patched assembly ----
# The mod ships as ONE dll. ilfold appends the CustomEventPack types to the module that is already
# there instead of rebuilding it, because ILRepack cannot round-trip this Assembly-CSharp at all:
# re-importing AscendReset/<TriggerAscensionRebootCR>d__31 makes its importer throw. See the
# header comment in _mod_tools/ilfold/Program.cs.
#
# Two consequences worth knowing:
#   * ScriptingAssemblies.json must NOT list CustomEventPackPlugin any more, or Unity would load
#     the standalone assembly as well and end up with two copies of every type
#   * RuntimeInitializeOnLoads.json points the Bootstrap entry at Assembly-CSharp; that lookup
#     does not actually fire, so the plugin bootstraps from the UnlockFramerate patch hook instead
FOLDER="$DATA/_mod_tools/ilfold/bin/Release/net10.0/ilfold"
if [ -f "$PLUGIN" ] && [ -x "$FOLDER" ]; then
  "$FOLDER" "$LIVE" "$PLUGIN" "$LIVE.folded" "$M" >/dev/null || {
    echo "[launcher] FOLD FAILED"; exit 1; }
  mv -f "$LIVE.folded" "$LIVE"
  echo "[launcher] folded the plugin into Assembly-CSharp"
else
  echo "[launcher] WARNING: $PLUGIN or ilfold missing - plugin NOT embedded"
fi"""
t = t[:start] + block + t[end:]
open(P, "w", encoding="utf-8").write(t)
print("launcher now folds the plugin")