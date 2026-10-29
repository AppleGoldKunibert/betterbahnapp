#!/usr/bin/env python3
"""Builds BetterBahnKit's offline list of train stations (StationHints.json) from Transitous.

Station search uses it to find nearby stations by their first letters ("be" -> Bernau), which the
geocoder can't. Only names, rough positions and how busy a station is are kept; the app looks the
picked names up live, so the list doesn't go stale with Transitous' stop IDs. Rerun it now and
then (new stations): python3 scripts/make-station-hints.py

Transitous is a snapshot of whatever its feeds hold that day, so a rebuild never makes the list worse than
the one it replaces: a station missing this time (a line closed for works) keeps its old entry, and each
country's busyness keeps last time's level (a feed whose timetable ends early makes a whole country look
quieter).
"""
import json
import re
import statistics
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.transitous.org/api/v1/map/stops"
RESOURCES = Path(__file__).resolve().parent.parent / "Packages/BetterBahnKit/Sources/BetterBahnKit/Resources"
OUT = RESOURCES / "StationHints.json"
# Germany and its neighbours as far as StationHints.radius (150 km) reaches from it: Liège from Aachen,
# Wrocław from Görlitz.
BOUNDS = (46.2, 3.8, 56.4, 17.3)
TRAIN = {"HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL", "REGIONAL_RAIL", "REGIONAL_FAST_RAIL", "SUBURBAN", "RAIL"}
# Border and tariff points ("Kehl(Gr)", "Toender [Grenze]", "Aachen, Süd Grenze"): trains pass,
# nobody gets on (TransitousProvider.isBorderPoint). "Ahlbeck Grenze" is a station.
BORDER_POINT = re.compile(r"(\(Gr\)|\[Grenze\])\s*$|,[^,]*\bGrenze\b|^Grenze\b|Grænse|Tarifpunkt")
# The railways' own points along a line that some feeds list as stops: the Harz narrow-gauge railway's
# "Elend Drw_Eld 007", Czech kilometre posts ("Km 18,000"), junctions and passing loops ("hr.VUSC 0100/0200 01",
# "Tábor výh.č.501", "Pha hl.n. Lc105-102", "P.hl.n.-Vítkov v.301").
INTERNAL = re.compile(r"\b[A-Za-z]+[_-][A-Za-z]+ \d{3}( P\d)?$|^hr\.|^Km \d|\bvýh\.|\bLc\d|\bv\.\d{3}$|\bodb\.|^Odb ")
# A station's names that are worse than its others: a local transit authority's ("S Südkreuz Bhf (Berlin)",
# "S Ostbahnhof (Berlin)").
CLUMSY = re.compile(r"^[SU](\+U)? |\bBhf\b|\(Berlin\)$")
# Stops of one station are this close (degrees, about 300 m); a German station's name this far (about 5 km)
# from where DB has it is a feed's mistake ("Passau Hbf" 110 km south of Passau).
SAME = (0.0027, 0.0045)
MISPLACED = 0.05
# A country's busyness is only matched to last time's with this many stations in both.
MIN_MATCHES = 20


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
        if TRAIN & set(stop.get("modes") or []) and not BORDER_POINT.search(stop["name"]) \
                and not INTERNAL.search(stop["name"]):
            found.append(stop)
    print(f"{lat1:.2f},{lon1:.2f}: {len(found)} train stops", flush=True)


def readable(name):
    """A station's name as people know it: "Dortmund Hbf" for FlixTrain's "Dortmund Central Station
    (FlixTrain)", "Berlin Südkreuz" for "Berlin Südkreuz (FlixTrain)", "Karlsruhe Hbf" for "KARLSRUHE HBF"."""
    name = " ".join(name.split())
    if name.endswith(" Central Station (FlixTrain)"):
        return name[: -len(" Central Station (FlixTrain)")] + " Hbf"
    if name.endswith(" (FlixTrain)"):
        return name[: -len(" (FlixTrain)")]
    if name.isupper():
        keep = {"HBF": "Hbf", "BF": "Bf", "SBB": "SBB", "HB": "HB"}
        return " ".join(keep.get(word, word.capitalize() if "." not in word else word.title()) for word in name.split(" "))
    return name


class Places:
    """Entries by position, to find the ones within SAME of a point."""

    def __init__(self, entries):
        self.grid = {}
        for entry in entries:
            self.grid.setdefault(self.cell(entry[1], entry[2]), []).append(entry)

    @staticmethod
    def cell(lat, lon):
        return round(lat * 100), round(lon * 100)

    def near(self, lat, lon, within=SAME):
        cell = self.cell(lat, lon)
        found = [e for dy in (-1, 0, 1) for dx in (-1, 0, 1) for e in self.grid.get((cell[0] + dy, cell[1] + dx), [])
                 if abs(e[1] - lat) < within[0] and abs(e[2] - lon) < within[1]]
        return sorted(found, key=lambda e: (e[1] - lat) ** 2 + (e[2] - lon) ** 2)


