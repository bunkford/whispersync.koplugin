local H = require("helpers")
local edge = require("edge")
local json = require("json")

-- Sec-MS-GEC against the edge-tts Python computation (tests/gec oracle)
H.eq(edge.gec(1757000000), "A27A3507D7417EDD6F88E29C6D766BEA1C6B878B44A332112C95B3AD42C108F1", "gec 1757000000")
H.eq(edge.gec(1757000299), "A5BC35CC9630499075D70BC661044DB1471D3CC13E2761E98766A697FD017181", "gec rounds down to the 5-minute mark")
H.eq(edge.gec(1700000000.7), "42301B335578FEFDAE2637DED1ABD614505D432559EC08032B82048483726AFF", "gec with a fractional clock")
H.eq(edge.gec(1757000000), edge.gec(1757000050), "same 5-minute window, same token")

-- URL and ids
local id = edge.connect_id(string.rep("\255", 16))
H.eq(id, string.rep("ff", 16), "connect id is 32 hex chars")
local url = edge.url(id, 1757000000)
H.ok(url:find("^wss://speech%.platform%.bing%.com/consumer/speech/synthesize/readaloud/edge/v1%?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4&Sec%-MS%-GEC=%x+&Sec%-MS%-GEC%-Version=1%-143%.0%.3650%.75&ConnectionId=" .. id .. "$"), "url shape: " .. url)
H.eq(edge.headers()[3][1], "Origin", "browser-like headers")

-- Messages
H.eq(edge.date_string(0), "Thu Jan 01 1970 00:00:00 GMT+0000 (Coordinated Universal Time)", "JS date string")
local cfg = edge.speech_config(0, edge.FORMATS.pcm)
H.ok(cfg:find('Path:speech.config\r\n\r\n{"context"', 1, true), "speech.config framing")
H.ok(cfg:find('"wordBoundaryEnabled":"true"', 1, true), "word boundaries requested")
H.ok(cfg:find('"outputFormat":"raw-24khz-16bit-mono-pcm"', 1, true), "format selectable")
H.eq(edge.full_voice_name("en-US-AndrewNeural"), "Microsoft Server Speech Text to Speech Voice (en-US, AndrewNeural)", "full voice name")
H.eq(edge.full_voice_name("Microsoft Server Speech Text to Speech Voice (en-GB, RyanNeural)"), "Microsoft Server Speech Text to Speech Voice (en-GB, RyanNeural)", "full name passes through")
H.eq(edge.rate_string(1.25), "+25%", "rate +"); H.eq(edge.rate_string(0.9), "-10%", "rate -"); H.eq(edge.rate_string(1), "+0%", "rate 1")
local ssml = edge.ssml("en-US-AvaNeural", "Tom & Jerry <said> \"hi\"\11there", 1.5)
H.ok(ssml:find("<voice name='Microsoft Server Speech Text to Speech Voice (en-US, AvaNeural)'>", 1, true), "voice in ssml")
H.ok(ssml:find("rate='+50%'", 1, true), "rate in prosody")
H.ok(ssml:find("Tom &amp; Jerry &lt;said&gt; &quot;hi&quot; there", 1, true), "escaped and sanitized: " .. ssml)
local msg = edge.ssml_message("abc", 0, ssml)
H.ok(msg:find("^X%-RequestId:abc\r\nContent%-Type:application/ssml%+xml\r\nX%-Timestamp:Thu Jan 01 1970 00:00:00 GMT%+0000 %(Coordinated Universal Time%)Z\r\nPath:ssml\r\n\r\n<speak"), "ssml message headers (with the service's stray Z)")

