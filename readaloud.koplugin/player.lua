--[[--
The reading-aloud state machine.

Sentences are taken from the book at the reading position and grouped into
utterances; each utterance is synthesized in a forked child process (the
network wait must not freeze the UI), written to a temp file and played by
audio.lua while the next one is already being fetched. A quarter-second
tick reads the playback clock, finds the word being spoken on the
utterance's timeline and moves the highlight; when the audio ends, the next
utterance starts. Pause remembers the position and resumes by seeking.

States: idle, preparing (waiting for audio), playing, paused, error.
]]

local Player = {}
Player.__index = Player

local audio = require("audio")
local edge = require("edge")
local segment = require("segment")

local TICK = 0.25
local QUEUE_AHEAD = 2      -- utterances fetched ahead of the one playing
local MAX_ATTEMPTS = 2

--- opts: ui, settings() -> { voice, speed, highlight, style, follow },
-- plan (audio plan), tmpdir, highlight (Highlight), bar (Bar), log(msg),
-- notify(msg), on_state(state), ffiutil (KOReader ffi/util), uimanager,
-- json_encode/json_decode.
function Player.new(opts)
    local self = setmetatable({}, Player)
    self.opts = opts
    self.ui = opts.ui
    self.state = "idle"
    self.utterances = {}
    self.cur = 0
    self.seq = 0
    self.format_index = 1
    -- Start with the format a previous session found the service honours.
    local remembered = opts.settings and opts.settings().format
    for i, fmt in ipairs(opts.plan and opts.plan.formats or {}) do
        if fmt == remembered then self.format_index = i end
    end
    self.tick_fn = function() self:tick() end
    return self
end

function Player:log(msg)
    if self.opts.log then self.opts.log(msg) end
end

function Player:set_state(s, detail)
    if self.state ~= s or detail then
        self.state = s
        self.detail = detail
        if self.opts.on_state then self.opts.on_state(s, detail) end
    end
end

function Player:settings()
    return self.opts.settings and self.opts.settings() or {}
end

function Player:tmpfile(id, ext)
    return (self.opts.tmpdir or "/tmp") .. "/readaloud-" .. id .. "." .. ext
end

-------------------------------------------------------------------------------
-- queue
-------------------------------------------------------------------------------

