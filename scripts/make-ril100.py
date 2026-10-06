#!/usr/bin/env python3
"""Builds BetterBahnKit's offline list of RIL100 codes (Ril100.json) for station search (#165).

Source: the npm package db-stations (https://github.com/derhuerst/db-stations), which bundles DB
Station&Service's station data (StaDa, CC BY 4.0). Every station with its EVA number, name, position
and RIL100 codes, the main one first ("Berlin Hauptbahnhof": BHBF, BL, BLS). Rerun it now and then:

    npm pack db-stations && tar xzf db-stations-*.tgz
    python3 scripts/make-ril100.py package/full.ndjson
"""
import json
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "Packages/BetterBahnKit/Sources/BetterBahnKit/Resources/Ril100.json"


def codes(station):
    identifiers = sorted(station.get("ril100Identifiers") or [], key=lambda i: not i.get("isMain"))
    found = [" ".join(i["rilIdentifier"].split()) for i in identifiers]
    if not found and station.get("ril100"):
        found = [" ".join(station["ril100"].split())]
    return list(dict.fromkeys(found))


def main(path):
    rows = []
    with open(path, encoding="utf-8") as file:
        for line in file:
            station = json.loads(line)
            location = station.get("location") or {}
            found = codes(station)
            if not found or "latitude" not in location:
                continue
            rows.append([station["name"], round(location["latitude"], 5), round(location["longitude"], 5),
                         found, station["id"]])
    rows.sort(key=lambda row: row[0])
    with open(OUT, "w", encoding="utf-8") as file:
        file.write("[\n")
        file.write(",\n".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) for row in rows))
        file.write("\n]\n")
    print(f"{len(rows)} stations -> {OUT}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "package/full.ndjson")
