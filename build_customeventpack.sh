#!/usr/bin/env bash
# Build CustomEventPackPlugin.dll against the game's own assemblies.
set -euo pipefail
DATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DATA_DIR"

export HOME="$DATA_DIR/_mod_tools/devhome"
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1

CSC="$(ls /usr/share/dotnet/sdk/*/Roslyn/bincore/csc.dll | head -1)"
[ -n "$CSC" ] || { echo "csc.dll not found"; exit 1; }

SRC="_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
OUT="Managed/CustomEventPackPlugin.dll"

echo "compiling $SRC -> $OUT"
dotnet "$CSC" -nologo -noconfig -nostdlib+ -target:library -langversion:9.0 -optimize+ -debug- \
  -out:"$OUT" \
  @_mod_tools/refs.rsp \
  "$SRC"

echo "OK: $(ls -la "$OUT")"