def station_names():
    """DB's names of the German stations with their positions, and every name StationNames.json knows
    (the national railways' spellings abroad too)."""
    path = RESOURCES / "StationNames.json"
    if not path.exists():
        return {}, set()
    data = json.loads(path.read_text(encoding="utf-8"))
    german = {}
    for _, name, _, flat in data["germany"]:
        german.setdefault(name, []).extend(zip(flat[0::2], flat[1::2]))
    return german, set(german) | {row[0] for row in data["abroad"]}


def misplaced(name, lat, lon, german):
    """Whether name is a German station's that DB has somewhere else."""
    points = german.get(name)
    return bool(points) and all(abs(p[0] - lat) > MISPLACED or abs(p[1] - lon) > MISPLACED for p in points)


def main():
    previous = json.loads(OUT.read_text(encoding="utf-8")) if OUT.exists() else []
    before = Places(previous)
    german, known = station_names()

    found = []
    lat1, lon1, lat2, lon2 = BOUNDS
    lat = lat1
    while lat < lat2:
        lon = lon1
        while lon < lon2:
            collect(lat, lon, min(lat + 1, lat2), min(lon + 1, lon2), found)
            lon += 1
        lat += 1

    # The same station comes from several feeds, under several names: one entry for the stops within
    # 300 m, as busy as the busiest of them, with the trains of all of them.
    found.sort(key=lambda s: -(s.get("importance") or 0))
    clusters = []
    grid = {}
    for stop in found:
        cell = (round(stop["lat"] * 100), round(stop["lon"] * 100))
        neighbours = [c for dy in (-1, 0, 1) for dx in (-1, 0, 1) for c in grid.get((cell[0] + dy, cell[1] + dx), [])]
        near = next((c for c in neighbours
                     if abs(c["lat"] - stop["lat"]) < SAME[0] and abs(c["lon"] - stop["lon"]) < SAME[1]), None)
        name = readable(stop["name"])
        if near:
            near["modes"] |= set(stop.get("modes") or [])
            if name not in near["names"]:
                near["names"].append(name)
            continue
        cluster = {"names": [name], "lat": stop["lat"], "lon": stop["lon"], "tz": stop.get("tz"),
                   "importance": stop.get("importance") or 0, "modes": set(stop.get("modes") or [])}
        grid.setdefault(cell, []).append(cluster)
        clusters.append(cluster)

    entries = []
    for c in clusters:
        # All stops of a station are equally busy, so which feed's name comes first is chance: take DB's
        # name (or the national railway's abroad), else last time's, else one that isn't clumsy.
        names = [n for n in c["names"] if not misplaced(n, c["lat"], c["lon"], german)]
        if not names:
            continue
        old = {e[0] for e in before.near(c["lat"], c["lon"])}
        name = min(names, key=lambda n: (n not in known, n not in old, bool(CLUMSY.search(n)), names.index(n)))
        importance = c["importance"]
        # S-Bahn trains run so often that an S-Bahn-only halt looks as busy as a town's station:
        # count a quarter (TransitousProvider.suburbanDiscount).
        if "SUBURBAN" in c["modes"] and not (c["modes"] & (TRAIN - {"SUBURBAN"})):
            importance /= 4
        entries.append({"name": name, "lat": c["lat"], "lon": c["lon"], "tz": c["tz"], "importance": importance,
                        "old": before.near(c["lat"], c["lon"])})

    # Keep each country (time zone) as busy as last time: scale its stations by how much busier the ones
    # in both lists were before, in the middle.
    ratios = {}
    for e in entries:
        if e["old"] and e["old"][0][3] and e["importance"]:
            ratios.setdefault(e["tz"], []).append(e["old"][0][3] / e["importance"])
    factors = {tz: statistics.median(r) for tz, r in ratios.items() if len(r) >= MIN_MATCHES}
    for tz, factor in sorted(factors.items()):
        print(f"{tz}: busyness x{factor:.2f} to match last time ({len(ratios[tz])} stations)")

    kept = [[e["name"], round(e["lat"], 3), round(e["lon"], 3), float(f"{e['importance'] * factors.get(e['tz'], 1):.2g}")]
            for e in entries]

    # A station missing this time (no trains in the feeds right now) keeps last time's entry, unless the
    # list has it a little further away now.
    now = Places(kept)
    names_now = {}
    for e in kept:
        names_now.setdefault(e[0], []).append(e)
    missing = []
    for name, lat, lon, importance in previous:
        name = readable(name)
        if now.near(lat, lon) or BORDER_POINT.search(name) or INTERNAL.search(name) or misplaced(name, lat, lon, german):
            continue
        if any(abs(e[1] - lat) < 0.02 and abs(e[2] - lon) < 0.03 for e in names_now.get(name, [])):
            continue
        missing.append([name, lat, lon, importance])
    print(f"{len(missing)} stations kept from last time: {', '.join(e[0] for e in missing[:30])}")
    kept += missing

    kept.sort(key=lambda e: e[0])
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(kept, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"{len(kept)} stations -> {OUT}")


if __name__ == "__main__":
    main()
