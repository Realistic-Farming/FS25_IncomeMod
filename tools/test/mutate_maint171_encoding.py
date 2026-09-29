# IncomeMod MAINTENANCE row 171 mutation battery (targeted tier): the modDesc.xml
# encoding repair. Rows live in MAINT-171-moddesc_encoding_test.lua. Each mutation puts
# one defect of the class back into the shipped file; the bar must fail on it.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_maint171_encoding.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

MOD = "modDesc.xml"

MUTATIONS = [
 ("E1-one-string-left-unfixed", MOD,
  [("<de><![CDATA[Täglich]]></de>", "<de><![CDATA[T├â┬ñglich]]></de>", 1)],
  "the German pay-mode label still reads as box-drawing mojibake"),
 ("E2-one-em-dash-left-in", MOD,
  [("<en><![CDATA[Income Mod: Overview]]></en>", "<en><![CDATA[Income Mod — Overview]]></en>", 1)],
  "a restored help title keeps its em dash"),
 ("E3-half-repaired-value", MOD,
  [("<de><![CDATA[Täglich]]></de>", "<de><![CDATA[TÃ¤glich]]></de>", 1)],
  "the cp850 layer is undone but the cp1252 layer is left"),
 ("E4-an-R17-string-moved", MOD,
  [("<en><![CDATA[Income schedule]]></en>", "<en><![CDATA[Income Schedule]]></en>", 1)],
  "the repair touched an already-correct R17 string"),
 ("E6-half-repaired-Cyrillic", MOD,
  [("<ru><![CDATA[Ежедневно]]></ru>", "<ru><![CDATA[Ð•Ð¶ÐµÐ´Ð½ÐµÐ²Ð½Ð¾]]></ru>", 1)],
  "a Russian value keeps its cp1252 layer"),
 ("E7-title-back-to-another-mods-name", MOD,
  [("    <title>\n        <en><![CDATA[Income Mod]]></en>\n        <de><![CDATA[Einkommens-Mod]]></de>\n", "    <title>\n        <en><![CDATA[Income Mod]]></en>\n        <de><![CDATA[Realistisches Ernten]]></de>\n", 1)],
  "the German mod title names another mod again"),
 ("E5-a-language-entry-dropped", MOD,
  [("            <da><![CDATA[Dagligt]]></da>\n", "", 1)],
  "the repair lost a language entry"),
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
