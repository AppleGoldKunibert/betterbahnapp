"""Tests for tzlog.py: `python3 -m unittest Server/bahnde-proxy/tzlog_test.py` (needs aiohttp; no network)."""

import asyncio
import datetime as dt
import sys
import unittest
from pathlib import Path

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

sys.path.insert(0, str(Path(__file__).parent))
import tzlog  # noqa: E402


def coach(vehicle_id, construction="I4080", category="PASSENGERCARRIAGE_ECONOMY_CLASS"):
    return {"vehicleID": vehicle_id, "type": {"category": category, "constructionType": construction}}


def sequence(*groups, status="MATCHES_SCHEDULE", journey_id="20261031-abc"):
    return {"sequenceStatus": status, "journeyID": journey_id, "groups": [
        {"name": name, "transport": {"category": "ICE", "number": number, "destination": {"name": "Köln Hbf"}},
         "vehicles": [coach(v, t) if isinstance(v, str) else v for v, t in vehicles]}
        for name, number, vehicles in groups]}


class ParseTests(unittest.TestCase):
    def test_unit_number(self):
        self.assertEqual(tzlog.unit_number("ICE8043"), ("ICE", "8043"))
        self.assertEqual(tzlog.unit_number("ICE0169"), ("ICE", "169"))
        self.assertEqual(tzlog.unit_number("ICD4886"), ("ICD", "4886"))
        self.assertIsNone(tzlog.unit_number("IC450007"))
        self.assertIsNone(tzlog.unit_number("ICE0000"))
        self.assertIsNone(tzlog.unit_number(None))

    def test_keeps_the_trains_own_and_coupled_sets(self):
        body = sequence(("ICE9203", 956, [("1", "I4080"), ("2", "I4081")]), ("ICE9228", 958, [("3", "I4080")]))
        self.assertEqual([(s["tz"], s["number"]) for s in tzlog.parse_sequence(body, "ICE", 956)],
                         [("9203", 956), ("9228", 958)])

    def test_another_trains_sequence_gives_nothing(self):
        self.assertEqual(tzlog.parse_sequence(sequence(("ICE8043", 77, [])), "ICE", 1516), [])

    def test_no_tz_for_loco_hauled_ic(self):
        self.assertEqual(tzlog.parse_sequence(sequence(("IC450007", 2200, [("1", "R6684")])), "IC", 2200), [])

    def test_vehicle_is_a_coach_never_a_locomotive(self):
        loco = {"vehicleID": "918000000001", "type": {"category": "LOCOMOTIVE", "constructionType": "E1475"}}
        car = coach("938000000002", "R6684")
        self.assertEqual(tzlog.pick_vehicle([loco, car]), "938000000002")
        self.assertIsNone(tzlog.pick_vehicle([loco]))
        self.assertIsNone(tzlog.pick_vehicle([coach("not-a-number")]))
        body = sequence(("ICD4886", 2049, [(loco, None), (car, None)]))
        self.assertEqual(tzlog.parse_sequence(body, "IC", 2049)[0]["vehicle"], "938000000002")

    def test_operating_days(self):
        self.assertEqual(tzlog.operating_day("20261103-dcbecefc-ebbb", "x"), "2026-11-03")
        self.assertEqual(tzlog.operating_day(None, "fallback"), "fallback")
        self.assertEqual(tzlog.board_day("2|#VN#1#DA#311026#1S#8000105#", "x"), "2026-10-31")
        self.assertEqual(tzlog.board_day("nothing", "fallback"), "fallback")

    def test_vehicle_journeys(self):
        body = {"vehicle": {"vehicleGroupName": "ICE9490"}, "journeys": [
            {"journeyID": "20261028-aa", "journeyRelation": {"startTime": "2026-10-28T04:56:00Z", "startCategory": "ICE",
                                                              "startJourneyNumber": 271}},
            # Leaves at 23:30 UTC = 00:30 the next day in Germany, but the journey's own day is the 3rd.
            {"journeyID": "20261103-bb", "journeyRelation": {"startTime": "2026-11-03T23:30:00Z", "startCategory": "ICE",
                                                              "startJourneyNumber": 610}},
            {"journeyID": "x", "journeyRelation": {"startTime": "2026-11-03T08:28:00Z"}},
        ]}
        self.assertEqual(tzlog.parse_vehicle_journeys(body), ("9490", [("2026-10-28", "ICE", 271), ("2026-11-03", "ICE", 610)]))
        self.assertEqual(tzlog.parse_vehicle_journeys({"vehicle": {}}), (None, []))
        self.assertEqual(tzlog.parse_vehicle_journeys(None), (None, []))


