CREATE TABLE widgets (
    name TEXT PRIMARY KEY,
    owner TEXT NOT NULL REFERENCES users(nick)
);
