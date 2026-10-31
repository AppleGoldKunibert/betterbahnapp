"""The Tz log (#502): which trainset (Tz) ran which ICE/IC today, and for a year back.

bahn.de names the trainset of a train in its Wagenreihung ("ICE8043", "ICD4886") hours before it leaves, but
cannot say where a given Tz runs. So the server asks the other way round, slowly: every few hours it reads
the ICE/IC departure boards of the big stations (`HUBS`), asks the Wagenreihung of each train it finds once,
and keeps "Tz X ran as train Y on day Z" in a small SQLite file for `RETENTION_DAYS`. The app reads it with
`GET /tz/list` (every Tz with the trains of its latest day) and `GET /tz/history?tz=8043`.

The scan is meant to stay small: `TZ_SCAN_INTERVAL` seconds between its requests, nothing while bahn.de has
the proxy paused, and the app's own requests take their turn between its. It records no one who asks.

Environment: TZ_DB (file, default `tz.db` next to this file), TZ_SCAN ("false" turns the scan off, the log
is still served), TZ_SCAN_INTERVAL (3), TZ_SCAN_EVERY (10800: seconds between two scans, also how far
ahead each one looks).
"""

import asyncio
import datetime as dt
import json
import logging
import re
import sqlite3
import time
from urllib.parse import quote
from zoneinfo import ZoneInfo

log = logging.getLogger("bahnde-proxy.tz")

BERLIN = ZoneInfo("Europe/Berlin")
RETENTION_DAYS = 365
# A trainset's group name in the Wagenreihung: ICE and ICD (IC 2) units have a Tz; a loco-hauled IC 1's
# coach set ("IC450007") hasn't.
GROUP_NAME = re.compile(r"^(ICE|ICD)(\d{1,5})$")
MAX_TYPES = 12
BOARD_PAGE = 7

# Stations whose ICE/IC departure boards cover (nearly) every long-distance train of Germany, Switzerland,
# the Netherlands and Austria: bahn.de's EVA number and name.
HUBS = [
    ("8011160", "Berlin Hbf"), ("8002549", "Hamburg Hbf"), ("8000261", "München Hbf"),
    ("8000105", "Frankfurt(Main)Hbf"), ("8000207", "Köln Hbf"), ("8000152", "Hannover Hbf"),
    ("8000096", "Stuttgart Hbf"), ("8000284", "Nürnberg Hbf"), ("8010205", "Leipzig Hbf"),
    ("8010085", "Dresden Hbf"), ("8000080", "Dortmund Hbf"), ("8000098", "Essen Hbf"),
    ("8000085", "Düsseldorf Hbf"), ("8000244", "Mannheim Hbf"), ("8000191", "Karlsruhe Hbf"),
    ("8500010", "Basel SBB"), ("8503000", "Zürich HB"), ("8400058", "Amsterdam Centraal"),
    ("8400621", "Utrecht Centraal"), ("8103000", "Wien Hbf"), ("8100002", "Salzburg Hbf"),
    ("8100108", "Innsbruck Hbf"), ("8003200", "Kassel-Wilhelmshöhe"), ("8000260", "Würzburg Hbf"),
    ("8000050", "Bremen Hbf"), ("8000115", "Fulda"), ("8010101", "Erfurt Hbf"),
    ("8000149", "Hamm(Westf)Hbf"), ("8000263", "Münster(Westf)Hbf"), ("8000107", "Freiburg(Breisgau) Hbf"),
    ("8000170", "Ulm Hbf"), ("8070003", "Frankfurt(M) Flughafen Fernbf"), ("8010304", "Rostock Hbf"),
    ("8000199", "Kiel Hbf"), ("8000206", "Koblenz Hbf"), ("8000240", "Mainz Hbf"), ("8000001", "Aachen Hbf"),
    ("8400530", "Rotterdam Centraal"), ("8100173", "Graz Hbf"), ("8010404", "Berlin-Spandau"),
    ("8010224", "Magdeburg Hbf"), ("8010159", "Halle(Saale)Hbf"), ("8004449", "Norddeich"),
    ("8006369", "Westerland(Sylt)"), ("8004585", "Oberstdorf"), ("8003400", "Konstanz"),
    ("8509000", "Chur"), ("8000298", "Passau Hbf"), ("8000309", "Regensburg Hbf"),
    ("8011191", "Binz (Rügen)"), ("8001768", "Emden Hbf"), ("8000291", "Oldenburg(Oldb)Hbf"),
    ("8000294", "Osnabrück Hbf"), ("8000049", "Braunschweig Hbf"), ("8000128", "Göttingen"),
    ("8000036", "Bielefeld Hbf"), ("8000323", "Saarbrücken Hbf"), ("8000134", "Trier Hbf"),
    ("8000156", "Heidelberg Hbf"), ("8010338", "Stralsund Hbf"),
]


def unit_number(group_name):
    """("ICE", "8043") for "ICE8043" or "ICE08043"; None for anything without a Tz."""
    match = GROUP_NAME.match(group_name or "")
    if not match:
        return None
    digits = match.group(2).lstrip("0")
    return (match.group(1), digits) if digits else None


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
        types = sorted({(v.get("type") or {}).get("constructionType") for v in group.get("vehicles") or []
                        if isinstance(v, dict)} - {None})[:MAX_TYPES]
        result.append({
            "tz": unit[1], "unit": unit[0] + unit[1], "types": types,
            "category": transport.get("category") or category,
            "number": transport.get("number") or number,
            "destination": ((transport.get("destination") or {}).get("name")),
            "status": body.get("sequenceStatus"),
        })
    return result


