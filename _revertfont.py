P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
s = open(P, encoding="utf-8").read()
start = s.index("\t\t// The custom UI text is created with TMP_Settings.defaultFontAsset")
end = s.index('catch (Exception e) { Log.Warn("FontReplacer bootstrap failed: " + e.Message); }')
end += len('catch (Exception e) { Log.Warn("FontReplacer bootstrap failed: " + e.Message); }')
removed = s[start:end]
s = s[:start] + s[end:]
# tidy the blank line the removal leaves behind
s = s.replace("\t\tif (_installed) return;\n\n\n", "\t\tif (_installed) return;\n\n")
open(P, "w", encoding="utf-8").write(s)
print("removed", len(removed), "chars of FontReplacer bootstrap code")