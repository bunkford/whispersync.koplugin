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

-- 2. Cover badge hook degrades gracefully without the renderer.
local okb, why = Zen.installCoverBadge(function() return true end, function() return true end)
H.eq(okb, false, "no mosaic renderer loaded -> false"); H.ok(why, "with a reason")
-- With a ZenOS-patched mosaic menu present, items get wrapped once and painted with a badge.
local painted = {}
local Mosaic = { _zen_renderer_patched = true }
Mosaic._updateItemsBuildUI = function(self) return 1 end
package.loaded["mosaicmenu"] = Mosaic
package.preload["ffi/blitbuffer"] = function() return { COLOR_WHITE = "W", COLOR_BLACK = "B" } end
package.preload["ui/widget/textwidget"] = function() return { new = function(_, o) return { getSize = function() return { w = 6, h = 8 } end, paintTo = function() painted.glyph = true end } end } end
package.preload["ui/font"] = function() return { getFace = function() return "face" end } end
package.preload["device"] = function() return { screen = { scaleBySize = function(_, n) return n end } } end
H.eq(Zen.installCoverBadge(function(p) return p == "/k.mobi" end, function() return true end), true, "hook installed")
H.eq(Zen.installCoverBadge(function() end, function() end), true, "second install is a no-op")
local bb = { paintRoundedRect = function() painted.rects = (painted.rects or 0) + 1 end }
local item_k = { _zen_is_book = true, filepath = "/k.mobi", _zen_cover_frame = { dimen = { x = 10, y = 20, w = 100, h = 150 } },
    paintTo = function() painted.original = (painted.original or 0) + 1 end }
local item_other = { _zen_is_book = true, filepath = "/o.epub", _zen_cover_frame = { dimen = { x = 0, y = 0, w = 100, h = 150 } },
    paintTo = function() painted.original = (painted.original or 0) + 1 end }
local menu = { layout = { { item_k, item_other } } }
Mosaic._updateItemsBuildUI(menu)
item_k:paintTo(bb, 0, 0); item_other:paintTo(bb, 0, 0)
H.eq(painted.original, 2, "original paintTo still runs for both")
H.eq(painted.rects, 2, "badge (two rounded rects) painted for the Kindle book only")
H.eq(painted.glyph, true, "glyph painted")
Mosaic._updateItemsBuildUI(menu)
item_k:paintTo(bb, 0, 0)
H.eq(painted.rects, 4, "rebuild does not double-wrap (one badge per paint)")

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
