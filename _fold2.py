# 1. ilfold: make the <PrivateImplementationDetails> rename unique PER PLUGIN, otherwise the
#    second fold collides with the name the first fold already introduced.
P = "_mod_tools/ilfold/Program.cs"
t = open(P, encoding="utf-8").read()
old = '\"<PrivateImplementationDetails>CustomEventPack\"'
new = '\"<PrivateImplementationDetails>\" + pm.Assembly.Name.Name'
assert t.count(old) == 1, ("ilfold", t.count(old))
t = t.replace(old, new)
open(P, "w", encoding="utf-8").write(t)
print("ilfold: rename is now per-plugin")

# 2. the CustomEventPack plugin bootstraps FontReplacer, so ONE dll is self-sufficient.
Q = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
s = open(Q, encoding="utf-8").read()
anchor = "	\tif (_installed) return;"
assert s.count(anchor) == 1, ("anchor", s.count(anchor))
call = anchor + """

\t\t// The custom UI text is created with TMP_Settings.defaultFontAsset, and the game ships a
\t\t// default TMP font with no CJK glyphs - so every string this mod writes would render as
\t\t// nothing. FontReplacer swaps in a runtime font built from StreamingAssets/zh-cn.ttf.
\t\t// It is folded into this same assembly now, but reflection is used so the two plugins also
\t\t// still work as separate dlls, and so a missing FontReplacer degrades instead of crashing.
\t\ttry
\t\t{
\t\t\tType fr = Type.GetType("FontReplacerPlugin.FontReplacerBootstrap");
\t\t\tif (fr == null)
\t\t\t{
\t\t\t\tforeach (Assembly a in AppDomain.CurrentDomain.GetAssemblies())
\t\t\t\t{
\t\t\t\t\tfr = a.GetType("FontReplacerPlugin.FontReplacerBootstrap");
\t\t\t\t\tif (fr != null) break;
\t\t\t\t}
\t\t\t}
\t\t\tif (fr != null)
\t\t\t{
\t\t\t\tMethodInfo mi = fr.GetMethod("Install", BindingFlags.Public | BindingFlags.Static);
\t\t\t\tif (mi != null) mi.Invoke(null, null);
\t\t\t\telse Log.Warn("FontReplacerBootstrap.Install not found");
\t\t\t}
\t\t\telse Log.Warn("FontReplacer is not installed; CJK text may not render");
\t\t}
\t\tcatch (Exception e) { Log.Warn("FontReplacer bootstrap failed: " + e.Message); }"""
s = s.replace(anchor, call)
open(Q, "w", encoding="utf-8").write(s)
print("plugin: bootstraps FontReplacer")