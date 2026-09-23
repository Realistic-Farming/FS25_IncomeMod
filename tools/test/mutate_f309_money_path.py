# RSF-F309 v0.3 items 2 to 6 mutation battery (PR-B, the emergency loan money path).
#
# Each mutation re-introduces one of the six live defects Bob's intake re-derived, or
# removes one clause of the repair, and must be KILLED by a named row of
# tools/test/lua/f309_loan_money_path_test.lua. For each: assert the edit LANDED
# (exact occurrence count), run the suite, record KILLED/SURVIVED with the named rows,
# restore byte-for-byte and PROVE the restore with a hash. A no-op edit is
# indistinguishable from an unpinned rule, which is why the count assert is not
# optional. "DID NOT APPLY" never counts as a kill.
#
# Usage: py tools/test/mutate_f309_money_path.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

EL = "src/EmergencyLoan.lua"
IM = "src/IncomeManager.lua"

MUTATIONS = [
 ("M1-delete-on-manual-payoff", EL,
  # item 2: applyManualPayment deletes the paid record again (the pre-F309 line)
  [("    if not d.active then\n        self:retireDebt(farmId, d)\n    end\n    Logging.info(\"Income Mod: Emergency loan manual payment",
    "    if not d.active then\n        self.debts[farmId] = nil\n        self:unregisterInterestAccrual(farmId)\n    end\n    Logging.info(\"Income Mod: Emergency loan manual payment", 1)],
  "a manual payoff deletes the record, so the draw history and the revision are lost"),

 ("M2-delete-on-automatic-payoff", EL,
  [("    if not d.active then\n        self:retireDebt(farmId, d)\n    end\n    Logging.info(\"Income Mod: Emergency loan repayment",
    "    if not d.active then\n        self.debts[farmId] = nil\n        self:unregisterInterestAccrual(farmId)\n    end\n    Logging.info(\"Income Mod: Emergency loan repayment", 1)],
  "an automatic payoff deletes the record"),

 ("M3-grant-drawCount-1", EL,
  # item 3: a new grant starts the history over
  [("        drawCount       = ((prior and prior.drawCount) or 0) + 1,",
    "        drawCount       = 1,", 1)],
  "a grant after a retired line is draw 1 again, so the escalation never reads the history"),

 ("M4-grant-revision-1", EL,
  [("        revision        = ((prior and prior.revision) or 0) + 1,",
    "        revision        = 1,", 1)],
  "a grant resets the revision to 1, so a stale token from an earlier life can match again"),

 ("M5-drop-settle-revision-bump", EL,
  # item 4
  [("    if grown > 0 then debt.revision = (debt.revision or 0) + 1 end",
    "", 1)],
  "a settle grows the debt without advancing the revision, so a quote held across it still applies"),

 ("M6-pay-recomputed-not-bound", IM,
  # item 5: the accepted branches recompute the offer instead of paying the bound sum
  [("                    ok = loan:redraw(farmId, quote.amount)",
    "                    ok = loan:redraw(farmId)", 1),
   ("                    ok = loan:grant(farmId, quote.amount)",
    "                    ok = loan:grant(farmId)", 1)],
  "the bound amount is dropped on the way into redraw/grant, which recompute the offer"),

 ("M7-restore-and-or-fallthrough", IM,
  [("                local debt = loan.debts[farmId]\n                local ok\n                if debt ~= nil and debt.active == true then\n                    ok = loan:redraw(farmId, quote.amount)\n                else\n                    ok = loan:grant(farmId, quote.amount)\n                end",
    "                local debt = loan.debts[farmId]\n                local ok = (debt ~= nil and debt.active == true) and loan:redraw(farmId, quote.amount) or loan:grant(farmId, quote.amount)", 1)],
  "a refused redraw (false) falls through the and-or into grant"),

 ("M8-accept-skips-binding-recheck", IM,
  [("            if not bindingMatches(quote, now) or not borrowStillAdmissible(quote.amount, loan:computeOffer(farmId)) then",
    "            if false then", 1)],
  "ACCEPT no longer re-reads the assumptions the borrow quote bound (revision, readiness, cash, terms, offer)"),

 ("M23-exact-cash-equality-restored", IM,
  # Arissani's ruling (17994ad): cash is revalidated for admissibility, not equality
  [("            if not bindingMatches(quote, now) or not borrowStillAdmissible(quote.amount, loan:computeOffer(farmId)) then",
    "            if not bindingMatches(quote, now) or quote.cash ~= now.cash or not borrowStillAdmissible(quote.amount, loan:computeOffer(farmId)) then", 1)],
  "any cash movement since the quote strands the Borrow again (a buying helper refuses every client Borrow)"),

 ("M24-offer-ceiling-dropped", IM,
  [("    return amount <= offerNow\n", "    return true\n", 1)],
  "an amount above the offer recomputed from current cash is still paid"),

 ("M25-shortage-check-dropped", IM,
  [("    if type(offerNow) ~= \"number\" or offerNow ~= offerNow or offerNow <= 0 or offerNow == math.huge then return false end\n    return amount <= offerNow\n",
    "    return amount <= (tonumber(offerNow) or math.huge)\n", 1)],
  "a Borrow is paid after the shortage has gone"),

 ("M26-recomputed-offer-substituted", IM,
  [("                    ok = loan:redraw(farmId, quote.amount)", "                    ok = loan:redraw(farmId, loan:computeOffer(farmId))", 1),
   ("                    ok = loan:grant(farmId, quote.amount)", "                    ok = loan:grant(farmId, loan:computeOffer(farmId))", 1)],
  "the current offer is paid instead of the exact bound amount"),

 ("M27-manual-cash-coverage-dropped", IM,
  [("            elseif cash == nil or quote.amount > cash then status = \"INSUFFICIENT_CASH\"\n", "", 1)],
  "a manual payment is taken although current cash no longer covers it"),

 ("M9-skip-exact-retry-check", IM,
  # item 6: same-sequence handling removed; a retry runs again (token now spent -> STALE)
  [("    if seq == session.highest then\n        local last = session.lastCommand",
    "    if false then\n        local last = session.lastCommand", 1)],
  "an exact retry of the last command is evaluated again instead of answered from the record"),

 ("M10-skip-old-sequence-refusal", IM,
  [("    if seq < session.highest then\n        return self:_viewReply(loan:getView(farmId, { isManager = true }), seq, \"OLD_SEQUENCE\")\n    end",
    "", 1)],
  "an older sequence is processed as new"),

 ("M11-cache-before-rights", IM,
  # the manager check moved AFTER the sequence step: a demoted user's retry gets the cached reply
  [("    if actor.isManager ~= true then\n        return self:_viewReply(loan:getView(farmId, { isManager = false }), seq, \"NOT_MANAGER\")\n    end\n\n    -- 2. session sequence",
    "    -- 2. session sequence", 1),
   ("    -- Reserve the sequence BEFORE any money moves;",
    "    if actor.isManager ~= true then\n        return self:_viewReply(loan:getView(farmId, { isManager = false }), seq, \"NOT_MANAGER\")\n    end\n    -- Reserve the sequence BEFORE any money moves;", 1)],
  "the cached result is disclosed before the actor's rights are established"),

 ("M12-sequence-wraps", IM,
  [("    if used >= EmergencyLoanController.MAX_SEQUENCE then\n        Logging.warning(\"Income Mod: emergency loan request sequence exhausted for this session; no further owner commands until the next session\")\n        return nil\n    end\n    self._loanSeq = used + 1",
    "    if used >= EmergencyLoanController.MAX_SEQUENCE then used = 0 end\n    self._loanSeq = used + 1", 1)],
  "the client sequence wraps to 1 at MAX instead of refusing"),

 ("M13-second-command-not-refused", IM,
  [("        if self:_isLoanUiBusy() then deliver(nil); return false, \"BUSY\" end\n        local ev, seq = self:_newLoanRequest(EmergencyLoanController.OP.ACCEPT_QUOTE, nil, token)",
    "        local ev, seq = self:_newLoanRequest(EmergencyLoanController.OP.ACCEPT_QUOTE, nil, token)", 1)],
  "a second owner-UI command is sent while one is in flight"),

 ("M18-armed-auto-accept-not-busy", IM,
  # Bob's MINOR on #79: a quote-then-accept flow whose auto-accept is pending did not count
  # as busy, so a double-clicked Borrow sent two quotes and lost both
  [("    return self._pendingQuote ~= nil or self._pendingResult ~= nil or type(self._pendingAccept) == \"number\"",
    "    return self._pendingQuote ~= nil or self._pendingResult ~= nil", 1)],
  "a pending auto-accept does not make the client busy, so a double-clicked Borrow sends twice"),

 ("M19-disarm-only-on-token", IM,
  # Bob's re-look on cdaef21: disarming only on a token-bearing reply leaves a refused quote
  # (no token) armed, so every later command is BUSY until the report is reopened
  [("    if type(armed) == \"number\" and payload.sequence == armed then\n        self._pendingAccept = false\n        if payload.token ~= nil and payload.token ~= \"\" and g_client and g_client.getServerConnection then",
    "    if type(armed) == \"number\" and payload.sequence == armed and payload.token ~= nil and payload.token ~= \"\" then\n        self._pendingAccept = false\n        if g_client and g_client.getServerConnection then", 1)],
  "a refused quote (no token) leaves the client armed and BUSY"),

 ("M20-failed-send-stays-armed", IM,
  [("        if not ok then self._pendingAccept = false end   -- a failed send never leaves the client BUSY\n",
    "", 1)],
  "a failed send leaves the client armed and BUSY"),

 ("M21-accept-does-not-hold-the-slot", IM,
  [("                self._pendingResult = { sequence = seq, callback = nil }\n",
    "", 1)],
  "the auto-accept is fire-and-forget, so a second command can go out while it is in flight"),

 ("M22-failed-accept-send-keeps-the-slot", IM,
  # Bob's B2 on 1923f82: a failed auto-accept send kept the result slot, so the client stayed BUSY
  [("                if not ok then self._pendingResult = nil end\n",
    "", 1)],
  "a failed auto-accept send keeps the result slot and the client stays BUSY"),

 ("M14-skip-session-clear-on-disconnect", IM,
  [("    if connection == nil or self._loanSessions == nil then return end\n    self._loanSessions[connection] = nil",
    "    if connection == nil or self._loanSessions == nil then return end", 1)],
  "a closed connection keeps its session, quote and sequence"),

 ("M15-skip-session-clear-on-delete", IM,
  [("    self._loanSessions = nil\n",
    "", 1)],
  "teardown keeps every session"),

 ("M16-hook-never-installed", IM,
  [("    IncomeManager.installLoanSessionTeardown()\n",
    "", 1)],
  "the constructor never appends the teardown to FSBaseMission:onConnectionClosed"),

 ("M17-quote-slot-not-replaced", IM,
  # a newer quote does not drop the older token (two live tokens)
  [("    quote.token = token\n    session.quote = quote\n    return token",
    "    quote.token = token\n    session.quotes = session.quotes or {}\n    session.quotes[token] = quote\n    session.quote = session.quote or quote\n    return token", 1)],
  "minting a second quote keeps the first as the session's outstanding quote"),
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
    print("  %s %s" % (tag, mid))
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
