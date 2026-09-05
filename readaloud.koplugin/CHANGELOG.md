# Changelog

Release notes for the Read Aloud (Edge voices) KOReader plugin. The newest
release is first; ZenPM shows this file as the package's release notes.

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
