#!/usr/bin/env python3
"""Builds BetterBahnKit's offline platform data (Platforms.json) for the coach advice (#383): which tracks of a
DB station share one platform, and where along each track's platform the stairs, lifts and the exit are.

Which tracks share a platform comes from DB InfraGO's "OpenStation NeTEx" (Deutsche Bahn AG, CC0 1.0, the
same file as for make-station-names.py): every platform ("Bahnsteig Gleis 11/12") lists its tracks. It also
has the lifts' positions on some platforms, but none of the stairs.

The stairs, escalators, lifts and buffer stops come from OpenStreetMap (© OpenStreetMap contributors, ODbL
1.0, so Platforms.json is under the ODbL too): each track's platform edge (`railway=platform_edge` with the
track as `ref`), else the platform with the tracks as `ref` ("11;12", drawn as a way or a multipolygon) and
its long axis, the stairs and lifts on that platform, and the sector signs (`railway:platform:section`),
which tie the positions to bahn.de's sectors. At a terminus like Frankfurt Hbf the end at the buffer stops
is the platform's exit: most of its tracks end at buffer stops side by side, and no track above ground
(OSM's `railway=rail`) runs on past them, as through tracks do beside bay platforms. Stations get their
positions from Ril100.json, as in make-station-names.py, and each platform edge goes to the nearest station
that has its track.

Per EVA number: {"p": [["11", "12"], …], "t": {"11": [lat, lon, lat, lon, length, [[kind, m], …],
[[sector, m], …]], …}}, the edge from its first to its last point (positions in metres from the first),
kinds "s" (stairs, escalator), "l" (lift) and "x" (the exit at a terminus).

    curl -L --compressed -o netex.xml https://bahnhof.de/daten/netex
    curl -L -o germany.osm.pbf https://download.geofabrik.de/europe/germany-latest.osm.pbf
    pip install osmium
    python3 scripts/make-platforms.py netex.xml germany.osm.pbf
"""
import json
import math
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

RESOURCES = Path(__file__).resolve().parent.parent / "Packages/BetterBahnKit/Sources/BetterBahnKit/Resources"
OUT = RESOURCES / "Platforms.json"
NETEX = "{http://www.netex.org.uk/netex}"
# How far (metres) a platform edge may be from its station's position.
STATION_RADIUS = 1000
# How far (metres) stairs or a lift may be from a platform edge without a second track on the platform,
# whose edge tells how wide it is. Stairs on the next platform are about 10 m away.
SIDE_PLATFORM_WIDTH = 7
# How far (metres) a buffer stop may be beyond the end of the edge for that end to be the exit.
BUFFER_STOP_DISTANCE = 35


def track_key(ref):
    """"Gleis 11", "11 " and "11" are all "11"."""
    ref = re.sub(r"^(gleis|gl\.?)\s*", "", ref.strip().lower())
    return re.sub(r"\s+", "", ref)


def openstation(netex_path):
    """Per station (EVA numbers, RIL100 codes): the tracks sharing a platform, the tracks it has and the
    lifts by track."""
    stations = []
    for _, element in ET.iterparse(netex_path, events=("end",)):
        if element.tag != NETEX + "StopPlace":
            continue
        keys = [(kv.findtext(NETEX + "Key"), kv.findtext(NETEX + "Value"))
                for kv in element.findall(f"{NETEX}keyList/{NETEX}KeyValue")]
        evas = sorted({value for key, value in keys if key == "EVA" and value})
        codes = [value for key, value in keys if key == "RIL" and value]
        quays = {}
        children = defaultdict(list)
        for quay in element.iter(NETEX + "Quay"):
            name = quay.findtext(NETEX + "PlateCode") or quay.findtext(NETEX + "Name") or ""
            quays[quay.get("id")] = (quay, name)
            parent = quay.find(NETEX + "ParentQuayRef")
            if parent is not None:
                children[parent.get("ref")].append(quay.get("id"))
        shared = []
        tracks = set()
        lifts = defaultdict(list)
        for quay_id, (quay, name) in quays.items():
            own = children.get(quay_id)
            if quay.find(NETEX + "ParentQuayRef") is not None:
                tracks.add(track_key(name))
                continue
            names = sorted({track_key(quays[child][1]) for child in own or []} - {""}, key=natural)
            if len(names) > 1:
                shared.append(names)
            if not own:
                tracks.add(track_key(name))
            for place in quay.iter(NETEX + "EquipmentPlace"):
                if place.find(f"{NETEX}placeEquipments/{NETEX}LiftEquipmentRef") is None:
                    continue
                location = place.find(f"{NETEX}Centroid/{NETEX}Location")
                if location is None:
                    continue
                point = (float(location.findtext(NETEX + "Latitude")), float(location.findtext(NETEX + "Longitude")))
                for track in names or [track_key(name)]:
                    lifts[track].append(point)
        if evas:
            name = " ".join((element.findtext(NETEX + "Name") or "").split())
            stations.append({"evas": evas, "codes": codes, "name": name, "shared": sorted(shared, key=lambda g: natural(g[0])),
                             "tracks": tracks - {""}, "lifts": lifts})
        element.clear()
    return stations


