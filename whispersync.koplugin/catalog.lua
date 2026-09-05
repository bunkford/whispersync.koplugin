--[[--
Catalog helpers: what the shelf knows about each book and how it is shown.

Pure functions over catalog entries so they can be tested on a desktop. An
entry is the syncMetaData item (asin, title, authors, content_type,
content_size, content_tags, ...) enriched over time with:

  meta          -- from the MOBI header: title, author, publisher, isbn,
                   published, text_length, acr
  cover         -- path to a cover image file
  file          -- downloaded book file, downloaded_at
  guid          -- Amazon's book guid (needed for writes)
  remote_pos, furthest_pos, remote_epoch, remote_read  -- from the sidecar
  annotation_count
  header_fetched, cover_fetched  -- immutable data, fetched once
]]

local M = {}

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
M.trim = trim

--- Personal-document titles are filename-derived ("Moby Dick - Herman
-- Melville", "book.epub"). With the author known from EXTH the suffix can go.
function M.clean_title(title, author)
    local t = trim(title)
    t = t:gsub("%.[Ee][Pp][Uu][Bb]$", ""):gsub("%.[Mm][Oo][Bb][Ii]$", ""):gsub("%.[Aa][Zz][Ww]3?$", ""):gsub("%.[Pp][Dd][Ff]$", "")
    t = t:gsub("_", " ")
    local a = trim(author)
    if a ~= "" then
        local lower_t, lower_a = t:lower(), a:lower()
        for _, sep in ipairs({ " - ", " – ", " — ", " by " }) do
            local suffix = sep .. lower_a
            if #lower_t > #suffix and lower_t:sub(-#suffix) == suffix then
                return trim(t:sub(1, #t - #suffix))
            end
            local prefix = lower_a .. sep
            if #lower_t > #prefix and lower_t:sub(1, #prefix) == prefix then
                return trim(t:sub(#prefix + 1))
            end
        end
    end
    return t
end

function M.title(item)
    local meta = item.meta or {}
    local author = M.author(item)
    if meta.title and meta.title ~= "" and not meta.title:match("^CR!") then
        return M.clean_title(meta.title, author)
    end
    return M.clean_title(item.title ~= "" and item.title or item.asin, author)
end

function M.author(item)
    local meta = item.meta or {}
    if meta.author and meta.author ~= "" then return trim(meta.author) end
    if item.authors and item.authors ~= "" then return trim(item.authors) end
    -- Filename-derived "Title - Author" is the only other source.
    local t = trim(item.title)
    local tail = t:match(" %- ([^%-]+)$")
    if tail and #tail < 40 and not tail:match("%d") then return trim(tail) end
    return ""
end

function M.is_dictionary(item)
    return (item.content_tags or ""):find("DICT", 1, true) ~= nil
end

function M.is_document(item)
    return item.content_type == "PDOC"
end

function M.is_downloaded(item, exists)
    if not item.file then return false end
    if exists then return exists(item.file) end
    return true
end

function M.is_pdf(item)
    return item.file ~= nil and item.file:lower():sub(-4) == ".pdf"
end

--- 0..100, or nil when unknown.
function M.percent(item)
    local pos = item.remote_pos
    local len = item.meta and item.meta.text_length or item.text_length
    if pos == nil or not len or len <= 0 then return nil end
    return math.max(0, math.min(100, pos / len * 100))
end

function M.is_finished(item)
    local p = M.percent(item)
    return p ~= nil and p >= 99.5
end

function M.human_size(n)
    n = tonumber(n)
    if not n then return "" end
    if n >= 1024 * 1024 then return ("%.1f MB"):format(n / 1024 / 1024) end
    return ("%d KB"):format(math.floor(n / 1024 + 0.5))
end

--- The short status shown under a cover.
function M.status_text(item, opts)
    opts = opts or {}
    if not M.is_document(item) then return opts.store_label or "Store · DRM" end
    local p = M.percent(item)
    local parts = {}
    if p then
        if p >= 99.5 then parts[#parts + 1] = opts.finished_label or "Finished"
        elseif p < 0.5 and not item.remote_epoch then parts[#parts + 1] = opts.new_label or "New"
        else parts[#parts + 1] = ("%d%%"):format(math.floor(p + 0.5)) end
    elseif item.remote_pos == nil and item.header_fetched then
        parts[#parts + 1] = opts.new_label or "New"
    end
    if M.is_downloaded(item, opts.exists) then
        parts[#parts + 1] = M.is_pdf(item) and "PDF" or (opts.on_device_label or "On device")
    elseif item.content_size then
        parts[#parts + 1] = M.human_size(item.content_size)
    end
    return table.concat(parts, " · ")
end

--- Most recent activity, for "recent" sorting: Amazon's last read, else the
-- download time, else when it appeared in the library.
function M.recency(item)
    return item.remote_epoch or item.downloaded_at or item.purchase_epoch or 0
end

local SORTS = {
    recent = function(a, b)
        local ra, rb = M.recency(a), M.recency(b)
        if ra ~= rb then return ra > rb end
        return M.title(a):lower() < M.title(b):lower()
    end,
    title = function(a, b)
        local ta, tb = M.title(a):lower(), M.title(b):lower()
        if ta ~= tb then return ta < tb end
        return a.asin < b.asin
    end,
    author = function(a, b)
        local aa, ab = M.author(a):lower(), M.author(b):lower()
        if aa ~= ab then
            if aa == "" then return false end
            if ab == "" then return true end
            return aa < ab
        end
        return M.title(a):lower() < M.title(b):lower()
    end,
}
M.SORT_MODES = { "recent", "title", "author" }

--- Filter and sort the catalog for display.
function M.shelf_items(catalog, opts)
    opts = opts or {}
    local list = {}
    for _, it in pairs(catalog) do
        local keep = not M.is_dictionary(it)
        if keep and not M.is_document(it) and not opts.show_store then keep = false end
        if keep and opts.downloaded_only and not M.is_downloaded(it, opts.exists) then keep = false end
        if keep and opts.query and opts.query ~= "" then
            local q = opts.query:lower()
            keep = M.title(it):lower():find(q, 1, true) ~= nil or M.author(it):lower():find(q, 1, true) ~= nil
        end
        if keep then list[#list + 1] = it end
    end
    table.sort(list, SORTS[opts.sort or "recent"] or SORTS.recent)
    return list
end

--- Merge a library listing into the catalog. Never deletes entries that have
-- a downloaded file; incremental listings omit unchanged store books.
function M.merge(catalog, items, removed, now)
    now = now or os.time()
    local added = 0
    for _, it in ipairs(items) do
        local cur = catalog[it.asin]
        if not cur then cur = {}; added = added + 1 end
        for k, v in pairs(it) do
            if v ~= nil and v ~= "" then cur[k] = v elseif cur[k] == nil then cur[k] = v end
        end
        cur.seen_at = now
        cur.purchase_epoch = cur.purchase_epoch or M.parse_iso(it.purchase_date)
        catalog[it.asin] = cur
    end
    for _, asin in ipairs(removed or {}) do
        local cur = catalog[asin]
        if cur and not cur.file then catalog[asin] = nil end
    end
    return added
end

--- "2026-02-07T13:05:12+0000" / "2026-02-07 13:05:12" -> epoch (UTC), or nil.
function M.parse_iso(s)
    if not s or s == "" then return nil end
    local Y, Mo, D, h, m, sec = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)")
    if not Y then return nil end
    local t = os.time({ year = tonumber(Y), month = tonumber(Mo), day = tonumber(D),
                        hour = tonumber(h), min = tonumber(m), sec = tonumber(sec), isdst = false })
    if not t then return nil end
    local now = os.time()
    return t + os.difftime(now, os.time(os.date("!*t", now)))
end

--- Record what the MOBI header told us.
function M.apply_header(item, hdr)
    item.meta = item.meta or {}
    for _, k in ipairs({ "title", "author", "publisher", "isbn", "published", "subject", "text_length" }) do
        if hdr[k] ~= nil then item.meta[k] = hdr[k] end
    end
    item.meta.acr = hdr.palm_name
    item.text_length = hdr.text_length or item.text_length
    item.encrypted = hdr.encrypted
    item.header_fetched = true
end

--- Record what the sidecar told us.
function M.apply_sidecar(item, sc)
    if sc == nil then
        item.remote_checked_at = os.time()
        return
    end
    if sc.guid and sc.guid ~= "" then item.guid = sc.guid end
    if sc.position ~= nil then
        item.remote_pos = sc.position
        item.furthest_pos = sc.furthest_position
        item.remote_epoch = sc.last_read_epoch
        item.remote_read = sc.last_read
    end
    item.annotation_count = #(sc.annotations or {})
    item.remote_checked_at = os.time()
end

function M.cover_path(dir, asin, kind)
    return ("%s/covers/%s.%s"):format(dir, asin, kind == "png" and "png" or kind == "gif" and "gif" or "jpg")
end

--- Multi-line details for the info dialog.
function M.details(item, opts)
    opts = opts or {}
    local meta = item.meta or {}
    local lines = {}
    local function add(label, value)
        if value ~= nil and value ~= "" then lines[#lines + 1] = label .. ": " .. tostring(value) end
    end
    lines[#lines + 1] = M.title(item)
    local author = M.author(item)
    if author ~= "" then lines[#lines + 1] = author end
    lines[#lines + 1] = ""
    local p = M.percent(item)
    if p then
        add("Progress", ("%.1f%%"):format(p) .. (item.remote_read and (" (Amazon, " .. item.remote_read:sub(1, 16) .. " UTC)") or ""))
    elseif item.header_fetched then
        add("Progress", "never opened on a Kindle")
    end
    local fp = item.furthest_pos
    if fp and item.text_length and item.text_length > 0 and item.remote_pos and fp > item.remote_pos then
        add("Furthest read", ("%.1f%%"):format(math.min(100, fp / item.text_length * 100)))
    end
    add("Annotations", item.annotation_count)
    add("Publisher", meta.publisher)
    add("ISBN", meta.isbn)
    add("Published", meta.published)
    add("Size", M.human_size(item.content_size))
    add("Type", M.is_document(item) and "Personal document" or "Store purchase (DRM)")
    add("File", item.file or "not downloaded")
    add("Amazon guid", (item.guid and item.guid ~= "") and "yes, position sync possible" or "none yet: open once on a Kindle")
    add("Key", item.asin)
    return table.concat(lines, "\n")
end

return M
