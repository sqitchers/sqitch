-- Deploy greptest:posts to pg
-- requires: users

BEGIN;

CREATE TABLE posts (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    title TEXT NOT NULL,
    content TEXT
);

-- Test regex pattern: foo.*bar
-- Test literal string: ALTER TABLE
-- Case test: create table (lowercase)

COMMIT;
