P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
t = open(P, encoding="utf-8").read()
old = 'n.GetActiveDuration().ToString("F2")'
assert t.count(old) == 1, t.count(old)
# GetActiveDuration() returns a TimeSpan, and TimeSpan does not accept the "F2" format
# string - it threw FormatException and the probe logged nothing useful.
t = t.replace(old, 'n.GetActiveDuration().TotalSeconds.ToString("F2")')
open(P, "w", encoding="utf-8").write(t)
print("fixed")