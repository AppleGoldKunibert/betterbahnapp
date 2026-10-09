#!/usr/bin/env python3
"""Builds BetterBahnKit's offline list of RIL100 codes (Ril100.json) for station search (#165).

Source: "Infrastrukturdaten der DB InfraGO" (Deutsche Bahn AG, CC BY 4.0, updated yearly) from the
Mobilithek, https://mobilithek.info/offers/922109165921083392 (also on GovData). Its
"Betriebsstellen.csv" lists every operating point with its code ("Kürzel"), name and position, once
per line it lies on. Only stations and halts in service are kept, each code with all its positions
(big stations span several kilometres).

Stations abroad ("XS ZH" Zürich HB: X + country letter + station, Z for eastern Europe) are not in that
file. They come from DB InfraGO's "Übersicht der Betriebsstellen und deren Abkürzungen" (XLSX, newest sheet
first, https://www.dbinfrago.com/resource/blob/12593004/d363d64ef7ecc1792c1518075d8ea769/Download-betriebsstellen-data.xlsx),
which has names but no positions, so they are kept with an empty position list and matched by name.
Needs `pip install openpyxl`. Rerun it when DB publishes a new year:

    curl -o infra.zip https://mobilithek.info/mdp-api/files/aux/922109165921083392/Infrastrukturdaten.zip
    unzip infra.zip && python3 scripts/make-ril100.py "M1 Betriebsstellen.csv" Download-betriebsstellen-data.xlsx
"""
import csv
import json
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "Packages/BetterBahnKit/Sources/BetterBahnKit/Resources/Ril100.json"
# Positions of one code closer than this (degrees, about 50 m) count as one.
SAME_POINT = 0.0005


def number(text):
    return float(text.replace(",", "."))


# Types of the XLSX that are stations or halts ("Bf" Bahnhof, "Bft" part of one, "Hp" Haltepunkt, "Hst" Haltestelle).
ABROAD_TYPES = {"Bf", "Bft", "Hp", "Hst"}


def abroad(path):
    """Codes of stations abroad (not "ehemals") from the newest sheet of DB's XLSX: (code, name) pairs."""
    import openpyxl
    sheet = openpyxl.load_workbook(path, read_only=True).worksheets[0]
    found = {}
    for row in sheet.iter_rows(min_row=5, values_only=True):
        code = " ".join(str(row[1] or "").split())
        if code[:1] not in ("X", "Z") or row[4] not in ABROAD_TYPES or row[5] == "ehemals":
            continue
        found.setdefault(code, " ".join(str(row[2] or "").split()))
    return found


def main(path, abroad_path=None):
    stations = {}
    with open(path, encoding="utf-8-sig", newline="") as file:
        for row in csv.DictReader(file, delimiter=";"):
            kind = row["Art lang"]
            if row["Betriebszustand"] != "in Betrieb" or not ("Bahnhof" in kind or "Haltepunkt" in kind):
                continue
            code = " ".join(row["Kürzel"].split())
            name = " ".join(row["Bezeichnung"].split())
            point = (round(number(row["Geographische Breite (EPSG 4326)"]), 4),
                     round(number(row["Geographische Länge (EPSG 4326)"]), 4))
            name_, points = stations.setdefault(code, (name, []))
            if all(abs(point[0] - p[0]) > SAME_POINT or abs(point[1] - p[1]) > SAME_POINT for p in points):
                points.append(point)
    if abroad_path:
        for code, name in abroad(abroad_path).items():
            stations.setdefault(code, (name, []))
    rows = [[code, name, [x for point in points for x in point]] for code, (name, points) in sorted(stations.items())]
    with open(OUT, "w", encoding="utf-8") as file:
        file.write("[\n")
        file.write(",\n".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) for row in rows))
        file.write("\n]\n")
    print(f"{len(rows)} codes -> {OUT}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "M1 Betriebsstellen.csv", sys.argv[2] if len(sys.argv) > 2 else None)
