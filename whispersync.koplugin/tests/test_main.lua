local H = require("helpers")
package.path = H.here .. "vendor/?.lua;" .. package.path
require("kostubs")
local Whispersync = require("main")
local mobi = require("mobi")

-- A reader session over the fixture MOBI, with a crengine-like fake document
-- (same shape as in test_posmap) so posmap() and currentOffset() run for real.
local fixture = H.here .. "fixture/fixture.mobi"
local text = assert(mobi.extract_text(H.read(fixture)))
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
local function xp_for(i, off) return ("/body/p[%d]/text().%d"):format(i, off) end
local function parse_xp(xp) local i, c = xp:match("p%[(%d+)%]/text%(%)%.?(%d*)"); return tonumber(i), tonumber(c) or 0 end
local doc = {
    file = fixture,
    info = { has_pages = false },
    getPageCount = function() return PAGES end,
    getTextFromXPointer = function(_, xp) return paras[(parse_xp(xp))] end,
    getPageFromXPointer = function(_, xp) local i, c = parse_xp(xp); return math.max(1, math.ceil((starts[i] + c) / #idx.plain * PAGES)) end,
    getPageXPointer = function(_, page)
        local target = (page - 1) / PAGES * #idx.plain
        for i = #paras, 1, -1 do if starts[i] <= target then return xp_for(i, 0) end end
        return xp_for(1, 0)
    end,
    findAllText = function(_, pattern, ci, ctx, max_hits)
        local hits = {}
        for i, para in ipairs(paras) do
            local a, b = para:find(pattern, 1, true)
            if a then hits[#hits + 1] = { start = xp_for(i, a - 1), ["end"] = xp_for(i, b) } end
            if #hits >= max_hits then break end
        end
        return hits
    end,
    getXPointer = function() return xp_for(200, 0) end,
}
local saved = {}
local ws = Whispersync:new{
    ui = {
        menu = { registerToMainMenu = function() end },
        document = doc,
        doc_settings = { readSetting = function(_, k) return saved[k] end, saveSetting = function(_, k, v) saved[k] = v end },
    },
}

os.remove(fixture .. ".sdr/whispersync.index"); os.remove(fixture .. ".sdr")
os.execute("mkdir -p '" .. fixture .. ".sdr'")

-- Not a Kindle book until the catalog says so.
H.eq(ws:currentBook(), nil, "unknown file is not a Kindle book")
ws.catalog["TESTPDOCKEY0123456789ABCDEFGHIJK"] = { asin = "TESTPDOCKEY0123456789ABCDEFGHIJK", content_type = "PDOC", file = fixture, title = "Fixture" }
ws._book_for_file = nil
local book = ws:currentBook()
H.ok(book, "catalog entry found by file path")

-- This is the call that crashed on the device: it must build a real index.
local pm = ws:posmap()
H.ok(pm, "posmap built")
H.ok(not pm.percent_only, "text-based mapping, not the percent fallback")
H.eq(book.text_length, #text, "text_length recorded from the header")
H.eq(book.meta.acr, "CR!FIXTUREACRNAME00000000000000", "acr recorded from the header")
H.ok(io.open(fixture .. ".sdr/whispersync.index", "rb"), "index cached beside the sdr")

-- Current position maps by text and round-trips.
local off, method = ws:currentOffset()
H.eq(method, "text", "current offset resolved by text")
local raw200 = text:find(paras[200]:sub(1, 40), 1, true) - 1
H.eq(off, raw200, "current offset is the 200th node's first byte")

-- Second call reuses the cache (no re-extraction) and the same object.
H.eq(ws:posmap(), pm, "posmap memoised per file")
ws._posmap = nil
local pm2 = ws:posmap()
H.ok(pm2 and not pm2.percent_only, "index loads from cache")

-- A file that is not MOBI falls back to the percent-only mapper instead of crashing.
local other = os.tmpname(); local f = io.open(other, "wb"); f:write("not a book"); f:close()
os.execute("mkdir -p '" .. other .. ".sdr'")
ws.catalog.X = { asin = "X", content_type = "PDOC", file = other, title = "Junk", text_length = 1000 }
doc.file = other
ws._book_for_file = nil; ws._posmap = nil
local pm3 = ws:posmap()
H.ok(pm3 and pm3.percent_only, "non-MOBI file gets the percent-only mapper")
local o3 = pm3:to_offset(xp_for(200, 0))
H.ok(o3 >= 0 and o3 <= 1000, "percent-only offset within text_length")
os.remove(other)


-- ZenOS launcher calls open() on the module table: no live instance, no crash.
H.eq(Whispersync.liveInstance(), nil, "no live UI in tests")
H.eq(Whispersync.open(Whispersync), true, "open() on the class is harmless without a UI")
H.eq(Whispersync.open(ws), true, "open() on an instance works")

-- Shelf items honour the settings; status text renders without a document.
ws.catalog = {
    A = { asin = "A", title = "Persuasion - Jane Austen", content_type = "PDOC", content_size = 1000000, file = fixture, text_length = 900000, remote_pos = 450000, remote_epoch = 1000 },
    B = { asin = "B", title = "Never opened", content_type = "PDOC", content_size = 2000 },
    S = { asin = "S", title = "Store", content_type = "EBOK" },
}
ws.settings.show_store_books = false
H.eq(#ws:shelfItems(), 2, "store books hidden by default")
ws.settings.show_store_books = true
H.eq(#ws:shelfItems(), 3, "store books shown when asked")
ws.settings.downloaded_only = true
H.eq(#ws:shelfItems(), 1, "downloaded-only filter")
ws.settings.downloaded_only = false

-- enrichItem against a mock client: header metadata, cover extraction, position.
local blob = H.read(fixture)
local prefix = blob:sub(1, 32768)
local mock = {
    download = function(_, key, ctype, dest, range)
        local f = io.open(dest, "wb"); f:write(range and blob:sub(1, range) or blob); f:close(); return true
    end,
    download_range = function(_, key, ctype, dest, first, last)
        local f = io.open(dest, "wb"); f:write(blob:sub(first + 1, last + 1)); f:close(); return true
    end,
    sidecar = function(_, key)
        return { guid = "G1", position = 27000, furthest_position = 30000, last_read_epoch = 1234, last_read = "2026-01-01 00:00:00.0", annotations = { {} } }
    end,
}
local tmpdir = os.tmpname(); os.remove(tmpdir); os.execute("mkdir -p '" .. tmpdir .. "'")
ws.settings.library_dir = tmpdir
local item = { asin = "TESTPDOCKEY0123456789ABCDEFGHIJK", title = "fixture.mobi", content_type = "PDOC", content_size = #blob }
H.ok(ws:enrichItem(mock, item, { header = true, cover = true, position = true }), "enrich reports a change")
H.eq(item.meta.title, "Nineteen Eighty-Four (fixture)", "EXTH title applied")
H.eq(item.meta.author, "George Orwell, Second Author", "EXTH author applied")
H.eq(item.text_length, #text, "text_length applied")
H.ok(item.cover and item.cover:match("%.jpg$"), "cover saved as jpg")
H.eq(H.read(item.cover):sub(1, 3), "\255\216\255", "cover file is the JPEG record")
H.eq(item.guid, "G1", "guid recorded")
H.near(require("catalog").percent(item), 27000 / #text * 100, 0.01, "percent from sidecar and header")
H.eq(item.annotation_count, 1, "annotation count")
H.eq(item.header_fetched, true, "header marked fetched")
H.eq(ws:enrichItem(mock, item, { header = true, cover = true }), false, "immutable data is not fetched twice")
os.execute("rm -rf '" .. tmpdir .. "'")

os.execute("rm -rf '" .. fixture .. ".sdr'")
H.done("test_main")
