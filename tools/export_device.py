#!/usr/bin/env python3
"""
Export the dashboard's Amazon device credentials for the KOReader plugin.

The Kindle dashboard (https://github.com/bunkford/Kindle-sync) registered a
virtual Kindle once (its secrets/config.json). The KOReader plugin can reuse
that registration instead of doing its own OAuth dance. Run this on the
dashboard host, pointing --config at that file if it is not in the default
place, and copy the resulting file to the Kindle at:

    koreader/settings/whispersync_device.json

then choose "Kindle Whispersync → Amazon account → Import credentials from
file" in KOReader, and delete the file afterwards.

Sharing one registration between the Pi and the Kindle is fine: it is just a
signing key. Amazon will attribute positions from both to the same device
name. Register separately from the plugin if you want them told apart.

    python3 tools/export_device.py                       # writes whispersync_device.json here
    python3 tools/export_device.py --config /path/to/kindle/secrets/config.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

DEFAULT_CONFIG = Path.home() / "kindle" / "secrets" / "config.json"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("-o", "--output", default="whispersync_device.json")
    ap.add_argument("--config", default=str(DEFAULT_CONFIG), help="the dashboard's secrets/config.json")
    args = ap.parse_args()

    cfg_path = Path(args.config)
    if not cfg_path.exists():
        print(f"no config at {cfg_path}; connect the dashboard first", file=sys.stderr)
        return 78
    cfg = json.loads(cfg_path.read_text())
    dev = cfg.get("device") or {}
    if not dev.get("adp_token") or not dev.get("device_private_key"):
        print("config.json has no device registration yet", file=sys.stderr)
        return 78

    out = {
        "adp_token": dev["adp_token"],
        "device_private_key": dev["device_private_key"],
        "marketplace": dev.get("marketplace", "us"),
        "device_serial": dev.get("device_serial"),
        "exported_from": "kindle-sync dashboard",
    }
    out_path = Path(args.output)
    out_path.write_text(json.dumps(out, indent=2))
    os.chmod(out_path, 0o600)
    print(f"wrote {out_path} ({out_path.stat().st_size} bytes, mode 0600)")
    print("copy it to the Kindle as koreader/settings/whispersync_device.json, import, then delete it")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
