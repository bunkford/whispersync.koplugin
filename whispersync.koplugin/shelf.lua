--[[--
The shelf: a paged grid of covers with title, author and progress, like the
dashboard's library view, for books that live in your Amazon account rather
than on disk.

KOReader widget modules are required lazily (inside `ko()`), so the layout
maths at the top can be unit-tested on a desktop without KOReader.
]]

local Shelf = {}

-------------------------------------------------------------------------------
-- pure layout
-------------------------------------------------------------------------------

Shelf.COVER_RATIO = 1.5      -- height / width
Shelf.TARGET_CELL_UNITS = 150 -- in Screen:scaleBySize units (~1 mm at 160 dpi)

--- Grid geometry for a screen. `scale` is Screen:scaleBySize(1).
-- `title_h` and `footer_h` are the heights already taken by the bars.
function Shelf.layout(w, h, scale, title_h, footer_h)
    scale = scale or 1
    title_h = title_h or 0
    footer_h = footer_h or 0
    local padding = math.max(4, math.floor(6 * scale))
    local target = Shelf.TARGET_CELL_UNITS * scale
    local cols = math.max(2, math.min(6, math.floor(w / target)))
    local cell_w = math.floor((w - padding) / cols) - padding
    local cover_w = cell_w - 2 * padding
    local cover_h = math.floor(cover_w * Shelf.COVER_RATIO)
    local font_title = math.max(12, math.floor(14 * (scale > 1.5 and 1 or 1.1)))
    local font_small = math.max(10, font_title - 2)
    -- Three text lines plus a progress bar, in pixels.
    local text_h = math.floor((font_title + 2 * font_small) * 1.35 * scale) + 3 * padding
    local bar_h = math.max(3, math.floor(3 * scale))
    local cell_h = cover_h + bar_h + text_h + 2 * padding
    local body_h = h - title_h - footer_h - padding
    local rows = math.max(1, math.floor(body_h / (cell_h + padding)))
    return {
        cols = cols, rows = rows, per_page = cols * rows,
        cell_w = cell_w, cell_h = cell_h, cover_w = cover_w, cover_h = cover_h,
        padding = padding, bar_h = bar_h,
        font_title = font_title, font_small = font_small,
        body_h = body_h,
        left = math.floor((w - cols * (cell_w + padding) + padding) / 2),
    }
end

function Shelf.page_count(n, per_page)
    if n <= 0 then return 1 end
    return math.ceil(n / per_page)
end

