# Changelog

Release notes for the Kindle Whispersync KOReader plugin. The newest release
is first; ZenPM shows this file as the package's release notes.

## 0.2.0

ZenOS becomes home ground, and one crash is fixed.

- **Kindle tab in the ZenOS navbar.** *Kindle Whispersync → ZenOS → Add a
  Kindle tab* adds a native folder tab pointing at the download folder, so the
  Kindle library appears in ZenOS's own cover view with its sorting and
  badges. Takes effect after a restart.
- **Keep every personal document on this device** (default on). A refresh
  downloads all Send-to-Kindle documents (large files skipped), so the native
  library, Recent and search see the whole Kindle library, not only books
  opened once.
- **Amazon read times and progress feed KOReader's history and sidecars**
  (default on). Downloaded Kindle books show up in KOReader history and in
  ZenOS Home → Recent at the time they were last read on a Kindle, with their
  progress and finished state. A later read on this device always wins.
- **"K" badge on Kindle books' covers** (default on): on the shelf, on the
  Home strip, and on ZenOS's own library tiles.
- **Fixed an intermittent crash while signing** with credentials whose
  private key arrived as base64 DER (the imported-from-dashboard format on
  older accounts). LuaJIT's array-from-string initializer did not survive
  garbage collection; the key is now copied into a buffer the plugin owns.
  Base64 is also table-driven now instead of pattern-matched, which is much
  faster on a 1.6 KB key.

## 0.1.0

First release.

- Send-to-Kindle library shelf with covers, titles, authors and progress,
  fetched straight from Amazon; tap to download and open, hold for details.
- Reading position written to Amazon after quiet reading, on close and on
  suspend, verified by read-back; newer Kindle positions offered on open.
- Bookmarks, highlights and notes synced both ways.
- Per-book sync status with Amazon's own record of which device wrote the
  position, and a persistent sync log.
- Registration from a phone via a connect page served on the Kindle, or by
  importing the dashboard's device credentials.
- ZenOS: Launcher/Controls entry point and a Home strip.
