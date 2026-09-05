#!/usr/bin/env python3
"""
Generate the ZenPM repository for the plugins in this repository.

ZenPM (https://github.com/xZenLabs/zen-pm) installs KOReader plugins from any
static site that serves a manifest.json; users add the site under Sources.
One site, two packages: Kindle Whispersync and Read Aloud (Edge voices). This
writes that site into zenpm/:

    zenpm/manifest.json                             one entry per package
    zenpm/packages/<plugin>.koplugin/versions.json  release history + asset URLs
    zenpm/packages/<plugin>.koplugin/README.md      shown as the package page
    zenpm/packages/<plugin>.koplugin/RELEASE_NOTES.md  the plugin CHANGELOG

A run records ONE release for ONE plugin (--plugin, default whispersync), then
rebuilds manifest.json from every package's newest recorded release, so the
manifest never announces a version that has no asset behind it. The version
comes from the plugin's _meta.lua (ZenPM reads the same field on the device to
decide whether an update exists). Normally run by the release workflow; safe to
run by hand.

    python3 tools/zenpm_manifest.py --plugin readaloud --tag readaloud-v0.1.0 \
        --asset-url https://github.com/bunkford/whispersync.koplugin/releases/download/readaloud-v0.1.0/readaloud.koplugin.zip \
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
OUT = ROOT / "zenpm"

DEFAULT_SOURCE = "https://github.com/bunkford/whispersync.koplugin"
DEFAULT_REPO_URL = "https://bunkford.github.io/whispersync.koplugin/"

PLUGINS = {
    "whispersync": {
        "name": "Kindle Whispersync",
        "description": ("Read your Send-to-Kindle library straight from Amazon and keep reading position, "
                        "bookmarks, highlights and notes in sync with your Kindle account."),
        "category": "utility",
        "tag_prefix": "v",          # legacy: the first releases were plain vX.Y.Z tags
    },
    "readaloud": {
        "name": "Read Aloud (Edge voices)",
        "description": ("Reads the open book aloud with Microsoft Edge's neural voices, synthesized on the "
                        "device, and underlines each word as it is spoken. Bluetooth audio on Kindle."),
        "category": "reader",
        "tag_prefix": "readaloud-v",
    },
}

# Same regex ZenPM applies to _meta.lua on the device.
META_VERSION = re.compile(r"\bversion\s*=\s*[\"']([^\"']+)[\"']")


def plugin_dir(plugin: str) -> Path:
    return ROOT / f"{plugin}.koplugin"


def pkg_dir(plugin: str) -> Path:
    return OUT / "packages" / f"{plugin}.koplugin"


def plugin_version(plugin: str) -> str:
    m = META_VERSION.search((plugin_dir(plugin) / "_meta.lua").read_text())
    if not m:
        raise SystemExit(f"no version = \"...\" in {plugin}.koplugin/_meta.lua")
    return m.group(1).strip()


def load_versions(plugin: str) -> list[dict]:
    path = pkg_dir(plugin) / "versions.json"
    if not path.exists():
        return []
    return json.loads(path.read_text()).get("releases", [])


def version_of_tag(plugin: str, tag: str) -> str:
    for prefix in (PLUGINS[plugin]["tag_prefix"], f"{plugin}-v", "v"):
        if tag.startswith(prefix):
            return tag[len(prefix):]
    return tag


def package_entry(plugin: str, source: str) -> dict | None:
    """The manifest entry for a plugin from its newest recorded release."""
    releases = load_versions(plugin)
    if not releases:
        return None
    latest = releases[0]
    meta = PLUGINS[plugin]
    asset = (latest.get("assets") or [{}])[0]
    asset_name = f"{plugin}.koplugin.zip"
    size = str(asset.get("size", "") or "")
    return {
        "id": plugin,
        "name": meta["name"],
        "version": latest.get("version") or version_of_tag(plugin, latest["tag_name"]),
        "description": meta["description"],
        "author": "bunkford",
        "category": meta["category"],
        "platforms": ["koreader"],
        "dependencies": [],
        "source": source,
        "source_type": "release",
        "source_asset": asset_name,
        "plugin_module": plugin,
        "published_at": latest.get("published_at", ""),
        "readme_url": f"packages/{plugin}.koplugin/README.md",
        "release_notes_url": f"packages/{plugin}.koplugin/RELEASE_NOTES.md",
        "versions_url": f"packages/{plugin}.koplugin/versions.json",
        "size": size,
        "assets": [{"arch": "any", "asset": asset_name, "url": asset.get("url", ""), "size": size}],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--plugin", default="whispersync", choices=sorted(PLUGINS), help="which plugin this release is for")
    ap.add_argument("--tag", help="release tag (default <prefix><version>)")
    ap.add_argument("--asset-url", help="download URL of the zip (default: GitHub release URL for the tag)")
    ap.add_argument("--size", type=int, default=None)
    ap.add_argument("--sha256", default=None)
    ap.add_argument("--published", default=None, help="ISO-8601 UTC, default now")
    ap.add_argument("--source", default=DEFAULT_SOURCE, help="GitHub repository the releases live in")
    ap.add_argument("--repo-url", default=DEFAULT_REPO_URL, help="public URL of the zenpm/ directory")
    ap.add_argument("--prerelease", action="store_true")
    ap.add_argument("--manifest-only", action="store_true", help="only rebuild manifest.json from the recorded releases")
    args = ap.parse_args()

    plugin = args.plugin
    if not args.manifest_only:
        version = plugin_version(plugin)
        tag = args.tag or f"{PLUGINS[plugin]['tag_prefix']}{version}"
        asset_name = f"{plugin}.koplugin.zip"
        asset_url = args.asset_url or f"{args.source}/releases/download/{tag}/{asset_name}"
        published = args.published or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        asset = {"name": asset_name, "url": asset_url}
        if args.size:
            asset["size"] = args.size
        if args.sha256:
            asset["digest"] = "sha256:" + args.sha256.lower().removeprefix("sha256:")
        release = {"tag_name": tag, "name": tag, "version": version, "published_at": published, "assets": [asset]}
        if args.prerelease:
            release["prerelease"] = True

        releases = [r for r in load_versions(plugin) if r.get("tag_name") != tag]
        releases.insert(0, release)

        pkg = pkg_dir(plugin)
        pkg.mkdir(parents=True, exist_ok=True)
        (pkg / "versions.json").write_text(json.dumps({"releases": releases}, indent=2) + "\n")
        shutil.copyfile(plugin_dir(plugin) / "README.md", pkg / "README.md")
        shutil.copyfile(plugin_dir(plugin) / "CHANGELOG.md", pkg / "RELEASE_NOTES.md")
        print(f"{plugin}: recorded {tag} ({version}), {len(releases)} release(s) in versions.json")

    packages = []
    for name in PLUGINS:
        entry = package_entry(name, args.source)
        if entry:
            packages.append(entry)
    manifest = {
        "schema_version": "1",
        "repo": {
            "id": "bunkford-koreader-plugins",
            "name": "bunkford's KOReader plugins",
            "url": args.repo_url,
        },
        "packages": packages,
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("zenpm/manifest.json: " + ", ".join(f"{p['id']} {p['version']}" for p in packages))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
