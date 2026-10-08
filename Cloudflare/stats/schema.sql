-- Train runs the app has seen, watched until their terminus (worker.mjs). One row per run, the stops
-- as JSON, so a train costs one written row instead of one per stop (D1 free plan: 100,000 a day).
-- Query stops with json_each, e.g. the average arrival delay per station:
--   SELECT s.value->>0 AS eva, avg(s.value->>2) FROM runs, json_each(runs.stops) s
--   WHERE state = 'done' GROUP BY eva;
CREATE TABLE IF NOT EXISTS runs (
    -- "<DA>|<category>|<number>|<first stop EVA>" from bahn.de's journey ID, or the ID itself.
    key TEXT PRIMARY KEY,
    journey_id TEXT NOT NULL,
    -- new → planned (schedule known) → formed (Wagenreihung asked at departure) → done.
    state TEXT NOT NULL DEFAULT 'new',
    -- Unix seconds: when the cron looks at the run next, and how often it failed so far.
    next_check INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    first_seen INTEGER NOT NULL,
    completed_at INTEGER,
    -- Berlin day of the first stop's departure, "2026-10-06".
    service_day TEXT,
    -- "ICE 1095", "ICE", "1095", "RE 3" (line, regional trains only).
    name TEXT,
    category TEXT,
    number TEXT,
    line TEXT,
    origin_eva TEXT,
    destination_eva TEXT,
    -- Berlin local time "2026-10-06T18:30" at the first and last stop.
    planned_departure TEXT,
    planned_arrival TEXT,
    -- Delay in minutes at the terminus (cancelled terminus: delay at the last stop served).
    final_delay INTEGER,
    cancelled INTEGER,
    -- JSON: {status, groups: [{name, category, number, destination, vehicles: [{type, id}]}]}, from bahn.de at departure.
    formation TEXT,
    -- JSON: train-wide messages ["Bauarbeiten", …].
    messages TEXT,
    -- JSON, one array per stop, compact so a run stays well under 1 KB:
    -- [eva, arrival, arrivalDelay, departure, departureDelay, platform, changedPlatform, flags, messages?]
    -- arrival/departure: planned, in minutes after planned_departure (null at the first/last stop);
    -- delays in minutes, null without realtime; changedPlatform only when it differs from platform;
    -- flags: 1 = stop cancelled, 2 = additional stop (Zusatzhalt); messages: ["Reparatur am Zug", …], left out when none.
    stops TEXT
);

-- Every index costs an extra written row per update, so only what the Worker and backup.sh need.
CREATE INDEX IF NOT EXISTS runs_due ON runs (state, next_check);
CREATE INDEX IF NOT EXISTS runs_day ON runs (service_day);

-- Station names for the EVA numbers in runs.stops, written once per station.
CREATE TABLE IF NOT EXISTS stations (
    eva TEXT PRIMARY KEY,
    name TEXT NOT NULL
);