class TzStore:
    """SQLite file with one row per Tz, day and train."""

    def __init__(self, path=":memory:"):
        self.db = sqlite3.connect(path)
        self.db.execute("""CREATE TABLE IF NOT EXISTS sightings (
            tz TEXT NOT NULL, day TEXT NOT NULL, category TEXT NOT NULL, number INTEGER NOT NULL,
            unit TEXT NOT NULL, types TEXT NOT NULL, station TEXT, destination TEXT, status TEXT, seen REAL NOT NULL,
            PRIMARY KEY (tz, day, category, number))""")
        self.db.execute("CREATE INDEX IF NOT EXISTS by_day ON sightings (day)")
        self.db.commit()

    def record(self, day, sighting, station, now):
        self.db.execute(
            """INSERT INTO sightings (tz, day, category, number, unit, types, station, destination, status, seen)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT (tz, day, category, number) DO UPDATE SET unit = excluded.unit, types = excluded.types,
               station = excluded.station, destination = excluded.destination, status = excluded.status,
               seen = excluded.seen""",
            (sighting["tz"], day, sighting["category"], sighting["number"], sighting["unit"],
             json.dumps(sighting["types"]), station, sighting["destination"], sighting["status"], now))
        self.db.commit()

    @staticmethod
    def _train(row):
        return {"day": row[0], "category": row[1], "number": row[2], "station": row[3], "destination": row[4],
                "status": row[5]}

    def units(self):
        """Every Tz with its latest day's trains, ordered by Tz."""
        rows = self.db.execute(
            """SELECT s.tz, s.unit, s.types, s.day, s.category, s.number, s.station, s.destination, s.status
               FROM sightings s JOIN (SELECT tz, MAX(day) AS day FROM sightings GROUP BY tz) latest
               ON s.tz = latest.tz AND s.day = latest.day ORDER BY CAST(s.tz AS INTEGER), s.number""").fetchall()
        units = {}
        for tz, unit, types, day, category, number, station, destination, status in rows:
            entry = units.setdefault(tz, {"tz": tz, "unit": unit, "types": json.loads(types), "lastDay": day, "trains": []})
            entry["trains"].append(self._train((day, category, number, station, destination, status)))
        return list(units.values())

    def history(self, tz):
        """The trains a Tz ran, newest day first."""
        rows = self.db.execute(
            """SELECT day, category, number, station, destination, status FROM sightings WHERE tz = ?
               ORDER BY day DESC, number""", (tz,)).fetchall()
        return [self._train(row) for row in rows]

    def prune(self, today):
        """Forgets what is older than `RETENTION_DAYS` before `today` (a `date`)."""
        limit = (today - dt.timedelta(days=RETENTION_DAYS)).isoformat()
        self.db.execute("DELETE FROM sightings WHERE day < ?", (limit,))
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


class Scanner:
    """Reads the hubs' boards and the Wagenreihung of each train on them, slowly, into a `TzStore`.
    `get(path) -> (status, body)` asks bahn.de through the proxy (replaced in tests)."""

    def __init__(self, store, get, hubs=HUBS, interval=3.0, every=10800, now=time.time, sleep=asyncio.sleep,
                 pause_left=lambda: 0):
        self.store = store
        self.get = get
        self.hubs = hubs
        self.interval = interval
        self.every = every
        self.now = now
        self.sleep = sleep
        self.pause_left = pause_left

    async def run(self):
        while True:
            try:
                await self.scan()
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 - the next scan starts fresh
                log.exception("Tz scan failed")
            await self.sleep(self.every)

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
        started = self.now()
        start = dt.datetime.fromtimestamp(started, BERLIN).replace(tzinfo=None, second=0, microsecond=0)
        end = start + dt.timedelta(seconds=self.every)
        done = set()
        found = 0
        for eva, name in self.hubs:
            for entry in await self.entries(eva, start, end):
                train = entry.get("verkehrmittel") or {}
                parts = (train.get("name") or "").split()
                try:
                    category, number = parts[0], int(parts[-1])
                    local = dt.datetime.fromisoformat(entry["zeit"]).replace(tzinfo=None)
                except (IndexError, ValueError, KeyError, TypeError):
                    continue
                day = local.date().isoformat()
                key = (day, category, number)
                if key in done:
                    continue
                done.add(key)
                status, body = await self._ask(sequence_path(category, number, eva, local))
                if status != 200:
                    continue
                for sighting in parse_sequence(body, category, number):
                    self.store.record(day, sighting, name, self.now())
                    found += 1
        self.store.prune(dt.datetime.fromtimestamp(started, BERLIN).date())
        log.info("Tz scan: %d trains, %d trainsets", len(done), found)

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
            nxt = last if last is not None and last > at else at + dt.timedelta(hours=1)
            at = nxt
        return [e for e in entries if _before(e, end)]


def _before(entry, end):
    try:
        return dt.datetime.fromisoformat(entry["zeit"]).replace(tzinfo=None) < end
    except (KeyError, ValueError, TypeError):
        return False
