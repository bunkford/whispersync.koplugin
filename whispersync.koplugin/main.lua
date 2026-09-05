--[[--
Kindle Whispersync for KOReader.

Reads your Send-to-Kindle library straight from Amazon and keeps the reading
position, bookmarks, highlights and notes of those books in sync with your
Kindle account — using the device protocol Kindle hardware speaks, not the
stock reader's sidecar files.

Modules:
  adp.lua            ADP request signing (libcrypto via FFI, openssl CLI fallback)
  amazon.lua         device-stack client: library, sidecar GET/POST, downloads, OAuth
  mobi.lua           MOBI headers, PalmDOC decompression, plain-text index, covers
  posmap.lua         xpointer <-> Kindle byte offset, by matching words
  booksync.lua       pure reconciliation logic (what to pull/push/pair)
  catalog.lua        what the shelf knows about each book, sorting, status text
  shelf.lua          the cover grid, and the ZenOS Home strip
  connectdialog.lua  QR code + instructions + live status on one screen
  zenos.lua          ZenOS navbar tab, cover badge, history/progress hand-off

Everything Amazon-facing follows the rules established live in this repo's
README ("Pushing progress back to your Kindle"); see amazon.lua for the list.
]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Device = require("device")
local Screen = Device.screen
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = plugin_dir .. "/?.lua;" .. package.path

local adp = require("adp")
local amazon = require("amazon")
local mobi = require("mobi")
local PosMap = require("posmap")
local BookSync = require("booksync")
local Catalog = require("catalog")
local Shelf = require("shelf")
local ConnectDialog = require("connectdialog")
local Zen = require("zenos")

local Whispersync = WidgetContainer:extend{
    name = "whispersync",
    is_doc_only = false,
    settings_file = DataStorage:getSettingsDir() .. "/whispersync.lua",
    -- Files the user can drop into the settings directory.
    import_file = DataStorage:getSettingsDir() .. "/whispersync_device.json",
    login_file = DataStorage:getSettingsDir() .. "/whispersync_login.txt",
}

-- Push after this much quiet reading, like the web reader in this repo: a
-- signed write per page turn would be dozens of requests a chapter.
local PUSH_QUIET_SECONDS = 90
-- Amazon asks for no more than one library call per 300 s.
local LIBRARY_MIN_INTERVAL = 300
-- The connect page is served on the Kindle's Wi-Fi address on this port.
local CONNECT_PORT = 8123
-- Pause between per-book Amazon requests during a shelf refresh.
local REFRESH_PACE_US = 250000
-- Keep this many sync log lines.
local LOG_LINES = 80

local DEFAULT_SETTINGS = {
    auto_pull = true,          -- check Amazon when a Kindle book opens
    auto_push = true,          -- write position after quiet reading / on close
    pull_mode = "ask",         -- ask | always | never
    sync_annotations = true,   -- bookmarks, highlights, notes both ways
    mirror_remote_deletions = false,
    show_store_books = false,  -- DRM'd EBOKs cannot be opened in KOReader
    downloaded_only = false,
    sort = "recent",
    library_dir = nil,         -- default computed below
    keep_on_device = true,     -- download every personal document, so the native library shows them all
    download_cap_mb = 40,      -- but skip anything larger than this when doing so automatically
    kindle_badge = true,       -- "Kindle" corner banner on Kindle books' covers (shelf, ZenOS Home and library)
    badge_corner = "tl",       -- which top corner the banner sits in: "tl" or "tr"
    feed_history = true,       -- Amazon read times/progress into KOReader history and sidecars
}

-------------------------------------------------------------------------------
-- helpers (defined before anything that runs at init)
-------------------------------------------------------------------------------

local function notify(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 4 })
end

--- Run `fn` so that a bug in this plugin is logged (and shown once) instead
-- of taking the whole reader down: scheduled tasks and menu callbacks run
-- outside any KOReader error handler.
local function guarded(fn, what)
    return function(...)
        local ok, err = xpcall(fn, debug.traceback, ...)
        if not ok then
            logger.err("whispersync:", what or "error", err)
            notify(T(_("Kindle Whispersync hit a bug (%1). Details are in crash.log."), tostring(err):match("^[^\n]*")), 8)
        end
        return ok
    end
end

--- Is the network usable right now? NetworkMgr:isConnected() is device
-- specific and can be wrong in both directions, so fall back to a DNS check.
local function online()
    local ok, connected = pcall(NetworkMgr.isConnected, NetworkMgr)
    if ok and connected then return true end
    local ok2, up = pcall(NetworkMgr.isOnline, NetworkMgr)
    return ok2 and up or false
end

local function file_exists(path)
    return path ~= nil and lfs.attributes(path, "mode") == "file"
end