-- Responses
local h, body = edge.parse_text_frame("X-RequestId:1\r\nPath:audio.metadata\r\n\r\n{\"Metadata\":[]}")
H.eq(h.Path, "audio.metadata", "text frame headers"); H.eq(body, '{"Metadata":[]}', "text frame body")
local header = "X-RequestId:1\r\nContent-Type:audio/mpeg\r\nPath:audio\r\n"
local bin = string.char(0, #header) .. header .. "MP3DATA"
local bh, audio = edge.parse_binary_frame(bin)
H.eq(bh.Path, "audio", "binary headers"); H.eq(bh["Content-Type"], "audio/mpeg", "content type"); H.eq(audio, "MP3DATA", "audio payload after header")
H.eq(select(2, edge.parse_binary_frame("\0")), "short binary frame", "short frame rejected")
local meta = '{"Metadata":[{"Type":"WordBoundary","Data":{"Offset":1000000,"Duration":2500000,"text":{"Text":"Tom","Length":3,"BoundaryType":"WordBoundary"}}},{"Type":"SessionEnd","Data":{}},{"Type":"WordBoundary","Data":{"Offset":4000000,"Duration":1000000,"text":{"Text":"&amp;","Length":5,"BoundaryType":"WordBoundary"}}}]}'
local words = edge.parse_metadata(meta, json.decode)
H.eq(#words, 2, "two word boundaries"); H.eq(words[1].text, "Tom", "word text"); H.near(words[1].t0, 0.1, 1e-9, "t0 seconds"); H.near(words[1].t1, 0.35, 1e-9, "t1 seconds")
H.eq(words[2].text, "&", "word text unescaped")
H.near(edge.duration(edge.FORMATS.mp3, 48000 / 8 * 10), 10, 1e-9, "mp3 duration from CBR bytes")
H.near(edge.duration(edge.FORMATS.pcm, 24000 * 2 * 3), 3, 1e-9, "pcm duration")
H.eq(edge.parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT"), 784111777, "http date -> unix time")
H.eq(edge.parse_http_date("Thu, 01 Jan 1970 00:00:00 GMT"), 0, "epoch")
H.eq(edge.parse_http_date("garbage"), nil, "bad date")

-- Synthesis over a scripted connection: config, ssml, then metadata + audio + turn.end
local ws = require("ws")
local function scripted(frames, sent_log)
    return function(url, opts)
        local i = 0
        return {
            send_text = function(_, s) sent_log[#sent_log + 1] = s; return true end,
            recv = function() i = i + 1; local f = frames[i]; if not f then return nil, "closed" end; return f[1], f[2] end,
            close = function() sent_log.closed = true end,
        }
    end
end
local sent = {}
local frames = {
    { ws.OPCODE.TEXT, "Path:turn.start\r\n\r\n{}" },
    { ws.OPCODE.TEXT, "Path:response\r\n\r\n{}" },
    { ws.OPCODE.BINARY, bin },
    { ws.OPCODE.TEXT, "Path:audio.metadata\r\n\r\n" .. meta },
    { ws.OPCODE.BINARY, string.char(0, #header) .. header .. "MORE" },
    { ws.OPCODE.BINARY, string.char(0, 24) .. "X-RequestId:1\r\nPath:audio\r\n" }, -- empty terminator
    { ws.OPCODE.TEXT, "Path:turn.end\r\n\r\n" },
}
local res, err = edge.synthesize("Tom & Jerry", { voice = "en-US-AvaNeural", connect = scripted(frames, sent), json_decode = json.decode })
H.ok(res, "synthesis ok: " .. tostring(err))
H.eq(res.audio, "MP3DATAMORE", "audio concatenated in order"); H.eq(#res.words, 2, "words collected"); H.eq(res.format, edge.FORMATS.mp3, "format reported")
H.eq(#sent, 2, "config then ssml sent"); H.ok(sent[1]:find("speech.config", 1, true) and sent[2]:find("Path:ssml", 1, true), "in that order")
H.eq(sent.closed, true, "connection closed")
-- No audio -> clear error
local none, nerr = edge.synthesize("x", { connect = scripted({ { ws.OPCODE.TEXT, "Path:turn.end\r\n\r\n" } }, {}), json_decode = json.decode, format = edge.FORMATS.pcm })
H.eq(none, nil, "no audio is an error"); H.ok(nerr:find("no audio"), "with a reason: " .. tostring(nerr))
-- The service hanging up carries its reason out of the close frame
local hung = edge.synthesize("x", { connect = function()
    return { send_text = function() return true end, close = function() end,
             recv = function() return nil, "closed", { code = 1007, reason = "Unsupported output format" } end }
end, json_decode = json.decode, format = edge.FORMATS.pcm })
H.eq(select(2, edge.synthesize("x", { connect = function()
    return { send_text = function() return true end, close = function() end,
             recv = function() return nil, "closed", { code = 1007, reason = "Unsupported output format" } end }
end, json_decode = json.decode, format = edge.FORMATS.pcm })), "the service closed the connection: 1007 Unsupported output format (format raw-24khz-16bit-mono-pcm)", "close code and reason surfaced")
H.eq(edge.is_refusal("the service closed the connection: 1007 x (format y)"), true, "a hang-up counts as a refusal (next format is tried)")
H.eq(edge.is_refusal("connection ended without audio (format y)"), true, "so does a bare drop")
H.eq(edge.is_refusal("connect: refused by proxy"), true, "'refused' matches too (harmless: the next format fails the same way fast)")
H.eq(edge.is_refusal("tls handshake: wantread"), false, "network trouble is not a refusal")
-- 403 with a Date header teaches the clock skew and retries once
local calls = 0
local skewed = function(url, opts)
    calls = calls + 1
    if calls == 1 then return nil, "upgrade refused: HTTP/1.1 403 Forbidden", { code = 403, headers = { date = "Sun, 06 Nov 1994 08:49:37 GMT" } } end
    return scripted(frames, {})(url, opts)
end
edge.clock_skew = 0
local r2 = edge.synthesize("hi", { connect = skewed, json_decode = json.decode })
H.ok(r2 and r2.audio == "MP3DATAMORE", "retried after 403"); H.eq(calls, 2, "exactly one retry")
H.ok(edge.clock_skew < -900000000, "skew learned from the server date")
edge.clock_skew = 0
local r3, e3 = edge.synthesize("hi", { connect = function() return nil, "connect: refused" end })
H.eq(r3, nil, "connect failure surfaces"); H.eq(e3, "connect: refused", "with its reason")
H.eq(select(2, edge.synthesize("   ", {})), "nothing to say", "blank text refused before connecting")
H.done("test_edge")
