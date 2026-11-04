"""Tests for ausfallskript.py: `python3 -m unittest scripts/ausfallskript_test.py` (no network, no pyarrow)."""

import sys
import unittest
from datetime import date, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Cloudflare" / "stats"))
import ausfallskript  # noqa: E402
import importer  # noqa: E402

BASE = "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1/"
DAY = date(2026, 10, 21)


def plan(eva, name, stops):
    """stops: (stop id, category, number, arrival, departure) with pt/pp attribute strings."""
    body = "".join(
        f'<s id="{sid}"><tl f="F" t="p" o="80" c="{category}" n="{number}"/>'
        + (f'<ar pt="{arrival[0]}" pp="{arrival[1]}"/>' if arrival else "")
        + (f'<dp pt="{departure[0]}" pp="{departure[1]}"/>' if departure else "") + "</s>"
        for sid, category, number, arrival, departure in stops)
    return f'<timetable station="{name}">{body}</timetable>'


def sample_day():
    data = ausfallskript.NamedDay()
    # ICE 784 Hamburg -> Hannover -> München: cancelled altogether. ICE 123 Hamburg -> Hannover -> Kassel -> München:
    # Hannover and Kassel cancelled, 12 minutes late at München. IC 2000: all fine. RE 9: regional, ignored.
    data.read("timetables/v1/plan", BASE + "plan/08002549/261021/06", plan("8002549", "Hamburg Hbf", [
        ("1-2610210600-1", "ICE", "784", None, ("2610210602", "14")),
        ("2-2610210700-1", "ICE", "123", None, ("2610210702", "12")),
        ("3-2610210800-1", "IC", "2000", None, ("2610210802", "3")),
        ("4-2610210600-1", "RE", "9", None, ("2610210610", "1")),
    ]), 1)
    data.read("timetables/v1/plan", BASE + "plan/08000152/261021/07", plan("8000152", "Hannover Hbf", [
        ("1-2610210600-2", "ICE", "784", ("2610210730", "5"), ("2610210732", "5")),
        ("2-2610210700-2", "ICE", "123", ("2610210830", "6"), ("2610210832", "6")),
        ("3-2610210800-2", "IC", "2000", ("2610210930", "7"), ("2610210932", "7")),
    ]), 1)
    data.read("timetables/v1/plan", BASE + "plan/08003200/261021/09", plan("8003200", "Kassel-Wilhelmshöhe", [
        ("2-2610210700-3", "ICE", "123", ("2610210930", "1"), ("2610210932", "1")),
    ]), 1)
    data.read("timetables/v1/plan", BASE + "plan/08000261/261021/11", plan("8000261", "München Hbf", [
        ("1-2610210600-3", "ICE", "784", ("2610211100", "20"), None),
        ("2-2610210700-4", "ICE", "123", ("2610211200", "21"), None),
        ("3-2610210800-3", "IC", "2000", ("2610211300", "22"), None),
    ]), 1)
    changes = {
        "08002549": '<timetable station="Hamburg Hbf"><s id="1-2610210600-1"><dp cs="c"/></s>'
                    '<s id="2-2610210700-1"><dp ct="2610210702"/></s><s id="3-2610210800-1"><dp ct="2610210802"/></s></timetable>',
        "08000152": '<timetable station="Hannover Hbf"><s id="1-2610210600-2"><ar cs="c"/><dp cs="c"/></s>'
                    '<s id="2-2610210700-2"><ar cs="c"/><dp cs="c"/></s><s id="3-2610210800-2"><ar ct="2610210930"/><dp ct="2610210932"/></s></timetable>',
        "08003200": '<timetable station="Kassel-Wilhelmshöhe"><s id="2-2610210700-3"><ar cs="c"/><dp cs="c"/></s></timetable>',
        "08000261": '<timetable station="München Hbf"><s id="1-2610210600-3"><ar cs="c"/></s>'
                    '<s id="2-2610210700-4"><ar ct="2610211212" cp="22"/></s><s id="3-2610210800-3"><ar ct="2610211300"/></s></timetable>',
    }
    for eva, xml in changes.items():
        data.read("timetables/v1/fchg", BASE + f"fchg/{eva}", xml, 2)
    return data


def next_day():
    """22 October: ICE 500, 501 and 502 cancelled altogether."""
    data = ausfallskript.NamedDay()
    data.read("timetables/v1/plan", BASE + "plan/08002549/261022/06", plan("8002549", "Hamburg Hbf", [
        (f"{number}-2610220600-1", "ICE", str(number), None, ("2610220602", "14")) for number in (500, 501, 502)
    ]), 1)
    changes = "".join(f'<s id="{number}-2610220600-1"><dp cs="c"/></s>' for number in (500, 501, 502))
    data.read("timetables/v1/fchg", BASE + "fchg/08002549", f'<timetable station="Hamburg Hbf">{changes}</timetable>', 2)
    return data


