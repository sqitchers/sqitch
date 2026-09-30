-- Revert greptest:users from pg

BEGIN;

DROP TABLE users;

-- Another DROP reference

COMMIT;
