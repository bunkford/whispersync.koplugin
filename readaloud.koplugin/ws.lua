--[[--
A small WebSocket client (RFC 6455) on luasocket + luasec.

KOReader ships luasocket and luasec but no WebSocket library, and the Edge
read-aloud service speaks nothing else. This is the minimum a client needs:
the HTTP upgrade handshake, masked client frames, unmasked server frames
with fragmentation, ping/pong and close. The framing functions are pure so
they can be tested without a network; `connect` does the I/O.
]]

local M = {}

local bit = require("bit")
local band, bor, bxor, rshift, lshift = bit.band, bit.bor, bit.bxor, bit.rshift, bit.lshift

M.OPCODE = { CONTINUATION = 0, TEXT = 1, BINARY = 2, CLOSE = 8, PING = 9, PONG = 10 }

-------------------------------------------------------------------------------
-- pure helpers
-------------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function M.base64(s)
    local ok, mime = pcall(require, "mime")
    if ok and mime and mime.b64 then return (mime.b64(s)) end
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = rshift(n, 18) % 64
        local c2 = rshift(n, 12) % 64
        local c3 = rshift(n, 6) % 64
        local c4 = n % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

--- `n` random bytes, from /dev/urandom when there is one.
function M.random_bytes(n)
    local f = io.open("/dev/urandom", "rb")
    if f then
        local d = f:read(n)
        f:close()
        if d and #d == n then return d end
    end
    local t = {}
    for i = 1, n do t[i] = string.char(math.random(0, 255)) end
    return table.concat(t)
end

--- Split a ws:// or wss:// URL into its parts.
function M.parse_url(url)
    local scheme, host, port, path = url:match("^(wss?)://([^/:]+):?(%d*)(/?.*)$")
    if not scheme then return nil, "not a websocket URL: " .. tostring(url) end
    port = tonumber(port) or (scheme == "wss" and 443 or 80)
    if path == "" then path = "/" end
    return { scheme = scheme, host = host, port = port, path = path, tls = scheme == "wss" }
end

