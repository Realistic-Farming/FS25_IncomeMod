# IncomeMod IM-6 PR B mutation battery: the readers and the gated typed amount control.
# Rows live in IM6-B-readers_test.lua (the reader bar) and IM6-l10n_test.lua.
#
# SEPARATE FILE ON PURPOSE: each item's battery belongs to its own work. PR A's battery,
# mutate_im6_host_authority.py, must stay green on this head too (its V1 anchor follows
# this PR's DISABLED-first state order).
#
# The brief's reader clauses (3.6) and the typed control (3.4, gated by 3.7):
#   R  a reader shows this machine's own settings instead of the host's view
#   S  a reader names a season
#   G  the explanation or the typed control shows while the gate is LOCKED, or the gate
#      opens on an unreadable opt-in
#   V  the view loses a reader field, or an unknown month is shown as a figure
#   T  the typed control applies without confirm, lets a non-admin edit, or lowers a
#      legacy amount unasked
#   L  a new string loses a language
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_im6_readers.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SCH = "src/IncomeSchedule.lua"
HUD = "src/ui/IncomeHUD.lua"
REP = "src/ui/IncomeReportDialog.lua"
PDA = "src/gui/ImRfPdaGuest.lua"
UI = "src/settings/SettingsUI.lua"
MOD = "modDesc.xml"

