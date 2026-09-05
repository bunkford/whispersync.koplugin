--[[--
ZenOS integration, and the KOReader-level pieces it builds on.

ZenOS (the Zen UI plugin) has three public hooks — Home widgets, status-bar
items and launchable plugin menus — and this plugin uses all of them from
main.lua. The things asked for here go further than the hooks allow, so this
module reaches into ZenOS the same way ZenOS reaches into KOReader, with every
step guarded so a ZenOS update that moves something simply switches the
feature off instead of breaking anything:

  * addKindleTab      a native "Kindle" folder tab in the ZenOS navbar, so the
                      downloaded library appears in ZenOS's own cover view.
                      Mirrors ZenOS's own commitCustomTab.
  * installCoverBadge a diagonal "Kindle" corner banner, in the style of
                      ZenOS's "New" banner, on ZenOS library tiles for books
                      that came from the Kindle library. ZenOS paints badges in
                      its mosaic item's paintTo; we wrap each built item once.
  * installHomeBadge  the same banner on ZenOS Home covers (Featured book,
                      Recent strip and friends), which are built by ZenOS's
                      cover_common.make_cover_widget rather than the mosaic.
  * paintBanner       the painter both hooks and the plugin's own shelf use.
  * recordHistory     Amazon's last-read time and progress written into
                      KOReader's reading history and the book's sidecar, which
                      is what ZenOS's Home "Recent" strip and progress badges
                      read. Works without ZenOS too.
]]

local M = {}

-- ZenOS registers itself with KOReader under its plugin name ("zenos", or
-- "zen_ui" for the legacy package), so the running instance lives on the
-- FileManager / ReaderUI it was created for. The __ZEN_UI_PLUGIN global only
-- exists while ZenOS loads its own features, so it is a last resort here.
M.PLUGIN_NAMES = { "zenos", "zen_ui" }
M.UI_MODULES = { "apps/filemanager/filemanager", "apps/reader/readerui" }

local function has_config(p)
    return type(p) == "table" and type(p.config) == "table"
end

local function zen_plugin()
    for _, mod in ipairs(M.UI_MODULES) do
        local app = package.loaded[mod]
        local ui = type(app) == "table" and app.instance or nil
        if type(ui) == "table" then
            for _, name in ipairs(M.PLUGIN_NAMES) do
                if has_config(ui[name]) then return ui[name] end
            end
        end
    end
    local g = rawget(_G, "__ZEN_UI_PLUGIN")
    if has_config(g) then return g end
    return nil
end
M.plugin = zen_plugin

--- Is ZenOS running? True when its plugin instance is reachable, or when its
-- Home widget registry (installed at ZenOS start-up) is present.
function M.available()
    if zen_plugin() then return true end
    return type(rawget(_G, "__ZENOS_REGISTER_HOME_ITEM")) == "function"
        or type(rawget(_G, "__ZEN_UI_REGISTER_HOME_ITEM")) == "function"
        or rawget(_G, "__ZEN_UI_LIBRARY_FONT_CFG") ~= nil
end

-------------------------------------------------------------------------------
-- navbar tab
-------------------------------------------------------------------------------

M.NAVBAR_MAX_TABS = 7

--- Does a custom folder tab for `folder` already exist?
function M.findFolderTab(config, folder)
    local navbar = config and config.navbar
    if type(navbar) ~= "table" or type(navbar.custom_tabs) ~= "table" then return nil end
    folder = (folder or ""):gsub("/+$", "")
    for _, ct in ipairs(navbar.custom_tabs) do
        if type(ct) == "table" and ct.type == "folder" and (tostring(ct.folder or ""):gsub("/+$", "")) == folder then
            return ct
        end
    end
    return nil
end

