"""Tests for importer.py: `python3 -m unittest Cloudflare/stats/importer_test.py` (no pyarrow needed)."""

import json
import sys
import unittest
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import importer  # noqa: E402

PLAN_FULDA = """<timetable station="Fulda">
<s id="123-2610141756-2"><tl f="F" t="p" o="80" c="ICE" n="1095"/>
  <ar pt="2610141900" pp="7" ppth="München Hbf"/><dp pt="2610141902" pp="7" ppth="Frankfurt(Main)Hbf"/></s>
<s id="555-2610141800-4"><tl f="S" t="p" o="800" c="S" n="5540"/><dp pt="2610141900" pp="1"/></s>
<s id="777-2610130900-3"><tl f="N" t="p" o="800" c="RE" n="3185"/><dp pt="2610131000" pp="2"/></s>
</timetable>"""

PLAN_MUNICH = """<timetable station="München Hbf">
<s id="123-2610141756-1"><tl f="F" t="p" o="80" c="ICE" n="1095"/><dp pt="2610141756" pp="19"/></s>
</timetable>"""

PLAN_FRANKFURT = """<timetable station="Frankfurt(Main)Hbf">
<s id="123-2610141756-3"><tl f="F" t="p" o="80" c="ICE" n="1095"/><ar pt="2610142209" pp="8"/></s>
<s id="999-2610141700-5"><tl f="N" t="p" o="800" c="HLB" n="24010"/><ar pt="2610141800" pp="20"/></s>
</timetable>"""

# Early snapshot: 3 minutes late at Fulda. Later snapshot: 12 minutes, another platform; Frankfurt cancelled.
CHANGES_EARLY = """<timetable station="Fulda" eva="8000115">
<s id="123-2610141756-2" eva="8000115"><ar ct="2610141903"/><dp ct="2610141905"/></s>
</timetable>"""
CHANGES_LATE_FULDA = """<timetable station="Fulda" eva="8000115">
<s id="123-2610141756-2" eva="8000115"><m t="h" cat="BAUARBEITEN"/><ar ct="2610141912" cp="8"/><dp ct="2610141914" cp="8"/></s>
</timetable>"""
CHANGES_FRANKFURT = """<timetable station="Frankfurt(Main)Hbf" eva="8000105">
<s id="123-2610141756-3" eva="8000105"><ar cs="c" clt="2610141500"/></s>
<s id="123-2610141756-4" eva="8000105"><tl f="F" t="p" o="80" c="ICE" n="1095"/><ar pt="2610142230" pp="9" ps="a" ct="2610142240"/></s>
</timetable>"""

BASE = "https://apis.deutschebahn.com/db-api-marketplace/apis/timetables/v1/"


def sample_day():
    data = importer.Day()
    data.read("timetables/v1/plan", BASE + "plan/08000261/261014/17", PLAN_MUNICH, 1)
    data.read("timetables/v1/plan", BASE + "plan/08000115/261014/19", PLAN_FULDA, 1)
    data.read("timetables/v1/plan", BASE + "plan/08000105/261014/22", PLAN_FRANKFURT, 1)
    data.read("timetables/v1/fchg", BASE + "fchg/08000115", CHANGES_LATE_FULDA, 3)
    # Read after the later one, as files can come in any order: the later snapshot still wins.
    data.read("timetables/v1/fchg", BASE + "fchg/08000115", CHANGES_EARLY, 2)
    data.read("timetables/v1/fchg", BASE + "fchg/08000105", CHANGES_FRANKFURT, 3)
    data.read("timetables/v1/fchg", BASE + "fchg/08000002", "<timetable/>", 3)
    return data


