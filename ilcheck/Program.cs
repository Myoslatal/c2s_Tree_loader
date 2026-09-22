using System;
using System.Collections.Generic;
using System.Linq;
using Mono.Cecil;

// Resolve every type/member reference in an assembly and report the ones that cannot be
// resolved, plus any duplicated type full names. Used to find what ILRepack left dangling
// when it merged CustomEventPackPlugin into Assembly-CSharp.
//   ilcheck <assembly> <searchDir> [nameFilter]
internal static class Program
{
    private static int Main(string[] args)
    {
        // "ildump" reuses this binary to inspect a single type
        if (args.Length >= 2 && args[0] == "--dump") return Dump.Run(new[] { args[1], args[2] });

        var asm = AssemblyDefinition.ReadAssembly(args[0], new ReaderParameters
        {
            AssemblyResolver = BuildResolver(args[1]),
            ReadSymbols = false,
        });

        Console.WriteLine("ASSEMBLY REFERENCES of " + asm.Name.Name + ":");
        foreach (var ar in asm.MainModule.AssemblyReferences)
            Console.WriteLine("   " + ar.Name + " " + ar.Version);

        // duplicate full names would make Unity's type lookup ambiguous
        var seen = new Dictionary<string, int>();
        foreach (var t in AllTypes(asm.MainModule))
        {
            seen.TryGetValue(t.FullName, out int c);
            seen[t.FullName] = c + 1;
        }
        foreach (var kv in seen.Where(k => k.Value > 1))
            Console.WriteLine("DUPLICATE TYPE: " + kv.Key + " x" + kv.Value);

        string filter = args.Length > 2 ? args[2] : null;
        int bad = 0, total = 0;
        foreach (var t in AllTypes(asm.MainModule))
        {
            foreach (var m in t.Methods.Where(x => x.HasBody))
            {
                foreach (var ins in m.Body.Instructions)
                {
                    if (!(ins.Operand is TypeReference tr)) continue;
                    // generic parameters are TypeReferences too, but they are not resolvable
                    // and are NOT a defect - skipping them removes all the false positives
                    if (tr is GenericParameter) continue;
                    if (filter != null && !tr.FullName.Contains(filter) && !m.FullName.Contains(filter)) continue;
                    total++;
                    try
                    {
                        var r = tr.Resolve();
                        if (r == null) { Console.WriteLine("UNRESOLVED TYPE  " + tr.FullName + "  in " + m.FullName); bad++; }
                    }
                    catch (Exception e)
                    {
                        Console.WriteLine("UNRESOLVED TYPE  " + tr.FullName + "  in " + m.FullName + "  (" + e.GetType().Name + " " + e.Message + ")"); bad++;
                    }
                }
            }
        }
        Console.WriteLine("checked " + total + " type reference(s), " + bad + " unresolved");
        return bad == 0 ? 0 : 1;
    }

    private static IEnumerable<TypeDefinition> AllTypes(ModuleDefinition m)
    {
        foreach (var t in m.Types)
        {
            yield return t;
            foreach (var n in Nested(t)) yield return n;
        }
    }

    private static IEnumerable<TypeDefinition> Nested(TypeDefinition t)
    {
        foreach (var n in t.NestedTypes)
        {
            yield return n;
            foreach (var x in Nested(n)) yield return x;
        }
    }

    private static DefaultAssemblyResolver BuildResolver(string dir)
    {
        var r = new DefaultAssemblyResolver();
        r.AddSearchDirectory(dir);
        r.AddSearchDirectory("/home/forin/.nuget/packages/mono.cecil/0.11.4/lib/netstandard2.0");
        return r;
    }
}
