P = "_mod_tools/patcher/Program.cs"
t = open(P, encoding="utf-8").read()
anchor = '            case "callstoreconst":'
assert t.count(anchor) == 1
new = '''            case "fieldinit":
            {
                // Rewrite a field's initialiser: find "stfld <field>" and replace the constant
                // that is loaded immediately before it. Targeting the FIELD NAME (rather than
                // the literal) matters here - Assistant..ctor initialises a dozen floats, so a
                // value-based "const" could easily hit the wrong one.
                var t5 = FindType(asm, a[1]);
                int n = 0;
                foreach (var m in t5.Methods.Where(x => x.Name == a[2] && x.HasBody))
                {
                    var insns = m.Body.Instructions;
                    foreach (var ins in insns.ToList())
                    {
                        if (ins.OpCode != OpCodes.Stfld || !(ins.Operand is FieldReference fr)) continue;
                        if (fr.Name != a[3]) continue;
                        int i = insns.IndexOf(ins);
                        if (i < 1) continue;
                        var prev = insns[i - 1];
                        float nv = float.Parse(a[4], System.Globalization.CultureInfo.InvariantCulture);
                        if (prev.OpCode == OpCodes.Ldc_R4) { prev.Operand = nv; n++; }
                        else if (prev.OpCode == OpCodes.Ldc_R8) { prev.Operand = (double)nv; n++; }
                        else if (prev.OpCode == OpCodes.Ldc_I4) { prev.Operand = (int)nv; n++; }
                    }
                }
                Console.WriteLine($"  fieldinit {a[1]}.{a[2]} {a[3]} = {a[4]}  ({n} site(s))");
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

# mod: make the nanobots as fast as the game itself ever makes them.
# Assistant..ctor initialises delaybuy = 0.15f (seconds between purchases) and baseSpeed = 10f
# (units/second of travel). The game's own AI-mode branch uses delaybuy = 0.00833f (about 120
# purchases per second) and baseSpeed = 400f, which is the fastest it ever configures. Apply
# those to the initialisers so they hold whether or not AI mode is enabled.
fieldinit   Assistant .ctor delaybuy 0.00833
fieldinit   Assistant .ctor baseSpeed 400
"""
open(Q, "w", encoding="utf-8").write(pt)
print("fieldinit added")