class StoreTests(unittest.TestCase):
    def sighting(self, tz, number, category="ICE", vehicle="938000000001", destination="Köln Hbf"):
        return {"tz": tz, "unit": "ICE" + tz, "types": ["I4080"], "vehicle": vehicle, "category": category,
                "number": number, "destination": destination, "status": "MATCHES_SCHEDULE"}

    def record(self, store, day, tz, number, station="Berlin Hbf", **kwargs):
        sighting = self.sighting(tz, number, **kwargs)
        store.record_unit(sighting, 1)
        store.record(day, sighting, station, 1)

    def test_list_has_each_tz_once_with_its_latest_day(self):
        store = tzlog.TzStore()
        self.record(store, "2026-10-30", "8043", 318)
        self.record(store, "2026-10-31", "8043", 592)
        self.record(store, "2026-10-31", "8043", 593, station="Hannover Hbf")
        self.record(store, "2026-10-31", "169", 10)
        units = store.units()
        self.assertEqual([u["tz"] for u in units], ["169", "8043"])
        self.assertEqual(units[1]["lastDay"], "2026-10-31")
        self.assertEqual(units[1]["types"], ["I4080"])
        self.assertEqual([t["number"] for t in units[1]["trains"]], [592, 593])

    def test_a_vehicle_lookup_keeps_what_the_boards_knew(self):
        store = tzlog.TzStore()
        self.record(store, "2026-10-31", "8043", 592)
        # The WiFi host only knows the train: no destination, station, status or coach types.
        store.record("2026-10-31", {"tz": "8043", "category": "ICE", "number": 592}, None, 2)
        store.record_unit({"tz": "8043", "unit": "ICE8043", "types": [], "vehicle": None}, 2)
        train = store.units()[0]["trains"][0]
        self.assertEqual((train["destination"], train["station"], train["status"]),
                         ("Köln Hbf", "Berlin Hbf", "MATCHES_SCHEDULE"))
        self.assertEqual(store.units()[0]["types"], ["I4080"])
        self.assertEqual(store.vehicles(), [("8043", "938000000001", False)])

    def test_has_train_and_backfilled_and_dropped_vehicles(self):
        store = tzlog.TzStore()
        self.record(store, "2026-10-31", "8043", 592)
        self.assertTrue(store.has_train("2026-10-31", "ICE", 592))
        self.assertFalse(store.has_train("2026-11-01", "ICE", 592))
        store.mark_backfilled("8043")
        self.assertEqual(store.vehicles(), [("8043", "938000000001", True)])
        store.drop_vehicle("8043")
        self.assertEqual(store.vehicles(), [])
        self.assertEqual(len(store.units()), 1, "its trains stay")
        self.record(store, "2026-11-01", "8043", 592, vehicle="938000000009")
        self.assertEqual(store.vehicles(), [("8043", "938000000009", True)])

    def test_history_newest_first_and_prune_after_a_year(self):
        store = tzlog.TzStore()
        self.record(store, "2025-10-01", "8043", 1)
        self.record(store, "2026-10-30", "8043", 2)
        self.record(store, "2026-10-31", "8043", 3)
        self.assertEqual([t["day"] for t in store.history("8043")], ["2026-10-31", "2026-10-30", "2025-10-01"])
        store.prune(dt.date(2026, 10, 31))
        self.assertEqual([t["day"] for t in store.history("8043")], ["2026-10-31", "2026-10-30"])

    def test_prune_forgets_a_tz_without_trains(self):
        store = tzlog.TzStore()
        self.record(store, "2025-01-01", "169", 1)
        self.record(store, "2026-10-31", "8043", 3)
        store.prune(dt.date(2026, 10, 31))
        self.assertEqual([tz for tz, _, _ in store.vehicles()], ["8043"])


