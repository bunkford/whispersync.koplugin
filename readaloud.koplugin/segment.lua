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

-- An utterance is one request to the service. Long ones read most naturally
-- (one prosodic arc, few seams) and the stream plays them back to back; the
-- first is kept short so the voice starts within a few seconds.
M.MAX_UTTERANCE_BYTES = 2000       -- ~2 minutes of speech; the service caps requests near 4 KB
M.MAX_UTTERANCE_SENTENCES = 40
M.FIRST_UTTERANCE_BYTES = 500
M.MAX_WORDS_PER_SENTENCE = 400

-------------------------------------------------------------------------------
-- sentences and words from crengine
-------------------------------------------------------------------------------

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Sentence-ending punctuation, optionally followed by closing quotes/brackets.
local SENTENCE_END = "[%.!%?\226\128\166][\"'\226\128\152-\226\128\157%)%]]*$"

--- Does this text end a sentence? (trailing whitespace ignored)
function M.ends_sentence(text)
    text = (text or ""):gsub("%s+$", "")
    if text == "" then return false end
    -- ASCII closers and Unicode closing quotes (U+2018-U+201D) after . ! ? or an ellipsis
    text = text:gsub("[\"'%)%]]+$", ""):gsub("\226\128[\152-\157]$", "")
    local last = text:sub(-1)
    if last == "." or last == "!" or last == "?" then return true end
    return text:sub(-3) == "\226\128\166" -- …
end

--- The block (paragraph) an xpointer belongs to: its path without the text
-- node offset and without common inline wrappers, so a word inside <i> in
-- the same paragraph compares equal to its neighbours.
function M.block_of(xp)
    if type(xp) ~= "string" then return "" end
    local b = xp:match("^(.*)/text%(%)%.%d+$")
    if not b then return "" end -- not a crengine text xpointer: no paragraph information
    for _ = 1, 3 do
        local stripped = b:gsub("/[ibusq]%[%d+%]$", ""):gsub("/[ibusq]$", "")
            :gsub("/[%a]-(em|strong|span|a|small|sup|sub|code|cite|abbr|mark|font)%[%d+%]$", "")
            :gsub("/(em|strong|span|a|small|sup|sub|code|cite|abbr|mark|font)$", "")
        if stripped == b then break end
        b = stripped
    end
    return b
end

--- Start of the word at or after `xp` (a page-top xpointer may sit inside a
-- word or on an element).
function M.first_word_start(doc, xp)
    local eok, e = pcall(doc.getNextVisibleWordEnd, doc, xp)
    if eok and e and e ~= "" then
        local sok, st = pcall(doc.getPrevVisibleWordStart, doc, e)
        if sok and st and st ~= "" then return st end
    end
    return M.word_start_after(doc, xp)
end

--- The first word start strictly after `xp`.
function M.word_start_after(doc, xp)
    local ok, nxt = pcall(doc.getNextVisibleWordStart, doc, xp)
    if ok and nxt and nxt ~= "" then return nxt end
    return nil
end

--- Sentences starting at `xp`, until `budget_bytes` of text or `max`
-- sentences. Built from crengine's word navigation: each word plus the text
-- between it and the next word (punctuation, spaces), so what is spoken has
-- its full stops, and a sentence closes on terminal punctuation or when the
-- next word is in another paragraph (a heading or an unpunctuated paragraph
-- then gets a full stop, so the voice pauses there).
-- Returns list of { xp0, xp1, text } and the xpointer to continue from
-- (nil at the end of the book).
function M.sentences_from(doc, xp, budget_bytes, max, deadline, clock)
    budget_bytes = budget_bytes or M.MAX_UTTERANCE_BYTES
    max = max or M.MAX_UTTERANCE_SENTENCES
    clock = clock or (deadline and (function()
        local ok, socket = pcall(require, "socket")
        if ok and socket and socket.gettime then return socket.gettime end
        return os.time
    end)())
    local out, total = {}, 0
    local s = M.first_word_start(doc, xp)
    local cur_words, cur_xp0 = {}, nil
    local cur_word_list = {}   -- { xp0, xp1, text } per word, kept on the sentence for alignment
    local words_in_sentence = 0
    local function close(xp1, add_stop)
        if #cur_words == 0 then return end
        local text = trim(table.concat(cur_words))
        if text ~= "" then
            if add_stop and not M.ends_sentence(text) and not text:match("[,;:%-\226\128\148]$") then text = text .. "." end
            out[#out + 1] = { xp0 = cur_xp0, xp1 = xp1, text = text, words = cur_word_list }
            total = total + #text
        end
        cur_words, cur_xp0, words_in_sentence, cur_word_list = {}, nil, 0, {}
    end
    local guard = 0
    while s and #out < max and total < budget_bytes do
        guard = guard + 1
        if guard > 4000 then break end
        -- Stay inside the UI tick: stop at a sentence boundary once the deadline passes.
        if deadline and #cur_words == 0 and #out > 0 and clock() > deadline then break end
        local eok, e = pcall(doc.getNextVisibleWordEnd, doc, s)
        if not eok or not e or e == "" then break end
        local tok, word = pcall(doc.getTextFromXPointers, doc, s, e)
        word = tok and type(word) == "string" and word or ""
        local n = M.word_start_after(doc, e)
        local gap = ""
        local same_block = n and M.block_of(n) == M.block_of(s)
        if n and (same_block or M.block_of(n) == "") then
            local gok, g = pcall(doc.getTextFromXPointers, doc, e, n)
            gap = gok and type(g) == "string" and g or " "
            if gap == "" then gap = " " end
        elseif n then
            gap = "\n" -- a new paragraph; never ask crengine for a range across blocks
        end
        if not cur_xp0 then cur_xp0 = s end
        cur_words[#cur_words + 1] = word .. gap
        if trim(word) ~= "" then cur_word_list[#cur_word_list + 1] = { xp0 = s, xp1 = e, text = trim(word) } end
        words_in_sentence = words_in_sentence + 1
        local paragraph_break = n and (gap:find("\n") or M.block_of(n) ~= M.block_of(s)) or false
        if not n then
            close(e, true)
        elseif M.ends_sentence(word .. gap) or paragraph_break or words_in_sentence >= M.MAX_WORDS_PER_SENTENCE then
            close(e, paragraph_break)
        end
        s = n
    end
    -- Whatever is still open is a partial sentence at the budget edge: the
    -- next call continues from its first word rather than mid-sentence.
    if #cur_words > 0 then s = cur_xp0 end
    return out, s
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

--- Words for a whole utterance: the words recorded while its sentences were
-- walked (no second pass over crengine), or a fresh walk for sentences that
-- came without them.
function M.utterance_words(doc, utterance)
    local all = {}
    for _, s in ipairs(utterance.sentences) do
        local ws = s.words or M.words_between(doc, s.xp0, s.xp1)
        for _, w in ipairs(ws) do all[#all + 1] = w end
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
