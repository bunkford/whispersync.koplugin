--[[--
Turning the book into things to say, and saying which word is where.

crengine (KOReader's EPUB/MOBI engine) can extend any position to the
sentence around it, walk from word to word, and give the screen boxes of a
range. That is enough to read a book aloud without ever touching the file:
sentences from the current position are grouped into utterances small
enough for the Edge service to answer quickly, and when the audio comes back
with a WordBoundary per spoken word, those are aligned to the words
crengine sees in the same sentences, so each boundary knows the xpointers to
highlight.

Everything that needs a document takes it as a parameter (a fake in tests);
`align`, `group` and the normalizers are pure.
]]

local M = {}

M.MAX_UTTERANCE_BYTES = 900   -- ~50-60 s of speech; the service answers in a second or two
M.MAX_UTTERANCE_SENTENCES = 8
M.MAX_WORDS_PER_SENTENCE = 400

-------------------------------------------------------------------------------
-- sentences and words from crengine
-------------------------------------------------------------------------------

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

--- The sentence around xpointer `xp`: { xp0, xp1, text } or nil.
function M.sentence_at(doc, xp)
    if not xp then return nil end
    local ok, seg = pcall(doc.extendXPointersToSentenceSegment, doc, xp, xp)
    if ok and type(seg) == "table" and seg.pos0 and seg.pos1 then
        local text = seg.text
        if type(text) ~= "string" then
            local tok, t = pcall(doc.getTextFromXPointers, doc, seg.pos0, seg.pos1)
            text = tok and t or ""
        end
        return { xp0 = seg.pos0, xp1 = seg.pos1, text = trim(text or "") }
    end
    -- Fallback: the single word at xp.
    local eok, e = pcall(doc.getNextVisibleWordEnd, doc, xp)
    if eok and e then
        local tok, t = pcall(doc.getTextFromXPointers, doc, xp, e)
        return { xp0 = xp, xp1 = e, text = trim(tok and t or "") }
    end
    return nil
end

--- The first word start at or after `xp`.
function M.word_start_after(doc, xp)
    local ok, nxt = pcall(doc.getNextVisibleWordStart, doc, xp)
    if ok and nxt and nxt ~= "" then return nxt end
    return nil
end

--- Sentences starting at `xp`, until `budget_bytes` of text or `max` sentences.
-- Returns list of { xp0, xp1, text } and the xpointer where the next call
-- should continue (nil at the end of the book).
function M.sentences_from(doc, xp, budget_bytes, max)
    budget_bytes = budget_bytes or M.MAX_UTTERANCE_BYTES * 3
    max = max or M.MAX_UTTERANCE_SENTENCES * 3
    local out, total = {}, 0
    local cur = xp
    local guard = 0
    while cur and #out < max and total < budget_bytes do
        guard = guard + 1
        if guard > max * 4 then break end
        local s = M.sentence_at(doc, cur)
        if not s then break end
        -- Never go backwards or stand still.
        local last = out[#out]
        if last then
            local cok, cmp = pcall(doc.compareXPointers, doc, last.xp1, s.xp1)
            if not cok or not cmp or cmp <= 0 then
                -- s ends at or before the previous one: step a word forward instead
                local step = M.word_start_after(doc, last.xp1)
                if not step or step == cur then break end
                cur = step
                s = nil
            end
        end
        if s then
            if s.text ~= "" then
                out[#out + 1] = s
                total = total + #s.text
            end
            local nxt = M.word_start_after(doc, s.xp1)
            if not nxt or nxt == cur then
                cur = nil
            else
                cur = nxt
            end
        end
    end
    return out, cur
end

--- The words crengine sees between two xpointers: { xp0, xp1, text }.
function M.words_between(doc, xp0, xp1, max)
    max = max or M.MAX_WORDS_PER_SENTENCE
    local out = {}
    local start = xp0
    while start and #out < max do
        local eok, e = pcall(doc.getNextVisibleWordEnd, doc, start)
        if not eok or not e or e == "" then break end
        -- Stop once the word end passes the range end.
        local cok, cmp = pcall(doc.compareXPointers, doc, e, xp1)
        if not cok or cmp == nil then break end
        if cmp < 0 then
            -- e is after xp1: include it only if it starts inside the range
            local sok, scmp = pcall(doc.compareXPointers, doc, start, xp1)
            if not (sok and scmp and scmp > 0) then break end
        end
        local tok, text = pcall(doc.getTextFromXPointers, doc, start, e)
        text = tok and type(text) == "string" and trim(text) or ""
        if text ~= "" then out[#out + 1] = { xp0 = start, xp1 = e, text = text } end
        local nok, nxt = pcall(doc.getNextVisibleWordStart, doc, e)
        if not nok or not nxt or nxt == "" or nxt == start then break end
        local nc_ok, ncmp = pcall(doc.compareXPointers, doc, nxt, xp1)
        if not nc_ok or not ncmp or ncmp <= 0 then break end
        start = nxt
    end
    return out
end

-------------------------------------------------------------------------------
-- pure: grouping and alignment
-------------------------------------------------------------------------------

--- Group sentences into utterances no longer than `max_bytes` / `max_n`.
-- Each utterance: { sentences = {...}, text = "joined text" }.
function M.group(sentences, max_bytes, max_n)
    max_bytes = max_bytes or M.MAX_UTTERANCE_BYTES
    max_n = max_n or M.MAX_UTTERANCE_SENTENCES
    local out, cur, len = {}, {}, 0
    local function flush()
        if #cur > 0 then
            local texts = {}
            for i, s in ipairs(cur) do texts[i] = s.text end
            out[#out + 1] = { sentences = cur, text = table.concat(texts, " ") }
        end
        cur, len = {}, 0
    end
    for _, s in ipairs(sentences) do
        if #cur > 0 and (len + #s.text + 1 > max_bytes or #cur >= max_n) then flush() end
        cur[#cur + 1] = s
        len = len + #s.text + 1
    end
    flush()
    return out
end

--- Lowercase letters and digits only, for matching spoken words to laid-out ones.
function M.norm(s)
    s = (s or ""):lower()
    -- Strip everything that is not a letter or digit (ASCII fast path; keep
    -- non-ASCII bytes so accented words still compare equal to themselves).
    -- General Punctuation block (dashes, curly quotes, ellipsis) and NBSP too.
    s = s:gsub("\226\128[\128-\191]", ""):gsub("\226\129[\128-\191]", ""):gsub("\194\160", "")
    s = s:gsub("[%s%p]", "")
    return s
end

--- Align the service's words (with times) to crengine's words (with
-- xpointers) for one utterance. Both are in reading order; the service
-- splits on spaces and drops punctuation, crengine keeps punctuation glued
-- to words and may split hyphenated compounds differently. A greedy walk
-- with a small lookahead handles what occurs in practice; a spoken word
-- that finds no home rests on the previous match, so the highlight simply
-- stays there a moment longer.
-- Returns list parallel to `spoken`: each { xp0, xp1 } or nil.
function M.align(cre_words, spoken)
    -- crengine "words" that are pure punctuation (a lone dash) are skipped.
    local cre, cn = {}, {}
    for _, w in ipairs(cre_words) do
        local nw = M.norm(w.text)
        if nw ~= "" then cre[#cre + 1] = w; cn[#cn + 1] = nw end
    end
    local n = #cre
    local LOOK, FAR = 4, 24
    local function span(j, k) return { xp0 = cre[j].xp0, xp1 = cre[k].xp1 } end
    local out = {}
    local ci, i = 1, 1
    while i <= #spoken do
        local sn = M.norm(spoken[i].text)
        local placed = false
        if sn == "" then
            out[i] = out[i - 1]
            placed = true
        end
        -- 1. the same word, close by
        if not placed then
            for j = ci, math.min(n, ci + LOOK) do
                if cn[j] == sn then out[i] = span(j, j); ci = j + 1; placed = true; break end
            end
        end
        -- 2. several spoken words make up one crengine word ("well-known" laid out as one)
        if not placed then
            for j = ci, math.min(n, ci + LOOK) do
                if #sn >= 1 and cn[j]:sub(1, #sn) == sn and #cn[j] > #sn then
                    local acc, k = sn, i
                    while k < #spoken and #acc < #cn[j] do
                        local nxt = acc .. M.norm(spoken[k + 1].text)
                        if cn[j]:sub(1, #nxt) ~= nxt then break end
                        acc, k = nxt, k + 1
                    end
                    if acc == cn[j] then
                        for m = i, k do out[m] = span(j, j) end
                        ci = j + 1
                        i = k
                        placed = true
                    end
                    break
                end
            end
        end
        -- 3. one spoken word covers several crengine words (crengine split "well-" "known")
        if not placed then
            for j = ci, math.min(n, ci + LOOK) do
                if #cn[j] < #sn and sn:sub(1, #cn[j]) == cn[j] then
                    local acc, k = cn[j], j
                    while k < n and #acc < #sn and sn:sub(1, #acc + #cn[k + 1]) == acc .. cn[k + 1] do
                        k = k + 1
                        acc = acc .. cn[k]
                    end
                    if acc == sn then
                        out[i] = span(j, k)
                        ci = k + 1
                        placed = true
                    end
                    break
                end
            end
        end
        -- 4. lost: look further ahead for the same word before giving up
        if not placed then
            for j = ci + LOOK + 1, math.min(n, ci + FAR) do
                if cn[j] == sn then out[i] = span(j, j); ci = j + 1; placed = true; break end
            end
        end
        if not placed then out[i] = out[i - 1] end
        i = i + 1
    end
    return out
end

--- Words for a whole utterance: its sentences' crengine words concatenated.
function M.utterance_words(doc, utterance)
    local all = {}
    for _, s in ipairs(utterance.sentences) do
        for _, w in ipairs(M.words_between(doc, s.xp0, s.xp1)) do all[#all + 1] = w end
    end
    return all
end

--- Given spoken words with times and their alignment, produce the timeline
-- the player walks: { t0, t1, xp0, xp1, text } sorted by t0, with gaps
-- closed so the highlight never blinks off between words.
function M.timeline(spoken, aligned, sentences_by_word)
    local out = {}
    for i, w in ipairs(spoken) do
        local a = aligned[i]
        if a then
            out[#out + 1] = { t0 = w.t0, t1 = w.t1, xp0 = a.xp0, xp1 = a.xp1, text = w.text }
        end
    end
    for i = 1, #out - 1 do
        if out[i + 1].t0 > out[i].t1 then out[i].t1 = out[i + 1].t0 end
    end
    return out
end

--- Index of the timeline entry playing at time `t` (nil before the first).
function M.at(timeline, t)
    local lo, hi = 1, #timeline
    if hi == 0 or t < timeline[1].t0 then return nil end
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if timeline[mid].t0 <= t then lo = mid else hi = mid - 1 end
    end
    return lo
end

return M
