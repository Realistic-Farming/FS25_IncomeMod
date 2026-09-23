#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RSF-F309 item 1 (unknown money): does the bar catch the versions that would ship it wrong?

Five mutants, each must send f309_unknown_money_test.lua RED:

  M1  the `or 0` restored on one written field   an unknown cash arrives as 0 again.
  M2  the reader takes tonumber on outstanding    "" reads as nil here too, but a real
                                                 "0.000000" is fine; the row that kills it
                                                 is the unknown case through parseAmount's
                                                 contract on the other two fields (M2 keeps
                                                 tonumber semantics that turn "" into nil,
                                                 so it must be killed by the typed contract:
                                                 see the bar's A rows on all three fields).
  M3  the report treats nil as 0                  an unknown reads "no emergency loan".
  M4  Pay Off keyed on canRepay alone             a button appears over an unknown amount.
  M5  Borrow keyed on canBorrow alone             a button appears over an unknown offer.

Every edit asserts it LANDED by exact occurrence count. Restore is proved by sha256.

Run from tools/test:  py mutate_f309_unknown_money.py
"""
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
EVT = os.path.join(ROOT, "src", "EmergencyLoanEvent.lua")
DLG = os.path.join(ROOT, "src", "ui", "IncomeReportDialog.lua")
BAR = "f309_unknown_money_test.lua"
BAR_RE = re.compile(re.escape(BAR) + r"[^\n(]*\((\d+) passed, (\d+) failed")

WRITE_CASH = "        streamWriteString(streamId, EmergencyLoanController.encodeAmount(p.cash))\n"
READ_OUT = "            outstanding = EmergencyLoanController.parseAmount(streamReadString(streamId)),\n"
NIL_AS_ZERO = "    local outstanding = view.outstanding\n    local known = type(outstanding) == \"number\"\n"
PAYOFF = "    setBtn(payoffBtn, view.canRepay == true and known and outstanding > 0)\n"
BORROW = "    setBtn(borrowBtn, view.canBorrow == true and offerKnown)\n"

MUTATIONS = [
    ("M1 the `or 0` restored on the written cash", EVT,
     [(WRITE_CASH, "        streamWriteString(streamId, string.format(\"%.6f\", tonumber(p.cash) or 0))\n", 1)]),
    ("M2 the written outstanding falls back to 0", EVT,
     [("        streamWriteString(streamId, EmergencyLoanController.encodeAmount(p.outstanding))\n",
       "        streamWriteString(streamId, EmergencyLoanController.encodeAmount(p.outstanding or 0))\n", 1)]),
    ("M3 the report treats nil as 0", DLG,
     [(NIL_AS_ZERO, "    local outstanding = view.outstanding or 0\n    local known = type(outstanding) == \"number\"\n", 1)]),
    ("M4 Pay Off keyed on canRepay alone", DLG,
     [(PAYOFF, "    setBtn(payoffBtn, view.canRepay == true)\n", 1)]),
    ("M5 Borrow keyed on canBorrow alone", DLG,
     [(BORROW, "    setBtn(borrowBtn, view.canBorrow == true)\n", 1)]),
]


def read(path):
    with io.open(path, "r", encoding="utf-8", newline="") as fh:
        return fh.read()


def write(path, s):
    with io.open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(s)


def digest(path):
    return hashlib.sha256(read(path).encode("utf-8")).hexdigest()[:12]


def run_bar():
    proc = subprocess.run(["node", "run-tests.mjs"], cwd=HERE, capture_output=True, text=True)
    out = (proc.stdout or "") + (proc.stderr or "")
    m = BAR_RE.search(out)
    if not m:
        return None, None, out.strip()[-600:]
    return int(m.group(1)), int(m.group(2)), ""


def apply(src, edits):
    for needle, repl, count in edits:
        n = src.count(needle)
        if n != count:
            crlf = needle.replace("\n", "\r\n")
            if src.count(crlf) != count:
                return None, "needle found %d time(s), expected %d: %r" % (n, count, needle[:60])
            needle, repl = crlf, repl.replace("\n", "\r\n")
        src = src.replace(needle, repl, count)
    return src, ""


def main():
    bases = {p: (read(p), digest(p)) for p in (EVT, DLG)}
    p, f, tail = run_bar()
    if p is None or f != 0 or p == 0:
        print("ABORT: the bar is not green before mutating.\n" + tail)
        return 1
    print("baseline        : %d passed, %d failed\n" % (p, f))

    killed, survived, unapplied = 0, [], []
    for name, target, edits in MUTATIONS:
        mutated, why = apply(bases[target][0], edits)
        if mutated is None or mutated == bases[target][0]:
            unapplied.append(name)
            print("  %-48s MUTATION DID NOT APPLY (%s)" % (name, why))
            continue
        shutil.copyfile(target, target + ".bak")
        try:
            write(target, mutated)
            mp, mf, mtail = run_bar()
        finally:
            shutil.copyfile(target + ".bak", target)
            os.remove(target + ".bak")
        if mf is None:
            print("  %-48s DID NOT RUN\n%s" % (name, mtail))
            survived.append(name)
        elif mf > 0:
            killed += 1
            print("  %-48s KILLED (%d red)" % (name, mf))
        else:
            survived.append(name)
            print("  %-48s SURVIVED" % name)

    for path, (_, d) in bases.items():
        if digest(path) != d:
            print("\nRESULT: restore FAILED, %s is not byte-identical." % os.path.basename(path))
            return 1
    p2, f2, _ = run_bar()
    print("\nafter restore   : %d passed, %d failed (sources byte-identical)" % (p2, f2))
    if f2 != 0 or p2 != p:
        print("RESULT: the bar is not green again after restore.")
        return 1
    if unapplied:
        print("RESULT: %d mutation(s) did not apply; a red result would be unattributable." % len(unapplied))
        return 1
    if survived:
        print("RESULT: %d SURVIVED: %s" % (len(survived), "; ".join(survived)))
        return 1
    print("RESULT: %d killed, 0 survived, 0 unapplied." % killed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
