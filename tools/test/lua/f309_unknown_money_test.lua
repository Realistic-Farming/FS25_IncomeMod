-- f309_unknown_money_test.lua: RSF-F309 v0.3 item 1, unknown money is unknown, not 0.
--
-- THE DEFECT. The reply wrote cash, outstanding and offer as `tonumber(x) or 0` and the
-- reader took `tonumber(text)`, so an UNKNOWN amount (a pure client asking before the
-- server's view was ready) arrived as a confident 0. The report then did
-- `view.outstanding or 0` and keyed the money buttons on `outstanding > 0`, and
-- readiness was never consulted: a client mid-load read "no emergency loan" over a
-- debt it could not see. A nil-preserving encodeAmount/parseAmount pair already existed
-- on this event for the quote amount and was not used for these three fields.
--
-- THE REPAIR. writeStream uses encodeAmount (nil encodes as ""), readStream uses
-- parseAmount ("" is nil, a real "0" is 0), and the report treats nil as UNAVAILABLE
-- (the existing im_loan_fc_unavailable string, "Unavailable" in every language) and
-- keys every money button on a KNOWN amount. Wire-compatible: still one string per
-- field; an old peer's tonumber("") is nil and then hits its own `or 0`.
--
-- ENTRY-POINT BARS. Group A drives the REAL writeStream and readStream through the
-- prelude's stream tape (the #76 bench), the way the engine runs an event. Group B
-- drives the REAL IncomeReportDialog:updateLoanSection over the payload that came off
-- that wire, through the same manager door the dialog uses (getEmergencyLoanView).
--
-- What this bar does NOT prove: engine stream framing, a real client joining mid-load,
-- and the readiness field's meaning (items 2 to 6 are PR-B). The TESTING row.
--
--!load: src/ReleaseGate.lua, src/settings/SettingsManager.lua, src/settings/Settings.lua, src/EmergencyLoan.lua, src/EmergencyLoanEvent.lua, src/IncomeManager.lua, src/ui/IncomeReportDialog.lua

local saved = { g_IncomeManager = g_IncomeManager, g_i18n = g_i18n }
g_i18n = { getText = function(_, k) return k end, formatMoney = function(_, v) return "$" .. tostring(math.floor((v or 0) + 0.5)) end }

-- The reply as the server builds it, over the wire, back as the client reads it.
local function roundTrip(fields)
  local s = _sfMockStream()
  local p = { status = "OK", sequence = 7, canBorrow = fields.canBorrow == true, canRepay = fields.canRepay == true, token = "", quoteAmount = nil }
  p.cash, p.outstanding, p.offer = fields.cash, fields.outstanding, fields.offer
  EmergencyLoanEvent.newReply(p):writeStream(s, nil)
  g_IncomeManager = nil
  local back = EmergencyLoanEvent.emptyNew()
  back:readStream(s, nil)
  return back.payload, s
end

-- =====================================================================
-- GROUP A: the wire. Unknown stays unknown, zero stays zero, a value stays a value.
-- =====================================================================
do
  local p, s = roundTrip({ cash = nil, outstanding = nil, offer = nil })
  T.eq("F309 A1: no type mismatch on the tape", s.typeErrors, 0)
  T.eq("F309 A2: write and read agree on the field count", s.underflows, 0)
  T.eq("F309 A3: an UNKNOWN cash arrives as nil, not 0", p.cash, nil)
  T.eq("F309 A4: an UNKNOWN outstanding arrives as nil, not 0", p.outstanding, nil)
  T.eq("F309 A5: an UNKNOWN offer arrives as nil, not 0", p.offer, nil)
end
do
  local p = roundTrip({ cash = 0, outstanding = 0, offer = 0 })
  T.eq("F309 A6: a real zero cash stays 0", p.cash, 0)
  T.eq("F309 A7: a real zero outstanding stays 0 (nothing owed is a known fact)", p.outstanding, 0)
  T.eq("F309 A8: a real zero offer stays 0", p.offer, 0)
end
do
  local p = roundTrip({ cash = 12345.5, outstanding = 987.25, offer = 500 })
  T.near("F309 A9: a positive cash survives to six decimals", p.cash, 12345.5, 1e-6)
  T.near("F309 A10: a positive outstanding survives", p.outstanding, 987.25, 1e-6)
  T.near("F309 A11: a positive offer survives", p.offer, 500, 1e-6)
end
do
  -- Wire compatibility with an unrepaired peer: the same field is still one string,
  -- and the empty encoding is what an old reader's tonumber turns into nil.
  T.eq("F309 A12: the unknown encoding is the empty string", EmergencyLoanController.encodeAmount(nil), "")
  T.eq("F309 A13: an old peer's tonumber of it is nil, so its own `or 0` is what decides there", tonumber(""), nil)
  T.eq("F309 A14: a non-finite amount is unknown too", EmergencyLoanController.encodeAmount(0 / 0), "")
end

-- =====================================================================
-- GROUP B: the report over the payload that came off the wire.
-- =====================================================================
local function newWidget()
  local w = { visible = "unset", disabled = "unset", text = "unset" }
  function w:setVisible(v) self.visible = v end
  function w:setDisabled(v) self.disabled = v end
  function w:setText(t) self.text = t end
  return w
end
local function report(fields)
  local payload = roundTrip(fields)
  g_IncomeManager = { getEmergencyLoanView = function() return payload end }
  local dlg = setmetatable({}, { __index = IncomeReportDialog })
  dlg.loanStatusText, dlg.loanBorrowButton, dlg.loanPayoffButton, dlg.loanRepayAmountButton = newWidget(), newWidget(), newWidget(), newWidget()
  dlg.updateForecastLines = function() end
  dlg.formatWorkingCashBasis = function() return "" end
  local ok, err = pcall(IncomeReportDialog.updateLoanSection, dlg)
  return dlg, ok, err
end
do
  local dlg, ok, err = report({ cash = nil, outstanding = nil, offer = nil, canBorrow = true, canRepay = true })
  T.ok("F309 B0: the report renders an unknown view without error (" .. tostring(err) .. ")", ok)
  T.eq("F309 B1: UNKNOWN outstanding shows UNAVAILABLE, not 'no emergency loan'", dlg.loanStatusText.text, "im_loan_fc_unavailable")
  T.eq("F309 B2: no Pay Off button on an unknown amount, even with canRepay set", dlg.loanPayoffButton.visible, false)
  T.eq("F309 B3: no Repay Amount button either", dlg.loanRepayAmountButton.visible, false)
  T.eq("F309 B4: no Borrow button on an unknown offer, even with canBorrow set", dlg.loanBorrowButton.visible, false)
end
do
  local dlg = report({ cash = 100, outstanding = 0, offer = 0, canBorrow = false, canRepay = false })
  T.eq("F309 B5: a KNOWN zero with nothing offered reads 'no emergency loan'", dlg.loanStatusText.text, "im_loan_none")
  T.eq("F309 B6: and no buttons", dlg.loanPayoffButton.visible == false and dlg.loanBorrowButton.visible == false, true)
end
do
  local dlg = report({ cash = 100, outstanding = 0, offer = 2500, canBorrow = true, canRepay = false })
  T.ok("F309 B7: a known zero with a known offer shows the offer line", dlg.loanStatusText.text:find("im_loan_offer_available", 1, true) ~= nil and dlg.loanStatusText.text:find("$2500", 1, true) ~= nil)
  T.eq("F309 B8: and the Borrow button", dlg.loanBorrowButton.visible, true)
  T.eq("F309 B9: but no Pay Off", dlg.loanPayoffButton.visible, false)
end
do
  local dlg = report({ cash = 100, outstanding = 1234.5, offer = 0, canBorrow = false, canRepay = true })
  T.ok("F309 B10: a known positive outstanding shows the outstanding line with the server's sum", dlg.loanStatusText.text:find("im_loan_outstanding", 1, true) ~= nil and dlg.loanStatusText.text:find("$1235", 1, true) ~= nil)
  T.eq("F309 B11: with Pay Off", dlg.loanPayoffButton.visible, true)
  T.eq("F309 B12: and Repay Amount", dlg.loanRepayAmountButton.visible, true)
end
do
  -- Unknown outstanding with a KNOWN offer: the amount owed is what the buttons key on,
  -- so unavailable still wins the status line and Pay Off stays hidden.
  local dlg = report({ cash = 100, outstanding = nil, offer = 2500, canBorrow = true, canRepay = true })
  T.eq("F309 B13: unknown outstanding beats a known offer on the status line", dlg.loanStatusText.text, "im_loan_fc_unavailable")
  T.eq("F309 B14: Pay Off hidden", dlg.loanPayoffButton.visible, false)
end

g_IncomeManager, g_i18n = saved.g_IncomeManager, saved.g_i18n
