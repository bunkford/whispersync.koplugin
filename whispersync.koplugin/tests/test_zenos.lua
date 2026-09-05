local H = require("helpers")
package.path = H.here .. "vendor/?.lua;" .. package.path

-- Stub the KOReader modules zenos.lua touches.
local hist = {}
local added = {}
package.preload["readhistory"] = function() return {
    hist = hist,
    reload = function() end,
    addItem = function(_, file, ts, no_flush) added[#added + 1] = { file = file, ts = ts, no_flush = no_flush }; return true end,
    _reduce = function() end, _flush = function() end,
} end
local sidecars = {}
package.preload["docsettings"] = function() return {
    open = function(_, file)
        sidecars[file] = sidecars[file] or { data = {}, flushed = 0 }
        local sc = sidecars[file]
        return {
            readSetting = function(_, k) return sc.data[k] end,
            saveSetting = function(_, k, v) sc.data[k] = v end,
            flush = function() sc.flushed = sc.flushed + 1 end,
        }
    end,
} end
package.preload["libs/libkoreader-lfs"] = function() return { attributes = function(path, mode)
    local f = io.open(path, "rb"); if not f then return nil end; f:close(); return mode == "mode" and "file" or {} end } end

local Zen = require("zenos")

-- 1. Navbar tab: mirrors ZenOS's commitCustomTab.
local saves = 0
local plugin = { config = { navbar = { show_tabs = { books = true, home = true }, tab_order = { "books", "home", "menu" } } },
                 saveConfig = function() saves = saves + 1 end }
H.eq(Zen.available(), false, "no live ZenOS in tests")
-- Detection: ZenOS's instance sits on the FileManager/ReaderUI under its plugin name;
-- the __ZEN_UI_PLUGIN global is only set while ZenOS loads its own features.
package.loaded["apps/filemanager/filemanager"] = { instance = { zenos = { config = { navbar = {} } } } }
H.eq(Zen.available(), true, "ZenOS found via FileManager.instance.zenos")
H.eq(Zen.plugin(), package.loaded["apps/filemanager/filemanager"].instance.zenos, "plugin() returns that instance")
package.loaded["apps/filemanager/filemanager"] = { instance = { zen_ui = { config = {} } } }
H.ok(Zen.plugin() ~= nil, "legacy zen_ui name works too")
package.loaded["apps/filemanager/filemanager"] = nil
package.loaded["apps/reader/readerui"] = { instance = { zenos = { config = {} } } }
H.ok(Zen.plugin() ~= nil, "found on ReaderUI when reading")
package.loaded["apps/reader/readerui"] = nil
H.eq(Zen.plugin(), nil, "gone again")
rawset(_G, "__ZENOS_REGISTER_HOME_ITEM", function() end)
H.eq(Zen.available(), true, "Home registry alone proves ZenOS is running"); H.eq(Zen.plugin(), nil, "but gives no settings")
rawset(_G, "__ZENOS_REGISTER_HOME_ITEM", nil)
H.eq(Zen.available(), false, "clean again")
local ok, msg = Zen.addKindleTab("/mnt/us/koreader/kindle-library", "Kindle", plugin)
H.ok(ok, "tab added: " .. tostring(msg))
local nav = plugin.config.navbar
H.eq(#nav.custom_tabs, 1, "one custom tab")
H.eq(nav.custom_tabs[1].type, "folder", "folder type")
H.eq(nav.custom_tabs[1].folder, "/mnt/us/koreader/kindle-library", "folder path")
H.eq(nav.custom_tabs[1].label, "Kindle", "label")
H.eq(nav.custom_tabs[1].id, "ct_1", "id from next_custom_id")
H.eq(nav.show_tabs.ct_1, true, "visible (under the 7-tab cap)")
H.eq(table.concat(nav.tab_order, ","), "books,home,ct_1,menu", "inserted before the trailing menu control")
H.eq(saves, 1, "ZenOS config saved")
local ok2, msg2 = Zen.addKindleTab("/mnt/us/koreader/kindle-library/", "Kindle", plugin)
H.ok(ok2 and msg2 == "already there", "second add is idempotent (trailing slash tolerated)")
H.eq(#nav.custom_tabs, 1, "still one tab")
-- Cap: with 7 visible tabs the new one is added hidden.
local full = { config = { navbar = { show_tabs = {}, tab_order = {} } }, saveConfig = function() end }
for i = 1, 7 do full.config.navbar.show_tabs["t" .. i] = true; full.config.navbar.tab_order[i] = "t" .. i end
local ok3, msg3 = Zen.addKindleTab("/x", "Kindle", full)
H.ok(ok3 and msg3:find("hidden"), "eighth tab added hidden: " .. tostring(msg3))
H.eq(select(2, Zen.addKindleTab("/x", "Kindle", nil)), "ZenOS is not running", "no plugin: clear reason")

-- 2. Cover banner hook degrades gracefully without the renderer.
local okb, why = Zen.installCoverBadge(function() return true end, function() return true end)
H.eq(okb, false, "no mosaic renderer loaded -> false"); H.ok(why, "with a reason")
local okh, whyh = Zen.installHomeBadge(function() return true end, function() return true end)
H.eq(okh, false, "no ZenOS Home cover module -> false"); H.ok(whyh, "with a reason")

-- A tiny pixel-buffer stand-in for Blitbuffer: enough to see where the banner lands.
local function fake_bb(w, h, fill)
    local px = {}
    local bb = { w = w, h = h, px = px, rects = {} }
    function bb:getWidth() return self.w end
    function bb:getHeight() return self.h end
    function bb:getType() return 4 end
    function bb:setPixel(x, y, c) self.px[y * 100000 + x] = c end
    function bb:getPixel(x, y) return self.px[y * 100000 + x] or fill end
    function bb:paintRect(x, y, rw, rh, c)
        self.rects[#self.rects + 1] = { x = x, y = y, w = rw, h = rh, c = c }
        for yy = y, y + rh - 1 do for xx = x, x + rw - 1 do self.px[yy * 100000 + xx] = c end end
    end
    return bb
end
package.preload["ffi/blitbuffer"] = function() return {
    COLOR_WHITE = "W", COLOR_BLACK = "B",
    new = function(w, h) return fake_bb(w, h, nil) end,
} end
local glyphs = 0
package.preload["ui/widget/textwidget"] = function() return { new = function(_, o)
    return { getSize = function() return { w = 6, h = 8 } end, paintTo = function() glyphs = glyphs + 1 end } end } end
package.preload["ui/font"] = function() return { getFace = function() return "face" end } end
package.preload["device"] = function() return { screen = { scaleBySize = function(_, n) return n end } } end

-- Geometry follows ZenOS's "New" banner proportions.
local g = Zen.bannerGeometry(100, 150, 1)
H.eq(g.span, 50, "span = 2.5 x base (base = max(20, 14% of width))")
H.eq(g.thick, 17, "band thickness 35% of span")
H.eq(g.font_size, 6, "font clamps at 6")
H.eq(Zen.bannerGeometry(300, 450, 1).span, 105, "bigger cover, bigger banner")
H.eq(Zen.bannerGeometry(30, 40, 1).span, 37, "tiny cover: banner bounded by the cover")

-- Painting: top-left banner covers the top-left corner only; top-right the other.
local function corner_hits(bb, x, y, w, h)
    local tl, tr, bl = 0, 0, 0
    for yy = y, y + h - 1 do
        for xx = x, x + w - 1 do
            local c = bb.px[yy * 100000 + xx]
            if c == "B" or c == "W" then
                -- the outer 25% square of each top corner, and the whole lower half
                if xx < x + w / 4 and yy < y + h / 4 then tl = tl + 1 end
                if xx >= x + w * 3 / 4 and yy < y + h / 4 then tr = tr + 1 end
                if yy >= y + h / 2 then bl = bl + 1 end
            end
        end
    end
    return tl, tr, bl
end
local screen = fake_bb(400, 600, "bg")
H.eq(Zen.paintBanner(screen, 10, 20, 100, 150, { corner = "tl", color = "B", foreground = "W", scale = 1 }), true, "painted")
local tl, tr, bottom = corner_hits(screen, 10, 20, 100, 150)
H.ok(tl > 30, "top-left corner painted (" .. tl .. " px)")
H.eq(tr, 0, "nothing in the top-right corner"); H.eq(bottom, 0, "nothing in the lower half")
H.ok(glyphs >= 1, "label drawn into the band once")
local before = glyphs
screen = fake_bb(400, 600, "bg")
Zen.paintBanner(screen, 10, 20, 100, 150, { corner = "tr", color = "B", foreground = "W", scale = 1 })
tl, tr = corner_hits(screen, 10, 20, 100, 150)
H.eq(tl, 0, "top-right style leaves the top-left corner alone"); H.ok(tr > 30, "top-right corner painted")
H.eq(glyphs, before, "band cached: no second text render for the same size")
H.eq(Zen.paintBanner(screen, 0, 0, 8, 8, {}), false, "too small to carry a banner")
screen = fake_bb(400, 600, "bg")
Zen.paintBanner(screen, 10, 20, 100, 150, { corner = "tl", color = "B", foreground = "W", scale = 1, border = 2, border_color = "E" })
H.eq(screen.px[20 * 100000 + 10], "E", "cover border repainted over the banner (top edge)")
H.eq(screen.px[100 * 100000 + 10], "E", "left edge too")

-- With a ZenOS-patched mosaic menu present, items get wrapped once and painted with the banner.
local painted = {}
local Mosaic = { _zen_renderer_patched = true }
Mosaic._updateItemsBuildUI = function(self) return 1 end
package.loaded["mosaicmenu"] = Mosaic
local corner = "tl"
H.eq(Zen.installCoverBadge(function(p) return p == "/k.mobi" end, function() return true end, function() return { corner = corner } end), true, "hook installed")
H.eq(Zen.installCoverBadge(function() end, function() end), true, "second install is a no-op")
-- (the second install replaced the callbacks with ones that return nil: restore)
Zen.installCoverBadge(function(p) return p == "/k.mobi" end, function() return true end, function() return { corner = corner } end)
local tile_bb = fake_bb(400, 600, "bg")
local item_k = { _zen_is_book = true, filepath = "/k.mobi", _zen_cover_frame = { dimen = { x = 10, y = 20, w = 100, h = 150 }, bordersize = 1, color = "E" },
    paintTo = function() painted.original = (painted.original or 0) + 1 end }
local item_other = { _zen_is_book = true, filepath = "/o.epub", _zen_cover_frame = { dimen = { x = 200, y = 20, w = 100, h = 150 } },
    paintTo = function() painted.original = (painted.original or 0) + 1 end }
local menu = { layout = { { item_k, item_other } } }
Mosaic._updateItemsBuildUI(menu)
item_k:paintTo(tile_bb, 0, 0); item_other:paintTo(tile_bb, 0, 0)
H.eq(painted.original, 2, "original paintTo still runs for both")
tl = corner_hits(tile_bb, 10, 20, 100, 150)
H.ok(tl > 30, "banner on the Kindle tile")
H.eq(corner_hits(tile_bb, 200, 20, 100, 150), 0, "no banner on the other book")
H.eq(tile_bb.px[20 * 100000 + 10], "E", "tile border repainted")
Mosaic._updateItemsBuildUI(menu)
local wraps = 0
local probe = { _zen_is_book = true, filepath = "/k.mobi", _zen_cover_frame = { dimen = { x = 0, y = 0, w = 100, h = 150 } }, paintTo = function() wraps = wraps + 1 end }
Mosaic._updateItemsBuildUI({ layout = { { probe } } }); Mosaic._updateItemsBuildUI({ layout = { { probe } } })
probe:paintTo(fake_bb(400, 600, "bg"), 0, 0)
H.eq(wraps, 1, "rebuild does not double-wrap")

-- ZenOS Home covers: the cover factory is wrapped so Featured/Recent covers carry the banner.
local built = 0
local cover_common = { make_cover_widget = function(book, mw, mh, o)
    built = built + 1
    local frame = { bordersize = 1, color = "E", paintTo = function(self, bb, x, y) self.dimen = { x = x, y = y, w = 100, h = 150 }; painted.home = (painted.home or 0) + 1 end }
    return frame, 100, 150, false
end }
package.loaded[Zen.HOME_COVER_MODULE] = cover_common
H.eq(Zen.installHomeBadge(function(p) return p == "/k.mobi" end, function() return true end, function() return { corner = corner } end), true, "home hook installed")
H.eq(Zen.installHomeBadge(function(p) return p == "/k.mobi" end, function() return true end, function() return { corner = corner } end), true, "home hook idempotent")
local home_bb = fake_bb(400, 600, "bg")
local f1, w1, h1, hyd = cover_common.make_cover_widget({ path = "/k.mobi" }, 100, 150, {})
H.eq(built, 1, "original factory called once"); H.eq(w1, 100, "return values pass through"); H.eq(hyd, false, "all four of them")
f1:paintTo(home_bb, 10, 20)
H.eq(painted.home, 1, "original cover painted")
H.ok(corner_hits(home_bb, 10, 20, 100, 150) > 30, "banner on the Kindle Home cover")
local f2 = cover_common.make_cover_widget({ path = "/other.epub" }, 100, 150, {})
f2:paintTo(home_bb, 200, 20)
H.eq(corner_hits(home_bb, 200, 20, 100, 150), 0, "other books untouched")
local f3 = cover_common.make_cover_widget(nil, 100, 150, {})
f3:paintTo(home_bb, 200, 300)
H.eq(painted.home, 3, "cover without a book still paints")
corner = "tr"
home_bb = fake_bb(400, 600, "bg")
f1:paintTo(home_bb, 10, 20)
local tl2, tr2 = corner_hits(home_bb, 10, 20, 100, 150)
H.eq(tl2, 0, "corner setting read at paint time"); H.ok(tr2 > 30, "now top-right")
local st = Zen.bannerStatus()
H.eq(st.library, true, "status: library hook on"); H.eq(st.home, true, "status: home hook on"); H.eq(st.zen, false, "status: no live ZenOS")

-- 3. History decisions and sidecar progress.
H.eq(Zen.historyNeedsUpdate({}, "/k.mobi", 1000), true, "unknown file -> add")
H.eq(Zen.historyNeedsUpdate({ { file = "/k.mobi", time = 500 } }, "/k.mobi", 1000), true, "older entry -> update")
H.eq(Zen.historyNeedsUpdate({ { file = "/k.mobi", time = 2000 } }, "/k.mobi", 1000), false, "newer local read wins")
H.eq(Zen.historyNeedsUpdate({}, "/k.mobi", nil), false, "no epoch -> nothing")
local tmp = os.tmpname()
local ch = Zen.recordHistory(tmp, 1700000000, { percent = 42.4 })
H.eq(ch.history, true, "added to history"); H.eq(added[1].ts, 1700000000, "at Amazon's time")
H.near(sidecars[tmp].data.percent_finished, 0.424, 0.0001, "percent_finished written as 0..1")
H.eq(sidecars[tmp].data.summary, nil, "not marked complete at 42%")
local ch2 = Zen.recordHistory(tmp, 1700000000, { percent = 42.4 })
H.eq(ch2.sidecar, false, "unchanged progress is not rewritten")
local ch3 = Zen.recordHistory(tmp, nil, { percent = 99.8 })
H.eq(ch3.sidecar, true, "progress updated"); H.eq(sidecars[tmp].data.summary.status, "complete", "finished on Amazon -> complete")
sidecars[tmp].data.summary.status = "abandoned"
Zen.recordHistory(tmp, nil, { percent = 100 })
H.eq(sidecars[tmp].data.summary.status, "abandoned", "an explicit abandoned status is respected")
local ch4 = Zen.recordHistory(tmp, 1700000000, { percent = 10, is_open = function() return true end })
H.eq(ch4.history or ch4.sidecar, false, "the open document is left alone")
H.eq(Zen.recordHistory("/does/not/exist.mobi", 1, { percent = 1 }).history, false, "missing file ignored")
os.remove(tmp)

H.done("test_zenos")
