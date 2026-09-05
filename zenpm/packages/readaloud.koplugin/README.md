# Read Aloud (Edge voices) for KOReader

Reads the open book aloud with Microsoft Edge's neural voices and marks each
word on the page as it is spoken. Everything happens on the device: the plugin
speaks to the Edge read-aloud service directly over Wi-Fi, a sentence group at
a time, and plays the result through Bluetooth on Kindle (or the usual players
on a desktop). No server, no account, no Piper models to install.

Works with any reflowable book KOReader opens with crengine: EPUB, MOBI/AZW3,
FB2, HTML, TXT. Not PDF.

## Install

**With ZenPM** (recommended): add the source
`https://bunkford.github.io/whispersync.koplugin/` under *Sources* (the same
source as Kindle Whispersync), then install *Read Aloud (Edge voices)*.
Updates arrive the same way.

**By hand:** download `readaloud.koplugin.zip` from the
[releases](https://github.com/bunkford/whispersync.koplugin/releases) and
unzip it into KOReader's `plugins/` folder so that
`plugins/readaloud.koplugin/main.lua` exists. Restart KOReader.

## Use

1. On Kindle, pair headphones or a speaker in the Kindle's own
   *Settings → Bluetooth* first. KOReader cannot pair devices; it only uses the
   connection the Kindle already has.
2. Open a book and tap *Tools → Read aloud → Start reading from this page*, or
   assign the *Read aloud: start / pause* gesture action.
3. A bar appears along the bottom: previous / next sentence group, Pause, and
   ✕ to stop. Tapping and swiping anywhere else still turns pages, opens menus
   and so on. The spoken word is inverted on the page and the page turns to
   follow the voice.

**Voice, speed, marker.** *Read aloud → Voice* lists thirty English voices
(US, UK, Australia, Canada, Ireland, India, New Zealand, South Africa); *Other
voice…* takes any Edge voice short name, such as `fr-FR-HenriNeural`. Speed
runs from 0.8× to 2×, applied by the service so the voice stays natural.
*Word marker* switches between word, sentence and none, and the style: invert
(clearest on e-ink), underline, box or grey.

**If the marker runs ahead of or behind the voice**, *Audio → Marker timing
offset* shifts it in quarter-second steps. Bluetooth on Kindle adds about a
second of delay, which is already accounted for; different headphones differ.

## How it works

- **Text.** crengine extends the current position to its sentence, walks
  sentence by sentence, and later word by word. Up to eight sentences or ~900
  bytes make one utterance, which is what the service is asked for at a time;
  the next utterance is fetched while the current one plays.
- **Voice.** The Edge read-aloud service (the one the Edge browser uses,
  documented by the [edge-tts](https://github.com/rany2/edge-tts) project) is
  a WebSocket that takes SSML and streams audio plus a `WordBoundary` event
  per spoken word with its offset in the audio. The plugin carries its own
  WebSocket client on KOReader's luasocket/luasec. The fetch runs in a forked
  child so the UI never waits on the network.
- **Alignment.** Each spoken word is matched, in order, to the words crengine
  sees in the same sentences (punctuation ignored, hyphenated compounds
  handled either way round), giving every word timing an xpointer range. A
  quarter-second tick reads the playback clock and moves the marker; the
  marker is a ReaderView view module and refreshes only the strip it touched.
- **Sound on Kindle.** Kindle firmware exposes no ALSA or PulseAudio; Bluetooth
  audio goes through Amazon's `audiomgrd`. The stock GStreamer's `mixersink`
  element feeds it, and a `gst-launch filesrc ! capsfilter ! mixersink`
  pipeline plays raw PCM through it, the path the
  [audiobook.koplugin](https://github.com/stradichenko/audiobook.koplugin)
  project established on Paperwhite 5/6 hardware. Kindle's GStreamer has no
  MP3 decoder, so the plugin asks the service for raw 24 kHz PCM; if the
  service ever refuses that, MP3 is played through Amazon's own player
  (`playermgr` over LIPC), or decoded by an `ffmpeg` binary when one is
  present (the audiobook plugin bundles one). *Audio → Audio output details*
  shows what was detected, *Play a test tone* proves the pipeline, and *Voice →
  Test the voice* reports exactly what the service returned.

## Caveats

- Edge's voices are a free, unofficial service. It needs internet, and
  Microsoft can change or restrict it; the plugin implements the current
  handshake (the `Sec-MS-GEC` token) and corrects for a wrong device clock
  from the service's own reply.
- Kindles without Bluetooth (before the 2018 Paperwhite) have no audio path.
- Amazon's `playermgr` fallback cannot seek, so pausing there resumes from the
  start of the current sentence group.

## Development

    sh readaloud.koplugin/tests/run.sh      # desktop tests, plain luajit
    sh tools/build_plugin.sh                # dist/readaloud.koplugin.zip

Releases: bump `version` in `_meta.lua`, add a CHANGELOG entry, then run the
*release* workflow choosing *readaloud* with *publish* ticked (or push a
`readaloud-vX.Y.Z` tag). The
workflow runs the tests, builds the zip, creates the GitHub release,
regenerates `zenpm/` and redeploys the GitHub Pages site ZenPM reads.

## Files

    readaloud.koplugin/
      main.lua        plugin, menu, settings, diagnostics
      edge.lua        Edge read-aloud protocol (SSML, Sec-MS-GEC, WordBoundary)
      ws.lua          WebSocket client
      segment.lua     sentences and words from crengine; alignment
      audio.lua       playback backends and commands
      player.lua      state machine
      highlight.lua   word marker view module
      bar.lua         transport bar view module
      tests/          run.sh and the suites
    tools/            build and ZenPM manifest scripts
    zenpm/            the static ZenPM repository served by GitHub Pages
