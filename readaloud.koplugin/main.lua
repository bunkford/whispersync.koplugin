--[[--
Read Aloud (Edge voices): a KOReader plugin that reads the open book with
Microsoft Edge's neural voices, synthesized on the device, and underlines
each word as it is spoken. On Kindle the sound goes out over Bluetooth
through Amazon's audio mixer, the same way the stock software plays
Audible.

  edge.lua       the Edge read-aloud service protocol (SSML in, audio and
                 per-word timing out)
  ws.lua         a WebSocket client on luasocket/luasec
  segment.lua    sentences and words from crengine; aligning spoken words
                 to laid-out ones
  audio.lua      playback backends (Kindle GStreamer mixersink, Amazon's
                 player, desktop players)
  player.lua     the state machine tying fetch, playback and highlight together
  highlight.lua  the word marker, painted as a view module
  bar.lua        the transport bar along the bottom of the page

Requires a crengine document (EPUB, MOBI, FB2, HTML…); PDFs have no text
positions to walk.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local audio = require("audio")
local edge = require("edge")

local ReadAloud = WidgetContainer:extend{
    name = "readaloud",
    is_doc_only = true,
}

local DEFAULTS = {
    voice = edge.DEFAULT_VOICE,
    speed = 1.0,
    highlight = "word",     -- word | sentence | off
    style = "invert",       -- invert | underline | box | lighten
    follow = true,          -- turn the page to the spoken word
    latency_adjust = 0,     -- seconds added to the backend's output latency
    format = nil,           -- the Edge output format the service last honoured
    silent = false,         -- follow the words without playing sound
}
local SPEEDS = { 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0 }
local LOG_LINES = 80

local function notify(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 4 })
end

function ReadAloud:init()
    self.settings_file = DataStorage:getSettingsDir() .. "/readaloud.lua"
    self.store = LuaSettings:open(self.settings_file)
    self.settings = self.store:readSetting("settings") or {}
    for k, v in pairs(DEFAULTS) do
        if self.settings[k] == nil then self.settings[k] = v end
    end
    self.synclog = self.store:readSetting("log") or {}
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end
end

function ReadAloud:saveSettings()
    self.store:saveSetting("settings", self.settings)
    self.store:flush()
end

function ReadAloud:log(msg)
    logger.info("readaloud:", msg)
    self.synclog = self.synclog or {}
    self.synclog[#self.synclog + 1] = os.date("%m-%d %H:%M:%S") .. "  " .. msg
    while #self.synclog > LOG_LINES do table.remove(self.synclog, 1) end
    self.store:saveSetting("log", self.synclog)
end

function ReadAloud:pluginDir()
    if self.path then return self.path end
    local src = debug.getinfo(1, "S").source or ""
    return src:match("^@(.*)/[^/]*$") or "."
end

function ReadAloud:onDispatcherRegisterActions()
    Dispatcher:registerAction("readaloud_toggle", {
        category = "none", event = "ReadAloudToggle", title = _("Read aloud: start / pause"), reader = true,
    })
    Dispatcher:registerAction("readaloud_stop", {
        category = "none", event = "ReadAloudStop", title = _("Read aloud: stop"), reader = true,
    })
end

-------------------------------------------------------------------------------
-- lifecycle
-------------------------------------------------------------------------------

function ReadAloud:supported()
    local ui = self.ui
    if not (ui and ui.document and ui.rolling) then return false end
    local info = ui.document.info
    return not (info and info.has_pages)
end

--- The audio plan for this device, detected once per session.
function ReadAloud:plan()
    if self.settings.silent then
        self._plan = nil
        return audio.silent_plan()
    end
    if not self._plan then
        self._plan = audio.detect(Device:isKindle(), self:pluginDir())
        self._plan.latency = (self._plan.latency or 0) + (tonumber(self.settings.latency_adjust) or 0)
        self:log(("audio: %s (%s)"):format(self._plan.backend, table.concat(self._plan.formats or {}, ", ")))
    end
    return self._plan
end

function ReadAloud:ensureParts()
    if self.player then return end
    local Highlight = require("highlight")
    local Bar = require("bar")
    local Player = require("player")
    self.highlight = Highlight.new(self.ui, {
        style = function() return self.settings.style end,
        follow = function() return self.settings.follow end,
        reserved_bottom = function() return self.bar and self.bar.visible and self.bar.height or 0 end,
    })
    self.bar = Bar.new(self.ui, {
        on_prev = function() self.player:skip(-1) end,
        on_next = function() self.player:skip(1) end,
        on_toggle = function() self:toggle() end,
        on_close = function() self:stop() end,
        playing = function() return self.player.state == "playing" or self.player.state == "preparing" end,
        status = function() return self.player:status_text() end,
    })
    local okf, ffiutil = pcall(require, "ffi/util")
    self.player = Player.new{
        ui = self.ui,
        settings = function() return self.settings end,
        plan = self:plan(),
        tmpdir = DataStorage:getDataDir() .. "/cache",
        highlight = self.highlight,
        bar = self.bar,
        log = function(m) self:log(m) end,
        notify = function(m) notify(m, 5) end,
        on_state = function(s) if self.bar then self.bar:refresh() end if s == "idle" and self.bar then self.bar:hide() end end,
        ffiutil = okf and ffiutil.runInSubProcess and ffiutil or nil,
        uimanager = UIManager,
        json_decode = edge.json_decode,
        on_format = function(fmt) self.settings.format = fmt; self:saveSettings(); self:log("service format: " .. tostring(fmt)) end,
    }
    -- Make sure the cache dir exists for the temp files.
    pcall(require("util").makePath, DataStorage:getDataDir() .. "/cache")
end

function ReadAloud:start()
    if not self:supported() then
        notify(_("Read aloud works with EPUB, MOBI and other reflowable books, not PDFs."))
        return
    end
    local plan = self:plan()
    if plan.backend == "none" then
        notify(T(_("No way to play sound was found: %1"), tostring(plan.reason)), 8)
        return
    end
    NetworkMgr:runWhenOnline(function()
        self:ensureParts()
        local xp = self.ui.document:getXPointer()
        local ok, err = self.player:start(xp)
        if not ok then notify(tostring(err)); return end
        self.bar:show()
        self:log("started at " .. tostring(xp))
    end)
end

function ReadAloud:stop()
    if self.player then self.player:stop() end
    if self.bar then self.bar:hide() end
end

function ReadAloud:toggle()
    if not self.player or self.player.state == "idle" then
        self:start()
    else
        self.player:toggle()
    end
end

function ReadAloud:onReadAloudToggle() self:toggle(); return true end
function ReadAloud:onReadAloudStop() self:stop(); return true end
function ReadAloud:onCloseDocument() self:stop() end
function ReadAloud:onSuspend() if self.player and self.player.state == "playing" then self.player:pause() end end
function ReadAloud:onCloseWidget() self:stop() end

-------------------------------------------------------------------------------
-- diagnostics
-------------------------------------------------------------------------------

function ReadAloud:testSound()
    local plan = self:plan()
    if plan.backend == "none" then notify(tostring(plan.reason), 6); return end
    local dir = DataStorage:getDataDir() .. "/cache"
    pcall(require("util").makePath, dir)
    local path = dir .. "/readaloud-tone.pcm"
    local f = io.open(path, "wb")
    if not f then notify(_("Cannot write to the cache directory.")); return end
    f:write(audio.test_tone_pcm(1.0)); f:close()
    local fmt = edge.FORMATS.pcm
    if plan.backend == "kindle-lipc" then
        notify(_("Amazon's player cannot play a raw tone; try 'Test the voice' instead."), 5)
        return
    end
    local h, err = audio.start(plan, path, fmt, 0, dir)
    if not h then notify(T(_("Could not play: %1"), tostring(err)), 6); return end
    notify(T(_("Playing a one-second tone through %1. Hear it?"), plan.backend), 4)
    UIManager:scheduleIn(4, function() audio.stop(h); os.remove(path) end)
end

function ReadAloud:testVoice()
    NetworkMgr:runWhenOnline(function()
        local plan = self:plan()
        local info = InfoMessage:new{ text = _("Asking the Edge voice service, one format at a time…") }
        UIManager:show(info)
        UIManager:scheduleIn(0.1, function()
            local formats = {}
            if self.settings.format then formats[1] = self.settings.format end
            for _i, f in ipairs(plan.formats or { edge.FORMATS.mp3 }) do
                if f ~= self.settings.format then formats[#formats + 1] = f end
            end
            local lines, result = {}, nil
            local sample = "Hello. This is " .. ((self.settings.voice or ""):match("%-(%a+)Neural$") or "the reader") .. ", reading aloud on your Kindle."
            for _i, f in ipairs(formats) do
                local t0 = os.time()
                local r, err = edge.synthesize(sample, { voice = self.settings.voice, speed = self.settings.speed, format = f, timeout = 30, first_timeout = 10 })
                local took = os.time() - t0
                if r then
                    lines[#lines + 1] = T(_("%1: OK, %2 s of audio, %3 timed words (%4 s)"), f, ("%.1f"):format(r.duration), #r.words, took)
                    self:log(("voice test %s: ok, %d bytes, %d words, %ds"):format(f, #r.audio, #r.words, took))
                    if not result then result = r end
                    if not edge.is_refusal(err) then break end
                else
                    lines[#lines + 1] = T(_("%1: %2 (%3 s)"), f, tostring(err), took)
                    self:log(("voice test %s: %s (%ds)"):format(f, tostring(err), took))
                    if not edge.is_refusal(err) then break end -- network trouble: no point trying other formats
                end
            end
            UIManager:close(info)
            if not result then
                UIManager:show(InfoMessage:new{ text = _("The voice service did not answer.") .. "\n\n" .. table.concat(lines, "\n") })
                return
            end
            if self.settings.format ~= result.format then
                self.settings.format = result.format
                self:saveSettings()
            end
            local dir = DataStorage:getDataDir() .. "/cache"
            pcall(require("util").makePath, dir)
            local path = dir .. "/readaloud-test.audio"
            local f = io.open(path, "wb"); f:write(result.audio); f:close()
            local h, perr = audio.start(plan, path, result.format, 0, dir)
            if not h then
                UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") .. "\n\n" .. T(_("Could not play the %1 audio: %2"), result.format, tostring(perr)) })
                self:log("voice test playback failed: " .. tostring(perr))
                return
            end
            UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") .. "\n\n" .. T(_("Playing the %1 audio through %2 now."), result.format, tostring(h.player or plan.backend)), timeout = 8 })
            UIManager:scheduleIn(result.duration + 3, function() audio.stop(h); os.remove(path) end)
        end)
    end)
end

function ReadAloud:audioInfo()
    local plan = self:plan()
    local lines = {
        T(_("Device: %1"), Device.model or "?"),
        T(_("Backend: %1"), plan.backend),
        plan.gst and T(_("GStreamer: %1"), plan.gst) or nil,
        plan.ffmpeg and T(_("ffmpeg: %1"), plan.ffmpeg) or nil,
        T(_("Formats to try, in order: %1"), table.concat(plan.formats or {}, ", ")),
        self.settings.format and T(_("Format the service last honoured: %1"), self.settings.format) or nil,
        T(_("Output latency: %1 s"), ("%.2f"):format(plan.latency or 0)),
        plan.reason and T(_("Note: %1"), plan.reason) or nil,
        "",
        Device:isKindle() and _("Pair the headphones or speaker in the Kindle's own Settings → Bluetooth before playing; KOReader cannot pair.") or "",
    }
    local text = {}
    for _i, l in ipairs(lines) do if l then text[#text + 1] = l end end
    UIManager:show(InfoMessage:new{ text = table.concat(text, "\n") })
end

function ReadAloud:showLog()
    local TextViewer = require("ui/widget/textviewer")
    local lines = {}
    for i = #self.synclog, 1, -1 do lines[#lines + 1] = self.synclog[i] end
    UIManager:show(TextViewer:new{ title = _("Read aloud log"), text = #lines > 0 and table.concat(lines, "\n") or _("Nothing yet.") })
end

-------------------------------------------------------------------------------
-- menu
-------------------------------------------------------------------------------

function ReadAloud:voiceMenu()
    local items = {}
    for _i, v in ipairs(edge.VOICES) do
        items[#items + 1] = {
            text = v[2],
            checked_func = function() return self.settings.voice == v[1] end,
            callback = function() self.settings.voice = v[1]; self:saveSettings() end,
            radio = true,
        }
    end
    items[#items + 1] = {
        text_func = function()
            local known = false
            for _i, v in ipairs(edge.VOICES) do if v[1] == self.settings.voice then known = true end end
            return known and _("Other voice…") or T(_("Other voice: %1"), self.settings.voice)
        end,
        separator = true,
        callback = function()
            local InputDialog = require("ui/widget/inputdialog")
            local dialog
            dialog = InputDialog:new{
                title = _("Voice short name"),
                input = self.settings.voice,
                input_hint = "en-US-AndrewNeural",
                description = _("Any Edge read-aloud voice, e.g. fr-FR-HenriNeural or de-DE-KatjaNeural."),
                buttons = { {
                    { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                    { text = _("Use"), is_enter_default = true, callback = function()
                        local v = dialog:getInputText():gsub("%s", "")
                        if v ~= "" then self.settings.voice = v; self:saveSettings() end
                        UIManager:close(dialog)
                    end },
                } },
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end,
    }
    items[#items + 1] = { text = _("Test the voice"), callback = function() self:testVoice() end }
    return items
end

function ReadAloud:speedMenu()
    local items = {}
    for _i, s in ipairs(SPEEDS) do
        items[#items + 1] = {
            text = s == 1.0 and _("Normal") or ("%.2g×"):format(s),
            checked_func = function() return math.abs((self.settings.speed or 1) - s) < 0.01 end,
            callback = function() self.settings.speed = s; self:saveSettings() end,
            radio = true,
        }
    end
    return items
end

function ReadAloud:highlightMenu()
    local function mode(text, value)
        return { text = text, radio = true, checked_func = function() return self.settings.highlight == value end,
                 callback = function() self.settings.highlight = value; self:saveSettings() end }
    end
    local function style(text, value)
        return { text = text, radio = true, checked_func = function() return self.settings.style == value end,
                 callback = function() self.settings.style = value; self:saveSettings() end }
    end
    return {
        mode(_("Underline the spoken word"), "word"),
        mode(_("Mark the spoken sentence"), "sentence"),
        mode(_("No marker"), "off"),
        { text = _("Marker style"), separator = true, sub_item_table = {
            style(_("Invert (clearest on e-ink)"), "invert"),
            style(_("Underline"), "underline"),
            style(_("Box"), "box"),
            style(_("Grey background"), "lighten"),
        } },
        {
            text = _("Turn the page to follow the voice"),
            checked_func = function() return self.settings.follow end,
            callback = function() self.settings.follow = not self.settings.follow; self:saveSettings() end,
        },
    }
end

function ReadAloud:audioMenu()
    local function adjust(delta)
        self.settings.latency_adjust = math.max(-2, math.min(3, (tonumber(self.settings.latency_adjust) or 0) + delta))
        self:saveSettings()
        self._plan = nil
        if self.player then self.player.opts.plan = self:plan() end
    end
    return {
        {
            text = _("Follow the words without sound"),
            help_text = _("Runs the reading at the voice's pace and marks each word, but plays nothing: read-along mode, or for when no speaker is connected. The voice is still fetched, for its word timing."),
            checked_func = function() return self.settings.silent == true end,
            callback = function()
                self.settings.silent = not self.settings.silent
                self:saveSettings()
                if self.player then self.player.opts.plan = self:plan(); self.player.format_index = 1 end
            end,
            separator = true,
        },
        { text = _("Play a test tone"), enabled_func = function() return not self.settings.silent end, callback = function() self:testSound() end },
        { text = _("Audio output details"), callback = function() self:audioInfo() end },
        {
            text_func = function()
                local v = tonumber(self.settings.latency_adjust) or 0
                return T(_("Marker timing offset: %1 s"), (v >= 0 and "+" or "") .. ("%.2f"):format(v))
            end,
            help_text = _("If the marker runs ahead of the voice, add time; if it lags, subtract. Bluetooth adds a second or so on Kindle."),
            sub_item_table = {
                { text = _("+0.25 s (marker later)"), keep_menu_open = true, callback = function() adjust(0.25) end },
                { text = _("−0.25 s (marker earlier)"), keep_menu_open = true, callback = function() adjust(-0.25) end },
                { text = _("Reset"), keep_menu_open = true, callback = function() self.settings.latency_adjust = 0; self:saveSettings(); self._plan = nil end },
            },
        },
        {
            text = _("Forget which audio format worked"),
            enabled_func = function() return self.settings.format ~= nil end,
            callback = function() self.settings.format = nil; self:saveSettings(); if self.player then self.player.format_index = 1 end end,
        },
        { text = _("Log"), callback = function() self:showLog() end },
    }
end

function ReadAloud:addToMainMenu(menu_items)
    menu_items.readaloud = {
        text = _("Read aloud"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    if self.player and self.player.state == "playing" then return _("Pause") end
                    if self.player and self.player.state == "paused" then return _("Resume") end
                    return _("Start reading from this page")
                end,
                enabled_func = function() return self:supported() end,
                callback = function() self:toggle() end,
            },
            {
                text = _("Stop"),
                enabled_func = function() return self.player ~= nil and self.player.state ~= "idle" end,
                callback = function() self:stop() end,
                separator = true,
            },
            { text_func = function() return T(_("Voice: %1"), (self.settings.voice or ""):gsub("Neural$", "")) end, sub_item_table = self:voiceMenu() },
            { text_func = function() return T(_("Speed: %1"), self.settings.speed == 1 and _("normal") or ("%.2g×"):format(self.settings.speed)) end, sub_item_table = self:speedMenu() },
            { text = _("Word marker"), sub_item_table = self:highlightMenu() },
            { text = _("Audio"), sub_item_table = self:audioMenu(), separator = true },
            {
                text = _("Help"),
                callback = function()
                    local TextViewer = require("ui/widget/textviewer")
                    UIManager:show(TextViewer:new{ title = _("Read aloud"), text = _([[
Reads the open book with Microsoft Edge's neural voices. The voice is synthesized on this device over Wi-Fi, a sentence group at a time, and every spoken word is marked on the page as it is said; the page turns to follow.

Start it from this menu or the "Read aloud: start / pause" gesture action. The bar along the bottom has previous/next sentence group, pause and stop. Tapping elsewhere still turns pages as usual.

On Kindle, pair headphones or a speaker in the Kindle's own Settings → Bluetooth first; sound goes out through the same mixer Audible uses. If the marker runs ahead of or behind the voice, adjust Audio → Marker timing offset.

Edge's voices are a free, unofficial service: it needs internet and Microsoft may change it.]]) })
                end,
            },
        },
    }
end

return ReadAloud
