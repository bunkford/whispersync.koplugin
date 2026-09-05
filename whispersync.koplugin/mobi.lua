--[[--
MOBI file handling for the Whispersync plugin.

Three jobs, all of them needed because a Kindle reading position is a byte
offset into the *decompressed* text of the MOBI7 part of the book:

  1. Read the PalmDB / PalmDOC / MOBI / EXTH headers (title, author, ASIN,
     text length, compression, encryption).
  2. Decompress the PalmDOC text records into the raw HTML the Kindle indexes.
  3. Build a plain-text index over that HTML, so a byte offset can be turned
     into the words at that point (and back again).

Nothing here decrypts anything. Store purchases carry `encryption=2` and are
refused before a single text record is touched; Send-to-Kindle personal
documents are `encryption=0` and are simply compressed.

Two traps recorded in this repo's README and honoured here:

  * `extra_flags` (the trailing-entry descriptor) lives at record0 + 242, and
    the trailing bytes must be stripped *before* decompression or the tail of
    every record decodes as scrambled words.
  * The EXTH-present flag in the MOBI header is unreliable; look for the
    "EXTH" magic instead. The real title is EXTH 503.
]]

local M = {}

local byte, sub, char, concat = string.byte, string.sub, string.char, table.concat

local function u16(s, i) -- i is a 0-based offset
    local a, b = byte(s, i + 1, i + 2)
    if not b then return nil end
    return a * 256 + b
end

local function u32(s, i)
    local a, b, c, d = byte(s, i + 1, i + 4)
    if not d then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

M.EXTH_TEXT = {
    [100] = "author", [101] = "publisher", [103] = "description", [104] = "isbn",
    [105] = "subject", [106] = "published", [113] = "asin", [503] = "title",
    [504] = "asin_alt",
}
M.EXTH_NUM = { [121] = "kf8_boundary", [201] = "cover_offset", [202] = "thumb_offset" }

--- Is this buffer a MOBI-family file?
function M.is_mobi(buf)
    return buf ~= nil and #buf >= 82 and sub(buf, 61, 68) == "BOOKMOBI"
end

--- PalmDB record offsets (0-based), or nil if the table is truncated.
function M.record_table(buf)
    if #buf < 78 then return nil end
    local n = u16(buf, 76)
    if #buf < 78 + 8 * n then return nil end
    local offs = {}
    for i = 0, n - 1 do
        offs[i + 1] = u32(buf, 78 + 8 * i)
    end
    return offs
end

--- Parse the headers at the front of a MOBI file.
-- `buf` may be a prefix of the file (32 KB is plenty) or the whole thing.
-- Returns a table, or nil plus a reason when the bytes are not MOBI.
function M.parse_header(buf)
    if not M.is_mobi(buf) then
        return nil, "not a MOBI file"
    end
    local out = {}
    out.palm_name = sub(buf, 1, 32):match("^[^%z]*")
    local offs = M.record_table(buf)
    if not offs then return nil, "truncated record table" end
    out.record_count = #offs
    out.offsets = offs
    local rec0 = offs[1]
    if #buf < rec0 + 16 then return nil, "truncated record 0" end

    out.compression = u16(buf, rec0)
    out.text_length = u32(buf, rec0 + 4)
    out.text_records = u16(buf, rec0 + 8)
    out.record_size = u16(buf, rec0 + 10)
    out.encryption = u16(buf, rec0 + 12)
    out.encrypted = out.encryption ~= 0

    local m = rec0 + 16
    if sub(buf, m + 1, m + 4) ~= "MOBI" then
        out.extra_flags = 0
        return out
    end
    local mobi_len = u32(buf, m + 4)
    out.mobi_header_length = mobi_len
    out.mobi_type = u32(buf, m + 8)
    out.text_encoding = u32(buf, m + 12)
    -- first_image_index is at MOBI+92 (not the widely quoted +108).
    out.first_image_index = u32(buf, m + 92)
    -- Trailing-entry flags: documented offset 242 from the start of record 0,
    -- present only when the header is long enough to reach it.
    if mobi_len >= 0xE4 and #buf >= rec0 + 244 then
        out.extra_flags = u16(buf, rec0 + 242)
    else
        out.extra_flags = 0
    end

    -- EXTH follows the MOBI header. Don't trust the flag, find the magic.
    local e = m + mobi_len
    if sub(buf, e + 1, e + 4) ~= "EXTH" then
        local found = buf:find("EXTH", m + 1, true)
        if not found or found > m + 4096 then return out end
        e = found - 1
    end
    local count = u32(buf, e + 8)
    if not count then return out end
    local p = e + 12
    for _ = 1, math.min(count, 256) do
        if p + 8 > #buf then break end
        local rtype, rlen = u32(buf, p), u32(buf, p + 4)
        if not rlen or rlen < 8 or p + rlen > #buf then break end
        local raw = sub(buf, p + 9, p + rlen)
        if M.EXTH_NUM[rtype] then
            if #raw == 4 and out[M.EXTH_NUM[rtype]] == nil then
                out[M.EXTH_NUM[rtype]] = u32(raw, 0)
            end
        elseif M.EXTH_TEXT[rtype] then
            local val = raw:gsub("%z", ""):match("^%s*(.-)%s*$")
            if val ~= "" then
                local key = M.EXTH_TEXT[rtype]
                if (key == "author" or key == "subject") and out[key] then
                    if not (", " .. out[key] .. ", "):find(", " .. val .. ", ", 1, true) then
                        out[key] = out[key] .. ", " .. val
                    end
                elseif out[key] == nil then
                    out[key] = val
                end
            end
        end
        p = p + rlen
    end
    if out.title == nil and out.palm_name ~= "" then
        out.title = out.palm_name
    end
    return out
