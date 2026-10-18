#!/usr/bin/env python3
"""Tests for make-exit-sides.py on a made-up station: python3 scripts/make-exit-sides-test.py"""

import importlib.util
import json
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("make_exit_sides", Path(__file__).with_name("make-exit-sides.py"))
exit_sides = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exit_sides)

LAT, LON = 50.0, 8.0
# Metres per degree at 50° N.
KY, KX = 110_540, 111_320 * 0.6428


def point(x, y):
    """A node `x` metres east and `y` metres north of the station."""
    return {"lat": LAT + y / KY, "lon": LON + x / KX}


def way(way_id, tags, points, node_ids=None):
    nodes = node_ids or [way_id * 100 + i for i in range(len(points))]
    return {"type": "way", "id": way_id, "tags": tags, "nodes": nodes, "geometry": [point(*p) for p in points]}


def rectangle(x1, y1, x2, y2):
    return [(x1, y1), (x2, y1), (x2, y2), (x1, y2), (x1, y1)]


def station_node(node_id=1, name="Teststadt Hbf", **tags):
    return {"type": "node", "id": node_id, "lat": LAT, "lon": LON, "tags": {"railway": "station", "name": name, **tags}}


class NumbersTests(unittest.TestCase):
    def test_normalize_track(self):
        self.assertEqual(exit_sides.normalize_track("7 D-G"), "7")
        self.assertEqual(exit_sides.normalize_track("Gleis 4a"), "4a")
        self.assertEqual(exit_sides.normalize_track("07"), "7")
        self.assertEqual(exit_sides.normalize_track("101"), "101")
        self.assertIsNone(exit_sides.normalize_track("Bus"))
        self.assertIsNone(exit_sides.normalize_track("7ab"))

    def test_platform_refs(self):
        self.assertEqual(exit_sides.platform_refs({"ref": "7;8"}), ["7", "8"])
        self.assertEqual(exit_sides.platform_refs({"ref": "7/8"}), ["7", "8"])
        self.assertEqual(exit_sides.platform_refs({"ref": "7-8"}), ["7", "8"])
        self.assertEqual(exit_sides.platform_refs({"ref": "Gleis 7 und 8"}), ["7", "8"])
        self.assertEqual(exit_sides.platform_refs({"ref": "101 - 104"}), ["101", "102", "103", "104"])
        self.assertEqual(exit_sides.platform_refs({"local_ref": "3"}), ["3"])
        self.assertEqual(exit_sides.platform_refs({"ref": "A"}), [])
        # A long span is a name, not a list of tracks.
        self.assertEqual(exit_sides.platform_refs({"ref": "1-20"}), [])


class GeometryTests(unittest.TestCase):
    def test_project_sides_and_heading(self):
        east = [(0, 0), (100, 0)]
        distance, _, side, heading = exit_sides.project((50, 3), east)
        self.assertAlmostEqual(distance, 3)
        self.assertEqual(side, 1)  # north of an eastbound track is its left
        self.assertAlmostEqual(heading, 90)
        self.assertEqual(exit_sides.project((50, -3), east)[2], -1)

    def test_platform_side(self):
        east = [(0, 0), (200, 0)]
        north = exit_sides.densify([(0, 2), (200, 2), (200, 8), (0, 8), (0, 2)], closed=True)
        self.assertEqual(exit_sides.platform_side(north, east), ("left", 90))
        south = exit_sides.densify([(0, -2), (200, -2), (200, -8), (0, -8), (0, -2)], closed=True)
        side, heading = exit_sides.platform_side(south, east)
        self.assertEqual(side, "right")
        self.assertAlmostEqual(heading, 90)
        # Too far away: another track's platform.
        far = exit_sides.densify([(0, 6), (200, 6), (200, 12), (0, 12), (0, 6)], closed=True)
        self.assertIsNone(exit_sides.platform_side(far, east))
        # Straddling the track: the ref matched the wrong track.
        across = exit_sides.densify([(0, -3), (200, -3), (200, 3), (0, 3), (0, -3)], closed=True)
        self.assertIsNone(exit_sides.platform_side(across, east))

    def test_combine_turns_pieces_to_one_direction(self):
        self.assertEqual(exit_sides.combine([("left", 90), ("right", 270)]), ("left", 90))
        self.assertIsNone(exit_sides.combine([("left", 90), ("left", 272)]))