class BuildRowsTests(unittest.TestCase):
    def test_one_run_with_delays_platforms_cancellations_and_additional_stops(self):
        rows = importer.build_rows(sample_day(), "2026-10-14")
        self.assertEqual(list(rows), ["1095"], "no S-Bahn, no run without realtime, no run of another day")
        self.assertEqual(rows["1095"], [{"c": "ICE", "x": 0, "s": [
            ["8000261", None, None, "19", None, 0],
            ["8000115", 12, 12, "7", "8", 0],
            ["8000105", None, None, "8", None, 1],
            ["8000105", 10, None, "9", None, 2],
        ]}])

    def test_lower_levels_count_as_the_main_station(self):
        data = importer.Day()
        data.read("timetables/v1/plan", BASE + "plan/08098160/261014/18",
                  '<timetable><s id="1-2610141800-1"><tl c="ICE" n="1"/><ar pt="2610141800" pp="2"/></s></timetable>', 1)
        data.read("timetables/v1/fchg", BASE + "fchg/08098160", '<timetable><s id="1-2610141800-1"><ar ct="2610141802"/></s></timetable>', 2)
        self.assertEqual(importer.build_rows(data, "2026-10-14")["1"][0]["s"][0][0], "8011160")

    def test_a_run_with_every_stop_cancelled_is_cancelled(self):
        data = importer.Day()
        data.read("timetables/v1/plan", BASE + "plan/08000105/261014/18", PLAN_FRANKFURT, 1)
        data.read("timetables/v1/fchg", BASE + "fchg/08000105",
                  '<timetable><s id="999-2610141700-5"><ar cs="c"/></s></timetable>', 2)
        self.assertEqual(importer.build_rows(data, "2026-10-14")["24010"], [{"c": "HLB", "x": 1, "s": [["8000105", None, None, "20", None, 1]]}])

    def test_sql_inserts_the_rows_and_notes_the_day(self):
        rows = {"1095": [{"c": "ICE", "x": 0, "s": [["8000115", 3, 3, "7", None, 0]]}], "it's": []}
        sql = importer.sql_for_day("2026-10-14", rows)
        self.assertEqual(sql[0], "DELETE FROM train_days WHERE day = '2026-10-14';")
        self.assertIn("('1095','2026-10-14','[{\"c\":\"ICE\",\"x\":0,\"s\":[[\"8000115\",3,3,\"7\",null,0]]}]')", sql[1])
        self.assertIn("'it''s'", sql[1])
        self.assertTrue(sql[-1].startswith("INSERT INTO train_import (day, rows) VALUES ('2026-10-14', 2)"))

    def test_big_days_are_split_into_statements_under_d1s_limit(self):
        rows = {str(n): [{"c": "RE", "x": 0, "s": [["8000115", 1, 1, "1", None, 0]] * 20}] for n in range(2000)}
        sql = importer.sql_for_day("2026-10-14", rows)
        self.assertGreater(len(sql), 3)
        self.assertTrue(all(len(statement) < 100_000 for statement in sql))
        self.assertEqual(sum(statement.count("'2026-10-14','") for statement in sql), 2000)

    def test_yesterday_first_then_missing_days_and_old_ones_expire(self):
        today = date(2026, 10, 15)
        imported = {"2026-10-13": 100, "2026-09-10": 50}
        days = importer.days_to_import(imported, today)
        self.assertEqual(days[:3], ["2026-10-14", "2026-10-12", "2026-10-11"])
        self.assertEqual(days[-1], "2026-09-15")
        self.assertEqual(importer.expired(imported, today), {"2026-09-10": 50})

    def test_a_day_counts_once_the_next_mornings_changes_are_in(self):
        from datetime import datetime
        data = importer.Day()
        self.assertFalse(importer.complete(data, "2026-10-14"))
        data.read("timetables/v1/fchg", BASE + "fchg/08000115", CHANGES_EARLY, datetime(2026, 10, 15, 0, 16))
        self.assertFalse(importer.complete(data, "2026-10-14"))
        data.read("timetables/v1/fchg", BASE + "fchg/08000115", CHANGES_EARLY, datetime(2026, 10, 15, 8, 40))
        self.assertTrue(importer.complete(data, "2026-10-14"))

    def test_reads_wranglers_json(self):
        answer = json.dumps([{"results": [{"day": "2026-10-13", "rows": 27000}], "success": True}])
        self.assertEqual(importer.imported_days(answer), {"2026-10-13": 27000})


if __name__ == "__main__":
    unittest.main()
