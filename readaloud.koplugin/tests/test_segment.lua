local H = require("helpers")
local S = require("segment")

local fake_doc = require("fakedoc")

local words = { "It", "was", "a", "well-known", "fact.", "Nobody", "argued;", "1,000", "people", "nodded.", "The", "end." }
local doc = fake_doc(words, { { 1, 5 }, { 6, 10 }, { 11, 12 } })

-- sentences from the start: punctuation kept, split on terminal punctuation
local sents, nxt = S.sentences_from(doc, "1s")
H.eq(#sents, 3, "three sentences"); H.eq(sents[1].text, "It was a well-known fact.", "first sentence text with its full stop")
H.eq(sents[2].text, "Nobody argued; 1,000 people nodded.", "semicolon does not split")
H.eq(sents[2].xp0, "6s", "second sentence start"); H.eq(sents[3].xp1, "12e", "last sentence end"); H.eq(nxt, nil, "end of book")
-- from inside a word, that word is where reading starts
local mid = S.sentences_from(doc, "3s")
H.eq(mid[1].xp0, "3s", "starts at the word the position is in"); H.eq(mid[1].text, "a well-known fact.", "partial first sentence keeps its punctuation")
H.eq(S.block_of("3s"), "", "non-crengine xpointers carry no paragraph information")
-- budget stops at a sentence boundary and hands back where to continue
local few, cont = S.sentences_from(doc, "1s", 10, 10)
H.eq(#few, 1, "budget of 10 bytes: one sentence"); H.eq(cont, "6s", "continue at the next sentence")
-- a paragraph break closes a sentence and an unpunctuated one gets a full stop
local hdoc = fake_doc({ "CHAPTER", "1", "He", "woke", "up." }, {})
hdoc.paragraph_after[2] = true
local hs = S.sentences_from(hdoc, "1s")
H.eq(#hs, 2, "heading and paragraph are two sentences"); H.eq(hs[1].text, "CHAPTER 1.", "heading gets a full stop so the voice pauses"); H.eq(hs[2].text, "He woke up.", "then the paragraph")
H.eq(S.ends_sentence("Really?”"), true, "question mark before a closing quote ends a sentence"); H.eq(S.ends_sentence("well,"), false, "comma does not")
H.eq(S.ends_sentence("wait…"), true, "ellipsis ends"); H.eq(S.block_of("/body/DocFragment[2]/body/p[7]/i[1]/text().4"), "/body/DocFragment[2]/body/p[7]", "block ignores inline italics")
H.eq(S.block_of("/body/DocFragment[2]/body/p[8]/text().0") == S.block_of("/body/DocFragment[2]/body/p[7]/text().0"), false, "different paragraphs differ")
-- words between
local ws = S.words_between(doc, "1s", "5e")
H.eq(#ws, 5, "five words in sentence 1"); H.eq(ws[4].text, "well-known", "word text"); H.eq(ws[5].xp1, "5e", "last word end")
H.eq(#S.words_between(doc, "6s", "10e"), 5, "second sentence words")

-- grouping
local groups = S.group(sents, 50, 8)
H.eq(#groups, 2, "50-byte budget splits into two utterances"); H.eq(groups[1].text, "It was a well-known fact.", "first utterance")
H.eq(#groups[2].sentences, 2, "rest in the second"); H.eq(#S.group(sents, 1000, 2), 2, "sentence cap")

-- normalization
H.eq(S.norm("Well-Known,"), "wellknown", "norm strips punctuation and case"); H.eq(S.norm("1,000"), "1000", "digits kept"); H.eq(S.norm("—"), "", "dash alone is empty")

-- alignment: the service's word list for utterance 1+2 (as Edge reports: no punctuation, hyphen kept)
local cre = {}
for _, w in ipairs(S.words_between(doc, "1s", "5e")) do cre[#cre + 1] = w end
for _, w in ipairs(S.words_between(doc, "6s", "10e")) do cre[#cre + 1] = w end
local spoken = {
    { text = "It", t0 = 0.1 }, { text = "was", t0 = 0.3 }, { text = "a", t0 = 0.5 }, { text = "well", t0 = 0.6 }, { text = "known", t0 = 0.8 },
    { text = "fact", t0 = 1.0 }, { text = "Nobody", t0 = 1.5 }, { text = "argued", t0 = 1.9 }, { text = "1,000", t0 = 2.3 }, { text = "people", t0 = 2.6 }, { text = "nodded", t0 = 2.9 },
}
local al = S.align(cre, spoken)
H.eq(al[1].xp0, "1s", "It -> w1"); H.eq(al[4].xp0, "4s", "well -> the compound word"); H.eq(al[5].xp0, "4s", "known -> the same compound word")
H.eq(al[6].xp0, "5s", "fact -> fact. (punctuation ignored)"); H.eq(al[8].xp0, "7s", "argued -> argued;"); H.eq(al[9].xp0, "8s", "1,000 -> 1,000")
H.eq(al[11].xp0, "10s", "nodded -> nodded.")
-- crengine splitting a compound the service kept whole
local cre2 = { { xp0 = "1s", xp1 = "1e", text = "well-" }, { xp0 = "2s", xp1 = "2e", text = "known" }, { xp0 = "3s", xp1 = "3e", text = "fact" } }
local al2 = S.align(cre2, { { text = "well-known" }, { text = "fact" } })
H.eq(al2[1].xp0, "1s", "spoken compound starts at the first fragment"); H.eq(al2[1].xp1, "2e", "and ends at the second"); H.eq(al2[2].xp0, "3s", "then continues")
-- a spoken word with no home rests on the previous one; a lone dash on the crengine side is skipped
local cre3 = { { xp0 = "1s", xp1 = "1e", text = "Yes" }, { xp0 = "2s", xp1 = "2e", text = "—" }, { xp0 = "3s", xp1 = "3e", text = "no" } }
local al3 = S.align(cre3, { { text = "Yes" }, { text = "um" }, { text = "no" } })
H.eq(al3[2].xp0, "1s", "unmatched word rests on the previous"); H.eq(al3[3].xp0, "3s", "and alignment recovers")
-- recovery after the service skips a stretch of words
local cre4 = {}
for i = 1, 30 do cre4[i] = { xp0 = i .. "s", xp1 = i .. "e", text = "w" .. i } end
local al4 = S.align(cre4, { { text = "w1" }, { text = "w2" }, { text = "w20" }, { text = "w21" } })
H.eq(al4[3].xp0, "20s", "far lookahead finds the word again"); H.eq(al4[4].xp0, "21s", "and continues from there")

-- timeline and lookup
local tl = S.timeline({ { text = "a", t0 = 0.0, t1 = 0.2 }, { text = "b", t0 = 0.5, t1 = 0.7 }, { text = "c", t0 = 0.7, t1 = 0.9 } },
    { { xp0 = "1s", xp1 = "1e" }, nil, { xp0 = "3s", xp1 = "3e" } })
H.eq(#tl, 2, "unaligned words dropped from the timeline"); H.eq(tl[1].t1, 0.7, "gap closed to the next word")
H.eq(S.at(tl, -1), nil, "before the first word"); H.eq(S.at(tl, 0.1), 1, "first word"); H.eq(S.at(tl, 0.75), 2, "second word"); H.eq(S.at(tl, 5), 2, "after the end stays on the last")
H.done("test_segment")
