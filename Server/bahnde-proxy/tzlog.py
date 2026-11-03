"""The Tz log (#502): which trainset (Tz) ran which ICE/IC, today and for a year back.

The log runs on the **RIS::Transports API behind the on-board WiFi landing page** (`RisClient`): one request per
known Tz and day asks which journeys its coach is in (the first time also the last `BACKFILL_DAYS` days), without
logging in. The known Tz come from `tz_seed.json` (a list of Tz with the UIC number of one coach, made by
`make_tz_seed.py` and checked into the repo), so the server needs nothing else for them.

bahn.de is only asked to learn Tz the list doesn't have yet (a new delivery, a renumbered set), and only a little:
after each vehicle round the server reads the ICE/IC departure boards of a few big stations (`HUBS`) for the rest
of the day and asks the Wagenreihung of the trains the vehicle round did not explain, which names the Tz and gives
a coach. When every train is explained, that is a few dozen board requests a day and no more.

"Tz X ran as train Y on day Z" stays in a small SQLite file for `RETENTION_DAYS`. The app reads it with
`GET /tz/list` (every Tz with the trains of its latest day) and `GET /tz/history?tz=8043`.

The scan stays small: `TZ_RIS_INTERVAL` seconds between requests to the WiFi host, `TZ_SCAN_INTERVAL` between
those to bahn.de (through the proxy: its cache, turn-taking and pause, and the app's own requests go first), and it
records no one who asks.

Environment: TZ_DB (file, default `tz.db` next to this file), TZ_SEED (default `tz_seed.json` next to this file),
TZ_SCAN ("false" turns the scan off, the log is still served), TZ_VEHICLE_EVERY (43200: seconds between two rounds),
TZ_RIS ("false" turns the WiFi host off), TZ_RIS_INTERVAL (1), TZ_BOARDS ("false" never asks bahn.de),
TZ_SCAN_INTERVAL (3).
"""

import asyncio
import datetime as dt
import json
import logging
import re
import sqlite3
import time
from pathlib import Path
from urllib.parse import quote
from zoneinfo import ZoneInfo

import aiohttp

log = logging.getLogger("bahnde-proxy.tz")

BERLIN = ZoneInfo("Europe/Berlin")
RETENTION_DAYS = 365
# A trainset's group name in the Wagenreihung: ICE and ICD (IC 2) units have a Tz; a loco-hauled IC 1's
# coach set ("IC450007") hasn't.
GROUP_NAME = re.compile(r"^(ICE|ICD)(\d{1,5})$")
MAX_TYPES = 12
BOARD_PAGE = 7
# The first time a Tz is known, its journeys of this many days back are asked too (the API keeps about a week).
BACKFILL_DAYS = 6
RIS_BASE = "https://wifi-landingpage.dbregio.de"
RIS_USER_AGENT = "BetterBahn tz log (+https://betterbahn.betterbahn.workers.dev/support)"
RIS_SESSION_MAX_AGE = 3600
# This many failed requests in a row end a round at the WiFi host.
RIS_MAX_FAILURES = 5

# Stations whose boards the server reads to find Tz the seed list lacks: the busiest long-distance stations, which a
# new trainset passes within days. bahn.de's EVA number and name.
HUBS = [
    ("8000261", "München Hbf"), ("8000152", "Hannover Hbf"), ("8000207", "Köln Hbf"), ("8011160", "Berlin Hbf"),
    ("8000191", "Karlsruhe Hbf"), ("8002549", "Hamburg Hbf"),
]
# What `make_tz_seed.py` reads: stations that together list every ICE, IC and ECE run that touches Germany (greedy
# cover of one day's runs from the train statistics, 2026-10-30: 806 runs).
SEED_HUBS = HUBS + [
    ("8000177", "Horb"), ("8010205", "Leipzig Hbf"), ("8003693", "Lindau-Reutin"), ("8000244", "Mannheim Hbf"),
    ("8011201", "Flughafen BER"), ("8003200", "Kassel-Wilhelmshöhe"), ("8000284", "Nürnberg Hbf"),
    ("8000085", "Düsseldorf Hbf"), ("8000225", "Leer(Ostfriesl)"),
]


