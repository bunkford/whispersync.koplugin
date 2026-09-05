local H = require("helpers")
local ws = require("ws")

-- URL parsing
local u = ws.parse_url("wss://speech.platform.bing.com/consumer/x?y=1")
H.eq(u.host, "speech.platform.bing.com", "host"); H.eq(u.port, 443, "wss default port"); H.eq(u.path, "/consumer/x?y=1", "path keeps query")
H.eq(u.tls, true, "wss is tls")
H.eq(ws.parse_url("ws://h:8080").path, "/", "empty path -> /")
H.eq(ws.parse_url("http://x"), nil, "not a websocket URL")

-- base64
H.eq(ws.base64("abc"), "YWJj", "base64 abc"); H.eq(ws.base64("ab"), "YWI=", "padding 1"); H.eq(ws.base64("a"), "YQ==", "padding 2")
H.eq(#ws.random_bytes(16), 16, "random bytes length")

-- handshake
local req = ws.handshake_request("h.example", "/p?q=1", "dGhlIHNhbXBsZSBub25jZQ==", { { "Origin", "chrome-extension://abc" }, { "Sec-WebSocket-Version", "99" } })
H.ok(req:find("^GET /p%?q=1 HTTP/1.1\r\nHost: h.example\r\n"), "request line and host")
H.ok(req:find("Sec%-WebSocket%-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"), "key header")
H.ok(req:find("Origin: chrome%-extension://abc\r\n"), "extra header")
H.ok(not req:find("Version: 99"), "duplicate version header dropped")
H.ok(req:sub(-4) == "\r\n\r\n", "terminated")
local resp = ws.parse_handshake_response("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: x\r\n\r\n")
H.eq(resp.code, 101, "status code"); H.eq(resp.headers["sec-websocket-accept"], "x", "headers lowercased")
local forbidden = ws.parse_handshake_response("HTTP/1.1 403 Forbidden\r\nDate: Sun, 06 Nov 1994 08:49:37 GMT\r\n\r\n")
H.eq(forbidden.code, 403, "403 parsed"); H.eq(forbidden.headers.date, "Sun, 06 Nov 1994 08:49:37 GMT", "date header")

-- framing: RFC 6455 examples
H.eq(ws.encode_frame(ws.OPCODE.TEXT, "Hello", false), "\129\5Hello", "unmasked text frame")
H.eq(ws.encode_frame(ws.OPCODE.TEXT, "Hello", "\55\250\33\61"), "\129\133\55\250\33\61\127\159\77\81\88", "masked text frame (RFC example)")
local frames, rest = ws.decode_frames("\129\133\55\250\33\61\127\159\77\81\88\130\2ab")
H.eq(#frames, 2, "two frames decoded"); H.eq(frames[1].payload, "Hello", "unmasked on decode"); H.eq(frames[1].opcode, 1, "text")
H.eq(frames[2].opcode, 2, "binary"); H.eq(frames[2].payload, "ab", "binary payload"); H.eq(rest, "", "nothing left")
-- medium and large lengths round-trip
local mid = string.rep("x", 300)
local f2 = ws.decode_frames(ws.encode_frame(ws.OPCODE.BINARY, mid, false))
H.eq(#f2[1].payload, 300, "16-bit length")
local big = string.rep("y", 70000)
local f3 = ws.decode_frames(ws.encode_frame(ws.OPCODE.BINARY, big, "abcd"))
H.eq(#f3[1].payload, 70000, "64-bit length, masked"); H.eq(f3[1].payload:sub(1, 3), "yyy", "unmasked content")
-- partial input waits
local partial_frames, partial_rest = ws.decode_frames("\130\126\1\44" .. string.rep("z", 100))
H.eq(#partial_frames, 0, "incomplete frame not emitted"); H.eq(#partial_rest, 104, "kept for later")
-- fragmentation handled by Conn:recv over a fake socket
local script = {
    ws.encode_frame(ws.OPCODE.TEXT, "Hel", false, false),
    ws.encode_frame(ws.OPCODE.PING, "p", false),
    ws.encode_frame(ws.OPCODE.CONTINUATION, "lo", false, true),
    ws.encode_frame(ws.OPCODE.CLOSE, "", false),
}
local data = table.concat(script)
local sent = {}
local fake = { pos = 1 }
function fake:settimeout() end
function fake:send(s) sent[#sent + 1] = s; return #s end
function fake:receive(n)
    if self.pos > #data then return nil, "closed" end
    local chunk = data:sub(self.pos, self.pos + n - 1)
    self.pos = self.pos + #chunk
    return chunk
end
function fake:close() self.closed = true end
local conn = setmetatable({ sock = fake, buf = "" }, { __index = getmetatable(select(1, (function() return setmetatable({}, { __index = {} }) end)())) })
-- use the real Conn methods via connect's metatable: reach them through a tiny shim
local Conn_recv = debug.getupvalue and nil
-- ws exposes Conn only through connect(); emulate by borrowing the functions from a connected object shape:
local real = ws.connect  -- ensure module loaded
local conn_mt
do
    -- construct via the same path connect() uses
    conn_mt = { __index = {} }
end
-- Simplest: call the module's recv through a connected-like object made by connect's constructor.
-- We can't reach the private Conn table, so test recv through a monkeypatched socket module instead.
package.loaded["socket"] = { tcp = function() return fake end }
fake.connect = function() return 1 end
fake.receive_line = nil
local lines = { "HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "" }
local li = 0
local orig_receive = fake.receive
fake.receive = function(self, n)
    if n == "*l" then li = li + 1; return lines[li] end
    return orig_receive(self, n)
end
local c = assert(ws.connect("ws://h.example/x", { headers = {} }))
local op, msg = c:recv()
H.eq(op, ws.OPCODE.TEXT, "fragmented text reassembled as text"); H.eq(msg, "Hello", "fragments joined across a ping")
H.ok(sent[2] and sent[2]:byte(1) == 0x8A, "ping answered with a masked pong")
local op2, why = c:recv()
H.eq(op2, nil, "close frame ends the stream"); H.eq(why, "closed", "reported as closed")
H.done("test_ws")
