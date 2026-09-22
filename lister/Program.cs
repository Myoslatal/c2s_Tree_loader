using Mono.Cecil;
using System;
using System.Linq;
var asm=AssemblyDefinition.ReadAssembly(args[0], new ReaderParameters{});
var t=asm.MainModule.Types.FirstOrDefault(x=>x.FullName==args[1]);
if(t==null){ Console.WriteLine("TYPE NOT FOUND: "+args[1]); return; }
Console.WriteLine("TYPE "+t.FullName);
Console.WriteLine("-- methods --");
foreach(var m in t.Methods) Console.WriteLine((m.IsPublic?"pub ":"")+(m.IsStatic?"static ":"")+m.ReturnType.Name+" "+m.Name+"("+string.Join(", ", m.Parameters.Select(p=>p.ParameterType.Name+" "+p.Name))+")");
Console.WriteLine("-- properties --");
foreach(var p in t.Properties) Console.WriteLine((p.GetMethod?.IsPublic==true?"pub ":"")+"get "+p.PropertyType.Name+" "+p.Name+" set="+(p.SetMethod?.IsPublic==true));
Console.WriteLine("-- fields --");
foreach(var f in t.Fields) Console.WriteLine((f.IsPublic?"pub ":"")+(f.IsStatic?"static ":"")+f.FieldType.Name+" "+f.Name);
