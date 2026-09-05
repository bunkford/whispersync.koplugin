--[[--
The word (or sentence) being spoken, drawn on the page.

A ReaderView "view module" paints after the page content, so the marker
rides every repaint; each change refreshes only the strip of screen it
touched, which on e-ink is the difference between a flicker and a flash.
When the spoken word is not on the visible page, the page is turned to it
(ReaderRolling's own xpointer navigation), at most once a second.
]]

local Highlight = {}
Highlight.__index = Highlight

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Screen = Device.screen

Highlight.STYLES = { "invert", "underline", "box", "lighten" }

--- opts.style() -> style name; opts.follow() -> bool; opts.reserved_bottom() -> px the bar covers.
function Highlight.new(ui, opts)
    local self = setmetatable({ ui = ui, opts = opts or {}, boxes = nil, last_follow = 0 }, Highlight)
    if ui and ui.view and ui.view.registerViewModule then
        ui.view:registerViewModule("readaloud_highlight", {
            paintTo = function(_, bb, x, y) self:paint(bb, x, y) end,
        })
    end
    return self
end

local function union(a, b)
    local min_x, min_y, max_x, max_y
    for _, list in ipairs({ a, b }) do
        for _, r in ipairs(list or {}) do
            local x2, y2 = r.x + r.w, r.y + r.h
            if not min_x or r.x < min_x then min_x = r.x end
            if not min_y or r.y < min_y then min_y = r.y end
            if not max_x or x2 > max_x then max_x = x2 end
            if not max_y or y2 > max_y then max_y = y2 end
        end
    end
    if not min_x then return nil end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    min_x, min_y = math.max(0, min_x - 2), math.max(0, min_y - 2)
    max_x, max_y = math.min(sw, max_x + 2), math.min(sh, max_y + 2)
    if max_x <= min_x or max_y <= min_y then return nil end
    return Geom:new{ x = min_x, y = min_y, w = max_x - min_x, h = max_y - min_y }
end

--- Boxes on the visible page for a range, or an empty list.
function Highlight:boxes_for(xp0, xp1)
    local doc = self.ui.document
    local ok, boxes = pcall(doc.getScreenBoxesFromPositions, doc, xp0, xp1, true)
    if not ok or type(boxes) ~= "table" then return {} end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local bottom = sh - (self.opts.reserved_bottom and self.opts.reserved_bottom() or 0)
    local out = {}
    for _, b in ipairs(boxes) do
        if b.w > 0 and b.h > 0 and b.x + b.w > 0 and b.x < sw and b.y + b.h > 0 and b.y < bottom then
            out[#out + 1] = { x = b.x, y = b.y, w = b.w, h = b.h }
        end
    end
    return out
end

--- Mark the range. Returns "shown", "followed" (page turned, boxes next time)
-- or "offscreen".
function Highlight:show(xp0, xp1)
    if not xp0 then return "offscreen" end
    local boxes = self:boxes_for(xp0, xp1 or xp0)
    if #boxes == 0 then
        local doc = self.ui.document
        local okp, inpage = pcall(doc.isXPointerInCurrentPage, doc, xp0)
        if not (okp and inpage) then
            if self.opts.follow and self.opts.follow() then
                local now = os.time()
                if now - self.last_follow >= 1 and self.ui.rolling and self.ui.rolling.onGotoXPointer then
                    self.last_follow = now
                    self:clear()
                    pcall(self.ui.rolling.onGotoXPointer, self.ui.rolling, xp0)
                    return "followed"
                end
            end
            return "offscreen"
        end
        -- On the page but no boxes (a word inside an image caption, say): nothing to draw.
        return "offscreen"
    end
    local region = union(self.boxes, boxes)
    self.boxes = boxes
    if region then UIManager:setDirty(self.ui.dialog or self.ui, "ui", region) end
    return "shown"
end

function Highlight:clear()
    if self.boxes then
        local region = union(self.boxes, nil)
        self.boxes = nil
        if region then UIManager:setDirty(self.ui.dialog or self.ui, "ui", region) end
    end
end

function Highlight:paint(bb, _x, _y)
    local boxes = self.boxes
    if not boxes or #boxes == 0 or not bb then return end
    local style = self.opts.style and self.opts.style() or "invert"
    local line = Screen:scaleBySize(2)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    for _, b in ipairs(boxes) do
        local x, y = math.max(0, b.x), math.max(0, b.y)
        local w, h = math.min(b.w - (x - b.x), sw - x), math.min(b.h - (y - b.y), sh - y)
        if w > 0 and h > 0 then
            if style == "underline" then
                bb:paintRect(x, y + h - line, w, line, Blitbuffer.COLOR_BLACK)
            elseif style == "box" then
                bb:paintRect(x, y, w, line, Blitbuffer.COLOR_BLACK)
                bb:paintRect(x, y + h - line, w, line, Blitbuffer.COLOR_BLACK)
                bb:paintRect(x, y, line, h, Blitbuffer.COLOR_BLACK)
                bb:paintRect(x + w - line, y, line, h, Blitbuffer.COLOR_BLACK)
            elseif style == "lighten" then
                pcall(bb.darkenRect, bb, x, y, w, h, 0.2)
            else
                pcall(bb.invertRect, bb, x, y, w, h)
            end
        end
    end
end

return Highlight
