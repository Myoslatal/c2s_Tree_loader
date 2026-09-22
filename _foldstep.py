P = "_mod_tools/launch_modded.sh"
lines = open(P, encoding="utf-8").read().split("\n")
# the disabled ILRepack block occupies 1-based lines 49..68
assert lines[48].startswith("# ---- 1b. DISABLED"), lines[48]
assert lines[67].strip() == "# fi", repr(lines[67])
block = """# ---- 1b. fold the plugin INTO the patched assembly ----
# The mod ships as ONE dll. ilfold APPENDS the CustomEventPack types to the module that is
# already there instead of rebuilding it, because ILRepack cannot round-trip this
# Assembly-CSharp at all: re-importing AscendReset/<TriggerAscensionRebootCR>d__31 makes its
# importer throw, even when ILRepack is handed Assembly-CSharp with no plugin at all.
# See the header comment in _mod_tools/ilfold/Program.cs.
#
# Two things to know:
#   * ScriptingAssemblies.json must NOT list CustomEventPackPlugin any more, or Unity would load
#     the standalone assembly too and end up with two copies of every type
#   * RuntimeInitializeOnLoads.json points the Bootstrap entry at Assembly-CSharp, but that
#     lookup does not actually fire, so the plugin bootstraps from the UnlockFramerate patch
#     hook instead (see PatchHooks.UnlockFramerate in the plugin source)
FOLDER="$DATA/_mod_tools/ilfold/bin/Release/net10.0/ilfold"
if [ -f "$PLUGIN" ] && [ -x "$FOLDER" ]; then
  "$FOLDER" "$LIVE" "$PLUGIN" "$LIVE.folded" "$M" >/dev/null || {
    echo "[launcher] FOLD FAILED"; exit 1; }
  mv -f "$LIVE.folded" "$LIVE"
  echo "[launcher] folded the plugin into Assembly-CSharp"
else
  echo "[launcher] WARNING: $PLUGIN or ilfold missing - plugin NOT embedded"
fi""".split("\n")
out = lines[:48] + block + lines[68:]
open(P, "w", encoding="utf-8").write("\n".join(out))
print("replaced", 68 - 48, "lines with the fold step")