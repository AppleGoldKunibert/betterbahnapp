-- #452: the app's Träwelling login kept here, and sign-ups that read with it.
-- Run once on a database made before #452 (schema.sql has all of it for new ones):
-- npx wrangler d1 execute betterbahn-push --remote --file=migrations/0002_server_logins.sql
ALTER TABLE subscriptions ADD COLUMN login_id TEXT;
CREATE INDEX IF NOT EXISTS subscriptions_login ON subscriptions (login_id);
CREATE TABLE IF NOT EXISTS logins (
    id TEXT PRIMARY KEY,
    secret_hash TEXT NOT NULL,
    tokens TEXT NOT NULL,
    notifications INTEGER NOT NULL DEFAULT 0,
    renewed INTEGER NOT NULL,
    renewing INTEGER,
    used INTEGER NOT NULL,
    webhook_id INTEGER,
    webhook TEXT,
    created INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS logins_renewed ON logins (renewed);
CREATE INDEX IF NOT EXISTS logins_used ON logins (used);
CREATE INDEX IF NOT EXISTS logins_webhook ON logins (webhook_id);
