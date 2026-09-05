-- Just enough of KOReader to load main.lua on a desktop. Each test can
-- override entries in the returned table before requiring "main".
local TMP = os.getenv("TMPDIR") or "/tmp"
-- Stub the KOReader modules main.lua requires, just enough to load it.
local stubs = {
    ["docsettings"] = { getSidecarDir = function(_, path) return path .. ".sdr" end },
    ["datastorage"] = { getSettingsDir = function() return TMP end, getFullDataDir = function() return "/tmp" end },
    ["dispatcher"] = { registerAction = function() end },
    ["ui/event"] = { new = function(_, ...) return { ... } end },
    ["ui/widget/infomessage"] = { new = function(_, o) return o end },
    ["ui/widget/confirmbox"] = { new = function(_, o) return o end },
    ["ui/widget/inputdialog"] = { new = function(_, o) return o end },
    ["luasettings"] = { open = function() return { readSetting = function() return nil end, saveSetting = function() end, flush = function() end } end },
    ["ui/widget/menu"] = { new = function(_, o) return o end },
    ["ui/network/manager"] = { isConnected = function() return true end, runWhenOnline = function(_, cb) cb() end },
    ["ui/uimanager"] = { show = function() end, close = function() end, scheduleIn = function() end, unschedule = function() end,
                         nextTick = function(_, f) f() end, tickAfterNext = function(_, f) f() end, insertZMQ = function() end, removeZMQ = function() end, setDirty = function() end },
    ["ui/widget/container/widgetcontainer"] = { extend = function(_, o)
        -- Like WidgetContainer:new, run init() so ordering bugs show up here.
        o.new = function(c, i) i = i or {}; setmetatable(i, { __index = c }); if i.init then i:init() end; return i end
        return o
    end },
    ["device"] = { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end }, isKindle = function() return false end },
    ["libs/libkoreader-lfs"] = { attributes = function(path, mode)
        local f = io.open(path, "rb")
        if not f then return nil end
        f:close()
        return mode == "mode" and "file" or { mode = "file" }
    end },
    ["logger"] = { dbg = function() end, info = function() end, warn = function() end },
    ["util"] = { makePath = function(dir) os.execute("mkdir -p '" .. dir .. "'") end },
    ["gettext"] = function(s) return s end,
    ["ffi/util"] = { template = function(s, ...) local a = { ... }; return (s:gsub("%%(%d)", function(n) return tostring(a[tonumber(n)]) end)) end,
                     usleep = function() end },
    ["ui/widget/textviewer"] = { new = function(_, o) return o end },
    ["ui/trapper"] = { wrap = function(_, fn) return fn() end, info = function() return true end, clear = function() end,
                       confirm = function() return true end },
}
for k, v in pairs(stubs) do package.preload[k] = function() return v end end
return stubs
