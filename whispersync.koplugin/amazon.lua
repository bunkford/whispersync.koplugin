--[[--
Amazon device-stack client: the services Kindle hardware talks to.

    todo-ta-g7g.amazon.com/FionaTodoListProxy/syncMetaData  -> library listing
    cde-ta-g7g.amazon.com/FionaCDEServiceEngine/sidecar     -> position + annotations (GET and POST)
    cde-ta-g7g.amazon.com/FionaCDEServiceEngine/FSDownloadContent -> the book file

Everything is ADP-signed with the device key from OAuth registration; the key
never expires so there is no token refresh to manage.

The write path was hard to find and is easy to get subtly wrong. Every rule
below was established live in this repo (README, "Pushing progress back to
your Kindle"), and each one fails *silently* — HTTP 200, nothing stored:

  1. `guid` must be the book's real one (from the sidecar GET). "_LATEST_" is
     accepted and discarded. A book never opened on a Kindle has no guid and
     cannot be written to.
  2. No `key=` in the write query string: `?type=X` only, key in <book key=>.
     Leaving it on gives a 404.
  3. Content-Type is `application/xml`; `text/xml` draws a 400.
  4. No XML prolog, no whitespace between elements, timestamps ISO 8601 with a
     UTC offset carrying no colon (-0400).
  5. The signature covers the exact body bytes sent.
  6. Only `<last_read>` (kindle.most_recent_read) is written. No kindle.lpr:
     Amazon treats furthest-read as monotonic and raises it itself.
  7. Annotations need action="create|modify|delete"; a note delete must carry
     the note's text or the note stays. Creates verify by read-back; deletes
     trust the 200 because they are not read-after-write consistent.
]]

local adp = require("adp")

local M = {}

M.TODO_HOST = "todo-ta-g7g.amazon.com"
M.CDE_HOST = "cde-ta-g7g.amazon.com"
M.UA = "okhttp/3.12.1"
M.HEADER_BYTES = 32768

-- Registration identity: Kindle for iOS. Presenting a legacy device type is
-- what makes Amazon serve MOBI rather than KFX, which is what KOReader reads.
M.DEVICE_TYPE = "AGZZ1ST63LKBW"
M.APP_NAME = "Kindle for iOS"
M.APP_VERSION = "6.38.0.100"
M.SOFTWARE_VERSION = "1184366692"

-- Per-country OAuth handles. device_assoc is per country, not per region;
-- the wrong one returns Amazon's 404 page instead of a login form.
M.MARKETPLACES = {
    { code = "us", label = "United States (amazon.com)", domain = "amazon.com", device_assoc = "amzn_device_us" },
    { code = "ca", label = "Canada (amazon.ca)", domain = "amazon.ca", device_assoc = "amzn_device_ca" },
    { code = "uk", label = "United Kingdom (amazon.co.uk)", domain = "amazon.co.uk", device_assoc = "amzn_device_uk" },
    { code = "de", label = "Germany (amazon.de)", domain = "amazon.de", device_assoc = "amzn_device_de" },
    { code = "fr", label = "France (amazon.fr)", domain = "amazon.fr", device_assoc = "amzn_device_fr" },
    { code = "it", label = "Italy (amazon.it)", domain = "amazon.it", device_assoc = "amzn_device_it" },
    { code = "es", label = "Spain (amazon.es)", domain = "amazon.es", device_assoc = "amzn_device_es" },
    { code = "jp", label = "Japan (amazon.co.jp)", domain = "amazon.co.jp", device_assoc = "amzn_device_jp" },
    { code = "au", label = "Australia (amazon.com.au)", domain = "amazon.com.au", device_assoc = "amzn_device_au" },
    { code = "in", label = "India (amazon.in)", domain = "amazon.in", device_assoc = "amzn_device_in" },
}

function M.marketplace(code)
    for _, mp in ipairs(M.MARKETPLACES) do
        if mp.code == code then return mp end
    end
    return M.MARKETPLACES[1]
end

-------------------------------------------------------------------------------
-- JSON (KOReader ships dkjson as "json"; tests provide their own)
-------------------------------------------------------------------------------

local json
do
    local ok, mod = pcall(require, "json")
    if ok then json = mod else
        ok, mod = pcall(require, "rapidjson")
        if ok then json = mod end
    end
end

function M.json_decode(s)
    if not json then return nil, "no JSON library" end
    local ok, res = pcall(json.decode, s)
    if ok then return res end
    return nil, tostring(res)
end

function M.json_encode(t)
    return json.encode(t)
end

-------------------------------------------------------------------------------
-- small helpers
-------------------------------------------------------------------------------

local function xml_attr(s)
    s = tostring(s):gsub("&", "&amp;"):gsub('"', "&quot;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    return '"' .. s .. '"'
end

local function xml_text(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local XML_ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }
function M.xml_unescape(s)
    if not s then return "" end
    s = s:gsub("^%s*<!%[CDATA%[(.-)%]%]>%s*$", "%1")
    return (s:gsub("&(#?x?%w+);", function(e)
        if XML_ENTITIES[e] then return XML_ENTITIES[e] end
        local cp = e:match("^#x(%x+)$")
        if cp then cp = tonumber(cp, 16) else cp = tonumber(e:match("^#(%d+)$") or "") end
        if cp then
            local ok, mobi = pcall(require, "mobi")
            if ok then return mobi.utf8_char(cp) end
        end
        return "&" .. e .. ";"
    end))
end

--- Child element text (first match) inside an XML fragment.
local function child(frag, tag)
    local v = frag:match("<" .. tag .. "[^>]*>(.-)</" .. tag .. ">")
    return v and M.xml_unescape(v):match("^%s*(.-)%s*$") or nil
end

--- All <child> texts inside <container>, joined with ", ".
local function join(frag, container, tag)
    local c = frag:match("<" .. container .. "[^>]*>(.-)</" .. container .. ">")
    if not c then return "" end
    local out = {}
    for v in c:gmatch("<" .. tag .. "[^>]*>(.-)</" .. tag .. ">") do
        v = M.xml_unescape(v):match("^%s*(.-)%s*$")
        if v ~= "" then out[#out + 1] = v end
    end
    return table.concat(out, ", ")
end

local function url_encode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c) return ("%%%02X"):format(c:byte()) end))
end
M.url_encode = url_encode

