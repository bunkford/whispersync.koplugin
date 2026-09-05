-- Just enough of KOReader to load main.lua and run the player on a desktop.
local TMP = os.getenv("TMPDIR") or "/tmp"
local Geom = {}
Geom.__index = Geom
function Geom:new(o) o = o or {}; return setmetatable(o, Geom) end
function Geom:intersectWith(r) return self.x >= r.x and self.x < r.x + r.w and self.y >= r.y and self.y < r.y + r.h end
local scheduled = {}
local stubs = {
    ["datastorage"] = { getSettingsDir = function() return TMP end, getDataDir = function() return TMP end, getFullDataDir = function() return TMP end },
    ["dispatcher"] = { registerAction = function() end },
    ["ui/event"] = { new = function(_, ...) return { ... } end },
    ["ui/widget/infomessage"] = { new = function(_, o) return o end },
    ["ui/widget/inputdialog"] = { new = function(_, o) return o end },
    ["ui/widget/textviewer"] = { new = function(_, o) return o end },
    ["luasettings"] = { open = function() local d = {}; return { readSetting = function(_, k) return d[k] end, saveSetting = function(_, k, v) d[k] = v end, flush = function() end } end },
    ["ui/network/manager"] = { isConnected = function() return true end, runWhenOnline = function(_, cb) cb() end },
    ["ui/uimanager"] = { show = function() end, close = function() end, scheduled = scheduled,
                         scheduleIn = function(_, t, fn) scheduled[#scheduled + 1] = fn end,
                         unschedule = function(_, fn) for i = #scheduled, 1, -1 do if scheduled[i] == fn then table.remove(scheduled, i) end end end,
                         setDirty = function() end },
    ["ui/widget/container/widgetcontainer"] = { extend = function(_, o)
        o.new = function(c, i) i = i or {}; setmetatable(i, { __index = c }); if i.init then i:init() end; return i end
        return o
    end },
    ["device"] = { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end, scaleBySize = function(_, n) return n end },
                   isKindle = function() return false end, model = "Test" },
    ["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end },
    ["util"] = { makePath = function(dir) os.execute("mkdir -p '" .. dir .. "'") end },
    ["gettext"] = function(s) return s end,
    ["ffi/util"] = { template = function(s, ...) local a = { ... }; return (s:gsub("%%(%d)", function(n) return tostring(a[tonumber(n)]) end)) end },
    ["ffi/blitbuffer"] = { COLOR_WHITE = "W", COLOR_BLACK = "B" },
    ["ui/geometry"] = Geom,
    ["ui/font"] = { getFace = function() return "face" end },
    ["ui/widget/textwidget"] = { new = function(_, o) return { getSize = function() return { w = 10, h = 10 } end, paintTo = function() end, free = function() end } end },
    ["ui/widget/button"] = { new = function(_, o) o.paintTo = function(self, bb, x, y) self.dimen = Geom:new{ x = x, y = y, w = self.width or 40, h = self.height or 40 } end
                                                    o.setText = function(self, t) self.text = t end; return o end },
}
for k, v in pairs(stubs) do package.preload[k] = function() return v end end
return stubs
