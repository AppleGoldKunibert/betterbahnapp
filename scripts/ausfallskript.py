#!/usr/bin/env python3
"""ausfallskript: cancelled long-distance trains of one day, with their whole run in a text file each.

    scripts/ausfallskript 21.10 3            # three cancellations of 21 October (this year, else last year)
    scripts/ausfallskript 21.10 3 -fullonly  # only trains cancelled altogether (no partial cancellations)

Prints, for each train:

    ICE 784
    Totalausfall (Hamburg Hbf -> München Hbf)
    Vollständiger Zuglauf mit Planzeiten in ICE7842110.txt

(`Teilausfall (A -> B)` with "Plan und Echtzeiten" for a train that lost some of its stops). The files are named
category + number + day + month and go into `--out` (the current folder). The data is DB Timetables as
piebro/deutsche-bahn-data keeps it (the same source as the train statistics): German stops only, long-distance
categories (`importer.LONG_DISTANCE`), and a day is a download of ~400 MB (kept in `--raw`, so asking again is quick).
Total cancellations come first, then partial ones, each by category and number. Needs `pip install pyarrow`.
"""

import argparse
import re
import sys
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Cloudflare" / "stats"))
import importer  # noqa: E402

CATEGORY_ORDER = ["ICE", "IC", "EC", "ECE"]
STATION = re.compile(r'<timetable[^>]*\sstation="([^"]*)"')


class NamedDay(importer.Day):
    """The importer's day, which also remembers the stations' names (eva → "Fulda") from the responses it reads; the
    importer itself has no use for them. A lower level of a big station only names the main station until that has
    its own name."""

    def __init__(self):
        super().__init__()
        self.names = {}

    def read(self, api, url, xml, snapshot):
        super().read(api, url, xml, snapshot)
        match = STATION.search(xml[:400]) if xml else None
        if match and api in ("timetables/v1/plan", "timetables/v1/fchg"):
            raw = url.rstrip("/").split("/")[-3 if api == "timetables/v1/plan" else -1]
            eva = importer.main_station(raw)
            if eva not in self.names or raw.lstrip("0") == eva:
                self.names[eva] = match.group(1)


def load_named_day(day, directory):
    """`importer.load_day` for a `NamedDay`: the day's folder and the next one."""
    data = NamedDay()
    for folder in (day, day + timedelta(days=1)):
        for path in importer.raw_files(folder):
            data.read_parquet(importer.download(path, directory))
    return data


@dataclass
class Stop:
    eva: str
    name: str
    arrival: dict | None
    departure: dict | None

    @property
    def events(self):
        return [event for event in (self.arrival, self.departure) if event is not None]

    @property
    def cancelled(self):
        return all(event.get("cs") == "c" for event in self.events)

    @property
    def additional(self):
        return any(event.get("ps") == "a" for event in self.events)


@dataclass
class Cancellation:
    category: str
    number: str
    stops: list = field(default_factory=list)

    @property
    def name(self):
        return f"{self.category} {self.number}"

    @property
    def total(self):
        return all(stop.cancelled for stop in self.stops)

    @property
    def cancelled_segments(self):
        """The runs of neighbouring cancelled stops, each as a list."""
        segments, current = [], []
        for stop in self.stops:
            if stop.cancelled:
                current.append(stop)
            elif current:
                segments.append(current)
                current = []
        if current:
            segments.append(current)
        return segments

    @property
    def description(self):
        if self.total:
            return f"Totalausfall ({self.stops[0].name} -> {self.stops[-1].name})"
        parts = [segment[0].name if len(segment) == 1 else f"{segment[0].name} -> {segment[-1].name}"
                 for segment in self.cancelled_segments]
        return f"Teilausfall ({', '.join(parts)})"

    def filename(self, day):
        return f"{self.category}{self.number}{day.day:02d}{day.month:02d}.txt"


def parse_day(text, today):
    """"21.10" (this year, or last year when that day isn't past yet), "21.10.2026", "21.10.26" or "2026-10-21"."""
    text = text.strip().rstrip(".")
    if "-" in text:
        return date.fromisoformat(text)
    parts = [int(part) for part in text.split(".")]
    if len(parts) == 2:
        candidate = date(today.year, parts[1], parts[0])
        return candidate if candidate < today else date(today.year - 1, parts[1], parts[0])
    year = parts[2] + 2000 if parts[2] < 100 else parts[2]
    return date(year, parts[1], parts[0])


def find_cancellations(data, day, categories=None):
    """Every long-distance run of `day` with a cancelled stop, total ones first, then by category and number."""
    categories = categories or importer.LONG_DISTANCE
    found = []
    for run in importer.collect_runs(data, day.isoformat()).values():
        label = run["label"]
        category, number = (label.get("c") or "").strip(), (label.get("n") or "").strip()
        if (not category or not number or category.upper() not in categories or label.get("f") == "S"
                or not any(importer.realtime(arrival) or importer.realtime(departure) for _, _, arrival, departure in run["stops"])):
            continue
        stops = [Stop(eva, data.names.get(eva, eva), arrival, departure)
                 for _, eva, arrival, departure in sorted(run["stops"], key=lambda stop: stop[0])]
        cancellation = Cancellation(category, number, stops)
        if any(stop.cancelled for stop in stops):
            found.append(cancellation)

    def order(cancellation):
        rank = CATEGORY_ORDER.index(cancellation.category.upper()) if cancellation.category.upper() in CATEGORY_ORDER else len(CATEGORY_ORDER)
        number = int(cancellation.number) if cancellation.number.isdigit() else 10**9
        return (not cancellation.total, rank, cancellation.category, number)

    return sorted(found, key=order)


