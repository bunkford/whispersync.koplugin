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
  * installCoverBadge a small "K" badge on ZenOS cover tiles for books that
                      came from the Kindle library. ZenOS paints badges in its
                      mosaic item's paintTo; we wrap each built item once.
  * recordHistory     Amazon's last-read time and progress written into
                      KOReader's reading history and the book's sidecar, which
                      is what ZenOS's Home "Recent" strip and progress badges
                      read. Works without ZenOS too.
]]

local M = {}

local function zen_plugin()
    return rawget(_G, "__ZEN_UI_PLUGIN")
end

function M.available()
    local plugin = zen_plugin()
    return type(plugin) == "table" and type(plugin.config) == "table"
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
-- cover badge
-------------------------------------------------------------------------------

local badge_widget_cache = {}

--- Paint a small round "K" badge at the bottom-left of a cover frame.
function M.paintBadge(bb, frame_dimen, opts)
    opts = opts or {}
    local ok, err = pcall(function()
        local Blitbuffer = require("ffi/blitbuffer")
        local TextWidget = require("ui/widget/textwidget")
        local Font = require("ui/font")
        local Screen = require("device").screen
        local size = opts.size or math.max(Screen:scaleBySize(18), math.floor(frame_dimen.w * 0.13))
        local inset = math.max(2, math.floor(size * 0.18))
        local x = frame_dimen.x + inset
        local y = frame_dimen.y + frame_dimen.h - size - inset - (opts.lift or 0)
        local r = math.floor(size / 2)
        local fg = opts.foreground or Blitbuffer.COLOR_WHITE
        local bg = opts.color or Blitbuffer.COLOR_BLACK
        bb:paintRoundedRect(x - 2, y - 2, size + 4, size + 4, fg, r + 2)
        bb:paintRoundedRect(x, y, size, size, bg, r)
        local font_size = math.max(7, math.floor(size * 0.55))
        local key = font_size .. "|" .. tostring(fg)
        local w = badge_widget_cache[key]
        if not w then
            w = TextWidget:new{ text = "K", face = Font:getFace("cfont", font_size), bold = true, fgcolor = fg, padding = 0 }
            badge_widget_cache[key] = w
        end
        local ws = w:getSize()
        w:paintTo(bb, x + math.floor((size - ws.w) / 2), y + math.floor((size - ws.h) / 2))
    end)
    if not ok then return false, err end
    return true
end

--- Wrap ZenOS's mosaic builder so Kindle books get a badge on their tiles.
-- `is_kindle(filepath)` and `enabled()` are consulted at paint time, so the
-- setting can change without a restart. Idempotent. Returns true when the
-- hook is in place, false with a reason when ZenOS's renderer is not there.
function M.installCoverBadge(is_kindle, enabled)
    local MosaicMenu = package.loaded["mosaicmenu"]
    if type(MosaicMenu) ~= "table" or type(MosaicMenu._updateItemsBuildUI) ~= "function" then
        return false, "mosaic renderer not loaded"
    end
    if MosaicMenu._whispersync_badge_hooked then return true end
    if not MosaicMenu._zen_renderer_patched then
        return false, "ZenOS renderer not active"
    end
    local builder = MosaicMenu._updateItemsBuildUI

    local function wrap_item(item)
        if type(item) ~= "table" or item._ws_badge_wrapped or type(item.paintTo) ~= "function" then return end
        if not item._zen_is_book or type(item.filepath) ~= "string" then return end
        local original = item.paintTo
        item._ws_badge_wrapped = true
        item.paintTo = function(self_item, bb, x, y)
            original(self_item, bb, x, y)
            if not enabled() or not is_kindle(self_item.filepath) then return end
            local frame = self_item._zen_cover_frame
            if not frame or not frame.dimen then return end
            -- Sit above a page-count pill when ZenOS shows one in the same corner.
            local lift = 0
            if self_item._zen_page_label then
                lift = math.floor(frame.dimen.w * 0.14) + 4
            end
            local color, foreground
            local utils = package.loaded["common/utils"]
            local plugin = zen_plugin()
            if utils and plugin and plugin.config and type(utils.getBadgeColor) == "function" then
                local okc, c = pcall(utils.getBadgeColor, plugin.config)
                if okc then color = c end
                local okt, t = pcall(utils.getBadgeTextColor, plugin.config)
                if okt then foreground = t end
            end
            M.paintBadge(bb, frame.dimen, { lift = lift, color = color, foreground = foreground })
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
    MosaicMenu._whispersync_badge_hooked = true
    -- ZenOS also routes FileChooser through the same builder.
    local ok, FileChooser = pcall(require, "ui/widget/filechooser")
    if ok and FileChooser and FileChooser._updateItemsBuildUI == builder then
        FileChooser._updateItemsBuildUI = MosaicMenu._updateItemsBuildUI
    end
    return true
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