--- Local time with a colon-less UTC offset: what sidecar writes require.
function M.sidecar_stamp(t)
    t = t or os.time()
    local z = os.date("%z", t)
    if not z or not z:match("^[%+%-]%d%d%d%d$") then
        -- Compute the offset by hand on platforms with an odd %z.
        local utc = os.time(os.date("!*t", t))
        local diff = os.difftime(t, utc)
        if os.date("*t", t).isdst then diff = diff + 3600 end
        local sign = diff < 0 and "-" or "+"
        diff = math.abs(diff)
        z = ("%s%02d%02d"):format(sign, math.floor(diff / 3600), math.floor(diff % 3600 / 60))
    end
    return os.date("%Y-%m-%dT%H:%M:%S", t) .. z
end

--- Amazon's "2026-06-01 14:42:32.0" (UTC) -> Unix epoch, or nil.
function M.parse_amazon_time(s)
    if not s then return nil end
    local Y, Mo, D, h, m, sec = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[ T](%d%d):(%d%d):(%d%d)")
    if not Y then return nil end
    local t = { year = tonumber(Y), month = tonumber(Mo), day = tonumber(D),
                hour = tonumber(h), min = tonumber(m), sec = tonumber(sec), isdst = false }
    -- os.time() interprets the table as local time; correct to UTC.
    local as_local = os.time(t)
    if not as_local then return nil end
    local now = os.time()
    local offset = os.difftime(now, os.time(os.date("!*t", now)))
    return as_local + offset
end

local function tonum(v)
    if v == nil then return nil end
    return tonumber((tostring(v):gsub("%s", "")))
end

-------------------------------------------------------------------------------
-- HTTP transport
-------------------------------------------------------------------------------

