-- Verify greptest:roles on pg

BEGIN;

SELECT id, name FROM roles WHERE FALSE;

-- Test pattern: SELECT.*FROM

ROLLBACK;
