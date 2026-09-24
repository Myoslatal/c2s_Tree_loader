// patcher - declarative IL patching for Cell to Singularity.
//
//   patcher <inDll> <outDll> <patchFile> [<searchDirForCalls>]
//
// Patch file: one directive per line, '#' comments.
//   call       <Type> <Method> <CallAsm> <CallType> <CallMethod>   inject a static call at method entry
//   const      <Type|*> <Method|*> <old> <new>                     replace ldc.i4 <old> with <new>
//   retconst   <Type> <Method> <value>                             replace the body with ldc <value>; ret
//   removecall <Type|*> <Method|*> <CallType> <CallMethod>         delete calls to that method
using Mono.Cecil;
using Mono.Cecil.Cil;

if (args.Length < 3) { Console.Error.WriteLine("usage: patcher <inDll> <outDll> <patchFile> [searchDir]"); return 2; }
string inDll = args[0], outDll = args[1], patchFile = args[2];
string inDir = Path.GetDirectoryName(Path.GetFullPath(inDll))!;
string searchDir = args.Length > 3 ? args[3] : inDir;

var resolver = new DefaultAssemblyResolver();
resolver.AddSearchDirectory(inDir);
resolver.AddSearchDirectory(searchDir);
var asm = AssemblyDefinition.ReadAssembly(inDll, new ReaderParameters { AssemblyResolver = resolver, ReadingMode = ReadingMode.Immediate });
Console.WriteLine($"input : {inDll} ({asm.Name.Name})");

int applied = 0, failed = 0;
var lines = File.ReadAllLines(patchFile)
    .Select(l => l.Trim())
    .Where(l => l.Length > 0 && !l.StartsWith("#"))
    .ToList();

