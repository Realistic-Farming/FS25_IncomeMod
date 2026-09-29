-- IM6-l10n_test.lua - IM-6: every new player string ships in the mod's complete locale set.
--
-- The brief's hard boundary: "New strings ship in IncomeMod's complete required locale
-- set." MAINTENANCE row 159 parks the OLD gaps; these are new. This bench reads the
-- shipped modDesc.xml and every im6_* key against the code set of the mod's fully
-- translated framework key (the same reference c3_loan_l10n_test.lua uses, so the list
-- cannot drift from the file), and reads the Lua that shows them so a key the code asks
-- for can never be missing from the file. It guards presence, emptiness, stubs, dashes
-- and the %s count a translation must keep (Lua's string.format has no positional
-- arguments, so a translation with a different count breaks or garbles the line). It
-- does not judge translation quality.
--
--!text: modDesc.xml, src/settings/SettingsUI.lua

local xml = T.text["modDesc.xml"]
local ui = T.text["src/settings/SettingsUI.lua"]
T.ok("modDesc.xml is readable by the bench", type(xml) == "string" and #xml > 1000)
T.ok("SettingsUI.lua is readable by the bench", type(ui) == "string" and #ui > 1000)

local function langsOf(body)
    local langs, order = {}, {}
    for code, value in body:gmatch("<(%a%a)><!%[CDATA%[(.-)%]%]></%1>") do
        if langs[code] ~= nil then langs[code] = { dup = true } else langs[code] = { value = value } end
        order[#order + 1] = code
    end
    return langs, order
end

local function count(s, pat)
    local n = 0
    for _ in s:gmatch(pat) do n = n + 1 end
    return n
end

local refLangs, refOrder = langsOf(xml:match('<text name="rf_pda_side_info_income">(.-)</text>') or "")
T.eq("reference key carries the mod's 26 codes", #refOrder, 26)

-- Every im6_* key the Esc door asks for.
local used, usedList = {}, {}
for key in ui:gmatch('"(im6_[%w_]+)"') do
    if not used[key] then used[key] = true; usedList[#usedList + 1] = key end
end
T.ok("the Esc door asks for im6 keys", #usedList >= 19)

local shipped = {}
for name, body in xml:gmatch('<text name="(im6_[%w_]+)">(.-)</text>') do
    shipped[name] = true
    local langs = langsOf(body)
    local want = count((langs.en and langs.en.value) or "", "%%s")
    local problems = {}
    for _, code in ipairs(refOrder) do
        local e = langs[code]
        if e == nil then problems[#problems + 1] = code .. ":missing"
        elseif e.dup then problems[#problems + 1] = code .. ":duplicate"
        elseif e.value:match("^%s*$") then problems[#problems + 1] = code .. ":empty"
        elseif e.value:match("^%s*%[EN%]") then problems[#problems + 1] = code .. ":stub"
        elseif e.value:find("\226\128\148", 1, true) or e.value:find("\226\128\147", 1, true) then
            problems[#problems + 1] = code .. ":dash"
        elseif count(e.value, "%%s") ~= want or count(e.value, "%%") ~= want then
            problems[#problems + 1] = code .. ":placeholders"
        end
    end
    for code in pairs(langs) do
        if refLangs[code] == nil then problems[#problems + 1] = code .. ":unknown-code" end
    end
    T.eq(name .. " is complete in every code", table.concat(problems, " "), "")
end

for _, key in ipairs(usedList) do
    T.ok(key .. " (asked for by SettingsUI.lua) ships in modDesc.xml", shipped[key] == true)
end