TWO_DAYS = "21.10.2026-22.10.2026"


class FindTests(unittest.TestCase):
    def test_a_lower_level_only_names_the_main_station_until_that_has_its_own(self):
        data = ausfallskript.NamedDay()
        data.read("timetables/v1/plan", BASE + "plan/08098105/261021/06", '<timetable station="Frankfurt(Main)Hbf (tief)"/>', 1)
        self.assertEqual(data.names["8000105"], "Frankfurt(Main)Hbf (tief)")
        data.read("timetables/v1/plan", BASE + "plan/08000105/261021/06", '<timetable station="Frankfurt(Main)Hbf"/>', 1)
        data.read("timetables/v1/plan", BASE + "plan/08098105/261021/07", '<timetable station="Frankfurt(Main)Hbf (tief)"/>', 1)
        self.assertEqual(data.names["8000105"], "Frankfurt(Main)Hbf")

    def test_finds_long_distance_cancellations_total_ones_first(self):
        found = ausfallskript.find_cancellations(sample_day(), DAY)
        self.assertEqual([(c.name, c.total) for c in found], [("ICE 784", True), ("ICE 123", False)])

    def test_describes_total_and_partial_cancellations(self):
        total, partial = ausfallskript.find_cancellations(sample_day(), DAY)
        self.assertEqual(total.description, "Totalausfall (Hamburg Hbf -> München Hbf)")
        self.assertEqual(partial.description, "Teilausfall (Hannover Hbf -> Kassel-Wilhelmshöhe)")
        self.assertEqual(total.filename(DAY), "ICE7842110.txt")
        self.assertEqual(partial.filename(DAY), "ICE1232110.txt")

    def test_a_single_cancelled_stop_names_just_that_stop(self):
        data = sample_day()
        data.read("timetables/v1/fchg", BASE + "fchg/08003200", '<timetable station="Kassel-Wilhelmshöhe"><s id="2-2610210700-3"><ar ct="2610210930"/><dp ct="2610210932"/></s></timetable>', 3)
        partial = [c for c in ausfallskript.find_cancellations(data, DAY) if c.number == "123"][0]
        self.assertEqual(partial.description, "Teilausfall (Hannover Hbf)")

    def test_parses_the_day(self):
        today = date(2026, 11, 4)
        self.assertEqual(ausfallskript.parse_day("21.10", today), date(2026, 10, 21))
        self.assertEqual(ausfallskript.parse_day("21.12", today), date(2025, 12, 21), "not past yet: last year")
        self.assertEqual(ausfallskript.parse_day("21.10.26", today), date(2026, 10, 21))
        self.assertEqual(ausfallskript.parse_day("21.10.2025", today), date(2025, 10, 21))
        self.assertEqual(ausfallskript.parse_day("2026-10-21", today), date(2026, 10, 21))

    def test_parses_a_range_of_days(self):
        today = date(2026, 11, 4)
        three = [date(2026, 10, 12), date(2026, 10, 13), date(2026, 10, 14)]
        for text in ("12.10-14.10", "12.10.-14.10.", "12.10.2026-14.10.2026", "12.10.26-14.10.26", "2026-10-12-2026-10-14", "12.10 - 14.10", "12.10–14.10"):
            self.assertEqual(ausfallskript.parse_days(text, today), three, text)

    def test_a_single_day_is_a_list_of_one(self):
        today = date(2026, 11, 4)
        self.assertEqual(ausfallskript.parse_days("21.10", today), [date(2026, 10, 21)])
        self.assertEqual(ausfallskript.parse_days("2026-10-21", today), [date(2026, 10, 21)], "not a range")

    def test_a_year_on_one_end_of_a_range_counts_for_both(self):
        today = date(2026, 11, 4)
        days = [date(2025, 10, 12), date(2025, 10, 13)]
        self.assertEqual(ausfallskript.parse_days("12.10-13.10.2025", today), days)
        self.assertEqual(ausfallskript.parse_days("12.10.2025-13.10", today), days)

    def test_a_range_can_run_over_new_year_and_past_today(self):
        today = date(2026, 11, 4)
        over_new_year = ausfallskript.parse_days("31.12-01.01", today)
        self.assertEqual(over_new_year, [date(2025, 12, 31), date(2026, 1, 1)])
        reaching_today = ausfallskript.parse_days("03.11-05.11", today)
        self.assertEqual(reaching_today, [date(2026, 11, 3), date(2026, 11, 4), date(2026, 11, 5)])

    def test_a_range_ending_before_it_starts_is_refused(self):
        today = date(2026, 11, 4)
        for text in ("14.10-12.10", "14.10.2026-12.10.2026"):
            with self.assertRaises(ValueError, msg=text):
                ausfallskript.parse_days(text, today)


