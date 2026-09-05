local H = require("helpers")
local mobi = require("mobi")

-- 1. Opcode torture stream against the Python oracle.
local torture = H.read(H.here .. "fixture/torture.bin")
H.eq(mobi.palmdoc_decompress(torture), H.read(H.here .. "fixture/torture.expected"), "palmdoc opcodes")

-- 2. Header parsing on the synthetic MOBI.
local blob = H.read(H.here .. "fixture/fixture.mobi")
local html = H.read(H.here .. "fixture/fixture.html")
local hdr = assert(mobi.parse_header(blob))
H.eq(hdr.title, "Nineteen Eighty-Four (fixture)", "EXTH 503 title")
H.eq(hdr.author, "George Orwell, Second Author", "repeated author records joined")
H.eq(hdr.asin, "TESTPDOCKEY0123456789ABCDEFGHIJK", "EXTH 113 asin")
H.eq(hdr.text_length, #html, "text_length")
H.eq(hdr.compression, 2, "compression")
H.eq(hdr.encrypted, false, "not encrypted")
H.eq(hdr.extra_flags, 3, "extra_flags at record0+242")
H.eq(hdr.palm_name, "CR!FIXTUREACRNAME00000000000000", "palm name")

-- Header parses from a 32 KB prefix too (that's what the Range fetch gives).
local prefix = blob:sub(1, 32768)
H.eq(assert(mobi.parse_header(prefix)).text_length, #html, "header from prefix")

-- 3. Full text extraction: byte-exact, trailing entries stripped.
local text, hdr2 = mobi.extract_text(blob)
H.ok(text, "extract_text ok")
H.eq(#text, #html, "extracted length equals text_length")
H.eq(text, html, "extracted text byte-exact")

-- 4. DRM refusal without touching records.
local drm = blob:sub(1, hdr.offsets[1] + 12) .. "\0\2" .. blob:sub(hdr.offsets[1] + 15)
local t, err = mobi.extract_text(drm)
H.eq(t, nil, "encrypted refused")
H.ok(err:find("DRM"), "refusal names DRM")

-- 5. Plain-text index and coordinate mapping.
local idx = mobi.build_index(text)
H.ok(#idx.plain < #text, "plain shorter than html")
H.ok(idx.plain:find("Winston Smith, his chin nuzzled into his breast & his coat", 1, true), "entity decoded, text preserved")
H.ok(idx.plain:find("caf\195\169 and \226\128\156quotes\226\128\157", 1, true), "named + numeric entities")
H.ok(idx.plain:find("old rag mats. At one end", 1, true), "whitespace run collapsed")
H.ok(idx.plain:find("Chapter One\nIt was a bright", 1, true), "block tags become paragraph breaks")

-- A raw offset in the middle of a word maps to that word, and back.
local raw = assert(text:find("clocks were striking thirteen", 1, true)) - 1
local p = mobi.plain_from_raw(idx, raw)
H.eq(idx.plain:sub(p, p + 5), "clocks", "raw -> plain lands on the word")
H.eq(mobi.raw_from_plain(idx, p), raw, "plain -> raw round trip")

-- A raw offset inside a tag snaps forward to the next visible character.
local tag_raw = assert(text:find("<h2>", 1, true)) - 1 + 1
local p2 = mobi.plain_from_raw(idx, tag_raw)
H.eq(idx.plain:sub(p2, p2 + 10), "Chapter Two", "offset inside tag snaps to following text")

-- After an entity, mapping stays exact.
local raw3 = assert(text:find("his coat, slipped", 1, true)) - 1
local p3 = mobi.plain_from_raw(idx, raw3)
H.eq(idx.plain:sub(p3, p3 + 7), "his coat", "mapping exact after entity")
H.eq(mobi.raw_from_plain(idx, p3), raw3, "round trip after entity")

-- Snippets stop at paragraph breaks and whole words.
local snip, s = mobi.snippet_at(idx, p, 30)
H.ok(#snip <= 30 and snip:sub(1, 6) == "clocks", "snippet starts at the word, bounded")
H.ok(not snip:find("\n"), "snippet has no paragraph break")
local last_para = assert(idx.plain:find("The end of the fixture text.", 1, true))
local snip2 = mobi.snippet_at(idx, last_para + 4, 200)
H.eq(snip2, "end of the fixture text.", "snippet clipped at paragraph end")

-- Repeated phrases: find_all returns every hit.
local hits = mobi.find_all(idx, "the clocks were striking", 1000)
H.ok(#hits >= 398, "repeated phrase found " .. #hits .. " times")

-- 6. Index round-trips through the cache file.
local tmp = os.tmpname()
H.ok(mobi.save_index(idx, tmp), "save_index")
local idx2 = assert(mobi.load_index(tmp))
H.eq(idx2.plain, idx.plain, "cached plain text identical")
H.eq(idx2.nseg, idx.nseg, "cached segment count identical")
H.eq(mobi.plain_from_raw(idx2, raw), p, "cached index maps identically")
os.remove(tmp)

-- 7. Cover record located from the 32 KB prefix; image kind sniffed.
local cs, ce = mobi.cover_record(prefix, #blob)
H.ok(cs and ce and ce > cs, "cover record range found")
local img = blob:sub(cs + 1, ce + 1)
H.eq(mobi.image_kind(img), "jpeg", "cover is a JPEG")
H.eq(#img, 4 + 8 * 200, "cover record is exactly the image record")
H.eq(mobi.image_kind("GIF89a..."), "gif", "gif sniffed")
H.eq(mobi.image_kind("hello world"), nil, "non-image rejected")

-- 8. Uncompressed (type 1) files decode too.
H.eq(mobi.normalize("  a\n\n b\194\160c  "), "a b c", "normalize")

H.done("test_mobi")