def unit_number(group_name):
    """("ICE", "8043") for "ICE8043" or "ICE08043"; None for anything without a Tz."""
    match = GROUP_NAME.match(group_name or "")
    if not match:
        return None
    digits = match.group(2).lstrip("0")
    return (match.group(1), digits) if digits else None


def pick_vehicle(vehicles):
    """The UIC number of a coach of the trainset that stays with it: a passenger coach, else a control car or
    power car. Never a locomotive, which hauls other sets on another day (an IC 2's)."""
    def rank(vehicle):
        category = ((vehicle or {}).get("type") or {}).get("category") or ""
        if "LOCOMOTIVE" in category:
            return None
        if category.startswith("PASSENGERCARRIAGE"):
            return 0
        return 1
    ranked = sorted((rank(v), n) for n, v in enumerate(vehicles or []) if isinstance(v, dict) and v.get("vehicleID") and rank(v) is not None)
    if not ranked:
        return None
    chosen = (vehicles or [])[ranked[0][1]]
    vehicle_id = str(chosen["vehicleID"])
    return vehicle_id if vehicle_id.isdigit() else None


def parse_sequence(body, category, number):
    """The trainsets in a Wagenreihung answer: one dict per group that has a Tz and belongs to the train
    asked for (or one coupled to it, which has its own number). A sequence naming only other trains is
    somebody else's (bahn.de sometimes answers with one) and gives nothing."""
    groups = body.get("groups") if isinstance(body, dict) else None
    result = []
    numbers = {(g.get("transport") or {}).get("number") for g in groups or [] if isinstance(g, dict)}
    numbers.discard(None)
    if number not in numbers and numbers:
        return []
    for group in groups or []:
        if not isinstance(group, dict):
            continue
        unit = unit_number(group.get("name"))
        if unit is None:
            continue
        transport = group.get("transport") or {}
        vehicles = group.get("vehicles") or []
        types = sorted({(v.get("type") or {}).get("constructionType") for v in vehicles
                        if isinstance(v, dict)} - {None})[:MAX_TYPES]
        result.append({
            "tz": unit[1], "unit": unit[0] + unit[1], "types": types, "vehicle": pick_vehicle(vehicles),
            "category": transport.get("category") or category,
            "number": transport.get("number") or number,
            "destination": ((transport.get("destination") or {}).get("name")),
            "status": body.get("sequenceStatus"),
        })
    return result


def operating_day(journey_id, fallback):
    """The operating day ("2026-11-03") a journey ID starts with ("20261103-dcbe…"), else `fallback`."""
    match = re.match(r"^(\d{4})(\d\d)(\d\d)-", journey_id or "")
    return f"{match.group(1)}-{match.group(2)}-{match.group(3)}" if match else fallback


def board_day(board_journey_id, fallback):
    """The operating day in a board's HAFAS journey ID ("…#DA#311026#…" is 31.10.2026), else `fallback`."""
    match = re.search(r"#DA#(\d\d)(\d\d)(\d\d)#", board_journey_id or "")
    return f"20{match.group(3)}-{match.group(2)}-{match.group(1)}" if match else fallback


def parse_vehicle_journeys(body):
    """(Tz of the vehicle's trainset or None, [(day, category, number)]) from a vehicle-journeys answer."""
    if not isinstance(body, dict):
        return None, []
    unit = unit_number(((body.get("vehicle") or {}).get("vehicleGroupName")))
    trains = []
    for journey in body.get("journeys") or []:
        relation = (journey or {}).get("journeyRelation") or {}
        category, number, start = relation.get("startCategory"), relation.get("startJourneyNumber"), relation.get("startTime")
        if not category or not isinstance(number, int) or not start:
            continue
        try:
            fallback = dt.datetime.fromisoformat(start.replace("Z", "+00:00")).astimezone(BERLIN).date().isoformat()
        except ValueError:
            continue
        trains.append((operating_day(journey.get("journeyID"), fallback), category, number))
    return (unit[1] if unit else None), trains