MUTATIONS = [
 # ── R: a reader reads local settings ────────────────────────────────────────
 ("R1-HUD-reads-local-settings", HUD,
  [("    local s   = IncomeSchedule.readerSettings(view)\n", "    local s   = self.settings\n", 1)],
  "the HUD shows a client's own defaults as the host's schedule"),
 ("R2-HUD-next-from-local-mode", HUD,
  [("    if s == nil or s.enabled ~= true then return \"--\" end\n", "    s = self.settings\n", 1)],
  "the HUD's next payment follows the client's own pay mode"),
 ("R3-report-reads-local-settings", REP,
  [("    local s = IncomeSchedule.readerSettings(view)\n", "    local s = g_IncomeManager and g_IncomeManager.settings\n", 1)],
  "the report's summary is the client's own settings"),
 ("R4-report-next-from-local-system", REP,
  [("IncomeSchedule.nextPaymentInfo(IncomeSchedule.readerView()) or \"--\"", "g_IncomeManager.incomeSystem:getNextPaymentInfo() or \"--\"", 1)],
  "the report's next payment follows the client's own pay mode"),
 ("R5-PDA-reads-local-settings", PDA,
  [("    local s = mgr and IncomeSchedule.readerSettings(view)\n", "    local s = mgr and mgr.settings\n", 1)],
  "the PDA summary and hints are the client's own settings"),
 # ── S: a season named ───────────────────────────────────────────────────────
 ("S1-HUD-names-the-season", HUD,
  [("        renderText(x, cy - tsSmall, tsSmall, IncomeSchedule.seasonAdjustText(view))", "        renderText(x, cy - tsSmall, tsSmall, \"Season: Autumn (1.2x)\")", 1)],
  "the HUD names a season from the ambiguous label path"),
 # ── G: the gate ─────────────────────────────────────────────────────────────
 ("G1-HUD-explanation-while-locked", HUD,
  [("    local showFarms  = not waiting and IncomeSchedule.explanationReleased()", "    local showFarms  = not waiting", 1)],
  "the HUD's every-farm row shows in a LOCKED build"),
 ("G2-report-explanation-while-locked", REP,
  [("    if IncomeSchedule.explanationReleased() then lines = IncomeSchedule.explanationLines(view) end", "    lines = IncomeSchedule.explanationLines(view)", 1)],
  "the report's estimate line shows in a LOCKED build"),
 ("G3-PDA-explanation-while-locked", PDA,
  [("    if IncomeSchedule.explanationReleased() then\n        for _, line in ipairs(IncomeSchedule.explanationLines(view))", "    if true then\n        for _, line in ipairs(IncomeSchedule.explanationLines(view))", 1)],
  "the PDA explanation shows in a LOCKED build"),
 ("G4-typed-control-while-locked", UI,
  [("    local amountOpt = nil\n    if IncomeSchedule.explanationReleased() then", "    local amountOpt = nil\n    if true then", 1)],
  "the typed amount row shows in a LOCKED build"),
 ("G5-gate-fails-open", SCH,
  [("    return ReleaseGate.isReleased(IncomeSchedule.GATE, optIn) == true", "    return optIn ~= false", 1)],
  "an unreadable opt-in releases the LOCKED surface"),
 # ── V: the view ─────────────────────────────────────────────────────────────
 ("V1-reader-field-dropped-on-the-wire", SCH,
  [("    v.difficulty            = streamReadUInt8(streamId)\n", "    v.difficulty            = streamReadUInt8(streamId) and nil\n", 1)],
  "a client reader shows a default difficulty instead of the host's"),
 ("V2-enabled-not-carried", SCH,
  [("        enabled               = settings.enabled == true,\n", "        enabled               = true,\n", 1)],
  "a disabled host reads as on"),
 ("V3-unavailable-hides-disabled", SCH,
  [("    if settings.enabled ~= true then\n        view.paymentState = IncomeSchedule.STATE.DISABLED   -- the estimate is hypothetical\n    elseif days == nil then\n        view.paymentState = IncomeSchedule.STATE.UNAVAILABLE\n",
    "    if days == nil then\n        view.paymentState = IncomeSchedule.STATE.UNAVAILABLE\n    elseif settings.enabled ~= true then\n        view.paymentState = IncomeSchedule.STATE.DISABLED   -- the estimate is hypothetical\n", 1)],
  "income off with an unknown month reads as on"),
 ("V4-unknown-month-shown-as-a-figure", SCH,
  [("    if view.monthEstimate == nil or view.daysThisMonth == nil then\n", "    if view.paymentState == IncomeSchedule.STATE.UNAVAILABLE then\n", 1)],
  "a disabled schedule with an unknown month shows a month of nil days"),
 ("V5-signature-misses-reader-fields", "src/IncomeManager.lua",
  [("        tostring(v.enabled), tostring(v.difficulty), tostring(v.incomeMultiplier),\n        tostring(v.seasonalEffects), tostring(v.seasonFactor),\n", "", 1)],
  "a host change that moves only a reader field never reaches the clients"),
 # ── T: the typed control ────────────────────────────────────────────────────
 ("T1-typed-No-applies", UI,
  [("            if not yes then\n                self:refreshUI()\n                return\n            end\n            mgr:requestIncomeSchedule(OP.APPLY, amountText,",
    "            mgr:requestIncomeSchedule(OP.APPLY, amountText,", 1)],
  "answering No to the typed amount applies it"),
 ("T2-non-admin-can-type", UI,
  [("    local usable = view.paymentState ~= IncomeSchedule.STATE.WAITING and view.canEdit ~= false", "    local usable = view.paymentState ~= IncomeSchedule.STATE.WAITING", 1)],
  "a non-admin gets a working typed control"),
 ("T3-entry-too-short-for-a-legacy-amount", UI,
  [("IncomeSchedule.MAX_TEXT, text(\"button_ok\"", "6, text(\"button_ok\"", 1)],
  "the entry cannot hold a legacy amount above the cap"),
 ("T4-legacy-warning-dropped", UI,
  [("        if before ~= nil and before.legacyOverCap and preview.view ~= nil", "        if false and before ~= nil and before.legacyOverCap and preview.view ~= nil", 1)],
  "lowering a legacy amount is not warned as permanent"),
 # ── L: strings ──────────────────────────────────────────────────────────────
 ("L1-a-reader-string-loses-a-language", MOD,
  [("            <vi><![CDATA[Trả cho mọi trang trại đang hoạt động]]></vi>\n", "", 1)],
  "a Vietnamese HUD shows the English every-farm row"),
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
