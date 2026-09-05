--[[--
The control bar: previous / play-pause / next / close, and a status line,
along the bottom of the page.

It is a view module (painted by ReaderView after the page) plus a touch zone
that overrides page-turn taps in that strip while the bar is up, the way
KOReader's own footer does it. That keeps the rest of the page fully
interactive: taps and swipes elsewhere still turn pages, open menus and so on.
]]

local Bar = {}
Bar.__index = Bar

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Screen = Device.screen
local _ = require("gettext")

Bar.ZONE_ID = "readaloud_bar_tap"

--- opts: on_prev, on_toggle, on_next, on_close (functions); playing() -> bool; status() -> text
function Bar.new(ui, opts)
    local self = setmetatable({ ui = ui, opts = opts or {}, visible = false }, Bar)
    self.height = Screen:scaleBySize(56)
    if ui and ui.view and ui.view.registerViewModule then
        ui.view:registerViewModule("readaloud_bar", {
            paintTo = function(_, bb, x, y) self:paint(bb, x, y) end,
        })
    end
    return self
end

function Bar:region()
    return Geom:new{ x = 0, y = Screen:getHeight() - self.height, w = Screen:getWidth(), h = self.height }
end

function Bar:build()
    local size = self.height - Screen:scaleBySize(12)
    local function btn(o)
        o.bordersize = 0
        o.padding = 0
        o.margin = 0
        o.height = size
        o.width = o.width or size
        o.text_font_size = 18
        o.icon_width = math.floor(size * 0.6)
        o.icon_height = math.floor(size * 0.6)
        return Button:new(o)
    end
    self.buttons = {
        prev = btn{ icon = "chevron.left", callback = self.opts.on_prev },
        toggle = btn{ text = _("Play"), width = Screen:scaleBySize(96), callback = self.opts.on_toggle },
        next = btn{ icon = "chevron.right", callback = self.opts.on_next },
        close = btn{ icon = "close", callback = self.opts.on_close },
    }
end

function Bar:show()
    if self.visible then return end
    if not self.buttons then self:build() end
    self.visible = true
    local r = self:region()
    if self.ui and self.ui.registerTouchZones then
        self.ui:registerTouchZones({
            {
                id = Bar.ZONE_ID,
                ges = "tap",
                screen_zone = { ratio_x = 0, ratio_y = r.y / Screen:getHeight(), ratio_w = 1, ratio_h = r.h / Screen:getHeight() },
                overrides = { "readerfooter_tap", "readerconfigmenu_ext_tap", "readerconfigmenu_tap", "tap_forward", "tap_backward", "tap_link" },
                handler = function(ges) return self:onTap(ges) end,
            },
        })
    end
    UIManager:setDirty(self.ui.dialog or self.ui, "ui", r)
end

function Bar:hide()
    if not self.visible then return end
    self.visible = false
    if self.ui and self.ui.unRegisterTouchZones then
        pcall(self.ui.unRegisterTouchZones, self.ui, { { id = Bar.ZONE_ID } })
    end
    UIManager:setDirty(self.ui.dialog or self.ui, "ui", self:region())
end

--- Repaint the bar (status text or play state changed).
function Bar:refresh()
    if self.visible then UIManager:setDirty(self.ui.dialog or self.ui, "ui", self:region()) end
end

function Bar:onTap(ges)
    if not self.visible or not ges or not ges.pos then return false end
    for _, b in pairs(self.buttons or {}) do
        if b.dimen and ges.pos:intersectWith(b.dimen) and b.callback then
            b.callback()
            return true
        end
    end
    return true -- taps on the bar never turn the page
end

function Bar:paint(bb, _x, _y)
    if not self.visible or not bb then return end
    if not self.buttons then self:build() end
    local r = self:region()
    bb:paintRect(r.x, r.y, r.w, r.h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(r.x, r.y, r.w, Screen:scaleBySize(1), Blitbuffer.COLOR_BLACK)
    local pad = Screen:scaleBySize(6)
    local y = r.y + pad
    local x = r.x + pad
    local playing = self.opts.playing and self.opts.playing()
    local toggle = self.buttons.toggle
    if toggle.setText then
        local want = playing and _("Pause") or _("Play")
        if toggle._readaloud_label ~= want then
            toggle:setText(want, toggle.width)
            toggle._readaloud_label = want
        end
    end
    for _, name in ipairs({ "prev", "toggle", "next" }) do
        local b = self.buttons[name]
        b:paintTo(bb, x, y)
        x = x + (b.dimen and b.dimen.w or b.width or 0) + pad
    end
    local close = self.buttons.close
    local cx = r.x + r.w - pad - (close.width or self.height)
    close:paintTo(bb, cx, y)
    -- status text between the transport buttons and close
    local text = self.opts.status and self.opts.status() or ""
    if text ~= "" then
        local max_w = cx - x - pad
        if max_w > Screen:scaleBySize(40) then
            local tw = TextWidget:new{ text = text, face = Font:getFace("smallinfofont"), max_width = max_w, truncate_with_ellipsis = true }
            local ts = tw:getSize()
            tw:paintTo(bb, x, r.y + math.floor((r.h - ts.h) / 2))
            tw:free()
        end
    end
end

return Bar
