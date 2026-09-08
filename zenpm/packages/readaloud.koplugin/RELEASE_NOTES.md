# Changelog

Release notes for the Read Aloud (Edge voices) KOReader plugin. The newest
release is first; ZenPM shows this file as the package's release notes.

## 0.2.5

The freeze, found and fixed.

- **Starting the stream deadlocked KOReader.** The stream player is launched
  with its input on a FIFO, which blocks until the feeder opens the other
  end, and the feeder was launched only after the player's launch returned;
  the launch itself waited on a pipe the blocked shell still held. The log
  from 0.2.4 showed the UI stopping at exactly that step while the fetch
  child carried on. Background jobs are now started with their standard
  streams detached before they run, so nothing can hold that pipe, and a
  test launches a job blocked on a FIFO to prove the caller returns at once.
  The same launch path is used for every player, so the per-utterance path
  can no longer stall the UI for the length of a clip either.

## 0.2.4

- **The fetch is traced end to end.** The log now records when each fetch
  child is spawned and finishes, and the child itself writes its progress
  (request sent, audio received, decoding, done) into the same file, with a
  heartbeat line every five seconds while anything is in flight. A freeze now
  leaves a trace of the exact step it happened in.

## 0.2.3

Chasing the freeze, with evidence this time.

- **A log that survives a power cycle.** Every line now goes straight to
  `koreader/readaloud.log` (the old log lived in settings that are only
  flushed later, so a freeze erased exactly the lines that mattered). *Audio →
  Log* shows the file.
- **The stream works on Kindle.** KOReader's cache sits on the FAT user
  partition, where a FIFO cannot be created, so the continuous stream never
  actually engaged there. Its FIFO and queue now live on /tmp, and queue
  entries are small job files naming the PCM to play, so nothing is copied or
  hard-linked.
- **The word walk is sliced.** crengine is asked for at most ~0.15 s of work
  per tick; a group accumulates over several ticks and is finalized when it
  reaches its size. Text between words is never requested across a paragraph
  boundary.

## 0.2.2

Fixes a freeze while "Fetching audio…" that needed a power cycle.

- The stream feeder paused with a fractional `sleep`, which busybox on Kindle
  can refuse, leaving the feeder spinning at full speed. It now uses `usleep`
  (with a whole-second fallback) and exits on its own when the player it feeds
  has gone.
- The word walk over crengine happens once per group, and the words it finds
  are reused for the marker timeline instead of walking again. Groups are
  built one per tick and capped at ~2000 bytes, so the UI never stalls for
  more than a fraction of a second.
- The log records how long each walk, timeline and stream start took.

## 0.2.1

Punctuation reaches the voice.

- **Real sentences.** KOReader's sentence-segment call only grabs punctuation
  around an existing selection; given a single point it returns nothing, so
  the plugin had been falling back to one word per "sentence", joined by
  spaces with the punctuation dropped, and capping each request at forty
  words. Sentences are now built from crengine's word navigation, keeping the
  text between words, so full stops, question marks, quotes and paragraph
  breaks all reach the voice, and requests carry the intended three minutes
  of text. Headings and unpunctuated paragraphs get a full stop so the voice
  pauses at them.

## 0.2.0

Narration that flows.

- **One continuous stream.** Playback is now a single audio pipeline fed
  from a queue: sentence groups are decoded as they arrive and poured into
  it back to back, so there is no process start-up, no silence padding and
  no gap between groups. Pause and skip rebuild the stream from the exact
  point.
- **Longer sentence groups.** After a short first group (so the voice starts
  within seconds), each request to the service carries up to about three
  minutes of text, which the voice reads as one arc instead of many short
  takes.
- The marker clock is derived from the stream schedule, so it stays in step
  across group boundaries.

## 0.1.5

Sound on Kindle.

- **A bundled MP3 decoder.** Kindle firmware has no MP3 decoder and Amazon's
  player will not take one, while the Edge service only ever sends MP3. The
  plugin now ships `bin/mp3dec`, a static build of the public-domain minimp3
  for both Kindle ABIs (hard-float and the older soft-float), under half a
  megabyte each. Each utterance is decoded to PCM in the background as soon
  as it arrives and plays through the same GStreamer path as the test tone.
- With the decoder present, MP3 is asked for first, so no time is spent on
  formats the service refuses.

## 0.1.4

- **Amazon's player is asked four ways.** When MP3 goes to playermgr over
  LIPC, the file is now offered as Open+Play with a path and with a file://
  URI, then as Play with either, and the player gets a moment to start before
  each attempt is judged. The failure message lists what the player reported
  for each, and points at Bluetooth being off or the silent mode.

## 0.1.3

- **Follow the words without sound.** *Audio → Follow the words without
  sound* runs the reading at the voice's pace and marks each word but plays
  nothing: a read-along mode, and the way to use the plugin on a Kindle with
  Bluetooth off. Without it, a missing speaker made the player exit at once
  and the marker race ahead.

## 0.1.2

- **A hang-up counts as a refusal.** When the service closes the connection
  without sending audio ("connection ended without audio"), the next output
  format is now tried instead of giving up, so a refused raw-PCM request
  falls through to MP3.
- **The close reason is shown.** The WebSocket close frame's status code and
  text, the one place the service says why it hung up, now appear in the
  error and in the voice test's report.

## 0.1.1

Fixes the first-run failure "wantread": luasec's name for a read that timed
out, which is what a request for an audio format the service does not
support looks like.

- **Formats are probed quickly and remembered.** The first message from the
  service now has a 12-second limit; a format that stays silent or ends
  without audio is treated as refused and the next one is tried. The format
  the service honours is saved and asked for first from then on (*Audio →
  Forget which audio format worked* resets it).
- **MP3 on Kindle without ffmpeg** goes to Amazon's own player (playermgr over
  LIPC); the player is chosen per format, so a raw-PCM refusal no longer
  leaves the Kindle with nothing to play.
- **Test the voice** now tries each format in turn and reports what happened
  to every one, with timings, then plays the first that worked.
- WebSocket frames are read by exact size; the client was verified end to end
  against a mock of the service on real sockets.

## 0.1.0

First release.

- **Edge neural voices, on the device.** The plugin talks to Microsoft Edge's
  read-aloud service itself over Wi-Fi: no server, no account. Thirty English
  voices are listed; any other Edge voice can be typed in.
- **Word-exact marker.** The service reports the timing of every spoken word;
  the plugin aligns those to the words crengine laid out and inverts (or
  underlines, boxes, greys) the word being spoken, turning the page to follow.
  A sentence mode marks the whole sentence instead.
- **Kindle Bluetooth audio.** Sound goes out through Amazon's audio mixer via
  the stock GStreamer, the path proven by the audiobook.koplugin project. Raw
  PCM is requested from the service so no decoder is needed; Amazon's own
  player is the fallback. Desktop KOReader plays through ffplay, mpv, paplay
  or aplay for testing.
- **Transport bar** along the bottom of the page with previous/next sentence
  group, pause/resume and stop; taps elsewhere still turn pages. Gesture
  actions for start/pause and stop.
- **Diagnostics:** a test tone, a voice test that reports what the service
  returned, output details, a marker timing offset, and a log.