local function html_escape(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function url_decode(s)
    return (s:gsub("+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function pct_text(p)
    if p == nil then return "—" end
    return ("%.1f%%"):format(p)
end

local function when_text(epoch)
    if not epoch then return _("unknown time") end
    return os.date("%Y-%m-%d %H:%M", epoch)
end

--- The live plugin instance (ZenOS calls launch methods on the module table).
function Whispersync.liveInstance()
    for _, mod in ipairs({ "apps/reader/readerui", "apps/filemanager/filemanager" }) do
        local m = package.loaded[mod]
        local inst = m and m.instance
        if inst and type(inst.whispersync) == "table" and inst.whispersync.catalog then
            return inst.whispersync
        end
    end
    return nil
end

-------------------------------------------------------------------------------
-- lifecycle
-------------------------------------------------------------------------------

function Whispersync:init()
    self:loadSettings()
    self.pending_push = false
    self.annotations_dirty = false
    self.push_task = guarded(function() self:pushIfNeeded("timer") end, "push")
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    self:registerZenOS()
end

function Whispersync:isKindleFile(path)
    if not path then return false end
    if not self._kindle_files then
        self._kindle_files = {}
        for _, it in pairs(self.catalog) do
            if it.file then self._kindle_files[it.file] = true end
        end
    end
    return self._kindle_files[path] == true
end

function Whispersync:loadSettings()
    self.store = LuaSettings:open(self.settings_file)
    self.settings = self.store:readSetting("settings") or {}
    for k, v in pairs(DEFAULT_SETTINGS) do
        if self.settings[k] == nil then self.settings[k] = v end
    end
    self.device = self.store:readSetting("device")
    self.catalog = self.store:readSetting("catalog") or {}
    self.library_meta = self.store:readSetting("library_meta") or {}
    self.synclog = self.store:readSetting("synclog") or {}
end

function Whispersync:saveSettings()
    self._kindle_files = nil
    self.store:saveSetting("settings", self.settings)
    self.store:saveSetting("device", self.device)
    self.store:saveSetting("catalog", self.catalog)
    self.store:saveSetting("library_meta", self.library_meta)
    self.store:saveSetting("synclog", self.synclog)
    self.store:flush()
end

--- One line in the sync log (and KOReader's log). Kept across restarts so
-- "did it sync?" has an answer.
function Whispersync:log(msg)
    logger.info("whispersync:", msg)
    self.synclog = self.synclog or {}
    self.synclog[#self.synclog + 1] = os.date("%m-%d %H:%M:%S") .. "  " .. msg
    while #self.synclog > LOG_LINES do table.remove(self.synclog, 1) end
    self.store:saveSetting("synclog", self.synclog)
end

function Whispersync:onDispatcherRegisterActions()
    Dispatcher:registerAction("whispersync_library",
        { category = "none", event = "WhispersyncLibrary", title = _("Kindle library"), general = true })
    Dispatcher:registerAction("whispersync_sync_now",
        { category = "none", event = "WhispersyncSyncNow", title = _("Kindle: sync this book"), reader = true })
    Dispatcher:registerAction("whispersync_status",
        { category = "none", event = "WhispersyncStatus", title = _("Kindle: sync status"), reader = true })
end

function Whispersync:onWhispersyncSyncNow() self:syncNow(); return true end
function Whispersync:onWhispersyncLibrary() self:showShelf(); return true end
function Whispersync:onWhispersyncStatus() self:showStatus(); return true end

--- ZenOS Launcher / Controls call this on the module table.
function Whispersync:open()
    local inst = (self.ui and self.catalog) and self or Whispersync.liveInstance()
    if inst then inst:showShelf() end
    return true
end
Whispersync.launch = Whispersync.open

function Whispersync:isConnected()
    return self.device ~= nil and self.device.adp_token ~= nil and self.device.device_private_key ~= nil
end

function Whispersync:client()
    if not self:isConnected() then return nil, _("Not connected to Amazon yet.") end
    if not self._client then self._client = amazon.new(self.device) end
    return self._client
end

function Whispersync:libraryDir()
    if self.settings.library_dir and self.settings.library_dir ~= "" then
        return self.settings.library_dir
    end
    -- Outside the stock reader's documents folder on a Kindle, so it does
    -- not index our copies as duplicates.
    return DataStorage:getFullDataDir() .. "/kindle-library"
end

-------------------------------------------------------------------------------
-- ZenOS
-------------------------------------------------------------------------------

--- Banner options shared by the shelf, the Home strip and the ZenOS hooks.
function Whispersync:badgeStyle()
    return { corner = self.settings.badge_corner == "tr" and "tr" or "tl" }
end

--- Offer a "Kindle library" strip for the ZenOS Home page. Safe to call any
-- number of times; ZenOS replaces the builder for an existing id.
function Whispersync:registerZenOS()
    -- "Kindle" banner on ZenOS's library tiles and Home covers (no-ops until
    -- the ZenOS modules they hook exist; harmless to repeat).
    local function is_kindle(path) local inst = Whispersync.liveInstance() or self; return inst:isKindleFile(path) end
    local function enabled() local inst = Whispersync.liveInstance() or self; return inst.settings.kindle_badge end
    local function style() local inst = Whispersync.liveInstance() or self; return inst:badgeStyle() end
    for name, install in pairs({ ["ZenOS library banner"] = Zen.installCoverBadge, ["ZenOS Home banner"] = Zen.installHomeBadge }) do
        local ok, hooked, why = pcall(install, is_kindle, enabled, style)
        local note = ok and (hooked and "on" or ("off: " .. tostring(why))) or ("error: " .. tostring(hooked))
        self._zen_hook_notes = self._zen_hook_notes or {}
        if self._zen_hook_notes[name] ~= note then
            self._zen_hook_notes[name] = note
            self:log(name .. " " .. note)
        end
    end
    local register = rawget(_G, "__ZENOS_REGISTER_HOME_ITEM") or rawget(_G, "__ZEN_UI_REGISTER_HOME_ITEM")
    if type(register) ~= "function" then return false end
    local ok = pcall(register, "whispersync.shelf", function(ctx)
        local inst = Whispersync.liveInstance() or self
        return inst:buildZenStrip(ctx)
    end, { label = _("Kindle library"), size = "m" })
    return ok
end

--- Repaint every cover that carries the banner after a setting changed.
function Whispersync:refreshCovers()
    if self.shelf then pcall(self.shelf.refresh, self.shelf) end
    UIManager:setDirty("all", "ui")
end

function Whispersync:showHomeStripInfo()
    local registered = type(rawget(_G, "__ZENOS_REGISTER_HOME_ITEM") or rawget(_G, "__ZEN_UI_REGISTER_HOME_ITEM")) == "function"
    local lines = {
        _("The “Kindle library” strip shows your most recently read Kindle books on ZenOS's Home page, with covers, progress and the Kindle banner. Tap a book to open it (downloading first if needed); tap an empty strip to open the library."),
        "",
        registered and _("Status: registered with ZenOS.") or _("Status: ZenOS's Home widget registry was not found, so the strip cannot be offered."),
        "",
        _("ZenOS decides whether the strip is shown. To turn it on: ZenOS Settings → Library → Home → Widgets, and enable “Kindle library”."),
    }
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

function Whispersync:showBannerInfo()
    self:registerZenOS()
    local st = Zen.bannerStatus()
    local yes, no = _("yes"), _("no")
    local lines = {
        self.settings.kindle_badge and _("The “Kindle” banner is on.") or _("The “Kindle” banner is off (Library → “Kindle” banner on covers)."),
        "",
        T(_("ZenOS running: %1"), st.zen and yes or no),
        T(_("ZenOS library tiles (Library, Kindle tab, folders): %1"), st.library and yes or no),
        T(_("ZenOS Home covers (Featured, Recent and other strips): %1"), st.home and yes or no),
        _("This plugin's own shelf: yes"),
        "",
        _("Covers repaint the next time their screen is drawn. If a line says “no” while ZenOS is running, that ZenOS screen has not been opened yet, or this ZenOS version draws it differently; the log has the reason."),
    }
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

function Whispersync:onZenOSReady() self:registerZenOS() end
function Whispersync:onZenUIReady() self:registerZenOS() end

function Whispersync:buildZenStrip(ctx)
    local items = Catalog.shelf_items(self.catalog, { sort = "recent", show_store = false })
    return Shelf.build_strip(ctx, items, {
        title_func = Catalog.title,
        cover_func = function(it) return file_exists(it.cover) and it.cover or nil end,
        percent_func = Catalog.percent,
        status_func = function(it) return Catalog.status_text(it, { exists = file_exists }) end,
        badge_func = function() return self.settings.kindle_badge and self:badgeStyle() or nil end,
        on_open = function(it) self:openItem(it) end,
        on_empty_tap = function() self:showShelf() end,
        empty_text = self:isConnected() and _("Kindle library\nTap to open") or _("Kindle library\nTap to connect"),
    })
end

-------------------------------------------------------------------------------
-- menu
-------------------------------------------------------------------------------

function Whispersync:addToMainMenu(menu_items)
    local in_reader = self.ui ~= nil and self.ui.document ~= nil
    local sub = {}

    sub[#sub + 1] = {
        text = _("Kindle library"),
        callback = guarded(function() self:showShelf() end, "library"),
        separator = not in_reader,
    }
    if in_reader then
        sub[#sub + 1] = {
            text = _("Sync status for this book"),
            enabled_func = function() return self:currentBook() ~= nil end,
            callback = guarded(function() self:showStatus() end, "status"),
        }
        sub[#sub + 1] = {
            text = _("Sync this book now"),
            enabled_func = function() return self:currentBook() ~= nil end,
            callback = guarded(function() self:syncNow() end, "menu sync"),
        }
        sub[#sub + 1] = {
            text = _("Jump to Amazon's position"),
            enabled_func = function() return self:currentBook() ~= nil end,
            callback = guarded(function() self:pullPosition(true) end, "menu pull"),
        }
        sub[#sub + 1] = {
            text = _("Send my position to Amazon"),
            enabled_func = function() return self:currentBook() ~= nil end,
            callback = guarded(function() self:pushPosition(true) end, "menu push"),
        }
        sub[#sub + 1] = {
            text = _("Sync bookmarks, highlights and notes"),
            enabled_func = function() return self:currentBook() ~= nil end,
            callback = guarded(function() self:syncAnnotations(true) end, "menu annotations"),
            separator = true,
        }
    end

    sub[#sub + 1] = {
        text = _("Sync log"),
        callback = guarded(function() self:showLog() end, "log"),
    }

    sub[#sub + 1] = {
        text = _("Automatic sync"),
        sub_item_table = {
            {
                text = _("Check Amazon when a book opens"),
                checked_func = function() return self.settings.auto_pull end,
                callback = function() self.settings.auto_pull = not self.settings.auto_pull; self:saveSettings() end,
            },
            {
                text = _("Send position while reading and on close"),
                checked_func = function() return self.settings.auto_push end,
                callback = function() self.settings.auto_push = not self.settings.auto_push; self:saveSettings() end,
            },
            {
                text = _("Sync bookmarks, highlights and notes"),
                checked_func = function() return self.settings.sync_annotations end,
                callback = function() self.settings.sync_annotations = not self.settings.sync_annotations; self:saveSettings() end,
                separator = true,
            },
            {
                text = _("When Amazon has a newer position: ask"),
                checked_func = function() return self.settings.pull_mode == "ask" end,
                callback = function() self.settings.pull_mode = "ask"; self:saveSettings() end,
            },
            {
                text = _("When Amazon has a newer position: always jump"),
                checked_func = function() return self.settings.pull_mode == "always" end,
                callback = function() self.settings.pull_mode = "always"; self:saveSettings() end,
            },
            {
                text = _("When Amazon has a newer position: never jump"),
                checked_func = function() return self.settings.pull_mode == "never" end,
                callback = function() self.settings.pull_mode = "never"; self:saveSettings() end,
                separator = true,
            },
            {
                text = _("Remove local marks deleted on a Kindle"),
                checked_func = function() return self.settings.mirror_remote_deletions end,
                callback = function()
                    self.settings.mirror_remote_deletions = not self.settings.mirror_remote_deletions
                    self:saveSettings()
                end,
            },
        },
    }

    sub[#sub + 1] = {
        text = _("Library"),
        sub_item_table = {
            {
                text_func = function() return T(_("Download folder: %1"), self:libraryDir()) end,
                keep_menu_open = true,
                callback = function() self:editLibraryDir() end,
            },
            {
                text = _("Show store purchases (DRM, cannot be opened)"),
                checked_func = function() return self.settings.show_store_books end,
                callback = function() self.settings.show_store_books = not self.settings.show_store_books; self:saveSettings() end,
            },
            {
                text = _("Keep every personal document on this device"),
                help_text = _("Downloads all Send-to-Kindle documents during a refresh, so the native library, Recent and search see them. Large files are skipped."),
                checked_func = function() return self.settings.keep_on_device end,
                callback = function() self.settings.keep_on_device = not self.settings.keep_on_device; self:saveSettings() end,
            },
            {
                text = _("Feed Amazon read times and progress into history"),
                help_text = _("Downloaded Kindle books appear in KOReader's history (and ZenOS Home → Recent) at the time they were last read on a Kindle, with their progress."),
                checked_func = function() return self.settings.feed_history end,
                callback = function() self.settings.feed_history = not self.settings.feed_history; self:saveSettings() end,
            },
            {
                text = _("“Kindle” banner on covers"),
                help_text = _("A diagonal corner banner, like ZenOS's “New” banner, on every cover that came from your Kindle library: this plugin's shelf, ZenOS Home (Featured, Recent) and ZenOS's library tiles."),
                checked_func = function() return self.settings.kindle_badge end,
                callback = function() self.settings.kindle_badge = not self.settings.kindle_badge; self:saveSettings(); self:refreshCovers() end,
            },
            {
                text_func = function()
                    return self.settings.badge_corner == "tr" and _("Banner corner: top right") or _("Banner corner: top left")
                end,
                enabled_func = function() return self.settings.kindle_badge end,
                sub_item_table = {
                    {
                        text = _("Top left"),
                        help_text = _("Keeps clear of ZenOS's progress badge and “New” banner in the top-right corner."),
                        checked_func = function() return self.settings.badge_corner ~= "tr" end,
                        callback = function() self.settings.badge_corner = "tl"; self:saveSettings(); self:refreshCovers() end,
                    },
                    {
                        text = _("Top right"),
                        checked_func = function() return self.settings.badge_corner == "tr" end,
                        callback = function() self.settings.badge_corner = "tr"; self:saveSettings(); self:refreshCovers() end,
                    },
                },
                separator = true,
            },
            {
                text = _("Refresh library, covers and progress from Amazon"),
                callback = guarded(function() self:refreshLibrary({ positions = true, force = true }) end, "refresh"),
            },
        },
    }

    sub[#sub + 1] = {
        text_func = function() return Zen.available() and _("ZenOS") or _("ZenOS (not running)") end,
        help_text = _("Everything here needs the ZenOS plugin. The Kindle banner, the Home strip and the navbar tab appear on their own once ZenOS is installed."),
        sub_item_table = {
            {
                text_func = function()
                    local plugin = rawget(_G, "__ZEN_UI_PLUGIN")
                    local have = plugin and Zen.findFolderTab(plugin.config, self:libraryDir())
                    return have and _("Kindle tab in the navbar: added") or _("Add a Kindle tab to the navbar")
                end,
                help_text = _("A native ZenOS folder tab pointing at the download folder: your Kindle books in ZenOS's own cover view, with its sorting and badges. Takes effect after KOReader restarts."),
                callback = guarded(function()
                    if not Zen.available() then notify(_("ZenOS is not running."), 4); return end
                    local ok, msg = Zen.addKindleTab(self:libraryDir(), _("Kindle"))
                    if ok then
                        notify(msg == "already there" and _("The Kindle tab is already in the navbar.")
                            or T(_("Kindle tab %1. Restart KOReader to see it."), msg), 6)
                    else
                        notify(T(_("Could not add the tab: %1"), tostring(msg)), 6)
                    end
                end, "zen tab"),
            },
            {
                text = _("Kindle library strip on Home…"),
                help_text = _("A strip of your recent Kindle books for ZenOS's Home page. It is registered automatically; ZenOS decides whether it is shown."),
                callback = guarded(function() self:showHomeStripInfo() end, "zen strip info"),
            },
            {
                text = _("Banner on ZenOS covers…"),
                help_text = _("Where the “Kindle” corner banner currently reaches."),
                callback = guarded(function() self:showBannerInfo() end, "zen banner info"),
            },
        },
    }

    sub[#sub + 1] = {
        text_func = function()
            return self:isConnected() and _("Amazon account: connected") or _("Amazon account: not connected")
        end,
        sub_item_table = {
            {
                text = _("Register this KOReader with Amazon"),
                help_text = _("Serves a connect page on this device's Wi-Fi address. Open it on your phone, sign in on Amazon's own page, paste the result there. Nothing to type on the Kindle."),
                sub_item_table = self:marketplaceMenu(),
            },
            {
                text = _("Import credentials from file"),
                help_text = T(_("Reads %1. Export it from the Kindle dashboard with tools/export_device.py."), self.import_file),
                callback = guarded(function() self:importCredentials() end, "import"),
            },
            {
                text_func = function()
                    return self.connect_server and _("Stop the connect page") or _("Connect page: not running")
                end,
                enabled_func = function() return self.connect_server ~= nil end,
                callback = function() self:stopConnectServer(); notify(_("Connect page stopped.")) end,
            },
            {
                text = _("Test connection"),
                enabled_func = function() return self:isConnected() end,
                callback = guarded(function() self:testConnection() end, "test"),
            },
            {
                text = _("Forget credentials"),
                enabled_func = function() return self:isConnected() end,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Forget the Amazon device credentials stored on this device? Downloaded books stay."),
                        ok_text = _("Forget"),
                        ok_callback = function()
                            self.device = nil
                            self._client = nil
                            self:saveSettings()
                            notify(_("Credentials forgotten."))
                        end,
                    })
                end,
            },
        },
    }

    sub[#sub + 1] = {
        text = _("Help"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(TextViewer:new{
                title = _("Kindle Whispersync"),
                text = _([[Talks to Amazon's device services the way Kindle hardware does. Send-to-Kindle documents are downloaded as plain MOBI files and opened in KOReader; your position, bookmarks, highlights and notes are written back to Amazon, so a Kindle or the Kindle app resumes where you left off.

How syncing works
• When a book opens, Amazon is checked. If a Kindle read further, you are offered the jump (Automatic sync sets whether to ask).
• After 90 seconds of quiet reading, on close and on suspend, your position is sent and verified by reading it back.
• KOReader writes "most recent read". A Kindle's own "sync to furthest page read" prompt appears only when the furthest position moves, so reading backwards here changes nothing on the Kindle; reading forwards does.
• "Sync status for this book" shows exactly what Amazon holds, and which device wrote it.

Limits
• Store purchases are DRM-protected and are never downloaded or decrypted.
• A book never opened on a Kindle has no Amazon guid yet, and Amazon silently drops writes without one: open it once in the stock reader (or the Kindle app).
• PDFs sent to Kindle have no MOBI text: they download and open, but positions are not synced.

ZenOS
• Kindle Whispersync → ZenOS → Add a Kindle tab puts your downloaded Kindle books in ZenOS's own cover view as a navbar tab.
• ZenOS Settings → Library → Home → Widgets → "Kindle library" adds a strip of your recent Kindle books to Home.
• With "Keep every personal document on this device" and "Feed Amazon read times" on (both default), every Kindle book appears in the native library and in Home → Recent at the time it was last read on a Kindle.
• Every cover that came from the Kindle carries a diagonal "Kindle" corner banner (like ZenOS's "New" banner) on this plugin's shelf, on ZenOS Home and on ZenOS library tiles. Library → "Kindle" banner on covers turns it off or moves it to the other corner.
• Launcher or Controls → Add → Plugin menu → Kindle Whispersync opens the cloud shelf.]]),
            })
        end,
    }

    menu_items.whispersync = {
        text = _("Kindle Whispersync"),
        sorting_hint = "tools",
        sub_item_table = sub,
    }
end

function Whispersync:marketplaceMenu()
    local items = {}
    for _, mp in ipairs(amazon.MARKETPLACES) do
        items[#items + 1] = {
            text = mp.label,
            callback = guarded(function() self:startRegistration(mp.code) end, "registration"),
        }
    end
    return items
end

function Whispersync:editLibraryDir()
    local dialog
    dialog = InputDialog:new{
        title = _("Download folder"),
        input = self:libraryDir(),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local v = dialog:getInputText():match("^%s*(.-)%s*$")
                if v ~= "" then
                    self.settings.library_dir = v
                    self:saveSettings()
                end
                UIManager:close(dialog)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-------------------------------------------------------------------------------
-- account
-------------------------------------------------------------------------------

function Whispersync:setDevice(dev)
    self.device = {
        adp_token = dev.adp_token,
        device_private_key = dev.device_private_key,
        marketplace = dev.marketplace or "us",
        device_serial = dev.device_serial,
        registered_at = dev.registered_at or os.time(),
        customer_name = dev.customer_name,
    }
    self._client = nil
    self:saveSettings()
    self:log("connected to Amazon (" .. tostring(self.device.marketplace) .. ")")
end

function Whispersync:importCredentials()
    local f = io.open(self.import_file, "rb")
    if not f then
        notify(T(_("No file at %1.\n\nOn the dashboard host run:\n  python3 tools/export_device.py\nand copy the result there."), self.import_file), 8)
        return
    end
    local raw = f:read("*a"); f:close()
    local data = amazon.json_decode(raw)
    if type(data) ~= "table" then notify(_("That file is not valid JSON.")); return end
    local dev = data.device or data
    if not dev.adp_token or not dev.device_private_key then
        notify(_("The file has no adp_token / device_private_key."))
        return
    end
    self:setDevice(dev)
    -- A quick signing self-test so a broken key shows up now, not on the
    -- first sync.
    local ok, err = adp.headers("GET", "/x", "", "t", dev.device_private_key)
    if not ok then
        notify(T(_("Credentials saved, but the private key could not be used: %1"), tostring(err)), 8)
        return
    end
    notify(T(_("Connected (signing via %1). You can delete %2 now."), adp.backend or "?", self.import_file), 6)
end

function Whispersync:testConnection()
    NetworkMgr:runWhenOnline(function()
        local client, err = self:client()
        if not client then notify(err); return end
        local info = InfoMessage:new{ text = _("Contacting Amazon…") }
        UIManager:show(info)
        UIManager:tickAfterNext(guarded(function()
            local items, err2, extra = client:library()
            UIManager:close(info)
            if not items then notify(T(_("Failed: %1"), tostring(err2)), 10); return end
            local pdoc, ebok, dict = 0, 0, 0
            for _, it in ipairs(items) do
                if Catalog.is_dictionary(it) then dict = dict + 1
                elseif it.content_type == "PDOC" then pdoc = pdoc + 1
                else ebok = ebok + 1 end
            end
            Catalog.merge(self.catalog, items, extra and extra.removed)
            self.library_meta.synced_at = os.time()
            self:saveSettings()
            notify(T(_("Connected. %1 personal documents, %2 store books, %3 dictionaries."), pdoc, ebok, dict), 8)
        end, "test connection"))
    end)
end

-- The connect page ------------------------------------------------------------
--
-- Why a web page: the OAuth flow ends on Amazon's blank "maplanding" page
-- whose address carries the authorization code, and the only place that
-- address exists is the browser that signed in. On a phone, copying it is one
-- long-press. Typing it on an e-ink keyboard is not. So the plugin serves a
-- page on the Kindle's own Wi-Fi address with the sign-in link and a paste
-- box, exactly like the dashboard's connect.php, and the phone does both.
--
-- Why not the Kindle's own credentials: stock firmware authenticates with a
-- TLS client certificate (/var/local/java/prefs/certs/client.p12) against
-- the cde-g7g hosts, not with an ADP token against the -ta- hosts we speak,
-- and Amazon picks the download format from the identity: the real Kindle's
-- identity gets KFX, which KOReader cannot open. A registration presenting a
-- legacy device type is what makes Send-to-Kindle documents arrive as MOBI.

--- This device's IPv4 address on the LAN, or nil.
function Whispersync:deviceIP()
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.udp then
        local udp = socket.udp()
        if udp then
            -- A connected UDP socket picks the outgoing address without sending.
            if udp:setpeername("8.8.8.8", 53) then
                local ip = udp:getsockname()
                udp:close()
                if ip and ip ~= "0.0.0.0" then return ip end
            else
                udp:close()
            end
        end
    end
    local ok2, NetInfo = pcall(require, "ffi/netinfo")
    if ok2 and NetInfo then
        local ok3, ifaces = pcall(function() return NetInfo:new():retrieve() end)
        if ok3 and type(ifaces) == "table" then
            for _, iface in ipairs(ifaces) do
                if iface.ipv4 and iface.name ~= "lo" then return iface.ipv4 end
            end
        end
    end
    local p = io.popen("ifconfig wlan0 2>/dev/null; ip -4 addr show 2>/dev/null")
    if p then
        local out = p:read("*a") or ""; p:close()
        local ip = out:match("inet addr:(%d+%.%d+%.%d+%.%d+)") or out:match("inet (%d+%.%d+%.%d+%.%d+)")
        if ip and ip ~= "127.0.0.1" then return ip end
    end
    return nil
end

local function firewall(action, port)
    -- The Kindle drops inbound connections by default; open (or close) the
    -- port the same way KOReader's HTTP inspector does.
    if not Device:isKindle() then return end
    os.execute(("iptables -%s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT"):format(action, port))
    os.execute(("iptables -%s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT"):format(action, port))
end

function Whispersync:startRegistration(mp_code)
    local ok, SimpleTCPServer = pcall(require, "ui/message/simpletcpserver")
    if not ok or not SimpleTCPServer then
        return self:startRegistrationManual(mp_code)
    end
    NetworkMgr:runWhenOnline(function()
        self:stopConnectServer()
        local login = amazon.build_login(mp_code)
        self.pending_login = login
        local server = SimpleTCPServer:new{
            host = "*",
            port = CONNECT_PORT,
            receiveCallback = function(data, client) return self:onConnectRequest(data, client) end,
        }
        firewall("A", CONNECT_PORT)
        local started, err = server:start()
        if not started then
            firewall("D", CONNECT_PORT)
            logger.warn("whispersync: connect page failed to start", err)
            notify(T(_("Could not start the connect page (%1). Falling back to the QR code flow."), tostring(err)), 6)
            return self:startRegistrationManual(mp_code)
        end
        self.connect_server = server
        UIManager:insertZMQ(server)
        local ip = self:deviceIP()
        local url = ("http://%s:%d/"):format(ip or "<this Kindle's IP address>", CONNECT_PORT)
        self.connect_url = url
        local f = io.open(self.login_file, "wb")
        if f then f:write(url, "\n\n", login.url, "\n"); f:close() end

        self.connect_dialog = ConnectDialog.new{
            url = url,
            store_label = amazon.marketplace(mp_code).label,
            status = _("Waiting for a phone to open the page…"),
            on_stop = function() self:stopConnectServer() end,
            on_hide = function() self.connect_dialog = nil end,
        }
        UIManager:show(self.connect_dialog)
    end)
end

function Whispersync:stopConnectServer()
    if self.connect_server then
        pcall(function() UIManager:removeZMQ(self.connect_server) end)
        pcall(function() self.connect_server:stop() end)
        firewall("D", CONNECT_PORT)
        self.connect_server = nil
        self.connect_url = nil
    end
end

function Whispersync:connectStatus(text)
    if self.connect_dialog then pcall(function() self.connect_dialog:setStatus(text) end) end
end

local CONNECT_CSS = [[body{font:17px/1.5 -apple-system,system-ui,sans-serif;max-width:34em;margin:2em auto;padding:0 1em;color:#222}
h1{font-size:1.4em}ol{padding-left:1.2em}li{margin:.5em 0}a.btn,button{display:inline-block;background:#232f3e;color:#fff;padding:.7em 1.2em;border-radius:6px;text-decoration:none;border:0;font-size:1em}
textarea{width:100%;min-height:7em;font-size:1em;box-sizing:border-box}small{color:#666}.ok{color:#176d2b}.bad{color:#a12}]]

function Whispersync:connectPage(status_html)
    local login = self.pending_login
    local body = {
        "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>",
        "<title>Connect KOReader to Amazon</title><style>", CONNECT_CSS, "</style>",
        "<h1>Connect KOReader to Amazon</h1>",
        status_html or "",
        "<ol>",
        "<li><a class=btn href=\"", html_escape(login.url), "\" target=_blank rel=noopener>Sign in to Amazon</a><br>",
        "<small>Amazon's own sign-in page. Password manager, passkey and 2FA all work. Nothing you type there reaches this device.</small></li>",
        "<li>Amazon will land you on a <b>blank page</b>. Copy its full address from the address bar.</li>",
        "<li><form method=get action=/finish><textarea name=code placeholder='Paste the address here' required></textarea><br>",
        "<button type=submit>Finish connecting</button></form></li>",
        "</ol>",
        "<p><small>Store: ", html_escape(amazon.marketplace(login.marketplace).label),
        ". This page is served by KOReader on your Kindle and disappears once connected.</small></p>",
    }
    return table.concat(body)
end

local function http_response(status, body, content_type)
    return table.concat({
        "HTTP/1.1 ", status, "\r\n",
        "Content-Type: ", content_type or "text/html; charset=utf-8", "\r\n",
        "Content-Length: ", tostring(#body), "\r\n",
        "Cache-Control: no-store\r\n",
        "Connection: close\r\n\r\n",
        body,
    })
end

function Whispersync:onConnectRequest(data, client)
    local server = self.connect_server
    if not server then return end
    local ok, err = xpcall(function() self:handleConnectRequest(data, client, server) end, debug.traceback)
    if not ok then
        logger.err("whispersync: connect page error", err)
        pcall(function() server:send(http_response("500 Internal Server Error", "<p>Something broke on the Kindle; see crash.log.</p>"), client) end)
    end
end

function Whispersync:handleConnectRequest(data, client, server)
    local method, uri = data:match("^(%u+) ([^ \r\n]*) HTTP/%d%.%d")
    local path, query = (uri or "/"):match("^([^%?]*)%??(.*)$")
    local function reply(status, body) server:send(http_response(status, body), client) end
    if not self.pending_login then
        return reply("410 Gone", "<p>Registration is no longer pending. Start it again from KOReader.</p>")
    end
    if method ~= "GET" then
        return reply("405 Method Not Allowed", "<p>GET only.</p>")
    end
    if path == "/" or path == "/index.html" then
        self:connectStatus(_("Page opened. Waiting for the sign-in…"))
        return reply("200 OK", self:connectPage())
    end
    if path == "/finish" then
        local raw = query:match("code=([^&]*)")
        local code, err = amazon.extract_code(raw and url_decode(raw) or "")
        if not code then
            self:connectStatus(_("That paste had no code. Waiting…"))
            return reply("200 OK", self:connectPage("<p class=bad>" .. html_escape(err) .. "</p>"))
        end
        self:connectStatus(_("Code received, registering with Amazon…"))
        -- Exchange the code right here: the browser waits a few seconds.
        local dev, rerr = amazon.register(self.pending_login, code, nil)
        if not dev then
            logger.warn("whispersync: registration failed", rerr)
            self:connectStatus(T(_("Amazon said no: %1"), tostring(rerr):sub(1, 80)))
            return reply("200 OK", self:connectPage("<p class=bad>Amazon rejected the registration: "
                .. html_escape(rerr) .. "</p><p>Sign in again to get a fresh code; codes are single-use.</p>"))
        end
        self:setDevice(dev)
        self.pending_login = nil
        os.remove(self.login_file)
        reply("200 OK", "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><style>"
            .. CONNECT_CSS .. "</style><h1 class=ok>Connected</h1><p>KOReader is registered with Amazon as a Kindle device. This registration does not expire.</p><p>You can close this page.</p>")
        self:connectStatus(_("Connected. This registration does not expire."))
        UIManager:nextTick(function()
            self:stopConnectServer()
            local dlg = self.connect_dialog
            self.connect_dialog = nil
            if dlg then UIManager:scheduleIn(3, function() pcall(function() dlg:close() end) end) end
            notify(_("Connected to Amazon. Open the Kindle library to fetch your books."), 6)
        end)
        return
    end
    reply("404 Not Found", "<p>Not here. Try <a href=/>the connect page</a>.</p>")
end

--- Fallback when no listener can be started: QR code of the sign-in URL,
-- then paste the result on this device.
function Whispersync:startRegistrationManual(mp_code)
    local login = amazon.build_login(mp_code)
    self.pending_login = login
    local f = io.open(self.login_file, "wb")
    if f then f:write(login.url, "\n"); f:close() end

    local function ask_for_code()
        local dialog
        dialog = InputDialog:new{
            title = _("Paste the address Amazon sent you to"),
            description = _("After signing in, Amazon shows a blank page. Copy its full address (it contains openid.oa2.authorization_code) and paste it here, or just the code."),
            input = "",
            input_type = "text",
            allow_newline = false,
            buttons = { {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                { text = _("Finish connecting"), is_enter_default = true, callback = function()
                    local code, err = amazon.extract_code(dialog:getInputText())
                    if not code then notify(err, 6); return end
                    UIManager:close(dialog)
                    NetworkMgr:runWhenOnline(function() self:finishRegistration(code) end)
                end },
            } },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end

    local dlg = ConnectDialog.new{
        url = login.url,
        store_label = amazon.marketplace(mp_code).label,
        status = _("No listener available: paste the result on this device instead."),
        on_stop = function() end,
        on_hide = ask_for_code,
    }
    UIManager:show(dlg)
end

function Whispersync:finishRegistration(code)
    local login = self.pending_login
    if not login then notify(_("Start the registration again.")); return end
    local info = InfoMessage:new{ text = _("Registering with Amazon…") }
    UIManager:show(info)
    UIManager:tickAfterNext(guarded(function()
        local dev, err = amazon.register(login, code, nil)
        UIManager:close(info)
        if not dev then notify(err, 10); return end
        self:setDevice(dev)
        self.pending_login = nil
        os.remove(self.login_file)
        notify(_("Connected to Amazon. This registration does not expire."), 6)
    end, "registration"))
end

-------------------------------------------------------------------------------
-- library: catalog, covers, downloads
-------------------------------------------------------------------------------

function Whispersync:coversDir()
    return self:libraryDir() .. "/covers"
end

local function safe_filename(title, asin)
    local name = (title or asin):gsub("[/\\:%*%?\"<>|%c]", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
    if #name > 120 then name = name:sub(1, 120) end
    if name == "" then name = asin end
    return name
end

--- Fetch everything immutable about a book once (header metadata and cover)
-- and, when asked, its current position. Returns true if anything changed.
function Whispersync:enrichItem(client, it, what)
    local changed = false
    local is_doc = Catalog.is_document(it)
    if what.header and is_doc and not it.header_fetched then
        local tmp = self:coversDir() .. "/" .. it.asin .. ".head"
        util.makePath(self:coversDir())
        local ok = client:download(it.asin, it.content_type, tmp, amazon.HEADER_BYTES)
        if ok then
            local head = mobi.read_file(tmp) or ""
            if mobi.is_mobi(head) then
                local hdr = mobi.parse_header(head)
                if hdr then Catalog.apply_header(it, hdr) end
                if what.cover and not it.cover_fetched then
                    local cs, ce = mobi.cover_record(head, it.content_size)
                    if cs and ce and ce - cs < 8 * 1024 * 1024 then
                        local img = self:coversDir() .. "/" .. it.asin .. ".img"
                        if client:download_range(it.asin, it.content_type, img, cs, ce) then
                            local kind = mobi.image_kind(mobi.read_file(img, 16))
                            if kind then
                                local dest = Catalog.cover_path(self:libraryDir(), it.asin, kind)
                                os.remove(dest)
                                if os.rename(img, dest) then it.cover = dest end
                            end
                        end
                        os.remove(img)
                    end
                    it.cover_fetched = true
                end
            else
                it.header_fetched = true
                it.not_mobi = head:sub(1, 4) == "%PDF" and "pdf" or "other"
                it.cover_fetched = true
            end
            changed = true
        else
            -- Don't hammer a title Amazon refuses (KFX-only).
            it.header_fetched = true
            it.header_error = true
            changed = true
        end
        os.remove(tmp)
    end
    if what.cover and not is_doc and not it.cover_fetched then
        util.makePath(self:coversDir())
        local dest = Catalog.cover_path(self:libraryDir(), it.asin, "jpg")
        if client:store_cover(it.asin, dest) then it.cover = dest end
        it.cover_fetched = true
        changed = true
    end
    if what.position and is_doc and it.not_mobi == nil then
        local sc, err = client:sidecar(it.asin, it.content_type)
        if not err then
            Catalog.apply_sidecar(it, sc)
            changed = true
        end
    end
    return changed
end

--- Fetch the library listing, then metadata, covers and progress. Runs
-- under Trapper so the progress message repaints and can be dismissed.
function Whispersync:refreshLibrary(opts)
    opts = opts or {}
    if not self:isConnected() then
        notify(_("Connect your Amazon account first (Kindle Whispersync → Amazon account)."), 6)
        return
    end
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local client = self:client()
            local age = os.time() - (self.library_meta.synced_at or 0)
            if opts.force or age >= LIBRARY_MIN_INTERVAL then
                if not Trapper:info(_("Fetching your Kindle library…")) then return end
                local items, sync_time, extra = client:library(self.library_meta.sync_time)
                if not items then
                    Trapper:clear()
                    notify(T(_("Could not fetch the library: %1"), tostring(sync_time)), 8)
                    self:log("library fetch failed: " .. tostring(sync_time))
                    return
                end
                local added = Catalog.merge(self.catalog, items, extra and extra.removed)
                self.library_meta.synced_at = os.time()
                if sync_time and sync_time ~= "" then self.library_meta.sync_time = sync_time end
                self:saveSettings()
                self:log(("library: %d items, %d new"):format(#items, added))
            end
            local list = Catalog.shelf_items(self.catalog, { show_store = self.settings.show_store_books, sort = "recent" })
            local n = #list
            for i, it in ipairs(list) do
                local needs = (Catalog.is_document(it) and (not it.header_fetched or (opts.positions and it.not_mobi == nil)))
                    or (not Catalog.is_document(it) and not it.cover_fetched)
                if needs then
                    if not Trapper:info(T(_("Updating %1 of %2\n%3"), i, n, Catalog.title(it))) then break end
                    local ok, err = pcall(self.enrichItem, self, client, it, { header = true, cover = true, position = opts.positions })
                    if not ok then logger.warn("whispersync: enrich failed", it.asin, err) end
                    if i % 5 == 0 then self:saveSettings() end
                    ffiutil.usleep(REFRESH_PACE_US)
                end
            end
            self.library_meta.enriched_at = os.time()
            self:saveSettings()

            -- Keep the whole library on the device, so the native library,
            -- Recent and search see every book, not just the ones opened.
            if self.settings.keep_on_device then
                local cap = (tonumber(self.settings.download_cap_mb) or 40) * 1024 * 1024
                local todo = {}
                for _, it in ipairs(list) do
                    if Catalog.is_document(it) and not file_exists(it.file) and not it.download_failed
                        and it.not_mobi == nil and (not it.content_size or it.content_size <= cap) then
                        todo[#todo + 1] = it
                    end
                end
                for i, it in ipairs(todo) do
                    if not Trapper:info(T(_("Downloading %1 of %2\n%3"), i, #todo, Catalog.title(it))) then break end
                    local ok, err = pcall(self.downloadItemNow, self, client, it)
                    if not ok or err then
                        it.download_failed = true
                        self:log("auto-download failed " .. it.asin .. ": " .. tostring(err))
                    end
                    if i % 3 == 0 then self:saveSettings() end
                end
                self:saveSettings()
            end

            self:feedHistory()
            Trapper:clear()
            if self.shelf then self.shelf:refresh() end
            if opts.then_cb then opts.then_cb() end
        end)
    end)
end

--- Hand Amazon's read times and progress to KOReader's history and sidecars
-- for every downloaded book (except the one open right now).
function Whispersync:feedHistory()
    if not self.settings.feed_history then return end
    local open_file = self.ui and self.ui.document and self.ui.document.file or nil
    local n = 0
    for _, it in pairs(self.catalog) do
        if Catalog.is_document(it) and file_exists(it.file) and (it.remote_epoch or Catalog.percent(it)) then
            local ok, changed = pcall(Zen.recordHistory, it.file, it.remote_epoch, {
                percent = Catalog.percent(it), no_flush = true,
                is_open = function(f) return f == open_file end,
            })
            if ok and changed and (changed.history or changed.sidecar) then n = n + 1 end
        end
    end
    pcall(Zen.flushHistory)
    if n > 0 then self:log(("history/progress updated for %d book(s)"):format(n)) end
end

--- Synchronous download used inside a Trapper loop. Returns nil on success,
-- an error string otherwise.
function Whispersync:downloadItemNow(client, it)
    local dir = self:libraryDir()
    util.makePath(dir)
    local base = dir .. "/" .. safe_filename(Catalog.title(it), it.asin)
    local author = Catalog.author(it)
    if author ~= "" then base = base .. " - " .. safe_filename(author, "") end
    local tmp = base .. ".part"
    local ok, derr = client:download(it.asin, it.content_type, tmp)
    if not ok then return tostring(derr) end
    local head = mobi.read_file(tmp, 32768) or ""
    local final
    if mobi.is_mobi(head) then
        local hdr = mobi.parse_header(head)
        if hdr and hdr.encrypted then os.remove(tmp); return "DRM-protected" end
        final = base .. ".mobi"
        if hdr then Catalog.apply_header(it, hdr) end
    elseif head:sub(1, 4) == "%PDF" then
        final = base .. ".pdf"
    else
        final = base .. ".bin"
    end
    os.remove(final)
    if not os.rename(tmp, final) then return "could not save the file" end
    it.file = final
    it.downloaded_at = os.time()
    self.catalog[it.asin] = it
    self._kindle_files = nil
    self:log("downloaded " .. Catalog.title(it))
    return nil
end

--- Tap on a shelf item: open it, downloading first if needed.
function Whispersync:openItem(it)
    if not Catalog.is_document(it) then
        notify(_("Store purchases are DRM-protected. KOReader cannot open them, and this plugin never downloads or decrypts them."), 8)
        return
    end
    if file_exists(it.file) then
        self:openFile(it.file)
        return
    end
    NetworkMgr:runWhenOnline(function() self:downloadItem(it, function(path) self:openFile(path) end) end)
end

function Whispersync:downloadItem(it, then_cb)
    local client, err = self:client()
    if not client then notify(err); return end
    local dir = self:libraryDir()
    util.makePath(dir)
    local base = dir .. "/" .. safe_filename(Catalog.title(it), it.asin)
    local author = Catalog.author(it)
    if author ~= "" then base = base .. " - " .. safe_filename(author, "") end
    local tmp = base .. ".part"
    Trapper:wrap(function()
        Trapper:info(T(_("Downloading\n%1\n(%2)"), Catalog.title(it), Catalog.human_size(it.content_size)), true, true)
        local ok, derr = client:download(it.asin, it.content_type, tmp)
        Trapper:clear()
        if not ok then
            notify(T(_("Download failed: %1"), tostring(derr)), 8)
            self:log("download failed " .. it.asin .. ": " .. tostring(derr))
            return
        end
        local head = mobi.read_file(tmp, 32768) or ""
        local final
        if mobi.is_mobi(head) then
            local hdr = mobi.parse_header(head)
            if hdr and hdr.encrypted then
                os.remove(tmp)
                notify(_("This document is DRM-protected and cannot be opened in KOReader."), 8)
                return
            end
            final = base .. ".mobi"
            if hdr then Catalog.apply_header(it, hdr) end
        elseif head:sub(1, 4) == "%PDF" then
            final = base .. ".pdf"
        else
            final = base .. ".bin"
        end
        os.remove(final)
        if not os.rename(tmp, final) then notify(_("Could not save the downloaded file.")); return end
        it.file = final
        it.downloaded_at = os.time()
        self.catalog[it.asin] = it
        self:saveSettings()
        self:log("downloaded " .. Catalog.title(it))
        if self.settings.feed_history and it.remote_epoch then
            pcall(Zen.recordHistory, final, it.remote_epoch, { percent = Catalog.percent(it) })
        end
        if self.shelf then self.shelf:refresh() end
        if final:sub(-4) == ".pdf" then
            notify(_("Saved. PDFs have no MOBI text, so positions are not synced for this one."), 6)
        end
        if then_cb then then_cb(final) end
    end)
end

function Whispersync:openFile(path)
    if self.shelf then UIManager:close(self.shelf); self.shelf = nil end
    local ReaderUI = require("apps/reader/readerui")
    if self.ui and self.ui.document then
        self.ui:switchDocument(path)
    else
        ReaderUI:showReader(path)
    end
end

function Whispersync:removeDownload(it)
    if it.file then
        os.remove(it.file)
        local DocSettings = require("docsettings")
        pcall(function()
            local sdr = DocSettings:getSidecarDir(it.file)
            os.remove(sdr .. "/whispersync.index")
        end)
    end
    it.file = nil
    it.downloaded_at = nil
    self:saveSettings()
    if self.shelf then self.shelf:refresh() end
end

-------------------------------------------------------------------------------
-- the shelf
-------------------------------------------------------------------------------

function Whispersync:shelfItems()
    return Catalog.shelf_items(self.catalog, {
        sort = self.settings.sort,
        show_store = self.settings.show_store_books,
        downloaded_only = self.settings.downloaded_only,
        exists = file_exists,
    })
end

function Whispersync:showShelf()
    if not self:isConnected() then
        UIManager:show(ConfirmBox:new{
            text = _("Connect your Amazon account first. Register this KOReader with Amazon now?"),
            ok_text = _("Register"),
            ok_callback = function() self:startRegistration(self.settings.marketplace or "us") end,
        })
        return
    end
    if self.shelf then UIManager:close(self.shelf); self.shelf = nil end
    self.shelf = Shelf.new{
        title = _("Kindle library"),
        items_func = function() return self:shelfItems() end,
        subtitle_func = function()
            local n = #self:shelfItems()
            local when = self.library_meta.synced_at and os.date("%H:%M", self.library_meta.synced_at) or _("never")
            local sort = ({ recent = _("recent"), title = _("title"), author = _("author") })[self.settings.sort] or ""
            return T(_("%1 books · by %2 · updated %3"), n, sort, when)
        end,
        title_func = Catalog.title,
        author_func = Catalog.author,
        status_func = function(it) return Catalog.status_text(it, { exists = file_exists }) end,
        percent_func = Catalog.percent,
        dim_func = function(it) return not Catalog.is_document(it) end,
        badge_func = function() return self.settings.kindle_badge end,
        cover_func = function(it) return file_exists(it.cover) and it.cover or nil end,
        on_open = guarded(function(it) self:openItem(it) end, "open"),
        on_hold = guarded(function(it) self:showDetails(it) end, "details"),
        menu_buttons_func = function() return self:shelfMenuButtons() end,
        on_close = function() self.shelf = nil end,
        empty_text = _("No books yet.\nTap ☰ (top left) and refresh from Amazon."),
    }
    UIManager:show(self.shelf)
    -- First visit, or a stale listing: refresh in the background.
    if not self.library_meta.synced_at then
        self:refreshLibrary({ positions = true, force = true })
    elseif os.time() - (self.library_meta.synced_at or 0) >= LIBRARY_MIN_INTERVAL and online() then
        self:refreshLibrary({ positions = false })
    end
end

function Whispersync:shelfMenuButtons()
    local function sort_button(mode, label)
        return { text = (self.settings.sort == mode and "● " or "○ ") .. label, callback = function()
            self.settings.sort = mode; self:saveSettings(); if self.shelf then self.shelf:refresh() end
        end }
    end
    return {
        { { text = _("Refresh library, covers and progress from Amazon"), callback = function() self:refreshLibrary({ positions = true, force = true }) end } },
        { sort_button("recent", _("Recent")), sort_button("title", _("Title")), sort_button("author", _("Author")) },
        { { text = (self.settings.downloaded_only and "☑ " or "☐ ") .. _("Only books on this device"), callback = function()
            self.settings.downloaded_only = not self.settings.downloaded_only; self:saveSettings(); if self.shelf then self.shelf:refresh() end
        end } },
        { { text = (self.settings.show_store_books and "☑ " or "☐ ") .. _("Show store purchases (DRM)"), callback = function()
            self.settings.show_store_books = not self.settings.show_store_books; self:saveSettings(); if self.shelf then self.shelf:refresh() end
        end } },
        { { text = _("Sync log"), callback = function() self:showLog() end } },
    }
end

--- Hold on a shelf item: metadata and actions.
function Whispersync:showDetails(it)
    local viewer
    local buttons = {}
    local row1 = {}
    if Catalog.is_document(it) then
        if file_exists(it.file) then
            row1[#row1 + 1] = { text = _("Open"), callback = function() UIManager:close(viewer); self:openFile(it.file) end }
            row1[#row1 + 1] = { text = _("Remove download"), callback = function()
                UIManager:close(viewer)
                UIManager:show(ConfirmBox:new{
                    text = T(_("Delete the downloaded copy of “%1” from this device? Your progress on Amazon is untouched."), Catalog.title(it)),
                    ok_text = _("Delete"),
                    ok_callback = function() self:removeDownload(it) end,
                })
            end }
        else
            row1[#row1 + 1] = { text = _("Download and open"), callback = function() UIManager:close(viewer); self:openItem(it) end }
        end
        row1[#row1 + 1] = { text = _("Update progress"), callback = function()
            UIManager:close(viewer)
            NetworkMgr:runWhenOnline(function()
                Trapper:wrap(function()
                    Trapper:info(_("Asking Amazon…"), true, true)
                    local client = self:client()
                    if client then pcall(self.enrichItem, self, client, it, { header = true, cover = true, position = true }) end
                    self:saveSettings()
                    Trapper:clear()
                    if self.shelf then self.shelf:refresh() end
                    self:showDetails(it)
                end)
            end)
        end }
    end
    buttons[#buttons + 1] = row1
    buttons[#buttons + 1] = { { text = _("Close"), callback = function() UIManager:close(viewer) end } }
    viewer = TextViewer:new{
        title = Catalog.title(it),
        title_multilines = true,
        text = Catalog.details(it),
        buttons_table = buttons,
    }
    UIManager:show(viewer)
end

-------------------------------------------------------------------------------
-- book identity and index
-------------------------------------------------------------------------------

--- The catalog entry for the open document, or nil if it is not one of ours.
function Whispersync:currentBook()
    if not self.ui or not self.ui.document then return nil end
    if self._book_for_file == self.ui.document.file then return self._book end
    self._book_for_file = self.ui.document.file
    self._book = nil
    local file = self.ui.document.file
    for _, it in pairs(self.catalog) do
        if it.file == file then self._book = it; break end
    end
    if not self._book then
        -- A MOBI whose EXTH ASIN matches a catalog key (e.g. copied in by
        -- hand) counts too.
        local head = mobi.read_file(file, 32768)
        if head and mobi.is_mobi(head) then
            local hdr = mobi.parse_header(head)
            local asin = hdr and (hdr.asin or hdr.asin_alt)
            if asin and self.catalog[asin] then
                self._book = self.catalog[asin]
                self._book.file = file
                Catalog.apply_header(self._book, hdr)
                self:saveSettings()
            end
        end
    end
    return self._book
end

function Whispersync:bookState()
    local st = self.ui.doc_settings:readSetting("whispersync")
    if not st then
        st = { links = {} }
        self.ui.doc_settings:saveSetting("whispersync", st)
    end
    st.links = st.links or {}
    return st
end

--- Build or load the plain-text index for the open book. Returns a PosMap
-- (text-based when possible, percent-only otherwise), or nil for PDFs.
function Whispersync:posmap()
    local book = self:currentBook()
    if not book then return nil end
    if self._posmap_for == book.file and self._posmap then return self._posmap end
    local doc = self.ui.document
    if doc.info.has_pages then
        -- PDFs: no MOBI text, no byte positions. Nothing to map.
        return nil
    end
    local DocSettings = require("docsettings")
    local sdr = DocSettings:getSidecarDir(book.file)
    util.makePath(sdr)
    local cache = sdr .. "/whispersync.index"
    local idx = mobi.load_index(cache)
    if not idx then
        local raw, rerr = mobi.read_file(book.file)
        local text, hdr
        if raw then
            text, hdr = mobi.extract_text(raw)
        else
            hdr = rerr
        end
        raw = nil
        if text and hdr then
            idx = mobi.build_index(text)
            Catalog.apply_header(book, hdr)
            mobi.save_index(idx, cache)
            logger.info("whispersync: indexed", book.file, #text, "bytes,", idx.nseg, "segments")
            self:log(("indexed %s: %d bytes, %d segments"):format(Catalog.title(book), #text, idx.nseg))
        else
            logger.warn("whispersync: cannot index", book.file, hdr)
            self:log("could not index " .. Catalog.title(book) .. ": " .. tostring(hdr))
        end
    end
    if not idx then
        -- Percent-only stand-in with the same interface.
        local pages = doc:getPageCount()
        local text_length = book.text_length or 1
        self._posmap = {
            percent_only = true,
            to_offset = function(_, xp)
                local page = doc:getPageFromXPointer(xp) or 1
                return math.floor((page - 0.5) / pages * text_length), "percent"
            end,
            to_xpointer = function(_, raw)
                local page = math.max(1, math.min(pages, math.floor(raw / text_length * pages + 0.5)))
                return doc:getPageXPointer(page), "percent"
            end,
            range_to_xpointers = function(pm, s, e) local a = pm:to_xpointer(s); return a, pm:to_xpointer(e or s) or a, nil end,
            xpointers_to_range = function(pm, p0, p1) local a = pm:to_offset(p0); return a, p1 and pm:to_offset(p1) or a end,
        }
    else
        self._posmap = PosMap.new(idx, doc, book.text_length or idx.raw_length)
    end
    self._posmap_for = book.file
    return self._posmap
end

function Whispersync:currentXPointer()
    if self.ui.rolling and self.ui.rolling.getLastProgress then
        local xp = self.ui.rolling:getLastProgress()
        if xp then return xp end
    end
    return self.ui.document:getXPointer()
end

function Whispersync:currentOffset()
    local pm = self:posmap()
    if not pm then return nil end
    return pm:to_offset(self:currentXPointer())
end

function Whispersync:localPercent()
    local book = self:currentBook()
    local off = self:currentOffset()
    if not book or not off or not book.text_length or book.text_length <= 0 then return nil end
    return math.min(100, off / book.text_length * 100)
end

-------------------------------------------------------------------------------
-- reader hooks
-------------------------------------------------------------------------------

function Whispersync:onReaderReady()
    self._book_for_file = nil
    self._posmap = nil
    self.pending_push = false
    self.annotations_dirty = false
    local book = self:currentBook()
    if not book or not self:isConnected() then return end
    local st = self:bookState()
    st.opened_at = os.time()
    -- KOReader emits PageUpdate while restoring the saved position; that is
    -- not the user reading, and must not count as local progress or a
    -- freshly downloaded book would push its opening page over Amazon's
    -- real position.
    self._ready_at = os.time()
    if self.settings.auto_pull and online() then
        -- Let the first page paint before we go to the network.
        UIManager:scheduleIn(1, guarded(function() self:syncNow(false) end, "sync on open"))
    end
end

function Whispersync:onPageUpdate()
    if not self.ui or not self.ui.document then return end
    if not self._ready_at or os.time() - self._ready_at < 3 then return end
    local book = self:currentBook()
    if not book then return end
    local st = self:bookState()
    st.last_local_change = os.time()
    self.pending_push = true
    if self.settings.auto_push and self:isConnected() then
        UIManager:unschedule(self.push_task)
        UIManager:scheduleIn(PUSH_QUIET_SECONDS, self.push_task)
    end
end

function Whispersync:onAnnotationsModified()
    if self:currentBook() then
        self.annotations_dirty = true
        self.pending_push = true
        if self.settings.auto_push and self:isConnected() then
            UIManager:unschedule(self.push_task)
            UIManager:scheduleIn(PUSH_QUIET_SECONDS, self.push_task)
        end
    end
end

function Whispersync:onCloseDocument()
    UIManager:unschedule(self.push_task)
    if self.settings.auto_push then guarded(function() self:pushIfNeeded("close") end, "push on close")() end
    self._posmap = nil
    self._posmap_for = nil
end

function Whispersync:onSuspend()
    UIManager:unschedule(self.push_task)
    if self.settings.auto_push then guarded(function() self:pushIfNeeded("suspend") end, "push on suspend")() end
end

function Whispersync:onNetworkConnected()
    if self.pending_push and self.settings.auto_push and self.ui and self.ui.document then
        UIManager:scheduleIn(3, self.push_task)
    end
end

function Whispersync:onCloseWidget()
    UIManager:unschedule(self.push_task)
    self:stopConnectServer()
end

-------------------------------------------------------------------------------
-- sync: position
-------------------------------------------------------------------------------

--- Fetch the sidecar for the open book and remember guid/position facts.
function Whispersync:fetchSidecar()
    local book = self:currentBook()
    local client, err = self:client()
    if not book or not client then return nil, err end
    local sc, serr = client:sidecar(book.asin, book.content_type or "PDOC")
    if serr then
        self:log("Amazon unreachable: " .. tostring(serr))
        return nil, serr
    end
    Catalog.apply_sidecar(book, sc)
    self:saveSettings()
    local st = self:bookState()
    st.remote_pos = sc and sc.position or nil
    st.remote_epoch = sc and sc.last_read_epoch or nil
    return sc
end

function Whispersync:decide(sc)
    local st = self:bookState()
    local pm = self:posmap()
    local local_pos = pm and self:currentOffset() or nil
    return BookSync.decide_position({
        local_pos = local_pos,
        last_pushed_pos = st.last_pushed_pos,
        last_local_change = st.last_local_change,
    }, sc), local_pos
end

--- Full sync of the open book: position decision, then annotations.
function Whispersync:syncNow(interactive)
    if interactive == nil then interactive = true end
    local book = self:currentBook()
    if not book then
        if interactive then notify(_("This book is not from your Kindle library.")) end
        return
    end
    if not self:isConnected() then
        if interactive then notify(_("Connect your Amazon account first.")) end
        return
    end
    local go = guarded(function()
        local sc, err = self:fetchSidecar()
        if err then
            if interactive then notify(T(_("Amazon could not be reached: %1"), tostring(err)), 6) end
            return
        end
        local decision, local_pos = self:decide(sc)
        self:log(("%s: %s (here %s, Amazon %s)"):format(Catalog.title(book), decision,
            tostring(local_pos), tostring(sc and sc.position)))
        if decision == "pull" or decision == "conflict_remote_newer" then
            self:offerPull(sc, decision == "conflict_remote_newer", interactive)
        elseif decision == "push" or decision == "conflict_local_newer" then
            if self.settings.auto_push or interactive then
                self:doPush(sc, interactive)
            end
        elseif interactive then
            if sc == nil then
                notify(_("Amazon has no record of this book being opened yet, so nothing can be written until it is opened once on a Kindle."), 8)
            else
                notify(_("Already in sync with Amazon."), 3)
            end
        end
        if self.settings.sync_annotations and sc and sc.guid ~= "" then
            self:reconcileAnnotations(sc, false)
        end
    end, "sync")
    if interactive then NetworkMgr:runWhenOnline(go) elseif online() then go() end
end

function Whispersync:describeRemote(sc)
    local book = self:currentBook()
    local pct = (book and book.text_length and sc.position) and (sc.position / book.text_length * 100) or nil
    local when = when_text(sc.last_read_epoch)
    if pct then return T(_("%1% (%2)"), ("%.1f"):format(math.min(100, pct)), when) end
    return T(_("position %1 (%2)"), tostring(sc.position), when)
end

function Whispersync:offerPull(sc, is_conflict, interactive)
    local mode = self.settings.pull_mode
    if mode == "never" and not interactive then return end
    if mode == "always" and not is_conflict and not interactive then
        self:jumpTo(sc)
        return
    end
    local st = self:bookState()
    -- Don't nag about the same remote position twice in one session.
    if not interactive and st.prompted_for == sc.position then return end
    st.prompted_for = sc.position
    local text = is_conflict
        and T(_("Amazon has a newer position for this book, at %1, and you have also read here since the last sync.\n\nJump to Amazon's position? (Your position here will be sent instead if you decline.)"), self:describeRemote(sc))
        or T(_("Amazon has a newer position for this book, at %1.\n\nJump there?"), self:describeRemote(sc))
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Jump"),
        cancel_text = _("Stay here"),
        ok_callback = function() self:jumpTo(sc) end,
        cancel_callback = function()
            if is_conflict and self.settings.auto_push then self:doPush(sc, false) end
        end,
    })
end

function Whispersync:jumpTo(sc)
    local pm = self:posmap()
    if not pm or not sc or not sc.position then return end
    local xp, method = pm:to_xpointer(sc.position)
    if not xp then notify(_("Could not locate that position in this book.")); return end
    self.ui:handleEvent(Event:new("GotoXPointer", xp))
    local st = self:bookState()
    -- Landing on Amazon's position means we now agree with it.
    st.last_pushed_pos = sc.position
    st.last_pushed_at = os.time()
    st.last_local_change = os.time()
    self.pending_push = false
    self:log(("jumped to Amazon's position %d (%s)"):format(sc.position, method))
    if method == "percent" then
        notify(_("Jumped to the approximate position (matched by percentage)."), 3)
    end
end

function Whispersync:pullPosition(interactive)
    NetworkMgr:runWhenOnline(guarded(function()
        local sc, err = self:fetchSidecar()
        if err then notify(T(_("Amazon could not be reached: %1"), tostring(err)), 6); return end
        if not sc or not sc.position then notify(_("Amazon has no position for this book yet."), 5); return end
        self:jumpTo(sc)
        local _ = interactive
    end, "pull"))
end

function Whispersync:pushPosition(interactive)
    NetworkMgr:runWhenOnline(guarded(function()
        local sc, err = self:fetchSidecar()
        if err then notify(T(_("Amazon could not be reached: %1"), tostring(err)), 6); return end
        self:doPush(sc, interactive, true)
    end, "push"))
end

--- Write the current position to Amazon. `sc` is a fresh sidecar (may be nil
-- when the book was never opened on a Kindle, in which case there is no guid
-- and nothing can be written).
function Whispersync:doPush(sc, interactive, force)
    local book = self:currentBook()
    local client = self:client()
    if not book or not client then return end
    local guid = (sc and sc.guid ~= "" and sc.guid) or book.guid
    if not guid or guid == "" then
        self:log("cannot push " .. Catalog.title(book) .. ": no guid yet")
        if interactive then
            notify(_("Amazon has no guid for this book yet, and it silently drops writes without one. Open the book once on a Kindle (or in the Kindle app); after that KOReader can sync it."), 10)
        end
        return
    end
    local pm = self:posmap()
    if not pm then
        if interactive then notify(_("Positions cannot be mapped for this file type.")) end
        return
    end
    local xp = self:currentXPointer()
    local off, method = pm:to_offset(xp)
    if not off then return end
    local st = self:bookState()
    if not force and st.last_pushed_pos and math.abs(off - st.last_pushed_pos) < BookSync.MIN_DELTA then
        self.pending_push = self.annotations_dirty
        if interactive then notify(_("Already in sync with Amazon."), 3) end
        return
    end
    local after, err = client:push_position(book.asin, book.content_type or "PDOC", guid, off)
    if not after then
        st.last_error = tostring(err)
        self:log("push FAILED for " .. Catalog.title(book) .. ": " .. tostring(err))
        if interactive then notify(T(_("Amazon did not accept the position: %1"), tostring(err)), 8) end
        return
    end
    st.last_pushed_pos = off
    st.last_pushed_at = os.time()
    st.last_pushed_method = method
    st.last_error = nil
    st.remote_pos = after.position
    st.remote_epoch = after.last_read_epoch
    Catalog.apply_sidecar(book, after)
    self.pending_push = self.annotations_dirty
    local pct = book.text_length and (" (" .. ("%.1f"):format(math.min(100, off / book.text_length * 100)) .. "%)") or ""
    self:log(("pushed %s: %d%s, verified, mapped by %s"):format(Catalog.title(book), off, pct, method))
    if interactive then
        notify(T(_("Position sent to Amazon and verified%1."), pct), 4)
    end
end

--- Background push after quiet reading, on close, or on suspend.
function Whispersync:pushIfNeeded(reason)
    if not self.ui or not self.ui.document then return end
    if not self.pending_push or not self:isConnected() then return end
    local book = self:currentBook()
    if not book then return end
    if not online() then
        self:log("push deferred (" .. reason .. "): offline")
        return -- onNetworkConnected retries
    end
    local sc, ferr = self:fetchSidecar()
    if ferr then return end
    local decision = self:decide(sc)
    if decision == "push" or decision == "conflict_local_newer" then
        self:doPush(sc, false)
    elseif decision == "conflict_remote_newer" and reason == "timer" then
        -- Someone read further elsewhere while we were reading here.
        -- Don't drag them back silently; ask.
        self:offerPull(sc, true, false)
    elseif decision == "none" then
        self.pending_push = self.annotations_dirty
    else
        self:log(("%s: %s on %s, nothing sent"):format(Catalog.title(book), decision, reason))
    end
    if self.annotations_dirty and self.settings.sync_annotations and sc and sc.guid ~= "" then
        self:reconcileAnnotations(sc, false)
    end
end

-------------------------------------------------------------------------------
-- status and log
-------------------------------------------------------------------------------

function Whispersync:statusText(oracle)
    local book = self:currentBook()
    local st = self:bookState()
    local lines = { Catalog.title(book), "" }
    local function add(l) lines[#lines + 1] = l end
    local lp = self:localPercent()
    add(T(_("Here: %1%2"), pct_text(lp), self.pending_push and _(" · unsent changes") or ""))
    if book.remote_pos ~= nil then
        add(T(_("Amazon, most recent: %1 at %2"), pct_text(Catalog.percent(book)), when_text(book.remote_epoch)))
        if book.furthest_pos and book.text_length and book.furthest_pos > (book.remote_pos or 0) then
            add(T(_("Amazon, furthest read: %1"), pct_text(math.min(100, book.furthest_pos / book.text_length * 100))))
        end
    else
        add(_("Amazon: no position yet"))
    end
    if st.last_pushed_at then
        add(T(_("Last sent from here: %1 at %2, verified (%3)"),
            pct_text(book.text_length and st.last_pushed_pos and math.min(100, st.last_pushed_pos / book.text_length * 100) or nil),
            when_text(st.last_pushed_at), st.last_pushed_method or "?"))
    else
        add(_("Last sent from here: never"))
    end
    if st.last_error then add(T(_("Last error: %1"), st.last_error)) end
    add("")
    add(T(_("Amazon guid: %1"), (book.guid and book.guid ~= "") and _("yes") or _("none yet (open once on a Kindle)")))
    add(T(_("Automatic: check on open %1, send %2, marks %3"),
        self.settings.auto_pull and _("on") or _("off"), self.settings.auto_push and _("on") or _("off"),
        self.settings.sync_annotations and _("on") or _("off")))
    add(T(_("Network: %1"), online() and _("online") or _("offline")))
    if oracle then
        add("")
        add(_("Amazon's own record (getAnnotations):"))
        for _, r in ipairs(oracle) do
            local p = (book.text_length and r.pos) and pct_text(math.min(100, r.pos / book.text_length * 100)) or tostring(r.pos)
            add(T(_("  %1 by “%2” %3"), p, r.source_device, r.time or ""))
        end
        if #oracle == 0 then add(_("  nothing recorded")) end
    end
    add("")
    add(_("A Kindle prompts “sync to furthest page read” only when the furthest position moves; KOReader writes “most recent read”, and Amazon raises furthest-read itself when you read past it."))
    return table.concat(lines, "\n")
end

function Whispersync:showStatus(oracle)
    local book = self:currentBook()
    if not book then notify(_("This book is not from your Kindle library.")); return end
    local viewer
    viewer = TextViewer:new{
        title = _("Kindle sync status"),
        text = self:statusText(oracle),
        buttons_table = {
            {
                { text = _("Send now"), callback = function() UIManager:close(viewer); self:pushPosition(true) end },
                { text = _("Jump to Amazon's"), callback = function() UIManager:close(viewer); self:pullPosition(true) end },
            },
            {
                { text = _("Who wrote it?"), callback = function()
                    UIManager:close(viewer)
                    NetworkMgr:runWhenOnline(guarded(function()
                        local client = self:client()
                        local sc = self:fetchSidecar()
                        local guid = (sc and sc.guid ~= "" and sc.guid) or book.guid
                        local rows, err = client and client:last_read(book.asin, book.content_type or "PDOC", guid)
                        if not rows then notify(T(_("Could not ask Amazon: %1"), tostring(err)), 6); rows = {} end
                        self:showStatus(rows)
                    end, "oracle"))
                end },
                { text = _("Sync log"), callback = function() UIManager:close(viewer); self:showLog() end },
                { text = _("Close"), callback = function() UIManager:close(viewer) end },
            },
        },
    }
    UIManager:show(viewer)
end

function Whispersync:showLog()
    local lines = {}
    for i = #self.synclog, 1, -1 do lines[#lines + 1] = self.synclog[i] end
    local viewer
    viewer = TextViewer:new{
        title = _("Kindle sync log"),
        text = #lines > 0 and table.concat(lines, "\n") or _("Nothing yet."),
        monospace_font = true,
        text_font_size = 14,
        buttons_table = { {
            { text = _("Clear"), callback = function() self.synclog = {}; self:saveSettings(); UIManager:close(viewer) end },
            { text = _("Close"), callback = function() UIManager:close(viewer) end },
        } },
    }
    UIManager:show(viewer)
end

-------------------------------------------------------------------------------
-- sync: bookmarks, highlights, notes
-------------------------------------------------------------------------------

local function item_key(item)
    return (item.datetime or "?") .. "|" .. tostring(item.pos0 or item.page)
end

--- KOReader annotations converted to Kindle offsets.
function Whispersync:localItems(pm)
    local out = {}
    local ann = self.ui.annotation and self.ui.annotation.annotations or {}
    for _, item in ipairs(ann) do
        local key = item_key(item)
        if item.drawer then
            local s, e = pm:xpointers_to_range(item.pos0, item.pos1, item.text)
            if s then
                out[#out + 1] = { key = key, kind = "highlight", start = s, ["end"] = e or s, text = item.text,
                                  note = item.note, item = item }
            end
        else
            local s = pm:to_offset(item.page)
            if s then out[#out + 1] = { key = key, kind = "bookmark", start = s, ["end"] = s, item = item } end
        end
    end
    return out
end

function Whispersync:syncAnnotations(interactive)
    NetworkMgr:runWhenOnline(guarded(function()
        local sc, err = self:fetchSidecar()
        if err then notify(T(_("Amazon could not be reached: %1"), tostring(err)), 6); return end
        if not sc or sc.guid == "" then
            notify(_("Amazon has no record of this book being opened yet. Open it once on a Kindle first."), 8)
            return
        end
        self:reconcileAnnotations(sc, interactive)
    end, "annotations"))
end

function Whispersync:reconcileAnnotations(sc, interactive)
    local book = self:currentBook()
    local client = self:client()
    local pm = self:posmap()
    if not book or not client or not pm or not sc then return end
    local st = self:bookState()
    local locals = self:localItems(pm)
    local plan = BookSync.plan(sc.annotations, locals, st.links)
    local imported, pushed, deleted, removed = 0, 0, 0, 0

    -- Pair what already sits at the same place on both sides.
    for _, p in ipairs(plan.pair) do
        st.links[p["local"].key] = {
            id = p.remote.annotation_id, kind = p["local"].kind,
            start = p.remote.start, ["end"] = p.remote["end"] or p.remote.start,
            text = p["local"].text, note = p.note and p.note.text or nil,
            note_id = p.note and p.note.annotation_id or nil,
        }
    end

    -- Import Amazon's records we have never seen.
    for _, imp in ipairs(plan.imports) do
        local key = self:importAnnotation(imp.remote, imp.note, pm)
        if key then
            local link = {
                id = imp.remote.annotation_id, kind = imp.remote.kind,
                start = imp.remote.start, ["end"] = imp.remote["end"] or imp.remote.start,
                note = (imp.note and imp.note.text) or nil,
                note_id = imp.note and imp.note.annotation_id or nil,
            }
            if imp.remote.kind == "note" then
                -- A standalone Kindle note is tracked by its note id.
                link.id, link.kind, link.note_id, link.note = nil, nil, imp.remote.annotation_id, imp.remote.text
            end
            st.links[key] = link
            imported = imported + 1
        end
    end

    -- Remote deletions.
    for _, key in ipairs(plan.remote_gone) do
        local link = st.links[key]
        if link then
            if self.settings.mirror_remote_deletions then
                local item = self:findLocalItem(locals, key)
                if item then
                    pcall(function() self.ui.bookmark:removeItem(item) end)
                    removed = removed + 1
                end
                st.links[key] = nil
            else
                link.remote_gone = true
            end
        end
    end

    -- Local deletions -> delete upstream. Deletes are not read-after-write
    -- consistent, so the 200 is trusted; a delete that didn't take would
    -- simply re-import on the next sync.
    local del_items = {}
    for _, d in ipairs(plan.delete_remote) do
        for _, it in ipairs(BookSync.delete_items(d.link)) do del_items[#del_items + 1] = it end
    end
    if #del_items > 0 then
        local after, err = client:push_annotations(book.asin, book.content_type or "PDOC", sc.guid, del_items)
        if after then
            for _, d in ipairs(plan.delete_remote) do st.links[d.key] = nil end
            deleted = #plan.delete_remote
        else
            self:log("annotation delete failed: " .. tostring(err))
        end
    end

    -- Local creations -> push, then pair by (kind, position).
    if #plan.pushes > 0 then
        local items = BookSync.create_items(plan.pushes)
        local after, err = client:push_annotations(book.asin, book.content_type or "PDOC", sc.guid, items)
        if after then
            local links, orphans = BookSync.pair_after_push(plan.pushes, after.annotations, st.links)
            for k, v in pairs(links) do st.links[k] = v; pushed = pushed + 1 end
            for _, o in ipairs(orphans) do
                -- Sent but not found on read-back: mark so it is not resent
                -- forever; the next full sync will pair it if it shows up.
                st.links[o.key] = { pending = true, kind = o.kind, start = o.start, ["end"] = o["end"], text = o.text, note = o.note }
                self:log(("annotation sent but not matched on read-back: %s at %d"):format(o.kind, o.start))
            end
        else
            self:log("annotation push failed: " .. tostring(err))
            if interactive then notify(T(_("Amazon did not accept the annotations: %1"), tostring(err)), 8) end
        end
    end
    -- Retry pairing for records marked pending on an earlier pass.
    for _, link in pairs(st.links) do
        if link.pending then
            local r = BookSync.match_remote(sc.annotations, link.kind, link.start)
            if r then link.pending = nil; link.id = r.annotation_id end
        end
    end

    self.annotations_dirty = false
    self.ui.doc_settings:saveSetting("whispersync", st)
    if imported > 0 or pushed > 0 or deleted > 0 or removed > 0 then
        self:log(("marks for %s: %d imported, %d sent, %d deleted upstream, %d removed"):format(
            Catalog.title(book), imported, pushed, deleted, removed))
    end
    if imported > 0 or removed > 0 then
        UIManager:setDirty(self.view and self.view.dialog or "all", "ui")
        pcall(function() self.ui.bookmark:setDogearVisibility(self.ui.bookmark:getCurrentPageNumber()) end)
    end
    if interactive then
        notify(T(_("Annotations: %1 imported, %2 sent, %3 deleted upstream, %4 removed locally."), imported, pushed, deleted, removed), 5)
    elseif imported > 0 then
        notify(T(_("Imported %1 mark(s) from your Kindle."), imported), 3)
    end
end

function Whispersync:findLocalItem(locals, key)
    for _, l in ipairs(locals) do if l.key == key then return l.item end end
    return nil
end

--- Create a KOReader annotation from an Amazon record. Returns its key.
function Whispersync:importAnnotation(r, note, pm)
    local item
    if r.kind == "bookmark" then
        local xp = pm:to_xpointer(r.start)
        if not xp then return nil end
        -- Don't stack a second dogear on a page that already has one.
        local ok, already = pcall(function() return self.ui.bookmark:isPageBookmarked(xp) end)
        if ok and already then
            for _, it in ipairs(self.ui.annotation.annotations) do
                if not it.drawer and it.page == xp then return item_key(it) end
            end
            return nil
        end
        local chapter = self.ui.toc and self.ui.toc:getTocTitleByPage(xp) or nil
        if chapter == "" then chapter = nil end
        item = { page = xp, chapter = chapter, text = chapter and T(_("in %1"), chapter) or nil }
    else
        local start, fin = r.start, r["end"]
        if r.kind == "note" and (not fin or fin <= start) then fin = start + 1 end
        local p0, p1, quote = pm:range_to_xpointers(start, fin)
        if not p0 then return nil end
        p1 = p1 or p0
        local drawer = (self.view and self.view.highlight and self.view.highlight.saved_drawer) or "lighten"
        local chapter = self.ui.toc and self.ui.toc:getTocTitleByPage(p0) or nil
        if chapter == "" then chapter = nil end
        local text = quote
        if not text or text == "" then
            local ok, t = pcall(self.ui.document.getTextFromXPointers, self.ui.document, p0, p1)
            text = ok and t or ""
        end
        item = { page = p0, pos0 = p0, pos1 = p1, text = text, drawer = drawer, chapter = chapter }
        if self.view and self.view.highlight and self.view.highlight.saved_color then
            item.color = self.view.highlight.saved_color
        end
        local note_text = (note and note.text) or (r.kind == "note" and r.text) or nil
        if note_text and note_text ~= "" then item.note = note_text end
    end
    item.datetime = r.created and r.created:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d") or os.date("%Y-%m-%d %H:%M:%S")
    local ok, index = pcall(function() return self.ui.annotation:addItem(item) end)
    if not ok then
        logger.warn("whispersync: addItem failed", index)
        return nil
    end
    pcall(function()
        self.ui:handleEvent(Event:new("AnnotationsModified", { item, index_modified = index,
            nb_highlights_added = item.drawer and 1 or nil }))
    end)
    return item_key(item)
end

return Whispersync
