-- Deploy greptest:users to pg
-- requires: roles

BEGIN;

CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    nick TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL
);

-- Another CREATE TABLE pattern
-- Test ALTER TABLE again

COMMIT;
