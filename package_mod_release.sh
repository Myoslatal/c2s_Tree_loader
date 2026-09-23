#!/usr/bin/env bash
# Package the custom exploration event mod as a standalone Windows 64-bit release.
#
#   bash _mod_tools/package_mod_release.sh --font /path/to/zh-cn.ttf
#
# --font is REQUIRED and points at the TTF FontReplacerPlugin should load. That is the
# whole point of the parameter: the font is not kept in the repository (11 MB third
# party binary), so every build must say where to take it from. Inside the archive it
# is always named zh-cn.ttf, because FontReplacerPlugin.cs resolves exactly
#   Path.Combine(Application.streamingAssetsPath, "zh-cn.ttf")
# a differently named source file is copied under that name, not kept as-is.
#
# Produces _mod_tools/dist/CellToSingularityMod-win64.zip
set -euo pipefail

DATA="$(cd "$(dirname "$0")/.." && pwd)"
M="$DATA/Managed"
DIST="$DATA/_mod_tools/dist"
OUT="$DIST/CellToSingularityMod-win64"
ZIP="$DIST/CellToSingularityMod-win64.zip"
FONT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --font)    FONT="${2:-}"; shift 2 ;;
    --font=*)  FONT="${1#--font=}"; shift ;;
    -h|--help) sed -n "2,13p" "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (use --help)" >&2; exit 2 ;;
  esac
done

[ -n "$FONT" ] || { echo "缺少 --font <ttf 路径>：字体不在仓库里，必须指定要打包的 TTF" >&2; exit 2; }
[ -f "$FONT" ] || { echo "字体不存在: $FONT" >&2; exit 2; }
for f in Assembly-CSharp.dll CustomEventPackPlugin.dll FontReplacerPlugin.dll; do
  [ -f "$M/$f" ] || { echo "缺少 $M/$f（先跑 launch_modded.sh 完成补丁与折叠）" >&2; exit 1; }
done

rm -rf "$OUT"
mkdir -p "$OUT/CellToSingularity_Data/Managed" \
         "$OUT/CellToSingularity_Data/StreamingAssets" \
         "$OUT/CellToSingularity_Data/CustomEvents" \
         "$OUT/原版备份"

cp "$M/Assembly-CSharp.dll"       "$OUT/CellToSingularity_Data/Managed/"
cp "$M/CustomEventPackPlugin.dll" "$OUT/CellToSingularity_Data/Managed/"
cp "$M/FontReplacerPlugin.dll"    "$OUT/CellToSingularity_Data/Managed/"
cp "$M/Assembly-CSharp.dll.bak"   "$OUT/原版备份/Assembly-CSharp.dll"

# Always land as zh-cn.ttf - see the lookup path in the header comment.
cp "$FONT" "$OUT/CellToSingularity_Data/StreamingAssets/zh-cn.ttf"

cp "$DATA/_mod_tools/mod_release_README.md" "$OUT/README.md"
cp "$OUT/README.md" "$OUT/CellToSingularity_Data/CustomEvents/README.md"

rm -f "$ZIP"
( cd "$OUT/.." && zip -r -q -X "$(basename "$ZIP")" "$(basename "$OUT")" )

echo "OK: $ZIP"
echo "    $(stat -c%s "$ZIP") bytes"
echo "    font: $FONT ($(stat -c%s "$FONT") bytes) -> StreamingAssets/zh-cn.ttf"
