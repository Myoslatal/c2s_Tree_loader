P = "_mod_tools/patches.txt"
t = open(P, encoding="utf-8").read()

# nanobot: zeroing GetNanobotResetTimer_Seconds also clamps the ACTIVE timer to 0
old = "retconst    NanobotUpgradeStats GetNanobotResetTimer_Seconds 0"
assert t.count(old) == 1
t = t.replace(old, """# REMOVED - it broke the very feature it targeted. BoostTimerManager.Update uses
# GetNanobotResetTimer_Seconds() BOTH as the cooldown length AND as the clamp for the
# ACTIVE timer ("if (timer > reset) timer = reset"), so returning 0 made every nanobot
# boost end the instant it started: the reported "nanobot working time is 0".
# retconst    NanobotUpgradeStats GetNanobotResetTimer_Seconds 0""")

# time capsule: keep the calls, drop only the two time zeroings
old2 = "removecall * * TimeManager ResetSimTimer"
assert t.count(old2) == 1
t = t.replace(old2, """# REMOVED - deleting the CALL also skipped the private singInfo / bSingRunComplete
# resets that ResetSimTimer performs, which hung the game on "reset main simulation".
# Drop only the two time-capsule assignments instead.
# removecall * * TimeManager ResetSimTimer
dropinit    TimeManager ResetSimTimer totalTimeCurSim
dropinit    TimeManager ResetSimTimer offlineTimeCurSim""")

# 5x tap: the return value is DISCARDED by every caller
for m in ["CalTapEvolutionValue", "CalTapIdeaValue", "CalTapDinoValue", "CalTapSciValue"]:
    line = "scaleret    GameController %s 5" % m
    assert t.count(line) == 1, line
    t = t.replace(line, "# REMOVED - the callers discard the return value; the payout is applied by\n# CalTap*Value's own side effects on Calculator.bank / clickValuePerSec.\n# scaleret    GameController %s 5" % m)

t = t.rstrip("\n") + """

# mod 2 (corrected) - every tap is worth 5.
# CalTap*Value(sc) multiplies by its 'sc' argument; every tap site passes 10.0 and
# DISCARDS the return value, so scaling the return (the old 'scaleret') did nothing.
# Scale the argument instead.
const       Assistant TapMove 10.0 50.0
const       Assistant FindCurrencyPayout 10.0 50.0
"""
open(P, "w", encoding="utf-8").write(t)
print("patches.txt rewritten")