def natural(track):
    """Sorts "9" before "10" and "1a" after "1"."""
    match = re.match(r"(\d+)(.*)", track)
    return (int(match.group(1)), match.group(2)) if match else (10**6, track)


def ril100_points():
    rows = json.loads((RESOURCES / "Ril100.json").read_text(encoding="utf-8"))
    points = {}
    for code, _, coords in rows:
        points[" ".join(code.split())] = list(zip(coords[0::2], coords[1::2]))
    return points


def is_train_platform(tags):
    """A railway platform, or a public transport one for trains (not a bus stop's)."""
    return tags.get("railway") == "platform" or (tags.get("public_transport") == "platform" and tags.get("train") == "yes")


def read_osm(pbf_path):
    """The platform edges, platforms, stairs, escalators and lifts (ways with their points; platforms
    drawn as multipolygons with their outer ring and the relation's tags), the lifts, buffer stops and
    sector signs (nodes) and the tracks above ground (their points) of the extract."""
    import osmium
    from osmium.filter import IdFilter, KeyFilter, TagFilter

    platform = TagFilter(("railway", "platform"), ("public_transport", "platform"))
    relations = []
    for relation in osmium.FileProcessor(pbf_path, osmium.osm.RELATION).with_filter(platform):
        tags = dict(relation.tags)
        if tags.get("type") == "multipolygon" and is_train_platform(tags):
            relations.append((tags, [m.ref for m in relation.members if m.type == "w" and m.role in ("outer", "")]))
    members = {ref for _, refs in relations for ref in refs}

    ways = {}
    wanted = TagFilter(("railway", "platform_edge"), ("railway", "platform"), ("public_transport", "platform"),
                       ("highway", "steps"), ("highway", "elevator"))
    for way in osmium.FileProcessor(pbf_path, osmium.osm.WAY).with_filter(wanted):
        tags = dict(way.tags)
        if tags.get("public_transport") == "platform" and not is_train_platform(tags):
            continue
        ways[way.id] = (tags, [node.ref for node in way.nodes])
    for way in osmium.FileProcessor(pbf_path, osmium.osm.WAY).with_filter(KeyFilter("conveying")):
        ways.setdefault(way.id, (dict(way.tags), [node.ref for node in way.nodes]))
    # Tracks above ground, to tell bay platforms from a terminus: a city tunnel beneath the hall doesn't count.
    rails = []
    for way in osmium.FileProcessor(pbf_path, osmium.osm.WAY).with_filter(TagFilter(("railway", "rail"))):
        tags = dict(way.tags)
        layer = tags.get("layer", "0")
        if tags.get("tunnel") not in (None, "no") or (layer.lstrip("-").isdigit() and int(layer) < 0):
            continue
        rails.append([node.ref for node in way.nodes])
    outlines = {way.id: [node.ref for node in way.nodes]
                for way in osmium.FileProcessor(pbf_path, osmium.osm.WAY).with_filter(IdFilter(members))}
    needed = ({ref for _, refs in ways.values() for ref in refs} | {ref for refs in outlines.values() for ref in refs}
              | {ref for refs in rails for ref in refs})
    points = {node.id: (node.location.lat, node.location.lon)
              for node in osmium.FileProcessor(pbf_path, osmium.osm.NODE).with_filter(IdFilter(needed))}
    for tags, refs in relations:
        ring = outer_ring([[points[n] for n in outlines[ref] if n in points] for ref in refs if ref in outlines])
        if ring:
            # A platform drawn as a multipolygon is used like one drawn as a closed way.
            ways[f"r{len(ways)}"] = (tags, ring)
    nodes = {}
    filters = [TagFilter(("highway", "elevator"), ("railway", "buffer_stop"), ("railway", "platform_section_sign"),
                         ("public_transport", "platform_section_sign")),
               KeyFilter("railway:platform:section")]
    for node_filter in filters:
        for node in osmium.FileProcessor(pbf_path, osmium.osm.NODE).with_filter(node_filter):
            nodes[node.id] = (dict(node.tags), (node.location.lat, node.location.lon))
    return ([(tags, refs if isinstance(key, str) else [points[ref] for ref in refs if ref in points])
             for key, (tags, refs) in ways.items()],
            list(nodes.values()),
            [[points[ref] for ref in refs if ref in points] for refs in rails])


