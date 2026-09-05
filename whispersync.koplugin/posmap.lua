--[[--
Map between KOReader xpointers and Kindle positions.

A Kindle position for a Send-to-Kindle document is a byte offset into the
decompressed MOBI HTML. KOReader addresses text by xpointer (a DOM path plus
a character offset). Neither is derivable from the other arithmetically, and
percentage is only an approximation — a 0.1% error in a novel is half a page.

So the mapping goes through the words themselves:

  xpointer -> offset:  take the text of the node under the xpointer, find it
                       in the plain-text index, convert to a raw byte.
  offset -> xpointer:  take the words at that offset from the index, search
                       the rendered document for them (findAllText).

Repeated phrases are disambiguated by the expected percentage — the lesson
this repo learned when `indexOf` landed on the wrong occurrence. Percentage
is the fallback when text matching fails (images, tables, empty nodes).
]]

local mobi = require("mobi")

local PosMap = {}
PosMap.__index = PosMap

--- `idx` from mobi.build_index; `document` is a CreDocument; `text_length`
-- from the MOBI header (the denominator for percentages).
function PosMap.new(idx, document, text_length)
    return setmetatable({
        idx = idx,
        doc = document,
        text_length = math.max(1, tonumber(text_length) or idx.raw_length or 1),
        page_count = nil,
    }, PosMap)
end

function PosMap:pages()
    if not self.page_count then
        local ok, n = pcall(self.doc.getPageCount, self.doc)
        self.page_count = (ok and tonumber(n) and n > 0) and n or 1
    end
    return self.page_count
end

--- 0..1 position of an xpointer in the rendered document.
function PosMap:percent_of_xpointer(xp)
    local ok, page = pcall(self.doc.getPageFromXPointer, self.doc, xp)
    if not ok or not tonumber(page) then return nil end
    return (page - 0.5) / self:pages()
end

--- 0..1 position of a raw byte offset in the book text.
function PosMap:percent_of_offset(raw)
    return math.max(0, math.min(1, raw / self.text_length))
end

-- Number of bytes taken by the first `nchars` UTF-8 characters of s.
local function utf8_bytes_for_chars(s, nchars)
    local i, chars, n = 1, 0, #s
    while i <= n and chars < nchars do
        local b = s:byte(i)
        if b < 0x80 then i = i + 1
        elseif b < 0xE0 then i = i + 2
        elseif b < 0xF0 then i = i + 3
        else i = i + 4 end
        chars = chars + 1
    end
    return math.min(i - 1, n)
end

