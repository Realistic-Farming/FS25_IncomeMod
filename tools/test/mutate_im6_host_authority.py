# IncomeMod IM-6 PR A mutation battery: the income schedule's host authority.
# Rows live in IM6-A-host_authority_test.lua (the entry-point bar), IM6-contract_test.lua
# (the design contract test, updated to production) and IM6-l10n_test.lua.
#
# SEPARATE FILE ON PURPOSE: each item's battery belongs to its own work. The siblings
# this change must keep green are mutate_f282.py (IncomeSystem.lua, the rewind guard
# beside the new rebase helper) and mutate_f309_money_path.py / mutate_f309_unknown_money.py
# (IncomeManager.lua, the loan handler beside the new schedule handler).
#
# The brief's nine kill targets (section 6) are K1 to K9, with the doors a target spans
# split into lettered rows. N, S, W, R, C, P, V, CO, E and L are this build's own.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_im6_host_authority.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SCH = "src/IncomeSchedule.lua"
MGR = "src/IncomeManager.lua"
SYS = "src/IncomeSystem.lua"
UI = "src/settings/SettingsUI.lua"
GUI = "src/settings/SettingsGUI.lua"
HUB = "src/settings/SettingsHubBridge.lua"
MOD = "modDesc.xml"

MUTATIONS = [
 # ── the brief's nine ────────────────────────────────────────────────────────
 ("K1-class-table-only-marker-write", SCH,
  [("    sys:rebaseForScheduleChange(env)\n    return true",
    "    IncomeSystem.lastHour, IncomeSystem.lastDay, IncomeSystem.lastMonotonicDay = env.currentHour, env.currentDay, env.currentMonotonicDay\n    return true", 1)],
  "the rebase writes the class table (the old setPayMode defect); the live poll pays the stale span"),
 ("K2-old-Esc-direct-mode-assign", UI,
  [("        function(val)\n            self:onPayModeSelected(val)\n        end",
    "        function(val)\n            self.settings.payMode = val\n            self.settings:save()\n        end", 1)],
  "the Esc option writes the mode with no preview, confirm or rebase"),
 ("K3a-unconfirmed-Reset-apply-wire", SCH,
  [("            if req.confirm ~= true then return { status = \"CONFIRM_REQUIRED\" } end\n", "", 1)],
  "RESET_APPLY without the explicit confirmation resets everything"),
 ("K3b-unconfirmed-Reset-apply-console", GUI,
  [("            if confirmWord ~= \"confirm\" then\n                done(text .. \"\\nNothing changed. To apply: IncomeResetSettings confirm\")",
    "            if false then\n                done(text .. \"\\nNothing changed. To apply: IncomeResetSettings confirm\")", 1)],
  "IncomeResetSettings resets without the literal confirm"),
 ("K3c-unconfirmed-Reset-apply-Esc", UI,
  [("            if not yes then return end\n", "", 1)],
  "Esc Reset applies when the player answers No"),
 ("K4-console-exponent-decimal-acceptance", SCH,
  [("not trimmed:match(\"^%d+$\")", "tonumber(trimmed) == nil", 1)],
  "1e3, 1.5, -1 and 0x10 are read as amounts"),
 ("K5-new-over-cap-acceptance", SCH,
  [("    if value >= 0 and value <= IncomeSchedule.CAP then return true end", "    if value >= 0 then return true end", 1)],
  "a new amount above 999999 is accepted"),
 ("K6-SettingsHub-amount-mode-declaration", HUB,
  [("        { id = \"enabled\",           type = \"bool\", default = s.enabled,           adminOnly = true,  label = \"Income Mod Enabled\" },\n",
    "        { id = \"enabled\",           type = \"bool\", default = s.enabled,           adminOnly = true,  label = \"Income Mod Enabled\" },\n        { id = \"payMode\", type = \"enum\", default = s.payMode, adminOnly = true, values = { 1, 2 }, label = \"Pay Mode\" },\n        { id = \"customAmount\", type = \"int\", default = s.customAmount, adminOnly = true, label = \"Custom Amount\" },\n", 1)],
  "SettingsHub lists the two retired rows again"),
 ("K7-SettingsHub-callback-write", HUB,
  [("    if IncomeSettingsHubBridge.RETIRED_KEYS[key] then return end\n", "", 1)],
  "a stale mirror or ledger restore writes the mode and amount through the generic callback"),
 ("K8a-local-default-before-host-copy-view", MGR,
  [("    return copyView(self.scheduleView) or { paymentState = IncomeSchedule.STATE.WAITING }\nend",
    "    return copyView(self.scheduleView) or IncomeSchedule.buildView(self.settings, self.incomeSystem, self.scheduleRevision, nil)\nend", 1)],
  "a client answers from its own settings before the host's view arrives"),
 ("K8b-local-default-before-host-copy-Esc", UI,
  [("    if view == nil or view.unit == nil then return nil end", "    if view == nil or view.unit == nil then return self.settings.payMode end", 1)],
  "the Esc option offers the client's own mode while it waits"),
 ("K9-incomeBasis-zero-as-display-estimate", SCH,
  [("        view.monthEstimate     = EmergencyLoan.periodGross(payment, factor, settings.payMode, days)",
    "        view.monthEstimate     = (g_IncomeManager ~= nil and g_IncomeManager.emergencyLoan ~= nil) and g_IncomeManager.emergencyLoan:incomeBasis().periodGross or 0", 1)],
  "the estimate reads incomeBasis, which is 0 when disabled"),
 # ── non-admin apply, stale preview accepted ─────────────────────────────────
 ("N1-non-admin-apply", SCH,
  [("    if isAdmin ~= true then return { status = \"NOT_ADMIN\" } end\n", "", 1)],
  "a non-admin's request is served"),
 ("N2-any-connection-is-admin", SCH,
  [("    return okM and isMaster == true", "    return okM", 1)],
  "the master-user check passes every user"),
 ("S1-stale-preview-accepted", SCH,
  [("    if op == OP.APPLY and req.revision ~= revision then\n        return { status = \"STALE_PREVIEW\" }\n    end\n", "", 1)],
  "an apply at an old revision overwrites another admin's change"),
 ("S2-stale-reset-accepted", SCH,
  [("            if req.revision ~= revision then return { status = \"STALE_PREVIEW\" } end\n", "", 1)],
  "a confirmed Reset at an old revision applies"),
 # ── the wire ────────────────────────────────────────────────────────────────
 ("W1-reply-revision-not-carried", SCH,
  [("        self.payload.revision = self.payload.view ~= nil and self.payload.view.revision or nil\n", "", 1)],
  "a client's confirm carries no revision and is always stale"),
 ("W2-reply-broadcast-not-to-requester", SCH,
  [("            connection:sendEvent(IncomeScheduleEvent.newReply(reply))", "            g_server:broadcastEvent(IncomeScheduleEvent.newReply(reply), false)", 1)],
  "the reply goes to everyone instead of the requesting connection"),
 ("W3-host-takes-a-forged-view", SCH,
  [("    elseif g_server ~= nil then\n        -- The host is the author of every view; it never takes one from a connection.\n        return\n", "", 1)],
  "a connection can plant a view on the host"),
 ("W4-preview-cached-as-accepted", MGR,
  [("    if payload.status ~= \"OK\" or not isPreview then", "    if true then", 1)],
  "a client shows a preview's hypothetical result as the host's schedule"),
 ("W5-broadcast-drops-capability", MGR,
  [("    if view.canEdit == nil and self.scheduleView ~= nil then\n        view.canEdit = self.scheduleView.canEdit\n    end\n", "", 1)],
  "a broadcast wipes each client's own edit capability"),
 # ── the rebase ──────────────────────────────────────────────────────────────
 ("R1-mode-change-without-rebase", SCH,
  [("        if modeChanged then IncomeSchedule.rebaseLiveMarkers(mgr) end\n", "", 1)],
  "the switch pays the stale span under the new unit"),
 ("R2-reset-without-rebase", SCH,
  [("        settings:resetToDefaults(false)\n        IncomeSchedule.rebaseLiveMarkers(mgr)\n", "        settings:resetToDefaults(false)\n", 1)],
  "a Reset mid-day pays the stale span"),
 ("R3-rebase-helper-moves-nothing", SYS,
  [("        env.currentDay, env.currentMonotonicDay or -1, env.currentHour)\n    self.lastHour         = env.currentHour\n    self.lastDay          = env.currentDay\n    self.lastMonotonicDay = env.currentMonotonicDay or -1\n",
    "        env.currentDay, env.currentMonotonicDay or -1, env.currentHour)\n", 1)],
  "the helper logs and leaves the markers"),
 # ── commit ──────────────────────────────────────────────────────────────────
 ("C1-accepted-change-not-published", SCH,
  [("    if mgr.publishIncomeScheduleView ~= nil then mgr:publishIncomeScheduleView(true) end\n", "", 1)],
  "other clients keep the old schedule"),
 ("C2-accepted-change-not-saved", SCH,
  [("    if mgr.settings ~= nil and mgr.settings.save ~= nil then mgr.settings:save() end\n", "", 1)],
  "an accepted change is lost on reload"),
 ("C3-revision-not-advanced", SCH,
  [("    mgr.scheduleRevision = (mgr.scheduleRevision or 0) + 1\n", "", 1)],
  "a second admin's stale preview is never detected"),
 ("P1-preview-writes", SCH,
  [("        local probe = probeSettings(settings, { customAmount = verdict.amount, payMode = verdict.mode })\n",
    "        settings.customAmount = verdict.amount\n        settings.payMode = verdict.mode\n        local probe = settings\n", 1)],
  "a preview changes the host"),
 # ── the view ────────────────────────────────────────────────────────────────
 ("V1-disabled-shown-as-scheduled", SCH,
  [("    elseif settings.enabled ~= true then\n", "    elseif false then\n", 1)],
  "income off is presented as scheduled"),
 ("V2-unavailable-sent-as-zero", SCH,
  [("    local days = IncomeSchedule.activeDaysPerPeriod()\n", "    local days = IncomeSchedule.activeDaysPerPeriod() or 0\n", 1)],
  "an unknown month length reads as a 0 estimate"),
 # ── the console and Esc doors ───────────────────────────────────────────────
 ("CO1-pay-mode-applies-without-confirm", GUI,
  [("            if confirmWord ~= \"confirm\" then\n                done(text .. string.format(", "            if false then\n                done(text .. string.format(", 1)],
  "IncomeSetPayMode applies without the literal confirm"),
 ("E1-Esc-No-applies", UI,
  [("        YesNoDialog.show(function(yes)\n            if yes then\n", "        YesNoDialog.show(function(yes)\n            if true then\n", 1)],
  "answering No to the pay-mode confirm applies it"),
 ("E2-waiting-client-can-pick", UI,
  [("    if accepted == nil then self:refreshUI() return end\n", "    if accepted == nil then accepted = self.settings.payMode end\n", 1)],
  "a client with no host view sends a change from its own state"),
 # ── strings ─────────────────────────────────────────────────────────────────
 ("L1-a-key-loses-a-language", MOD,
  [("            <vi><![CDATA[Đổi chế độ trả?]]></vi>\n", "", 1)],
  "a Vietnamese player sees the English fallback"),
 ("L2-a-translation-drops-its-placeholder", MOD,
  [("<de><![CDATA[Betrag pro Zahlung: %s.]]></de>", "<de><![CDATA[Betrag pro Zahlung.]]></de>", 1)],
  "the German line loses the amount"),
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
