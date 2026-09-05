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
-- `opts.timeout` seconds per socket operation (default 30); `opts.host`
-- overrides the Host header (testing through a tunnel).
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
    local req = M.handshake_request(opts.host or u.host, u.path, key, opts.headers)
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
    return setmetatable({ sock = sock, closed = false, timeout = opts.timeout or 30 }, Conn)
end

function Conn:send_text(s)
    return self.sock:send(M.encode_frame(M.OPCODE.TEXT, s))
end

function Conn:send_pong(payload)
    return self.sock:send(M.encode_frame(M.OPCODE.PONG, payload or ""))
end

--- Read exactly n bytes (luasec hands back partial reads on timeout).
function Conn:read_exact(n, timeout)
    if n == 0 then return "" end
    self.sock:settimeout(timeout or self.timeout or 30)
    local chunks, got = {}, 0
    while got < n do
        local chunk, err, partial = self.sock:receive(n - got)
        if chunk then
            chunks[#chunks + 1] = chunk
            got = got + #chunk
        else
            if partial and #partial > 0 then
                chunks[#chunks + 1] = partial
                got = got + #partial
            end
            if err == "closed" then return nil, "closed" end
            -- luasec reports a timed-out read as "wantread".
            if err == "timeout" or err == "wantread" then return nil, "timeout" end
            if got < n then return nil, err or "receive failed" end
        end
    end
    return table.concat(chunks)
end

--- Read one frame: { fin, opcode, payload }. `timeout` applies to the wait
-- for its first byte; the rest of a started frame gets the normal timeout.
function Conn:read_frame(timeout)
    local head, err = self:read_exact(2, timeout)
    if not head then return nil, err end
    local b1, b2 = head:byte(1, 2)
    local fin = band(b1, 0x80) ~= 0
    local opcode = band(b1, 0x0f)
    local masked = band(b2, 0x80) ~= 0
    local len = band(b2, 0x7f)
    if len == 126 then
        local ext = self:read_exact(2); if not ext then return nil, "closed" end
        len = ext:byte(1) * 256 + ext:byte(2)
    elseif len == 127 then
        local ext = self:read_exact(8); if not ext then return nil, "closed" end
        len = 0
        for i = 1, 8 do len = len * 256 + ext:byte(i) end
    end
    local mask
    if masked then
        mask = self:read_exact(4); if not mask then return nil, "closed" end
    end
    local payload, perr = self:read_exact(len)
    if not payload then return nil, perr end
    if mask then
        local m = { mask:byte(1, 4) }
        local out = {}
        for i = 1, len do out[i] = string.char(bxor(payload:byte(i), m[(i - 1) % 4 + 1])) end
        payload = table.concat(out)
    end
    return { fin = fin, opcode = opcode, payload = payload }
end

--- Receive one complete message. Returns opcode (TEXT or BINARY), payload;
-- or nil, "closed" / "timeout" / error. Pings are answered here; fragments
-- are joined. `timeout` is how long to wait for the message to begin.
function Conn:recv(timeout)
    local message, mopcode
    while true do
        local f, err = self:read_frame(timeout)
        if not f then return nil, err end
        if f.opcode == M.OPCODE.PING then
            pcall(self.send_pong, self, f.payload)
        elseif f.opcode == M.OPCODE.PONG then
            -- ignore
        elseif f.opcode == M.OPCODE.CLOSE then
            self.closed = true
            pcall(function() self.sock:send(M.encode_frame(M.OPCODE.CLOSE, "")) end)
            -- The close payload is a 2-byte status code and a UTF-8 reason:
            -- the one place the service says why it hung up.
            local code, reason
            if #f.payload >= 2 then
                code = f.payload:byte(1) * 256 + f.payload:byte(2)
                reason = f.payload:sub(3)
            end
            self.close_code, self.close_reason = code, reason
            return nil, "closed", { code = code, reason = reason }
        else
            if f.opcode ~= M.OPCODE.CONTINUATION then
                mopcode = f.opcode
                message = {}
            end
            if not message then return nil, "protocol: continuation without start" end
            message[#message + 1] = f.payload
            if f.fin then return mopcode, table.concat(message) end
        end
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