class FakeBahnDe:
    """Boards: Berlin has one full page (7 trains, ICE 1…7) then nothing; Hamburg shows ICE 5 again."""

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
        return 200, sequence((f"ICE{8000 + number}", number, [(f"9380000000{number:02d}", "I4080")]))

    @staticmethod
    def entry(number, zeit):
        return {"zeit": zeit, "journeyId": f"2|#VN#1#DA#311026#ZE#{number}#", "verkehrmittel": {"name": f"ICE {number}"}}


def noop_sleep():
    slept = []

    async def sleep(seconds):
        slept.append(seconds)

    sleep.slept = slept
    return sleep


NOW = dt.datetime(2026, 10, 31, 10, 0, tzinfo=tzlog.BERLIN).timestamp()


class BoardScanTests(unittest.IsolatedAsyncioTestCase):
    async def scan(self, bahn_de, hubs=(("1", "Berlin Hbf"), ("2", "Hamburg Hbf")), every=3600, store=None):
        self.store = store or tzlog.TzStore()
        scanner = tzlog.Scanner(self.store, bahn_de, hubs=list(hubs), every=every, now=lambda: NOW, sleep=noop_sleep())
        await scanner.scan()
        return scanner

    async def test_asks_each_train_once_and_records_it_with_the_hub_and_its_coach(self):
        bahn_de = FakeBahnDe()
        await self.scan(bahn_de)
        asked = [p for p in bahn_de.paths if p.startswith("reisebegleitung")]
        self.assertEqual(len(asked), 7)
        self.assertEqual([u["tz"] for u in self.store.units()], [str(8000 + n) for n in range(1, 8)])
        self.assertEqual(self.store.history("8005")[0]["station"], "Berlin Hbf")
        self.assertEqual(self.store.history("8005")[0]["day"], "2026-10-31")
        self.assertEqual(dict((tz, v) for tz, v, _ in self.store.vehicles())["8005"], "938000000005")

    async def test_trains_a_vehicle_lookup_already_named_are_not_asked(self):
        store = tzlog.TzStore()
        store.record("2026-10-31", {"tz": "8003", "category": "ICE", "number": 3}, None, 1)
        bahn_de = FakeBahnDe()
        await self.scan(bahn_de, store=store)
        asked = [p for p in bahn_de.paths if p.startswith("reisebegleitung")]
        self.assertEqual(len(asked), 6)
        self.assertFalse(any("number=3&" in p for p in asked))

    async def test_full_page_continues_where_it_ended_and_empty_one_an_hour_later(self):
        bahn_de = FakeBahnDe()
        await self.scan(bahn_de, hubs=[("1", "Berlin Hbf")], every=7200)
        boards = [p.split("zeit=")[1].split("&")[0] for p in bahn_de.paths if p.startswith("reiseloesung")]
        self.assertEqual(boards, ["10:00:00", "10:35:00", "11:35:00"])

    async def test_next_scan_continues_where_the_last_window_ended(self):
        boards = []

        async def get(path):
            if path.startswith("reiseloesung"):
                boards.append(path.split("zeit=")[1].split("&")[0])
            return 200, {"entries": []}

        clock = [NOW]
        scanner = tzlog.Scanner(tzlog.TzStore(), get, hubs=[("1", "Berlin Hbf")], interval=0, every=3600,
                                now=lambda: clock[0], sleep=noop_sleep())
        await scanner.scan()
        clock[0] += 3600 + 20 * 60  # the next scan starts 20 minutes late
        await scanner.scan()
        # The first reads 10:00 up to 11:00, the second 11:00 (not 11:20) on, up to 12:20.
        self.assertEqual(boards, ["10:00:00", "11:00:00", "12:00:00"])

    async def test_sequence_asked_with_utc_time_and_berlin_day(self):
        path = tzlog.sequence_path("ICE", 1516, "8000105", dt.datetime(2026, 11, 1, 0, 41))
        self.assertIn("date=2026-11-01", path)
        self.assertIn("time=2026-10-31T23:41:00.000Z", path)

    async def test_waits_out_the_proxys_pause(self):
        calls = []

        async def get(path):
            calls.append(path)
            return (503, None) if len(calls) == 1 else (200, {"entries": []})

        sleep = noop_sleep()
        scanner = tzlog.Scanner(tzlog.TzStore(), get, hubs=[("1", "Berlin Hbf")], interval=0, every=3600,
                                now=lambda: NOW, sleep=sleep, pause_left=lambda: 30 if len(calls) == 1 else 0)
        await scanner.scan()
        self.assertEqual(len(calls), 2)
        self.assertIn(31, sleep.slept)


class VehicleRoundTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.store = tzlog.TzStore()
        for tz, vehicle in (("8043", "938000000043"), ("9490", "938000000090")):
            self.store.record_unit({"tz": tz, "unit": "ICE" + tz, "types": ["I4080"], "vehicle": vehicle}, 1)
        self.asked = []
        self.answers = {}

    async def ris(self, uic, day):
        self.asked.append((uic, day))
        return self.answers.get((uic, day)) or self.answers.get(uic) or (404, None)

    def scanner(self, **options):
        return tzlog.Scanner(self.store, None, hubs=[], now=lambda: NOW, sleep=noop_sleep(), ris=self.ris, **options)

    @staticmethod
    def answer(group, *journeys):
        return 200, {"vehicle": {"vehicleGroupName": group}, "journeys": [
            {"journeyID": day.replace("-", "") + "-x",
             "journeyRelation": {"startTime": day + "T08:00:00Z", "startCategory": category, "startJourneyNumber": number}}
            for day, category, number in journeys]}

    async def test_a_new_tz_gets_the_last_week_then_only_today(self):
        scanner = self.scanner()
        self.answers = {("938000000043", "2026-10-30"): self.answer("ICE8043", ("2026-10-30", "ICE", 699)),
                        ("938000000043", "2026-10-31"): self.answer("ICE8043", ("2026-10-31", "ICE", 610), ("2026-10-31", "ICE", 611))}
        await scanner.scan_vehicles()
        self.assertEqual(len(self.asked), 2 * (tzlog.BACKFILL_DAYS + 1))
        self.assertEqual([t["number"] for t in self.store.history("8043")], [610, 611, 699])
        self.assertTrue(all(done for _, _, done in self.store.vehicles()))
        self.asked.clear()
        await scanner.scan_vehicles()
        self.assertEqual(self.asked, [("938000000043", "2026-10-31"), ("938000000090", "2026-10-31")])

    async def test_a_days_first_round_also_asks_the_day_before(self):
        scanner = self.scanner()
        await scanner.scan_vehicles()
        self.asked.clear()
        scanner.now = lambda: NOW + 24 * 3600
        await scanner.scan_vehicles()
        self.assertEqual([d for _, d in self.asked], ["2026-10-31", "2026-11-01"] * 2)

    async def test_a_coach_in_another_trainset_is_dropped_not_recorded(self):
        scanner = self.scanner()
        self.answers = {"938000000043": self.answer("ICE8099", ("2026-10-31", "ICE", 610)),
                        "938000000090": (404, None)}
        await scanner.scan_vehicles()
        self.assertEqual(self.store.history("8043"), [])
        self.assertEqual([tz for tz, _, _ in self.store.vehicles()], ["9490"])

    async def test_failures_leave_it_for_the_next_round_and_stop_after_five_in_a_row(self):
        for n in range(10):
            self.store.record_unit({"tz": str(100 + n), "unit": "ICE", "types": [], "vehicle": f"93800000{n:04d}"}, 1)
        scanner = self.scanner()
        self.answers = {}

        async def failing(uic, day):
            self.asked.append((uic, day))
            return 500, None

        scanner.ris = failing
        await scanner.scan_vehicles()
        self.assertEqual(len(self.asked), tzlog.RIS_MAX_FAILURES)
        self.assertFalse(any(done for _, _, done in self.store.vehicles()), "not backfilled, tried again later")

    async def test_no_wifi_host_no_round(self):
        scanner = tzlog.Scanner(self.store, None, hubs=[], now=lambda: NOW, sleep=noop_sleep(), ris=None)
        await scanner.scan_vehicles()
        self.assertEqual(self.asked, [])


