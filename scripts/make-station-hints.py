#!/usr/bin/env python3
"""Builds BetterBahnKit's offline list of train stations (StationHints.json) from Transitous.

Station search uses it to find nearby stations by their first letters ("be" -> Bernau), which the
geocoder can't. Only names, rough positions and how busy a station is are kept; the app looks the
picked names up live, so the list doesn't go stale with Transitous' stop IDs. Rerun it now and
then (new stations): python3 scripts/make-station-hints.py
"""
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.transitous.org/api/v1/map/stops"
OUT = Path(__file__).resolve().parent.parent / "Packages/BetterBahnKit/Sources/BetterBahnKit/Resources/StationHints.json"
# Germany with a margin into its neighbours.
BOUNDS = (47.2, 5.8, 55.1, 15.1)
TRAIN = {"HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL", "REGIONAL_RAIL", "REGIONAL_FAST_RAIL", "SUBURBAN", "RAIL"}


def stops(lat1, lon1, lat2, lon2):
    query = urllib.parse.urlencode({"min": f"{lat1},{lon1}", "max": f"{lat2},{lon2}"})
    request = urllib.request.Request(f"{API}?{query}", headers={"User-Agent": "BetterBahn station hints"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code == 422:
                return None  # too many stops: split the tile
            time.sleep(2 ** attempt)
        except (urllib.error.URLError, TimeoutError):
            time.sleep(2 ** attempt)
    raise SystemExit(f"failed: {lat1},{lon1} {lat2},{lon2}")


def collect(lat1, lon1, lat2, lon2, found):
    time.sleep(0.5)
    result = stops(lat1, lon1, lat2, lon2)
    if result is None:
        mlat, mlon = (lat1 + lat2) / 2, (lon1 + lon2) / 2
        for a, b, c, d in [(lat1, lon1, mlat, mlon), (lat1, mlon, mlat, lon2), (mlat, lon1, lat2, mlon), (mlat, mlon, lat2, lon2)]:
            collect(a, b, c, d, found)
        return
    for stop in result:
        if TRAIN & set(stop.get("modes") or []):
            found.append(stop)
    print(f"{lat1:.2f},{lon1:.2f}: {len(found)} train stops", flush=True)


def main():
    found = []
    lat1, lon1, lat2, lon2 = BOUNDS
    lat = lat1
    while lat < lat2:
        lon = lon1
        while lon < lon2:
            collect(lat, lon, min(lat + 1, lat2), min(lon + 1, lon2), found)
            lon += 1
        lat += 1

    # The same station comes from several feeds, under several names: keep the busiest stop
    # within 300 m.
    found.sort(key=lambda s: -(s.get("importance") or 0))
    kept = []
    grid = {}
    for stop in found:
        cell = (round(stop["lat"] * 100), round(stop["lon"] * 100))
        neighbours = [k for dy in (-1, 0, 1) for dx in (-1, 0, 1) for k in grid.get((cell[0] + dy, cell[1] + dx), [])]
        if any(abs(k[1] - stop["lat"]) < 0.0027 and abs(k[2] - stop["lon"]) < 0.0045 for k in neighbours):
            continue
        entry = [stop["name"].strip(), round(stop["lat"], 3), round(stop["lon"], 3),
                 float(f"{stop.get('importance') or 0:.2g}")]
        grid.setdefault(cell, []).append(entry)
        kept.append(entry)
    kept.sort(key=lambda e: e[0])
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(kept, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"{len(kept)} stations -> {OUT}")


if __name__ == "__main__":
    main()
