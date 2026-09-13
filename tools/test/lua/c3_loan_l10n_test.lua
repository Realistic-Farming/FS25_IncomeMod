-- c3_loan_l10n_test.lua - C3/RSF-F130: the emergency-loan string block is fully localized.
--
-- The delivered brief requires every player-facing loan string in all 26 language codes
-- the mod already ships, with real translations (an "[EN] ..." stub is not one). This
-- bench reads the shipped modDesc.xml and checks every im_loan_* key against the code
-- set the mod's own fully translated keys use (derived from rf_pda_side_info_income, so
-- the list cannot drift from the file). It does not judge translation quality; it
-- guards presence, emptiness, stubs and dashes, which are the failure modes a later
-- key addition would silently reintroduce.
--
--!text: modDesc.xml

local xml = T.text["modDesc.xml"]
T.ok("modDesc.xml is readable by the bench", type(xml) == "string" and #xml > 1000)

local function langsOf(body)
    local langs, order = {}, {}
    for code, value in body:gmatch("<(%a%a)><!%[CDATA%[(.-)%]%]></%1>") do
        if langs[code] ~= nil then langs[code] = { dup = true } else langs[code] = { value = value } end
        order[#order + 1] = code
    end
    return langs, order
end

local function textBlock(name)
    return xml:match('<text name="' .. name .. '">(.-)</text>')
end

-- The reference code set: whatever the mod's fully translated framework key carries.
local refLangs, refOrder = langsOf(textBlock("rf_pda_side_info_income") or "")
T.eq("reference key carries the mod's 26 codes", #refOrder, 26)
T.ok("reference set includes en", refLangs.en ~= nil)

-- Every key the C3 block shipped on development must be present.
local REQUIRED = {
    "im_loan_none", "im_loan_offer_available", "im_loan_borrow", "im_loan_payoff",
    "im_loan_principal", "im_loan_interest", "im_loan_outstanding", "im_loan_repay_amount",
    "im_loan_amount_prompt", "im_loan_amount_invalid", "im_loan_confirm_title",
    "im_loan_confirm_text", "im_loan_confirm_clamped",
    "im_loan_payoff_confirm_title", "im_loan_payoff_confirm_text", "im_loan_repaid",
    "im_loan_repay_failed", "im_loan_insufficient_cash", "im_loan_not_manager",
    "im_loan_no_debt", "im_loan_stale_quote",
}

local found = {}
local blockCount = 0
for name, body in xml:gmatch('<text name="(im_loan_[%w_]+)">(.-)</text>') do
    blockCount = blockCount + 1
    found[name] = true
    local langs, order = langsOf(body)
    local problems = {}
    for _, code in ipairs(refOrder) do
        local e = langs[code]
        if e == nil then problems[#problems + 1] = code .. ":missing"
        elseif e.dup then problems[#problems + 1] = code .. ":duplicate"
        elseif e.value:match("^%s*$") then problems[#problems + 1] = code .. ":empty"
        elseif e.value:match("^%s*%[EN%]") then problems[#problems + 1] = code .. ":stub"
        elseif e.value:find("\226\128\148", 1, true) or e.value:find("\226\128\147", 1, true) then
            problems[#problems + 1] = code .. ":dash"
        end
    end
    for _, code in ipairs(order) do
        if refLangs[code] == nil then problems[#problems + 1] = code .. ":not-a-mod-language" end
    end
    T.ok(name .. " carries all 26 real translations", #problems == 0, table.concat(problems, " "))
    T.eq(name .. " keeps its English source", langs.en and langs.en.value ~= nil, true)
end

for _, name in ipairs(REQUIRED) do
    T.ok("key present on development is still shipped: " .. name, found[name] == true)
end
T.ok("at least the 21 development keys exist", blockCount >= #REQUIRED)

-- The "English authored ... until a translation pass" note is no longer true.
T.ok("the EN-only fallback comment is gone", xml:find("until a translation pass", 1, true) == nil)