--- Keep QUEUE_AHEAD utterances queued after the current one.
function Player:fill()
    local doc = self.ui.document
    local guard = 0
    while self.cursor and (#self.utterances - math.max(self.cur, 1)) < QUEUE_AHEAD and guard < 4 do
        guard = guard + 1
        local sentences, nxt = segment.sentences_from(doc, self.cursor, segment.MAX_UTTERANCE_BYTES, segment.MAX_UTTERANCE_SENTENCES)
        self.cursor = nxt
        if #sentences == 0 then break end
        for _, g in ipairs(segment.group(sentences)) do
            self.seq = self.seq + 1
            g.id = self.seq
            g.status = "pending"
            g.attempts = 0
            self.utterances[#self.utterances + 1] = g
        end
    end
end

local function json_escape(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\"
        elseif c == "\n" then return "\\n" elseif c == "\r" then return "\\r" elseif c == "\t" then return "\\t"
        else return ("\\u%04x"):format(c:byte()) end
    end) .. '"'
end

--- The child's work: synthesize, write audio + a JSON sidecar, exit.
-- Pure of UI; only files. Returned so it can be run inline in tests.
function Player:fetch_job(utt, formats, settings, audio_path, meta_path)
    return function()
        local result, err
        for _, f in ipairs(formats) do
            result, err = edge.synthesize(utt.text, { voice = settings.voice, speed = settings.speed, format = f, timeout = 40 })
            if result then break end
            if not edge.is_refusal(err) then break end
        end
        local out = io.open(meta_path .. ".tmp", "wb")
        if result then
            local a = io.open(audio_path, "wb")
            if a then a:write(result.audio); a:close() end
            local words = {}
            for i, w in ipairs(result.words) do
                words[i] = ('{"text":%s,"t0":%.3f,"t1":%.3f}'):format(json_escape(w.text), w.t0, w.t1)
            end
            if out then
                out:write(('{"ok":true,"format":%s,"duration":%.3f,"bytes":%d,"words":[%s]}'):format(
                    json_escape(result.format), result.duration, #result.audio, table.concat(words, ",")))
            end
        elseif out then
            out:write(('{"ok":false,"error":%s}'):format(json_escape(tostring(err))))
        end
        if out then out:close(); os.rename(meta_path .. ".tmp", meta_path) end
    end
end

--- Start fetching the next pending utterance, if none is in flight.
function Player:fetch_next()
    if self.fetch then return end
    local utt
    for i = math.max(self.cur, 1), #self.utterances do
        if self.utterances[i].status == "pending" then utt = self.utterances[i]; break end
    end
    if not utt then return end
    utt.status = "fetching"
    utt.attempts = utt.attempts + 1
    local formats = {}
    local plan_formats = self.opts.plan and self.opts.plan.formats or { edge.FORMATS.mp3 }
    for i = self.format_index, #plan_formats do formats[#formats + 1] = plan_formats[i] end
    for i = 1, self.format_index - 1 do formats[#formats + 1] = plan_formats[i] end
    local meta = self:tmpfile(utt.id, "json")
    local audio_path = self:tmpfile(utt.id, "audio")
    os.remove(meta)
    local job = self:fetch_job(utt, formats, self:settings(), audio_path, meta)
    local ffiutil = self.opts.ffiutil
    if ffiutil and ffiutil.runInSubProcess then
        local pid, perr = ffiutil.runInSubProcess(function() job() end)
        if not pid then
            self:log("cannot fork: " .. tostring(perr))
            job() -- fall back to blocking
            pid = nil
        end
        self.fetch = { utt = utt, pid = pid, meta = meta, audio = audio_path, started = os.time() }
    else
        job()
        self.fetch = { utt = utt, pid = nil, meta = meta, audio = audio_path, started = os.time() }
    end
end

--- Collect a finished fetch. Returns true when something changed.
function Player:collect()
    local f = self.fetch
    if not f then return false end
    local ffiutil = self.opts.ffiutil
    if f.pid and ffiutil and not ffiutil.isSubProcessDone(f.pid) then
        if os.time() - f.started > 90 then
            ffiutil.terminateSubProcess(f.pid)
            self:log("fetch timed out")
        else
            return false
        end
    end
    self.fetch = nil
    local utt = f.utt
    local fh = io.open(f.meta, "rb")
    local meta = fh and fh:read("*a") or nil
    if fh then fh:close() end
    os.remove(f.meta)
    local data = meta and self.opts.json_decode and self.opts.json_decode(meta) or nil
    if type(data) == "table" and data.ok then
        utt.status = "ready"
        utt.file = f.audio
        utt.format = data.format
        utt.duration = tonumber(data.duration) or 0
        utt.words = data.words or {}
        -- Remember the format the service honoured, so later fetches ask for it first.
        for i, fmt in ipairs(self.opts.plan and self.opts.plan.formats or {}) do
            if fmt == data.format then
                if self.format_index ~= i and self.opts.on_format then self.opts.on_format(data.format) end
                self.format_index = i
            end
        end
        self:log(("utterance %d ready: %.1fs, %d words, %s"):format(utt.id, utt.duration, #utt.words, tostring(data.format)))
    else
        local why = type(data) == "table" and data.error or "no result"
        self:log(("utterance %d failed (attempt %d): %s"):format(utt.id, utt.attempts, tostring(why)))
        os.remove(f.audio)
        if utt.attempts < MAX_ATTEMPTS then
            utt.status = "pending"
        else
            utt.status = "failed"
            utt.error = why
        end
    end
    return true
end

-------------------------------------------------------------------------------
-- playback
-------------------------------------------------------------------------------

--- Alignment of the spoken words to crengine's, done once per utterance.
function Player:prepare_timeline(utt)
    if utt.timeline then return end
    local doc = self.ui.document
    local cre = segment.utterance_words(doc, utt)
    local aligned = segment.align(cre, utt.words or {})
    utt.timeline = segment.timeline(utt.words or {}, aligned)
    local missing = 0
    for i = 1, #(utt.words or {}) do if not aligned[i] then missing = missing + 1 end end
    if missing > 0 then self:log(("utterance %d: %d of %d words unplaced"):format(utt.id, missing, #utt.words)) end
end

function Player:play_current(seek)
    local utt = self.utterances[self.cur]
    if not utt or utt.status ~= "ready" then return false end
    self:prepare_timeline(utt)
    if self.handle then audio.stop(self.handle); self.handle = nil end
    local handle, err = audio.start(self.opts.plan, utt.file, utt.format, seek or 0, self.opts.tmpdir)
    if not handle then
        self:log("cannot play: " .. tostring(err))
        self:set_state("error", tostring(err))
        if self.opts.notify then self.opts.notify(tostring(err)) end
        self:stop_audio_only()
        return false
    end
    self.handle = handle
    self.word_index = nil
    self.play_started = os.time()
    self:set_state("playing")
    self:update_highlight(utt, audio.position(handle))
    return true
end

--- Sentence range containing xpointer xp within utterance (for sentence mode).
function Player:sentence_for(utt, xp)
    local doc = self.ui.document
    for _, s in ipairs(utt.sentences or {}) do
        local ok1, c1 = pcall(doc.compareXPointers, doc, s.xp0, xp)
        local ok2, c2 = pcall(doc.compareXPointers, doc, xp, s.xp1)
        if ok1 and ok2 and c1 and c2 and c1 >= 0 and c2 >= 0 then return s end
    end
    return nil
end

function Player:update_highlight(utt, pos)
    local idx = segment.at(utt.timeline, pos)
    if idx == self.word_index then return end
    self.word_index = idx
    local hl = self.opts.highlight
    if not hl then return end
    local mode = self:settings().highlight or "word"
    if mode == "off" or not idx then return end
    local w = utt.timeline[idx]
    if mode == "sentence" then
        local s = self:sentence_for(utt, w.xp0)
        if s then hl:show(s.xp0, s.xp1) return end
    end
    hl:show(w.xp0, w.xp1)
end

function Player:tick()
    if self.state == "idle" then return end
    local ok, err = pcall(function()
        if self:collect() then self:fetch_next() end
        local utt = self.utterances[self.cur]
        if self.state == "preparing" then
            if utt and utt.status == "ready" then
                self:play_current(self.resume_at or 0)
                self.resume_at = nil
            elseif utt and utt.status == "failed" then
                self:log("skipping utterance " .. utt.id .. ": " .. tostring(utt.error))
                if self.opts.notify then self.opts.notify(tostring(utt.error)) end
                self:advance()
            elseif not utt then
                self:finish()
            else
                self:fetch_next()
            end
        elseif self.state == "playing" and utt then
            local pos = audio.position(self.handle)
            self:update_highlight(utt, pos)
            local ended = pos >= (utt.duration or 0) + 0.15
            if not ended and pos > 1.0 and not audio.running(self.handle) then ended = true end
            if ended then self:advance() end
        end
        self:fill()
        self:fetch_next()
    end)
    if not ok then self:log("tick error: " .. tostring(err)) end
    if self.state ~= "idle" then
        self.opts.uimanager:scheduleIn(TICK, self.tick_fn)
    end
end

--- Move to the next utterance (playing it if ready, else waiting).
function Player:advance()
    if self.handle then audio.stop(self.handle); self.handle = nil end
    local old = self.utterances[self.cur]
    if old then
        if old.file then os.remove(old.file); old.file = nil end
        old.status = "done"
    end
    self.cur = self.cur + 1
    self:fill()
    local utt = self.utterances[self.cur]
    if not utt then
        if not self.cursor then self:finish() else self:set_state("preparing") end
        return
    end
    if utt.status == "ready" then
        self:play_current(0)
    else
        self:set_state("preparing")
    end
end

function Player:finish()
    self:log("end of book reached")
    if self.opts.notify then self.opts.notify("Reached the end of the book.") end
    self:stop()
end

-------------------------------------------------------------------------------
-- controls
-------------------------------------------------------------------------------

function Player:start(xp)
    self:stop()
    if not xp then return false, "no position" end
    self.cursor = xp
    self.utterances = {}
    self.cur = 1
    self:fill()
    if #self.utterances == 0 then return false, "nothing to read here" end
    self:set_state("preparing")
    self:fetch_next()
    self.opts.uimanager:scheduleIn(TICK, self.tick_fn)
    return true
end

function Player:pause()
    if self.state ~= "playing" then return end
    local pos = math.max(0, audio.position(self.handle))
    self.paused_at = pos
    audio.stop(self.handle)
    self.handle = nil
    self:set_state("paused")
end

function Player:resume()
    if self.state ~= "paused" then return end
    local utt = self.utterances[self.cur]
    local seek = self.paused_at or 0
    if self.opts.plan and self.opts.plan.backend == "kindle-lipc" then seek = 0 end
    -- Resume a little before the pause so the ear catches up.
    seek = math.max(0, seek - 0.4)
    if utt and utt.status == "ready" then
        self:play_current(seek)
    else
        self.resume_at = seek
        self:set_state("preparing")
    end
end

function Player:toggle()
    if self.state == "playing" then self:pause()
    elseif self.state == "paused" then self:resume()
    end
end

function Player:skip(delta)
    if self.state == "idle" then return end
    if self.handle then audio.stop(self.handle); self.handle = nil end
    local target = math.max(1, self.cur + delta)
    -- Utterances behind us were dropped from disk; refetch them.
    for i = target, self.cur do
        local u = self.utterances[i]
        if u and u.status == "done" then u.status = "pending"; u.attempts = 0; u.timeline = nil end
    end
    self.cur = target
    self.word_index = nil
    self:fill()
    local utt = self.utterances[self.cur]
    if utt and utt.status == "ready" then
        self:play_current(0)
    elseif utt then
        self:set_state("preparing")
        self:fetch_next()
    else
        self:finish()
    end
end

function Player:stop_audio_only()
    if self.handle then audio.stop(self.handle); self.handle = nil end
end

function Player:stop()
    self:stop_audio_only()
    if self.fetch then
        local pid, ffiutil = self.fetch.pid, self.opts.ffiutil
        if pid and ffiutil then
            pcall(ffiutil.terminateSubProcess, pid)
            -- Reap it once the kill has landed, so it does not linger as a zombie.
            self.opts.uimanager:scheduleIn(1, function() pcall(ffiutil.isSubProcessDone, pid) end)
        end
        os.remove(self.fetch.meta)
        os.remove(self.fetch.audio)
        self.fetch = nil
    end
    self.opts.uimanager:unschedule(self.tick_fn)
    for _, u in ipairs(self.utterances) do
        if u.file then os.remove(u.file) end
    end
    self.utterances = {}
    self.cur = 0
    self.cursor = nil
    self.word_index = nil
    self.paused_at = nil
    if self.opts.highlight then pcall(self.opts.highlight.clear, self.opts.highlight) end
    self:set_state("idle")
end

--- Human-readable status for the bar.
function Player:status_text()
    local utt = self.utterances[self.cur]
    if self.state == "preparing" then
        if self.fetch then return "Fetching audio…" end
        return "Preparing…"
    elseif self.state == "playing" then
        local ahead = 0
        for i = self.cur + 1, #self.utterances do if self.utterances[i].status == "ready" then ahead = ahead + 1 end end
        return (self:settings().voice or ""):gsub("Neural$", ""):gsub("^en%-%u%u%-", "") .. (ahead > 0 and "" or " · buffering")
    elseif self.state == "paused" then
        return "Paused"
    elseif self.state == "error" then
        return "Error: " .. tostring(self.detail)
    end
    return ""
end

return Player
