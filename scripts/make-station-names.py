#!/usr/bin/env python3
"""Builds BetterBahnKit's offline list of station names (StationNames.json), shown instead of the feeds' own (#205).

Germany: DB InfraGO's "OpenStation NeTEx" (Deutsche Bahn AG, CC0 1.0) from the Mobilithek,
https://mobilithek.info/offers/879076212433727488: every DB station with its DHID, EVA numbers, RIL100
codes and name ("Dresden-Neustadt" for DELFI's "Dresden Bahnhof Neustadt"). It has no positions, so each
station gets those of its RIL100 codes from Ril100.json (scripts/make-ril100.py). About one name in ten
isn't the one DB shows passengers ("Barmbek" for "Hamburg-Barmbek", "Celle Pbf" for "Celle"), so the
name comes from DB's RIS as bahn.expert's station search has it, found by EVA number. bahn.expert is
unofficial, and asking it for every station takes about an hour: names already in StationNames.json are
kept (by EVA numbers), so a rerun only asks for new stations; --refresh asks for all again.

Abroad: the national railways' names with their accents ("Děčín hlavní nádraží"), as Transitous has them
from their own feeds; DELFI and others write them without ("Decin hl.n."). Only names with letters outside
ASCII are kept, none at a German station, and those without accents that are the same as one with them
(Polish "Kolin", Czech "Kolín"), so the app knows which needs its position.

    curl -L --compressed -o netex.xml https://bahnhof.de/daten/netex
    python3 scripts/make-station-names.py netex.xml [--refresh]
"""
import json
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

RESOURCES = Path(__file__).resolve().parent.parent / "Packages/BetterBahnKit/Sources/BetterBahnKit/Resources"
OUT = RESOURCES / "StationNames.json"
NETEX = "{http://www.netex.org.uk/netex}"
API = "https://api.transitous.org/api/v1/map/stops"
EXPERT = "https://bahn.expert/api/orpc/stopPlace/byTerm"
# bahn.expert only answers requests that say they come from its own site (see BahnExpertClient).
EXPERT_HEADERS = {"Content-Type": "application/json", "Accept": "application/json",
                  "Referer": "https://bahn.expert/", "User-Agent": "BetterBahn station names"}
TRAIN = {"HIGHSPEED_RAIL", "LONG_DISTANCE", "NIGHT_RAIL", "REGIONAL_RAIL", "REGIONAL_FAST_RAIL", "SUBURBAN", "RAIL"}
BORDER_POINT = re.compile(r"(\(Gr\)|\[Grenze\])\s*$|,[^,]*\bGrenze\b|^Grenze\b|Grænse|Tarifpunkt")

# The national railways' feeds in Transitous, each with the stop IDs that are its own country's (the
# ÖBB's and SBB's feeds also have stops abroad) and its country's rough borders (south, west, north, east).
ABROAD = [
    ("cz-CZPTT_", ":CZ:", (48.5, 12.0, 51.1, 18.9)),
    ("pl-PKP-Intercity_", "", (49.0, 14.1, 54.9, 24.2)),
    ("pl-Polish-Trains_", "", (49.0, 14.1, 54.9, 24.2)),
    ("sk-zsr_", "", (47.7, 16.8, 49.7, 22.6)),
    ("hu-mav_", "", (45.7, 16.1, 48.6, 22.9)),
    ("si-nap_", "", (45.4, 13.3, 46.9, 16.7)),
    ("at-Railway-Current-Reference-Data", "_at:", (46.3, 9.5, 49.1, 17.2)),
    ("ch-opentransportdataswiss", "_ch:", (45.8, 5.9, 47.9, 10.6)),
    ("dk-rejseplanen_", "", (54.5, 8.0, 57.8, 15.3)),
    ("se-Trafiklab_", "", (55.3, 10.9, 60.5, 19.0)),
]
# A stop abroad this close (degrees, about 1 km) to a German station is that station, under another name.
NEAR_GERMAN_STATION = 0.01
# Stops of one name this close (about 500 m) are one station.
SAME_STATION = 0.005


