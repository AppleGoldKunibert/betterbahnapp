-- Train statistics (#316, #336), imported once a day by importer.py from piebro/deutsche-bahn-data.
-- One row per train number and day, so a day costs about 28,000 written rows (D1 free plan: 100,000 a day)
-- and the Worker finds a train's last 30 days by its primary key. No other index: each would cost a write per row.
CREATE TABLE IF NOT EXISTS train_days (
    -- Run number (Zugnummer) as DB Timetables gives it, "1095"; regional trains too ("3185" for an RE 5).
    number TEXT NOT NULL,
    -- Berlin day the run started, "2026-10-14".
    day TEXT NOT NULL,
    -- JSON, every run with this number that day (regional numbers repeat across operators):
    -- [{"c": category ("ICE", "RE", "HLB" …), "x": 1 when cancelled altogether else 0, "s": stops}]
    -- One array per stop, in order: [eva, arrivalDelay, departureDelay, platform, changedPlatform, flags]
    -- delays in minutes (negative when early), null without realtime or when cancelled; changedPlatform only
    -- when it differs from the planned platform; flags: 1 = stop cancelled, 2 = additional stop (Zusatzhalt).
    runs TEXT NOT NULL,
    PRIMARY KEY (number, day)
) WITHOUT ROWID;

-- Days imported so far and their rows (what deleting them later writes), so importer.py knows what's missing.
CREATE TABLE IF NOT EXISTS train_import (
    day TEXT PRIMARY KEY,
    rows INTEGER NOT NULL
);