--- Add a folder tab to ZenOS's navbar, the way ZenOS's own settings do.
-- `plugin` defaults to the live ZenOS plugin; pass a fake for tests.
-- Returns true, message on success; false, reason otherwise.
function M.addKindleTab(folder, label, plugin)
    plugin = plugin or zen_plugin()
    if type(plugin) ~= "table" or type(plugin.config) ~= "table" then
        return false, "ZenOS is not running"
    end
    local config = plugin.config
    config.navbar = type(config.navbar) == "table" and config.navbar or {}
    local navbar = config.navbar
    navbar.custom_tabs = type(navbar.custom_tabs) == "table" and navbar.custom_tabs or {}
    navbar.show_tabs = type(navbar.show_tabs) == "table" and navbar.show_tabs or {}
    navbar.tab_order = type(navbar.tab_order) == "table" and navbar.tab_order or {}

    local existing = M.findFolderTab(config, folder)
    if existing then
        navbar.show_tabs[existing.id] = true
        if type(plugin.saveConfig) == "function" then plugin:saveConfig() end
        return true, "already there"
    end

    navbar.next_custom_id = (tonumber(navbar.next_custom_id) or 0) + 1
    local ct = {
        type = "folder",
        folder = folder,
        label = label or "Kindle",
        label_auto = false,
        icon = "tab_folder",
        id = "ct_" .. navbar.next_custom_id,
    }
    table.insert(navbar.custom_tabs, ct)

    -- Visible only if there is room; ZenOS caps the bar at 7 visible tabs.
    local enabled = 0
    for _, id in ipairs(navbar.tab_order) do
        if navbar.show_tabs[id] == true then enabled = enabled + 1 end
    end
    navbar.show_tabs[ct.id] = enabled < M.NAVBAR_MAX_TABS

    -- Order: before the trailing page/menu controls, else at the end.
    local inserted = false
    for i, id in ipairs(navbar.tab_order) do
        if id == "page_right" or id == "menu" then
            table.insert(navbar.tab_order, i, ct.id)
            inserted = true
            break
        end
    end
    if not inserted then table.insert(navbar.tab_order, ct.id) end

    if type(plugin.saveConfig) == "function" then
        local ok, err = pcall(plugin.saveConfig, plugin)
        if not ok then return false, "ZenOS could not save its settings: " .. tostring(err) end
    end
    return true, navbar.show_tabs[ct.id] and "added" or "added but hidden: the navbar already shows 7 tabs"
end

-------------------------------------------------------------------------------
-- cover banner
-------------------------------------------------------------------------------

M.BANNER_LABEL = "Kindle"
M.CORNERS = { "tl", "tr" }

local band_cache = {}

--- Badge colours from ZenOS's settings (falls back to black on white).
function M.badgeColors()
    local Blitbuffer = require("ffi/blitbuffer")
    local color, foreground = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    local utils = package.loaded["common/utils"]
    local plugin = zen_plugin()
    if type(utils) == "table" and plugin and type(plugin.config) == "table" then
        local okc, c = pcall(utils.getBadgeColor, plugin.config)
        if okc and c then color = c end
        local okt, t = pcall(utils.getBadgeTextColor, plugin.config)
        if okt and t then foreground = t end
    end
    return color, foreground
end

--- ZenOS's badge scale (1 when ZenOS or its setting is absent).
function M.badgeScale()
    local utils = package.loaded["common/utils"]
    local plugin = zen_plugin()
    if type(utils) == "table" and plugin and type(plugin.config) == "table" and type(utils.getBadgeScale) == "function" then
        local ok, s = pcall(utils.getBadgeScale, plugin.config)
        if ok and tonumber(s) and s > 0 then return s end
    end
    return 1
end

--- Banner geometry for a cover of `w` x `h` pixels, ZenOS's own proportions:
-- the "New" banner and this one come out the same size on the same cover.
function M.bannerGeometry(w, h, scale)
    local Screen = require("device").screen
    local base = math.floor(math.max(Screen:scaleBySize(20), math.floor(w * 0.14)) * (scale or 1))
    base = math.max(8, math.min(base, math.floor(math.min(w, h) / 2)))
    local span = math.floor(base * 2.5)
    return {
        span = span,
        thick = math.max(3, math.floor(span * 0.35)),
        font_size = math.max(6, math.floor(base * 0.25)),
    }
end

-- Stable cache key for a Blitbuffer colour (ZenOS builds a fresh cdata per call).
local function color_key(color)
    if type(color) == "cdata" or type(color) == "table" then
        local ok, rgb = pcall(function() return color:getColorRGB32() end)
        if ok and rgb then return string.format("%d,%d,%d,%d", rgb.r, rgb.g, rgb.b, rgb.alpha or 255) end
    end
    return tostring(color)
end