--- The HTTP upgrade request. `headers` is an ordered list of {name, value}.
function M.handshake_request(host, path, key, headers)
    local lines = {
        "GET " .. path .. " HTTP/1.1",
        "Host: " .. host,
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: " .. key,
        "Sec-WebSocket-Version: 13",
    }
    for _, h in ipairs(headers or {}) do
        if h[1]:lower() ~= "sec-websocket-version" then
            lines[#lines + 1] = h[1] .. ": " .. h[2]
        end
    end
    return table.concat(lines, "\r\n") .. "\r\n\r\n"
end

--- Parse the status line and headers of the upgrade response.
function M.parse_handshake_response(text)
    local status_line, rest = text:match("^([^\r\n]*)\r?\n(.*)$")
    if not status_line then return nil, "empty response" end
    local code = tonumber(status_line:match("^HTTP/%d%.%d (%d%d%d)"))
    local headers = {}
    for line in (rest or ""):gmatch("([^\r\n]+)") do
        local k, v = line:match("^([^:]+):%s*(.*)$")
        if k then headers[k:lower()] = v end
    end
    return { code = code, status = status_line, headers = headers }
end

local function be16(n) return string.char(rshift(n, 8) % 256, n % 256) end

--- Encode one frame. Client frames are masked (`mask` = 4 bytes; random when nil).
function M.encode_frame(opcode, payload, mask, fin)
    payload = payload or ""
    local len = #payload
    local first = bor(fin == false and 0 or 0x80, opcode)
    local parts = { string.char(first) }
    local masked = mask ~= false
    local mbit = masked and 0x80 or 0
    if len < 126 then
        parts[#parts + 1] = string.char(bor(mbit, len))
    elseif len < 65536 then
        parts[#parts + 1] = string.char(bor(mbit, 126)) .. be16(len)
    else
        -- 64-bit length; payloads here are far below 2^32.
        parts[#parts + 1] = string.char(bor(mbit, 127)) .. string.char(0, 0, 0, 0)
            .. string.char(rshift(len, 24) % 256, rshift(len, 16) % 256, rshift(len, 8) % 256, len % 256)
    end
    if masked then
        if type(mask) ~= "string" or #mask ~= 4 then mask = M.random_bytes(4) end
        parts[#parts + 1] = mask
        local m = { mask:byte(1, 4) }
        local out = {}
        for i = 1, len do
            out[i] = string.char(bxor(payload:byte(i), m[(i - 1) % 4 + 1]))
        end
        parts[#parts + 1] = table.concat(out)
    else
        parts[#parts + 1] = payload
    end
    return table.concat(parts)
end

--- Decode as many complete frames as `buf` holds.
-- Returns list of { fin, opcode, payload } and the unconsumed remainder.
function M.decode_frames(buf)
    local frames = {}
    local pos = 1
    while true do
        if #buf - pos + 1 < 2 then break end
        local b1, b2 = buf:byte(pos, pos + 1)
        local fin = band(b1, 0x80) ~= 0
        local opcode = band(b1, 0x0f)
        local masked = band(b2, 0x80) ~= 0
        local len = band(b2, 0x7f)
        local p = pos + 2
        if len == 126 then
            if #buf < p + 1 then break end
            local h, l = buf:byte(p, p + 1)
            len = h * 256 + l
            p = p + 2
        elseif len == 127 then
            if #buf < p + 7 then break end
            local b = { buf:byte(p, p + 7) }
            len = 0
            for i = 1, 8 do len = len * 256 + b[i] end
            p = p + 8
        end
        local mask
        if masked then
            if #buf < p + 3 then break end
            mask = buf:sub(p, p + 3)
            p = p + 4
        end
        if #buf < p + len - 1 then break end
        local payload = buf:sub(p, p + len - 1)
        if mask then
            local m = { mask:byte(1, 4) }
            local out = {}
            for i = 1, len do out[i] = string.char(bxor(payload:byte(i), m[(i - 1) % 4 + 1])) end
            payload = table.concat(out)
        end
        frames[#frames + 1] = { fin = fin, opcode = opcode, payload = payload }
        pos = p + len
    end
    return frames, buf:sub(pos)
end

-------------------------------------------------------------------------------
-- connection
-------------------------------------------------------------------------------

local Conn = {}
Conn.__index = Conn

--- Open a WebSocket. `opts.headers` is an ordered list of {name, value};
-- `opts.timeout` seconds per socket operation (default 30).
-- Returns conn, or nil, reason, response (the upgrade response, when the
-- server answered with something other than 101; it carries a Date header
-- the Edge client uses to correct clock skew).
function M.connect(url, opts)
    opts = opts or {}
    local u, err = M.parse_url(url)
    if not u then return nil, err end
    local socket = require("socket")
    local sock = socket.tcp()
    sock:settimeout(opts.timeout or 30)
    local ok, cerr = sock:connect(u.host, u.port)
    if not ok then return nil, "connect: " .. tostring(cerr) end
    if u.tls then
        local sok, ssl = pcall(require, "ssl")
        if not sok then sock:close(); return nil, "no TLS support (luasec missing)" end
        local params = {
            mode = "client",
            protocol = "any",
            verify = "none",
            options = { "all", "no_sslv2", "no_sslv3" },
        }
        local ssock, werr = ssl.wrap(sock, params)
        if not ssock then sock:close(); return nil, "tls: " .. tostring(werr) end
        if ssock.sni then pcall(ssock.sni, ssock, u.host) end
        ssock:settimeout(opts.timeout or 30)
        local hok, herr = ssock:dohandshake()
        if not hok then ssock:close(); return nil, "tls handshake: " .. tostring(herr) end
        sock = ssock
    end
    local key = M.base64(M.random_bytes(16))
    local req = M.handshake_request(u.host, u.path, key, opts.headers)
    local sent, serr = sock:send(req)
    if not sent then sock:close(); return nil, "send: " .. tostring(serr) end
    -- Read the response head.
    local head = {}
    while true do
        local line, rerr = sock:receive("*l")
        if not line then sock:close(); return nil, "handshake: " .. tostring(rerr) end
        if line == "" then break end
        head[#head + 1] = line
    end
    local resp = M.parse_handshake_response(table.concat(head, "\r\n") .. "\r\n")
    if not resp or resp.code ~= 101 then
        sock:close()
        return nil, "upgrade refused: " .. tostring(resp and resp.status or "?"), resp
    end
    return setmetatable({ sock = sock, buf = "", closed = false }, Conn)
end

function Conn:send_text(s)
    return self.sock:send(M.encode_frame(M.OPCODE.TEXT, s))
end

function Conn:send_pong(payload)
    return self.sock:send(M.encode_frame(M.OPCODE.PONG, payload or ""))
end

--- Receive one complete message. Returns opcode (TEXT or BINARY), payload;
-- or nil, "closed"/error. Pings are answered here; fragments are joined.
function Conn:recv()
    local message, mopcode
    while true do
        local frames, rest = M.decode_frames(self.buf)
        self.buf = rest
        for _, f in ipairs(frames) do
            if f.opcode == M.OPCODE.PING then
                pcall(self.send_pong, self, f.payload)
            elseif f.opcode == M.OPCODE.PONG then
                -- ignore
            elseif f.opcode == M.OPCODE.CLOSE then
                self.closed = true
                pcall(function() self.sock:send(M.encode_frame(M.OPCODE.CLOSE, "")) end)
                return nil, "closed"
            else
                if f.opcode ~= M.OPCODE.CONTINUATION then
                    mopcode = f.opcode
                    message = {}
                end
                if not message then return nil, "protocol: continuation without start" end
                message[#message + 1] = f.payload
                if f.fin then
                    return mopcode, table.concat(message)
                end
            end
        end
        -- Need more bytes.
        local chunk, err, partial = self.sock:receive(1)
        if not chunk then
            if partial and #partial > 0 then chunk = partial
            else return nil, err or "receive failed" end
        end
        -- Take whatever else is immediately available, cheaply.
        self.sock:settimeout(0)
        local more, _, mpartial = self.sock:receive(65536)
        self.sock:settimeout(self.timeout or 30)
        self.buf = self.buf .. chunk .. (more or mpartial or "")
    end
end

function Conn:close()
    if not self.closed then
        self.closed = true
        pcall(function() self.sock:send(M.encode_frame(M.OPCODE.CLOSE, "")) end)
    end
    pcall(function() self.sock:close() end)
end

return M
