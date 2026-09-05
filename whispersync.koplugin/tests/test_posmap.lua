local H = require("helpers")
local mobi = require("mobi")
local PosMap = require("posmap")

-- A fake CreDocument over the fixture's plain text: paragraphs are the DOM
-- nodes, xpointers look like "/body/p[N]/text().C" with C a char offset,
-- and pages are proportional to the byte position.
local blob = H.read(H.here .. "fixture/fixture.mobi")
local text, hdr = assert(mobi.extract_text(blob))
local idx = mobi.build_index(text)

local paras, starts = {}, {}
do
    local pos = 1
    for para in (idx.plain .. "\n"):gmatch("(.-)\n") do
        if para ~= "" then paras[#paras + 1] = para; starts[#paras] = pos end
        pos = pos + #para + 1
    end
end
local PAGES = 300
local function utf8_len(s) local _, n = s:gsub("[^\128-\191]", ""); return n end
local function xp_for(i, byte_off) return ("/body/p[%d]/text().%d"):format(i, utf8_len(paras[i]:sub(1, byte_off))) end
local function parse_xp(xp) local i, c = xp:match("p%[(%d+)%]/text%(%)%.?(%d*)"); return tonumber(i), tonumber(c) or 0 end
local FakeDoc = {}
function FakeDoc:getPageCount() return PAGES end
function FakeDoc:getTextFromXPointer(xp) local i = parse_xp(xp); return paras[i] end
function FakeDoc:getPageFromXPointer(xp)
    local i, c = parse_xp(xp)
    local bytepos = starts[i] + c
    return math.max(1, math.ceil(bytepos / #idx.plain * PAGES))
end
function FakeDoc:getPageXPointer(page)
    local target = (page - 1) / PAGES * #idx.plain
    for i = #paras, 1, -1 do if starts[i] <= target then return xp_for(i, 0) end end
    return xp_for(1, 0)
end
function FakeDoc:findAllText(pattern, ci, ctx, max_hits)
    local hits = {}
    for i, para in ipairs(paras) do
        local s = 1
        while true do
            local a, b = para:find(pattern, s, true)
            if not a then break end
            hits[#hits + 1] = { start = xp_for(i, a - 1), ["end"] = xp_for(i, b), text = pattern }
            if #hits >= max_hits then return hits end
            s = a + 1
        end
    end
    return hits
end

local pm = PosMap.new(idx, FakeDoc, hdr.text_length)

-- 1. Unique phrase: xpointer -> offset is exact, and back.
local raw = text:find("hallway smelt of boiled cabbage", 1, true) - 1
local xp = pm:to_xpointer(raw)
local i, c = parse_xp(xp)
H.eq(paras[i]:sub(utf8_len(paras[i]:sub(1, c)) + 1, c + 7), "hallway", "offset -> xpointer lands on the word")
local back, method = pm:to_offset(xp)
H.eq(method, "text", "xpointer -> offset by text")
H.eq(back, raw, "round trip exact (unique phrase)")

-- 2. Mid-paragraph xpointer with a char offset: exact byte.
local raw2 = text:find("too large for indoor display", 1, true) - 1
local xp2 = pm:to_xpointer(raw2)
H.eq(pm:to_offset(xp2), raw2, "mid-paragraph round trip exact")

-- 3. Repeated phrase (398 paragraphs share it): the percent hint picks the right one.
local n = 0
for s in text:gmatch("Paragraph number 250 repeats") do n = n + 1 end
H.eq(n, 1, "sanity: paragraph 250 unique by number")
local raw3 = text:find("repeats the phrase the clocks were striking for testing, with caf&eacute; and &#8220;quotes&#8221; number 250", 1, true) - 1
local xp3, m3 = pm:to_xpointer(raw3)
H.eq(m3, "text", "repeated phrase resolved by text")
local i3 = parse_xp(xp3)
H.ok(paras[i3]:find("number 250", 1, true), "repeated phrase disambiguated to paragraph 250 (got: " .. paras[i3]:sub(1, 30) .. ")")
H.eq(pm:to_offset(xp3), raw3, "repeated phrase round trip exact")

-- 4. Text after an entity still maps exactly (raw offsets include entity bytes).
local raw4 = text:find("number 300.</p>", 1, true) - 1
local xp4 = pm:to_xpointer(raw4)
H.eq(pm:to_offset(xp4), raw4, "round trip across entities")

-- 5. Offset inside a tag snaps to the following text.
local raw5 = text:find("<h2>Chapter Two", 1, true) - 1 + 1
local xp5 = pm:to_xpointer(raw5)
H.eq(paras[parse_xp(xp5)], "Chapter Two", "tag offset resolves to next heading")

-- 6. Percent fallback when nothing matches: an empty node.
local EmptyDoc = setmetatable({ getTextFromXPointer = function() return "" end }, { __index = FakeDoc })
local pm2 = PosMap.new(idx, EmptyDoc, hdr.text_length)
local off, m = pm2:to_offset(xp_for(200, 0))
H.eq(m, "percent", "percent fallback used")
H.near(off / hdr.text_length, starts[200] / #idx.plain, 0.02, "percent fallback is close")

-- 7. Highlight ranges both ways.
local hs = text:find("boiled cabbage and old rag mats", 1, true) - 1
local he = hs + #"boiled cabbage and old rag mats" - 1 -- inclusive end
local p0, p1, quote = pm:range_to_xpointers(hs, he)
H.eq(quote, "boiled cabbage and old rag mats", "quote recovered from range")
local qi, qc = parse_xp(p0)
H.eq(paras[qi]:sub(qc + 1, qc + 6), "boiled", "range start xpointer")
local rs, re = pm:xpointers_to_range(p0, p1, quote)
H.eq(rs, hs, "range start round trip")
H.eq(re, he, "range end round trip")

-- Highlight text anchor beats a wrong xpointer: text wins.
local rs2 = pm:xpointers_to_range(xp_for(5, 0), nil, "boiled cabbage and old rag mats")
H.eq(rs2, hs, "highlight text anchors the position")

H.done("test_posmap")
