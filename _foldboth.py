P = "_mod_tools/launch_modded.sh"
t = open(P, encoding="utf-8").read()

# declare the second plugin path next to the first
old_var = 'PLUGIN="$M/CustomEventPackPlugin.dll"'
assert t.count(old_var) == 1, ("var", t.count(old_var))
t = t.replace(old_var, old_var + chr(10) + 'FONT_PLUGIN="$M/FontReplacerPlugin.dll"')

# fold BOTH plugins instead of just the first
old_fold = '''if [ -f "$PLUGIN" ] && [ -x "$FOLDER" ]; then
  "$FOLDER" "$LIVE" "$PLUGIN" "$LIVE.folded" "$M" >/dev/null || {
    echo "[launcher] FOLD FAILED"; exit 1; }
  mv -f "$LIVE.folded" "$LIVE"
  echo "[launcher] folded the plugin into Assembly-CSharp"
else
  echo "[launcher] WARNING: $PLUGIN or ilfold missing - plugin NOT embedded"
fi'''
new_fold = '''if [ -f "$PLUGIN" ] && [ -x "$FOLDER" ]; then
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
fi'''
assert t.count(old_fold) == 1, ("fold", t.count(old_fold))
t = t.replace(old_fold, new_fold)
open(P, "w", encoding="utf-8").write(t)
print("OK: launcher folds both plugins")