class FileTests(unittest.TestCase):
    def test_a_total_cancellation_lists_the_plan_times_only(self):
        text = ausfallskript.run_file(ausfallskript.find_cancellations(sample_day(), DAY)[0], DAY)
        self.assertIn("ICE 784 am 21.10.2026", text)
        self.assertIn("Totalausfall (Hamburg Hbf -> München Hbf)", text)
        self.assertIn("Hannover Hbf", text)
        self.assertRegex(text, r"Hannover Hbf\s+07:30\s+07:32\s+5")
        self.assertNotIn("entfällt", text.split("Planzeiten", 1)[1].split("\n", 1)[1])

    def test_a_partial_cancellation_shows_plan_and_real_times(self):
        text = ausfallskript.run_file(ausfallskript.find_cancellations(sample_day(), DAY)[1], DAY)
        self.assertIn("Plan und Echtzeiten", text)
        self.assertRegex(text, r"Hannover Hbf\s+08:30 / entfällt\s+08:32 / entfällt\s+6\s+Halt entfällt")
        self.assertRegex(text, r"München Hbf\s+12:00 / 12:12\s+-\s+21 / 22\s+an \+12 min")


class CommandLineTests(unittest.TestCase):
    def run_main(self, arguments, data, today=None, incomplete=()):
        """`data`: one day's data, or a dict by day. `today` a datetime (default the real one), `incomplete` the ISO
        days the dataset lacks the next morning of. Leaves the days asked for in `self.loaded`, stderr in `self.notes`."""
        import io
        import tempfile
        from contextlib import redirect_stderr, redirect_stdout
        from unittest import mock

        self.loaded = []

        def load(day, raw):
            self.loaded.append(day)
            return data[day] if isinstance(data, dict) else data

        out, err = io.StringIO(), io.StringIO()
        clock = mock.Mock(now=mock.Mock(return_value=today)) if today else datetime
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(ausfallskript, "load_named_day", side_effect=load), \
                mock.patch.object(ausfallskript, "datetime", clock), \
                mock.patch.object(importer, "complete", side_effect=lambda _, day: day not in incomplete), \
                redirect_stdout(out), redirect_stderr(err):
            try:
                ausfallskript.main(arguments + ["--out", folder])
            finally:
                self.notes = err.getvalue()
            names = sorted(path.name for path in Path(folder).iterdir())
        return out.getvalue(), names

    def two_days(self):
        return {date(2026, 10, 21): sample_day(), date(2026, 10, 22): next_day()}

    def test_prints_the_asked_number_and_writes_a_file_each(self):
        output, names = self.run_main(["21.10.2026", "2"], sample_day())
        self.assertEqual(output, "ICE 784\nTotalausfall (Hamburg Hbf -> München Hbf)\nVollständiger Zuglauf mit Planzeiten in ICE7842110.txt\n\n"
                                 "ICE 123\nTeilausfall (Hannover Hbf -> Kassel-Wilhelmshöhe)\nVollständiger Zuglauf mit Plan und Echtzeiten in ICE1232110.txt\n")
        self.assertEqual(names, ["ICE1232110.txt", "ICE7842110.txt"])

    def test_fullonly_leaves_out_partial_cancellations(self):
        output, names = self.run_main(["21.10.2026", "5", "-fullonly"], sample_day())
        self.assertIn("ICE 784", output)
        self.assertNotIn("ICE 123", output)
        self.assertEqual(names, ["ICE7842110.txt"])

    def test_one_is_enough_when_asked_for_one(self):
        output, names = self.run_main(["21.10.2026", "1"], sample_day())
        self.assertEqual(names, ["ICE7842110.txt"])

    def test_without_a_count_a_day_gives_three(self):
        output, names = self.run_main(["22.10.2026"], next_day())
        self.assertEqual(names, ["ICE5002210.txt", "ICE5012210.txt", "ICE5022210.txt"])
        output, names = self.run_main(["22.10.2026", "-perday", "1"], next_day())
        self.assertEqual(names, ["ICE5002210.txt"])

    def test_perday_takes_that_many_of_each_day_of_a_range(self):
        output, names = self.run_main([TWO_DAYS, "-perday", "2"], self.two_days())
        self.assertEqual(names, ["ICE1232110.txt", "ICE5002210.txt", "ICE5012210.txt", "ICE7842110.txt"])
        self.assertEqual(self.loaded, [date(2026, 10, 21), date(2026, 10, 22)])
        self.assertEqual(output, "21.10.2026\nICE 784\nTotalausfall (Hamburg Hbf -> München Hbf)\nVollständiger Zuglauf mit Planzeiten in ICE7842110.txt\n\n"
                                 "ICE 123\nTeilausfall (Hannover Hbf -> Kassel-Wilhelmshöhe)\nVollständiger Zuglauf mit Plan und Echtzeiten in ICE1232110.txt\n\n"
                                 "22.10.2026\nICE 500\nTotalausfall (Hamburg Hbf -> Hamburg Hbf)\nVollständiger Zuglauf mit Planzeiten in ICE5002210.txt\n\n"
                                 "ICE 501\nTotalausfall (Hamburg Hbf -> Hamburg Hbf)\nVollständiger Zuglauf mit Planzeiten in ICE5012210.txt\n")

    def test_perday_without_a_count_has_no_limit_in_all(self):
        output, names = self.run_main([TWO_DAYS, "-perday", "9"], self.two_days())
        self.assertEqual(len(names), 5, "more than the default of three")

    def test_a_count_on_a_range_counts_the_whole_range_total_cancellations_first(self):
        output, names = self.run_main([TWO_DAYS, "4"], self.two_days())
        self.assertEqual(names, ["ICE5002210.txt", "ICE5012210.txt", "ICE5022210.txt", "ICE7842110.txt"])
        self.assertLess(output.index("ICE 784"), output.index("ICE 500"), "printed in day order")

    def test_count_and_perday_both_apply_in_any_order(self):
        output, names = self.run_main([TWO_DAYS, "2", "-perday", "1"], self.two_days())
        self.assertEqual(names, ["ICE5002210.txt", "ICE7842110.txt"])
        output, names = self.run_main([TWO_DAYS, "-perday", "1", "1"], self.two_days())
        self.assertEqual(names, ["ICE5002210.txt"])

    def test_fullonly_applies_before_perday(self):
        output, names = self.run_main([TWO_DAYS, "-perday", "2", "-fullonly"], self.two_days())
        self.assertEqual(names, ["ICE5002210.txt", "ICE5012210.txt", "ICE7842110.txt"])

    def test_a_range_leaves_out_days_that_are_not_over_with_a_note(self):
        output, names = self.run_main(["21.10.2026-24.10.2026", "-perday", "1"], self.two_days(), today=datetime(2026, 10, 23, 12))
        self.assertEqual(names, ["ICE5002210.txt", "ICE7842110.txt"])
        self.assertEqual(self.loaded, [date(2026, 10, 21), date(2026, 10, 22)], "nothing downloaded for days not over")
        self.assertIn("23.10.2026 isn't over yet", self.notes)
        self.assertIn("24.10.2026 isn't over yet", self.notes)

    def test_a_range_leaves_out_days_the_dataset_lacks_with_a_note(self):
        output, names = self.run_main([TWO_DAYS, "-perday", "1"], self.two_days(), incomplete=("2026-10-22",))
        self.assertEqual(names, ["ICE7842110.txt"])
        self.assertIn("22.10.2026: the dataset doesn't have the next morning's changes yet", self.notes)

    def test_stops_when_no_day_is_available(self):
        with self.assertRaises(SystemExit) as stopped:
            self.run_main(["21.10.2026"], sample_day(), today=datetime(2026, 10, 21, 12))
        self.assertIn("21.10.2026 isn't over yet", stopped.exception.code)
        with self.assertRaises(SystemExit) as stopped:
            self.run_main([TWO_DAYS], self.two_days(), incomplete=("2026-10-21", "2026-10-22"))
        self.assertIn("21.10.2026: the dataset", stopped.exception.code)
        self.assertIn("22.10.2026: the dataset", stopped.exception.code)

    def test_a_backward_range_is_a_usage_error(self):
        with self.assertRaises(SystemExit) as stopped:
            self.run_main(["14.10.2026-12.10.2026"], sample_day())
        self.assertEqual(stopped.exception.code, 2)
        self.assertIn("before it starts", self.notes)
        self.assertEqual(self.loaded, [], "nothing downloaded")

    def test_says_when_a_range_has_nothing_fitting(self):
        data = ausfallskript.NamedDay()
        output, names = self.run_main([TWO_DAYS, "-perday", "1"], {date(2026, 10, 21): data, date(2026, 10, 22): data})
        self.assertEqual(output, "Keine passenden Ausfälle in diesem Zeitraum.\n")
        self.assertEqual(names, [])


if __name__ == "__main__":
    unittest.main()