-- The band (a horizontal strip with the label) is rendered once per size and
-- colour into an off-screen buffer, then copied onto the cover rotated 45°.
local function band(bb, width, height, label, font_size, fill, border)
    local Blitbuffer = require("ffi/blitbuffer")
    local TextWidget = require("ui/widget/textwidget")
    local Font = require("ui/font")
    local key = table.concat({ width, height, tostring(bb:getType()), label, font_size, color_key(fill), color_key(border) }, "|")
    local cached = band_cache[key]
    if cached then return cached end
    local buf = Blitbuffer.new(width, height, bb:getType())
    if not buf then return nil end
    buf:paintRect(0, 0, width, height, border)
    if height > 2 then buf:paintRect(0, 1, width, height - 2, fill) end
    local max_w, max_h = math.floor(width * 0.82), math.max(1, height - 2)
    local size = font_size
    local text, ts
    repeat
        if text and text.free then text:free() end
        text = TextWidget:new{ text = label, face = Font:getFace("cfont", size), bold = true, fgcolor = border, padding = 0 }
        ts = text:getSize()
        if ts.w <= max_w and ts.h <= max_h then break end
        size = size - 1
    until size < 6
    text:paintTo(buf, math.max(0, math.floor((width - ts.w) / 2)), math.max(0, math.floor((height - ts.h) / 2)))
    if text.free then text:free() end
    band_cache[key] = buf
    return buf
end

