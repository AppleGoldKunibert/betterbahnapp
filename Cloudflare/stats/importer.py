"""Daily import of the train statistics (#336) from piebro/deutsche-bahn-data into D1 (`betterbahn-stats`).

The dataset (https://huggingface.co/datasets/piebro/deutsche-bahn-data, CC BY 4.0, source Deutsche Bahn)
keeps DB Timetables (IRIS) responses of every German station: the hourly plans and, four times a day, every
change known (reaching back more than six hours). This script turns one day of it into one row per train
number (`train_days`, see schema.sql): per run of that number its stops with delays, cancellations and platforms.

    python3 importer.py --imported imported.json --sql out.sql

reads which days D1 has (`SELECT day, rows FROM train_import` as `wrangler d1 execute --json` prints it),
imports yesterday and then older missing days of the last `STATS_DAYS`, as long as the rows written stay within
`--budget` (D1's free plan writes 100,000 rows a day), and writes the SQL for `wrangler d1 execute --file`.
Needs pyarrow; everything else is the standard library.
"""

import argparse
import json
import re
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

DATASET = "https://huggingface.co/api/datasets/piebro/deutsche-bahn-data"
RESOLVE = "https://huggingface.co/datasets/piebro/deutsche-bahn-data/resolve/main/"
STATS_DAYS = 30
# D1 takes at most 100 KB per SQL statement; one INSERT carries this much.
MAX_STATEMENT = 90_000
# Not kept: S-Bahn and buses (as in the app, which asks only for regional and long-distance trains).
EXCLUDED_CATEGORIES = {"S", "BUS", "SEV", "STR", "U"}
# Big stations whose lower levels DB Timetables lists as stations of their own (as `TimetablesClient.lowerLevels`
# in the app): their stops are kept under the main station, which is what the app asks for. Same list in worker.mjs.
LOWER_LEVELS = {
    "8098263": "8000261",  # München Hbf (tief)
    "8098096": "8000096",  # Stuttgart Hbf (tief)
    "8098105": "8000105",  # Frankfurt (Main) Hbf (tief)
    "8098549": "8002549",  # Hamburg Hbf (S-Bahn)
    "8098205": "8010205",  # Leipzig Hbf (tief)
    "8098160": "8011160",  # Berlin Hbf (tief)
    "8089021": "8011160",  # Berlin Hbf (S-Bahn)
}
STOP_ID = re.compile(r"^(.*)-(\d{10})-(\d+)$")


# MARK: - Reading the raw responses


class Day:
    """The plan and the latest known change of every stop, from the responses read so far."""

    def __init__(self):
        # stop ID → (eva, train label, arrival, departure); arrival/departure: the XML attributes or None.
        self.plan = {}
        # (stop ID, "ar"/"dp") → (snapshot, attributes): the latest change of that event.
        self.changes = {}
        # stop ID → (eva, train label) for stops only the changes know (additional stops, replacement trains).
        self.change_stops = {}
        # The latest snapshot of changes read (Berlin local time, as the dataset keeps it).
        self.latest_changes = None

    def read(self, api, url, xml, snapshot):
        if not xml or "<s " not in xml:
            return
        root = ET.fromstring(xml)
        if api == "timetables/v1/plan":
            # .../plan/<eva>/<yymmdd>/<hh>
            eva = main_station(url.rstrip("/").split("/")[-3])
            for stop in root.findall("s"):
                self.plan[stop.get("id")] = (eva, attributes(stop.find("tl")), attributes(stop.find("ar")), attributes(stop.find("dp")))
        elif api == "timetables/v1/fchg":
            eva = main_station(url.rstrip("/").split("/")[-1])
            if self.latest_changes is None or self.latest_changes < snapshot:
                self.latest_changes = snapshot
            for stop in root.findall("s"):
                sid = stop.get("id")
                label = attributes(stop.find("tl"))
                if label:
                    self.change_stops[sid] = (eva, label)
                elif sid not in self.change_stops:
                    self.change_stops[sid] = (eva, {})
                for kind in ("ar", "dp"):
                    event = attributes(stop.find(kind))
                    if not event:
                        continue
                    previous = self.changes.get((sid, kind))
                    if previous is None or previous[0] <= snapshot:
                        self.changes[(sid, kind)] = (snapshot, event)

    def read_parquet(self, path):
        import pyarrow.parquet as pq

        columns = ["timestamp", "url", "api_name", "response_data", "status_code"]
        for batch in pq.ParquetFile(path).iter_batches(columns=columns, batch_size=2000):
            rows = batch.to_pydict()
            for snapshot, url, api, xml, status in zip(*(rows[name] for name in columns)):
                if status == "200" and api in ("timetables/v1/plan", "timetables/v1/fchg"):
                    self.read(api, url, xml, snapshot)


