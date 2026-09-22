#!/usr/bin/env bash
# Launch the game with dwproton (standalone Proton launcher) while keeping the
# existing Steam prefix, so the pack loader can be verified end to end.
#
# Cleanup note: dwproton spawns its own wine services (services.exe, plugplay.exe,
# explorer.exe /desktop, tabtip.exe, xalia.exe). If they are left behind they keep
# creating windows and fight any session Steam launched against the same prefix, so
# every run cleans them up by matching the *real exe path* - never the command line,
# which would make this script match itself.
set +e
C=/mis/SteamLibrary/steamapps/compatdata/977400
S="$C/pfx/drive_c/users/steamuser/AppData/LocalLow/Computer Lunch/Cell to Singularity"
L="$S/Player.log"
GAME="/mis/SteamLibrary/steamapps/common/Cell to Singularity"
LAUNCHER="/usr/bin/dwproton"

kill_dwproton() {
  local p exe n=0
  for p in $(pgrep -f 'wine|xalia|services\.exe|plugplay|explorer\.exe|tabtip|winemenubuilder|rpcss|svchost|conhost' 2>/dev/null); do
    [ -d "/proc/$p" ] || continue
    exe=$(readlink -f "/proc/$p/exe" 2>/dev/null)
    case "$exe" in
      */compatibilitytools.d/dwproton/*) kill -9 "$p" 2>/dev/null && n=$((n+1)) ;;
    esac
  done
  echo "cleanup: killed $n dwproton process(es)"
}

pkill -9 -x CellToSingularity.exe 2>/dev/null
kill_dwproton
sleep 2
rm -f "$L" "$S"/cepack_shot*.png

cd "$GAME" || exit 1
export STEAM_COMPAT_DATA_PATH="$C"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam"
export SteamAppId=977400
export SteamGameId=977400
export CUSTOM_EVENT_PACK="${1:-SamplePack}"
export CUSTOM_EVENT_PACK_SHOT="${2:-}"
export CUSTOM_EVENT_PACK_SYNTH="${3:-0}"
export CUSTOM_EVENT_PACK_AUTOACCEPT="${4:-0}"
export CUSTOM_EVENT_PACK_FORCE_OUTRO="${5:-0}"
export CUSTOM_EVENT_PACK_FORCE_ADVANCE="${6:-0}"
echo "(pack='$CUSTOM_EVENT_PACK' shot='$CUSTOM_EVENT_PACK_SHOT' synth='$CUSTOM_EVENT_PACK_SYNTH' autoaccept='$CUSTOM_EVENT_PACK_AUTOACCEPT')"

echo "=== launching via dwproton at $(date +%T) ==="
setsid "$LAUNCHER" run "CellToSingularity.exe" -screen-fullscreen 0 -screen-width 1280 -screen-height 720 > /tmp/cepack_launch.log 2>&1 &
PID=$!

for i in $(seq 1 70); do
  sleep 5
  if grep -q "post-load fixup applied" "$L" 2>/dev/null; then echo "=== EVENT LOADED after $((i*5))s ==="; break; fi
  if grep -qa "load failed" "$L" 2>/dev/null; then echo "=== LOAD FAILED after $((i*5))s ==="; break; fi
done

echo "=== waiting for screenshot series ==="
sleep 110
ls -la "$S"/cepack_shot*.png 2>/dev/null || echo "no game screenshots"

echo "=== [CustomEventPack] log ==="
grep -a "CustomEventPack" "$L" 2>/dev/null | head -100
echo "=== exception summary ==="
grep -a -c "NullReferenceException" "$L" 2>/dev/null

echo "=== shutting down ==="
kill -TERM -$PID 2>/dev/null
sleep 4
pkill -9 -x CellToSingularity.exe 2>/dev/null
kill_dwproton
sleep 1
kill_dwproton
echo ALLDONE
