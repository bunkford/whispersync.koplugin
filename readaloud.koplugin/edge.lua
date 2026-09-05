--[[--
Microsoft Edge read-aloud voices, spoken to directly from the device.

This is the same service the Edge browser's "Read aloud" uses (and that the
edge-tts project documents): a WebSocket at speech.platform.bing.com that
takes SSML and streams back audio plus, when asked, a WordBoundary event for
every word with its offset into the audio in 100-nanosecond ticks. Those
events are what make word-exact highlighting possible: nothing is guessed.

The service is unofficial and quota-less: it wants a browser-like set of
headers, a ConnectionId, and since late 2024 a Sec-MS-GEC token — the
SHA-256 of the current time in Windows file-time ticks (rounded down to five
minutes) concatenated with a fixed client token. A device clock that is off
by more than a few minutes gets a 403; the Date header of that refusal tells
us the skew, and one retry with it applied succeeds.

Everything that shapes or parses a message is a pure function here, tested
offline; `synthesize` strings them together over a live socket.
]]

local M = {}

M.TRUSTED_CLIENT_TOKEN = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
M.HOST = "speech.platform.bing.com"
M.PATH = "/consumer/speech/synthesize/readaloud/edge/v1"
M.CHROMIUM_FULL_VERSION = "143.0.3650.75"
M.CHROMIUM_MAJOR_VERSION = M.CHROMIUM_FULL_VERSION:match("^(%d+)")
M.SEC_MS_GEC_VERSION = "1-" .. M.CHROMIUM_FULL_VERSION
M.USER_AGENT = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s.0.0.0 Safari/537.36 Edg/%s.0.0.0")
    :format(M.CHROMIUM_MAJOR_VERSION, M.CHROMIUM_MAJOR_VERSION)
M.WIN_EPOCH = 11644473600
M.TICKS_PER_SECOND = 10000000

-- Output formats. MP3 is what Edge itself uses and is always accepted; the
-- raw PCM formats are what a Kindle can play without a decoder, and the
-- plugin probes whether the service will hand them out.
M.FORMATS = {
    mp3 = "audio-24khz-48kbitrate-mono-mp3",
    pcm = "raw-24khz-16bit-mono-pcm",
    wav = "riff-24khz-16bit-mono-pcm",
}
M.MP3_BITRATE_BPS = 48000
M.PCM_RATE = 24000

-- A useful subset of the English voices (short names; the full name is
-- derived). The service has ~30 English voices; the settings menu also
-- takes a typed name.
M.VOICES = {
    { "en-US-AndrewNeural", "Andrew (US, male)" },
    { "en-US-BrianNeural", "Brian (US, male)" },
    { "en-US-ChristopherNeural", "Christopher (US, male)" },
    { "en-US-GuyNeural", "Guy (US, male)" },
    { "en-US-EricNeural", "Eric (US, male)" },
    { "en-US-RogerNeural", "Roger (US, male)" },
    { "en-US-SteffanNeural", "Steffan (US, male)" },
    { "en-US-AvaNeural", "Ava (US, female)" },
    { "en-US-EmmaNeural", "Emma (US, female)" },
    { "en-US-JennyNeural", "Jenny (US, female)" },
    { "en-US-AriaNeural", "Aria (US, female)" },
    { "en-US-MichelleNeural", "Michelle (US, female)" },
    { "en-US-AnaNeural", "Ana (US, child)" },
    { "en-GB-RyanNeural", "Ryan (UK, male)" },
    { "en-GB-ThomasNeural", "Thomas (UK, male)" },
    { "en-GB-SoniaNeural", "Sonia (UK, female)" },
    { "en-GB-LibbyNeural", "Libby (UK, female)" },
    { "en-GB-MaisieNeural", "Maisie (UK, child)" },
    { "en-AU-WilliamNeural", "William (Australia, male)" },
    { "en-AU-NatashaNeural", "Natasha (Australia, female)" },
    { "en-CA-LiamNeural", "Liam (Canada, male)" },
    { "en-CA-ClaraNeural", "Clara (Canada, female)" },
    { "en-IE-ConnorNeural", "Connor (Ireland, male)" },
    { "en-IE-EmilyNeural", "Emily (Ireland, female)" },
    { "en-IN-PrabhatNeural", "Prabhat (India, male)" },
    { "en-IN-NeerjaNeural", "Neerja (India, female)" },
    { "en-NZ-MitchellNeural", "Mitchell (New Zealand, male)" },
    { "en-NZ-MollyNeural", "Molly (New Zealand, female)" },
    { "en-ZA-LukeNeural", "Luke (South Africa, male)" },
    { "en-ZA-LeahNeural", "Leah (South Africa, female)" },
}
M.DEFAULT_VOICE = "en-US-AndrewNeural"