def main_station(eva):
    eva = eva.lstrip("0")
    return LOWER_LEVELS.get(eva, eva)


def attributes(element):
    return dict(element.attrib) if element is not None and element.attrib else None


# MARK: - Runs


def build_rows(data, day):
    """Train number → the runs of that number that started on `day` ("2026-10-14"), as stored in
    `train_days.runs`: [{"c": category, "x": 1 when cancelled altogether, "s": stops}], each stop
    [eva, arrival delay, departure delay, platform, changed platform, flags] (see schema.sql)."""
    stamp = day[2:4] + day[5:7] + day[8:10]
    runs = {}
    for sid in set(data.plan) | set(data.change_stops):
        match = STOP_ID.match(sid or "")
        if not match or not match.group(2).startswith(stamp):
            continue
        planned = data.plan.get(sid)
        eva, label = (planned[0], planned[1]) if planned else data.change_stops[sid]
        arrival = merge(planned[2] if planned else None, data.changes.get((sid, "ar")))
        departure = merge(planned[3] if planned else None, data.changes.get((sid, "dp")))
        if arrival is None and departure is None:
            continue
        run = runs.setdefault((match.group(1), match.group(2)), {"label": {}, "stops": []})
        if label and (planned or not run["label"]):
            run["label"] = label
        run["stops"].append((int(match.group(3)), eva, arrival, departure))

    rows = {}
    for run in runs.values():
        label = run["label"]
        category, number = (label.get("c") or "").strip(), (label.get("n") or "").strip()
        if not category or not number or category.upper() in EXCLUDED_CATEGORIES or label.get("f") == "S":
            continue
        stops = [stop_row(eva, arrival, departure) for _, eva, arrival, departure in sorted(run["stops"], key=lambda s: s[0])]
        # Only runs with realtime data count; without any, DB had no live information on the train.
        if not any(realtime(arrival) or realtime(departure) for _, _, arrival, departure in run["stops"]):
            continue
        cancelled = all(row[5] & 1 for row in stops)
        rows.setdefault(number, []).append({"c": category, "x": 1 if cancelled else 0, "s": stops})
    for number_runs in rows.values():
        number_runs.sort(key=lambda run: (run["c"], run["s"][0][0]))
    return rows


def merge(planned, change):
    """One event: its plan with the latest change on top (additional stops have their plan in the change)."""
    if planned is None and change is None:
        return None
    event = dict(planned or {})
    if change is not None:
        for key, value in change[1].items():
            if key in ("ct", "cp", "cs", "clt") or key not in event:
                event[key] = value
    return event


def realtime(event):
    return event is not None and any(key in event for key in ("ct", "cs", "cp"))


def stop_row(eva, arrival, departure):
    events = [event for event in (arrival, departure) if event is not None]
    cancelled = all(event.get("cs") == "c" for event in events)
    additional = any(event.get("ps") == "a" for event in events)
    planned_platform = next((event["pp"] for event in (departure, arrival) if event and event.get("pp")), None)
    changed_platform = next((event["cp"] for event in (departure, arrival) if event and event.get("cp")), None)
    return [
        eva,
        None if cancelled else delay(arrival),
        None if cancelled else delay(departure),
        planned_platform,
        changed_platform if changed_platform and changed_platform != planned_platform else None,
        (1 if cancelled else 0) | (2 if additional else 0),
    ]


def delay(event):
    """Minutes late (negative when early); None without realtime or when the event was cancelled."""
    if not event or event.get("cs") == "c" or not event.get("ct") or not event.get("pt"):
        return None
    return round((parse_time(event["ct"]) - parse_time(event["pt"])).total_seconds() / 60)


def parse_time(text):
    return datetime.strptime(text, "%y%m%d%H%M")


# MARK: - SQL


def sql_for_day(day, rows):
    """Replaces `day` in D1: deletes what an earlier import left, inserts `rows`, notes the import."""
    statements = [f"DELETE FROM train_days WHERE day = {quote(day)};"]
    values = []
    size = 0
    for number in sorted(rows):
        value = f"({quote(number)},{quote(day)},{quote(json.dumps(rows[number], separators=(',', ':'), ensure_ascii=False))})"
        if values and size + len(value) > MAX_STATEMENT:
            statements.append(insert(values))
            values, size = [], 0
        values.append(value)
        size += len(value) + 1
    if values:
        statements.append(insert(values))
    statements.append(
        f"INSERT INTO train_import (day, rows) VALUES ({quote(day)}, {len(rows)}) "
        "ON CONFLICT (day) DO UPDATE SET rows = excluded.rows;"
    )
    return statements


