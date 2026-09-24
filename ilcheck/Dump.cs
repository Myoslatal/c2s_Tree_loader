using System;
using System.Linq;
using Mono.Cecil;

// Dump one type's interfaces and method signatures, so a folded type can be diffed against the
// original.   ildump <assembly> <typeFullName>
internal static class Dump
{
    public static int Run(string[] args)
    {
        var resolver = new DefaultAssemblyResolver();
        resolver.AddSearchDirectory(System.IO.Path.GetDirectoryName(args[0]));
        resolver.AddSearchDirectory("Managed");
        var asm = AssemblyDefinition.ReadAssembly(args[0], new ReaderParameters { AssemblyResolver = resolver });

        foreach (var t in All(asm.MainModule).Where(t => t.FullName == args[1]))
        {
            Console.WriteLine("TYPE " + t.FullName);
            Console.WriteLine("  attrs   : " + t.Attributes);
            Console.WriteLine("  base    : " + (t.BaseType == null ? "<null>" : t.BaseType.FullName));
            Console.WriteLine("  classSize=" + t.ClassSize + " packingSize=" + t.PackingSize);
            foreach (var i in t.Interfaces)
                Console.WriteLine("  IFACE   : " + i.InterfaceType.FullName);
            foreach (var f in t.Fields)
                Console.WriteLine("  FIELD   : " + f.FieldType.FullName + " " + f.Name);
            foreach (var m in t.Methods)
            {
                Console.WriteLine("  METHOD  : " + m.ReturnType.FullName + " " + m.Name +
                    "(" + string.Join(",", m.Parameters.Select(p => p.ParameterType.FullName)) + ")" +
                    " attrs=" + m.Attributes + " impl=" + m.ImplAttributes);

                // 3rd argument: dump this method's IL body. Used to check WHERE an injected
                // call actually landed and how many rets the method has - an appendcall that
                // targets the last ret is useless if that ret sits on a cold branch.
                if (args.Length < 3 || args[2] != m.Name || !m.HasBody) continue;
                Console.WriteLine("    IL    : maxStack=" + m.Body.MaxStackSize +
                    " locals=" + m.Body.Variables.Count + " instrs=" + m.Body.Instructions.Count);
                foreach (var ins in m.Body.Instructions)
                {
                    string mark = (ins.OpCode.Name == "ret") ? "   <== RET" :
                        (ins.OpCode.Name == "call" || ins.OpCode.Name == "callvirt") ? "   <== CALL" : "";
                    Console.WriteLine("      " + ins.Offset.ToString("X4") + ": " +
                        ins.OpCode.Name.PadRight(10) + " " +
                        (ins.Operand == null ? "" : ins.Operand.ToString()) + mark);
                }
                int rets = m.Body.Instructions.Count(i => i.OpCode.Name == "ret");
                Console.WriteLine("    RET COUNT = " + rets);
            }
        }
        return 0;
    }

    private static System.Collections.Generic.IEnumerable<TypeDefinition> All(ModuleDefinition m)
    {
        foreach (var t in m.Types)
        {
            yield return t;
            foreach (var n in Nested(t)) yield return n;
        }
    }

    private static System.Collections.Generic.IEnumerable<TypeDefinition> Nested(TypeDefinition t)
    {
        foreach (var n in t.NestedTypes)
        {
            yield return n;
            foreach (var x in Nested(n)) yield return x;
        }
    }
}