-------------------------------------------------------------------------------
-- hashing and ids
-------------------------------------------------------------------------------

local sha256_impl
local function sha256_hex(s)
    if sha256_impl == nil then
        local ok, sha = pcall(require, "ffi/sha2")
        if ok and type(sha) == "table" and sha.sha256 then
            sha256_impl = function(str) return sha.sha256(str) end
        else
            sha256_impl = false
        end
    end
    if sha256_impl then return sha256_impl(s) end
    -- Last resort: the sha256sum binary (busybox has it).
    local tmp = os.tmpname()
    local f = io.open(tmp, "wb"); f:write(s); f:close()
    local p = io.popen("sha256sum " .. tmp .. " 2>/dev/null")
    local out = p and p:read("*a") or ""
    if p then p:close() end
    os.remove(tmp)
    local hex = out:match("^(%x+)")
    if not hex then error("no SHA-256 implementation available") end
    return hex
end
M.sha256_hex = sha256_hex

--- Sec-MS-GEC for a Unix time (seconds). Pure: the same input always gives
-- the same token, which is what the tests check against a Python oracle.
function M.gec(now)
    local ticks = math.floor(now + M.WIN_EPOCH)
    ticks = ticks - ticks % 300
    -- Windows file time is 100 ns units: append seven zeros rather than
    -- multiply, so the 64-bit value never touches a double.
    local str = tostring(ticks) .. "0000000" .. M.TRUSTED_CLIENT_TOKEN
    return sha256_hex(str):upper()
end