class TzStore:
    """SQLite file: `units` (one row per Tz) and `sightings` (one row per Tz, day and train)."""

    def __init__(self, path=":memory:"):
        self.db = sqlite3.connect(path)
        self.db.execute("""CREATE TABLE IF NOT EXISTS units (
            tz TEXT PRIMARY KEY, unit TEXT NOT NULL, types TEXT NOT NULL, vehicle TEXT, seen REAL NOT NULL,
            backfilled INTEGER NOT NULL DEFAULT 0)""")
        self.db.execute("""CREATE TABLE IF NOT EXISTS sightings (
            tz TEXT NOT NULL, day TEXT NOT NULL, category TEXT NOT NULL, number INTEGER NOT NULL,
            station TEXT, destination TEXT, status TEXT, seen REAL NOT NULL,
            PRIMARY KEY (tz, day, category, number))""")
        self.db.execute("CREATE INDEX IF NOT EXISTS by_day ON sightings (day)")
        self.db.commit()

    def record_unit(self, sighting, now):
        """Remembers a Tz with its vehicle types and the UIC number of one coach (kept when a sighting has none)."""
        self.db.execute(
            """INSERT INTO units (tz, unit, types, vehicle, seen) VALUES (?, ?, ?, ?, ?)
               ON CONFLICT (tz) DO UPDATE SET unit = excluded.unit,
               types = CASE WHEN excluded.types = '[]' THEN types ELSE excluded.types END,
               vehicle = COALESCE(excluded.vehicle, vehicle), seen = excluded.seen""",
            (sighting["tz"], sighting["unit"], json.dumps(sighting["types"]), sighting.get("vehicle"), now))
        self.db.commit()

    def load_seed(self, path, now=None):
        """Adds the Tz of a seed file (`[{"tz", "unit", "types", "vehicle"}]`) that the log doesn't have yet; what it
        learned itself stays. Returns how many were new."""
        try:
            seed = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return 0
        known = {tz for (tz,) in self.db.execute("SELECT tz FROM units")}
        added = 0
        for item in seed if isinstance(seed, list) else []:
            tz, vehicle = str(item.get("tz", "")), str(item.get("vehicle") or "")
            if not tz.isdigit() or not vehicle.isdigit() or tz in known:
                continue
            self.record_unit({"tz": tz, "unit": item.get("unit") or "ICE" + tz, "types": item.get("types") or [],
                              "vehicle": vehicle}, time.time() if now is None else now)
            added += 1
        return added

    def record(self, day, sighting, station, now):
        """Tz X ran as train Y on `day`; what a later sighting doesn't know (destination, station) is kept."""
        self.db.execute(
            """INSERT INTO sightings (tz, day, category, number, station, destination, status, seen)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT (tz, day, category, number) DO UPDATE SET
               station = COALESCE(excluded.station, station), destination = COALESCE(excluded.destination, destination),
               status = COALESCE(excluded.status, status), seen = excluded.seen""",
            (sighting["tz"], day, sighting["category"], sighting["number"], station, sighting.get("destination"),
             sighting.get("status"), now))
        self.db.commit()

    def has_train(self, day, category, number):
        return self.db.execute("SELECT 1 FROM sightings WHERE day = ? AND category = ? AND number = ? LIMIT 1",
                               (day, category, number)).fetchone() is not None

    def vehicles(self):
        """(tz, UIC number, already backfilled) of every Tz with a known coach."""
        return [(tz, vehicle, bool(done)) for tz, vehicle, done in self.db.execute(
            "SELECT tz, vehicle, backfilled FROM units WHERE vehicle IS NOT NULL ORDER BY CAST(tz AS INTEGER)")]

    def mark_backfilled(self, tz):
        self.db.execute("UPDATE units SET backfilled = 1 WHERE tz = ?", (tz,))
        self.db.commit()

    def drop_vehicle(self, tz):
        """Forgets a coach that turned out to run in another trainset; boards teach the right one again."""
        self.db.execute("UPDATE units SET vehicle = NULL WHERE tz = ?", (tz,))
        self.db.commit()

    @staticmethod
    def _train(row):
        return {"day": row[0], "category": row[1], "number": row[2], "station": row[3], "destination": row[4],
                "status": row[5]}

    def units(self):
        """Every Tz with its latest day's trains, ordered by Tz."""
        rows = self.db.execute(
            """SELECT s.tz, u.unit, u.types, s.day, s.category, s.number, s.station, s.destination, s.status
               FROM sightings s
               JOIN (SELECT tz, MAX(day) AS day FROM sightings GROUP BY tz) latest ON s.tz = latest.tz AND s.day = latest.day
               LEFT JOIN units u ON u.tz = s.tz ORDER BY CAST(s.tz AS INTEGER), s.number""").fetchall()
        units = {}
        for tz, unit, types, day, category, number, station, destination, status in rows:
            entry = units.setdefault(tz, {"tz": tz, "unit": unit or ("ICE" + tz), "types": json.loads(types or "[]"),
                                          "lastDay": day, "trains": []})
            entry["trains"].append(self._train((day, category, number, station, destination, status)))
        return list(units.values())

    def history(self, tz):
        """The trains a Tz ran, newest day first."""
        rows = self.db.execute(
            """SELECT day, category, number, station, destination, status FROM sightings WHERE tz = ?
               ORDER BY day DESC, number""", (tz,)).fetchall()
        return [self._train(row) for row in rows]

    def prune(self, today):
        """Forgets what is older than `RETENTION_DAYS` before `today` (a `date`), and Tz not seen since."""
        limit = (today - dt.timedelta(days=RETENTION_DAYS)).isoformat()
        self.db.execute("DELETE FROM sightings WHERE day < ?", (limit,))
        self.db.execute("DELETE FROM units WHERE tz NOT IN (SELECT DISTINCT tz FROM sightings)")
        self.db.commit()


