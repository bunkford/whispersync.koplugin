#!/usr/bin/env python3
"""
Generate the ZenPM repository for the Kindle Whispersync plugin.

ZenPM (https://github.com/xZenLabs/zen-pm) installs KOReader plugins from any
static site that serves a manifest.json; users add the site under Sources.
This writes that site into zenpm/:

    zenpm/manifest.json                                  package summary
    zenpm/packages/whispersync.koplugin/versions.json    release history + asset URLs
    zenpm/packages/whispersync.koplugin/README.md        shown as the package page
    zenpm/packages/whispersync.koplugin/RELEASE_NOTES.md the plugin CHANGELOG

The version comes from _meta.lua (ZenPM reads the same field on the device to
decide whether an update exists), the asset from a GitHub release of this
repository. Normally run by the release workflow; safe to run by hand.

    python3 tools/zenpm_manifest.py --tag v0.1.0 \
        --asset-url https://github.com/bunkford/whispersync.koplugin/releases/download/v0.1.0/whispersync.koplugin.zip \
        --size 123456 --sha256 abc...
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLUGIN_DIR = ROOT / "whispersync.koplugin"
OUT = ROOT / "zenpm"
PKG = OUT / "packages" / "whispersync.koplugin"

PACKAGE_ID = "whispersync"
MODULE = "whispersync"
ASSET_NAME = "whispersync.koplugin.zip"
DEFAULT_SOURCE = "https://github.com/bunkford/whispersync.koplugin"
DEFAULT_REPO_URL = "https://bunkford.github.io/whispersync.koplugin/"

# Same regex ZenPM applies to _meta.lua on the device.
META_VERSION = re.compile(r"\bversion\s*=\s*[\"']([^\"']+)[\"']")


def plugin_version() -> str:
    m = META_VERSION.search((PLUGIN_DIR / "_meta.lua").read_text())
    if not m:
        raise SystemExit("no version = \"...\" in _meta.lua")
    return m.group(1).strip()


def load_versions() -> list[dict]:
    path = PKG / "versions.json"
    if not path.exists():
        return []
    return json.loads(path.read_text()).get("releases", [])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--tag", help="release tag (default v<version>)")
    ap.add_argument("--asset-url", help="download URL of whispersync.koplugin.zip (default: GitHub release URL for the tag)")
    ap.add_argument("--size", type=int, default=None)
    ap.add_argument("--sha256", default=None)
    ap.add_argument("--published", default=None, help="ISO-8601 UTC, default now")
    ap.add_argument("--source", default=DEFAULT_SOURCE, help="GitHub repository the releases live in")
    ap.add_argument("--repo-url", default=DEFAULT_REPO_URL, help="public URL of the zenpm/ directory")
    ap.add_argument("--prerelease", action="store_true")
    args = ap.parse_args()

    version = plugin_version()
    tag = args.tag or f"v{version}"
    asset_url = args.asset_url or f"{args.source}/releases/download/{tag}/{ASSET_NAME}"
    published = args.published or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    asset = {"name": ASSET_NAME, "url": asset_url}
    if args.size:
        asset["size"] = args.size
    if args.sha256:
        asset["digest"] = "sha256:" + args.sha256.lower().removeprefix("sha256:")
    release = {"tag_name": tag, "name": tag, "assets": [asset]}
    if args.prerelease:
        release["prerelease"] = True

    releases = [r for r in load_versions() if r.get("tag_name") != tag]
    releases.insert(0, release)

    PKG.mkdir(parents=True, exist_ok=True)
    (PKG / "versions.json").write_text(json.dumps({"releases": releases}, indent=2) + "\n")
    shutil.copyfile(PLUGIN_DIR / "README.md", PKG / "README.md")
    shutil.copyfile(PLUGIN_DIR / "CHANGELOG.md", PKG / "RELEASE_NOTES.md")

    description = ("Read your Send-to-Kindle library straight from Amazon and keep reading position, "
                   "bookmarks, highlights and notes in sync with your Kindle account.")
    package = {
        "id": PACKAGE_ID,
        "name": "Kindle Whispersync",
        "version": version,
        "description": description,
        "author": "bunkford",
        "category": "utility",
        "platforms": ["koreader"],
        "dependencies": [],
        "source": args.source,
        "source_type": "release",
        "source_asset": ASSET_NAME,
        "plugin_module": MODULE,
        "published_at": published,
        "readme_url": "packages/whispersync.koplugin/README.md",
        "release_notes_url": "packages/whispersync.koplugin/RELEASE_NOTES.md",
        "versions_url": "packages/whispersync.koplugin/versions.json",
        "size": str(args.size) if args.size else "",
        "assets": [{"arch": "any", "asset": ASSET_NAME, "url": asset_url, "size": str(args.size) if args.size else ""}],
    }
    manifest = {
        "schema_version": "1",
        "repo": {
            "id": "bunkford-whispersync",
            "name": "Kindle Whispersync",
            "url": args.repo_url,
        },
        "packages": [package],
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"zenpm/manifest.json: {PACKAGE_ID} {version} ({tag}), {len(releases)} release(s) in versions.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