local HEX = "0123456789abcdef"
--- 32 lowercase hex characters (a UUID without dashes), random.
function M.connect_id(rand)
    rand = rand or require("ws").random_bytes(16)
    local out = {}
    for i = 1, #rand do
        local b = rand:byte(i)
        out[#out + 1] = HEX:sub(math.floor(b / 16) + 1, math.floor(b / 16) + 1) .. HEX:sub(b % 16 + 1, b % 16 + 1)
    end
    return table.concat(out)
end

--- The URL for one connection.
function M.url(conn_id, now)
    return ("wss://%s%s?TrustedClientToken=%s&Sec-MS-GEC=%s&Sec-MS-GEC-Version=%s&ConnectionId=%s")
        :format(M.HOST, M.PATH, M.TRUSTED_CLIENT_TOKEN, M.gec(now), M.SEC_MS_GEC_VERSION, conn_id)
end

--- Handshake headers, as an ordered list.
function M.headers()
    return {
        { "Pragma", "no-cache" },
        { "Cache-Control", "no-cache" },
        { "Origin", "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold" },
        { "User-Agent", M.USER_AGENT },
        { "Accept-Encoding", "gzip, deflate, br, zstd" },
        { "Accept-Language", "en-US,en;q=0.9" },
    }
end

-------------------------------------------------------------------------------
-- messages
-------------------------------------------------------------------------------

local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

--- JavaScript-style UTC date string the service expects in X-Timestamp.
function M.date_string(now)
    local t = os.date("!*t", math.floor(now))
    return ("%s %s %02d %04d %02d:%02d:%02d GMT+0000 (Coordinated Universal Time)")
        :format(DAYS[t.wday], MONTHS[t.month], t.day, t.year, t.hour, t.min, t.sec)
end

function M.speech_config(now, format)
    return "X-Timestamp:" .. M.date_string(now) .. "\r\n"
        .. "Content-Type:application/json; charset=utf-8\r\n"
        .. "Path:speech.config\r\n\r\n"
        .. '{"context":{"synthesis":{"audio":{"metadataoptions":{'
        .. '"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"true"'
        .. '},"outputFormat":"' .. (format or M.FORMATS.mp3) .. '"}}}}\r\n'
end

--- The service's full voice name from a short one like en-US-AndrewNeural.
function M.full_voice_name(voice)
    if voice:find("^Microsoft Server Speech") then return voice end
    local lang, region, name = voice:match("^(%a%a+)%-(%u%u+)%-(.+Neural)$")
    if lang then
        return ("Microsoft Server Speech Text to Speech Voice (%s-%s, %s)"):format(lang, region, name)
    end
    return voice
end

function M.xml_escape(s)
    return (s:gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&apos;" }))
end

function M.xml_unescape(s)
    return (s:gsub("&(%w+);", { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }))
end

--- The service rejects control characters (vertical tab especially, common
-- in OCR'd text); they become spaces.
function M.sanitize(text)
    return (text:gsub("[%z\1-\8\11\12\14-\31]", " "))
end

--- Signed percent strings for prosody: 1.25 -> "+25%", 0.9 -> "-10%".
function M.rate_string(speed)
    local pct = math.floor((tonumber(speed) or 1) * 100 + 0.5) - 100
    return (pct >= 0 and "+" or "") .. tostring(pct) .. "%"
end

function M.ssml(voice, text, speed, pitch)
    return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
        .. "<voice name='" .. M.full_voice_name(voice) .. "'>"
        .. "<prosody pitch='" .. (pitch or "+0Hz") .. "' rate='" .. M.rate_string(speed) .. "' volume='+0%'>"
        .. M.xml_escape(M.sanitize(text))
        .. "</prosody></voice></speak>"
end

function M.ssml_message(request_id, now, ssml)
    return "X-RequestId:" .. request_id .. "\r\n"
        .. "Content-Type:application/ssml+xml\r\n"
        .. "X-Timestamp:" .. M.date_string(now) .. "Z\r\n" -- the trailing Z is the service's own quirk
        .. "Path:ssml\r\n\r\n" .. ssml
end

-------------------------------------------------------------------------------
-- responses
-------------------------------------------------------------------------------

local function parse_headers(block)
    local h = {}
    for line in block:gmatch("([^\r\n]+)") do
        local k, v = line:match("^([^:]+):(.*)$")
        if k then h[k] = v end
    end
    return h
end

--- A text frame: "Header:value\r\n...\r\n\r\nbody" -> headers, body.
function M.parse_text_frame(s)
    local head, body = s:match("^(.-)\r\n\r\n(.*)$")
    if not head then return parse_headers(s), "" end
    return parse_headers(head), body
end

--- A binary frame: 2-byte big-endian header length, the headers, the audio.
function M.parse_binary_frame(s)
    if #s < 2 then return nil, "short binary frame" end
    local hl = s:byte(1) * 256 + s:byte(2)
    if hl + 2 > #s then return nil, "binary frame shorter than its header length" end
    local headers = parse_headers(s:sub(3, 2 + hl))
    return headers, s:sub(hl + 3)
end

--- Word boundaries from an audio.metadata body. Each: { text, t0, t1 } in seconds.
function M.parse_metadata(body, json_decode)
    local data = json_decode(body)
    local out = {}
    if type(data) ~= "table" or type(data.Metadata) ~= "table" then return out end
    for _, m in ipairs(data.Metadata) do
        if m.Type == "WordBoundary" and type(m.Data) == "table" then
            local off = tonumber(m.Data.Offset) or 0
            local dur = tonumber(m.Data.Duration) or 0
            local text = type(m.Data.text) == "table" and m.Data.text.Text or ""
            out[#out + 1] = {
                text = M.xml_unescape(tostring(text)),
                t0 = off / M.TICKS_PER_SECOND,
                t1 = (off + dur) / M.TICKS_PER_SECOND,
            }
        end
    end
    return out
end

--- Audio duration in seconds from the byte count, for the formats we ask for.
function M.duration(format, nbytes)
    if format == M.FORMATS.pcm then return nbytes / (M.PCM_RATE * 2) end
    if format == M.FORMATS.wav then return math.max(0, nbytes - 44) / (M.PCM_RATE * 2) end
    return nbytes * 8 / M.MP3_BITRATE_BPS
end

--- Parse an RFC 2616 date ("Sun, 06 Nov 1994 08:49:37 GMT") to Unix time.
function M.parse_http_date(s)
    if type(s) ~= "string" then return nil end
    local d, mon, y, hh, mm, ss = s:match("^%a+, (%d+) (%a+) (%d+) (%d+):(%d+):(%d+)")
    if not d then return nil end
    local mi
    for i, m in ipairs(MONTHS) do if m == mon then mi = i end end
    if not mi then return nil end
    -- Days since epoch, civil-from-days (Howard Hinnant), avoiding os.time's local zone.
    y, mi, d = tonumber(y), mi, tonumber(d)
    local yy = mi <= 2 and y - 1 or y
    local era = math.floor(yy / 400)
    local yoe = yy - era * 400
    local doy = math.floor((153 * (mi + (mi > 2 and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + tonumber(hh) * 3600 + tonumber(mm) * 60 + tonumber(ss)
end

-------------------------------------------------------------------------------
-- synthesis
-------------------------------------------------------------------------------

M.clock_skew = 0   -- seconds to add to the local clock; learned from a 403

M.FIRST_TIMEOUT = 12   -- seconds to wait for the service's first message

--- Is this error the service declining the request (as opposed to the
-- network failing)? A format the service does not support gets either
-- silence until our timeout or a turn that ends without audio.
function M.is_refusal(err)
    err = tostring(err or "")
    return err:find("no audio", 1, true) ~= nil or err:find("refused", 1, true) ~= nil
        or err:find("did not answer", 1, true) ~= nil or err:find("without audio", 1, true) ~= nil
        or err:find("closed the connection", 1, true) ~= nil
end

--- Speak `text`. opts: voice, speed (1.0), format (M.FORMATS.*), timeout
-- (per read, default 30), first_timeout (wait for the first message,
-- default M.FIRST_TIMEOUT), json_decode (function), connect (ws.connect
-- replacement for tests).
-- Returns { audio = string, words = {{text,t0,t1}}, format, duration, took }
-- or nil, reason.
function M.synthesize(text, opts)
    opts = opts or {}
    local ws = require("ws")
    local connect = opts.connect or ws.connect
    local json_decode = opts.json_decode or M.json_decode
    local format = opts.format or M.FORMATS.mp3
    local voice = opts.voice or M.DEFAULT_VOICE
    text = M.sanitize(text or "")
    if text:match("^%s*$") then return nil, "nothing to say" end
    local t_start = os.time()

    local attempts = 0
    while true do
        attempts = attempts + 1
        local now = os.time() + M.clock_skew
        local conn, err, resp = connect(M.url(M.connect_id(), now), { headers = M.headers(), timeout = opts.timeout or 30 })
        if conn then
            local audio, words, closed_ok = {}, {}, false
            local ok, serr = conn:send_text(M.speech_config(now, format))
            if ok then ok, serr = conn:send_text(M.ssml_message(M.connect_id(), now, M.ssml(voice, text, opts.speed, opts.pitch))) end
            if not ok then conn:close(); return nil, "send: " .. tostring(serr) end
            local first = true
            local close_info
            while true do
                local opcode, payload, info = conn:recv(first and (opts.first_timeout or M.FIRST_TIMEOUT) or nil)
                if not opcode then
                    if payload == "closed" then close_info = info or {}; break end
                    conn:close()
                    if payload == "timeout" then
                        if first then
                            return nil, ("the service did not answer within %d s (format %s refused?)"):format(opts.first_timeout or M.FIRST_TIMEOUT, format)
                        end
                        return nil, "the service stopped mid-stream (timeout)"
                    end
                    return nil, "receive: " .. tostring(payload)
                end
                first = false
                if opcode == ws.OPCODE.TEXT then
                    local headers, body = M.parse_text_frame(payload)
                    local path = headers.Path
                    if path == "audio.metadata" then
                        for _, w in ipairs(M.parse_metadata(body, json_decode)) do words[#words + 1] = w end
                    elseif path == "turn.end" then
                        closed_ok = true
                        break
                    end
                elseif opcode == ws.OPCODE.BINARY then
                    local headers, data = M.parse_binary_frame(payload)
                    if headers and headers.Path == "audio" and data and #data > 0 then
                        audio[#audio + 1] = data
                    end
                end
            end
            conn:close()
            local bytes = table.concat(audio)
            if #bytes == 0 then
                if closed_ok then return nil, "the service sent no audio (format " .. format .. " refused?)" end
                if close_info and close_info.code then
                    return nil, ("the service closed the connection: %d %s (format %s)"):format(close_info.code,
                        (close_info.reason and close_info.reason ~= "") and close_info.reason or "no reason given", format)
                end
                return nil, "connection ended without audio (format " .. format .. ")"
            end
            table.sort(words, function(a, b) return a.t0 < b.t0 end)
            return { audio = bytes, words = words, format = format, duration = M.duration(format, #bytes), voice = voice,
                     took = os.time() - t_start }
        end
        -- A 403 with a Date header means our clock is off: learn the skew, retry once.
        local date = resp and resp.headers and resp.headers.date
        local server_now = M.parse_http_date(date)
        if attempts == 1 and resp and resp.code == 403 and server_now then
            M.clock_skew = server_now - os.time()
        else
            return nil, err
        end
    end
end

-- JSON (KOReader ships dkjson as "json"; tests provide their own)
function M.json_decode(s)
    local ok, json = pcall(require, "json")
    if not ok then ok, json = pcall(require, "rapidjson") end
    if not ok or not json then error("no JSON library") end
    local dok, v = pcall(json.decode, s)
    return dok and v or nil
end

return M
