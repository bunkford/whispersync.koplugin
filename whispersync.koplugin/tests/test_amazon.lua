local H = require("helpers")
package.path = H.here .. "vendor/?.lua;" .. package.path
local amazon = require("amazon")
local adp = require("adp")

local key_pem = H.read(H.here .. "fixture/adp_key.pem")
local device = { adp_token = "{enc:fake}{key:fake}", device_private_key = key_pem }

-- 1. Library XML, as syncMetaData returns it.
local LIB = [==[<?xml version="1.0" encoding="UTF-8"?>
<response syncType="full"><sync_time>2026-09-04T12:00:00Z</sync_time><add_update_list>
<meta_data><ASIN>TESTPDOCKEY0123456789ABCDEFGHIJK</ASIN><title><![CDATA[Moby Dick - Herman Melville]]></title>
<authors><author>Herman Melville</author></authors><publishers/><publication_date></publication_date>
<cde_contenttype>PDOC</cde_contenttype><content_type>application/x-mobipocket-ebook</content_type><content_size>1234567</content_size></meta_data>
<meta_data><ASIN>B0TESTASIN</ASIN><title>Pride &amp; Prejudice: A Novel</title><authors><author>Jane Austen</author><author>Someone Else</author></authors>
<cde_contenttype>EBOK</cde_contenttype><content_type>application/x-mobi8-ebook</content_type></meta_data>
<meta_data><ASIN>B00DICT001</ASIN><title>Oxford Dictionary</title><cde_contenttype>EBOK</cde_contenttype><content_tags><tag>DICT</tag><tag>FREE_DICT</tag></content_tags></meta_data>
</add_update_list><removal_list><ASIN>GONE0000000000000000000000000000</ASIN></removal_list></response>]==]
local items, sync_time, extra = assert(amazon.parse_library(LIB))
H.eq(#items, 3, "three items")
H.eq(sync_time, "2026-09-04T12:00:00Z", "sync_time")
H.eq(items[1].title, "Moby Dick - Herman Melville", "CDATA title")
H.eq(items[1].content_type, "PDOC", "pdoc type")
H.eq(items[1].content_size, 1234567, "size")
H.eq(items[2].title, "Pride & Prejudice: A Novel", "entity in title")
H.eq(items[2].authors, "Jane Austen, Someone Else", "authors joined")
H.eq(amazon.is_dictionary(items[3]), true, "dictionary tagged")
H.eq(amazon.is_dictionary(items[1]), false, "book untagged")
H.eq(extra.removed[1], "GONE0000000000000000000000000000", "removal list")
H.eq(extra.sync_type, "full", "sync type")
local nope, err = amazon.parse_library("<?xml version=\"1.0\"?><error><message>Internal Error</message></error>")
H.eq(nope, nil, "error body rejected"); H.ok(err:find("Internal Error"), "error surfaced")

-- 2. Sidecar JSON, the real shape.
local SIDE = [==[{"md5":"x","payload":{"syncToken":"t","type":"PDOC","guid":"CR!TESTACR0000000000000000000000:DEADBEEF","acr":"CR!TESTACR0000000000000000000000",
"records":[{"type":"kindle.lpr","location":"12847","annotationId":"A-furthest-page-read","creationTime":"2026-02-07 13:05:12.0"},
{"type":"kindle.most_recent_read","location":"12000","annotationId":"ad55","creationTime":"2026-02-08 13:05:12.0"},
{"type":"kindle.bookmark","startPosition":"5000","annotationId":"bm1","creationTime":"2026-01-01 00:00:00.0","metadata":{"mchl_color":"dark_blue"}},
{"type":"kindle.highlight","startPosition":"6000","endPosition":"6100","annotationId":"hl1","creationTime":"2026-01-02 00:00:00.0"},
{"type":"kindle.note","startPosition":"6000","endPosition":"6100","text":"a note","annotationId":"n1","creationTime":"2026-01-02 00:00:00.0"}],
"key":"TESTPDOCKEY0123456789ABCDEFGHIJK"}}]==]
local sc = amazon.parse_sidecar(assert(amazon.json_decode(SIDE)))
H.eq(sc.position, 12000, "most_recent_read preferred over lpr")
H.eq(sc.furthest_position, 12847, "furthest from lpr")
H.eq(sc.guid, "CR!TESTACR0000000000000000000000:DEADBEEF", "guid")
H.eq(sc.last_read, "2026-02-08 13:05:12.0", "last_read string")
H.eq(#sc.annotations, 3, "three annotations")
H.eq(sc.annotations[1].kind, "bookmark", "bookmark kind")
H.eq(sc.annotations[1].colour, "dark_blue", "bookmark colour")
H.eq(sc.annotations[3].text, "a note", "note text")
H.eq(sc.annotations[2]["end"], 6100, "highlight end")
H.ok(sc.last_read_epoch, "epoch parsed")
H.eq(os.date("!%Y-%m-%d %H:%M:%S", sc.last_read_epoch), "2026-02-08 13:05:12", "epoch is UTC-correct")

-- 3. Wire format: byte-exact against the README example.
local stamp = "2026-07-29T23:14:42-0400"
local body = amazon.sidecar_body("KEY", "PDOC", "CR!X:CAFEF00D", amazon.last_read_child(744912, stamp), stamp)
H.eq(body, '<annotations version="1.0" timestamp="2026-07-29T23:14:42-0400"><book key="KEY" type="PDOC" guid="CR!X:CAFEF00D"><last_read begin="744912" pos="744912" timestamp="2026-07-29T23:14:42-0400"/></book></annotations>', "last_read body")
H.eq(amazon.annotation_child("bookmark", "create", 100, nil, nil, "dark_blue", stamp),
    '<bookmark action="create" begin="100" end="100" pos="100" timestamp="2026-07-29T23:14:42-0400"><metadata><![CDATA[{"mchl_color": "dark_blue"}]]></metadata></bookmark>', "bookmark child")
H.eq(amazon.annotation_child("highlight", "create", 100, 90, nil, nil, stamp),
    '<highlight action="create" begin="100" end="100" pos="100" timestamp="2026-07-29T23:14:42-0400"/>', "highlight child, end clamped to begin")
H.eq(amazon.annotation_child("note", "delete", 100, 120, "a <b> & c", nil, stamp),
    '<note action="delete" begin="100" end="120" pos="100" timestamp="2026-07-29T23:14:42-0400">a &lt;b&gt; &amp; c</note>', "note delete carries escaped text")
H.ok(amazon.sidecar_stamp():match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d[%+%-]%d%d%d%d$"), "stamp has colon-less offset: " .. amazon.sidecar_stamp())

-- 4. Push with a mock transport: checks URL shape, content type, signature, verify-by-readback.
local log = {}
local sidecar_pos = 100
local function mock(req)
    log[#log + 1] = req
    if req.url:find("/sidecar?type=PDOC&key=", 1, true) and req.method == "GET" then
        return 200, (SIDE:gsub('"location":"12000"', '"location":"' .. sidecar_pos .. '"')), {}
    elseif req.url:find("/sidecar?type=PDOC", 1, true) and req.method == "POST" then
        H.eq(req.headers["Content-Type"], "application/xml", "write content type")
        H.ok(not req.url:find("key=", 1, true), "no key= on write URL")
        H.ok(req.headers["x-adp-signature"], "write is signed")
        -- Verify the signature covers the exact body bytes.
        local date = req.headers["x-adp-signature"]:match(":(.*)$")
        local expect = adp.headers("POST", "/FionaCDEServiceEngine/sidecar?type=PDOC", req.body, device.adp_token, key_pem, date)
        H.eq(req.headers["x-adp-signature"], expect["x-adp-signature"], "signature covers body")
        local pos = tonumber(req.body:match('pos="(%d+)"'))
        if req.body:find('guid="CR!TESTACR0000000000000000000000:DEADBEEF"', 1, true) then sidecar_pos = pos end
        return 200, "", {}
    elseif req.url:find("/syncMetaData", 1, true) then
        return 200, LIB, {}
    elseif req.url:find("/FSDownloadContent", 1, true) then
        H.eq(req.headers.Range, "bytes=0-32767", "range header")
        local f = io.open(req.sink_file, "wb"); f:write("BOOKMOBI-ish"); f:close()
        return 206, "", {}
    end
    return 404, "", {}
end
local c = amazon.new(device, mock)
local after = assert(c:push_position("TESTPDOCKEY0123456789ABCDEFGHIJK", "PDOC", "CR!TESTACR0000000000000000000000:DEADBEEF", 54321))
H.eq(after.position, 54321, "push verified by read-back")

-- A wrong guid is accepted by the server (200) but discarded: we must report failure.
sidecar_pos = 100
local r, e = c:push_position("TESTPDOCKEY0123456789ABCDEFGHIJK", "PDOC", "_LATEST_", 999)
H.eq(r, nil, "silent discard detected"); H.ok(e:find("reads back as 100"), "read-back mismatch reported")
local r2, e2 = c:push_position("K", "PDOC", "", 5)
H.eq(r2, nil, "no guid refused"); H.ok(e2:find("guid"), "guid message")

local libitems = assert(c:library())
H.eq(#libitems, 3, "library via client")
H.ok(log[#log].headers["x-adp-token"], "library request signed")
local tmp = os.tmpname()
H.ok(c:download("K", "PDOC", tmp, 32768), "download ok")
H.eq(H.read(tmp), "BOOKMOBI-ish", "downloaded bytes on disk"); os.remove(tmp)

-- 4b. The last_read oracle: one element per device, source_device decoded.
local LR = [==[<?xml version="1.0" encoding="UTF-8"?><book><last_read annotation_time_utc="2026-07-29T23:14:42Z" lto="0" pos="744912" source_device="Reader&apos;s Kindle" method="FRL" version="0"/><last_read pos="12" source_device="Kindle" method="FRL"/></book>]==]
local lr = amazon.parse_last_read(LR)
H.eq(#lr, 2, "two devices")
H.eq(lr[1].pos, 744912, "pos parsed")
H.eq(lr[1].source_device, "Reader's Kindle", "source device unescaped")
H.eq(lr[1].time, "2026-07-29T23:14:42Z", "time parsed")
H.eq(amazon.store_cover_url("B0TESTASIN"), "https://m.media-amazon.com/images/P/B0TESTASIN.01._SCLZZZZZZZ_.jpg", "cdn url")
local r3, e3 = c:last_read("K", "PDOC", "")
H.eq(r3, nil, "last_read needs a guid")

-- 5. Registration helpers.
local login = amazon.build_login("ca")
H.ok(login.url:find("^https://www%.amazon%.ca/ap/signin%?"), "login on the marketplace's own domain")
H.ok(login.url:find("openid.assoc_handle=amzn_device_ca", 1, true), "per-country assoc handle")
H.ok(login.url:find("openid.oa2.client_id=device%3A" .. login.client_id, 1, true), "client id")
H.eq(#login.serial, 32, "serial is 32 hex")
H.eq(amazon.extract_code("https://www.amazon.ca/ap/maplanding?openid.oa2.authorization_code=ANabc123XYZ&openid.mode=id_res"), "ANabc123XYZ", "code from url")
H.eq(amazon.extract_code("ANabc123XYZ99"), "ANabc123XYZ99", "bare code")
H.eq(amazon.extract_code("https://www.amazon.ca/"), nil, "url without code rejected")

H.done("test_amazon")
