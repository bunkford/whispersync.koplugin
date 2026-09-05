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
-- ffmpeg = path or nil }. Returns { backend, gst, lipc, ffmpeg, formats, latency }.
-- `formats` are Edge output formats in the order to try; the first the
-- service honours is used, and `start` picks the player per format:
-- PCM/WAV go to GStreamer's mixersink, MP3 to ffmpeg-into-mixersink when an
-- ffmpeg binary exists, else to Amazon's player (LIPC playermgr).
function M.plan(env)
    local edge = require("edge")
    if env.kindle then
        local gst = (env.has("gst-launch-1.0") and "gst-launch-1.0") or (env.has("gst-launch-0.10") and "gst-launch-0.10") or nil
        local lipc = env.has("lipc-set-prop")
        local formats = {}
        if gst then formats[#formats + 1] = edge.FORMATS.pcm; formats[#formats + 1] = edge.FORMATS.wav end
        if (gst and env.ffmpeg) or lipc then formats[#formats + 1] = edge.FORMATS.mp3 end
        if #formats == 0 then
            return { backend = "none", formats = { edge.FORMATS.mp3 }, latency = 0, reason = "no gst-launch or lipc-set-prop on this Kindle" }
        end
        return { backend = gst and "kindle-gst" or "kindle-lipc", gst = gst, lipc = lipc, ffmpeg = env.ffmpeg,
                 formats = formats, latency = M.KINDLE_LATENCY }
    end
    for _, p in ipairs({ "ffplay", "mpv", "paplay", "aplay" }) do
        if env.has(p) then
            local formats = (p == "ffplay" or p == "mpv") and { edge.FORMATS.mp3, edge.FORMATS.wav } or { edge.FORMATS.wav, edge.FORMATS.pcm }
            return { backend = p, formats = formats, latency = M.DESKTOP_LATENCY }
        end
    end
    return { backend = "none", formats = { edge.FORMATS.mp3 }, latency = 0, reason = "no audio player found (ffplay, mpv, paplay or aplay)" }
end

--- A plan that plays nothing and just keeps time: the marker follows the
-- words at the service's timing with no speaker attached (read-along mode,
-- or a Kindle without Bluetooth on).
function M.silent_plan()
    local edge = require("edge")
    return { backend = "silent", formats = { edge.FORMATS.mp3 }, latency = 0 }
end

--- Which player handles `fmt` under this plan: "gst", "ffmpeg-gst", "lipc",
-- a desktop player name, or nil with a reason.
function M.player_for(plan, fmt)
    local edge = require("edge")
    if plan.backend == "kindle-gst" or plan.backend == "kindle-lipc" then
        if fmt == edge.FORMATS.mp3 then
            if plan.gst and plan.ffmpeg then return "ffmpeg-gst" end
            if plan.lipc then return "lipc" end
            return nil, "MP3 needs an ffmpeg binary or Amazon's player, neither is available"
        end
        if plan.gst then return "gst" end
        return nil, "raw audio needs gst-launch, which this Kindle lacks"
    end
    if plan.backend == "none" then return nil, plan.reason end
    return plan.backend -- desktop players and "silent"
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
    local player, why = M.player_for(plan, fmt)
    if not player then return nil, why end
    if player == "ffmpeg-gst" then
        -- ffmpeg decodes into the mixersink pipeline; seek is ffmpeg's -ss.
        return ("%s -loglevel error -nostdin -ss %.2f -i %s -f s16le -ar %d -ac 1 -af 'adelay=500:all=1,apad=pad_dur=1' - | %s fdsrc%s ! capsfilter caps=%s ! mixersink stream-type=Music sync=true")
            :format(sh_quote(plan.ffmpeg), seek, sh_quote(file), M.PCM_RATE, plan.gst,
                plan.gst == "gst-launch-1.0" and " do-timestamp=true" or "",
                sh_quote(M.gst_caps(plan.gst, M.PCM_RATE, 1)))
    elseif player == "gst" then
        return ("%s filesrc location=%s ! capsfilter caps=%s ! mixersink stream-type=Music sync=true")
            :format(plan.gst, sh_quote(file), sh_quote(M.gst_caps(plan.gst, M.PCM_RATE, 1)))
    elseif player == "lipc" or player == "silent" then
        return nil, player .. " has no command line"
    elseif player == "ffplay" then
        return ("ffplay -nodisp -autoexit -loglevel error -ss %.2f %s%s"):format(seek,
            fmt == edge.FORMATS.pcm and ("-f s16le -ar %d -ac 1 "):format(M.PCM_RATE) or "", sh_quote(file))
    elseif player == "mpv" then
        return ("mpv --no-video --really-quiet --start=%.2f %s%s"):format(seek,
            fmt == edge.FORMATS.pcm and ("--demuxer=rawaudio --demuxer-rawaudio-rate=%d --demuxer-rawaudio-channels=1 "):format(M.PCM_RATE) or "", sh_quote(file))
    elseif player == "paplay" then
        if fmt == edge.FORMATS.pcm then
            return ("paplay --raw --format=s16le --rate=%d --channels=1 %s"):format(M.PCM_RATE, sh_quote(file))
        end
        return "paplay " .. sh_quote(file)
    elseif player == "aplay" then
        if fmt == edge.FORMATS.pcm then
            return ("aplay -q -t raw -f S16_LE -r %d -c 1 %s"):format(M.PCM_RATE, sh_quote(file))
        end
        return "aplay -q " .. sh_quote(file)
    end
    return nil, "no player for " .. tostring(fmt)
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

--- Amazon's player, driven over LIPC. playermgr is what plays Audible on the
-- device; whether it takes an MP3 handed to it this way, and how it wants
-- the path, is only known from trying, so several shapes are tried in turn
-- (the same ones the audiobook plugin walks) and InPlayback is polled for a
-- moment after each. The failure message carries what the player reported.
function M.lipc_query(prop)
    local p = io.popen("lipc-get-prop com.lab126.playermgr " .. prop .. " 2>&1")
    local out = p and p:read("*a") or ""
    if p then p:close() end
    return (out:gsub("%s+$", ""))
end

function M.start_lipc(plan, file)
    kindle_focus()
    os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
    local uri = "file://" .. file
    local attempts = {
        { "Open+Play (path)", "lipc-set-prop com.lab126.playermgr Open " .. sh_quote(file), "lipc-set-prop com.lab126.playermgr Play ''" },
        { "Open+Play (uri)", "lipc-set-prop com.lab126.playermgr Open " .. sh_quote(uri), "lipc-set-prop com.lab126.playermgr Play ''" },
        { "Play (uri)", nil, "lipc-set-prop com.lab126.playermgr Play " .. sh_quote(uri) },
        { "Play (path)", nil, "lipc-set-prop com.lab126.playermgr Play " .. sh_quote(file) },
    }
    local seen = {}
    for _, at in ipairs(attempts) do
        if at[2] then os.execute(at[2] .. " 2>/dev/null") end
        os.execute(at[3] .. " 2>/dev/null")
        -- Give it up to ~1.5 s to spin up before deciding.
        for _ = 1, 5 do
            os.execute("usleep 300000 2>/dev/null || sleep 0.3")
            if M.lipc_query("InPlayback"):match("^%s*1") then
                return { lipc = true, started = M.now(), plan = plan, file = file, seek = 0, latency = plan.latency, player = "lipc", how = at[1] }
            end
        end
        seen[#seen + 1] = at[1] .. "=" .. M.lipc_query("InPlayback")
        os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
    end
    return nil, ("Amazon's player (playermgr) did not start playing the MP3 [%s; TTS_State=%s]. With Bluetooth off there is no output for it; pair a speaker, or use 'Follow the words without sound'.")
        :format(table.concat(seen, ", "), M.lipc_query("TTS_State"))
end

--- Start playing. Returns a handle { pid, started, plan, file } or nil, err.
-- `seek` seconds; for Kindle PCM the padded temp file is built here.
function M.start(plan, file, fmt, seek, tmpdir)
    local edge = require("edge")
    seek = seek or 0
    local player, why = M.player_for(plan, fmt)
    if not player then return nil, why end
    if player == "silent" then
        return { silent = true, started = M.now(), plan = plan, file = file, seek = seek, latency = 0, player = "silent" }
    end
    if player == "lipc" then
        return M.start_lipc(plan, file)
    end
    local play_file = file
    if player == "gst" then
        kindle_focus()
        -- Old pipelines still draining would play over the new one.
        os.execute("pkill -f 'mixersink stream-type=Music' 2>/dev/null")
        play_file = (tmpdir or "/tmp") .. "/readaloud-play.pcm"
        os.execute(M.prepare_pcm_command(file, play_file, seek, fmt == edge.FORMATS.wav))
    elseif player == "ffmpeg-gst" then
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
    return { pid = pid, started = M.now(), plan = plan, file = file, seek = seek, latency = plan.latency,
             temp = play_file ~= file and play_file or nil, player = player }
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
    if handle.silent then return true end -- the player decides by duration
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
    if handle.silent then return end
    if handle.lipc then
        os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
        return
    end
    if handle.pid then
        -- The sh wrapper and whatever it spawned (ffmpeg | gst-launch).
        os.execute("pkill -P " .. handle.pid .. " 2>/dev/null; kill " .. handle.pid .. " 2>/dev/null")
    end
    if handle.player == "gst" or handle.player == "ffmpeg-gst" then
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
