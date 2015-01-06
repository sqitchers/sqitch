SET client_min_messages = warning;
CREATE SCHEMA __myapp;
CREATE TABLE __myapp.users (
    nick TEXT PRIMARY KEY,
    name TEXT NOT NULL
);
