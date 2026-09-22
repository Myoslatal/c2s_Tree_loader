P = "_mod_tools/launch_modded.sh"
t = open(P, encoding="utf-8").read()
start = t.index("# ---- 1b. merge the plugin INTO the patched assembly ----")
end = t.index('  echo "[launcher] WARNING: $PLUGIN or ILRepack missing - plugin NOT embedded"\nfi') + len('  echo "[launcher] WARNING: $PLUGIN or ILRepack missing - plugin NOT embedded"\nfi')
block = t[start:end]
commented = "\n".join(("# " + l) if l.strip() else l for l in block.split("\n"))
note = """# ---- 1b. DISABLED: merging the plugin into Assembly-CSharp ----
# The merge itself works (ILRepack embeds all 36 CustomEventPack types and the result has no
# reference to the plugin assembly), but Unity never invoked Bootstrap.Install afterwards:
# the game ran to completion with ZERO "[CustomEventPack]" lines in Player.log. The merged
# Assembly-CSharp also decompiles with "Unknown result type" inside Install(), so the merge
# leaves dangling references. Until that is understood, ship the two-dll layout, which is
# verified working.
#"""
t = t[:start] + note + commented + t[end:]
open(P, "w", encoding="utf-8").write(t)
print("merge step disabled in the launcher")