import re
P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
t = open(P, encoding="utf-8").read()

old = '''				Pack lastLoaded = PackLoader.LastLoaded;
				string text = null;
				if (lastLoaded != null && lastLoaded.Backgrounds != null)
				{
					foreach (BackgroundDef background in lastLoaded.Backgrounds)
					{
						if (background.Visible && background.File != null && File.Exists(background.File))
						{
							text = background.File;
							break;
						}
					}
				}'''
new = '''				Pack lastLoaded = PackLoader.LastLoaded;
				string text = null;
				if (lastLoaded != null)
				{
					// A pack has ONE background ("background" in pack.json). The legacy
					// "backgrounds" array is only a fallback so packs written by older
					// editor builds keep working.
					if (!string.IsNullOrEmpty(lastLoaded.Background) && File.Exists(lastLoaded.Background))
					{
						text = lastLoaded.Background;
					}
					else if (lastLoaded.Backgrounds != null)
					{
						foreach (BackgroundDef background in lastLoaded.Backgrounds)
						{
							if (background.Visible && background.File != null && File.Exists(background.File))
							{
								text = background.File;
								break;
							}
						}
					}
				}'''
assert t.count(old) == 1, t.count(old)
t = t.replace(old, new)

old2 = 'string[] array2 = new string[3] { "pink donut", "fetus circle", "mother circle" };'
new2 = ('// "tree_background" covers the other event templates; "pink donut" and the two\n'
        '\t\t\t\t\t// circle sprites are the fetus-womb template this event borrows its tree from.\n'
        '\t\t\t\t\tstring[] array2 = new string[4] { "tree_background", "pink donut", "fetus circle", "mother circle" };')
assert t.count(old2) == 1, t.count(old2)
t = t.replace(old2, new2)
open(P, "w", encoding="utf-8").write(t)
print("plugin applier updated")
