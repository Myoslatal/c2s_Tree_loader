P = "_mod_tools/patcher/Program.cs"
t = open(P, encoding="utf-8").read()
anchor = '            case "branchalways":'
assert t.count(anchor) == 1, t.count(anchor)
block = '''            case "storepop":
            {
                // Neutralise ONE field store by replacing it with the pops that keep the stack
                // balanced, leaving the value computation in place. dropinit cannot be used here:
                // it locates the start of the assignment by walking back to ldarg.0, which does
                // not exist in a STATIC method - the receiver there comes from a get_instance
                // call, so dropinit would walk past unrelated statements and delete them.
                //
                // stfld pops [object, value] and stsfld pops [value], so the replacement is exact.
                var t3 = FindType(asm, a[1]);
                int n = 0;
                foreach (var m in t3.Methods.Where(x => x.Name == a[2] && x.HasBody))
                {
                    var insns = m.Body.Instructions;
                    for (int i = insns.Count - 1; i >= 0; i--)
                    {
                        var ins = insns[i];
                        if (ins.OpCode == OpCodes.Stfld && ins.Operand is FieldReference fr && fr.Name == a[3])
                        {
                            ins.OpCode = OpCodes.Pop;
                            ins.Operand = null;
                            insns.Insert(i, Instruction.Create(OpCodes.Pop));
                            n++;
                        }
                        else if (ins.OpCode == OpCodes.Stsfld && ins.Operand is FieldReference fr2 && fr2.Name == a[3])
                        {
                            ins.OpCode = OpCodes.Pop;
                            ins.Operand = null;
                            n++;
                        }
                    }
                }
                Console.WriteLine($"  storepop {a[1]}.{a[2]} ~ {a[3]}  ({n} store(s) neutralised)");
                applied += n;
                break;
            }
            case "branchalways":'''
t = t.replace(anchor, block)
open(P, "w", encoding="utf-8").write(t)
print("OK: storepop added to the patcher")

# register the two directives
Q = "_mod_tools/patches.txt"
s = open(Q, encoding="utf-8").read()
old = "dropinit    TimeManager ResetSimTimer offlineTimeCurSim"
assert s.count(old) == 1, s.count(old)
new = old + """

# The assignments above are NOT the ones that actually do the work: the caller zeroes both
# fields BEFORE it ever calls ResetSimTimer, so removing them there changed nothing. DeleteSave.
# OnPressedYesThirdTime is the "reset main simulation" confirmation handler and is static, which
# is why storepop (replace the store with its pops) is used instead of dropinit.
storepop    DeleteSave OnPressedYesThirdTime totalTimeCurSim
storepop    DeleteSave OnPressedYesThirdTime offlineTimeCurSim"""
s = s.replace(old, new)
open(Q, "w", encoding="utf-8").write(s)
print("OK: two storepop directives registered")