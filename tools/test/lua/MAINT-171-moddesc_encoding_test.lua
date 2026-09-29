-- MAINT-171-moddesc_encoding_test.lua - MAINTENANCE row 171: modDesc.xml's inline
-- translations read as the words they are.
--
-- The older strings (610 values in 97 keys across 11 codes, the mod's title and description
-- among them, and 15 comment lines) had been multiply encoded: UTF-8 misread as cp1252 and
-- saved, then misread as cp850 and saved again, so a German player read "T├â┬ñglich" for
-- "Täglich" and ru/uk text was unreadable. The repair restored each value through the
-- reverse chain, only where re-encoding the result reproduced the stored bytes, replaced the
-- em dashes the restore brought back, and rewrote the comments in ASCII.
--
-- This bar reads the SHIPPED file, which is what the game reads: nothing in it can pass
-- while a garbled string, a dash, a lost key or a moved R17 string remains.
--
--!text: modDesc.xml

local xml = T.text["modDesc.xml"]
T.ok("modDesc.xml is readable by the bench", type(xml) == "string" and #xml > 100000)
local lf = xml:gsub("\r", "")

--- Lines of the file that match a byte pattern, as "line: text" (first three).
local function hits(pattern)
    local found, n, lineNo = {}, 0, 0
    for line in (lf .. "\n"):gmatch("(.-)\n") do
        lineNo = lineNo + 1
        if line:find(pattern) then
            n = n + 1
            if #found < 3 then found[#found + 1] = lineNo .. ": " .. line:gsub("^%s+", ""):sub(1, 60) end
        end
    end
    return n, table.concat(found, " | ")
end

-- U+2500 to U+257F (box drawing) is E2 94 xx and E2 95 xx in UTF-8.
local nBox, whereBox = hits("\226[\148\149]")
T.eq("no box-drawing character anywhere (the cp850 layer)", nBox .. " " .. whereBox, "0 ")
-- A leftover cp1252 layer: U+00C2 or U+00C3 followed by a Latin-1 continuation character
-- (C2 80 to C2 BF) or a cp1252 punctuation or letter (E2 80 xx, C5 xx, C6 92, CB xx, E2 84 A2).
local nMoji = 0
local mojiWhere = ""
for _, follow in ipairs({ "\194[\128-\191]", "\226\128", "\197", "\198\146", "\203", "\226\132\162" }) do
    local n, w = hits("\195[\130\131]" .. follow)
    nMoji = nMoji + n
    if w ~= "" then mojiWhere = w end
end
T.eq("no leftover double-encoded pair (the cp1252 layer)", nMoji .. " " .. mojiWhere, "0 ")
local nEm, whereEm = hits("\226\128\148")
T.eq("no em dash anywhere", nEm .. " " .. whereEm, "0 ")
local nEn, whereEn = hits("\226\128\147")
T.eq("no en dash anywhere", nEn .. " " .. whereEn, "0 ")

local function value(key, code)
    local block = lf:match('<text name="' .. key .. '">(.-)</text>')
    return block and block:match("<" .. code .. "><!%[CDATA%[(.-)%]%]></" .. code .. ">") or nil
end
T.eq("German im_paymode_2 reads Täglich (the Esc pay-mode option)", value("im_paymode_2", "de"), "Täglich")
T.eq("Russian im_paymode_2 reads clean Cyrillic", value("im_paymode_2", "ru"), "Ежедневно")
T.eq("Ukrainian im_paymode_2 reads clean Cyrillic", value("im_paymode_2", "uk"), "Щоденно")
local title = lf:match("<title>(.-)</title>")
T.eq("the Ukrainian mod title in the mod manager reads clean Cyrillic",
    title and title:match("<uk><!%[CDATA%[(.-)%]%]></uk>"), "Реалістичний збір врожаю")
T.eq("the German mod title reads clean", title and title:match("<de><!%[CDATA%[(.-)%]%]></de>"), "Realistisches Ernten")

-- The repair changed values, never keys or codes: the counts measured on the file before it.
local keys, entries = 0, 0
for _ in lf:gmatch('<text name="') do keys = keys + 1 end
for _ in lf:gmatch("<%a%a><!%[CDATA%[") do entries = entries + 1 end
T.eq("the key count is the pre-repair count", keys, 200)
T.eq("the language-entry count is the pre-repair count", entries, 3712)

-- R17's strings (#88 and #90) were already correct and must be byte-identical: the same
-- checksum over every im6_* block, in file order, as the file before the repair.
local blocks, count = {}, 0
for block in lf:gmatch('<text name="im6_[^"]+">.-</text>') do
    blocks[#blocks + 1] = block
    count = count + 1
end
local h = 0.0
local joined = table.concat(blocks)
for i = 1, #joined do h = (h * 31 + joined:byte(i)) % 2147483647 end
T.eq("the 30 R17 im6 keys are all present", count, 30)
T.eq("and byte-identical to the file before the repair", h, 1895299354)
