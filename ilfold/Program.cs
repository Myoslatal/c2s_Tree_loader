using System;
using System.Collections.Generic;
using System.Linq;
using Mono.Cecil;
using Mono.Cecil.Cil;

// Fold CustomEventPackPlugin INTO Assembly-CSharp so the mod ships as ONE dll.
//
// Why not ILRepack: ILRepack rebuilds the module by RE-IMPORTING every type of every input, and
// this game's Assembly-CSharp holds AscendReset/<TriggerAscensionRebootCR>d__31, whose body makes
// ILRepack's importer throw (Instruction.Create with a null branch target). That happens even
// when ILRepack is handed Assembly-CSharp ALONE, with no plugin at all, so it is not a tuning
// problem.
//
// This tool never re-imports an existing type. It APPENDS the plugin's types to the module that
// is already there, so every original game type is left untouched and a reference to a game type
// resolves to the definition already present in the module.
//
//   ilfold <mainDll> <pluginDll> <outDll> <searchDir>
internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Length < 4)
        {
            Console.Error.WriteLine("usage: ilfold <mainDll> <pluginDll> <outDll> <searchDir>");
            return 2;
        }
        var resolver = new DefaultAssemblyResolver();
        resolver.AddSearchDirectory(args[3]);

        var target = AssemblyDefinition.ReadAssembly(args[0], new ReaderParameters { AssemblyResolver = resolver });
        var plugin = AssemblyDefinition.ReadAssembly(args[1], new ReaderParameters { AssemblyResolver = resolver });

        new Folder(target, plugin).Run();
        target.Write(args[2]);

        Console.WriteLine("folded " + args[1] + " into " + args[0] + " -> " + args[2]);
        return 0;
    }
}

internal sealed class Folder
{
    private readonly ModuleDefinition tm;
    private readonly ModuleDefinition pm;
    private readonly Dictionary<TypeDefinition, TypeDefinition> _types = new();
    private readonly Dictionary<FieldDefinition, FieldDefinition> _fields = new();
    private readonly Dictionary<MethodDefinition, MethodDefinition> _methods = new();
    private readonly Dictionary<GenericParameter, GenericParameter> _gps = new();

    public Folder(AssemblyDefinition target, AssemblyDefinition plugin)
    {
        tm = target.MainModule;
        pm = plugin.MainModule;
    }

    public void Run()
    {
        foreach (var ar in pm.AssemblyReferences)
            if (ar.Name != pm.Assembly.Name.Name && !tm.AssemblyReferences.Any(x => x.Name == ar.Name))
                tm.AssemblyReferences.Add(ar);

        var all = pm.Types.Where(t => t.Name != "<Module>").SelectMany(WithNested).ToList();
        Console.WriteLine("plugin types to fold: " + all.Count);

        foreach (var t in all) Shell(t);       // 1 type shells
        foreach (var t in all) Head(t);        // 2 generic params, base type, interfaces
        foreach (var t in all) Members(t);     // 3 field/method shells
        foreach (var t in all) ImplMap(t);     // 3b explicit interface impls (.override / MethodImpl)
        foreach (var t in all) Accessors(t);   // 4 properties/events point at 3
        foreach (var t in all) Fill(t);        // 5 bodies
        foreach (var t in all) Attributes(t);  // 6 attributes last

        Console.WriteLine("folded " + all.Count + " types");

        // DO NOT strip the CustomEventPackPlugin assembly reference.
        // Folding the types in does not rewrite every scope: some metadata still points at the
        // plugin assembly, so removing the reference produces ~12000 TypeLoadExceptions and the
        // event never loads. It is harmless to KEEP it as long as CustomEventPackPlugin.dll sits
        // next to Assembly-CSharp in Managed/ - just do not list it in ScriptingAssemblies.json.
        // (The checker in _mod_tools/ilcheck cannot see this: it resolves references through the
        //  assembly resolver, so it happily finds the dll on disk and reports "0 unresolved".)
    }

    private static IEnumerable<TypeDefinition> WithNested(TypeDefinition t)
    {
        yield return t;
        foreach (var n in t.NestedTypes)
            foreach (var x in WithNested(n)) yield return x;
    }

    private void Shell(TypeDefinition src)
    {
        // The C# compiler emits helper types into EVERY assembly that needs them -
        // <PrivateImplementationDetails> for array initialiser blobs (plus its nested
        // __StaticArrayInitTypeSize=NN), Microsoft.CodeAnalysis.EmbeddedAttribute for init-only
        // setters, and so on. Folding therefore has to cope with a name that is already taken.
        // Renaming the outer type is enough: every reference goes through _types and is remapped.
        var name = UniqueName(src);

        var nt = new TypeDefinition(src.Namespace, name, src.Attributes)
        {
            ClassSize = src.ClassSize,
            PackingSize = src.PackingSize,
        };
        _types[src] = nt;
        if (src.IsNested) _types[src.DeclaringType].NestedTypes.Add(nt);
        else tm.Types.Add(nt);
    }

