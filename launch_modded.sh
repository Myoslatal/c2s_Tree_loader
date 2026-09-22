#!/usr/bin/env bash
# launch_modded.sh - rebuild Assembly-CSharp.dll from the PRISTINE OFFICIAL backup with all
# patches from _mod_tools/patches.txt applied, launch the game, then restore.
#
# SAFETY RULES (learned the hard way - an earlier version of this script copied the official
# backup over the user's hand-modded dll and destroyed it):
#   1. NEVER write to Managed/Assembly-CSharp.dll without first snapshotting it to
#      _mod_tools/dll_backups/Assembly-CSharp.<timestamp>.dll
#   2. The patch BASE is always Assembly-CSharp.dll.bak (the official original), never the
#      live file, so patches are reproducible and never stack on each other.
#   3. Restore runs from a trap, so Ctrl-C / kill / crash still restores.
set +e
DATA="/mis/SteamLibrary/steamapps/common/Cell to Singularity/CellToSingularity_Data"
M="$DATA/Managed"
LIVE="$M/Assembly-CSharp.dll"
BASE="$M/Assembly-CSharp.dll.bak"
PLUGIN="$M/CustomEventPackPlugin.dll"
FONT_PLUGIN="$M/FontReplacerPlugin.dll"
PATCHER="$DATA/_mod_tools/patcher/bin/Release/net10.0/patcher"
SPEC="$DATA/_mod_tools/patches.txt"
BACKUPS="$DATA/_mod_tools/dll_backups"

[ -f "$BASE" ]    || { echo "[launcher] missing official backup: $BASE"; exit 1; }
[ -f "$PLUGIN" ]  || { echo "[launcher] missing plugin: $PLUGIN"; exit 1; }
[ -x "$PATCHER" ] || { echo "[launcher] missing patcher (build _mod_tools/patcher)"; exit 1; }
[ -f "$SPEC" ]    || { echo "[launcher] missing patch spec: $SPEC"; exit 1; }

# ---- 0. always snapshot whatever is live right now ----
mkdir -p "$BACKUPS"
STAMP=$(date +%Y%m%d-%H%M%S)
if [ -f "$LIVE" ]; then
  cp -f "$LIVE" "$BACKUPS/Assembly-CSharp.$STAMP.dll"
  echo "[launcher] snapshotted live dll -> dll_backups/Assembly-CSharp.$STAMP.dll"
fi

RESTORED=0
restore() {
  [ "$RESTORED" = 1 ] && return
  RESTORED=1
  cp -f "$BACKUPS/Assembly-CSharp.$STAMP.dll" "$LIVE"
  echo "[launcher] restored the pre-launch dll"
}
trap restore EXIT INT TERM

# ---- 1. rebuild from the official base + patch ----
cp -f "$BASE" "$LIVE"
( cd "$M" && HOME=/home/forin "$PATCHER" "$BASE" "$LIVE" "$SPEC" "$M" ) || {
  echo "[launcher] PATCH FAILED - restoring"; exit 1; }

# ---- 1b. fold the plugin INTO the patched assembly ----
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
  # Fold the pack plugin first, then FontReplacer: the pack UI builds its text with
  # TMP_Settings.defaultFontAsset, and FontReplacer is what gives that font CJK glyphs.
  "$FOLDER" "$LIVE" "$PLUGIN" "$LIVE.fold1" "$M" >/dev/null || {
    echo "[launcher] FOLD FAILED (pack plugin)"; exit 1; }
  if [ -f "$FONT_PLUGIN" ]; then
    "$FOLDER" "$LIVE.fold1" "$FONT_PLUGIN" "$LIVE.fold2" "$M" >/dev/null || {
      echo "[launcher] FOLD FAILED (FontReplacer)"; exit 1; }
    mv -f "$LIVE.fold2" "$LIVE"
    rm -f "$LIVE.fold1"
    echo "[launcher] folded the pack plugin AND FontReplacer into Assembly-CSharp"
  else
    mv -f "$LIVE.fold1" "$LIVE"
    echo "[launcher] WARNING: $FONT_PLUGIN missing - CJK text may not render"
  fi
else
  echo "[launcher] WARNING: $PLUGIN or ilfold missing - plugin NOT embedded"
fi

# ---- 2. launch ----
C="/mis/SteamLibrary/steamapps/compatdata/977400"
GAME="/mis/SteamLibrary/steamapps/common/Cell to Singularity"
export STEAM_COMPAT_DATA_PATH="$C"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam"
export SteamAppId=977400 SteamGameId=977400

case "${1:-dwproton}" in
  steam) echo "[launcher] launching via Steam"; setsid steam -applaunch 977400 & ;;
  *)     echo "[launcher] launching via dwproton"
         cd "$GAME" && setsid /usr/bin/dwproton run "CellToSingularity.exe" \
           -screen-fullscreen 0 -screen-width 1280 -screen-height 720 & ;;
esac
PID=$!
echo "[launcher] patch is ACTIVE while the game runs. Close the game to restore."
wait $PID
echo "[launcher] game exited"
