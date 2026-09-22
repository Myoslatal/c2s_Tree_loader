P = "_mod_tools/patcher/Program.cs"
t = open(P, encoding="utf-8").read()
anchor = '            case "dropinit":'
assert t.count(anchor) == 1
new = '''            case "scalearg":
            {
                // Multiply a method's numeric PARAMETER by a factor, at the very top of the
                // body. This is how the 5x tap is applied: every tap path - the manual one in
                // TapEmptySpace (scale field, default 1.0) and the Assistant's auto-tap
                // (literal 10.0) - funnels through CalTap*Value, so scaling the argument there
                // covers all of them. Patching the call sites only ever caught one path.
                var t3 = FindType(asm, a[1]);
                double factor = double.Parse(a[3], System.Globalization.CultureInfo.InvariantCulture);
                int n = 0;
                foreach (var m in t3.Methods.Where(x => x.Name == a[2] && x.HasBody && x.Parameters.Count > 0))
                {
                    var p0 = m.Parameters[0].ParameterType;
                    if (p0.MetadataType != MetadataType.Double && p0.MetadataType != MetadataType.Single)
                        continue;
                    var il = m.Body.GetILProcessor();
                    var first = m.Body.Instructions[0];
                    if (p0.MetadataType == MetadataType.Double)
                    {
                        il.InsertBefore(first, il.Create(OpCodes.Ldarg, m.Parameters[0]));
                        il.InsertBefore(first, il.Create(OpCodes.Ldc_R8, factor));
                        il.InsertBefore(first, il.Create(OpCodes.Mul));
                    }
                    else
                    {
                        il.InsertBefore(first, il.Create(OpCodes.Ldarg, m.Parameters[0]));
                        il.InsertBefore(first, il.Create(OpCodes.Ldc_R4, (float)factor));
                        il.InsertBefore(first, il.Create(OpCodes.Mul));
                    }
                    il.InsertBefore(first, il.Create(OpCodes.Starg, m.Parameters[0]));
                    n++;
                }
                Console.WriteLine($"  scalearg {a[1]}.{a[2]} arg0 x{a[3]}  ({n} overload(s))");
                applied += n;
                break;
            }
'''
t = t.replace(anchor, new + anchor)
open(P, "w", encoding="utf-8").write(t)

Q = "_mod_tools/patches.txt"
pt = open(Q, encoding="utf-8").read()
pt = pt.replace("""const       Assistant TapMove 10.0 50.0
const       Assistant FindCurrencyPayout 10.0 50.0""",
"""# Applied INSIDE CalTap*Value so EVERY tap path is covered: the manual tap passes the
# TapEmptySpace.scale field (1.0) and the Assistant passes 10.0, so patching either call
# site only ever fixed one of them.
scalearg    GameController CalTapEvolutionValue 5
scalearg    GameController CalTapIdeaValue 5
scalearg    GameController CalTapDinoValue 5
scalearg    GameController CalTapSciValue 5""")
open(Q, "w", encoding="utf-8").write(pt)
print("scalearg added")
