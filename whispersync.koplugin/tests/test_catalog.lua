local H = require("helpers")
local C = require("catalog")

H.eq(C.clean_title("Moby Dick - Herman Melville", "Herman Melville"), "Moby Dick", "author suffix stripped")
H.eq(C.clean_title("Herman Melville - Moby Dick", "Herman Melville"), "Moby Dick", "author prefix stripped")
H.eq(C.clean_title("my_book.epub", ""), "my book", "extension and underscores cleaned")
H.eq(C.clean_title("Emma - A Novel", "Jane Austen"), "Emma - A Novel", "unrelated suffix kept")
H.eq(C.clean_title("Persuasion", "jane austen"), "Persuasion", "plain title untouched")

local it = { asin = "A", title = "Persuasion - Jane Austen", authors = "", content_type = "PDOC", content_size = 1258291 }
H.eq(C.author(it), "Jane Austen", "author recovered from filename title")
H.eq(C.title(it), "Persuasion", "title cleaned using recovered author")
C.apply_header(it, { title = "Persuasion: A Novel", author = "Jane Austen", text_length = 900000, palm_name = "CR!X", encrypted = false })
H.eq(C.title(it), "Persuasion: A Novel", "EXTH title preferred")
H.eq(C.percent(it), nil, "no position yet")
H.eq(C.status_text(it), "New · 1.2 MB", "new book status")
C.apply_sidecar(it, { guid = "G", position = 450000, furthest_position = 500000, last_read_epoch = 1000, last_read = "2026-01-01 00:00:00.0", annotations = { {}, {} } })
H.near(C.percent(it), 50, 0.01, "percent from position / text_length")
H.eq(C.status_text(it), "50% · 1.2 MB", "status with percent and size")
it.file = "/x/Persuasion.mobi"
H.eq(C.status_text(it), "50% · On device", "on device")
H.eq(C.status_text(it, { exists = function() return false end }), "50% · 1.2 MB", "missing file is not on device")
it.remote_pos = 899600
H.eq(C.status_text(it), "Finished · On device", "finished")
H.eq(C.status_text({ asin = "B", title = "Store", content_type = "EBOK" }), "Store · DRM", "store status")
H.eq(C.is_dictionary({ content_tags = "DICT, FREE_DICT" }), true, "dictionary")
H.ok(C.details(it):find("Progress: 100.0%%", 1, false) or C.details(it):find("Progress: 99.9", 1, true), "details include progress")
H.ok(C.details(it):find("Annotations: 2", 1, true), "details include annotations")

-- Sorting and filtering.
local cat = {
    A = { asin = "A", title = "Zebra", content_type = "PDOC", remote_epoch = 100 },
    B = { asin = "B", title = "Apple - Ann Author", content_type = "PDOC", remote_epoch = 300 },
    C = { asin = "C", title = "Mango", content_type = "PDOC", downloaded_at = 200, file = "/m" },
    D = { asin = "D", title = "Dict", content_type = "EBOK", content_tags = "DICT" },
    E = { asin = "E", title = "Store book", content_type = "EBOK" },
}
local function titles(list) local t = {}; for _, x in ipairs(list) do t[#t + 1] = x.asin end; return table.concat(t) end
H.eq(titles(C.shelf_items(cat, { sort = "recent" })), "BCA", "recent: Amazon read, then download, then rest")
H.eq(titles(C.shelf_items(cat, { sort = "title" })), "BCA", "title order (Apple, Mango, Zebra)")
H.eq(titles(C.shelf_items(cat, { sort = "author" })), "BCA", "author order: known authors first, then by title")
H.eq(titles(C.shelf_items(cat, { show_store = true, sort = "title" })), "BCEA", "store books when asked")
H.eq(titles(C.shelf_items(cat, { downloaded_only = true })), "C", "downloaded filter")
H.eq(titles(C.shelf_items(cat, { query = "ann" })), "B", "query matches author")

-- Merge keeps downloaded files, honours removals, counts additions.
local n = C.merge(cat, { { asin = "F", title = "New", content_type = "PDOC", purchase_date = "2026-02-07T13:05:12+0000" }, { asin = "A", title = "Zebra", content_type = "PDOC" } }, { "C", "E" }, 5)
H.eq(n, 1, "one new")
H.ok(cat.C ~= nil, "downloaded book survives removal")
H.eq(cat.E, nil, "undownloaded removed")
H.eq(cat.A.remote_epoch, 100, "existing enrichment kept on merge")
H.eq(os.date("!%Y-%m-%d %H", cat.F.purchase_epoch), "2026-02-07 13", "purchase date parsed as UTC")
H.eq(C.cover_path("/d", "X", "png"), "/d/covers/X.png", "cover path")

H.done("test_catalog")
