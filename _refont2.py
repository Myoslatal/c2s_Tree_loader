P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
s = open(P, encoding="utf-8").read()
T = chr(9)
anchor = T*2 + "if (_installed)" + chr(10) + T*2 + "{" + chr(10) + T*3 + "return;" + chr(10) + T*2 + "}"
assert s.count(anchor) == 1, ("anchor count", s.count(anchor))
block = [
    "",
    T*2 + "// The custom UI text is built with TMP_Settings.defaultFontAsset, and the game ships a",
    T*2 + "// default TMP font with no CJK glyphs - so on a machine without FontReplacer every",
    T*2 + "// string this mod writes renders as nothing at all: the interface appears, wordless.",
    T*2 + "// FontReplacer swaps in a runtime font built from StreamingAssets/zh-cn.ttf. It is folded",
    T*2 + "// into this same assembly, but reflection is used so the two plugins ALSO still work as",
    T*2 + "// separate dlls, and so a missing FontReplacer warns instead of crashing.",
    T*2 + "try",
    T*2 + "{",
    T*3 + 'Type fr = Type.GetType("FontReplacerPlugin.FontReplacerBootstrap");',
    T*3 + "if (fr == null)",
    T*3 + "{",
    T*4 + "foreach (Assembly asm in AppDomain.CurrentDomain.GetAssemblies())",
    T*4 + "{",
    T*5 + 'fr = asm.GetType("FontReplacerPlugin.FontReplacerBootstrap");',
    T*5 + "if (fr != null) break;",
    T*4 + "}",
    T*3 + "}",
    T*3 + "if (fr != null)",
    T*3 + "{",
    T*4 + 'MethodInfo mi = fr.GetMethod("Install", BindingFlags.Public | BindingFlags.Static);',
    T*4 + "if (mi != null)",
    T*4 + "{",
    T*5 + "mi.Invoke(null, null);",
    T*5 + 'Log.Info("FontReplacer bootstrapped (CJK text available)");',
    T*4 + "}",
    T*4 + 'else Log.Warn("FontReplacerBootstrap.Install not found");',
    T*3 + "}",
    T*3 + 'else Log.Warn("FontReplacer is not installed; CJK text will not render");',
    T*2 + "}",
    T*2 + 'catch (Exception e) { Log.Warn("FontReplacer bootstrap failed: " + e.Message); }',
]
s = s.replace(anchor, anchor + chr(10) + chr(10).join(block), 1)
open(P, "w", encoding="utf-8").write(s)
print("OK: FontReplacer bootstrap inserted")