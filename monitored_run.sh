#!/usr/bin/env bash
# Monitored run: launch the patched game with the pack auto-loading, WATCH THE GAME'S RSS,
# and hard-kill if it exceeds a ceiling. Never let a leak run away again.
set +e
DATA="/mis/SteamLibrary/steamapps/common/Cell to Singularity/CellToSingularity_Data"
LIMIT_MB=${1:-4200}
DURATION=${2:-200}

# clear the previous session's log first, otherwise the "shots done" check fires immediately
LOG="/mis/SteamLibrary/steamapps/compatdata/977400/pfx/drive_c/users/steamuser/AppData/LocalLow/Computer Lunch/Cell to Singularity/Player.log"
rm -f "$LOG" "$(dirname "$LOG")"/cepack_shot*.png
export CUSTOM_EVENT_PACK=SamplePack
export CUSTOM_EVENT_PACK_AUTOACCEPT=1
export CUSTOM_EVENT_PACK_SHOT=25

# Kill any previous instance FIRST. Without this a leftover game doubles the measured RSS
# and the watchdog fires during loading, before the probe can ever run.
P="Cell""ToSingularity"
pkill -9 -f "$P" 2>/dev/null
pkill -9 -f "wine""server" 2>/dev/null
# winedevice.exe processes are NOT children of the game: they survive it and pile up
# across runs. 38 of them once held 1 GB, which the watchdog counted as the game's own
# RSS and made it kill healthy runs. Always reap them first.
pkill -9 -f "wine""device" 2>/dev/null
# Wine's desktop explorer.exe survives the game: one 186 MB process per run stays
# behind. Eight of them once added 1.5 GB to the watchdog's reading - far more than
# the game itself - and killed perfectly healthy runs. Reap them too.
pkill -9 -f "explorer""[.]exe" 2>/dev/null
pkill -9 -f "dw""proton" 2>/dev/null
sleep 4

setsid bash "$DATA/_mod_tools/launch_modded.sh" dwproton > /tmp/mon_launch.log 2>&1 &
LPID=$!

PEAK=0
STARTED=0
for i in $(seq 1 $((DURATION/5))); do
  sleep 5
  if [ "$STARTED" = 0 ] && [ -s "$LOG" ]; then STARTED=1; echo "log appeared at t=$((i*5))s"; fi
  if [ "$STARTED" = 0 ] && [ "$i" -ge 12 ]; then
    echo "!!! game produced no log after 60s - it did not start"; tail -6 /tmp/mon_launch.log; break
  fi
  # total RSS of the game + its wine children
  RSS=$(ps -eo rss,args --no-headers 2>/dev/null | grep -E "CellToSingularity|wineserver|winedevice|explorer.exe" | grep -v grep | awk '{s+=$1} END {print int(s/1024)}')
  [ -z "$RSS" ] && RSS=0
  [ "$RSS" -gt "$PEAK" ] && PEAK=$RSS
  echo "t=$((i*5))s  gameRSS=${RSS}MB  peak=${PEAK}MB"
  if [ "$RSS" -gt "$LIMIT_MB" ]; then
    echo "!!! RSS ${RSS}MB exceeds ${LIMIT_MB}MB - KILLING"
    pkill -9 -f "Cell""ToSingularity"; pkill -9 -f "wine""server"; pkill -9 -f "dw""proton"
    break
  fi
  # stop early once the screenshots are done
  if grep -qa "screenshot -> .*cepack_shot3" "$LOG" 2>/dev/null; then
    echo "shots done at t=$((i*5))s"; break
  fi
done