# IncomeMod RSF-F282 mutation battery: the backwards-clock guard in
# src/IncomeSystem.lua. Rows live in RSF-F282-backwards_clock_test.lua.
#
# SEPARATE FILE ON PURPOSE: each item's battery belongs to its own work.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the lastHour range test (0..23) inside isClockRewound: an uninitialized marker
#     is -1, and no environment hour is below -1, so removing the test reads the same
#     on every bar; it guards a corrupted state file, which the bar does not model.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_f282.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

IS = "src/IncomeSystem.lua"

MUTATIONS = [
 ("F1-rewind-never-detected", IS,
  [("    if monoDay == nil or self.lastMonotonicDay < 0 then\n        return false\n    end\n    if monoDay < self.lastMonotonicDay then",
    "    if monoDay == nil or self.lastMonotonicDay < 0 then\n        return false\n    end\n    if true then return false end\n    if monoDay < self.lastMonotonicDay then", 1)],
  "a same-day rewind pays fourteen hours again"),
 ("F2-same-day-test-removed", IS,
  [("    return monoDay == self.lastMonotonicDay and self.lastHour >= 0 and self.lastHour <= 23 and env.currentHour < self.lastHour",
    "    return false", 1)],
  "only a lower monotonic day counts as a rewind; the console setter's same-day set pays"),
 ("F3-lower-day-test-removed", IS,
  [("    if monoDay < self.lastMonotonicDay then\n        return true\n    end\n", "", 1)],
  "persisted markers ahead of the clock are paid as elapsed time"),
 ("F4-forward-midnight-read-as-rewind", IS,
  [("    return monoDay == self.lastMonotonicDay and self.lastHour >= 0", "    return monoDay >= self.lastMonotonicDay and self.lastHour >= 0", 1)],
  "a genuine midnight crossing (hour 23 to 0, day up) is refused"),
 ("F5-markers-not-rebaselined", IS,
  [("    self.lastHour         = env.currentHour\n    self.lastDay          = env.currentDay\n    self.lastMonotonicDay = env.currentMonotonicDay\nend", "end", 1)],
  "the stale marker stays, so the next hour pays a span measured from a position the clock left"),
 ("F6-hourly-guard-pays-anyway", IS,
  [("            self:rebaselineAfterRewind(env, \"hourly\")\n            return false\n", "            self:rebaselineAfterRewind(env, \"hourly\")\n", 1)],
  "the hourly check re-baselines and then pays the rewound span"),
 ("F7-daily-guard-removed", IS,
  [("        if self:isClockRewound(env) then\n            self:rebaselineAfterRewind(env, \"daily\")\n            return false\n        end\n", "", 1)],
  "daily mode pays on markers ahead of the clock"),
 ("F8-hourly-guard-removed", IS,
  [("        if self:isClockRewound(env) then\n            self:rebaselineAfterRewind(env, \"hourly\")\n            return false\n        end\n", "", 1)],
  "hourly mode pays on a rewind"),
 ("F9-rewind-not-logged", IS,
  [("    Logging.info(\"[Income Mod] Clock moved backwards (%s check): Day %d[%d] Hour %d back to Day %d[%d] Hour %d; nothing settled, markers re-baselined\",\n        tostring(mode), self.lastDay, self.lastMonotonicDay, self.lastHour, env.currentDay, env.currentMonotonicDay, env.currentHour)\n", "", 1)],
  "a developer who rewinds the clock sees nothing"),
 ("F10-rewind-guard-without-counter", IS,
  [("    if monoDay == nil or self.lastMonotonicDay < 0 then\n        return false\n    end\n    if monoDay < self.lastMonotonicDay then",
    "    if monoDay == nil then return env.currentHour < self.lastHour end\n    if self.lastMonotonicDay < 0 then\n        return false\n    end\n    if monoDay < self.lastMonotonicDay then", 1)],
  "without the counter a midnight wrap is refused as a rewind (the modulo path the brief keeps)"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip()
                       .encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if "FAIL" in l and "assertions passed" not in l]
    crashes = [strip(l) for l in out.splitlines() if "Lua error while loading/running" in l]
    return r.returncode, fails, crashes


only = sys.argv[1:]
rc, fails, crashes = run_suite()
if rc != 0:
    print("BASELINE IS NOT GREEN; fix that before trusting any mutation result.")
    for l in fails[:10]:
        print("   " + l)
    sys.exit(2)
print("baseline green")

killed, crashkills, survived, badedit = [], [], [], []

for mid, rel, edits, why in MUTATIONS:
    if only and not any(mid.startswith(o) for o in only):
        continue
    path = p(rel)
    with open(path, "rb") as f:
        original = f.read()
    crlf = b"\r\n" in original
    enc = lambda s: (s.replace("\n", "\r\n") if crlf else s).encode("utf-8")

    ok, mutated = True, original
    for old, new, want in edits:
        ob, nb = enc(old), enc(new)
        n = mutated.count(ob)
        if n != want:
            badedit.append((mid, "anchor matched %dx, expected %d" % (n, want)))
            print("  !! %s: ANCHOR MISMATCH (%d != %d), mutation NOT applied" % (mid, n, want))
            ok = False
            break
        mutated = mutated.replace(ob, nb, want)
    if not ok:
        continue

    with open(path, "wb") as f:
        f.write(mutated)
    with open(path, "rb") as f:
        landed = f.read()
    if landed == original or landed != mutated:
        with open(path, "wb") as f:
            f.write(original)
        badedit.append((mid, "edit did not land"))
        print("  !! %s: EDIT DID NOT LAND" % mid)
        continue

    try:
        rc, fails, crashes = run_suite()
    finally:
        with open(path, "wb") as f:
            f.write(original)
    with open(path, "rb") as f:
        if sha(f.read()) != sha(original):
            print("  !! %s: RESTORE FAILED, stopping" % mid)
            sys.exit(3)

    named = [l for l in fails if l.startswith("FAIL ")]
    if rc != 0:
        killed.append(mid)
        tag = "KILLED  "
        if crashes and not named:
            crashkills.append(mid)
            tag = "KILLED* "
    else:
        survived.append((mid, why))
        tag = "SURVIVED"
    print("  %s %s  [%s]" % (tag, mid, rel))
    print("        (%s)" % why)
    for l in named[:4]:
        print("        " + l[:170])
    for l in crashes[:2]:
        print("        CRASH " + l[:170])

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (len(killed), len(crashkills)))
print("survived %d" % len(survived))
print("bad edit %d" % len(badedit))
for mid, why in survived:
    print("--- SURVIVED %s: %s" % (mid, why))
for mid, msg in badedit:
    print("--- BAD EDIT %s: %s" % (mid, msg))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