def board_path(eva, local):
    """The ICE/EC/IC departure board of a station from `local` (a Berlin `datetime`) on."""
    return (f"reiseloesung/abfahrten?datum={local:%Y-%m-%d}&zeit={local:%H:%M:00}&ortExtId={eva}"
            f"&ortId={quote(f'A=1@L={eva}@', safe='')}&mitVias=false&verkehrsmittel[]=ICE&verkehrsmittel[]=EC_IC")


def sequence_path(category, number, eva, local):
    """The Wagenreihung of a train leaving `eva` at `local` (naive Berlin time, as the board has it)."""
    departure = local.replace(tzinfo=BERLIN)
    utc = departure.astimezone(dt.timezone.utc)
    return ("reisebegleitung/wagenreihung/vehicle-sequence?administrationId=80"
            f"&category={quote(category)}&date={departure:%Y-%m-%d}&evaNumber={eva}&number={number}"
            f"&time={utc:%Y-%m-%dT%H:%M:00.000Z}")


class RisClient:
    """`async (uic, day) -> (status, body)`: the journeys a coach is in on `day` (`yyyy-MM-dd`), from the
    RIS::Transports API behind DB Regio's WiFi landing page. It needs no login, only what the page itself
    does: load the page, send its CSRF cookie back with the token from its HTML. Not a documented API, so it
    can change; the log then simply stops growing from here. `base` and `accept_ip_cookies` are for tests."""

    def __init__(self, base=RIS_BASE, clock=time.monotonic, accept_ip_cookies=False):
        self.base = base
        self.accept_ip_cookies = accept_ip_cookies
        self.clock = clock
        self.session = None
        self.token = None
        self.started = 0

    async def close(self):
        session, self.session = self.session, None
        if session is not None:
            await session.close()

    async def _headers(self):
        if self.session is not None and self.clock() - self.started > RIS_SESSION_MAX_AGE:
            await self.close()
        if self.session is None:
            self.session = aiohttp.ClientSession(cookie_jar=aiohttp.CookieJar(unsafe=self.accept_ip_cookies), timeout=aiohttp.ClientTimeout(total=15),
                                                 headers={"User-Agent": RIS_USER_AGENT})
            async with self.session.get(self.base + "/") as page:
                html = await page.text()
            match = re.search(r'name="csrf-token" content="([^"]+)"', html, re.I)
            if not match:
                await self.close()
                raise ConnectionError("WiFi landing page gave no CSRF token")
            self.token, self.started = match.group(1), self.clock()
        return {"Accept": "application/json", "Csrf-Token": self.token}

    async def __call__(self, uic, day):
        if not str(uic).isdigit():
            return 400, None
        for attempt in range(2):
            headers = await self._headers()
            async with self.session.get(f"{self.base}/api/transports/vehicles/{uic}/journeys",
                                        params={"date": day}, headers=headers) as response:
                if response.status in (401, 403) and attempt == 0:
                    await self.close()  # a new session, a new token
                    continue
                try:
                    body = await response.json(content_type=None)
                except Exception:  # noqa: BLE001 - no JSON, e.g. an error page
                    body = None
                return response.status, body
        return 403, None


