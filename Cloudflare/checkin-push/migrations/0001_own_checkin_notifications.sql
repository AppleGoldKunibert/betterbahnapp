-- #447: what each subscription is notified about, the Träwelling notifications already seen and its webhook.
-- Run once on a database made before #447 (schema.sql has the columns for new ones):
-- npx wrangler d1 execute betterbahn-push --remote --file=migrations/0001_own_checkin_notifications.sql
ALTER TABLE subscriptions ADD COLUMN kinds TEXT;
ALTER TABLE subscriptions ADD COLUMN notified TEXT;
ALTER TABLE subscriptions ADD COLUMN webhook_id INTEGER;
ALTER TABLE subscriptions ADD COLUMN webhook TEXT;
CREATE INDEX IF NOT EXISTS subscriptions_webhook ON subscriptions (webhook_id);