function Shelf.page_slice(items, page, per_page)
    local out = {}
    local first = (page - 1) * per_page + 1
    for i = first, math.min(#items, first + per_page - 1) do out[#out + 1] = items[i] end
    return out
end

-------------------------------------------------------------------------------
-- widget
-------------------------------------------------------------------------------

local K -- lazily loaded KOReader modules
local function ko()
    if K then return K end
    K = {
        Blitbuffer = require("ffi/blitbuffer"),
        ButtonDialog = require("ui/widget/buttondialog"),
        ButtonTable = require("ui/widget/buttontable"),
        CenterContainer = require("ui/widget/container/centercontainer"),
        Device = require("device"),
        Font = require("ui/font"),
        FrameContainer = require("ui/widget/container/framecontainer"),
        Geom = require("ui/geometry"),
        GestureRange = require("ui/gesturerange"),
        HorizontalGroup = require("ui/widget/horizontalgroup"),
        HorizontalSpan = require("ui/widget/horizontalspan"),
        ImageWidget = require("ui/widget/imagewidget"),
        InputContainer = require("ui/widget/container/inputcontainer"),
        OverlapGroup = require("ui/widget/overlapgroup"),
        RenderImage = require("ui/renderimage"),
        Size = require("ui/size"),
        TextBoxWidget = require("ui/widget/textboxwidget"),
        TextWidget = require("ui/widget/textwidget"),
        TitleBar = require("ui/widget/titlebar"),
        UIManager = require("ui/uimanager"),
        VerticalGroup = require("ui/widget/verticalgroup"),
        VerticalSpan = require("ui/widget/verticalspan"),
        _ = require("gettext"),
        T = require("ffi/util").template,
    }
    local ok, ProgressWidget = pcall(require, "ui/widget/progresswidget")
    if ok then K.ProgressWidget = ProgressWidget end
    K.Screen = K.Device.screen
    return K
end

--- Create the shelf widget. Every callback in `opts` is optional except
-- `items_func` (returns the sorted, filtered list).
--   items_func()            -> list of catalog entries
--   title_func(item), author_func(item), status_func(item), percent_func(item)
--   cover_func(item)        -> image path or nil
--   on_open(item), on_hold(item)
--   menu_buttons_func(shelf)-> rows for the ⋮ menu (ButtonDialog buttons)
--   subtitle_func()         -> text under the title
--   on_close()
function Shelf.new(opts)
    local W = ko()
    local shelf = W.InputContainer:new{
        title = opts.title or W._("Kindle library"),
        opts = opts,
        page = 1,
        dimen = W.Geom:new{ x = 0, y = 0, w = W.Screen:getWidth(), h = W.Screen:getHeight() },
    }
    for k, v in pairs(Shelf.methods) do shelf[k] = v end
    shelf.ges_events = {
        ShelfSwipe = { W.GestureRange:new{ ges = "swipe", range = function() return shelf.dimen end } },
    }
    if W.Device:hasKeys() then
        shelf.key_events = { Close = { { W.Device.input.group.Back } } }
    end
    shelf:render()
    return shelf
end

Shelf.methods = {}
local S = Shelf.methods

function S:items()
    self._items = self.opts.items_func() or {}
    return self._items
end

function S:pageCount()
    return Shelf.page_count(#(self._items or {}), self.layout_info.per_page)
end

--- Rebuild the whole widget tree for the current page.
function S:render()
    local W = ko()
    local Screen = W.Screen
    local w, h = Screen:getWidth(), Screen:getHeight()
    local items = self:items()

    if self[1] then self[1]:free() end

    self.titlebar = W.TitleBar:new{
        width = w,
        fullscreen = true,
        align = "left",
        title = self.title,
        subtitle = self.opts.subtitle_func and self.opts.subtitle_func() or nil,
        title_shrink_font_to_fit = true,
        with_bottom_line = true,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function() self:showMenu() end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }
    local title_h = self.titlebar:getHeight()

    -- Footer: pager.
    local footer = self:footer(w)
    local footer_h = footer:getSize().h

    local scale = Screen:scaleBySize(1)
    self.layout_info = Shelf.layout(w, h, scale, title_h, footer_h)
    local L = self.layout_info
    local pages = self:pageCount()
    if self.page > pages then self.page = pages end
    if self.page < 1 then self.page = 1 end
    footer = self:footer(w) -- now with the right page numbers

    local body = W.VerticalGroup:new{ align = "left" }
    local page_items = Shelf.page_slice(items, self.page, L.per_page)
    if #page_items == 0 then
        body[#body + 1] = W.CenterContainer:new{
            dimen = W.Geom:new{ w = w, h = L.body_h },
            W.TextBoxWidget:new{
                text = self.opts.empty_text or W._("Nothing here yet.\nUse the menu (top left) to refresh from Amazon."),
                face = W.Font:getFace("cfont", 18),
                width = math.floor(w * 0.7),
                alignment = "center",
            },
        }
    else
        body[#body + 1] = W.VerticalSpan:new{ width = L.padding }
        for r = 1, L.rows do
            local row = W.HorizontalGroup:new{ align = "top" }
            row[#row + 1] = W.HorizontalSpan:new{ width = L.left }
            for c = 1, L.cols do
                local item = page_items[(r - 1) * L.cols + c]
                if item then
                    row[#row + 1] = self:cell(item)
                    row[#row + 1] = W.HorizontalSpan:new{ width = L.padding }
                end
            end
            if #row > 1 then
                body[#body + 1] = row
                body[#body + 1] = W.VerticalSpan:new{ width = L.padding }
            end
        end
    end

    local body_frame = W.FrameContainer:new{
        bordersize = 0, padding = 0, background = W.Blitbuffer.COLOR_WHITE,
        width = w, height = h - title_h - footer_h,
        body,
    }

    self[1] = W.FrameContainer:new{
        bordersize = 0, padding = 0, background = W.Blitbuffer.COLOR_WHITE,
        width = w, height = h,
        W.VerticalGroup:new{ align = "left", self.titlebar, body_frame, footer },
    }
end

function S:footer(w)
    local W = ko()
    local pages = self.layout_info and self:pageCount() or 1
    local page = self.page or 1
    local label = W.T(W._("Page %1 of %2"), page, pages)
    local buttons = { {
        { text = "◁", enabled = page > 1, callback = function() self:gotoPage(page - 1) end },
        { text = label, enabled = false },
        { text = "▷", enabled = page < pages, callback = function() self:gotoPage(page + 1) end },
    } }
    return W.ButtonTable:new{ width = w, buttons = buttons, zero_sep = true, show_parent = self }
end

function S:gotoPage(page)
    local pages = self:pageCount()
    if page < 1 or page > pages then return end
    self.page = page
    self:refresh()
end

--- Re-read items and repaint (after a download, a sync, a sort change).
function S:refresh()
    local W = ko()
    self:render()
    W.UIManager:setDirty(self, "ui")
end

function S:onShelfSwipe(_, ges)
    if ges.direction == "west" then self:gotoPage(self.page + 1)
    elseif ges.direction == "east" then self:gotoPage(self.page - 1) end
    return true
end

function S:onClose()
    local W = ko()
    W.UIManager:close(self)
    if self.opts.on_close then self.opts.on_close() end
    return true
end

function S:showMenu()
    local W = ko()
    local rows = self.opts.menu_buttons_func and self.opts.menu_buttons_func(self) or {}
    if #rows == 0 then return end
    local dialog
    -- Close the dialog before running any action.
    for _, row in ipairs(rows) do
        for _, b in ipairs(row) do
            local cb = b.callback
            b.callback = function() W.UIManager:close(dialog); if cb then cb() end end
        end
    end
    dialog = W.ButtonDialog:new{ buttons = rows }
    W.UIManager:show(dialog)
end

--- One cover cell: cover (or placeholder), progress bar, three text lines.
function S:cell(item)
    local W = ko()
    local L = self.layout_info
    local o = self.opts
    local title = o.title_func and o.title_func(item) or (item.title or "")
    local author = o.author_func and o.author_func(item) or ""
    local status = o.status_func and o.status_func(item) or ""
    local percent = o.percent_func and o.percent_func(item) or nil
    local dim = o.dim_func and o.dim_func(item) or false

    local cover = self:cover(item, title, dim)
    local badge = o.badge_func and o.badge_func(item)
    if badge then
        cover = Shelf.with_badge(cover, L.cover_w, L.cover_h, type(badge) == "table" and badge or nil)
    end
    local group = W.VerticalGroup:new{ align = "left", cover }
    if W.ProgressWidget then
        group[#group + 1] = W.ProgressWidget:new{
            width = L.cover_w, height = L.bar_h, percentage = (percent or 0) / 100,
            margin_h = 0, margin_v = 0, radius = 0, bordersize = 0,
            bgcolor = percent and W.Blitbuffer.COLOR_LIGHT_GRAY or W.Blitbuffer.COLOR_WHITE,
            fillcolor = W.Blitbuffer.COLOR_BLACK,
        }
    else
        group[#group + 1] = W.VerticalSpan:new{ width = L.bar_h }
    end
    group[#group + 1] = W.VerticalSpan:new{ width = L.padding }
    group[#group + 1] = W.TextWidget:new{ text = title, face = W.Font:getFace("cfont", L.font_title), bold = true,
        max_width = L.cover_w, truncate_with_ellipsis = true, fgcolor = dim and W.Blitbuffer.COLOR_DARK_GRAY or W.Blitbuffer.COLOR_BLACK }
    group[#group + 1] = W.TextWidget:new{ text = author, face = W.Font:getFace("cfont", L.font_small),
        max_width = L.cover_w, truncate_with_ellipsis = true, fgcolor = W.Blitbuffer.COLOR_DARK_GRAY }
    group[#group + 1] = W.TextWidget:new{ text = status, face = W.Font:getFace("cfont", L.font_small),
        max_width = L.cover_w, truncate_with_ellipsis = true, fgcolor = W.Blitbuffer.COLOR_DARK_GRAY }

    local frame = W.FrameContainer:new{
        bordersize = 0, padding = L.padding, background = W.Blitbuffer.COLOR_WHITE,
        width = L.cell_w, height = L.cell_h,
        group,
    }
    local cell = W.InputContainer:new{ dimen = W.Geom:new{ w = L.cell_w, h = L.cell_h }, frame }
    cell.ges_events = {
        TapCell = { W.GestureRange:new{ ges = "tap", range = function() return cell.dimen end } },
        HoldCell = { W.GestureRange:new{ ges = "hold", range = function() return cell.dimen end } },
    }
    cell.onTapCell = function() if o.on_open then o.on_open(item, self) end; return true end
    cell.onHoldCell = function() if o.on_hold then o.on_hold(item, self) end; return true end
    return cell
end

--- Paint the "Kindle" corner banner over a cover widget (opts.corner = "tl" | "tr").
function Shelf.with_badge(cover, cover_w, cover_h, opts)
    if type(cover) ~= "table" or type(cover.paintTo) ~= "function" or cover._ws_badge_wrapped then return cover end
    local Zen = require("zenos")
    local paint = cover.paintTo
    opts = type(opts) == "table" and opts or {}
    cover._ws_badge_wrapped = true
    cover.paintTo = function(self, bb, x, y)
        paint(self, bb, x, y)
        local border = tonumber(self.bordersize) or 0
        Zen.paintBanner(bb, x, y, cover_w, cover_h, {
            corner = opts.corner, border = border, border_color = border > 0 and self.color or nil,
        })
    end
    return cover
end

--- Cover image from file, or a framed placeholder carrying the title.
function S:cover(item, title, dim)
    local W = ko()
    local L = self.layout_info
    local path = self.opts.cover_func and self.opts.cover_func(item) or nil
    local image
    if path then
        local ok, bb = pcall(W.RenderImage.renderImageFile, W.RenderImage, path, false, L.cover_w, L.cover_h)
        if ok and bb then
            image = W.ImageWidget:new{ image = bb, image_disposable = true, width = L.cover_w, height = L.cover_h, scale_factor = 0 }
        end
    end
    if image then
        return W.FrameContainer:new{
            bordersize = W.Size.border.thin, padding = 0, color = W.Blitbuffer.COLOR_DARK_GRAY,
            width = L.cover_w, height = L.cover_h,
            W.CenterContainer:new{ dimen = W.Geom:new{ w = L.cover_w - 2 * W.Size.border.thin, h = L.cover_h - 2 * W.Size.border.thin }, image },
        }
    end
    local inner_w = L.cover_w - 2 * L.padding
    return W.FrameContainer:new{
        bordersize = W.Size.border.thin, padding = 0,
        color = W.Blitbuffer.COLOR_DARK_GRAY,
        background = dim and W.Blitbuffer.COLOR_LIGHT_GRAY or W.Blitbuffer.COLOR_WHITE,
        width = L.cover_w, height = L.cover_h,
        W.CenterContainer:new{
            dimen = W.Geom:new{ w = L.cover_w - 2 * W.Size.border.thin, h = L.cover_h - 2 * W.Size.border.thin },
            W.TextBoxWidget:new{
                text = title, face = W.Font:getFace("cfont", L.font_title), width = inner_w,
                alignment = "center", height = L.cover_h - 4 * L.padding, height_overflow_show_ellipsis = true,
                bgcolor = dim and W.Blitbuffer.COLOR_LIGHT_GRAY or W.Blitbuffer.COLOR_WHITE,
            },
        },
    }
end

-------------------------------------------------------------------------------
-- ZenOS Home strip: a single row of covers sized to the space Home offers
-------------------------------------------------------------------------------

--- Build a horizontal strip for ZenOS Home. `ctx` has width/height.
function Shelf.build_strip(ctx, items, opts)
    local W = ko()
    local width, height = ctx.width, ctx.height
    local padding = math.max(4, math.floor(W.Screen:scaleBySize(4)))
    local label_h = math.floor(W.Screen:scaleBySize(14) * 1.4)
    local cover_h = math.max(20, height - label_h - 2 * padding)
    local cover_w = math.floor(cover_h / Shelf.COVER_RATIO)
    local n = math.max(1, math.floor((width - padding) / (cover_w + padding)))
    local row = W.HorizontalGroup:new{ align = "top" }
    row[#row + 1] = W.HorizontalSpan:new{ width = padding }
    local shown = 0
    for i = 1, math.min(n, #items) do
        local item = items[i]
        local title = opts.title_func and opts.title_func(item) or (item.title or "")
        local path = opts.cover_func and opts.cover_func(item) or nil
        local cover
        if path then
            local ok, bb = pcall(W.RenderImage.renderImageFile, W.RenderImage, path, false, cover_w, cover_h)
            if ok and bb then
                cover = W.ImageWidget:new{ image = bb, image_disposable = true, width = cover_w, height = cover_h, scale_factor = 0 }
            end
        end
        if not cover then
            cover = W.FrameContainer:new{
                bordersize = W.Size.border.thin, padding = 0, color = W.Blitbuffer.COLOR_DARK_GRAY,
                width = cover_w, height = cover_h,
                W.CenterContainer:new{
                    dimen = W.Geom:new{ w = cover_w - 2, h = cover_h - 2 },
                    W.TextBoxWidget:new{ text = title, face = W.Font:getFace("cfont", 12), width = cover_w - 2 * padding,
                        alignment = "center", height = cover_h - 2 * padding, height_overflow_show_ellipsis = true },
                },
            }
        end
        local badge = opts.badge_func and opts.badge_func(item)
        if badge then
            cover = Shelf.with_badge(cover, cover_w, cover_h, type(badge) == "table" and badge or nil)
        end
        local percent = opts.percent_func and opts.percent_func(item) or nil
        local label = percent and ("%d%%"):format(math.floor(percent + 0.5)) or (opts.status_func and opts.status_func(item) or "")
        local group = W.VerticalGroup:new{ align = "center", cover,
            W.TextWidget:new{ text = label, face = W.Font:getFace("cfont", 12), max_width = cover_w, fgcolor = W.Blitbuffer.COLOR_DARK_GRAY } }
        local cell = W.InputContainer:new{ dimen = W.Geom:new{ w = cover_w, h = height }, group }
        cell.ges_events = { TapStrip = { W.GestureRange:new{ ges = "tap", range = function() return cell.dimen end } } }
        cell.onTapStrip = function() if opts.on_open then opts.on_open(item) end; return true end
        row[#row + 1] = cell
        row[#row + 1] = W.HorizontalSpan:new{ width = padding }
        shown = shown + 1
    end
    if shown == 0 then
        local box = W.InputContainer:new{ dimen = W.Geom:new{ w = width, h = height },
            W.CenterContainer:new{ dimen = W.Geom:new{ w = width, h = height },
                W.TextBoxWidget:new{ text = opts.empty_text or W._("Kindle library: tap to open"), face = W.Font:getFace("cfont", 14),
                    width = math.floor(width * 0.8), alignment = "center" } } }
        box.ges_events = { TapStrip = { W.GestureRange:new{ ges = "tap", range = function() return box.dimen end } } }
        box.onTapStrip = function() if opts.on_empty_tap then opts.on_empty_tap() end; return true end
        return box
    end
    return W.FrameContainer:new{ bordersize = 0, padding = 0, width = width, height = height,
        W.VerticalGroup:new{ align = "left", W.VerticalSpan:new{ width = padding }, row } }
end

return Shelf
