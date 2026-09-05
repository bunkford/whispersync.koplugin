--[[--
Getting sound out of the device.

Kindle firmware has no ALSA and no PulseAudio; Bluetooth audio goes through
Amazon's audiomgrd, and the one userspace way in that is known to work from
KOReader is GStreamer's `mixersink` element, driven with the stock
gst-launch binary (0.10 on older firmware, 1.0 on newer) — the path the
audiobook.koplugin project established on Paperwhite 5/6. That sink takes
raw PCM only: Kindle's GStreamer ships no MP3 decoder. So on Kindle this
plugin asks the Edge service for raw PCM and hands it straight to mixersink;
if the service ever refuses that format, an MP3 can still be played through
Amazon's own player (LIPC playermgr), or decoded by an ffmpeg binary when
one is around (the audiobook plugin bundles one).

On a desktop, the usual players are used, which is how this is tested by ear.

`plan` and the command builders are pure; `start`/`stop` run things.
]]

local M = {}

M.KINDLE_LATENCY = 1.7      -- lead-in pad + mixer ring + BT chain, seconds
M.DESKTOP_LATENCY = 0.3
M.PCM_RATE = 24000

-------------------------------------------------------------------------------
-- pure: what to do given what exists
-------------------------------------------------------------------------------

local function sh_quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
M.sh_quote = sh_quote

