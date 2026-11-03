#!/usr/bin/env python3
"""Makes or extends `tz_seed.json` (#502): every ICE/IC trainset (Tz) with the UIC number of one of its coaches.

    python3 Server/bahnde-proxy/make_tz_seed.py [--seed tz_seed.json] [--interval 3]

It reads the ICE/IC departure boards of `tzlog.SEED_HUBS` (together they list every run) from now until midnight,
asks the Wagenreihung of each train through our server, and checks every coach it found against the WiFi host
(`RisClient`: the coach's trainset there must be the same Tz). What it finds is added to the seed file; Tz already
in it stay. One run sees the trains of the rest of the day, so run it on a few days until the list stops growing.
The server itself only needs the file: it never reads all boards again (see `tzlog.py`).

From a cloud session the environment's network secret adds the app token (as for `scripts/bahnde.py`); on a Mac set
`BAHNDE_PROXY_TOKEN` to a valid App Attest token. About 700 requests at `--interval` seconds apart.
"""

import argparse
import asyncio
import json
import logging
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import tzlog  # noqa: E402

BASE = os.environ.get("BAHNDE_PROXY", "https://bahnde-proxy.tail6eed6b.ts.net") + "/web/api/"


def fetch(path):
    request = urllib.request.Request(BASE + path, headers={"Accept": "application/json"})
    if os.environ.get("BAHNDE_PROXY_TOKEN"):
        request.add_header("X-BetterBahn-Token", os.environ["BAHNDE_PROXY_TOKEN"])
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, None
    except (OSError, ValueError):
        return 599, None


async def get(path):
    return await asyncio.to_thread(fetch, path)


async def main(seed_path, interval):
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    store = tzlog.TzStore()
    scanner = tzlog.Scanner(store, get, hubs=tzlog.SEED_HUBS, interval=interval, every=24 * 3600, ris=None)
    await scanner.scan()
    found = {tz: (unit, types, vehicle) for tz, unit, types, vehicle in store.db.execute(
        "SELECT tz, unit, types, vehicle FROM units WHERE vehicle IS NOT NULL")}

    print(f"boards done: {len(found)} trainsets, checking their coaches at the WiFi host", flush=True)
    seed = {item["tz"]: item for item in json.loads(seed_path.read_text(encoding="utf-8"))} if seed_path.exists() else {}
    ris = tzlog.RisClient()
    today = tzlog.dt.datetime.now(tzlog.BERLIN).date().isoformat()
    added = rejected = 0
    try:
        for tz, (unit, types, vehicle) in sorted(found.items(), key=lambda item: int(item[0])):
            if tz in seed:
                continue
            await asyncio.sleep(1)
            status, body = await asyncio.wait_for(ris(vehicle, today), timeout=60)
            group, _ = tzlog.parse_vehicle_journeys(body)
            if status == 200 and group == tz:
                seed[tz] = {"tz": tz, "unit": unit, "types": json.loads(types), "vehicle": vehicle}
                added += 1
                if added % 20 == 0:
                    print(f"  {added} confirmed", flush=True)
            else:
                rejected += 1
                print(f"Tz {tz}: coach {vehicle} is in {group or 'no trainset'} at the WiFi host ({status}), skipped")
    finally:
        await ris.close()
    ordered = [seed[tz] for tz in sorted(seed, key=int)]
    seed_path.write_text(json.dumps(ordered, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{len(found)} trainsets on today's boards, {added} new, {rejected} skipped, {len(ordered)} in {seed_path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--seed", type=Path, default=Path(__file__).parent / "tz_seed.json")
    parser.add_argument("--interval", type=float, default=3.0, help="seconds between two requests to bahn.de")
    arguments = parser.parse_args()
    asyncio.run(main(arguments.seed, arguments.interval))