local function first_words(s, max_bytes, min_words)
    s = mobi.normalize(s)
    if #s <= max_bytes then return s end
    local cut = s:sub(1, max_bytes):match("^.*()%s")
    if cut and cut > 8 then s = s:sub(1, cut - 1) else s = s:sub(1, max_bytes) end
    -- Don't end inside a multibyte sequence.
    while #s > 0 and s:byte(#s) >= 0x80 and s:byte(#s) < 0xC0 do s = s:sub(1, #s - 1) end
    if s:byte(#s) and s:byte(#s) >= 0xC0 then s = s:sub(1, #s - 1) end
    local _ = min_words
    return s
end

-- Nearest candidate to the expected percentage. Also returns the runner-up's
-- distance so callers can tell a clear winner from a coin toss.
local function pick_nearest(candidates, target_pct, pct_of)
    local best, best_d, second_d
    for _, c in ipairs(candidates) do
        local p = pct_of(c)
        local d = p and math.abs(p - target_pct) or 0.5
        if not best or d < best_d then
            second_d = best_d
            best, best_d = c, d
        elseif not second_d or d < second_d then
            second_d = d
        end
    end
    return best, best_d, second_d
end

-- The percentage hint has page resolution, so two hits closer together than
-- about a page cannot be told apart by it.
function PosMap:ambiguous(best_d, second_d)
    return second_d ~= nil and (second_d - best_d) < 1.5 / self:pages()
end

-------------------------------------------------------------------------------
-- xpointer -> offset
-------------------------------------------------------------------------------

--- Returns raw offset, method ("text" | "percent"), or nil when impossible.
function PosMap:to_offset(xp)
    if not xp then return nil end
    local pct = self:percent_of_xpointer(xp) or 0
    local ok, node_text = pcall(self.doc.getTextFromXPointer, self.doc, xp)
    node_text = ok and node_text or nil
    local char_off = tonumber((tostring(xp):match("%.(%d+)$")) or "0") or 0

    if node_text and mobi.normalize(node_text) ~= "" then
        local norm = mobi.normalize(node_text)
        local byte_off = utf8_bytes_for_chars(node_text, char_off)
        -- Whitespace collapsing may have shifted the offset a little; measure
        -- it on the normalized string instead when the node had runs.
        if #norm ~= #node_text then
            local before = mobi.normalize(node_text:sub(1, byte_off) .. "x")
            byte_off = #before - 1
        end
        local best_capped
        for _, max_bytes in ipairs({ 64, 200, 1000, 32, 16 }) do
            local needle = first_words(norm, max_bytes)
            if #needle >= 4 then
                local hits = mobi.find_all(self.idx, needle, PosMap.MAX_HITS)
                if #hits > 0 then
                    local hit, d1, d2 = pick_nearest(hits, pct, function(p)
                        return self:percent_of_offset(mobi.raw_from_plain(self.idx, p))
                    end)
                    local plain_pos = hit + math.min(byte_off, #norm)
                    local off = mobi.raw_from_plain(self.idx, plain_pos)
                    if #hits < PosMap.MAX_HITS and not self:ambiguous(d1, d2) then return off, "text" end
                    -- Capped or a near tie: remember it, try a longer needle.
                    best_capped = best_capped or off
                end
            end
        end
        if best_capped then return best_capped, "text" end
    end
    return math.floor(pct * self.text_length), "percent"
end

-------------------------------------------------------------------------------
-- offset -> xpointer
-------------------------------------------------------------------------------

PosMap.MAX_HITS = 500

--- Search the rendered document for `snippet`; returns hits list or {}.
-- A result with MAX_HITS entries is capped and therefore not trustworthy
-- for disambiguation; callers lengthen the snippet in that case.
function PosMap:find_in_document(snippet)
    if not snippet or #snippet < 3 then return {} end
    local ok, hits = pcall(self.doc.findAllText, self.doc, snippet, false, 0, PosMap.MAX_HITS, false)
    if ok and type(hits) == "table" and #hits > 0 then return hits end
    -- Some KOReader versions only offer findText; walk from the start.
    ok, hits = pcall(self.doc.findText, self.doc, snippet, -1, 0, false, nil, false, PosMap.MAX_HITS)
    if ok and type(hits) == "table" and #hits > 0 then return hits end
    return {}
end

--- Returns xpointer, method ("text" | "percent"), or nil.
function PosMap:to_xpointer(raw)
    raw = tonumber(raw)
    if not raw then return nil end
    local pct = self:percent_of_offset(raw)
    local plain_pos = mobi.plain_from_raw(self.idx, raw)
    -- Short snippets first (robust to renderer differences), longer ones
    -- when a phrase turns out to be repeated more often than the search cap.
    local best_capped
    local tried = {}
    for _, max_bytes in ipairs({ 48, 120, 400, 24 }) do
        local snippet = mobi.snippet_at(self.idx, plain_pos, max_bytes)
        if #snippet >= 4 and not tried[snippet] then
            tried[snippet] = true
            local hits = self:find_in_document(snippet)
            if #hits > 0 then
                local hit, d1, d2 = pick_nearest(hits, pct, function(h)
                    return self:percent_of_xpointer(h.start)
                end)
                if hit and hit.start then
                    if #hits < PosMap.MAX_HITS and not self:ambiguous(d1, d2) then return hit.start, "text" end
                    best_capped = best_capped or hit.start
                end
            end
        end
    end
    if best_capped then return best_capped, "text" end
    -- Fallback: the page at that percentage.
    local page = math.max(1, math.min(self:pages(), math.floor(pct * self:pages() + 0.5)))
    local ok, xp = pcall(self.doc.getPageXPointer, self.doc, page)
    if ok and xp then return xp, "percent" end
    return nil
end

--- A Kindle range (start, end) -> xpointers pos0, pos1 for a highlight.
-- `end` is inclusive (verified against live ranges in this repo). Uses the
-- highlighted words themselves when possible, so the highlight lands on the
-- same text.
function PosMap:range_to_xpointers(start, fin)
    start, fin = tonumber(start), tonumber(fin)
    if not start then return nil end
    if not fin or fin <= start then
        local xp = self:to_xpointer(start)
        return xp, xp
    end
    local p0 = mobi.plain_from_raw(self.idx, start)
    local p1 = mobi.plain_from_raw(self.idx, fin)
    local quote = mobi.normalize(self.idx.plain:sub(p0, p1))
    if #quote >= 4 and #quote <= 400 and not quote:find("\n") then
        local hits = self:find_in_document(quote)
        if #hits > 0 then
            local hit = pick_nearest(hits, self:percent_of_offset(start), function(h)
                return self:percent_of_xpointer(h.start)
            end)
            if hit and hit.start and hit["end"] then return hit.start, hit["end"], quote end
        end
    end
    local xp0 = self:to_xpointer(start)
    local xp1 = self:to_xpointer(fin)
    return xp0, xp1 or xp0, quote
end

--- Highlight xpointers -> Kindle (start, end), end inclusive. `text` is the
-- highlighted text KOReader stored, which is the most reliable anchor of all.
function PosMap:xpointers_to_range(pos0, pos1, text)
    local start = self:to_offset(pos0)
    local fin = pos1 and self:to_offset(pos1) or nil
    if text and #mobi.normalize(text) >= 4 then
        local norm = mobi.normalize(text)
        local needle = first_words(norm, 64)
        local hits = mobi.find_all(self.idx, needle, 200)
        if #hits > 0 then
            local pct = self:percent_of_xpointer(pos0) or (start and self:percent_of_offset(start)) or 0
            local hit = pick_nearest(hits, pct, function(p)
                return self:percent_of_offset(mobi.raw_from_plain(self.idx, p))
            end)
            start = mobi.raw_from_plain(self.idx, hit)
            -- End: where the quoted text ends in the plain index, if it is
            -- all there; otherwise trust the pos1 conversion.
            local tail = self.idx.plain:sub(hit, hit + #norm + 8)
            if mobi.normalize(tail):sub(1, #norm) == norm then
                fin = mobi.raw_from_plain(self.idx, hit + #norm - 1)
            end
        end
    end
    if start and (not fin or fin < start) then fin = start end
    return start, fin
end

return PosMap