    /// <summary>src.Name, suffixed when the target module already owns that name.</summary>
    private string UniqueName(TypeDefinition src)
    {
        string suffix = "$" + pm.Assembly.Name.Name;
        if (src.IsNested)
        {
            var parent = _types[src.DeclaringType];
            return parent.NestedTypes.Any(x => x.Name == src.Name) ? src.Name + suffix : src.Name;
        }
        return tm.GetType(src.Namespace, src.Name) != null ? src.Name + suffix : src.Name;
    }

    private void Head(TypeDefinition src)
    {
        var dst = _types[src];
        foreach (var gp in src.GenericParameters)
        {
            var ngp = new GenericParameter(gp.Name, dst);
            _gps[gp] = ngp;
            dst.GenericParameters.Add(ngp);
        }
        dst.BaseType = ImportType(src.BaseType);
        foreach (var i in src.Interfaces)
            dst.Interfaces.Add(new InterfaceImplementation(ImportType(i.InterfaceType)));
    }

    private void Members(TypeDefinition src)
    {
        var dst = _types[src];

        foreach (var f in src.Fields)
        {
            var nf = new FieldDefinition(f.Name, f.Attributes, ImportType(f.FieldType));
            if (f.HasConstant) nf.Constant = f.Constant;
            dst.Fields.Add(nf);
            _fields[f] = nf;
        }

        foreach (var m in src.Methods)
        {
            // the return type may mention the method's OWN generic parameters, so those have to
            // exist before it can be imported
            var nm = new MethodDefinition(m.Name, m.Attributes, tm.TypeSystem.Void)
            {
                ImplAttributes = m.ImplAttributes,
                SemanticsAttributes = m.SemanticsAttributes,
            };
            dst.Methods.Add(nm);
            _methods[m] = nm;

            foreach (var gp in m.GenericParameters)
            {
                var ngp = new GenericParameter(gp.Name, nm);
                _gps[gp] = ngp;
                nm.GenericParameters.Add(ngp);
            }
            nm.ReturnType = ImportType(m.ReturnType);
            foreach (var p in m.Parameters)
                nm.Parameters.Add(new ParameterDefinition(p.Name, p.Attributes, ImportType(p.ParameterType)));
        }
    }

    /// <summary>
    /// Copy the MethodImpl table (Cecil's MethodDefinition.Overrides, the IL <c>.override</c>
    /// directive) - the base methods that a body EXPLICITLY implements.
    ///
    /// Without this every compiler-generated iterator/async state machine folds into a type the
    /// CLR refuses to load: such types realise IEnumerator/IEnumerator&lt;T&gt;/IDisposable almost
    /// entirely through explicit implementations (System.Collections.IEnumerator.get_Current,
    /// .Reset, System.IDisposable.Dispose), and if the MethodImpl row is missing the interface
    /// slot has no implementation to bind to and type loading dies with
    /// "VTable setup of type ... failed". That is exactly what broke &lt;SelfTest&gt;d__14 and
    /// &lt;PostLoadFixup&gt;d__42.
    ///
    /// This is a separate pass on purpose: a body may override a method that belongs to a plugin
    /// type folded later in the Members loop, so every method shell has to exist before the
    /// override targets can be resolved to their folded definitions.
    /// </summary>
    private void ImplMap(TypeDefinition src)
    {
        foreach (var m in src.Methods)
        {
            if (!m.HasOverrides) continue;
            var nm = _methods[m];
            foreach (var ov in m.Overrides)
                nm.Overrides.Add(ImportMethod(ov));
        }
    }

    private void Accessors(TypeDefinition src)
    {
        var dst = _types[src];
        foreach (var p in src.Properties)
        {
            var np = new PropertyDefinition(p.Name, p.Attributes, ImportType(p.PropertyType));
            if (p.GetMethod != null && _methods.TryGetValue(p.GetMethod, out var g)) np.GetMethod = g;
            if (p.SetMethod != null && _methods.TryGetValue(p.SetMethod, out var s)) np.SetMethod = s;
            foreach (var m in p.OtherMethods)
                if (_methods.TryGetValue(m, out var o)) np.OtherMethods.Add(o);
            dst.Properties.Add(np);
        }
        foreach (var e in src.Events)
        {
            var ne = new EventDefinition(e.Name, e.Attributes, ImportType(e.EventType));
            if (e.AddMethod != null && _methods.TryGetValue(e.AddMethod, out var a)) ne.AddMethod = a;
            if (e.RemoveMethod != null && _methods.TryGetValue(e.RemoveMethod, out var r)) ne.RemoveMethod = r;
            if (e.InvokeMethod != null && _methods.TryGetValue(e.InvokeMethod, out var i)) ne.InvokeMethod = i;
            dst.Events.Add(ne);
        }
    }