class AnalysisTests(unittest.TestCase):
    def analyse(self, elements, **kwargs):
        stations, dropped = exit_sides.analyse(exit_sides.Data(elements), **kwargs)
        return exit_sides.output(stations)["stations"], dropped

    def test_through_station(self):
        elements = [
            station_node(**{"railway:ref": "TST", "uic_ref": "8000001"}),
            # Track 1 runs east; its platform lies north of it (left when eastbound). Track 2 runs west in
            # OSM's node order with the same island platform south of it: left again when westbound.
            way(10, {"railway": "rail", "railway:track_ref": "1"}, [(-300, 0), (300, 0)]),
            way(11, {"railway": "rail", "railway:track_ref": "2"}, [(300, 12), (-300, 12)]),
            way(20, {"railway": "platform", "ref": "1;2"}, rectangle(-150, 2, 150, 10)),
        ]
        stations, dropped = self.analyse(elements)
        self.assertEqual(dropped, 0)
        self.assertEqual(len(stations), 1)
        station = stations[0]
        self.assertEqual(station["name"], "Teststadt Hbf")
        self.assertEqual(station["ril100"], "TST")
        self.assertEqual(station["uic"], "8000001")
        self.assertEqual(station["tracks"], [
            {"track": "1", "heading": 90, "side": "left"},
            {"track": "2", "heading": 270, "side": "left"},
        ])

    def test_terminal_track_ahead_and_behind(self):
        elements = [
            station_node(),
            {"type": "node", "id": 900, "lat": LAT, "lon": LON + 300 / KX, "tags": {"railway": "buffer_stop"}},
            {"type": "node", "id": 901, "lat": LAT, "lon": LON - 300 / KX, "tags": {"railway": "buffer_stop"}},
            # Track 5 is drawn towards its buffer stop in the east: arrivals travel east, platform left.
            way(10, {"railway": "rail", "railway:track_ref": "5"}, [(-300, 0), (300, 0)], node_ids=[1000, 900]),
            way(20, {"railway": "platform", "ref": "5"}, rectangle(-150, 2, 150, 10)),
            # Track 6 is drawn away from its buffer stop (west end, reached over a second way piece): arrivals
            # travel west, so the heading turns round and the platform, north of the track, is on their right.
            way(11, {"railway": "rail", "railway:track_ref": "6"}, [(-100, 20), (300, 20)], node_ids=[1100, 1101]),
            way(12, {"railway": "rail", "railway:track_ref": "6"}, [(-300, 20), (-100, 20)], node_ids=[901, 1100]),
            way(21, {"railway": "platform", "ref": "6"}, rectangle(-150, 22, 150, 30)),
        ]
        stations, dropped = self.analyse(elements)
        self.assertEqual(dropped, 0)
        self.assertEqual(stations[0]["tracks"], [
            {"track": "5", "heading": 90, "side": "left", "terminal": True},
            {"track": "6", "heading": 270, "side": "right", "terminal": True},
        ])

    def test_platform_edges_and_relation(self):
        elements = [
            station_node(),
            way(10, {"railway": "rail", "railway:track_ref": "3"}, [(-300, 0), (300, 0)]),
            way(20, {"railway": "platform_edge", "ref": "3"}, [(-150, -1.7), (150, -1.7)]),
            way(11, {"railway": "rail", "railway:track_ref": "4"}, [(-300, 40), (300, 40)]),
            {"type": "relation", "id": 30, "tags": {"railway": "platform", "type": "multipolygon", "ref": "4"},
             "members": [{"type": "way", "ref": 40, "role": "outer", "geometry": [point(*p) for p in rectangle(-150, 42, 150, 50)]}]},
        ]
        stations, _ = self.analyse(elements)
        self.assertEqual(stations[0]["tracks"], [
            {"track": "3", "heading": 90, "side": "right"},
            {"track": "4", "heading": 90, "side": "left"},
        ])

    def test_contradictions_are_dropped(self):
        elements = [
            station_node(),
            way(10, {"railway": "rail", "railway:track_ref": "1"}, [(-300, 0), (300, 0)]),
            # Two platforms claim track 1, one on each side.
            way(20, {"railway": "platform", "ref": "1"}, rectangle(-150, 2, 150, 10)),
            way(21, {"railway": "platform", "ref": "1"}, rectangle(-150, -10, 150, -2)),
            # Track 2 has only a platform 30 m away: not next to it.
            way(11, {"railway": "rail", "railway:track_ref": "2"}, [(-300, 100), (300, 100)]),
            way(22, {"railway": "platform", "ref": "2"}, rectangle(-150, 130, 150, 138)),
        ]
        stations, dropped = self.analyse(elements)
        self.assertEqual(dropped, 1)
        self.assertEqual(stations, [])

    def test_nearest_station_within_reach(self):
        far = station_node(2, "Weitweg", **{"railway:ref": "WEI"})
        far["lat"] = LAT + 5000 / KY
        elements = [
            far,
            station_node(3, "Teststadt Hbf (S-Bahn)"),
            {"type": "node", "id": 4, "lat": LAT, "lon": LON, "tags": {"railway": "station", "name": "U Teststadt", "station": "subway"}},
            way(10, {"railway": "rail", "railway:track_ref": "1"}, [(-300, 0), (300, 0)]),
            way(20, {"railway": "platform", "ref": "1"}, rectangle(-150, 2, 150, 10)),
        ]
        stations, _ = self.analyse(elements)
        self.assertEqual([s["name"] for s in stations], ["Teststadt Hbf (S-Bahn)"])
        self.assertNotIn("ril100", stations[0])

    def test_dump_is_valid_json_one_station_per_line(self):
        elements = [
            station_node(),
            way(10, {"railway": "rail", "railway:track_ref": "1"}, [(-300, 0), (300, 0)]),
            way(20, {"railway": "platform", "ref": "1"}, rectangle(-150, 2, 150, 10)),
        ]
        stations, _ = exit_sides.analyse(exit_sides.Data(elements))
        text = exit_sides.dump(exit_sides.output(stations))
        parsed = json.loads(text)
        self.assertEqual(parsed["stations"][0]["tracks"][0]["side"], "left")
        self.assertEqual(text.count("\n"), 4)


if __name__ == "__main__":
    unittest.main()