def outer_ring(pieces):
    """The largest closed ring the outer ways of a multipolygon form, end to end; None if none closes."""
    pieces = [list(piece) for piece in pieces if len(piece) > 1]
    rings = []
    while pieces:
        ring = pieces.pop()
        while ring[0] != ring[-1]:
            for index, piece in enumerate(pieces):
                if piece[0] == ring[-1]:
                    ring += piece[1:]
                elif piece[-1] == ring[-1]:
                    ring += piece[::-1][1:]
                else:
                    continue
                del pieces[index]
                break
            else:
                break
        if len(ring) > 3 and ring[0] == ring[-1]:
            rings.append(ring)
    return max(rings, key=len, default=None)


class Plane:
    """Metres east and north of a point, close enough within a station."""

    def __init__(self, lat, lon):
        self.lat, self.lon = lat, lon
        self.kx = 111320 * math.cos(math.radians(lat))

    def xy(self, point):
        return ((point[1] - self.lon) * self.kx, (point[0] - self.lat) * 110574)

    def latlon(self, xy):
        return (self.lat + xy[1] / 110574, self.lon + xy[0] / self.kx)


def length(line):
    return sum(math.dist(a, b) for a, b in zip(line, line[1:]))


def project(line, point):
    """(lateral distance, metres along the line, side: 1 left of it, -1 right) of the nearest point on it."""
    best = None
    along = 0
    for (x1, y1), (x2, y2) in zip(line, line[1:]):
        dx, dy = x2 - x1, y2 - y1
        segment = math.hypot(dx, dy)
        if segment == 0:
            continue
        u = max(0, min(1, ((point[0] - x1) * dx + (point[1] - y1) * dy) / segment**2))
        distance = math.hypot(point[0] - x1 - u * dx, point[1] - y1 - u * dy)
        side = 1 if dx * (point[1] - y1) - dy * (point[0] - x1) > 0 else -1
        if best is None or distance < best[0]:
            best = (distance, along + u * segment, side)
        along += segment
    return best


def chain(lines):
    """Joins edge pieces whose ends meet (within 3 m) into the longest line."""
    lines = [list(line) for line in lines if len(line) > 1]
    joined = True
    while joined and len(lines) > 1:
        joined = False
        for i in range(len(lines)):
            for j in range(len(lines)):
                if i == j:
                    continue
                a, b = lines[i], lines[j]
                for first, second in ((a, b), (a, b[::-1]), (a[::-1], b), (a[::-1], b[::-1])):
                    if math.dist(first[-1], second[0]) < 3:
                        lines[i] = first + second[1:]
                        del lines[j]
                        joined = True
                        break
                if joined:
                    break
            if joined:
                break
    return max(lines, key=length) if lines else None


def platform_tracks(tags):
    """The tracks a platform area or line serves ("11;12", "Gleis 11/12": ["11", "12"]); none for a tram's,
    a bus's or an underground railway's platform."""
    if any(tags.get(mode) == "yes" for mode in ("subway", "light_rail", "tram", "bus")) or tags.get("highway") == "platform":
        return []
    ref = tags.get("ref") or tags.get("local_ref") or ""
    return [key for key in (track_key(part) for part in re.split(r"[;/,+]", ref)) if key]


