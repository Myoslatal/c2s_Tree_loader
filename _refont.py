P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
s = open(P, encoding="utf-8").read()
anchor = "\t\tif (_installed) return;"
assert s.count(anchor) == 1, s.count(anchor)
block = anchor + """

\t\t// The custom UI text is built with TMP_Settings.defaultFontAsset, and the game ships a
\t\t// default TMP font with no CJK glyphs - so on a machine without FontReplacer every string
\t\t// this mod writes renders as nothing at all (the interface appears, just wordless).
\t\t// FontReplacer swaps in a runtime font built from StreamingAssets/zh-cn.ttf. It is folded
\t\t// into this same assembly, but reflection is used so the two plugins ALSO still work as
\t\t// separate dlls, and so a missing FontReplacer degrades with a warning instead of crashing.
\t\ttry
\t\t{
\t\t\tType fr = Type.GetType("FontReplacerPlugin.FontReplacerBootstrap");
\t\t\tif (fr == null)
\t\t\t{
\t\t\t\tforeach (Assembly asm in AppDomain.CurrentDomain.GetAssemblies())
\t\t\t\t{
\t\t\t\t\tfr = asm.GetType("FontReplacerPlugin.FontReplacerBootstrap");
\t\t\t\t\tif (fr != null) break;
\t\t\t\t}
\t\t\t}
\t\t\tif (fr != null)
\t\t\t{
\t\t\t\tMethodInfo mi = fr.GetMethod("Install", BindingFlags.Public | BindingFlags.Static);
\t\t\t\tif (mi != null)
\t\t\t\t{
\t\t\t\t\tmi.Invoke(null, null);
\t\t\t\t\tLog.Info("FontReplacer bootstrapped (CJK text available)");
\t\t\t\t}
\t\t\t\telse Log.Warn("FontReplacerBootstrap.Install not found");
\t\t\t}
\t\t\telse Log.Warn("FontReplacer is not installed; CJK text will not render");
\t\t}
\t\tcatch (Exception e) { Log.Warn("FontReplacer bootstrap failed: " + e.Message); }"""
s = s.replace(anchor, block, 1)
open(P, "w", encoding="utf-8").write(s)
print("FontReplacer bootstrap restored")