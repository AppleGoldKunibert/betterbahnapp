#!/usr/bin/env python3
"""Keeps what a rebuild of StationNames.json and Platforms.json lost (.github/workflows/monthly-data-update.yml).

The sources are snapshots: a Transitous feed missing that day drops the stations abroad it names, and an
OpenStreetMap edit can drop a platform's lift or a whole track. A monthly rebuild should only make the lists
better, so after make-station-names.py and make-platforms.py this puts back from the committed files:

- StationNames.json: German stations whose EVA numbers (or DHID) and name aren't in the new list, other railways'
  names of a station that is still there, and stations abroad not in the new list under that name.
- Platforms.json: stations and tracks that are gone, a track that lost stairs, a lift or its exit (the old
  track instead), and shared platforms that are gone. An old track far from the station's new ones isn't
  put back: it was another station's platform.

Real removals then stay until someone takes them out by hand; the app looks every name up live anyway.

    python3 scripts/keep-previous-data.py [git ref of the old files, default HEAD]
"""
import json
import math
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = "Packages/BetterBahnKit/Sources/BetterBahnKit/Resources"
# Stops of one name this close (degrees, about 500 m) are one station (make-station-names.py).
SAME_STATION = 0.005
# How far (metres) a lost track's platform may be from the station's other tracks to be put back.
NEAR_TRACK = 300


def committed(ref, name):
    result = subprocess.run(["git", "show", f"{ref}:{RESOURCES}/{name}"], cwd=ROOT, capture_output=True, text=True)
    return json.loads(result.stdout) if result.returncode == 0 else None


def station_key(row):
    """What tells two rows of the German stations apart: the EVA numbers, else the DHID, else the name."""
    dhid, name, evas, _ = row
    return set(evas) or {dhid or name}


def station_names(old):
    path = ROOT / RESOURCES / "StationNames.json"
    new = json.loads(path.read_text(encoding="utf-8"))
    germany = new["germany"]

    known, names = set(), {row[1] for row in germany}
    for row in germany:
        known |= station_key(row)
    # A station under new EVA numbers keeps its name: that's the new row, not a lost one.
    lost = [row for row in old["germany"] if not station_key(row) & known and row[1] not in names]
    germany = sorted(germany + lost, key=lambda row: (row[0] or "~", row[1]))
    index = {}
    for number, row in enumerate(germany):
        for key in station_key(row):
            index.setdefault(key, number)

    def renumbered(rows, stations):
        """The rows with the index of their station in the merged list."""
        out = []
        for name, lat, lon, station in rows:
            number = next((index[k] for k in station_key(stations[station]) if k in index), None)
            if number is not None:
                out.append([name, lat, lon, number])
        return out

    aliases = renumbered(new["aliases"], new["germany"])
    lost_aliases = [row for row in renumbered(old["aliases"], old["germany"])
                    if not any(a[0] == row[0] and a[3] == row[3] for a in aliases)]
    aliases = sorted(aliases + lost_aliases)

    abroad = new["abroad"]
    lost_abroad = [row for row in old["abroad"]
                   if not any(a[0] == row[0] and abs(a[1] - row[1]) < SAME_STATION and abs(a[2] - row[2]) < SAME_STATION
                              for a in abroad)]
    abroad = sorted(abroad + lost_abroad)

    with open(path, "w", encoding="utf-8") as file:
        for key, rows in [("germany", germany), ("aliases", aliases), ("abroad", abroad)]:
            file.write(('{"' if key == "germany" else '],"') + key + '":[\n')
            file.write(",\n".join(json.dumps(list(row), ensure_ascii=False, separators=(",", ":")) for row in rows))
            file.write("\n")
        file.write("]}\n")
    print(f"StationNames.json: kept {len(lost)} German stations ({', '.join(r[1] for r in lost[:20])}), "
          f"{len(lost_aliases)} other names, {len(lost_abroad)} stations abroad "
          f"({', '.join(r[0] for r in lost_abroad[:20])})")


def natural(track):
    """Sorts "9" before "10" and "1a" after "1" (make-platforms.py)."""
    digits = len(track) - len(track.lstrip("0123456789"))
    return (int(track[:digits]), track[digits:]) if digits else (10**6, track)


def middle(track):
    return (track[0] + track[2]) / 2, (track[1] + track[3]) / 2


def distance(a, b):
    """Metres between two (lat, lon) points."""
    dlat, dlon = math.radians(b[0] - a[0]), math.radians(b[1] - a[1])
    h = math.sin(dlat / 2) ** 2 + math.cos(math.radians(a[0])) * math.cos(math.radians(b[0])) * math.sin(dlon / 2) ** 2
    return 2 * 6_371_000 * math.atan2(math.sqrt(h), math.sqrt(1 - h))


def worse(old, new):
    """Whether a track's new entry lost stairs, a lift or its exit."""
    before, after = Counter(kind for kind, _ in old[5]), Counter(kind for kind, _ in new[5])
    return any(after[kind] < count for kind, count in before.items())


def platforms(old):
    path = ROOT / RESOURCES / "Platforms.json"
    new = json.loads(path.read_text(encoding="utf-8"))
    changes = []
    for eva, before in old.items():
        if eva not in new:
            new[eva] = before
            changes.append(f"{eva} (all)")
            continue
        entry = new[eva]
        tracks = dict(entry.get("t", {}))
        # An old track far from all new ones was another station's platform (Wuppertal Hbf's at
        # Wuppertal-Steinbeck): that's a fix, not a loss.
        middles = [middle(v) for v in tracks.values()]
        kept = [t for t, v in before.get("t", {}).items()
                if (t not in tracks or worse(v, tracks[t]))
                and (not middles or min(distance(middle(v), m) for m in middles) < NEAR_TRACK)]
        for track in kept:
            tracks[track] = before["t"][track]
        pairs = list(entry.get("p", []))
        lost_pairs = [p for p in before.get("p", []) if not any(set(p) <= set(q) for q in pairs)]
        pairs += lost_pairs
        if not kept and not lost_pairs:
            continue
        merged = {}
        if pairs:
            merged["p"] = sorted(pairs, key=lambda p: [natural(t) for t in p])
        if tracks:
            merged["t"] = dict(sorted(tracks.items(), key=lambda kv: natural(kv[0])))
        new[eva] = merged
        changes.append(f"{eva} ({', '.join(['track ' + t for t in kept] + ['/'.join(p) for p in lost_pairs])})")

    with open(path, "w", encoding="utf-8") as file:
        file.write("{\n")
        file.write(",\n".join(f"{json.dumps(eva)}:{json.dumps(entry, ensure_ascii=False, separators=(',', ':'))}"
                              for eva, entry in sorted(new.items())))
        file.write("\n}\n")
    print(f"Platforms.json: kept {len(changes)} stations' old data: {', '.join(changes[:30])}")


def main(ref="HEAD"):
    names = committed(ref, "StationNames.json")
    if names:
        station_names(names)
    tracks = committed(ref, "Platforms.json")
    if tracks:
        platforms(tracks)


if __name__ == "__main__":
    main(*sys.argv[1:])
