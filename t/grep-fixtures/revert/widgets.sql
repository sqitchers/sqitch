-- Revert greptest:widgets from pg

BEGIN;

DROP TABLE widgets;

COMMIT;
