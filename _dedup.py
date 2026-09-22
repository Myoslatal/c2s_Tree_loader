P = "_mod_tools/ilfold/Program.cs"
t = open(P, encoding="utf-8").read()

# replace the <PrivateImplementationDetails>-only rename with a general collision check
start = t.index("        // The C# compiler emits <PrivateImplementationDetails>")
end = t.index("            : src.Name;") + len("            : src.Name;")
old_block = t[start:end]
new_block = """        // The C# compiler emits helper types into EVERY assembly that needs them -
        // <PrivateImplementationDetails> for array initialiser blobs (plus its nested
        // __StaticArrayInitTypeSize=NN), Microsoft.CodeAnalysis.EmbeddedAttribute for init-only
        // setters, and so on. Folding therefore has to cope with a name that is already taken.
        // Renaming the outer type is enough: every reference goes through _types and is remapped.
        var name = UniqueName(src);"""
t = t[:start] + new_block + t[end:]

helper = """    /// <summary>src.Name, suffixed when the target module already owns that name.</summary>
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

    private void Head(TypeDefinition src)"""
assert t.count("    private void Head(TypeDefinition src)") == 1
t = t.replace("    private void Head(TypeDefinition src)", helper)
open(P, "w", encoding="utf-8").write(t)
print("OK: UniqueName wired into Shell")