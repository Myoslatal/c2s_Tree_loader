P = "_mod_tools/patcher/Program.cs"
t = open(P, encoding="utf-8").read()
anchor = '            case "fieldinit":'
assert t.count(anchor) == 1
new = '''            case "forcefield":
            {
                // Append a forced assignment immediately AFTER each existing store to a field.
                // Used for NanobotUpgradeStats.EventNanobotsUnlocked, which UpdateAll() recomputes
                // as "GetOwnedCount(\\"a_nanobot_event\\") > 0" on every call. A custom event ships
                // without that upgrade, so the flag stays false, and in an event scene
                // UsesSharedBoostTimerForCurrentSimulation() then returns false - which makes
                // GetNanobotTapPowerScale() return a flat 1f and drops EVERY nanobot bonus.
                // Patching the store (rather than setting the field from the plugin) is required:
                // UpdateAll() runs as the first statement of the very getter that reads the flag,
                // so an external write is always overwritten before it is consulted.
                var t6 = FindType(asm, a[1]);
                int val = int.Parse(a[4]);
                int n = 0;
                foreach (var m in t6.Methods.Where(x => (a[2] == "*" || x.Name == a[2]) && x.HasBody))
                {
                    var ilp = m.Body.GetILProcessor();
                    foreach (var ins in m.Body.Instructions.ToList())
                    {
                        if (ins.OpCode != OpCodes.Stsfld || !(ins.Operand is FieldReference fr)) continue;
                        if (fr.Name != a[3]) continue;
                        ilp.InsertAfter(ins, ilp.Create(OpCodes.Stsfld, fr));
                        ilp.InsertAfter(ins, ilp.Create(OpCodes.Ldc_I4, val));
                        n++;
                    }
                }
                Console.WriteLine($"  forcefield {a[1]}.{a[2]} {a[3]} = {a[4]}  ({n} store(s))");
                if (n == 0) failed++;
                applied += n;
                break;
            }
'''
t = t.replace(anchor, new + anchor)
open(P, "w", encoding="utf-8").write(t)

Q = "_mod_tools/patches.txt"
pt = open(Q, encoding="utf-8").read()
pt = pt.rstrip("\n") + """

# Nanobot bonuses in a custom event.
# UsesSharedBoostTimerForCurrentSimulation() only returns true for an event scene when
# NanobotUpgradeStats.EventNanobotsUnlocked is set, and UpdateAll() derives that flag from
# owning "a_nanobot_event" - an upgrade a custom event does not ship. Without it
# GetNanobotTapPowerScale() short-circuits to 1f, so the nanobots receive no tap-power bonus.
forcefield  NanobotUpgradeStats * EventNanobotsUnlocked 1
"""
open(Q, "w", encoding="utf-8").write(pt)
print("forcefield added")
