import re
P = "_mod_tools/patcher/Program.cs"
t = open(P, encoding="utf-8").read()

# --- 1. const: support double/float literals ---
old = '''                int oldV = int.Parse(a[3]), newV = int.Parse(a[4]);
                int n = 0;'''
new = '''                int oldV = int.Parse(a[3]), newV = int.Parse(a[4]);
                int n = 0;
                // Literal doubles are the ones that matter for the tap bonus: the callers
                // pass the tap scale as "10.0", which the compiler emits as ldc.r8.
                double oldD = oldV, newD = newV;
                if (a.Count > 5 && a[5] == "f") { oldD = double.Parse(a[3], System.Globalization.CultureInfo.InvariantCulture); newD = double.Parse(a[4], System.Globalization.CultureInfo.InvariantCulture); }'''
assert t.count(old) == 1
t = t.replace(old, new)

old2 = '''                        else if (ins.OpCode == OpCodes.Ldc_I4_S && ins.Operand is sbyte sb && sb == oldV)
                        { ins.Operand = (sbyte)newV; n++; }'''
new2 = old2 + '''
                        else if (ins.OpCode == OpCodes.Ldc_R8 && ins.Operand is double dv && dv == oldD)
                        { ins.Operand = newD; n++; }
                        else if (ins.OpCode == OpCodes.Ldc_R4 && ins.Operand is float fv && (double)fv == oldD)
                        { ins.Operand = (float)newD; n++; }'''
assert t.count(old2) == 1
t = t.replace(old2, new2)

# --- 2. new directive: dropinit ---
anchor = '            case "branchalways":'
assert t.count(anchor) == 1
drop = '''            case "dropinit":
            {
                // Remove ONE field assignment from a method, together with the instructions
                // that compute its value. Used on TimeManager.ResetSimTimer, whose first two
                // statements zero the time-capsule totals: deleting the whole CALL to
                // ResetSimTimer (the previous approach) also lost the private singInfo /
                // bSingRunComplete resets that the singularity flow depends on, which hung
                // the game when the main simulation was restarted.
                var t2 = FindType(asm, a[1]);
                int n = 0;
                foreach (var m in t2.Methods.Where(x => x.Name == a[2] && x.HasBody))
                {
                    var insns = m.Body.Instructions;
                    for (int i = insns.Count - 1; i >= 0; i--)
                    {
                        var ins = insns[i];
                        if (ins.OpCode != OpCodes.Stfld || !(ins.Operand is FieldReference fr)) continue;
                        if (fr.Name != a[3]) continue;
                        // walk back to the 'ldarg.0' that starts the assignment, then drop the range
                        int start = i;
                        while (start > 0 && insns[start].OpCode != OpCodes.Ldarg_0) start--;
                        if (insns[start].OpCode != OpCodes.Ldarg_0) continue;
                        for (int k = i; k >= start; k--) insns.RemoveAt(k);
                        n++;
                    }
                }
                Console.WriteLine($"  dropinit {a[1]}.{a[2]} -= {a[3]}  ({n} assignment(s) removed)");
                applied += n;
                break;
            }
'''
t = t.replace(anchor, drop + anchor)
open(P, "w", encoding="utf-8").write(t)
print("patcher: const doubles + dropinit")