--- Paint a diagonal corner banner reading "Kindle" over the cover occupying
-- (x, y, w, h) on `bb`, in the style of ZenOS's "New" banner.
--   opts.corner       "tl" (default) or "tr"
--   opts.label        text, default M.BANNER_LABEL
--   opts.color / opts.foreground   band fill and text/edge colour
--   opts.scale        size multiplier (ZenOS badge scale)
--   opts.border, opts.border_color repaint the cover's border over the banner
-- Returns true when something was painted.
function M.paintBanner(bb, x, y, w, h, opts)
    opts = opts or {}
    if not bb or not w or not h or w < 12 or h < 12 then return false end
    local ok, painted = pcall(function()
        local color, foreground = opts.color, opts.foreground
        if not color or not foreground then
            local c, f = M.badgeColors()
            color, foreground = color or c, foreground or f
        end
        local g = M.bannerGeometry(w, h, opts.scale or M.badgeScale())
        local c = 0.70711
        local width = math.ceil((g.span + g.thick * 2) * 1.41422)
        local height = g.thick
        local buf = band(bb, width, height, opts.label or M.BANNER_LABEL, g.font_size, color, foreground)
        if not buf then return false end
        local top_left = opts.corner ~= "tr"
        local cover_left, cover_right, cover_top, cover_bottom = x, x + w, y, y + h
        local center_x = top_left and (cover_left + math.floor(g.span / 2)) or (cover_right - math.floor(g.span / 2))
        local center_y = cover_top + math.floor(g.span / 2)
        local half_box = math.ceil((width + height) * c / 2) + 1
        local bb_w, bb_h = bb:getWidth(), bb:getHeight()
        local half_w, half_h = width / 2, height / 2
        for dy = center_y - half_box, center_y + half_box do
            if dy >= cover_top and dy < cover_bottom and dy >= 0 and dy < bb_h then
                local ry = dy - center_y
                for dx = center_x - half_box, center_x + half_box do
                    if dx >= cover_left and dx < cover_right and dx >= 0 and dx < bb_w then
                        local rx = dx - center_x
                        local sx, sy
                        if top_left then
                            -- band runs bottom-left → top-right ("/"), text top towards the corner
                            sx = math.floor(half_w + (rx - ry) * c)
                            sy = math.floor(half_h + (rx + ry) * c)
                        else
                            -- band runs top-left → bottom-right ("\"), as ZenOS paints "New"
                            sx = math.floor(half_w + (rx + ry) * c)
                            sy = math.floor(half_h + (ry - rx) * c)
                        end
                        if sx >= 0 and sx < width and sy >= 0 and sy < height then
                            bb:setPixel(dx, dy, buf:getPixel(sx, sy))
                        end
                    end
                end
            end
        end
        local border = tonumber(opts.border) or 0
        if border > 0 and opts.border_color then
            bb:paintRect(x, y, w, border, opts.border_color)
            if top_left then
                bb:paintRect(x, y, border, h, opts.border_color)
            else
                bb:paintRect(x + w - border, y, border, h, opts.border_color)
            end
        end
        return true
    end)
    return ok and painted or false
end

-- Border colour of a cover FrameContainer, honouring ZenOS's dimmed border.
local function frame_border(frame)
    local Blitbuffer = require("ffi/blitbuffer")
    local size = tonumber(frame.bordersize) or 0
    if size <= 0 then return 0, nil end
    return size, frame._zen_cover_border_color or frame.color or Blitbuffer.COLOR_BLACK
end

local function style_of(style)
    local s = type(style) == "function" and style() or style
    return type(s) == "table" and s or {}
end

--- Wrap ZenOS's mosaic builder so Kindle books get the banner on their
-- library tiles. `is_kindle(filepath)`, `enabled()` and `style()` (returns
-- { corner = "tl"|"tr" }) are consulted at paint time, so settings change
-- without a restart. Idempotent. Returns true when the hook is in place,
-- false with a reason when ZenOS's renderer is not there.
function M.installCoverBadge(is_kindle, enabled, style)
    local MosaicMenu = package.loaded["mosaicmenu"]
    if type(MosaicMenu) ~= "table" or type(MosaicMenu._updateItemsBuildUI) ~= "function" then
        return false, "mosaic renderer not loaded"
    end
    if MosaicMenu._whispersync_badge_hooked then
        MosaicMenu._whispersync_badge_hooked.is_kindle = is_kindle
        MosaicMenu._whispersync_badge_hooked.enabled = enabled
        MosaicMenu._whispersync_badge_hooked.style = style
        return true
    end
    if not MosaicMenu._zen_renderer_patched then
        return false, "ZenOS renderer not active"
    end
    local builder = MosaicMenu._updateItemsBuildUI
    local hook = { is_kindle = is_kindle, enabled = enabled, style = style }

    local function wrap_item(item)
        if type(item) ~= "table" or item._ws_badge_wrapped or type(item.paintTo) ~= "function" then return end
        if not item._zen_is_book or type(item.filepath) ~= "string" then return end
        local original = item.paintTo
        item._ws_badge_wrapped = true
        item.paintTo = function(self_item, bb, x, y)
            original(self_item, bb, x, y)
            if not hook.enabled() or not hook.is_kindle(self_item.filepath) then return end
            local frame = self_item._zen_cover_frame
            if not frame or not frame.dimen then return end
            local d = frame.dimen
            local border, border_color = frame_border(frame)
            M.paintBanner(bb, d.x, d.y, d.w, d.h, {
                corner = style_of(hook.style).corner, border = border, border_color = border_color,
            })
        end
    end

    MosaicMenu._updateItemsBuildUI = function(self, ...)
        local result = builder(self, ...)
        pcall(function()
            for _, row in ipairs(self.layout or {}) do
                for _, item in ipairs(row) do wrap_item(item) end
            end
        end)
        return result
    end
    MosaicMenu._whispersync_badge_hooked = hook
    -- ZenOS also routes FileChooser through the same builder.
    local ok, FileChooser = pcall(require, "ui/widget/filechooser")
    if ok and FileChooser and FileChooser._updateItemsBuildUI == builder then
        FileChooser._updateItemsBuildUI = MosaicMenu._updateItemsBuildUI
    end
    return true
end

M.HOME_COVER_MODULE = "modules/filebrowser/patches/home/widgets/cover_common"

--- Wrap ZenOS's Home cover factory so the Featured book, the Recent strip
-- and every other Home widget that shows a cover carry the banner too.
-- Those covers are built by one function, `cover_common.make_cover_widget`,
-- which the mosaic hook above never sees. Same arguments as installCoverBadge.
function M.installHomeBadge(is_kindle, enabled, style)
    local cover_common = package.loaded[M.HOME_COVER_MODULE]
    if type(cover_common) ~= "table" and M.available() then
        local ok, mod = pcall(require, M.HOME_COVER_MODULE)
        if ok and type(mod) == "table" then cover_common = mod end
    end
    if type(cover_common) ~= "table" or type(cover_common.make_cover_widget) ~= "function" then
        return false, "ZenOS Home covers not loaded"
    end
    if cover_common._whispersync_badge_hooked then
        cover_common._whispersync_badge_hooked.is_kindle = is_kindle
        cover_common._whispersync_badge_hooked.enabled = enabled
        cover_common._whispersync_badge_hooked.style = style
        return true
    end
    local original = cover_common.make_cover_widget
    local hook = { is_kindle = is_kindle, enabled = enabled, style = style }
    cover_common.make_cover_widget = function(book, max_w, max_h, opts)
        local frame, target_w, target_h, needs_hydration = original(book, max_w, max_h, opts)
        pcall(function()
            if type(frame) ~= "table" or type(frame.paintTo) ~= "function" or frame._ws_badge_wrapped then return end
            local path = type(book) == "table" and (book.path or book.file) or nil
            if type(path) ~= "string" or path == "" then return end
            local paint = frame.paintTo
            frame._ws_badge_wrapped = true
            frame.paintTo = function(self_frame, bb, x, y)
                paint(self_frame, bb, x, y)
                if not hook.enabled() or not hook.is_kindle(path) then return end
                local d = self_frame.dimen
                local w = d and d.w or target_w
                local h = d and d.h or target_h
                local border, border_color = frame_border(self_frame)
                M.paintBanner(bb, x, y, w, h, {
                    corner = style_of(hook.style).corner, border = border, border_color = border_color,
                })
            end
        end)
        return frame, target_w, target_h, needs_hydration
    end
    cover_common._whispersync_badge_hooked = hook
    return true
end

--- Where the banner hooks currently are: { zen, library, home } booleans.
function M.bannerStatus()
    local mosaic = package.loaded["mosaicmenu"]
    local cover_common = package.loaded[M.HOME_COVER_MODULE]
    return {
        zen = M.available(),
        library = type(mosaic) == "table" and mosaic._whispersync_badge_hooked ~= nil,
        home = type(cover_common) == "table" and cover_common._whispersync_badge_hooked ~= nil,
    }
end

-------------------------------------------------------------------------------
-- reading history and sidecar progress
-------------------------------------------------------------------------------

--- Should an Amazon read at `epoch` replace what history holds for `file`?
-- Never move a book backwards in time: a later read on this device wins.
function M.historyNeedsUpdate(hist, file, epoch)
    if not epoch then return false end
    for _, entry in ipairs(hist or {}) do
        if entry.file == file then
            return (tonumber(entry.time) or 0) < epoch
        end
    end
    return true
end

--- Put a downloaded Kindle book into KOReader's reading history at Amazon's
-- last-read time and write its progress into the sidecar, so ZenOS's Recent
-- strip, progress badges and finished-book dimming all reflect the Kindle.
-- `opts.percent` is 0..100; `opts.is_open(file)` guards the open document.
-- Returns what changed: { history = bool, sidecar = bool }.
function M.recordHistory(file, epoch, opts)
    opts = opts or {}
    local changed = { history = false, sidecar = false }
    if type(file) ~= "string" then return changed end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(file, "mode") ~= "file" then return changed end
    if opts.is_open and opts.is_open(file) then return changed end

    if epoch then
        local ok, ReadHistory = pcall(require, "readhistory")
        if ok and ReadHistory and ReadHistory.addItem then
            pcall(ReadHistory.reload, ReadHistory, false)
            if M.historyNeedsUpdate(ReadHistory.hist, file, epoch) then
                local added = pcall(ReadHistory.addItem, ReadHistory, file, epoch, opts.no_flush)
                changed.history = added and true or false
            end
        end
    end

    if opts.percent ~= nil then
        local ok, DocSettings = pcall(require, "docsettings")
        if ok and DocSettings then
            local okd, ds = pcall(DocSettings.open, DocSettings, file)
            if okd and ds then
                local pct = math.max(0, math.min(1, opts.percent / 100))
                local cur = ds:readSetting("percent_finished")
                local summary = ds:readSetting("summary")
                local status = type(summary) == "table" and summary.status or nil
                local write = false
                if cur == nil or math.abs((tonumber(cur) or 0) - pct) > 0.002 then
                    ds:saveSetting("percent_finished", pct)
                    write = true
                end
                if pct >= 0.995 and status ~= "complete" and status ~= "abandoned" then
                    summary = type(summary) == "table" and summary or {}
                    summary.status = "complete"
                    summary.modified = os.date("%Y-%m-%d")
                    ds:saveSetting("summary", summary)
                    write = true
                end
                if write then
                    pcall(ds.flush, ds)
                    changed.sidecar = true
                end
            end
        end
    end
    return changed
end

--- Flush history once after a batch of no_flush adds.
function M.flushHistory()
    local ok, ReadHistory = pcall(require, "readhistory")
    if ok and ReadHistory then
        pcall(ReadHistory._reduce, ReadHistory)
        pcall(ReadHistory._flush, ReadHistory)
    end
end

return M
