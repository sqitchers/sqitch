-- Verify greptest:posts on pg

BEGIN;

SELECT id, user_id, title, content FROM posts WHERE FALSE;

-- Test verify directory search
-- Test SELECT pattern

ROLLBACK;
