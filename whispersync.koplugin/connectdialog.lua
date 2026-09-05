--[[--
The connect dialog: QR code, the address to open, the steps, and the live
status, all on one screen. Replaces the QR-then-explanation two-step whose
second half was easy to miss.
]]

local ConnectDialog = {}

local K
local function ko()
    if K then return K end
    K = {
        Blitbuffer = require("ffi/blitbuffer"),
        ButtonTable = require("ui/widget/buttontable"),
        CenterContainer = require("ui/widget/container/centercontainer"),
        Device = require("device"),
        Font = require("ui/font"),
        FrameContainer = require("ui/widget/container/framecontainer"),
        Geom = require("ui/geometry"),
        InputContainer = require("ui/widget/container/inputcontainer"),
        Size = require("ui/size"),
        TextBoxWidget = require("ui/widget/textboxwidget"),
        TextWidget = require("ui/widget/textwidget"),
        UIManager = require("ui/uimanager"),
        VerticalGroup = require("ui/widget/verticalgroup"),
        VerticalSpan = require("ui/widget/verticalspan"),
        _ = require("gettext"),
        T = require("ffi/util").template,
    }
    local ok, QRWidget = pcall(require, "ui/widget/qrwidget")
    if ok then K.QRWidget = QRWidget end
    K.Screen = K.Device.screen
    return K
end

--- opts: url (short address shown as QR), store_label, status (initial),
-- on_stop(), on_hide()
function ConnectDialog.new(opts)
    local W = ko()
    local dlg = W.InputContainer:new{
        opts = opts,
        status = opts.status or W._("Waiting for the sign-in…"),
        dimen = W.Geom:new{ x = 0, y = 0, w = W.Screen:getWidth(), h = W.Screen:getHeight() },
        modal = true,
    }
    for k, v in pairs(ConnectDialog.methods) do dlg[k] = v end
    if W.Device:hasKeys() then
        dlg.key_events = { Hide = { { W.Device.input.group.Back } } }
    end
    dlg:render()
    return dlg
end

ConnectDialog.methods = {}
local D = ConnectDialog.methods

function D:render()
    local W = ko()
    local Screen = W.Screen
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local content_w = math.floor(math.min(sw, sh) * 0.86)
    local qr_size = math.floor(math.min(content_w * 0.62, sh * 0.34))
    local pad = W.Size.padding.large

    if self[1] then self[1]:free() end

    local group = W.VerticalGroup:new{ align = "center" }
    group[#group + 1] = W.TextWidget:new{ text = W._("Connect KOReader to Amazon"), face = W.Font:getFace("tfont"), bold = true, max_width = content_w }
    group[#group + 1] = W.VerticalSpan:new{ width = pad }

    if W.QRWidget then
        local ok, qr = pcall(function()
            return W.QRWidget:new{ text = self.opts.url, width = qr_size, height = qr_size }
        end)
        if ok and qr then
            group[#group + 1] = W.FrameContainer:new{ bordersize = 0, padding = W.Size.padding.small, background = W.Blitbuffer.COLOR_WHITE, qr }
            group[#group + 1] = W.VerticalSpan:new{ width = pad }
        end
    end

    group[#group + 1] = W.TextWidget:new{ text = self.opts.url, face = W.Font:getFace("infont", 20), bold = true, max_width = content_w }
    group[#group + 1] = W.VerticalSpan:new{ width = pad }
    group[#group + 1] = W.TextBoxWidget:new{
        text = W.T(W._([[On a phone or computer on the same Wi-Fi, scan the code or type the address above.

1. Tap “Sign in to Amazon” on that page. It is Amazon's own sign-in (%1); passwords, 2FA and passkeys work as usual and nothing typed there reaches this device.
2. Amazon lands you on a blank page. Copy its address.
3. Paste it into the box on the page and tap “Finish connecting”.

This screen updates by itself when it is done.]]), self.opts.store_label or "Amazon"),
        face = W.Font:getFace("cfont", 17),
        width = content_w,
    }
    group[#group + 1] = W.VerticalSpan:new{ width = pad }
    group[#group + 1] = W.TextWidget:new{ text = self.status, face = W.Font:getFace("cfont", 18), bold = true, max_width = content_w }
    group[#group + 1] = W.VerticalSpan:new{ width = pad }
    group[#group + 1] = W.ButtonTable:new{
        width = content_w,
        zero_sep = true,
        show_parent = self,
        buttons = { {
            { text = W._("Hide (keep waiting)"), callback = function() self:onHide() end },
            { text = W._("Stop"), callback = function() if self.opts.on_stop then self.opts.on_stop() end; self:close() end },
        } },
    }

    self[1] = W.CenterContainer:new{
        dimen = W.Geom:new{ w = sw, h = sh },
        W.FrameContainer:new{
            background = W.Blitbuffer.COLOR_WHITE,
            bordersize = W.Size.border.window,
            radius = W.Size.radius.window,
            padding = pad,
            group,
        },
    }
end

function D:setStatus(text)
    local W = ko()
    self.status = text
    self:render()
    W.UIManager:setDirty(self, "ui")
end

function D:onHide()
    if self.opts.on_hide then self.opts.on_hide() end
    self:close()
    return true
end

function D:close()
    local W = ko()
    W.UIManager:close(self)
end

return ConnectDialog
