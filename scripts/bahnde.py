#!/usr/bin/env python3
"""Asks bahn.de through our server (Server/bahnde-proxy) from a cloud session, for debugging.

    python3 scripts/bahnde.py 'reiseloesung/abfahrten?datum=2026-10-21&zeit=15:00:00&ortExtId=8011160&ortId=A%3D1%40L%3D8011160%40&mitVias=false'

The cloud environment's network secret adds the app token (`X-BetterBahn-Token`) on the way to our server, so the
script sends none itself. Prints the JSON answer.
"""
import json
import sys
import urllib.error
import urllib.request

BASE = "https://bahnde-proxy.tail6eed6b.ts.net/web/api/"


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: scripts/bahnde.py '<path below /web/api/ with query>'")
    try:
        with urllib.request.urlopen(BASE + sys.argv[1].lstrip("/"), timeout=30) as response:
            print(json.dumps(json.load(response), ensure_ascii=False, indent=1))
    except urllib.error.HTTPError as error:
        hint = " (no token: is the network secret for our server set in this environment?)" if error.code == 401 else ""
        sys.exit(f"{error.code} {error.read().decode(errors='replace')[:300]}{hint}")


if __name__ == "__main__":
    main()
