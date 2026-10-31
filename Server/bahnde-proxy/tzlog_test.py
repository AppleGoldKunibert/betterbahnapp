"""Tests for tzlog.py: `python3 -m unittest Server/bahnde-proxy/tzlog_test.py` (no network)."""

import asyncio
import datetime as dt
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import tzlog  # noqa: E402


def sequence(*groups, status="MATCHES_SCHEDULE"):
    return {"sequenceStatus": status, "groups": [
        {"name": name, "transport": {"category": "ICE", "number": number, "destination": {"name": "Köln Hbf"}},
         "vehicles": [{"type": {"constructionType": t}} for t in types]} for name, number, types in groups]}


class ParseTests(unittest.TestCase):
    def test_unit_number(self):
        self.assertEqual(tzlog.unit_number("ICE8043"), ("ICE", "8043"))
        self.assertEqual(tzlog.unit_number("ICE0169"), ("ICE", "169"))
        self.assertEqual(tzlog.unit_number("ICD4886"), ("ICD", "4886"))
        self.assertIsNone(tzlog.unit_number("IC450007"))
        self.assertIsNone(tzlog.unit_number("ICE0000"))
        self.assertIsNone(tzlog.unit_number(None))

    def test_keeps_the_trains_own_and_coupled_sets(self):
        body = sequence(("ICE9203", 956, ["I4080", "I4081"]), ("ICE9228", 958, ["I4080"]))
        self.assertEqual([(s["tz"], s["number"]) for s in tzlog.parse_sequence(body, "ICE", 956)],
                         [("9203", 956), ("9228", 958)])

    def test_another_trains_sequence_gives_nothing(self):
        self.assertEqual(tzlog.parse_sequence(sequence(("ICE8043", 77, [])), "ICE", 1516), [])

    def test_no_tz_for_loco_hauled_ic(self):
        self.assertEqual(tzlog.parse_sequence(sequence(("IC450007", 2200, ["R6684"])), "IC", 2200), [])


class StoreTests(unittest.TestCase):
    def sighting(self, tz, number, category="ICE"):
        return {"tz": tz, "unit": "ICE" + tz, "types": ["I4080"], "category": category, "number": number,
                "destination": "Köln Hbf", "status": "MATCHES_SCHEDULE"}

    def test_list_has_each_tz_once_with_its_latest_day(self):
        store = tzlog.TzStore()
        store.record("2026-10-30", self.sighting("8043", 318), "Berlin Hbf", 1)
        store.record("2026-10-31", self.sighting("8043", 592), "Berlin Hbf", 2)
        store.record("2026-10-31", self.sighting("8043", 593), "Hannover Hbf", 3)
        store.record("2026-10-31", self.sighting("169", 10), "Hannover Hbf", 3)
        units = store.units()
        self.assertEqual([u["tz"] for u in units], ["169", "8043"])
        self.assertEqual(units[1]["lastDay"], "2026-10-31")
        self.assertEqual([t["number"] for t in units[1]["trains"]], [592, 593])

    def test_recording_again_updates(self):
        store = tzlog.TzStore()
        store.record("2026-10-31", self.sighting("8043", 318), "Berlin Hbf", 1)
        changed = self.sighting("8043", 318)
        changed["status"] = "DIFFERS_FROM_SCHEDULE"
        store.record("2026-10-31", changed, "Berlin Hbf", 2)
        self.assertEqual([t["status"] for t in store.history("8043")], ["DIFFERS_FROM_SCHEDULE"])

    def test_history_newest_first_and_prune_after_a_year(self):
        store = tzlog.TzStore()
        store.record("2025-10-01", self.sighting("8043", 1), "Berlin Hbf", 1)
        store.record("2026-10-30", self.sighting("8043", 2), "Berlin Hbf", 1)
        store.record("2026-10-31", self.sighting("8043", 3), "Berlin Hbf", 1)
        self.assertEqual([t["day"] for t in store.history("8043")], ["2026-10-31", "2026-10-30", "2025-10-01"])
        store.prune(dt.date(2026, 10, 31))
        self.assertEqual([t["day"] for t in store.history("8043")], ["2026-10-31", "2026-10-30"])


