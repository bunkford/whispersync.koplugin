local _ = require("gettext")
return {
    -- ZenPM reads this to know when an update is available; keep it in step
    -- with the release tag (vX.Y.Z) and CHANGELOG.md.
    version = "0.1.3",
    fullname = _("Read Aloud (Edge voices)"),
    description = _([[Reads the open book aloud with Microsoft Edge's neural voices, synthesized on the device itself, and underlines each word as it is spoken. Bluetooth audio on Kindle.]]),
}