def dhid_key(dhid):
    """"de:08135:0620" and "de:08135:620:1" are both "de:08135:620": DELFI writes the stop number with
    leading zeros, OpenStation sometimes adds a level."""
    parts = dhid.split(":")
    if len(parts) < 3 or parts[0] != "de" or not parts[2].isdigit():
        return ""
    return f"de:{parts[1]}:{int(parts[2])}"


def german_stations(netex_path):
    """(DHID key, name, EVA numbers, RIL100 codes) per DB station."""
    stations = []
    for _, element in ET.iterparse(netex_path, events=("end",)):
        if element.tag != NETEX + "StopPlace":
            continue
        keys = [(kv.findtext(NETEX + "Key"), kv.findtext(NETEX + "Value"))
                for kv in element.findall(f"{NETEX}keyList/{NETEX}KeyValue")]
        parent = element.find(NETEX + "ParentSiteRef")
        ref = parent.get("ref") if parent is not None else ""
        name = " ".join((element.findtext(NETEX + "Name") or "").split())
        if name:
            stations.append((dhid_key(ref[5:]) if ref.startswith("dhid:") else "", name,
                             [v for k, v in keys if k == "EVA"], [v for k, v in keys if k == "RIL"]))
        element.clear()
    return stations


def expert_search(term):
    """bahn.expert's station search: DB's stops for `term`, each with its EVA number and RIS name."""
    request = urllib.request.Request(EXPERT, data=json.dumps({"json": {"searchTerm": term}}).encode(),
                                     headers=EXPERT_HEADERS, method="POST")
    for attempt in range(4):
        try:
            time.sleep(0.3)
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)["json"]
        except (urllib.error.URLError, TimeoutError):
            time.sleep(2 ** attempt)
    raise SystemExit(f"bahn.expert failed for {term!r}")


def ris_name(name, evas):
    """DB's own name for a station (RIS, as bahn.de shows it): asked for OpenStation's name, without its
    part in brackets, then its town, until a hit has one of the station's EVA numbers; None if none has."""
    terms = [name, re.sub(r"\s*\([^)]*\)", "", name), re.split(r"[ (/-]", name)[0]]
    for term in dict.fromkeys(term for term in terms if term):
        for hit in expert_search(term):
            if hit.get("evaNumber") in evas:
                return hit["name"]
    return None


def shown_name(openstation, ris):
    """RIS's name, but OpenStation's when the two only differ in spaces: it writes "Neukirch (Lausitz) West"
    where RIS has "Neukirch(Lausitz)West"."""
    if ris is None or ris.replace(" ", "") == openstation.replace(" ", ""):
        return openstation
    return ris


def known_names():
    """The names StationNames.json already has, by EVA numbers."""
    if not OUT.exists():
        return {}
    return {tuple(row[2]): row[1] for row in json.loads(OUT.read_text())["germany"] if row[2]}


def ril100_points():
    """Positions per RIL100 code, from Ril100.json."""
    rows = json.loads((RESOURCES / "Ril100.json").read_text())
    return {" ".join(code.split()): list(zip(flat[0::2], flat[1::2])) for code, _, flat in rows}


def stops(lat1, lon1, lat2, lon2):
    query = urllib.parse.urlencode({"min": f"{lat1},{lon1}", "max": f"{lat2},{lon2}"})
    request = urllib.request.Request(f"{API}?{query}", headers={"User-Agent": "BetterBahn station names"})
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
            found[stop["stopId"]] = stop
    print(f"{lat1:.2f},{lon1:.2f}: {len(found)} train stops", flush=True)