end

--- Remove the trailing entries MOBI appends to a text record.
-- Must happen before decompression. Each flagged entry is length-prefixed
-- backwards (varint in the final bytes, bit 7 marks the end); bit 0 is a
-- multibyte overlap whose length is in the last byte's low bits.
function M.strip_extra_bytes(rec, extra_flags)
    if not extra_flags or extra_flags == 0 then return rec end
    -- Entries are stored in ascending flag order, so the highest bit's entry
    -- is last in the record: strip from bit 15 down to bit 1, then the
    -- multibyte overlap (bit 0), which sits closest to the text.
    for bit = 15, 1, -1 do
        if math.floor(extra_flags / 2 ^ bit) % 2 == 1 then
            local n, shift = 0, 0
            local len = #rec
            for i = len, math.max(1, len - 3), -1 do
                local b = byte(rec, i)
                n = n + (b % 128) * (2 ^ shift)
                shift = shift + 7
                if b >= 128 then break end
            end
            if n <= 0 or n > #rec then break end
            rec = sub(rec, 1, #rec - n)
        end
    end
    if extra_flags % 2 == 1 and #rec > 0 then
        local n = byte(rec, #rec) % 4
        rec = sub(rec, 1, #rec - n - 1)
    end
    return rec
end

--- PalmDOC (compression type 2) decompression of one record.
function M.palmdoc_decompress(data)
    local out, n_out = {}, 0
    local i, n = 1, #data
    while i <= n do
        local b = byte(data, i)
        i = i + 1
        if b == 0 then
            n_out = n_out + 1; out[n_out] = 0
        elseif b <= 8 then
            for k = i, math.min(n, i + b - 1) do
                n_out = n_out + 1; out[n_out] = byte(data, k)
            end
            i = i + b
        elseif b <= 0x7F then
            n_out = n_out + 1; out[n_out] = b
        elseif b <= 0xBF then
            if i > n then break end
            local pair = b * 256 + byte(data, i)
            i = i + 1
            local dist = math.floor(pair / 8) % 2048
            local length = pair % 8 + 3
            if dist == 0 or dist > n_out then break end
            local start = n_out - dist
            for k = 1, length do
                n_out = n_out + 1
                out[n_out] = out[start + k]
            end
        else
            n_out = n_out + 1; out[n_out] = 0x20
            n_out = n_out + 1; out[n_out] = b - 128
        end
    end
    -- string.char has an argument limit; join in chunks.
    local parts, CH = {}, 4096
    for s = 1, n_out, CH do
        parts[#parts + 1] = char(unpack(out, s, math.min(n_out, s + CH - 1)))
    end
    return concat(parts)
end

--- Decompress the whole text of a MOBI file held in memory.
-- Returns the raw HTML string (exactly `text_length` bytes when the header is
-- honest) and the parsed header, or nil plus a reason. Refuses DRM'd files.
function M.extract_text(buf)
    local hdr, err = M.parse_header(buf)
    if not hdr then return nil, err end
    if hdr.encrypted then
        return nil, "this book is DRM-protected; only personal documents can be read"
    end
    if hdr.compression ~= 1 and hdr.compression ~= 2 then
        return nil, ("unsupported compression type %d (HUFF/CDIC is used by store books)"):format(hdr.compression)
    end
    local offs = hdr.offsets
    local parts = {}
    for r = 1, hdr.text_records do
        local s = offs[r + 1]
        local e = offs[r + 2] and (offs[r + 2] - 1) or #buf
        if not s or s >= #buf then break end
        local rec = sub(buf, s + 1, e + 1)
        rec = M.strip_extra_bytes(rec, hdr.extra_flags)
        if hdr.compression == 2 then
            rec = M.palmdoc_decompress(rec)
        end
        parts[#parts + 1] = rec
    end
    local text = concat(parts)
    if hdr.text_length and #text > hdr.text_length then
        text = sub(text, 1, hdr.text_length)
    end
    return text, hdr
end

--- Byte range (start, end_inclusive) of the embedded cover image, or nil.
-- Covers live in an image record; locating one needs first_image_index from
-- the MOBI header (at MOBI+92, not the widely quoted +108) plus EXTH 201
-- (or 202 for the thumbnail) as an offset from it. Works on a 32 KB prefix.
-- `file_size` (the listing's content_size) bounds the last record when only
-- a prefix of the file is in hand.
function M.cover_record(buf, file_size)
    local hdr = M.parse_header(buf)
    if not hdr or not hdr.offsets or not hdr.first_image_index then return nil end
    local offs = hdr.offsets
    local first = hdr.first_image_index
    if first <= 0 or first >= #offs then return nil end
    local pick = hdr.cover_offset or hdr.thumb_offset
    if pick == nil then return nil end
    local idx = first + pick + 1 -- offsets[] is 1-based
    if idx > #offs then return nil end
    local last
    if offs[idx + 1] then
        last = offs[idx + 1] - 1
    else
        last = (file_size or #buf) - 1
    end
    if last <= offs[idx] then return nil end
    return offs[idx], last
end

--- "jpeg" | "png" | "gif" from magic bytes, or nil.
function M.image_kind(data)
    if not data or #data < 8 then return nil end
    if data:sub(1, 3) == "\255\216\255" then return "jpeg" end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "png" end
    if data:sub(1, 4) == "GIF8" then return "gif" end
    return nil
end

--- Read a whole file into a string.
function M.read_file(path, max_bytes)
    local f = io.open(path, "rb")
    if not f then return nil, "cannot open " .. tostring(path) end
    local data = f:read(max_bytes or "*a")
    f:close()
    return data
end

-------------------------------------------------------------------------------
-- Plain-text index
-------------------------------------------------------------------------------

local ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = "\194\160",
    mdash = "\226\128\148", ndash = "\226\128\147", hellip = "\226\128\166",
    lsquo = "\226\128\152", rsquo = "\226\128\153", ldquo = "\226\128\156",
    rdquo = "\226\128\157", copy = "\194\169", reg = "\194\174", shy = "",
    laquo = "\194\171", raquo = "\194\187", bull = "\226\128\162",
    trade = "\226\132\162", deg = "\194\176", eacute = "\195\169",
}

local function utf8_char(cp)
    if cp < 0x80 then return char(cp) end
    if cp < 0x800 then
        return char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    end
    if cp < 0x10000 then
        return char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
                0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end
M.utf8_char = utf8_char

local function decode_entity(name)
    if name:sub(1, 1) == "#" then
        local cp
        if name:sub(2, 2):lower() == "x" then
            cp = tonumber(name:sub(3), 16)
        else
            cp = tonumber(name:sub(2))
        end
        if cp and cp > 0 and cp < 0x110000 then return utf8_char(cp) end
        return nil
    end
    return ENTITIES[name]
end

-- Tags whose start marks a paragraph boundary in the plain text.
local BLOCK_TAGS = {
    p = true, div = true, br = true, h1 = true, h2 = true, h3 = true, h4 = true,
    h5 = true, h6 = true, li = true, blockquote = true, hr = true, tr = true,
    td = true, th = true, table = true, pre = true, ul = true, ol = true, dd = true,
    dt = true, ["mbp:pagebreak"] = true, body = true, html = true, title = true,
}

--- Build a plain-text index over raw MOBI HTML.
--
-- The result maps between two coordinate systems:
--   raw   -- 0-based byte offsets into the HTML, i.e. Kindle positions
--   plain -- 1-based byte offsets into `plain`, the visible text with tags
--            removed, entities decoded, whitespace runs collapsed, and a "\n"
--            at every block-level tag
--
-- Segments are stored as parallel arrays (pb, pl, rb, rl): plain start,
-- plain length, raw start, raw length. Inside a segment the mapping is
-- linear; between segments (inside a tag) a raw offset snaps forward to the
-- next visible character, which is where a device-made mark points anyway.
function M.build_index(html)
    local plain_parts, np = {}, 0
    local pb, pl, rb, rl = {}, {}, {}, {}
    local nseg = 0
    local plain_len = 0
    local n = #html
    local i = 1 -- 1-based cursor into html

    local function push(text, raw_start, raw_len)
        if text == "" then return end
        nseg = nseg + 1
        pb[nseg] = plain_len + 1
        pl[nseg] = #text
        rb[nseg] = raw_start
        rl[nseg] = raw_len
        np = np + 1
        plain_parts[np] = text
        plain_len = plain_len + #text
    end

    local last_space = true
    local function push_text(text, raw_start)
        -- Runs of 2+ whitespace chars (or any newline/tab) collapse to one
        -- space; single spaces stay in place so the mapping stays linear.
        local pos = 1
        local len = #text
        while pos <= len do
            local ws_s, ws_e = text:find("[%s]+", pos)
            if not ws_s then
                local chunk = sub(text, pos)
                push(chunk, raw_start + pos - 1, #chunk)
                last_space = false
                break
            end
            if ws_s > pos then
                local chunk = sub(text, pos, ws_s - 1)
                push(chunk, raw_start + pos - 1, #chunk)
                last_space = false
            end
            local run = sub(text, ws_s, ws_e)
            if run == " " and not last_space then
                push(" ", raw_start + ws_s - 1, 1)
                last_space = true
            elseif not last_space then
                push(" ", raw_start + ws_s - 1, ws_e - ws_s + 1)
                last_space = true
            end
            pos = ws_e + 1
        end
    end

    while i <= n do
        local j = html:find("[<&]", i)
        if not j then
            push_text(sub(html, i), i - 1)
            break
        end
        if j > i then
            push_text(sub(html, i, j - 1), i - 1)
        end
        if byte(html, j) == 60 then -- '<'
            local close
            if sub(html, j, j + 3) == "<!--" then
                close = html:find("-->", j + 4, true)
                close = close and (close + 2) or n
            else
                close = html:find(">", j + 1, true) or n
            end
            local name = html:match("^<%s*/?%s*([%w:]+)", j)
            if name and BLOCK_TAGS[name:lower()] and not last_space then
                push("\n", j - 1, close - j + 1)
                last_space = true
            elseif name and BLOCK_TAGS[name:lower()] and nseg > 0 and plain_parts[np] == " " then
                -- Turn a trailing space into a paragraph break instead.
                plain_parts[np] = "\n"
            end
            i = close + 1
        else -- '&'
            local ent_end = html:find(";", j + 1, true)
            local decoded
            if ent_end and ent_end - j <= 10 then
                decoded = decode_entity(sub(html, j + 1, ent_end - 1))
            end
            if decoded then
                if decoded == " " or decoded == "\194\160" then
                    if not last_space then
                        push(" ", j - 1, ent_end - j + 1)
                        last_space = true
                    end
                elseif decoded ~= "" then
                    push(decoded, j - 1, ent_end - j + 1)
                    last_space = false
                end
                i = ent_end + 1
            else
                push("&", j - 1, 1)
                last_space = false
                i = j + 1
            end
        end
    end

    return {
        plain = concat(plain_parts),
        pb = pb, pl = pl, rb = rb, rl = rl, nseg = nseg,
        raw_length = n,
    }
end

local function bsearch_le(arr, n, value)
    -- Largest index k with arr[k] <= value, or 0.
    local lo, hi, ans = 1, n, 0
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if arr[mid] <= value then
            ans = mid; lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return ans
end

--- Kindle position (0-based raw byte) -> 1-based offset into idx.plain.
function M.plain_from_raw(idx, raw)
    if idx.nseg == 0 then return 1 end
    raw = math.max(0, math.floor(raw))
    local k = bsearch_le(idx.rb, idx.nseg, raw)
    if k == 0 then return idx.pb[1] end
    local off = raw - idx.rb[k]
    if off < idx.rl[k] then
        -- Inside this segment: linear where lengths match, otherwise clamp.
        if idx.pl[k] == idx.rl[k] then
            return idx.pb[k] + off
        end
        return idx.pb[k]
    end
    -- In a gap (tag) after segment k: snap to the next visible character.
    if k < idx.nseg then return idx.pb[k + 1] end
    return idx.pb[k] + idx.pl[k]
end

--- 1-based offset into idx.plain -> Kindle position (0-based raw byte).
function M.raw_from_plain(idx, p)
    if idx.nseg == 0 then return 0 end
    p = math.max(1, math.floor(p))
    local k = bsearch_le(idx.pb, idx.nseg, p)
    if k == 0 then return idx.rb[1] end
    local off = p - idx.pb[k]
    if off < idx.pl[k] and idx.pl[k] == idx.rl[k] then
        return idx.rb[k] + off
    end
    if off >= idx.pl[k] and k < idx.nseg then
        return idx.rb[k + 1]
    end
    return idx.rb[k]
end

--- Collapse whitespace and trim, for comparing text from two renderers.
function M.normalize(s)
    if not s then return "" end
    s = s:gsub("\194\160", " "):gsub("%s+", " ")
    return (s:match("^%s*(.-)%s*$"))
end

--- A search snippet starting at plain offset p: up to `max_bytes`, whole
-- words, never crossing a paragraph break. Returns snippet and its plain
-- start (which may have moved forward past leading whitespace).
function M.snippet_at(idx, p, max_bytes)
    max_bytes = max_bytes or 48
    local plain = idx.plain
    local n = #plain
    if n == 0 then return "", 1 end
    p = math.max(1, math.min(p, n))
    -- Skip whitespace / paragraph break at the start.
    local s = plain:find("[^%s]", p) or n
    local para_end = plain:find("\n", s, true)
    para_end = para_end and para_end - 1 or n
    local e = math.min(para_end, s + max_bytes - 1)
    if e < para_end then
        -- Back up to a word boundary so we never search for half a word.
        local cut = plain:sub(s, e):match("^.*()%s")
        if cut and cut > 12 then e = s + cut - 2 end
    end
    -- Never cut a multibyte UTF-8 sequence.
    while e > s and byte(plain, e + 1) and byte(plain, e + 1) >= 0x80 and byte(plain, e + 1) < 0xC0 do
        e = e - 1
    end
    local snip = M.normalize(plain:sub(s, e))
    return snip, s
end

--- Find every occurrence of `needle` in idx.plain (plain find, no patterns).
function M.find_all(idx, needle, max_hits)
    local hits = {}
    if needle == "" then return hits end
    local init = 1
    while true do
        local s = idx.plain:find(needle, init, true)
        if not s then break end
        hits[#hits + 1] = s
        if max_hits and #hits >= max_hits then break end
        init = s + 1
    end
    return hits
end

--- Serialize the index to a file (fast to reload; rebuilding means
-- decompressing the whole book again).
function M.save_index(idx, path)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(("WSIDX1 %d %d %d\n"):format(#idx.plain, idx.nseg, idx.raw_length or 0))
    f:write(idx.plain)
    f:write("\n")
    local buf = {}
    for k = 1, idx.nseg do
        buf[#buf + 1] = ("%d %d %d %d\n"):format(idx.pb[k], idx.pl[k], idx.rb[k], idx.rl[k])
        if #buf >= 2048 then f:write(concat(buf)); buf = {} end
    end
    if #buf > 0 then f:write(concat(buf)) end
    f:close()
    return true
end

function M.load_index(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local head = f:read("*l")
    local plen, nseg, rawlen = (head or ""):match("^WSIDX1 (%d+) (%d+) (%d+)$")
    if not plen then f:close(); return nil end
    plen, nseg, rawlen = tonumber(plen), tonumber(nseg), tonumber(rawlen)
    local plain = f:read(plen)
    if not plain or #plain ~= plen then f:close(); return nil end
    f:read(1) -- newline
    local pb, pl, rb, rl = {}, {}, {}, {}
    for k = 1, nseg do
        local line = f:read("*l")
        if not line then f:close(); return nil end
        local a, b, c, d = line:match("^(%d+) (%d+) (%d+) (%d+)$")
        if not a then f:close(); return nil end
        pb[k], pl[k], rb[k], rl[k] = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    end
    f:close()
    return { plain = plain, pb = pb, pl = pl, rb = rb, rl = rl, nseg = nseg, raw_length = rawlen }
end

return M
