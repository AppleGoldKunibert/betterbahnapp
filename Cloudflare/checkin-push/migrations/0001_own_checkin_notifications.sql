-- #447: what each subscription is notified about and the Träwelling notifications already seen.
-- Run once on a database made before #447 (schema.sql has the columns for new ones):
-- npx wrangler d1 execute betterbahn-push --remote --file=migrations/0001_own_checkin_notifications.sql
ALTER TABLE subscriptions ADD COLUMN kinds TEXT;
ALTER TABLE subscriptions ADD COLUMN notified TEXT;
