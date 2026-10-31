-- Push notifications for new check-ins of the people a Träwelling user follows (#266) and about the user's own
-- check-ins (#447: likes, fellow travellers).
-- One row per device that turned them on.
CREATE TABLE IF NOT EXISTS subscriptions (
    id TEXT PRIMARY KEY,              -- random, given to the app
    secret_hash TEXT NOT NULL,        -- SHA-256 (hex) of the secret only the app knows
    device_token TEXT NOT NULL,       -- APNs device token (hex)
    sandbox INTEGER NOT NULL DEFAULT 0, -- 1: development build (APNs sandbox)
    user_id INTEGER NOT NULL,         -- the Träwelling user, so their own check-ins aren't reported
    tokens TEXT NOT NULL,             -- before #452: a Träwelling login of its own (read-only), AES-GCM with TOKEN_KEY; '' with login_id
    login_id TEXT,                    -- #452: the app's login (logins.id) the Worker reads with
    known TEXT,                       -- JSON array of the status IDs reported or seen; NULL until the first look
    kinds TEXT,                       -- JSON array: "followed", "likes", "companions" (#447); NULL: only "followed"
    language TEXT,                    -- the app's language for the notifications ("de", "en", #479); NULL: German + iOS keys
    notified TEXT,                    -- JSON array of Träwelling's notification IDs reported or seen; NULL until the first look
    webhook_id INTEGER,               -- Träwelling's webhook for the user's notifications (#447), if the login made one
    webhook TEXT,                     -- its signing secret, AES-GCM with TOKEN_KEY
    slot INTEGER NOT NULL,            -- minute (0–59) the look is due in, modulo INTERVAL_MINUTES
    created INTEGER NOT NULL          -- unix seconds
);
CREATE INDEX IF NOT EXISTS subscriptions_slot ON subscriptions (slot);
CREATE INDEX IF NOT EXISTS subscriptions_login ON subscriptions (login_id);
CREATE INDEX IF NOT EXISTS subscriptions_webhook ON subscriptions (webhook_id);

-- The app's Träwelling login (#452): one per user, renewed only here; devices fetch its access token.
CREATE TABLE IF NOT EXISTS logins (
    id TEXT PRIMARY KEY,              -- random, given to the app
    secret_hash TEXT NOT NULL,        -- SHA-256 (hex) of the secret only the user's devices know
    tokens TEXT NOT NULL,             -- access and refresh token, AES-GCM with TOKEN_KEY (bound to "login:<id>")
    notifications INTEGER NOT NULL DEFAULT 0, -- 1: made with `read-notifications` (likes, fellow travellers)
    renewed INTEGER NOT NULL,         -- unix seconds of the last renewal
    renewing INTEGER,                 -- unix seconds until which one request renews it; NULL otherwise
    used INTEGER NOT NULL,            -- unix seconds a device last fetched a token
    webhook_id INTEGER,               -- Träwelling's webhook for the user's notifications (#447), if the login made one
    webhook TEXT,                     -- its signing secret, AES-GCM with TOKEN_KEY
    created INTEGER NOT NULL          -- unix seconds
);
CREATE INDEX IF NOT EXISTS logins_renewed ON logins (renewed);
CREATE INDEX IF NOT EXISTS logins_used ON logins (used);
CREATE INDEX IF NOT EXISTS logins_webhook ON logins (webhook_id);

-- Regular trips (#397): the journeys a device's user said yes to for today, looked at in DB's timetable feed.
-- One row per device; deleted once its journeys have arrived.
CREATE TABLE IF NOT EXISTS commutes (
    id TEXT PRIMARY KEY,              -- made by the app
    secret_hash TEXT NOT NULL,        -- SHA-256 (hex) of the secret only the app knows
    device_token TEXT NOT NULL,       -- APNs device token (hex)
    sandbox INTEGER NOT NULL DEFAULT 0, -- 1: development build (APNs sandbox)
    journeys TEXT NOT NULL,           -- JSON: trains (category, number), stations (EVA, name), planned times,
                                      -- the stop IDs found in IRIS and what was reported
    language TEXT,                    -- the app's language for the notifications ("de", "en", #479); NULL: German + iOS keys
    slot INTEGER NOT NULL,            -- minute (0–59) the look is due in, modulo INTERVAL_MINUTES
    updated INTEGER NOT NULL          -- unix seconds
);
CREATE INDEX IF NOT EXISTS commutes_slot ON commutes (slot);

-- The APNs provider token, reused for 50 minutes (Apple refuses new ones more often than every 20).
CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated INTEGER NOT NULL
);