class FakeBahnDe:
    """Two hubs: Berlin has one full page (7 trains), then an empty hour; Hamburg shows ICE 5 again."""

    def __init__(self):
        self.paths = []

    async def __call__(self, path):
        self.paths.append(path)
        if path.startswith("reiseloesung/abfahrten"):
            eva = path.split("ortExtId=")[1].split("&")[0]
            zeit = path.split("zeit=")[1].split("&")[0]
            if eva == "1" and zeit == "10:00:00":
                return 200, {"entries": [self.entry(n, f"2026-10-31T10:{n * 5:02d}:00") for n in range(1, 8)]}
            if eva == "2" and zeit == "10:00:00":
                return 200, {"entries": [self.entry(5, "2026-10-31T10:25:00")]}
            return 200, {"entries": []} if eva == "1" else {}
        number = int(path.split("number=")[1].split("&")[0])
        return 200, sequence((f"ICE{8000 + number}", number, ["I4080"]))

    @staticmethod
    def entry(number, zeit):
        return {"zeit": zeit, "journeyId": f"j{number}", "verkehrmittel": {"name": f"ICE {number}"}}


class ScannerTests(unittest.IsolatedAsyncioTestCase):
    async def scan(self, bahn_de, hubs=(("1", "Berlin Hbf"), ("2", "Hamburg Hbf")), every=3600):
        self.store = tzlog.TzStore()
        slept = []

        async def sleep(seconds):
            slept.append(seconds)

        now = dt.datetime(2026, 10, 31, 10, 0, tzinfo=tzlog.BERLIN).timestamp()
        scanner = tzlog.Scanner(self.store, bahn_de, hubs=list(hubs), every=every, now=lambda: now, sleep=sleep)
        await scanner.scan()
        return slept

    async def test_asks_each_train_once_and_records_it_with_the_hub(self):
        bahn_de = FakeBahnDe()
        await self.scan(bahn_de)
        asked = [p for p in bahn_de.paths if p.startswith("reisebegleitung")]
        self.assertEqual(len(asked), 7)
        self.assertEqual([u["tz"] for u in self.store.units()], [str(8000 + n) for n in range(1, 8)])
        self.assertEqual(self.store.history("8005")[0]["station"], "Berlin Hbf")

    async def test_full_page_continues_where_it_ended_and_empty_one_an_hour_later(self):
        bahn_de = FakeBahnDe()
        await self.scan(bahn_de, hubs=[("1", "Berlin Hbf")], every=7200)
        boards = [p.split("zeit=")[1].split("&")[0] for p in bahn_de.paths if p.startswith("reiseloesung")]
        self.assertEqual(boards, ["10:00:00", "10:35:00", "11:35:00"])

    async def test_sequence_asked_with_utc_time_and_berlin_day(self):
        path = tzlog.sequence_path("ICE", 1516, "8000105", dt.datetime(2026, 11, 1, 0, 41))
        self.assertIn("date=2026-11-01", path)
        self.assertIn("time=2026-10-31T23:41:00.000Z", path)

    async def test_waits_out_the_proxys_pause(self):
        calls = []

        async def get(path):
            calls.append(path)
            return (503, None) if len(calls) == 1 else (200, {"entries": []})

        self.store = tzlog.TzStore()
        slept = []

        async def sleep(seconds):
            slept.append(seconds)

        scanner = tzlog.Scanner(self.store, get, hubs=[("1", "Berlin Hbf")], interval=0, every=3600,
                                now=lambda: dt.datetime(2026, 10, 31, 10, 0, tzinfo=tzlog.BERLIN).timestamp(),
                                sleep=sleep, pause_left=lambda: 30 if len(calls) == 1 else 0)
        await scanner.scan()
        self.assertEqual(len(calls), 2)
        self.assertIn(31, slept)


if __name__ == "__main__":
    unittest.main()
