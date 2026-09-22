import re
P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
t = open(P, encoding="utf-8").read()

# 1) add the single-background field next to the legacy list
old = "\tpublic List<BackgroundDef> Backgrounds = new List<BackgroundDef>();\n"
assert t.count(old) == 1
t = t.replace(old, old + "\n\t// The pack's SINGLE background image (pack.json \"background\"), resolved to an\n\t// absolute path. The legacy \"backgrounds\" array is still honoured for packs\n\t// written by older editor builds; this field wins when both are present.\n\tpublic string Background;\n")

# 2) parse it right before the legacy array is read
old = '\t\t\t\tpack.ResourceName = Str(jObject, "resourceName");'
assert t.count(old) == 1
t = t.replace(old, '''\t\t\t\tstring bgOne = Str(jObject, "background");
\t\t\t\tif (!string.IsNullOrEmpty(bgOne))
\t\t\t\t{
\t\t\t\t\tpack.Background = Resolve(dir, bgOne);
\t\t\t\t}
''' + old)
open(P, "w", encoding="utf-8").write(t)
print("plugin: field + parse added")

# 3) the applier should prefer it
old2 = '''			foreach (BackgroundDef background in pack.Backgrounds)
			{
				if (background.Visible && background.File != null && File.Exists(background.File))
				{
					string text = background.File;
					break;
				}
			}'''
print("applier matches:", t.count(old2))