def insert(values):
    return "INSERT INTO train_days (number, day, runs) VALUES " + ",".join(values) + ";"


def quote(text):
    return "'" + str(text).replace("'", "''") + "'"


# MARK: - Which days


def days_to_import(imported, today, days=STATS_DAYS):
    """Yesterday first, then the missing days of the last `days`, newest first. `imported`: day → rows."""
    wanted = [(today - timedelta(days=offset)).isoformat() for offset in range(1, days + 1)]
    return [day for day in wanted if day not in imported]


def expired(imported, today, days=STATS_DAYS):
    """Days older than the statistics reach, with their rows (what deleting them writes)."""
    oldest = (today - timedelta(days=days)).isoformat()
    return {day: rows for day, rows in imported.items() if day < oldest}


def complete(data, day):
    """Whether the changes reach into the next morning, so the evening's trains have their realtime data
    (each snapshot reaches back more than six hours)."""
    morning = datetime.fromisoformat(day) + timedelta(days=1, hours=6)
    return data.latest_changes is not None and data.latest_changes >= morning


def imported_days(answer):
    """Day → rows from `wrangler d1 execute --json` answering `SELECT day, rows FROM train_import`."""
    return {row["day"]: row["rows"] for result in json.loads(answer) for row in result.get("results", [])}


# MARK: - Download


def raw_files(day):
    """The raw files of one dataset folder (`raw_data/year=…/month=…/day=…`)."""
    folder = f"raw_data/year={day.year}/month={day.month}/day={day.day}"
    with urllib.request.urlopen(f"{DATASET}/tree/main/{urllib.parse.quote(folder)}") as response:
        return sorted(entry["path"] for entry in json.load(response) if entry.get("type") == "file" and entry["path"].endswith(".parquet"))


def download(path, directory):
    target = directory / path
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        print(f"Downloading {path}", file=sys.stderr)
        partial = target.with_suffix(".part")
        urllib.request.urlretrieve(RESOLVE + urllib.parse.quote(path), partial)
        partial.replace(target)
    return target


def load_day(day, directory):
    """The stops of runs that started on `day`: its folder and the next one (trains running past midnight, and
    the next morning's changes reaching back to the evening)."""
    data = Day()
    for folder in (day, day + timedelta(days=1)):
        for path in raw_files(folder):
            data.read_parquet(download(path, directory))
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--imported", type=Path, help="wrangler d1 execute --json output of SELECT day, rows FROM train_import")
    parser.add_argument("--sql", type=Path, required=True)
    parser.add_argument("--raw", type=Path, default=Path("raw"), help="where downloads are kept")
    parser.add_argument("--budget", type=int, default=90_000, help="rows written at most (deleted ones count too)")
    parser.add_argument("--day", action="append", help="import just this day (repeatable), e.g. 2026-10-14")
    args = parser.parse_args()

    imported = imported_days(args.imported.read_text()) if args.imported and args.imported.exists() else {}

    today = datetime.now(ZoneInfo("Europe/Berlin")).date()
    statements = []
    budget = args.budget
    old = expired(imported, today)
    if old:
        statements.append(f"DELETE FROM train_days WHERE day < {quote((today - timedelta(days=STATS_DAYS)).isoformat())};")
        statements.append(f"DELETE FROM train_import WHERE day < {quote((today - timedelta(days=STATS_DAYS)).isoformat())};")
        budget -= sum(old.values()) + len(old)

    for day in args.day or days_to_import(imported, today):
        data = load_day(date.fromisoformat(day), args.raw)
        if not complete(data, day):
            print(f"{day}: the next morning's changes aren't in the dataset yet; next time", file=sys.stderr)
            continue
        rows = build_rows(data, day)
        cost = len(rows) + imported.get(day, 0) + 1
        if not args.day and cost > budget:
            print(f"{day}: {len(rows)} trains, over the budget; next time", file=sys.stderr)
            break
        print(f"{day}: {len(rows)} trains, {sum(len(r) for r in rows.values())} runs", file=sys.stderr)
        statements += sql_for_day(day, rows)
        budget -= cost
        # Only the next day's folder is reused: older downloads go to keep the disk small.
        for folder in args.raw.glob("raw_data/year=*/month=*/day=*"):
            parts = dict(part.split("=") for part in folder.relative_to(args.raw).parts if "=" in part)
            if date(int(parts["year"]), int(parts["month"]), int(parts["day"])) > date.fromisoformat(day):
                for file in folder.glob("*.parquet"):
                    file.unlink()

    args.sql.write_text("\n".join(statements) + "\n")
    print(f"{len(statements)} statements in {args.sql}", file=sys.stderr)


if __name__ == "__main__":
    main()
