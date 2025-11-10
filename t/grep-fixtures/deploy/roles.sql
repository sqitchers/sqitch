-- Deploy greptest:roles to pg

BEGIN;

CREATE TABLE roles (
    id SERIAL PRIMARY KEY,
    name TEXT UNIQUE NOT NULL
);

-- Test CREATE pattern
-- Test ALTER TABLE reference

COMMIT;
