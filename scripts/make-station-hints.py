#!/usr/bin/env python3
"""Builds BetterBahnKit's offline list of train stations (StationHints.json) from Transitous.

Station search uses it to find nearby stations by their first letters ("be" -> Bernau), which the
geocoder can't. Only names, rough positions and how busy a station is are kept; the app looks the
picked names up live, so the list doesn't go stale with Transitous' stop IDs. Rerun it now and
then (new stations): python3 scripts/make-station-hints.py
"""
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.transitous.org/api/v1/map/stops"
OUT = Path(__file__).resolve().parent.parent / "Packages/BetterBahnKit/Sources/BetterBahnKit/Resources/StationHints.json"
# Germany and its neighbours as far as StationHints.radius (150 km) reaches from it: Liège from Aachen,
# Wrocław from Görlitz.
BOUNDS = (46.2, 3.8, 56.4, 17.3)
TRAIN = {"HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL", "REGIONAL_RAIL", "REGIONAL_FAST_RAIL", "SUBURBAN", "RAIL"}
# Border and tariff points ("Kehl(Gr)", "Toender [Grenze]", "Aachen, Süd Grenze"): trains pass,
# nobody gets on (TransitousProvider.isBorderPoint). "Ahlbeck Grenze" is a station.
BORDER_POINT = re.compile(r"(\(Gr\)|\[Grenze\])\s*$|,[^,]*\bGrenze\b|^Grenze\b|Grænse|Tarifpunkt")


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
        if TRAIN & set(stop.get("modes") or []) and not BORDER_POINT.search(stop["name"]):
            found.append(stop)
    print(f"{lat1:.2f},{lon1:.2f}: {len(found)} train stops", flush=True)


def readable(name):
    """A station's name as people know it: "Dortmund Hbf" for FlixTrain's "Dortmund Central Station
    (FlixTrain)", "Karlsruhe Hbf" for "KARLSRUHE HBF"."""
    if name.endswith(" Central Station (FlixTrain)"):
        return name[: -len(" Central Station (FlixTrain)")] + " Hbf"
    if name.isupper():
        keep = {"HBF": "Hbf", "BF": "Bf", "SBB": "SBB", "HB": "HB"}
        return " ".join(keep.get(word, word.capitalize() if "." not in word else word.title()) for word in name.split(" "))
    return name


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
    # within 300 m, with the trains of all of them.
    found.sort(key=lambda s: -(s.get("importance") or 0))
    clusters = []
    grid = {}
    for stop in found:
        cell = (round(stop["lat"] * 100), round(stop["lon"] * 100))
        neighbours = [c for dy in (-1, 0, 1) for dx in (-1, 0, 1) for c in grid.get((cell[0] + dy, cell[1] + dx), [])]
        near = next((c for c in neighbours
                     if abs(c["lat"] - stop["lat"]) < 0.0027 and abs(c["lon"] - stop["lon"]) < 0.0045), None)
        if near:
            near["modes"] |= set(stop.get("modes") or [])
            continue
        cluster = {"name": stop["name"].strip(), "lat": stop["lat"], "lon": stop["lon"],
                   "importance": stop.get("importance") or 0, "modes": set(stop.get("modes") or [])}
        grid.setdefault(cell, []).append(cluster)
        clusters.append(cluster)

    kept = []
    for c in clusters:
        importance = c["importance"]
        # S-Bahn trains run so often that an S-Bahn-only halt looks as busy as a town's station:
        # count a quarter (TransitousProvider.suburbanDiscount).
        if "SUBURBAN" in c["modes"] and not (c["modes"] & (TRAIN - {"SUBURBAN"})):
            importance /= 4
        kept.append([readable(c["name"]), round(c["lat"], 3), round(c["lon"], 3), float(f"{importance:.2g}")])
    kept.sort(key=lambda e: e[0])
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(kept, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"{len(kept)} stations -> {OUT}")


if __name__ == "__main__":
    main()