foreach (var line in lines)
{
    var a = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
    try
    {
        switch (a[0])
        {
            case "call":
            {
                var t = FindType(asm, a[1]); var m = FindMethod(t, a[2]);
                var callRef = ResolveCall(asm, resolver, a[3], a[4], a[5]);
                var il = m.Body.GetILProcessor();
                il.InsertBefore(m.Body.Instructions[0], il.Create(OpCodes.Call, callRef));
                Console.WriteLine($"  call   {a[1]}.{a[2]} <- {a[4]}.{a[5]}"); applied++;
                break;
            }
            case "const":
            {
                // Compare NUMERICALLY at double precision, so one directive handles both
                // ldc.i4 / ldc.i4.s (the tap-rate limit, emitted as an int) and ldc.r8
                // (the tap SCALE, emitted as "10" for the source literal 10.0).
                bool isDouble = a[3].Contains(".") || a[4].Contains(".");
                double oldD = double.Parse(a[3], System.Globalization.CultureInfo.InvariantCulture);
                double newD = double.Parse(a[4], System.Globalization.CultureInfo.InvariantCulture);
                int n = 0;
                foreach (var m in Methods(asm, a[1], a[2]))
                {
                    foreach (var ins in m.Body.Instructions.ToList())
                    {
                        var op = ins.OpCode;
                        // Two DISJOINT groups. An earlier version chained them with
                        // "if (isDouble) { } else if (<int arms>)", and because a true first
                        // branch skips every else-if, the double case matched nothing at all.
                        if (!isDouble)
                        {
                            if (op == OpCodes.Ldc_I4 && ins.Operand is int iv) { if ((double)iv == oldD) { ins.Operand = (int)newD; n++; } }
                            else if (op == OpCodes.Ldc_I4_S && ins.Operand is sbyte sb) { if ((double)sb == oldD) { ins.Operand = (sbyte)newD; n++; } }
                            else if (op == OpCodes.Ldc_I4_0 && oldD == 0) { ins.OpCode = OpCodes.Ldc_I4; ins.Operand = (int)newD; n++; }
                            else if (op == OpCodes.Ldc_I4_1 && oldD == 1) { ins.OpCode = OpCodes.Ldc_I4; ins.Operand = (int)newD; n++; }
                            else if (op == OpCodes.Ldc_I4_2 && oldD == 2) { ins.OpCode = OpCodes.Ldc_I4; ins.Operand = (int)newD; n++; }
                            else if (op == OpCodes.Ldc_I4_3 && oldD == 3) { ins.OpCode = OpCodes.Ldc_I4; ins.Operand = (int)newD; n++; }
                            else if (op == OpCodes.Ldc_I4_4 && oldD == 4) { ins.OpCode = OpCodes.Ldc_I4; ins.Operand = (int)newD; n++; }
                            else if (op == OpCodes.Ldc_I4_5 && oldD == 5) { ins.OpCode = OpCodes.Ldc_I4; ins.Operand = (int)newD; n++; }
                            else if (op == OpCodes.Ldc_I4_6 && oldD == 6) { ins.OpCode = OpCodes.Ldc_I4; ins.Operand = (int)newD; n++; }
                            else if (op == OpCodes.Ldc_I4_7 && oldD == 7) { ins.OpCode = OpCodes.Ldc_I4; ins.Operand = (int)newD; n++; }
                            else if (op == OpCodes.Ldc_I4_8 && oldD == 8) { ins.OpCode = OpCodes.Ldc_I4; ins.Operand = (int)newD; n++; }
                        }
                        else
                        {
                            if (op == OpCodes.Ldc_R8 && ins.Operand is double dv) { if (dv == oldD) { ins.Operand = newD; n++; } }
                            else if (op == OpCodes.Ldc_R4 && ins.Operand is float fv) { if ((double)fv == oldD) { ins.Operand = (float)newD; n++; } }
                        }
                    }
                }
                Console.WriteLine($"  const  {a[1]}.{a[2]} {a[3]} -> {a[4]}  ({n} site(s))");
                if (n == 0) failed++;
                applied += n;
                break;
            }


            case "appendcall":
            {
                // Insert `call <hook>` immediately BEFORE the last ret, so the hook runs
                // AFTER the original body has done its work. `call` (prefix injection) is
                // useless when the point of the hook is to revise something the original
                // body just assigned - the original would simply overwrite it again.
                var t = FindType(asm, a[1]); var m = FindMethod(t, a[2]);
                var callRef = ResolveCall(asm, resolver, a[3], a[4], a[5]);
                var il = m.Body.GetILProcessor();
                var ret = m.Body.Instructions.LastOrDefault(x => x.OpCode == OpCodes.Ret);
                if (ret == null)
                {
                    Console.WriteLine($"  appendcall {a[1]}.{a[2]} FAILED (no ret)"); failed++;
                }
                else
                {
                    // Insert the call, then RETARGET every branch that jumps to the ret so it
                    // jumps to the call instead. Without this the call is only reachable by
                    // FALLING THROUGH from the instruction above it - which lands it inside
                    // whatever if-block happens to end the method.
                    //
                    // Real case that broke the first version: SegLeaderboardDisplay.Start()
                    // ends with
                    //     if (eventIsDone) { Destroy(addFriendButtonHolder); }
                    //     ret
                    // so "insert before the last ret" put the hook INSIDE the if-body, and the
                    // brfalse that skips the if-body jumped straight over the hook. The hook
                    // then never ran during an active event (eventIsDone == false).
                    var callIns = il.Create(OpCodes.Call, callRef);
                    il.InsertBefore(ret, callIns);
                    int redirected = 0;
                    foreach (var ins in m.Body.Instructions)
                    {
                        if (ins.Operand is Instruction tgt && tgt == ret && ins != callIns)
                        {
                            ins.Operand = callIns;
                            redirected++;
                        }
                    }
                    foreach (var eh in m.Body.ExceptionHandlers)
                    {
                        if (eh.TryEnd == ret) { eh.TryEnd = callIns; redirected++; }
                        if (eh.HandlerStart == ret) { eh.HandlerStart = callIns; redirected++; }
                        if (eh.HandlerEnd == ret) { eh.HandlerEnd = callIns; redirected++; }
                    }
                    Console.WriteLine($"  appendcall {a[1]}.{a[2]} <- {a[4]}.{a[5]}  ({redirected} branch(es) retargeted)"); applied++;
                }
                break;
            }
            case "replacebody":
            {
                // void method: body becomes  call <ourMethod>; ret
                var t = FindType(asm, a[1]); var m = FindMethod(t, a[2]);
                var callRef = ResolveCall(asm, resolver, a[3], a[4], a[5]);
                var il = m.Body.GetILProcessor();
                m.Body.Instructions.Clear();
                m.Body.Variables.Clear();
                m.Body.ExceptionHandlers.Clear();
                il.Append(il.Create(OpCodes.Call, callRef));
                il.Append(il.Create(OpCodes.Ret));
                Console.WriteLine($"  replacebody {a[1]}.{a[2]} -> {a[4]}.{a[5]}"); applied++;
                break;
            }
            case "forcefield":
            {
                // Append a forced assignment immediately AFTER each existing store to a field.
                // Used for NanobotUpgradeStats.EventNanobotsUnlocked, which UpdateAll() recomputes
                // as "GetOwnedCount(\"a_nanobot_event\") > 0" on every call. A custom event ships
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
            case "fieldinit":
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
            case "callstoreconst":
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
                ILProcessor il2 = null;
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
                        // A callvirt CONSUMES its receiver, which for
                        // "UpgradeStatsManager.nanobots.GetNanobotResetTimer_Seconds()" is an
                        // object pushed by an earlier ldsfld. Replacing the callvirt with a bare
                        // ldc.r4 leaves that receiver on the stack and the method becomes
                        // invalid IL ("InvalidProgramException ... IL_02d2: ret"). Pop it first.
                        if (ins.OpCode == OpCodes.Callvirt)
                        {
                            ins.OpCode = OpCodes.Pop;
                            ins.Operand = null;
                            il2 = m.Body.GetILProcessor();
                            il2.InsertAfter(ins, il2.Create(OpCodes.Ldc_R4, val));
                        }
                        else
                        {
                            ins.OpCode = OpCodes.Ldc_R4;
                            ins.Operand = val;
                        }
                        n++;
                        Console.WriteLine($"    in {m.DeclaringType.Name}.{m.Name} at IL_{ins.Offset:x4}");
                    }
                }
                Console.WriteLine($"  callstoreconst {a[1]}.{a[2]} {a[3]}() -> {a[4]}f  ({n} site(s))");
                if (n == 0) failed++;
                applied += n;
                break;
            }
            case "scalearg":
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
            case "dropinit":
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
            case "storepop":
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
            case "branchalways":
            {
                // Find the first conditional branch that follows a call to <callName> inside
                // <Type>.<Method> and make it unconditional. Used to disable an inline
                // "if (x > y) x = y;" clamp that has no call to remove.
                var t = FindType(asm, a[1]);
                // a type can have several methods with the same name (overloads, or a nested
                // type's); pick the first that actually contains the call we are looking for.
                IList<Instruction> insns = null;
                int idx = -1;
                MethodDefinition chosen = null;
                var candidates = t.Methods.Where(x => x.Name == a[2] && x.HasBody).ToList();
                foreach (var cand in candidates)
                {
                    for (int k = 0; k < cand.Body.Instructions.Count; k++)
                    {
                        var ci = cand.Body.Instructions[k];
                        // instance methods compile to callvirt, not call
                        if ((ci.OpCode == OpCodes.Call || ci.OpCode == OpCodes.Callvirt) &&
                            ci.Operand is MethodReference cmr && cmr.Name == a[3])
                        { insns = cand.Body.Instructions; idx = k; chosen = cand; break; }
                    }
                    if (idx >= 0) break;
                }
                if (idx < 0)
                {
                    var all = AllTypes(asm.MainModule).Where(x => x.Name == a[1]).ToList();
                    throw new Exception($"no call to '{a[3]}' in any {a[1]}.{a[2]} ({candidates.Count} candidate(s), " +
                                        $"{all.Count} type(s) named {a[1]})");
                }
                bool done = false;
                for (int k = idx + 1; k < Math.Min(idx + 40, insns.Count) && !done; k++)
                {
                    var op = insns[k].OpCode;
                    // These all compare TWO values and POP BOTH. Swapping the opcode for an
                    // unconditional Br pops nothing, so the two values stayed on the stack and the
                    // method became invalid IL: "InvalidProgramException: Invalid IL code in
                    // BoostTimerManager:Update (): IL_00cb: ret", thrown once per frame (11070
                    // times in 80 seconds) and aborting the very feature the patch was for.
                    // Emit two pops first so the stack balances, then branch unconditionally.
                    bool cmp2 = op == OpCodes.Ble || op == OpCodes.Ble_S
                             || op == OpCodes.Bgt || op == OpCodes.Bgt_S
                             || op == OpCodes.Blt || op == OpCodes.Blt_S
                             || op == OpCodes.Bge || op == OpCodes.Bge_S;
                    if (!cmp2) continue;
                    var ilp = chosen.Body.GetILProcessor();
                    var target = insns[k].Operand;
                    ilp.InsertBefore(insns[k], Instruction.Create(OpCodes.Pop));
                    ilp.InsertBefore(insns[k], Instruction.Create(OpCodes.Pop));
                    insns[k].OpCode = OpCodes.Br;      // long form: always in range
                    insns[k].Operand = target;
                    done = true;
                }
                if (!done) throw new Exception($"no conditional branch found after call to '{a[3]}'");
                Console.WriteLine($"  branchalways {a[1]}.{a[2]} after {a[3]} -> unconditional"); applied++;
                break;
            }
            case "scaleret":
            {
                // Multiply the value a method is about to return. Used for the 5x tap bonus:
                // GameController.CalTap*Value return a BigDouble, so we splice in
                //   ldc.r8 <factor>; call BigDouble::op_Multiply(BigDouble, double)
                // immediately before every ret.
                var t = FindType(asm, a[1]);
                double factor = double.Parse(a[3], System.Globalization.CultureInfo.InvariantCulture);
                int n = 0;
                foreach (var m in t.Methods.Where(x => x.Name == a[2] && x.HasBody))
                {
                    var rt = m.ReturnType;
                    if (rt.MetadataType == MetadataType.Void) continue;
                    var il = m.Body.GetILProcessor();
                    // primitive numeric returns just need ldc + mul; anything else (BigDouble,
                    // a struct with an operator) needs the operator method.
                    bool primitive = rt.MetadataType == MetadataType.Double || rt.MetadataType == MetadataType.Single;
                    MethodReference mul = primitive ? null : FindMultiply(asm, resolver, rt);
                    if (!primitive && mul == null) throw new Exception($"no multiply operator found for return type {rt.FullName}");
                    foreach (var ret in m.Body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToList())
                    {
                        if (rt.MetadataType == MetadataType.Double)
                        {
                            il.InsertBefore(ret, il.Create(OpCodes.Ldc_R8, factor));
                            il.InsertBefore(ret, il.Create(OpCodes.Mul));
                        }
                        else if (rt.MetadataType == MetadataType.Single)
                        {
                            il.InsertBefore(ret, il.Create(OpCodes.Ldc_R4, (float)factor));
                            il.InsertBefore(ret, il.Create(OpCodes.Mul));
                        }
                        else if (mul.Parameters[0].ParameterType.IsByReference ||
                                 mul.Parameters[1].ParameterType.IsByReference)
                        {
                            // BigDouble::op_Multiply takes TWO REFERENCES, so pushing the return
                            // value plus a double and calling it emits nonsense IL. That produced
                            //   InvalidProgramException: Invalid IL code in
                            //   GameController:CalTapEvolutionValue (...): IL_0703: call
                            // which CRASHED THE GAME on the first background tap.
                            // Park the result in a fresh local, build the factor in a second local,
                            // then multiply through the two addresses.
                            var tRes = asm.MainModule.ImportReference(rt);
                            if (!m.Body.InitLocals) m.Body.InitLocals = true;
                            var vRes = new VariableDefinition(tRes);
                            var vFac = new VariableDefinition(tRes);
                            m.Body.Variables.Add(vRes);
                            m.Body.Variables.Add(vFac);
                            var imp = FindImplicit(asm, rt);
                            if (imp == null) throw new Exception($"no op_Implicit(double) for {rt.FullName}");
                            il.InsertBefore(ret, il.Create(OpCodes.Stloc, vRes));
                            il.InsertBefore(ret, il.Create(OpCodes.Ldloca, vRes));
                            il.InsertBefore(ret, il.Create(OpCodes.Ldc_R8, factor));
                            il.InsertBefore(ret, il.Create(OpCodes.Call, imp));
                            il.InsertBefore(ret, il.Create(OpCodes.Stloc, vFac));
                            il.InsertBefore(ret, il.Create(OpCodes.Ldloca, vFac));
                            il.InsertBefore(ret, il.Create(OpCodes.Call, mul));
                        }
                        else
                        {
                            il.InsertBefore(ret, il.Create(OpCodes.Ldc_R8, factor));
                            il.InsertBefore(ret, il.Create(OpCodes.Call, mul));
                        }
                        n++;
                    }
                }
                Console.WriteLine($"  scaleret {a[1]}.{a[2]} x{a[3]}  ({n} ret site(s))"); applied += n;
                break;
            }
            default:
                Console.Error.WriteLine($"  ?? unknown directive: {a[0]}"); failed++; break;
        }
    }
    catch (Exception e) { Console.Error.WriteLine($"  FAILED '{line}': {e.Message}"); failed++; }
}