class RunTests(unittest.IsolatedAsyncioTestCase):
    async def test_boards_and_vehicles_run_each_on_their_own_period(self):
        clock = [1000.0]
        calls = []
        sleeps = []

        async def sleep(seconds):
            sleeps.append(seconds)
            clock[0] += seconds
            if len(sleeps) == 5:
                raise asyncio.CancelledError

        scanner = tzlog.Scanner(tzlog.TzStore(), None, hubs=[], every=100, vehicle_every=250, now=lambda: clock[0],
                                sleep=sleep, ris=lambda *args: None)

        async def boards():
            calls.append(("boards", clock[0]))
            clock[0] += 30  # a scan takes time; the next one still starts `every` after this one began

        async def vehicles():
            calls.append(("vehicles", clock[0]))

        scanner.scan, scanner.scan_vehicles = boards, vehicles
        with self.assertRaises(asyncio.CancelledError):
            await scanner.run()
        # Boards every 100 s from their start, vehicles every 250 s from theirs (1030 + 250).
        self.assertEqual(calls[:5], [("boards", 1000.0), ("vehicles", 1030.0), ("boards", 1100.0), ("boards", 1200.0),
                                     ("vehicles", 1280.0)])

    async def test_without_a_wifi_host_only_the_boards_run(self):
        clock = [0.0]
        calls = []

        async def sleep(seconds):
            clock[0] += seconds
            if clock[0] > 500:
                raise asyncio.CancelledError

        scanner = tzlog.Scanner(tzlog.TzStore(), None, hubs=[], every=100, now=lambda: clock[0], sleep=sleep, ris=None)

        async def boards():
            calls.append("boards")

        async def vehicles():
            calls.append("vehicles")

        scanner.scan, scanner.scan_vehicles = boards, vehicles
        with self.assertRaises(asyncio.CancelledError):
            await scanner.run()
        self.assertEqual(set(calls), {"boards"})


class RisClientTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.requests = []
        self.reject_first = False

        async def page(request):
            self.requests.append("page")
            response = web.Response(text='<html><meta name="csrf-token" content="tok-1"></html>', content_type="text/html")
            response.set_cookie("csrf", "cookie-1")
            return response

        async def journeys(request):
            self.requests.append(f"journeys {request.match_info['uic']} {request.query.get('date')}")
            if self.reject_first and self.requests.count("page") == 1:
                return web.json_response({"error": "csrf"}, status=403)
            if request.headers.get("Csrf-Token") != "tok-1" or request.cookies.get("csrf") != "cookie-1":
                return web.json_response({"error": "csrf"}, status=403)
            return web.json_response({"vehicle": {"vehicleGroupName": "ICE9490"}, "journeys": []})

        app = web.Application()
        app.router.add_get("/", page)
        app.router.add_get("/api/transports/vehicles/{uic}/journeys", journeys)
        self.server = TestServer(app)
        await self.server.start_server()
        self.client = tzlog.RisClient(base=str(self.server.make_url("")).rstrip("/"), accept_ip_cookies=True)
        self.addAsyncCleanup(self.client.close)
        self.addAsyncCleanup(self.server.close)

    async def test_sends_the_pages_token_and_cookie_back_and_reuses_the_session(self):
        status, body = await self.client("938000000043", "2026-11-03")
        self.assertEqual((status, body["vehicle"]["vehicleGroupName"]), (200, "ICE9490"))
        await self.client("938000000043", "2026-11-02")
        self.assertEqual(self.requests, ["page", "journeys 938000000043 2026-11-03", "journeys 938000000043 2026-11-02"])

    async def test_a_refused_token_starts_a_new_session_once(self):
        self.reject_first = True
        status, _ = await self.client("938000000043", "2026-11-03")
        self.assertEqual(status, 200)
        self.assertEqual(self.requests.count("page"), 2)

    async def test_only_digits_are_asked_for(self):
        self.assertEqual((await self.client("../x", "2026-11-03"))[0], 400)
        self.assertEqual(self.requests, [])


if __name__ == "__main__":
    unittest.main()
