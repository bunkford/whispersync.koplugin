local H = require("helpers")
local A = require("audio")
local edge = require("edge")

local function env(kindle, cmds, ffmpeg)
    local set = {}
    for _, c in ipairs(cmds) do set[c] = true end
    return { kindle = kindle, has = function(c) return set[c] == true end, ffmpeg = ffmpeg }
end

-- Plans
local k1 = A.plan(env(true, { "gst-launch-1.0", "lipc-set-prop" }))
H.eq(k1.backend, "kindle-gst", "Kindle with gst-launch-1.0 -> mixersink pipeline"); H.eq(k1.gst, "gst-launch-1.0", "1.0 chosen")
H.eq(k1.formats[1], edge.FORMATS.pcm, "asks Edge for raw PCM first"); H.eq(k1.formats[3], edge.FORMATS.mp3, "mp3 last, via Amazon's player"); H.eq(k1.latency, A.KINDLE_LATENCY, "kindle latency")
H.eq(A.player_for(k1, edge.FORMATS.pcm), "gst", "pcm -> gst"); H.eq(A.player_for(k1, edge.FORMATS.mp3), "lipc", "mp3 without ffmpeg -> lipc")
local k0 = A.plan(env(true, { "gst-launch-0.10" }, "/x/ffmpeg"))
H.eq(k0.gst, "gst-launch-0.10", "0.10 on old firmware"); H.eq(k0.formats[3], edge.FORMATS.mp3, "mp3 allowed when ffmpeg is bundled")
H.eq(A.player_for(k0, edge.FORMATS.mp3), "ffmpeg-gst", "mp3 with ffmpeg -> decode into mixersink")
local kg = A.plan(env(true, { "gst-launch-1.0" }))
H.eq(#kg.formats, 2, "gst alone: no mp3 player at all"); H.eq(select(2, A.player_for(kg, edge.FORMATS.mp3)) ~= nil, true, "mp3 refused with a reason")
-- With the bundled decoder, MP3 comes first and decodes into the PCM pipeline
local kd = A.plan({ kindle = true, has = function(c) return c == "gst-launch-1.0" or c == "lipc-set-prop" end, decoder = "/p/bin/mp3dec-armhf" })
H.eq(kd.formats[1], edge.FORMATS.mp3, "decoder on board: ask for mp3 first"); H.eq(#kd.formats, 3, "pcm and wav still listed after it")
H.eq(A.player_for(kd, edge.FORMATS.mp3), "decode-gst", "mp3 -> decode then mixersink"); H.eq(kd.decoder, "/p/bin/mp3dec-armhf", "decoder path kept")
H.eq(A.find_decoder("/nonexistent"), nil, "no decoder dir -> nil")
local kl = A.plan(env(true, { "lipc-set-prop" }))
H.eq(kl.backend, "kindle-lipc", "no gst -> Amazon's player"); H.eq(kl.formats[1], edge.FORMATS.mp3, "which wants mp3")
H.eq(A.plan(env(true, {})).backend, "none", "nothing usable -> none")
H.eq(A.plan(env(false, { "aplay", "ffplay" })).backend, "ffplay", "desktop prefers ffplay")
H.eq(A.plan(env(false, { "aplay" })).formats[1], edge.FORMATS.wav, "aplay wants wav")
H.eq(A.plan(env(false, {})).backend, "none", "desktop without players")

-- Commands
local cmd = A.command(k1, "/tmp/a.pcm", edge.FORMATS.pcm)
H.eq(cmd, "gst-launch-1.0 filesrc location='/tmp/a.pcm' ! capsfilter caps='audio/x-raw,format=S16LE,rate=24000,channels=1,layout=interleaved' ! mixersink stream-type=Music sync=true", "1.0 pipeline")
local cmd0 = A.command(k0, "/tmp/a.pcm", edge.FORMATS.pcm)
H.ok(cmd0:find("audio/x%-raw%-int,endianness=1234,signed=true,width=16,depth=16,rate=24000,channels=1"), "0.10 caps")
local cmdm = A.command(k0, "/tmp/a.mp3", edge.FORMATS.mp3, 12.5)
H.ok(cmdm:find("^'/x/ffmpeg' %-loglevel error %-nostdin %-ss 12%.50 %-i '/tmp/a%.mp3' %-f s16le %-ar 24000 %-ac 1 .* | gst%-launch%-0%.10 fdsrc ! capsfilter"), "ffmpeg decodes mp3 into the pipeline with a seek: " .. cmdm)
local k1f = A.plan(env(true, { "gst-launch-1.0" }, "/f/ffmpeg"))
H.ok(A.command(k1f, "/f.mp3", edge.FORMATS.mp3):find("fdsrc do%-timestamp=true"), "1.0 fdsrc needs timestamps")
H.eq(A.command(A.plan(env(false, { "ffplay" })), "/tmp/x y.mp3", edge.FORMATS.mp3, 3), "ffplay -nodisp -autoexit -loglevel error -ss 3.00 '/tmp/x y.mp3'", "ffplay command quotes the path")
H.ok(A.command(A.plan(env(false, { "ffplay" })), "/t.pcm", edge.FORMATS.pcm):find("%-f s16le %-ar 24000 %-ac 1 '/t%.pcm'"), "ffplay raw pcm flags")
H.ok(A.command(A.plan(env(false, { "aplay" })), "/t.pcm", edge.FORMATS.pcm):find("%-t raw %-f S16_LE %-r 24000"), "aplay raw flags")
H.eq(select(2, A.command({ backend = "none", reason = "why" }, "/f", "x")), "why", "no backend -> reason")
H.eq(A.sh_quote("it's"), "'it'\\''s'", "shell quoting")

-- Silent plan: keeps time, plays nothing
local sp = A.silent_plan()
H.eq(sp.backend, "silent", "silent backend"); H.eq(A.player_for(sp, edge.FORMATS.mp3), "silent", "any format is 'played' silently")
local sh = A.start(sp, "/nonexistent.mp3", edge.FORMATS.mp3, 2)
H.eq(sh.silent, true, "silent handle"); H.eq(A.running(sh), true, "counts as running"); H.near(A.position(sh), 2, 0.05, "position runs from the seek point")
A.stop(sh)

-- PCM padding: half a second of zeros, then the file from the seek point, then a second of zeros
local prep = A.prepare_pcm_command("/in.pcm", "/out.pcm", 2, false)
H.eq(prep, "( dd if=/dev/zero bs=24000 count=1 2>/dev/null; tail -c +96001 '/in.pcm'; dd if=/dev/zero bs=48000 count=1 2>/dev/null ) > '/out.pcm' 2>/dev/null", "padded raw file command")
H.ok(A.prepare_pcm_command("/in.wav", "/o", 0, true):find("tail %-c %+45 "), "wav header skipped")

-- Continuous stream: player commands read PCM from stdin; scheduling is gapless
H.eq(A.stream_supported(k1), true, "kindle-gst streams"); H.eq(A.stream_supported({ backend = "kindle-lipc" }), false, "lipc cannot")
H.eq(A.stream_command(k1), "gst-launch-1.0 fdsrc fd=0 do-timestamp=true ! capsfilter caps='audio/x-raw,format=S16LE,rate=24000,channels=1,layout=interleaved' ! mixersink stream-type=Music sync=true", "gst stream pipeline reads the fifo on stdin")
H.ok(A.stream_command(A.plan(env(false, { "ffplay" }))):find("%-f s16le %-ar 24000 %-ac 1 %-i pipe:0"), "ffplay stream command")
H.eq(A.stream_schedule(nil, 100, 1.7), 101.2, "first file: after the output latency minus the feeder's own lead-in")
H.eq(A.stream_schedule(130, 100, 1.7), 130, "queued behind what is already playing: no gap")
H.eq(A.stream_schedule(100.5, 100, 1.7), 101.2, "queue nearly dry: the later of the two")

-- Position accounts for seek and latency
local h = { started = A.now() - 10, seek = 5, latency = 1.5 }
H.near(A.position(h), 13.5, 0.05, "position = seek + elapsed - latency")
H.eq(#A.test_tone_pcm(0.01), 480, "test tone bytes (24000 * 0.01 * 2)")
H.done("test_audio")
