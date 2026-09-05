local _ = require("gettext")
return {
    -- ZenPM reads this to know when an update is available; keep it in step
    -- with the release tag (vX.Y.Z) and CHANGELOG.md.
    version = "0.2.0",
    fullname = _("Kindle Whispersync"),
    description = _([[Reads your Send-to-Kindle library straight from Amazon and keeps reading position, bookmarks, highlights and notes in sync with your Kindle account, using the same device protocol Kindle hardware speaks.]]),
}