def name_words(name):
    words = re.findall(r"\w{3,}", name.lower())
    return {w for w in words if w not in {"hbf", "hauptbahnhof", "bahnhof", "gleis", "bahnsteig"}}


def axis(points):
    """A platform area's long axis through its middle, from one end to the other, and its width."""
    cx = sum(p[0] for p in points) / len(points)
    cy = sum(p[1] for p in points) / len(points)
    sxx = sum((p[0] - cx) ** 2 for p in points)
    syy = sum((p[1] - cy) ** 2 for p in points)
    sxy = sum((p[0] - cx) * (p[1] - cy) for p in points)
    angle = 0.5 * math.atan2(2 * sxy, sxx - syy)
    u = (math.cos(angle), math.sin(angle))
    along = [(p[0] - cx) * u[0] + (p[1] - cy) * u[1] for p in points]
    across = [-(p[0] - cx) * u[1] + (p[1] - cy) * u[0] for p in points]
    line = [(cx + min(along) * u[0], cy + min(along) * u[1]), (cx + max(along) * u[0], cy + max(along) * u[1])]
    return line, max(across) - min(across)


def inside(polygon, point, tolerance=2):
    """Whether `point` lies in the polygon or within `tolerance` metres of its outline."""
    x, y = point
    crossings = 0
    for (x1, y1), (x2, y2) in zip(polygon, polygon[1:] + polygon[:1]):
        if (y1 > y) != (y2 > y) and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1):
            crossings += 1
    if crossings % 2 == 1:
        return True
    return project(polygon + polygon[:1], point)[0] <= tolerance


