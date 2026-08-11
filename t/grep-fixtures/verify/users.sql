-- Verify greptest:users on pg

BEGIN;

SELECT id, nick, name FROM users WHERE FALSE;

-- Another SELECT reference

ROLLBACK;
