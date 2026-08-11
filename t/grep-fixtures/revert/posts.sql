-- Revert greptest:posts from pg

BEGIN;

DROP TABLE posts;

-- Test DROP pattern
-- Test revert directory search

COMMIT;
