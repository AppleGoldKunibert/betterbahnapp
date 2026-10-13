-- Push notifications for new check-ins of the people a Träwelling user follows (#266).
-- One row per device that turned them on.
CREATE TABLE IF NOT EXISTS subscriptions (
    id TEXT PRIMARY KEY,              -- random, given to the app
    secret_hash TEXT NOT NULL,        -- SHA-256 (hex) of the secret only the app knows
    device_token TEXT NOT NULL,       -- APNs device token (hex)
    sandbox INTEGER NOT NULL DEFAULT 0, -- 1: development build (APNs sandbox)
    user_id INTEGER NOT NULL,         -- the Träwelling user, so their own check-ins aren't reported
    tokens TEXT NOT NULL,             -- the Worker's own Träwelling login (read-statuses only), AES-GCM with TOKEN_KEY
    known TEXT,                       -- JSON array of the status IDs reported or seen; NULL until the first look
    slot INTEGER NOT NULL,            -- minute (0–59) the look is due in, modulo INTERVAL_MINUTES
    created INTEGER NOT NULL          -- unix seconds
);
CREATE INDEX IF NOT EXISTS subscriptions_slot ON subscriptions (slot);

-- The APNs provider token, reused for 50 minutes (Apple refuses new ones more often than every 20).
CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated INTEGER NOT NULL
);