--- Decide the playback plan. `env` = { kindle = bool, has = function(cmd) -> bool,
-- ffmpeg = path or nil }. Returns { backend, formats = {preferred..}, latency }.
-- `formats` are Edge output formats in the order to try: the first the
-- service honours is used.
function M.plan(env)
    local edge = require("edge")
    if env.kindle then
        local gst = (env.has("gst-launch-1.0") and "gst-launch-1.0") or (env.has("gst-launch-0.10") and "gst-launch-0.10") or nil
        if gst then
            local formats = { edge.FORMATS.pcm, edge.FORMATS.wav }
            if env.ffmpeg then formats[#formats + 1] = edge.FORMATS.mp3 end
            return { backend = "kindle-gst", gst = gst, ffmpeg = env.ffmpeg, formats = formats, latency = M.KINDLE_LATENCY }
        end
        if env.has("lipc-set-prop") then
            return { backend = "kindle-lipc", formats = { edge.FORMATS.mp3, edge.FORMATS.wav }, latency = M.KINDLE_LATENCY }
        end
        return { backend = "none", formats = { edge.FORMATS.mp3 }, latency = 0, reason = "no gst-launch or lipc-set-prop on this Kindle" }
    end
    for _, p in ipairs({ "ffplay", "mpv", "paplay", "aplay" }) do
        if env.has(p) then
            local formats = (p == "ffplay" or p == "mpv") and { edge.FORMATS.mp3, edge.FORMATS.wav } or { edge.FORMATS.wav, edge.FORMATS.pcm }
            return { backend = p, formats = formats, latency = M.DESKTOP_LATENCY }
        end
    end
    return { backend = "none", formats = { edge.FORMATS.mp3 }, latency = 0, reason = "no audio player found (ffplay, mpv, paplay or aplay)" }
end

--- GStreamer caps for our PCM, per gst generation.
function M.gst_caps(gst, rate, channels)
    if gst == "gst-launch-0.10" then
        return ("audio/x-raw-int,endianness=1234,signed=true,width=16,depth=16,rate=%d,channels=%d"):format(rate, channels)
    end
    return ("audio/x-raw,format=S16LE,rate=%d,channels=%d,layout=interleaved"):format(rate, channels)
end

--- Shell command that plays `file` (already raw PCM / WAV / MP3 as `fmt`
-- says) and blocks until done. `seek` seconds into the file.
-- For Kindle PCM the caller pads the raw file (see `prepare_pcm`).
function M.command(plan, file, fmt, seek)
    local edge = require("edge")
    seek = seek or 0
    if plan.backend == "kindle-gst" then
        if fmt == edge.FORMATS.mp3 then
            -- ffmpeg decodes into the same pipeline; seek is ffmpeg's -ss.
            return ("%s -loglevel error -nostdin -ss %.2f -i %s -f s16le -ar %d -ac 1 -af 'adelay=500:all=1,apad=pad_dur=1' - | %s fdsrc%s ! capsfilter caps=%s ! mixersink stream-type=Music sync=true")
                :format(sh_quote(plan.ffmpeg), seek, sh_quote(file), M.PCM_RATE, plan.gst,
                    plan.gst == "gst-launch-1.0" and " do-timestamp=true" or "",
                    sh_quote(M.gst_caps(plan.gst, M.PCM_RATE, 1)))
        end
        return ("%s filesrc location=%s ! capsfilter caps=%s ! mixersink stream-type=Music sync=true")
            :format(plan.gst, sh_quote(file), sh_quote(M.gst_caps(plan.gst, M.PCM_RATE, 1)))
    elseif plan.backend == "ffplay" then
        return ("ffplay -nodisp -autoexit -loglevel error -ss %.2f %s%s"):format(seek,
            fmt == edge.FORMATS.pcm and ("-f s16le -ar %d -ac 1 "):format(M.PCM_RATE) or "", sh_quote(file))
    elseif plan.backend == "mpv" then
        return ("mpv --no-video --really-quiet --start=%.2f %s%s"):format(seek,
            fmt == edge.FORMATS.pcm and ("--demuxer=rawaudio --demuxer-rawaudio-rate=%d --demuxer-rawaudio-channels=1 "):format(M.PCM_RATE) or "", sh_quote(file))
    elseif plan.backend == "paplay" then
        if fmt == edge.FORMATS.pcm then
            return ("paplay --raw --format=s16le --rate=%d --channels=1 %s"):format(M.PCM_RATE, sh_quote(file))
        end
        return "paplay " .. sh_quote(file)
    elseif plan.backend == "aplay" then
        if fmt == edge.FORMATS.pcm then
            return ("aplay -q -t raw -f S16_LE -r %d -c 1 %s"):format(M.PCM_RATE, sh_quote(file))
        end
        return "aplay -q " .. sh_quote(file)
    end
    return nil, plan.reason or "no backend"
end

--- Shell command that writes the padded raw PCM the Kindle pipeline wants:
-- half a second of silence up front (audiomgrd wakes the A2DP link late and
-- eats the start), the file from `seek` seconds in, and a second of silence
-- at the end (the ring buffer is torn down before it drains). `wav` skips
-- the 44-byte RIFF header.
function M.prepare_pcm_command(src, dst, seek, wav)
    local frame = 2 -- bytes per sample, mono 16-bit
    local skip = (wav and 44 or 0) + math.floor((seek or 0) * M.PCM_RATE) * frame
    return ("( dd if=/dev/zero bs=%d count=1 2>/dev/null; tail -c +%d %s; dd if=/dev/zero bs=%d count=1 2>/dev/null ) > %s 2>/dev/null")
        :format(math.floor(M.PCM_RATE / 2) * frame, skip + 1, sh_quote(src), M.PCM_RATE * frame, sh_quote(dst))
end

M.LEAD_IN = 0.5   -- seconds of silence prepare_pcm_command prepends

-------------------------------------------------------------------------------
-- runtime
-------------------------------------------------------------------------------

function M.has_command(cmd)
    local p = io.popen("command -v " .. sh_quote(cmd) .. " 2>/dev/null")
    if not p then return false end
    local out = p:read("*a") or ""
    p:close()
    return out:match("%S") ~= nil
end

--- Look for an ffmpeg binary: on PATH, or bundled by the audiobook plugin.
function M.find_ffmpeg(plugin_dir)
    if M.has_command("ffmpeg") then return "ffmpeg" end
    local candidates = {}
    if plugin_dir then
        candidates[#candidates + 1] = plugin_dir .. "/../audiobook.koplugin/bin/ffmpeg"
        candidates[#candidates + 1] = plugin_dir .. "/bin/ffmpeg"
    end
    for _, c in ipairs(candidates) do
        local f = io.open(c, "rb")
        if f then f:close(); return c end
    end
    return nil
end

--- The plan for this device.
function M.detect(is_kindle, plugin_dir)
    return M.plan({ kindle = is_kindle, has = M.has_command, ffmpeg = M.find_ffmpeg(plugin_dir) })
end

local focus_taken = false
local function kindle_focus()
    if focus_taken then return end
    os.execute("lipc-set-prop com.lab126.audiomgrd setFocus 'Music' 2>/dev/null")
    focus_taken = true
end

--- Start playing. Returns a handle { pid, started, plan, file } or nil, err.
-- `seek` seconds; for Kindle PCM the padded temp file is built here.
function M.start(plan, file, fmt, seek, tmpdir)
    local edge = require("edge")
    seek = seek or 0
    if plan.backend == "none" then return nil, plan.reason end
    if plan.backend == "kindle-lipc" then
        kindle_focus()
        os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
        os.execute("lipc-set-prop com.lab126.playermgr Open " .. sh_quote(file) .. " 2>/dev/null")
        os.execute("lipc-set-prop com.lab126.playermgr Play '' 2>/dev/null")
        local p = io.popen("lipc-get-prop com.lab126.playermgr InPlayback 2>/dev/null")
        local out = p and p:read("*a") or ""
        if p then p:close() end
        if not out:match("^%s*1") then return nil, "playermgr did not start playback" end
        return { lipc = true, started = M.now(), plan = plan, file = file, seek = 0, latency = plan.latency }
    end
    local play_file = file
    local latency = plan.latency
    if plan.backend == "kindle-gst" and fmt ~= edge.FORMATS.mp3 then
        kindle_focus()
        -- Old pipelines still draining would play over the new one.
        os.execute("pkill -f 'mixersink stream-type=Music' 2>/dev/null")
        play_file = (tmpdir or "/tmp") .. "/readaloud-play.pcm"
        os.execute(M.prepare_pcm_command(file, play_file, seek, fmt == edge.FORMATS.wav))
    elseif plan.backend == "kindle-gst" then
        kindle_focus()
        os.execute("pkill -f 'mixersink stream-type=Music' 2>/dev/null")
    end
    local cmd, cerr = M.command(plan, play_file, fmt, seek)
    if not cmd then return nil, cerr end
    local p = io.popen("sh -c " .. sh_quote(cmd .. " >/dev/null 2>&1") .. " & echo $!")
    if not p then return nil, "cannot spawn player" end
    local pid = tonumber((p:read("*a") or ""):match("%d+"))
    p:close()
    if not pid then return nil, "player did not start" end
    return { pid = pid, started = M.now(), plan = plan, file = file, seek = seek, latency = latency, temp = play_file ~= file and play_file or nil }
end

--- Monotonic-ish clock in seconds (socket.gettime when there is one).
function M.now()
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.gettime then return socket.gettime() end
    return os.time()
end

--- Seconds of audio the listener has heard so far (already corrected for
-- the lead-in and the device's output latency).
function M.position(handle)
    if not handle then return 0 end
    local started = handle.started or M.now()
    return (handle.seek or 0) + (M.now() - started) - (handle.latency or 0)
end

function M.running(handle)
    if not handle then return false end
    if handle.lipc then
        local p = io.popen("lipc-get-prop com.lab126.playermgr InPlayback 2>/dev/null")
        local out = p and p:read("*a") or ""
        if p then p:close() end
        return out:match("^%s*1") ~= nil
    end
    if not handle.pid then return false end
    local ok = os.execute("kill -0 " .. handle.pid .. " 2>/dev/null")
    return ok == 0 or ok == true
end

function M.stop(handle)
    if not handle then return end
    if handle.lipc then
        os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
        return
    end
    if handle.pid then
        -- The sh wrapper and whatever it spawned (ffmpeg | gst-launch).
        os.execute("pkill -P " .. handle.pid .. " 2>/dev/null; kill " .. handle.pid .. " 2>/dev/null")
    end
    if handle.plan and handle.plan.backend == "kindle-gst" then
        os.execute("pkill -f 'mixersink stream-type=Music' 2>/dev/null")
    end
    if handle.temp then os.remove(handle.temp) end
end

--- A short test tone (1 s, 440 Hz) as raw PCM, for "is anything coming out?".
function M.test_tone_pcm(seconds)
    seconds = seconds or 1
    local n = math.floor(M.PCM_RATE * seconds)
    local out = {}
    for i = 0, n - 1 do
        local v = math.floor(math.sin(2 * math.pi * 440 * i / M.PCM_RATE) * 12000 + 0.5)
        if v < 0 then v = v + 65536 end
        out[#out + 1] = string.char(v % 256, math.floor(v / 256))
    end
    return table.concat(out)
end

return M
