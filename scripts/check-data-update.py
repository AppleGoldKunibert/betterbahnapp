#!/usr/bin/env python3
"""Sanity check for the monthly data update (.github/workflows/monthly-data-update.yml).

Compares the three rebuilt offline lists in the working tree with the committed ones and prints a
Markdown table of their sizes (used as the PR description). Exits with an error when a list is empty
or shrank by more than 10 %, which means a source failed or changed its format, so a broken file
doesn't end up in a PR:  python3 scripts/check-data-update.py
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = "Packages/BetterBahnKit/Sources/BetterBahnKit/Resources"
MAX_SHRINK = 0.10


def sizes(data):
    """Entry counts per list: StationNames.json has three lists, the other files one."""
    if isinstance(data, dict):
        return {key: len(rows) for key, rows in data.items()}
    return {"": len(data)}


def committed(name):
    result = subprocess.run(["git", "show", f"HEAD:{RESOURCES}/{name}"], cwd=ROOT, capture_output=True, text=True)
    return sizes(json.loads(result.stdout)) if result.returncode == 0 else {}


def main():
    failed = False
    print("| File | List | Before | After | Change |\n| --- | --- | ---: | ---: | ---: |")
    for name in ("Ril100.json", "StationHints.json", "StationNames.json"):
        now = sizes(json.loads((ROOT / RESOURCES / name).read_text(encoding="utf-8")))
        before = committed(name)
        for key, count in now.items():
            old = before.get(key, 0)
            label = f"{name} ({key})" if key else name
            if count == 0 or (old and count < old * (1 - MAX_SHRINK)):
                print(f"::error::{label} has {count} entries, was {old}", file=sys.stderr)
                failed = True
            print(f"| `{name}` | {key or 'all'} | {old} | {count} | {count - old:+d} |")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
