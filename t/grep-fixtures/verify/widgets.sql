-- Verify greptest:widgets on pg

BEGIN;

SELECT id, name, price FROM widgets WHERE FALSE;

-- Test literal: price.$
-- Test verify search

ROLLBACK;