def main(netex_path, pbf_path):
    stations = openstation(netex_path)
    print(f"{len(stations)} stations in OpenStation", flush=True)
    ways, nodes, rails = read_osm(pbf_path)
    print(f"{len(ways)} ways, {len(nodes)} nodes, {len(rails)} tracks from OpenStreetMap", flush=True)

    by_code = ril100_points()
    for station in stations:
        station["points"] = [p for code in station["codes"] for p in by_code.get(" ".join(code.split()), [])]
    located = [s for s in stations if s["points"]]

    # A coarse grid (about 1 km) to find what is near a station.
    def cell(point):
        return (round(point[0] * 100), round(point[1] * 60))

    grid = defaultdict(list)
    for index, station in enumerate(located):
        for point in station["points"]:
            grid[cell(point)].append(index)

    def near(point):
        x, y = cell(point)
        return {i for dx in (-1, 0, 1) for dy in (-1, 0, 1) for i in grid.get((x + dx, y + dy), [])}

    def distance(a, b):
        return math.hypot((a[1] - b[1]) * 111320 * math.cos(math.radians(a[0])), (a[0] - b[0]) * 110574)

    def nearest_station(point, tracks):
        """The nearest station within STATION_RADIUS that has one of `tracks`."""
        candidates = [(min(distance(point, p) for p in located[i]["points"]), i) for i in near(point)
                      if located[i]["tracks"] & set(tracks)]
        candidates = [c for c in candidates if c[0] <= STATION_RADIUS]
        return min(candidates)[1] if candidates else None

    # Each platform edge and platform goes to the nearest station with its track.
    edges = defaultdict(list)
    areas = defaultdict(list)
    things = defaultdict(list)
    for tags, line in ways:
        if not line:
            continue
        middle = line[len(line) // 2]
        if tags.get("railway") == "platform_edge":
            track = track_key(tags.get("ref", ""))
            index = nearest_station(middle, [track]) if track else None
            if index is not None:
                edges[(index, track)].append(line)
        elif tags.get("railway") == "platform" or tags.get("public_transport") == "platform":
            tracks = platform_tracks(tags)
            index = nearest_station(middle, tracks) if tracks else None
            # Without train=yes only a platform named like the station, or without a name.
            if index is None or (tags.get("train") != "yes" and tags.get("name")
                                 and not name_words(tags["name"]) & name_words(located[index]["name"])):
                continue
            for track in tracks:
                areas[(index, track)].append((line, len(tracks)))
        else:
            kind = "l" if tags.get("highway") == "elevator" else "s"
            for i in near(middle):
                things[i].append(((kind, None), line))
    for line in rails:
        for i in {i for point in line[::5] + line[-1:] for i in near(point)}:
            things[i].append((("t", None), line))
    for tags, point in nodes:
        if tags.get("highway") == "elevator":
            kind = ("l", None)
        elif tags.get("railway") == "buffer_stop":
            kind = ("b", None)
        else:
            sector = tags.get("railway:platform:section") or tags.get("platform_section_sign") or tags.get("ref")
            if not sector or not re.fullmatch(r"[A-Z]", sector.strip()):
                continue
            kind = ("c", sector.strip())
        for i in near(point):
            things[i].append((kind, [point]))

    out = {}
    counts = defaultdict(int)
    for index, station in enumerate(located):
        plane = Plane(*station["points"][0])
        # Per track: the line positions are measured along, its points' latitude and longitude, how far
        # from the line the platform reaches, on which side (None: either), and the area's outline.
        shapes = {}
        for (i, track), pieces in edges.items():
            if i == index:
                line = chain([[plane.xy(p) for p in piece] for piece in pieces])
                if line and length(line) > 20:
                    shapes[track] = {"line": line, "width": SIDE_PLATFORM_WIDTH, "side": None, "outline": None, "edge": True}
        for (i, track), pieces in areas.items():
            if i != index or track in shapes:
                continue
            piece, served = max(pieces, key=lambda piece: len(piece[0]))
            points = [plane.xy(p) for p in piece]
            if len(points) > 3 and math.dist(points[0], points[-1]) < 1:
                line, width = axis(points[:-1])
                shape = {"line": line, "width": width / 2 + 2, "side": None, "outline": points[:-1], "edge": False,
                         "half": width / 2, "served": served}
            else:
                shape = {"line": points, "width": SIDE_PLATFORM_WIDTH, "side": None, "outline": None, "edge": False}
            if length(shape["line"]) > 20:
                shapes[track] = shape
        # The other track's edge tells which side the platform is on and how wide it is.
        for group in station["shared"]:
            for track in group:
                shape = shapes.get(track)
                if not shape or not shape["edge"]:
                    continue
                for other in group:
                    other_shape = shapes.get(other)
                    if other == track or not other_shape or not other_shape["edge"]:
                        continue
                    other_line = other_shape["line"]
                    lateral, _, side = project(shape["line"], other_line[len(other_line) // 2])
                    if 3 < lateral < 30:
                        shape["width"], shape["side"] = lateral + 1, side
                        break

        # A terminus: most of its tracks end at buffer stops, where the platforms meet the station hall.
        # Bay platforms of a through station (Augsburg, Ulm) end at buffer stops too, with no way out there.
        buffer_stops = [plane.xy(point) for (kind, _), shape_points in things[index] if kind == "b" for point in shape_points]
        buffers = {}
        for track, shape in shapes.items():
            if shape["outline"]:
                # An area: on a track along one of its long sides (one in line with the platform's middle
                # is no track's), and on both for an island's two tracks (one alone may be a bay's beside it).
                found = {buffer_side(shape["line"], point, shape["half"]) for point in buffer_stops} - {None}
                ends = {end for end, _ in found if shape["served"] < 2 or {(end, 1), (end, -1)} <= found}
            else:
                ends = {buffer_end(shape["line"], point, 3.5) for point in buffer_stops} - {None}
            if len(ends) == 1:
                buffers[track] = ends.pop()
        heads = head_tracks({t: (shapes[t]["line"], end) for t, end in buffers.items()})
        # Most of its tracks, or a row of three where OSM lacks some (Kassel Hbf); and no track runs on
        # past the row, as through tracks do beside bay platforms (Hamm). A big terminus's row is taken
        # as it is: one wing of München Hbf ends before the others.
        most = len(heads) * 10 >= len(station["tracks"]) * 6
        if len(heads) < 6 or not most:
            tracks_here = [[plane.xy(p) for p in line] for (kind, _), line in things[index] if kind == "t"]
            if len(heads) < 2 or not (most or len(heads) >= 3) or runs_past(
                    {t: (shapes[t]["line"], buffers[t]) for t in heads}, tracks_here):
                heads = set()

        tracks = {}
        for track, shape in shapes.items():
            line, total = shape["line"], length(shape["line"])

            def on_platform(point):
                lateral, along, side = project(line, point)
                if shape["outline"]:
                    ok = inside(shape["outline"], point)
                else:
                    ok = lateral <= shape["width"] and (shape["side"] is None or lateral < 1.5 or side == shape["side"])
                return (ok and -5 <= along <= total + 5, max(0, min(total, along)))

            accesses, sectors = [], defaultdict(list)
            for (kind, extra), shape_points in things[index]:
                if kind == "t":
                    continue
                points = [plane.xy(p) for p in shape_points]
                if kind == "s":
                    # Stairs often run along the platform; which end is the top isn't always mapped.
                    ends = [e for e in (on_platform(points[0]), on_platform(points[-1])) if e[0]]
                    if ends:
                        accesses.append(("s", sum(e[1] for e in ends) / len(ends)))
                elif kind == "l":
                    centre = (sum(p[0] for p in points) / len(points), sum(p[1] for p in points) / len(points))
                    ok, along = on_platform(centre)
                    if ok:
                        accesses.append(("l", along))
                elif kind == "c":
                    ok, along = on_platform(points[0])
                    if ok:
                        sectors[extra].append(along)
            for point in station["lifts"].get(track, []):
                ok, along = on_platform(plane.xy(point))
                if ok:
                    accesses.append(("l", along))
            if track in heads:
                accesses.append(("x", buffers[track]))
            accesses = merged(accesses)
            # A sector sign mapped twice (on the edge and above the platform) is one.
            signs = sorted(([name, round(sum(v) / len(v))] for name, v in sectors.items()
                            if max(v) - min(v) < 40), key=lambda s: s[1])
            if not accesses and not signs:
                continue
            first, last = plane.latlon(line[0]), plane.latlon(line[-1])
            tracks[track] = [round(first[0], 6), round(first[1], 6), round(last[0], 6), round(last[1], 6),
                             round(total), [[k, round(m)] for k, m in accesses], signs]
            counts["edge" if shape["edge"] else "area"] += 1
        if tracks or station["shared"]:
            entry = {}
            if station["shared"]:
                entry["p"] = station["shared"]
            if tracks:
                entry["t"] = dict(sorted(tracks.items(), key=lambda kv: natural(kv[0])))
            for eva in station["evas"]:
                out[eva] = entry
    with open(OUT, "w", encoding="utf-8") as file:
        file.write("{\n")
        file.write(",\n".join(f"{json.dumps(eva)}:{json.dumps(entry, ensure_ascii=False, separators=(',', ':'))}"
                              for eva, entry in sorted(out.items())))
        file.write("\n}\n")
    print(f"{len(out)} stations, tracks from platform edges: {counts['edge']}, from platforms: {counts['area']} -> {OUT}")


def head_tracks(ends):
    """The tracks whose buffer ends ({track: (line, 0 or its length)}) lie side by side along a station
    hall, as at a terminus: pointing the same way and level with at least one other track's. München Hbf
    has three such rows; a bay platform at either end of a through station has none."""
    heads = {}
    for track, (line, end) in ends.items():
        far, near = (line[-1], line[0]) if end == 0 else (line[0], line[-1])
        size = math.dist(far, near)
        heads[track] = (near, ((near[0] - far[0]) / size, (near[1] - far[1]) / size))
    mx, my = sum(u[0] for _, u in heads.values()), sum(u[1] for _, u in heads.values())
    size = math.hypot(mx, my)
    if size == 0:
        return set()
    mx, my = mx / size, my / size
    along = sorted((p[0] * mx + p[1] * my, t) for t, (p, u) in heads.items() if u[0] * mx + u[1] * my > 0.7)
    rows, kept = [], set()
    for value, track in along:
        if rows and value - rows[-1][-1][0] <= 40:
            rows[-1].append((value, track))
        else:
            rows.append([(value, track)])
    for row in rows:
        if len(row) >= 2:
            kept.update(track for _, track in row)
    return kept


def buffer_side(line, point, half_width):
    """(0 or the line's length, side) when a buffer stop stands just beyond that end of a platform area's
    axis, on a track along one of its long sides (about 1.7 m beyond the edge)."""
    total = length(line)
    for (a, b), along in (((line[1], line[0]), 0), ((line[-2], line[-1]), total)):
        dx, dy = b[0] - a[0], b[1] - a[1]
        segment = math.hypot(dx, dy)
        if segment == 0:
            continue
        beyond = ((point[0] - b[0]) * dx + (point[1] - b[1]) * dy) / segment
        lateral = (dx * (point[1] - b[1]) - dy * (point[0] - b[0])) / segment
        if -15 <= beyond <= BUFFER_STOP_DISTANCE and half_width - 1 <= abs(lateral) <= half_width + 4:
            return (along, 1 if lateral > 0 else -1)
    return None


def runs_past(ends, tracks):
    """Whether tracks (`tracks`: lines) run on beyond the row of buffer ends (`ends`: {track: (line,
    0 or its length)}): beside the row (within 25 m of its outer tracks) they cover at least 150 m of
    the stretch from 50 to 250 m past the platform ends, as a line running through does. A terminus's
    tracks end at the buffer stops, up to 35 m past the platforms; a siding beside it ends soon after."""
    points, directions = [], []
    for line, end in ends.values():
        far, near = (line[-1], line[0]) if end == 0 else (line[0], line[-1])
        size = math.dist(far, near)
        points.append(near)
        directions.append(((near[0] - far[0]) / size, (near[1] - far[1]) / size))
    mx, my = sum(d[0] for d in directions), sum(d[1] for d in directions)
    size = math.hypot(mx, my)
    mx, my = mx / size, my / size
    row = max(p[0] * mx + p[1] * my for p in points)
    across = [p[1] * mx - p[0] * my for p in points]
    low, high = min(across) - 25, max(across) + 25
    covered = []
    for line in tracks:
        for a, b in zip(line, line[1:]):
            along_a, along_b = a[0] * mx + a[1] * my, b[0] * mx + b[1] * my
            across_a, across_b = a[1] * mx - a[0] * my, b[1] * mx - b[0] * my
            # The part of the segment in the stretch beside the row, in its own parameter t (0…1).
            t0, t1 = 0.0, 1.0
            for value_a, value_b, lower, upper in ((along_a, along_b, row + 50, row + 250), (across_a, across_b, low, high)):
                if value_a == value_b:
                    if not lower <= value_a <= upper:
                        t0, t1 = 1.0, 0.0
                    continue
                u, v = (lower - value_a) / (value_b - value_a), (upper - value_a) / (value_b - value_a)
                t0, t1 = max(t0, min(u, v)), min(t1, max(u, v))
            if t0 < t1:
                first, last = along_a + t0 * (along_b - along_a), along_a + t1 * (along_b - along_a)
                covered.append((min(first, last), max(first, last)))
    total, reach = 0.0, -math.inf
    for first, last in sorted(covered):
        if last > reach:
            total += last - max(first, reach)
            reach = last
    return total >= 150


def buffer_end(line, point, lateral_limit):
    """0 or the line's length when a buffer stop stands just beyond that end of it, in line with it."""
    total = length(line)
    for (a, b), along in (((line[1], line[0]), 0), ((line[-2], line[-1]), total)):
        dx, dy = b[0] - a[0], b[1] - a[1]
        segment = math.hypot(dx, dy)
        if segment == 0:
            continue
        beyond = ((point[0] - b[0]) * dx + (point[1] - b[1]) * dy) / segment
        lateral = abs(dx * (point[1] - b[1]) - dy * (point[0] - b[0])) / segment
        if -15 <= beyond <= BUFFER_STOP_DISTANCE and lateral <= lateral_limit:
            return along
    return None


def merged(accesses):
    """Stairs and lifts closer than 8 m are one way off the platform; the exit at a terminus stays."""
    result = []
    for kind, along in sorted(accesses, key=lambda a: (a[1], a[0])):
        if result and result[-1][0] == kind and along - result[-1][1] < 8:
            continue
        result.append((kind, along))
    return result


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