# MARK: - The text file


def clock(text, day):
    """"HH:MM" of a yymmddHHMM time, with "+1" for the next day; "-" without one."""
    if not text:
        return "-"
    moment = importer.parse_time(text)
    return moment.strftime("%H:%M") + (f"+{(moment.date() - day).days}" if moment.date() > day else "")


def table(header, rows):
    widths = [max(len(str(row[column])) for row in [header] + rows) for column in range(len(header))]
    lines = ["  ".join(str(cell).ljust(width) for cell, width in zip(row, widths)).rstrip() for row in [header] + rows]
    lines.insert(1, "  ".join("-" * width for width in widths))
    return lines


def run_file(cancellation, day):
    """The whole run: with plan times for a total cancellation, with plan and real times for a partial one."""
    total = cancellation.total
    title = f"{cancellation.name} am {day.strftime('%d.%m.%Y')}"
    lines = [title, cancellation.description,
             "Planzeiten, vollständiger Zuglauf (nur Halte in Deutschland)" if total
             else "Plan und Echtzeiten, vollständiger Zuglauf (nur Halte in Deutschland)", ""]
    rows = []
    for stop in cancellation.stops:
        arrival, departure = stop.arrival or {}, stop.departure or {}
        platform = departure.get("pp") or arrival.get("pp") or "-"
        if total:
            rows.append([stop.name, clock(arrival.get("pt"), day), clock(departure.get("pt"), day), platform])
            continue
        changed = departure.get("cp") or arrival.get("cp")
        notes = []
        if stop.cancelled:
            notes.append("Halt entfällt")
        elif stop.additional:
            notes.append("Zusatzhalt")
        for label, event in (("an", arrival), ("ab", departure)):
            late = importer.delay(event)
            if late:
                notes.append(f"{label} {late:+d} min")

        def pair(event):
            planned = clock(event.get("pt"), day)
            if event.get("cs") == "c":
                return f"{planned} / entfällt"
            actual = clock(event.get("ct"), day) if event.get("ct") else "-"
            return f"{planned} / {actual}"

        rows.append([stop.name, pair(arrival) if stop.arrival else "-", pair(departure) if stop.departure else "-",
                     f"{platform} / {changed}" if changed and changed != platform else platform, ", ".join(notes)])
    header = ["Halt", "Ankunft", "Abfahrt", "Gleis"] if total else ["Halt", "Ankunft (Plan / Ist)", "Abfahrt (Plan / Ist)", "Gleis (Plan / Ist)", "Hinweis"]
    return "\n".join(lines + table(header, rows)) + "\n"


# MARK: - Command line


def main(argv=None):
    parser = argparse.ArgumentParser(prog="ausfallskript", description=__doc__.split("\n\n")[0])
    parser.add_argument("day", help='the day, "21.10" (this year, else last year), "21.10.2026" or "2026-10-21"')
    parser.add_argument("count", type=int, nargs="?", default=3, help="how many cancelled trains (default 3)")
    parser.add_argument("-fullonly", "--fullonly", dest="fullonly", action="store_true", help="only trains cancelled altogether")
    parser.add_argument("--out", type=Path, default=Path("."), help="where the text files go (default: here)")
    parser.add_argument("--raw", type=Path, default=Path("raw"), help="where the downloaded dataset is kept")
    args = parser.parse_args(argv)

    today = datetime.now(ZoneInfo("Europe/Berlin")).date()
    day = parse_day(args.day, today)
    if day >= today:
        sys.exit(f"{day.strftime('%d.%m.%Y')} isn't over yet; the dataset has the day after the next morning.")
    data = load_named_day(day, args.raw)
    if not importer.complete(data, day.isoformat()):
        sys.exit(f"{day.strftime('%d.%m.%Y')}: the dataset doesn't have the next morning's changes yet; try again later.")

    found = find_cancellations(data, day)
    chosen = [cancellation for cancellation in found if cancellation.total or not args.fullonly][:max(args.count, 0)]
    totals = sum(1 for cancellation in found if cancellation.total)
    print(f"{day.strftime('%d.%m.%Y')}: {len(found)} long-distance trains with cancellations, {totals} of them altogether", file=sys.stderr)
    args.out.mkdir(parents=True, exist_ok=True)
    for index, cancellation in enumerate(chosen):
        name = cancellation.filename(day)
        (args.out / name).write_text(run_file(cancellation, day), encoding="utf-8")
        if index:
            print()
        print(cancellation.name)
        print(cancellation.description)
        print(f"Vollständiger Zuglauf mit {'Planzeiten' if cancellation.total else 'Plan und Echtzeiten'} in {name}")
    if not chosen:
        print("Keine passenden Ausfälle an diesem Tag.")


if __name__ == "__main__":
    main()
