-- Live Activities kept current while the app is closed (#315). One row per running activity, from the moment
-- the app goes to the background until the journey has arrived (or the app is opened again).
CREATE TABLE IF NOT EXISTS activities (
    id TEXT PRIMARY KEY,              -- made up by the app
    secret_hash TEXT NOT NULL,        -- SHA-256 (hex) of the secret only the app knows
    push_token TEXT NOT NULL,         -- the activity's ActivityKit push token (hex)
    sandbox INTEGER NOT NULL DEFAULT 0, -- 1: development build (APNs sandbox)
    journey TEXT NOT NULL,            -- the journey's trains, stops, times and platforms (JSON), with where IRIS lists them
    state TEXT,                       -- the activity's state last pushed (JSON), so only changes are sent
    next_check INTEGER NOT NULL,      -- unix seconds: when to look again
    ends INTEGER NOT NULL,            -- unix seconds: the final arrival plus the minutes "Angekommen" shows
    created INTEGER NOT NULL          -- unix seconds
);
CREATE INDEX IF NOT EXISTS activities_next_check ON activities (next_check);

-- The APNs provider token, reused for 50 minutes (Apple refuses new ones more often than every 20).
CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated INTEGER NOT NULL
);
