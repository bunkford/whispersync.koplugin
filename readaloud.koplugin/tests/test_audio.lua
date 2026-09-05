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
H.eq(k1.formats[1], edge.FORMATS.pcm, "asks Edge for raw PCM first"); H.eq(#k1.formats, 2, "no mp3 without a decoder"); H.eq(k1.latency, A.KINDLE_LATENCY, "kindle latency")
local k0 = A.plan(env(true, { "gst-launch-0.10" }, "/x/ffmpeg"))
H.eq(k0.gst, "gst-launch-0.10", "0.10 on old firmware"); H.eq(k0.formats[3], edge.FORMATS.mp3, "mp3 allowed when ffmpeg is bundled")
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
H.ok(A.command(k1, "/f.mp3", edge.FORMATS.mp3):find("fdsrc do%-timestamp=true"), "1.0 fdsrc needs timestamps")
H.eq(A.command(A.plan(env(false, { "ffplay" })), "/tmp/x y.mp3", edge.FORMATS.mp3, 3), "ffplay -nodisp -autoexit -loglevel error -ss 3.00 '/tmp/x y.mp3'", "ffplay command quotes the path")
H.ok(A.command(A.plan(env(false, { "ffplay" })), "/t.pcm", edge.FORMATS.pcm):find("%-f s16le %-ar 24000 %-ac 1 '/t%.pcm'"), "ffplay raw pcm flags")
H.ok(A.command(A.plan(env(false, { "aplay" })), "/t.pcm", edge.FORMATS.pcm):find("%-t raw %-f S16_LE %-r 24000"), "aplay raw flags")
H.eq(select(2, A.command({ backend = "none", reason = "why" }, "/f", "x")), "why", "no backend -> reason")
H.eq(A.sh_quote("it's"), "'it'\\''s'", "shell quoting")

-- PCM padding: half a second of zeros, then the file from the seek point, then a second of zeros
local prep = A.prepare_pcm_command("/in.pcm", "/out.pcm", 2, false)
H.eq(prep, "( dd if=/dev/zero bs=24000 count=1 2>/dev/null; tail -c +96001 '/in.pcm'; dd if=/dev/zero bs=48000 count=1 2>/dev/null ) > '/out.pcm' 2>/dev/null", "padded raw file command")
H.ok(A.prepare_pcm_command("/in.wav", "/o", 0, true):find("tail %-c %+45 "), "wav header skipped")

-- Position accounts for seek and latency
local h = { started = A.now() - 10, seek = 5, latency = 1.5 }
H.near(A.position(h), 13.5, 0.05, "position = seek + elapsed - latency")
H.eq(#A.test_tone_pcm(0.01), 480, "test tone bytes (24000 * 0.01 * 2)")
H.done("test_audio")
