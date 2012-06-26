-- requires: users
-- conflicts: dr_evil
SET client_min_messages = warning;
CREATE TABLE __myapp.widgets (
    name TEXT PRIMARY KEY,
    owner TEXT NOT NULL REFERENCES __myapp.users(nick)
);