asm.Write(outDll);
Console.WriteLine($"wrote {outDll} ({new FileInfo(outDll).Length} bytes), applied={applied} failed={failed}");
return failed == 0 ? 0 : 5;

// ---------------- helpers ----------------
static TypeDefinition FindType(AssemblyDefinition asm, string name)
    => asm.MainModule.GetType(name) ?? throw new Exception($"type '{name}' not found");

static MethodDefinition FindMethod(TypeDefinition t, string name)
{
    var m = t.Methods.FirstOrDefault(x => x.Name == name && x.HasBody);
    return m ?? throw new Exception($"method '{t.FullName}.{name}' not found or has no body");
}

static IEnumerable<MethodDefinition> Methods(AssemblyDefinition asm, string typeName, string methodName)
{
    IEnumerable<TypeDefinition> types = typeName == "*"
        ? AllTypes(asm.MainModule)
        : new[] { FindType(asm, typeName) };
    foreach (var t in types)
        foreach (var m in t.Methods)
            if (m.HasBody && (methodName == "*" || m.Name == methodName))
                yield return m;
}

static IEnumerable<TypeDefinition> AllTypes(ModuleDefinition mod)
{
    foreach (var t in mod.Types)
    {
        yield return t;
        foreach (var n in Nested(t)) yield return n;
    }
}
static IEnumerable<TypeDefinition> Nested(TypeDefinition t)
{
    foreach (var n in t.NestedTypes) { yield return n; foreach (var x in Nested(n)) yield return x; }
}