    private void Fill(TypeDefinition src)
    {
        foreach (var m in src.Methods)
        {
            if (!m.HasBody) continue;
            try { CloneBody(m, _methods[m]); }
            catch (Exception e) { Console.Error.WriteLine("BODY FAILED " + m.FullName + ": " + e); throw; }
        }
    }

    private void Attributes(TypeDefinition src)
    {
        CopyAttributes(src, _types[src]);
        foreach (var f in src.Fields) CopyAttributes(f, _fields[f]);
        foreach (var m in src.Methods) CopyAttributes(m, _methods[m]);
    }

    private void CloneBody(MethodDefinition src, MethodDefinition dst)
    {
        var sb = src.Body;
        var db = new MethodBody(dst) { InitLocals = sb.InitLocals, MaxStackSize = sb.MaxStackSize };

        var vmap = new Dictionary<VariableDefinition, VariableDefinition>();
        foreach (var v in sb.Variables)
        {
            var nv = new VariableDefinition(ImportType(v.VariableType));
            db.Variables.Add(nv);
            vmap[v] = nv;
        }

        var pmap = new Dictionary<ParameterDefinition, ParameterDefinition>();
        for (int i = 0; i < src.Parameters.Count && i < dst.Parameters.Count; i++)
            pmap[src.Parameters[i]] = dst.Parameters[i];

        // a branch cannot be created with a null target, so every instruction starts as a nop and
        // its opcode/operand are filled in afterwards - the exact step ILRepack gets wrong
        var imap = new Dictionary<Instruction, Instruction>();
        foreach (var ins in sb.Instructions)
        {
            var ni = Instruction.Create(OpCodes.Nop);
            imap[ins] = ni;
            db.Instructions.Add(ni);
        }
        for (int i = 0; i < sb.Instructions.Count; i++)
        {
            var s = sb.Instructions[i];
            var d = db.Instructions[i];
            d.OpCode = s.OpCode;
            d.Operand = ImportOperand(s.Operand, imap, vmap, pmap);
        }

        foreach (var h in sb.ExceptionHandlers)
        {
            db.ExceptionHandlers.Add(new ExceptionHandler(h.HandlerType)
            {
                TryStart = Map(h.TryStart, imap),
                TryEnd = Map(h.TryEnd, imap),
                HandlerStart = Map(h.HandlerStart, imap),
                HandlerEnd = Map(h.HandlerEnd, imap),
                FilterStart = Map(h.FilterStart, imap),
                CatchType = ImportType(h.CatchType),
            });
        }

        dst.Body = db;
    }

    private static Instruction Map(Instruction i, Dictionary<Instruction, Instruction> imap)
        => i == null ? null : imap[i];

    private object ImportOperand(object op, Dictionary<Instruction, Instruction> imap,
        Dictionary<VariableDefinition, VariableDefinition> vmap,
        Dictionary<ParameterDefinition, ParameterDefinition> pmap)
    {
        switch (op)
        {
            case null: return null;
            case Instruction i:
                if (!imap.TryGetValue(i, out var ni)) throw new InvalidOperationException("unmapped branch target: " + i);
                return ni;
            case Instruction[] arr:
                return arr.Select(x => imap.TryGetValue(x, out var t2)
                    ? t2 : throw new InvalidOperationException("unmapped switch target: " + x)).ToArray();
            case VariableDefinition v:
                if (!vmap.TryGetValue(v, out var nv)) throw new InvalidOperationException("unmapped variable: " + v);
                return nv;
            case ParameterDefinition p: return pmap.TryGetValue(p, out var np) ? np : p;
            case TypeReference t: return ImportType(t);
            case MethodReference m: return ImportMethod(m);
            case FieldReference f: return ImportField(f);
            default: return op;
        }
    }

    private TypeReference ImportType(TypeReference tr)
    {
        if (tr == null) return null;
        if (tr is GenericParameter gp)
            return _gps.TryGetValue(gp, out var ngp) ? ngp : tm.ImportReference(tr);
        if (tr is ArrayType at) return new ArrayType(ImportType(at.ElementType), at.Rank);
        if (tr is ByReferenceType bt) return new ByReferenceType(ImportType(bt.ElementType));
        if (tr is PointerType pt) return new PointerType(ImportType(pt.ElementType));
        if (tr is PinnedType pin) return new PinnedType(ImportType(pin.ElementType));
        if (tr is SentinelType sen) return new SentinelType(ImportType(sen.ElementType));
        if (tr is OptionalModifierType om) return new OptionalModifierType(ImportType(om.ModifierType), ImportType(om.ElementType));
        if (tr is RequiredModifierType rm) return new RequiredModifierType(ImportType(rm.ModifierType), ImportType(rm.ElementType));
        if (tr is GenericInstanceType git)
        {
            var ng = new GenericInstanceType(ImportType(git.ElementType));
            foreach (var a in git.GenericArguments) ng.GenericArguments.Add(ImportType(a));
            return ng;
        }
        if (Resolve(tr) is TypeDefinition td && _types.TryGetValue(td, out var mapped)) return mapped;
        return tm.ImportReference(tr);
    }

