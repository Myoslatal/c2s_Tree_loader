p = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
src = open(p, encoding="utf-8").read().split("\n")

# 1-indexed 1384..1492 -> 0-indexed 1383..1491
a, b = 1383, 1491
assert "internal static void ApplyEventBackground" in src[a], src[a]
assert src[b].strip() == "}", src[b]
body = src[1391:1489]          # lines 1392..1489 verbatim (the surviving Tick body)
assert "EVENT BACKDROP" in body[0], body[0]
assert "hook BIG MR" in "\n".join(body), "tail missing"

head = [
'        /// <summary>',
'        /// Applies the pack background to the EVENT SCENE.',
'        ///',
'        /// Intentionally a no-op: the real work happens in PatchHooks.Tick, which the launch-time',
'        /// IL patch injects into EventController.Update and therefore runs inside the game frame',
'        /// loop. Calling it from the load path ran too early - the backdrop object does not exist',
'        /// until after the intro cutscene.',
'        /// </summary>',
'        internal static void ApplyEventBackground(Pack pack)',
'        {',
'            // no-op - see PatchHooks.Tick',
'        }',
'    }',
'',
'    /// <summary>',
'    /// Entry points called by the launch-time IL patch (see _mod_tools/patcher, patches.txt).',
'    /// </summary>',
'    public static class PatchHooks',
'    {',
'        private static int _ticks;',
'        private static bool _backdropSeen;   // the tree backdrop exists (tree view is up)',
'        private static int _bgAt;',
'        private static bool _bgApplied;',
'',
'        /// <summary>Replaces UIQualitySettings.SetGraphicsQuality(): unlock the framerate.</summary>',
'        public static void UnlockFramerate()',
'        {',
'            try',
'            {',
'                QualitySettings.SetQualityLevel(1, true);',
'                QualitySettings.vSyncCount = 0;',
'                Application.targetFrameRate = -1;',
'                Log.Info("patch hook: framerate unlocked (vSync=0, targetFrameRate=-1)");',
'            }',
'            catch (Exception e) { Log.Error("UnlockFramerate", e); }',
'        }',
'',
'        /// <summary>Injected at the start of EventController.Update().</summary>',
'        public static void Tick()',
'        {',
'            _ticks++;',
'            if (_ticks < 240) return;      // wait for the scene to come up',
]
tail = [
'        }',
'    }',
]
out = src[:a] + head + body + tail + src[b+1:]
open(p, "w", encoding="utf-8").write("\n".join(out))
print("rebuilt; file now", len(out), "lines")
