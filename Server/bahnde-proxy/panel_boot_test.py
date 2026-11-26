"""Tests for panel_boot.py: `python3 -m unittest Server/bahnde-proxy/panel_boot_test.py` (no network)."""

import io
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import panel_boot  # noqa: E402

BASE = "https://raw.githubusercontent.com/AppleGoldKunibert/betterbahnapp/{}/Server/bahnde-proxy/"


def github(branch, files):
    """A fetch answering `files` ({name: bytes}) of `branch` and 404 to everything else."""
    def fetch(url):
        name = url.removeprefix(BASE.format(branch))
        if name in files:
            return files[name]
        raise urllib.error.HTTPError(url, 404, "Not Found", {}, io.BytesIO())
    return fetch


class UpdateTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.here = Path(folder.name)
        for patch in (mock.patch.object(panel_boot, "HERE", self.here),
                      mock.patch.dict("os.environ", {"BRANCH": "feature"}),
                      mock.patch("sys.stdout", io.StringIO())):
            patch.start()
            self.addCleanup(patch.stop)

    def files(self):
        return {path.name: path.read_bytes() for path in self.here.iterdir()}

    def test_a_branch_without_the_tz_files_still_gets_its_own_code(self):
        (self.here / "proxy.py").write_bytes(b"old")
        (self.here / "tzlog.py").write_bytes(b"old tz")
        branch = {"proxy.py": b"new", "panel_start.py": b"start", "requirements.txt": b"aiohttp"}
        panel_boot.update(github("feature", branch))
        self.assertEqual(self.files(), {**branch, "tzlog.py": b"old tz"})

    def test_the_tz_files_come_along_when_the_branch_has_them(self):
        branch = {name: name.encode() for name in panel_boot.FILES + panel_boot.OPTIONAL_FILES}
        panel_boot.update(github("feature", branch))
        self.assertEqual(self.files(), branch)

    def test_a_needed_file_missing_on_the_branch_keeps_the_last_version_and_says_so(self):
        last = {name: b"last" for name in panel_boot.FILES}
        for name, content in last.items():
            (self.here / name).write_bytes(content)
        panel_boot.update(github("feature", {"proxy.py": b"new", "requirements.txt": b"aiohttp"}))
        self.assertEqual(self.files(), last)
        self.assertIn("panel_start.py isn't on AppleGoldKunibert/betterbahnapp@feature", sys.stdout.getvalue())

    def test_github_unreachable_keeps_the_last_version(self):
        last = {name: b"last" for name in panel_boot.FILES}
        for name, content in last.items():
            (self.here / name).write_bytes(content)

        def unreachable(url):
            raise urllib.error.URLError("timed out")
        panel_boot.update(unreachable)
        self.assertEqual(self.files(), last)
        self.assertIn("timed out", sys.stdout.getvalue())

    def test_nothing_downloaded_yet_and_a_needed_file_missing_stops(self):
        with self.assertRaises(SystemExit):
            panel_boot.update(github("feature", {}))
        self.assertEqual(self.files(), {})


if __name__ == "__main__":
    unittest.main()