    private MethodReference ImportMethod(MethodReference mr)
    {
        if (mr == null) return null;

        // a method we folded: point straight at the new definition so nothing keeps referring to
        // the plugin assembly
        if (Resolve(mr) is MethodDefinition md && _methods.TryGetValue(md, out var mapped))
        {
            if (mr is GenericInstanceMethod gim)
            {
                var gi = new GenericInstanceMethod(mapped);
                foreach (var a in gim.GenericArguments) gi.GenericArguments.Add(ImportType(a));
                return gi;
            }
            return mapped;
        }

        // An EXTERNAL method (UnityEngine / BCL / the game). Let Cecil import it: it needs to see
        // the original generic context to rewrite things like GameObject::AddComponent<!!0>, and
        // hand-building that reference is what produced a NullReferenceException inside
        // ImportGenericContext.MethodParameter. Only the two places that could still mention the
        // plugin are patched afterwards.
        // An INSTANTIATED external generic method (Enum.TryParse<T>, Enumerable.Select<T>, ...).
        // Importing the instance directly makes Cecil rewrite a generic argument that is one of
        // the plugin's own !!0 parameters, and it blows up in ImportGenericContext.MethodParameter
        // because the owning method is not part of the target module. Importing the generic method
        // DEFINITION is safe, so the instance is rebuilt here with arguments imported by hand.
        if (mr is GenericInstanceMethod srcGi)
        {
            var elem = tm.ImportReference(srcGi.ElementMethod);
            if (elem is MethodDefinition) return elem.IsGenericInstance ? elem : elem;
            var gi = new GenericInstanceMethod(elem);
            foreach (var a in srcGi.GenericArguments) gi.GenericArguments.Add(ImportType(a));
            return gi;
        }

        var imported = tm.ImportReference(mr);

        // a method that already lives in this module comes back as its own MethodDefinition, and
        // assigning DeclaringType on a definition throws InvalidOperationException
        if (imported is MethodDefinition) return imported;

        if (imported.GetType() == typeof(MethodReference))
            imported.DeclaringType = ImportType(mr.DeclaringType);
        return imported;
    }

    private FieldReference ImportField(FieldReference fr)
    {
        if (fr == null) return null;
        if (Resolve(fr) is FieldDefinition fd && _fields.TryGetValue(fd, out var mapped)) return mapped;
        var imported = tm.ImportReference(fr);
        if (imported is FieldDefinition) return imported;
        if (imported.GetType() == typeof(FieldReference)) imported.DeclaringType = ImportType(fr.DeclaringType);
        return imported;
    }

    private static TypeDefinition Resolve(TypeReference tr)
    {
        try { return tr.Resolve(); } catch { return null; }
    }

    private static MethodDefinition Resolve(MethodReference mr)
    {
        try { return mr.Resolve(); } catch { return null; }
    }

    private static FieldDefinition Resolve(FieldReference fr)
    {
        try { return fr.Resolve(); } catch { return null; }
    }

    private void CopyAttributes(ICustomAttributeProvider src, ICustomAttributeProvider dst)
    {
        if (!src.HasCustomAttributes) return;
        foreach (var ca in src.CustomAttributes)
        {
            try
            {
                var ctor = ImportMethod(ca.Constructor);
                if (ctor == null) continue;
                var nca = new CustomAttribute(ctor);
                foreach (var a in ca.ConstructorArguments) nca.ConstructorArguments.Add(ImportArg(a));
                foreach (var f in ca.Fields) nca.Fields.Add(new CustomAttributeNamedArgument(f.Name, ImportArg(f.Argument)));
                foreach (var p in ca.Properties) nca.Properties.Add(new CustomAttributeNamedArgument(p.Name, ImportArg(p.Argument)));
                dst.CustomAttributes.Add(nca);
            }
            catch
            {
                // an attribute that cannot be re-imported is not worth failing the fold for
            }
        }
    }

    private CustomAttributeArgument ImportArg(CustomAttributeArgument a)
    {
        var t = ImportType(a.Type);
        if (a.Value is CustomAttributeArgument[] arr)
            return new CustomAttributeArgument(t, arr.Select(ImportArg).ToArray());
        if (a.Value is TypeReference tr)
            return new CustomAttributeArgument(t, ImportType(tr));
        return new CustomAttributeArgument(t, a.Value);
    }
}