--- Default transport built on LuaSocket, KOReader-style. `req` has url,
-- method, headers, body, sink_file (optional). Returns code, body, headers.
local function default_transport(req)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil_ok, socketutil = pcall(require, "socketutil")
    if socketutil_ok then
        if req.sink_file then
            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        else
            socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        end
    end
    local chunks = {}
    local sink
    if req.sink_file then
        local f, err = io.open(req.sink_file, "wb")
        if not f then return nil, "cannot open " .. req.sink_file .. ": " .. tostring(err) end
        sink = ltn12.sink.file(f)
    else
        sink = ltn12.sink.table(chunks)
    end
    local headers = {}
    for k, v in pairs(req.headers or {}) do headers[k] = v end
    if req.body then
        headers["Content-Length"] = tostring(#req.body)
    end
    local request = {
        url = req.url,
        method = req.method or "GET",
        headers = headers,
        sink = sink,
        source = req.body and ltn12.source.string(req.body) or nil,
    }
    local code, resp_headers, status = socket.skip(1, http.request(request))
    if socketutil_ok then socketutil:reset_timeout() end
    if type(code) ~= "number" then
        return nil, tostring(code or status or "network error")
    end
    return code, table.concat(chunks), resp_headers or {}
end

M.transport = default_transport

-------------------------------------------------------------------------------
-- client
-------------------------------------------------------------------------------

local Client = {}
Client.__index = Client
M.Client = Client

--- `device` = { adp_token, device_private_key, marketplace? }
function M.new(device, transport)
    assert(device and device.adp_token and device.device_private_key, "device credentials required")
    return setmetatable({
        adp_token = device.adp_token,
        key = device.device_private_key,
        transport = transport or M.transport,
    }, Client)
end

function Client:_signed(method, host, path, body, extra_headers, sink_file)
    local headers, err = adp.headers(method, path, body or "", self.adp_token, self.key)
    if not headers then return nil, "signing failed: " .. tostring(err) end
    headers["User-Agent"] = M.UA
    if extra_headers then
        for k, v in pairs(extra_headers) do headers[k] = v end
    end
    return self.transport({
        url = "https://" .. host .. path,
        method = method,
        headers = headers,
        body = body,
        sink_file = sink_file,
    })
end

--- Library listing. Returns list of items and the server's sync_time token.
-- Despite type=EBOK this returns every content type, personal documents
-- included. Amazon asks for no more than one call per 300 s.
function Client:library(last_sync_time)
    local path = "/FionaTodoListProxy/syncMetaData?type=EBOK"
    if last_sync_time and last_sync_time ~= "" then
        path = path .. "&last_sync_time=" .. url_encode(last_sync_time)
    end
    local code, body = self:_signed("GET", M.TODO_HOST, path)
    if code ~= 200 then
        return nil, ("syncMetaData returned HTTP %s%s"):format(tostring(code), code == nil and (": " .. tostring(body)) or "")
    end
    return M.parse_library(body)
end

--- Parse a syncMetaData response.
function M.parse_library(xml)
    if not xml or not xml:find("<meta_data", 1, true) then
        if xml and xml:find("<error>", 1, true) then
            return nil, "Amazon returned an error: " .. (child(xml, "message") or "unknown")
        end
    end
    local items = {}
    local sync_time = child(xml, "sync_time") or ""
    local sync_type = xml:match('syncType="(%w+)"')
    for frag in xml:gmatch("<meta_data>(.-)</meta_data>") do
        local asin = child(frag, "ASIN")
        if asin and asin ~= "" then
            items[#items + 1] = {
                asin = asin,
                title = child(frag, "title") or "",
                authors = join(frag, "authors", "author"),
                publishers = join(frag, "publishers", "publisher"),
                content_type = child(frag, "cde_contenttype") or "",
                mime = child(frag, "content_type") or "",
                content_size = tonum(child(frag, "content_size")),
                publication_date = child(frag, "publication_date") or "",
                purchase_date = child(frag, "purchase_date") or "",
                -- Bundled dictionaries are tagged DICT / FREE_DICT; real
                -- books carry no tags at all.
                content_tags = join(frag, "content_tags", "tag"),
            }
        end
    end
    local removed = {}
    for frag in xml:gmatch("<removal_list>(.-)</removal_list>") do
        for asin in frag:gmatch("<ASIN>(.-)</ASIN>") do removed[#removed + 1] = asin end
    end
    return items, sync_time, { sync_type = sync_type, removed = removed }
end

function M.is_dictionary(item)
    return (item.content_tags or ""):find("DICT", 1, true) ~= nil
end

--- Raw sidecar for one book. Returns the decoded payload table, or nil when
-- the book has never been opened (Amazon answers 200 with an empty body).
function Client:sidecar(key, content_type)
    local path = ("/FionaCDEServiceEngine/sidecar?type=%s&key=%s"):format(content_type, url_encode(key))
    local code, body = self:_signed("GET", M.CDE_HOST, path)
    if code == nil then return nil, "sidecar request failed: " .. tostring(body) end
    if code ~= 200 then return nil, ("sidecar returned HTTP %d"):format(code) end
    if not body or body:match("^%s*$") then return nil end
    local data, err = M.json_decode(body)
    if not data then return nil, "sidecar was not JSON: " .. tostring(err) end
    return M.parse_sidecar(data)
end

M.POSITION_TYPES = { "kindle.most_recent_read", "kindle.lpr" }

--- Normalise a decoded sidecar JSON document.
function M.parse_sidecar(data)
    local payload = data.payload or data
    local records = payload.records or {}
    local by_type = {}
    for _, rec in ipairs(records) do
        if type(rec) == "table" and rec.type and not by_type[rec.type] then by_type[rec.type] = rec end
    end
    local best
    for _, t in ipairs(M.POSITION_TYPES) do
        if by_type[t] then best = by_type[t]; break end
    end
    local out = {
        key = payload.key,
        type = payload.type,
        guid = payload.guid or "",
        acr = payload.acr or "",
        sync_token = payload.syncToken,
        annotations = {},
    }
    if best then
        local furthest = by_type["kindle.lpr"] or best
        out.position = tonum(best.location)
        out.furthest_position = tonum(furthest.location)
        out.last_read = best.creationTime or best.lastModificationTime or ""
        out.last_read_epoch = M.parse_amazon_time(out.last_read)
    end
    for _, rec in ipairs(records) do
        local kind = rec.type or ""
        if kind ~= "kindle.lpr" and kind ~= "kindle.most_recent_read" and kind:sub(1, 7) == "kindle." then
            local meta = rec.metadata
            if type(meta) == "string" then meta = M.json_decode(meta) end
            out.annotations[#out.annotations + 1] = {
                annotation_id = rec.annotationId or "",
                kind = kind:sub(8),
                start = tonum(rec.startPosition) or tonum(rec.location),
                ["end"] = tonum(rec.endPosition),
                text = rec.text,
                colour = type(meta) == "table" and meta.mchl_color or nil,
                created = rec.creationTime or "",
                modified = rec.lastModificationTime or "",
            }
        end
    end
    return out
end

--- Build the one wire format for sidecar writes. String concatenation on
-- purpose: no XML library here may reorder attributes or add whitespace.
function M.sidecar_body(key, content_type, guid, children, stamp)
    stamp = stamp or M.sidecar_stamp()
    return ('<annotations version="1.0" timestamp=%s><book key=%s type=%s guid=%s>%s</book></annotations>'):format(
        xml_attr(stamp), xml_attr(key), xml_attr(content_type), xml_attr(guid), children)
end

function M.last_read_child(position, stamp)
    position = math.max(0, math.floor(tonumber(position) or 0))
    stamp = stamp or M.sidecar_stamp()
    return ('<last_read begin="%d" pos="%d" timestamp=%s/>'):format(position, position, xml_attr(stamp))
end

M.ANNOTATION_KINDS = { bookmark = true, highlight = true, note = true }
M.DEFAULT_BOOKMARK_COLOUR = "dark_blue"

--- One annotation record. `action` is mandatory (create|modify|delete) —
-- unlike <last_read>, which takes none. `end` defaults to `begin`.
function M.annotation_child(kind, action, begin, fin, text, colour, stamp)
    assert(M.ANNOTATION_KINDS[kind], "bad annotation kind " .. tostring(kind))
    assert(action == "create" or action == "modify" or action == "delete", "bad action " .. tostring(action))
    begin = math.max(0, math.floor(tonumber(begin) or 0))
    fin = fin and math.max(begin, math.floor(tonumber(fin))) or begin
    stamp = stamp or M.sidecar_stamp()
    local attrs = ('action=%s begin="%d" end="%d" pos="%d" timestamp=%s'):format(
        xml_attr(action), begin, fin, begin, xml_attr(stamp))
    local meta = ""
    if colour and action ~= "delete" then
        meta = '<metadata><![CDATA[{"mchl_color": "' .. colour .. '"}]]></metadata>'
    end
    if kind == "note" then
        return ("<note %s>%s%s</note>"):format(attrs, xml_text(text or ""), meta)
    end
    if meta ~= "" then
        return ("<%s %s>%s</%s>"):format(kind, attrs, meta, kind)
    end
    return ("<%s %s/>"):format(kind, attrs)
end

function Client:_post_sidecar(content_type, body)
    -- No key= on the write URL; the key rides in <book key=>.
    local path = "/FionaCDEServiceEngine/sidecar?type=" .. content_type
    local code, resp = self:_signed("POST", M.CDE_HOST, path, body, { ["Content-Type"] = "application/xml" })
    if code == nil then return nil, "write failed: " .. tostring(resp) end
    if code ~= 200 then return nil, ("Amazon rejected the write: HTTP %d %s"):format(code, (resp or ""):sub(1, 160)) end
    return true
end

--- Write where-you-are back to Amazon and confirm by reading it back.
-- Returns the verified sidecar, or nil plus a reason.
function Client:push_position(key, content_type, guid, position)
    if not guid or guid == "" then
        return nil, "no guid for this book. Amazon needs one and silently drops writes without it; open the book once on a Kindle."
    end
    position = math.max(0, math.floor(tonumber(position) or 0))
    local body = M.sidecar_body(key, content_type, guid, M.last_read_child(position))
    local ok, err = self:_post_sidecar(content_type, body)
    if not ok then return nil, err end
    local after, err2 = self:sidecar(key, content_type)
    if not after then return nil, "write returned 200 but the sidecar could not be read back: " .. tostring(err2) end
    if after.position ~= position then
        return nil, ("write returned 200 but the position reads back as %s, not %d (wrong guid?)"):format(
            tostring(after.position), position)
    end
    return after
end

--- Upload annotations as siblings of one <book>, then return the sidecar as
-- Amazon now holds it. `items` = { {kind, action, begin, end, text, colour} }.
function Client:push_annotations(key, content_type, guid, items)
    if not guid or guid == "" then
        return nil, "no guid for this book; Amazon drops annotation writes without one."
    end
    if #items == 0 then return self:sidecar(key, content_type) end
    local children = {}
    for _, it in ipairs(items) do
        local colour = it.colour
        if colour == nil and it.kind == "bookmark" then colour = M.DEFAULT_BOOKMARK_COLOUR end
        children[#children + 1] = M.annotation_child(it.kind, it.action or "create", it.begin, it["end"], it.text, colour)
    end
    local body = M.sidecar_body(key, content_type, guid, table.concat(children))
    local ok, err = self:_post_sidecar(content_type, body)
    if not ok then return nil, err end
    return self:sidecar(key, content_type)
end

--- Download an arbitrary byte range of a book file to `dest` (both ends
-- inclusive). Used for the cover image record without pulling the book.
function Client:download_range(key, content_type, dest, first, last)
    local path = ("/FionaCDEServiceEngine/FSDownloadContent?type=%s&key=%s"):format(content_type, url_encode(key))
    local code, body = self:_signed("GET", M.CDE_HOST, path, nil,
        { Range = ("bytes=%d-%d"):format(first, last) }, dest)
    if code == nil then os.remove(dest); return nil, "download failed: " .. tostring(body) end
    if code ~= 200 and code ~= 206 then os.remove(dest); return nil, ("download returned HTTP %d"):format(code) end
    return true
end

--- The second oracle: Amazon's own account of the last-read position, with
-- the device it credits it to. `source_device` naming this registration is
-- the proof a write was accepted rather than merely acknowledged. Returns a
-- list of { pos, source_device, method, time } (one per device), or nil.
function Client:last_read(key, content_type, guid)
    if not guid or guid == "" then return nil, "no guid" end
    local path = ("/FionaCDEServiceEngine/getAnnotations?filter=last_read&type=%s&key=%s&guid=%s"):format(
        content_type, url_encode(key), url_encode(guid))
    local code, body = self:_signed("GET", M.CDE_HOST, path)
    if code == nil then return nil, "getAnnotations failed: " .. tostring(body) end
    if code ~= 200 then return nil, ("getAnnotations returned HTTP %d"):format(code) end
    return M.parse_last_read(body or "")
end

function M.parse_last_read(xml)
    local out = {}
    for attrs in xml:gmatch("<last_read([^>]*)/?>") do
        local function a(name) return attrs:match(name .. '="([^"]*)"') end
        out[#out + 1] = {
            pos = tonum(a("pos")),
            source_device = M.xml_unescape(a("source_device") or ""),
            method = a("method") or "",
            time = a("annotation_time_utc") or a("timestamp") or "",
            lto = a("lto"),
        }
    end
    return out
end

--- Public CDN cover for a store book (no auth). Amazon answers with a ~43
-- byte 1x1 placeholder rather than a 404 when it has no art, so callers
-- must check the size.
function M.store_cover_url(asin)
    return ("https://m.media-amazon.com/images/P/%s.01._SCLZZZZZZZ_.jpg"):format(asin)
end

function Client:store_cover(asin, dest)
    local code, body = self.transport({ url = M.store_cover_url(asin), method = "GET",
        headers = { ["User-Agent"] = M.UA }, sink_file = dest })
    if code ~= 200 then os.remove(dest); return nil, ("cover returned HTTP %s"):format(tostring(code)) end
    local f = io.open(dest, "rb")
    local size = f and f:seek("end") or 0
    if f then f:close() end
    if size < 1000 then os.remove(dest); return nil, "no cover art" end
    return true
end

--- Download a book file (or its first `range_bytes`) to `dest`.
-- Returns true, or nil plus a reason. FORMAT_NOT_SUPPORTED_ERROR means a
-- KFX-only title our legacy device type is refused; only ever seen on
-- bundled dictionaries.
function Client:download(key, content_type, dest, range_bytes)
    local path = ("/FionaCDEServiceEngine/FSDownloadContent?type=%s&key=%s"):format(content_type, url_encode(key))
    local extra
    if range_bytes then extra = { Range = ("bytes=0-%d"):format(range_bytes - 1) } end
    local code, body = self:_signed("GET", M.CDE_HOST, path, nil, extra, dest)
    if code == nil then os.remove(dest); return nil, "download failed: " .. tostring(body) end
    if code ~= 200 and code ~= 206 then
        local snippet = ""
        local f = io.open(dest, "rb")
        if f then snippet = (f:read(300) or ""); f:close() end
        os.remove(dest)
        if snippet:find("FORMAT_NOT_SUPPORTED", 1, true) then
            return nil, "Amazon only has this title in a format this device type cannot download (KFX-only)."
        end
        return nil, ("download returned HTTP %d"):format(code)
    end
    return true
end

-------------------------------------------------------------------------------
-- OAuth device registration (the flow real Kindle apps use)
-------------------------------------------------------------------------------

--- Build the sign-in URL. Persist serial and code_verifier for the exchange.
function M.build_login(mp_code, serial)
    local mp = M.marketplace(mp_code)
    serial = serial or adp.hex(adp.random_bytes(16))
    local code_verifier = adp.b64url(adp.random_bytes(32))
    local challenge = adp.b64url(adp.sha256(code_verifier))
    local client_id = adp.hex(serial .. "#" .. M.DEVICE_TYPE)
    local params = {
        { "openid.ns", "http://specs.openid.net/auth/2.0" },
        { "openid.mode", "checkid_setup" },
        { "openid.claimed_id", "http://specs.openid.net/auth/2.0/identifier_select" },
        { "openid.identity", "http://specs.openid.net/auth/2.0/identifier_select" },
        { "openid.assoc_handle", mp.device_assoc },
        { "openid.return_to", "https://www." .. mp.domain .. "/ap/maplanding" },
        { "openid.pape.max_auth_age", "0" },
        { "openid.ns.oa2", "http://www.amazon.com/ap/ext/oauth/2" },
        { "openid.oa2.response_type", "code" },
        { "openid.oa2.code_challenge_method", "S256" },
        { "openid.oa2.code_challenge", challenge },
        { "openid.oa2.client_id", "device:" .. client_id },
        { "openid.oa2.scope", "device_auth_access" },
        { "openid.ns.pape", "http://specs.openid.net/extensions/pape/1.0" },
        { "accountStatusPolicy", "P1" },
        { "pageId", "amzn_device_common_dark" },
        { "language", "en_US" },
    }
    local q = {}
    for _, kv in ipairs(params) do q[#q + 1] = url_encode(kv[1]) .. "=" .. url_encode(kv[2]) end
    return {
        url = "https://www." .. mp.domain .. "/ap/signin?" .. table.concat(q, "&"),
        serial = serial,
        code_verifier = code_verifier,
        client_id = client_id,
        marketplace = mp.code,
    }
end

--- Pull the authorization code out of whatever was pasted: the maplanding
-- URL, a bare query string, or the code itself.
function M.extract_code(pasted)
    pasted = (pasted or ""):match("^%s*(.-)%s*$")
    if pasted == "" then return nil, "Nothing entered." end
    if pasted:find("openid.oa2.authorization_code", 1, true) then
        local code = pasted:match("openid%.oa2%.authorization_code=([^&%s]+)")
        if code and code ~= "" then
            return (code:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
        end
        return nil, "Found the parameter name but no value."
    end
    if pasted:sub(1, 4) == "http" then
        return nil, "That URL has no authorization code in it. Copy the address bar AFTER signing in; it should contain 'openid.oa2.authorization_code'."
    end
    if #pasted < 12 or pasted:find("%s") then
        return nil, "That does not look like an authorization code or a maplanding URL."
    end
    return pasted
end

--- Exchange the code for device credentials. `login` is build_login()'s result.
function M.register(login, code, device_name, transport)
    transport = transport or M.transport
    local mp = M.marketplace(login.marketplace)
    local body = M.json_encode({
        requested_token_type = { "bearer", "mac_dms", "website_cookies", "store_authentication_cookie" },
        cookies = { website_cookies = json.util and json.util.null and {} or {}, domain = "." .. mp.domain },
        registration_data = {
            domain = "Device",
            app_version = M.APP_VERSION,
            device_type = M.DEVICE_TYPE,
            device_name = device_name or "%FIRST_NAME%%FIRST_NAME_POSSESSIVE_STRING%%DUPE_STRATEGY_1ST%KOReader",
            os_version = "17.0",
            device_serial = login.serial,
            device_model = "iPhone",
            app_name = M.APP_NAME,
            software_version = M.SOFTWARE_VERSION,
        },
        auth_data = {
            client_id = login.client_id,
            authorization_code = code,
            code_verifier = login.code_verifier,
            code_algorithm = "SHA-256",
            client_domain = "DeviceLegacy",
        },
        requested_extensions = { "device_info", "customer_info" },
    })
    -- dkjson encodes an empty table as {} ; Amazon wants [] for website_cookies.
    body = body:gsub('"website_cookies":%s*{}', '"website_cookies":[]')
    local code_, resp = transport({
        url = "https://api." .. mp.domain .. "/auth/register",
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Accept-Language"] = "en-US",
            ["User-Agent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
        },
        body = body,
    })
    if code_ == nil then return nil, "registration request failed: " .. tostring(resp) end
    local data = M.json_decode(resp or "")
    if not data then return nil, ("Amazon returned non-JSON (HTTP %s): %s"):format(tostring(code_), (resp or ""):sub(1, 200)) end
    local r = data.response or {}
    if r.error then
        return nil, ("Amazon rejected the registration: %s - %s"):format(tostring(r.error.code), tostring(r.error.message))
    end
    local success = r.success
    if not success then return nil, "unexpected registration response" end
    local tokens = success.tokens or {}
    local mac = tokens.mac_dms or {}
    if not mac.adp_token or not mac.device_private_key then
        return nil, "registration succeeded but returned no device credentials"
    end
    local bearer = tokens.bearer or {}
    return {
        adp_token = mac.adp_token,
        device_private_key = mac.device_private_key,
        refresh_token = bearer.refresh_token,
        device_serial = login.serial,
        device_type = M.DEVICE_TYPE,
        marketplace = mp.code,
        registered_at = os.time(),
        customer_name = success.extensions and success.extensions.customer_info and success.extensions.customer_info.name or nil,
    }
end

return M
