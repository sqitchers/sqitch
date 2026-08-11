-- Revert greptest:roles from pg

BEGIN;

DROP TABLE roles;

COMMIT;
