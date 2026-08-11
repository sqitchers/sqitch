-- Deploy greptest:widgets to pg
-- requires: users

BEGIN;

CREATE TABLE widgets (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    price DECIMAL(10,2)
);

-- Special chars test: foo*bar
-- Special chars test: price.$
-- Pattern test: CREATE INDEX

COMMIT;