static MethodReference ResolveCall(AssemblyDefinition asm, IAssemblyResolver res, string asmName, string typeName, string methodName)
{
    AssemblyNameReference r = asm.MainModule.AssemblyReferences.FirstOrDefault(x => x.Name == asmName);
    if (r == null) { r = new AssemblyNameReference(asmName, new Version(0, 0, 0, 0)); asm.MainModule.AssemblyReferences.Add(r); }
    try
    {
        var def = res.Resolve(r);
        var ct = def.MainModule.GetType(typeName) ?? throw new Exception($"call type '{typeName}' not found in {asmName}");
        var cm = ct.Methods.FirstOrDefault(m => m.Name == methodName && m.Parameters.Count == 0 && m.IsStatic)
                 ?? throw new Exception($"call method '{typeName}.{methodName}()' not found");
        return asm.MainModule.ImportReference(cm);
    }
    catch (Exception e)
    {
        Console.WriteLine($"  note: resolving {asmName} failed ({e.Message}); using a synthetic reference");
        var declaring = new TypeReference("", typeName, asm.MainModule, r, false);
        return new MethodReference(methodName, asm.MainModule.TypeSystem.Void, declaring) { HasThis = false };
    }
}
static bool NeedRetarget(MethodDefinition m) => false;

// Find  T op_Multiply(T, double)  or  T op_Multiply(double, T)  on the return type.
static MethodReference FindImplicit(AssemblyDefinition asm, TypeReference rt)
{
    try
    {
        foreach (var m in rt.Resolve().Methods)
            if (m.Name == "op_Implicit" && m.IsStatic && m.Parameters.Count == 1 &&
                m.Parameters[0].ParameterType.MetadataType == MetadataType.Double &&
                m.ReturnType.FullName == rt.FullName)
                return asm.MainModule.ImportReference(m);
    }
    catch (Exception e) { Console.WriteLine($"  note: op_Implicit lookup for {rt.Name} failed: {e.Message}"); }
    return null;
}

static MethodReference FindMultiply(AssemblyDefinition asm, IAssemblyResolver res, TypeReference rt)
{
    try
    {
        var def = rt.Resolve();
        foreach (var m in def.Methods)
        {
            if (m.Name != "op_Multiply" || !m.IsStatic || m.Parameters.Count != 2) continue;
            var p0 = m.Parameters[0].ParameterType; var p1 = m.Parameters[1].ParameterType;
            bool a = p0.FullName == rt.FullName && p1.MetadataType == MetadataType.Double;
            bool b = p1.FullName == rt.FullName && p0.MetadataType == MetadataType.Double;
            if (a || b) return asm.MainModule.ImportReference(m);
        }
        foreach (var m in def.Methods)
            if (m.Name == "op_Multiply" && m.IsStatic && m.Parameters.Count == 2)
                return asm.MainModule.ImportReference(m);
    }
    catch (Exception e) { Console.WriteLine($"  note: resolving {rt.Name} failed: {e.Message}"); }
    return null;
}
