-- #479: the language the app shows its notifications in, which iOS doesn't tell for an app set to its own language.
-- Run once on a database made before #479 (schema.sql has the columns for new ones), before deploying:
-- npx wrangler d1 execute betterbahn-push --remote --file=migrations/0003_notification_language.sql
ALTER TABLE subscriptions ADD COLUMN language TEXT;
ALTER TABLE commutes ADD COLUMN language TEXT;