def abroad_stations(german_points):
    """(name, lat, lon) of the national railways' stations whose names have accents."""
    found = {}
    for south, west, north, east in sorted({box for _, _, box in ABROAD}):
        lat = south
        while lat < north:
            lon = west
            while lon < east:
                collect(lat, lon, min(lat + 1, north), min(lon + 1, east), found)
                lon += 1
            lat += 1
    grid = {}
    for lat, lon in german_points:
        grid.setdefault((round(lat * 100), round(lon * 100)), []).append((lat, lon))

    def near_german_station(lat, lon):
        cell = (round(lat * 100), round(lon * 100))
        return any(abs(p[0] - lat) < NEAR_GERMAN_STATION and abs(p[1] - lon) < NEAR_GERMAN_STATION
                   for dy in (-1, 0, 1) for dx in (-1, 0, 1) for p in grid.get((cell[0] + dy, cell[1] + dx), []))

    national = []
    for stop_id, stop in sorted(found.items()):
        name = " ".join(stop["name"].split())
        lat, lon = stop["lat"], stop["lon"]
        if BORDER_POINT.search(name) or near_german_station(lat, lon):
            continue
        if not any(stop_id.startswith(feed) and part in stop_id and south <= lat <= north and west <= lon <= east
                   for feed, part, (south, west, north, east) in ABROAD):
            continue
        if any(k[0] == name and abs(k[1] - lat) < SAME_STATION and abs(k[2] - lon) < SAME_STATION for k in national):
            continue
        national.append((name, round(lat, 3), round(lon, 3)))
    accented = {plain(name) for name, _, _ in national if not name.isascii()}
    return sorted(row for row in national if not row[0].isascii() or plain(row[0]) in accented)


def plain(name):
    """A name as the app compares stations abroad (StationNames.abroadKey): shortened, without accents and
    case, "ö"/"oe" alike, only letters and digits."""
    for long, short in [(" hlavní nádraží", " hl.n."), (" hlavná stanica", " hl.st.")]:
        if name.endswith(long) and len(name) > len(long):
            name = name[: -len(long)] + short
    for a, b in [("ß", "ss"), ("ł", "l"), ("Ł", "L"), ("ø", "o"), ("Ø", "O"), ("æ", "ae"), ("Æ", "Ae"), ("đ", "d"), ("Đ", "D")]:
        name = name.replace(a, b)
    name = "".join(c for c in unicodedata.normalize("NFKD", name).lower() if not unicodedata.combining(c))
    for a, b in [("oe", "o"), ("ae", "a"), ("ue", "u"), ("aa", "a")]:
        name = name.replace(a, b)
    return "".join(c for c in name if c.isalnum())


def main(netex_path, refresh=False):
    points_by_code = ril100_points()
    known = {} if refresh else known_names()
    germany = []
    keys = set()
    for number, (dhid, name, evas, codes) in enumerate(german_stations(netex_path)):
        evas = sorted(evas)
        if tuple(evas) in known:
            name = known[tuple(evas)]
        elif evas:
            name = shown_name(name, ris_name(name, evas))
            print(f"{number}: {name}", flush=True)
        points = []
        for code in codes:
            for lat, lon in points_by_code.get(" ".join(code.split()), []):
                if all(abs(lat - p[0]) > 0.001 or abs(lon - p[1]) > 0.001 for p in points):
                    points.append((lat, lon))
        if dhid in keys:
            dhid = ""  # two stations under one DHID: found by EVA number or position instead
        keys.add(dhid)
        germany.append([dhid, name, evas, [x for point in points for x in point]])
    germany.sort(key=lambda row: (row[0] or "~", row[1]))
    abroad = abroad_stations([p for row in germany for p in zip(row[3][0::2], row[3][1::2])])
    with open(OUT, "w", encoding="utf-8") as file:
        file.write('{"germany":[\n')
        file.write(",\n".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) for row in germany))
        file.write('\n],"abroad":[\n')
        file.write(",\n".join(json.dumps(list(row), ensure_ascii=False, separators=(",", ":")) for row in abroad))
        file.write("\n]}\n")
    print(f"{len(germany)} German and {len(abroad)} stations abroad -> {OUT}")


if __name__ == "__main__":
    arguments = [a for a in sys.argv[1:] if a != "--refresh"]
    main(arguments[0] if arguments else "netex.xml", refresh="--refresh" in sys.argv)
