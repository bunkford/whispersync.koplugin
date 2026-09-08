local H = require("helpers")
local stubs = require("kostubs")
local fakedoc = require("fakedoc")
local Player = require("player")
local audio = require("audio")
local edge = require("edge")
local segment = require("segment")

-- A 30-word book: 6 sentences of 5 words, pages of 10 words.
local words = {}
for i = 1, 30 do words[i] = "w" .. i .. (i % 5 == 0 and "." or "") end
local sentences = {}
for s = 0, 5 do sentences[#sentences + 1] = { s * 5 + 1, s * 5 + 5 } end
local doc = fakedoc(words, sentences, { 1, 10 })
local turned = {}
local ui = { document = doc, rolling = { onGotoXPointer = function(_, xp) turned[#turned + 1] = xp; doc.page = { tonumber(xp:match("%d+")), tonumber(xp:match("%d+")) + 9 } end },
             view = { registerViewModule = function() end }, dialog = "dlg" }

-- Fake Edge: each word takes 0.5 s, spoken word list mirrors the text.
local synth_calls = {}
edge.synthesize = function(text, opts)
    synth_calls[#synth_calls + 1] = { text = text, format = opts.format }
    if opts.format == edge.FORMATS.pcm then return nil, "the service sent no audio (format refused?)" end
    local ws = {}
    local t = 0
    for w in text:gmatch("%S+") do ws[#ws + 1] = { text = w:gsub("%.", ""), t0 = t, t1 = t + 0.4 }; t = t + 0.5 end
    return { audio = string.rep("x", 6000 * t), words = ws, format = opts.format, duration = t }
end
-- Fake audio: a clock we control.
local clock = 0
local started = {}
audio.now = function() return clock end
audio.start = function(plan, file, fmt, seek) started[#started + 1] = { file = file, fmt = fmt, seek = seek }; return { started = clock, seek = seek, latency = 0, plan = plan, file = file } end
audio.stop = function() end
audio.running = function() return true end

local hl_calls = {}
local highlight = { show = function(_, a, b) hl_calls[#hl_calls + 1] = { a, b }; return "shown" end, clear = function() hl_calls.cleared = true end }
local states = {}
local logs = {}
local remembered = {}
local p = Player.new{
    on_format = function(f) remembered[#remembered + 1] = f end,
    ui = ui,
    settings = function() return { voice = "en-US-AndrewNeural", speed = 1, highlight = "word" } end,
    plan = { backend = "ffplay", formats = { edge.FORMATS.pcm, edge.FORMATS.mp3 }, latency = 0 },
    tmpdir = os.getenv("TMPDIR") or "/tmp",
    highlight = highlight,
    log = function(m) logs[#logs + 1] = m end,
    notify = function(m) logs[#logs + 1] = "NOTIFY " .. m end,
    on_state = function(s) states[#states + 1] = s end,
    uimanager = stubs["ui/uimanager"],
    json_decode = require("json").decode,
}
segment.MAX_UTTERANCE_BYTES = 40   -- ~2 sentences per utterance for this test
segment.MAX_UTTERANCE_SENTENCES = 2

H.ok(p:start("1s"), "start from the first word")
H.eq(p.state, "preparing", "waits for audio first")
H.eq(#p.utterances, 1, "start walks one group only; the tick adds the rest")
H.eq(p.utterances[1].text, "w1 w2 w3 w4 w5. w6 w7 w8 w9 w10.", "first utterance is two sentences")
-- First tick: the (inline) fetch has run; collect -> ready -> playing
p:tick()
H.eq(p.state, "playing", "playing after the first tick")
H.ok(#p.utterances >= 2, "a second group walked on the tick: " .. #p.utterances)
H.eq(#started, 1, "audio started once"); H.eq(started[1].fmt, edge.FORMATS.mp3, "fell back to mp3 after pcm was refused")
H.eq(synth_calls[1].format, edge.FORMATS.pcm, "asked for pcm first"); H.eq(synth_calls[2].format, edge.FORMATS.mp3, "then mp3")
H.eq(p.format_index, 2, "remembers the format that worked")
H.eq(remembered[1], edge.FORMATS.mp3, "and tells the plugin so it can persist it")
-- A player created with the remembered format asks for it first
local p_mem = Player.new{ ui = ui, settings = function() return { voice = "v", speed = 1, format = edge.FORMATS.mp3 } end,
    plan = { backend = "ffplay", formats = { edge.FORMATS.pcm, edge.FORMATS.mp3 }, latency = 0 }, uimanager = stubs["ui/uimanager"] }
H.eq(p_mem.format_index, 2, "remembered format goes first next session")
H.eq(#hl_calls, 1, "first word marked at t=0"); H.eq(hl_calls[1][1], "1s", "it is w1")
clock = 0.6
p:tick()
H.eq(hl_calls[#hl_calls][1], "2s", "second word at t=0.6")
H.ok(synth_calls[#synth_calls].format == edge.FORMATS.mp3, "prefetch of the next utterance asks mp3 straight away")
clock = 2.6
p:tick()
H.eq(hl_calls[#hl_calls][1], "6s", "sixth word (second sentence) at t=2.6")
-- End of the utterance (10 words * 0.5 = 5 s) -> next utterance plays
clock = 5.3
p:tick()
H.eq(p.cur, 2, "advanced to the second utterance"); H.eq(p.state, "playing", "and it was ready, so it plays")
H.eq(#started, 2, "second audio start")
-- Its first word is w11, off the current page -> highlight would follow (our fake highlight just records)
clock = 5.3 + 0.1
p:tick()
H.eq(hl_calls[#hl_calls][1], "11s", "marker moves to w11")
-- Pause / resume seeks back a little
clock = 5.3 + 1.2
p:pause()
H.eq(p.state, "paused", "paused"); H.near(p.paused_at, 1.2, 0.01, "position remembered")
p:resume()
H.eq(p.state, "playing", "resumed"); H.near(started[#started].seek, 0.8, 0.01, "resumed 0.4 s before the pause point")
-- Skip forward and back
p:skip(1)
H.eq(p.cur, 3, "skipped to the third utterance")
p:skip(-1)
H.eq(p.cur, 2, "and back"); H.ok(p.state == "playing" or p.state == "preparing", "state sane after skipping back: " .. p.state)
-- Run to the end of the book
for _ = 1, 40 do clock = clock + 5.5; p:tick(); if p.state == "idle" then break end end
H.eq(p.state, "idle", "stops at the end of the book")
H.ok(logs[#logs - 1]:find("end of book") or logs[#logs]:find("end of book"), "logged the end")
H.eq(hl_calls.cleared, true, "marker cleared")
H.eq(#stubs["ui/uimanager"].scheduled, 0, "no tick left scheduled")

-- Sentence mode highlights the whole sentence
local p2 = Player.new{
    ui = ui, settings = function() return { voice = "v", speed = 1, highlight = "sentence" } end,
    plan = { backend = "ffplay", formats = { edge.FORMATS.mp3 }, latency = 0 }, tmpdir = os.getenv("TMPDIR") or "/tmp",
    highlight = highlight, log = function() end, notify = function() end, on_state = function() end,
    uimanager = stubs["ui/uimanager"], json_decode = require("json").decode,
}
doc.page = { 1, 10 }
clock = 0
p2:start("1s"); p2:tick()
H.eq(hl_calls[#hl_calls][1], "1s", "sentence start"); H.eq(hl_calls[#hl_calls][2], "5e", "sentence end")
clock = 2.6; p2:tick()
H.eq(hl_calls[#hl_calls][1], "6s", "second sentence marked when its first word is spoken")
p2:stop()

-- A failing fetch is retried once, then skipped with a notice
edge.synthesize = function() return nil, "connect: refused" end
local notes = {}
local p3 = Player.new{
    ui = ui, settings = function() return { voice = "v", speed = 1 } end,
    plan = { backend = "ffplay", formats = { edge.FORMATS.mp3 }, latency = 0 }, tmpdir = os.getenv("TMPDIR") or "/tmp",
    highlight = highlight, log = function() end, notify = function(m) notes[#notes + 1] = m end, on_state = function() end,
    uimanager = stubs["ui/uimanager"], json_decode = require("json").decode,
}
p3:start("1s")
p3:tick(); p3:tick(); p3:tick()
H.eq(p3.utterances[1].attempts, 2, "two attempts"); H.eq(p3.utterances[1].status, "done", "then given up and skipped")
H.ok(notes[1] and notes[1]:find("refused"), "user told why")
p3:stop()
-- Gapless stream mode: PCM utterances are queued back to back on one stream.
edge.synthesize = function(text, opts)
    local ws = {}
    local t = 0
    for w in text:gmatch("%S+") do ws[#ws + 1] = { text = w:gsub("%.", ""), t0 = t, t1 = t + 0.4 }; t = t + 0.5 end
    return { audio = string.rep("x", 48000 * t), words = ws, format = edge.FORMATS.pcm, duration = t }
end
local queued, streams = {}, 0
audio.stream_start = function(plan) streams = streams + 1; return { started = clock, latency = 1.7, seq = 0, plan = plan } end
audio.stream_enqueue = function(stream, file, skip) stream.seq = stream.seq + 1; queued[#queued + 1] = { file = file, skip = skip, at = clock }; return file end
audio.stream_stop = function() end
audio.stream_running = function() return true end
clock = 1000
doc.page = { 1, 10 }
hl_calls = {}
local ps = Player.new{
    ui = ui, settings = function() return { voice = "v", speed = 1, highlight = "word" } end,
    plan = { backend = "kindle-gst", gst = "gst-launch-1.0", formats = { edge.FORMATS.pcm }, latency = 1.7 }, tmpdir = os.getenv("TMPDIR") or "/tmp",
    highlight = { show = function(_, a, b) hl_calls[#hl_calls + 1] = { a, b }; return "shown" end, clear = function() end },
    log = function(m) logs[#logs + 1] = m end, notify = function() end, on_state = function() end,
    uimanager = stubs["ui/uimanager"], json_decode = require("json").decode,
}
H.eq(ps.stream_mode, true, "gst plan streams")
ps:start("1s"); ps:tick()
H.eq(ps.state, "playing", "playing on the stream"); H.eq(streams, 1, "one stream started"); H.ok(#queued >= 1, "first utterance queued")
local u1, u2 = ps.utterances[1], ps.utterances[2]
H.near(u1.start_at, 1000 + 1.2, 0.01, "first utterance sounds after the output latency (lead-in excluded)")
clock = 1000.5; ps:tick(); clock = 1001; ps:tick()
H.ok(u2 and u2.queued, "second utterance queued while the first plays")
H.near(u2.start_at, u1.start_at + u1.duration, 0.01, "and scheduled exactly at the first one's end: gapless")
H.eq(#hl_calls, 0, "nothing marked before the audio can be heard")
clock = u1.start_at + 0.6; ps:tick()
H.eq(hl_calls[#hl_calls][1], "2s", "marker follows the stream clock")
clock = u1.start_at + u1.duration + 0.1; ps:tick()
H.eq(ps.cur, 2, "advanced into the already-queued utterance"); H.eq(ps.state, "playing", "without leaving the playing state"); H.eq(streams, 1, "still the same stream")
-- pause tears the stream down; resume rebuilds it from the paused point
clock = u2.start_at + 2.0
ps:pause()
H.eq(ps.state, "paused", "paused"); H.near(ps.paused_at, 2.0, 0.01, "position inside the second utterance")
local before = #queued
ps:resume()
H.eq(streams, 2, "a fresh stream on resume"); H.ok(#queued > before, "re-queued")
H.eq(queued[before + 1].skip, math.floor(1.6 * 24000) * 2, "skips into the file to 0.4 s before the pause point")
H.near(u2.start_at, clock + 1.2 - 1.6, 0.01, "start_at set so the position reads 1.6 s at the first audible sample")
ps:stop()
H.done("test_player")