class Scanner:
    """Fills a `TzStore`. `get(path) -> (status, body)` asks bahn.de through the proxy, `ris(uic, day) ->
    (status, body)` the WiFi host (`RisClient`, none: no vehicle lookups); replaced in tests."""

    def __init__(self, store, get, hubs=HUBS, interval=3.0, every=43200, now=time.time, sleep=asyncio.sleep,
                 pause_left=lambda: 0, ris=None, ris_interval=1.0, vehicle_every=43200):
        self.store = store
        self.get = get
        self.hubs = hubs
        self.interval = interval
        self.every = every
        self.now = now
        self.sleep = sleep
        self.pause_left = pause_left
        self.ris = ris
        self.ris_interval = ris_interval
        self.vehicle_every = vehicle_every
        # Where the last finished board scan's window ended (naive Berlin time): the next one starts there, so a
        # scan that took a while, or ran late, leaves no trains between two windows.
        self.covered_until = None
        # The day the last vehicle round ran on; the first round of a day also asks the day before.
        self.vehicle_day = None

    async def run(self):
        """Vehicle rounds `vehicle_every` apart and board scans `every` apart, whatever one took; a round's vehicle
        lookups come first, so the boards only ask for trains they didn't explain."""
        next_boards = next_vehicles = self.now()
        while True:
            for name in ("vehicles", "boards"):
                due = next_boards if name == "boards" else next_vehicles
                if name == "vehicles" and self.ris is None or self.now() < due:
                    continue
                started = self.now()
                try:
                    await (self.scan() if name == "boards" else self.scan_vehicles())
                except asyncio.CancelledError:
                    raise
                except Exception:  # noqa: BLE001 - the next round starts fresh
                    log.exception("Tz %s round failed", name)
                if name == "boards":
                    next_boards = started + self.every
                else:
                    next_vehicles = started + self.vehicle_every
            upcoming = [next_boards] + ([next_vehicles] if self.ris is not None else [])
            await self.sleep(max(1.0, min(upcoming) - self.now()))

    async def _ask(self, path):
        """(status, parsed body or None) of a bahn.de path, after the proxy's pause if it is paused."""
        for _ in range(2):
            wait = self.pause_left()
            if wait > 0:
                await self.sleep(wait + 1)
            await self.sleep(self.interval)
            status, body = await self.get(path)
            if status != 503:
                return status, body
        return 503, None

    async def scan(self):
        """One board scan: trains of the hubs' boards no earlier answer explains get their Wagenreihung asked."""
        started = self.now()
        now = dt.datetime.fromtimestamp(started, BERLIN).replace(tzinfo=None, second=0, microsecond=0)
        # Not past midnight: the vehicle lookups know the trains of the day, and what they know isn't asked again.
        end = min(now + dt.timedelta(seconds=self.every), dt.datetime.combine(now.date() + dt.timedelta(days=1), dt.time()))
        # Continue where the last scan stopped; after a long break (or the first scan) start now.
        start = now
        if self.covered_until is not None and dt.timedelta(0) <= now - self.covered_until < dt.timedelta(hours=6):
            start = self.covered_until
        done = set()
        asked = found = 0
        for eva, name in self.hubs:
            entries = await self.entries(eva, start, end)
            log.info("Tz scan: %s lists %d trains", name, len(entries))
            for entry in entries:
                train = entry.get("verkehrmittel") or {}
                parts = (train.get("name") or "").split()
                try:
                    category, number = parts[0], int(parts[-1])
                    local = dt.datetime.fromisoformat(entry["zeit"]).replace(tzinfo=None)
                except (IndexError, ValueError, KeyError, TypeError):
                    continue
                day = board_day(entry.get("journeyId"), local.date().isoformat())
                key = (day, category, number)
                if key in done:
                    continue
                done.add(key)
                if self.store.has_train(*key):
                    continue  # a vehicle lookup (or an earlier scan) already named its Tz
                status, body = await self._ask(sequence_path(category, number, eva, local))
                asked += 1
                if status != 200:
                    continue
                for sighting in parse_sequence(body, category, number):
                    self.store.record_unit(sighting, self.now())
                    self.store.record(operating_day(body.get("journeyID"), day), sighting, name, self.now())
                    found += 1
        self.covered_until = end
        self.store.prune(now.date())
        log.info("Tz scan: %d trains on the boards, %d asked, %d trainsets", len(done), asked, found)

    async def entries(self, eva, start, end):
        """A hub's board entries from `start` up to `end`, page by page."""
        entries, seen, at = [], set(), start
        while at < end:
            status, body = await self._ask(board_path(eva, at))
            page = (body or {}).get("entries") if status == 200 and isinstance(body, dict) else None
            if page is None:
                break
            fresh = [e for e in page if e.get("journeyId") not in seen]
            seen.update(e.get("journeyId") for e in fresh)
            entries += fresh
            last = None
            if len(page) >= BOARD_PAGE:
                try:
                    last = dt.datetime.fromisoformat(page[-1]["zeit"]).replace(tzinfo=None)
                except (KeyError, ValueError, TypeError):
                    last = None
            # A full page ends where the next one starts; a short one means the board's window was empty.
            at = last if last is not None and last > at else at + dt.timedelta(hours=1)
        return [e for e in entries if _before(e, end)]

    async def scan_vehicles(self):
        """One request per known Tz and day to the WiFi host: today (and the day before in a day's first round); a
        Tz seen for the first time also gets the last `BACKFILL_DAYS` days."""
        if self.ris is None:
            return
        today = dt.datetime.fromtimestamp(self.now(), BERLIN).date()
        recent = [today] if self.vehicle_day == today else [today - dt.timedelta(days=1), today]
        failures = asked = 0
        for tz, uic, backfilled in self.store.vehicles():
            days = recent if backfilled else [today - dt.timedelta(days=n) for n in range(BACKFILL_DAYS, -1, -1)]
            complete = True
            for day in days:
                await self.sleep(self.ris_interval)
                try:
                    status, body = await self.ris(uic, day.isoformat())
                except Exception:  # noqa: BLE001 - counts as a failed request
                    status, body = 599, None
                asked += 1
                if status == 404:
                    continue  # no journeys that day
                if status != 200:
                    failures += 1
                    complete = False
                    break
                failures = 0
                group, trains = parse_vehicle_journeys(body)
                if group != tz:
                    # The coach runs in another trainset now (or the API names none): learn it again from the boards.
                    self.store.drop_vehicle(tz)
                    complete = False
                    break
                unit = {"tz": tz, "unit": "", "types": [], "vehicle": None}
                for train_day, category, number in trains:
                    self.store.record(train_day, {**unit, "category": category, "number": number}, None, self.now())
            if complete and not backfilled:
                self.store.mark_backfilled(tz)
            if failures >= RIS_MAX_FAILURES:
                log.warning("Tz vehicle round stopped: %d requests failed in a row", failures)
                break
        self.vehicle_day = today
        log.info("Tz vehicle round: %d requests", asked)


def _before(entry, end):
    try:
        return dt.datetime.fromisoformat(entry["zeit"]).replace(tzinfo=None) < end
    except (KeyError, ValueError, TypeError):
        return False
