P = "_mod_tools/patcher/Program.cs"
t = open(P, encoding="utf-8").read()
anchor = '            case "scalearg":'
assert t.count(anchor) == 1
new = '''            case "callstoreconst":
            {
                // Replace a CALL with a constant, ONLY where its result is stored straight into
                // a static field. BoostTimerManager calls GetNanobotResetTimer_Seconds() twice
                // with opposite meanings: once as the COOLDOWN length ("call" then "stsfld
                // timer" - the one we want to zero) and once as the ACTIVE timer's clamp ("call"
                // then "stloc"). Zeroing the function itself (the old "retconst") hit both and
                // made every nanobot boost end instantly.
                var t4 = FindType(asm, a[1]);
                float val = float.Parse(a[4], System.Globalization.CultureInfo.InvariantCulture);
                int n = 0;
                foreach (var m in t4.Methods.Where(x => (a[2] == "*" || x.Name == a[2]) && x.HasBody))
                {
                    var insns = m.Body.Instructions;
                    foreach (var ins in insns.ToList())
                    {
                        if (ins.OpCode != OpCodes.Call && ins.OpCode != OpCodes.Callvirt) continue;
                        if (!(ins.Operand is MethodReference mr) || mr.Name != a[3]) continue;
                        int i = insns.IndexOf(ins);
                        if (i < 0 || i + 1 >= insns.Count) continue;
                        if (insns[i + 1].OpCode != OpCodes.Stsfld) continue;   // only the field store
                        ins.OpCode = OpCodes.Ldc_R4;
                        ins.Operand = val;
                        n++;
                    }
                }
                Console.WriteLine($"  callstoreconst {a[1]}.{a[2]} {a[3]}() -> {a[4]}f  ({n} site(s))");
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

# mod 5 (corrected) - nanobot cooldown is 0.
# Zero ONLY the assignment that sets the cooldown length when a boost ends. That value is
# stored to the static 'timer' field, so the cooldown expires on the very next frame and
# nanobots are immediately ready again. The OTHER call to the same method feeds the ACTIVE
# timer's clamp ("if (timer > reset) timer = reset") and stores to a local, so it keeps its
# real value - zeroing it there was what made every boost end the moment it started.
callstoreconst BoostTimerManager * GetNanobotResetTimer_Seconds 0
"""
open(Q, "w", encoding="utf-8").write(pt)
print("callstoreconst added")
