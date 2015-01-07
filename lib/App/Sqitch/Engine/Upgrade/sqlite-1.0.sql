BEGIN;

CREATE TABLE releases (
    version         FLOAT       PRIMARY KEY,
    installed_at    DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    installer_name  TEXT        NOT NULL,
    installer_email TEXT        NOT NULL
);

-- Create a new changes table with script_hash.
CREATE TABLE new_changes (
    change_id       TEXT        PRIMARY KEY,
    script_hash     TEXT            NULL UNIQUE,
    change          TEXT        NOT NULL,
    project         TEXT        NOT NULL REFERENCES projects(project) ON UPDATE CASCADE,
    note            TEXT        NOT NULL DEFAULT '',
    committed_at    DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    committer_name  TEXT        NOT NULL,
    committer_email TEXT        NOT NULL,
    planned_at      DATETIME    NOT NULL,
    planner_name    TEXT        NOT NULL,
    planner_email   TEXT        NOT NULL
);

-- Copy all the data to the new table and move it into place.
INSERT INTO new_changes
SELECT change_id, change_id, change, project, note,
       committed_at, committer_name, committer_email,
       planned_at, planner_name, planner_email
  FROM changes;
PRAGMA foreign_keys = OFF;
DROP TABLE changes;
ALTER TABLE new_changes RENAME TO changes;
PRAGMA foreign_keys = ON;

-- Create a new events table with support for "merge" events.
CREATE TABLE new_events (
    event           TEXT        NOT NULL CHECK (event IN ('deploy', 'revert', 'fail', 'merge')),
    change_id       TEXT        NOT NULL,
    change          TEXT        NOT NULL,
    project         TEXT        NOT NULL REFERENCES projects(project) ON UPDATE CASCADE,
    note            TEXT        NOT NULL DEFAULT '',
    requires        TEXT        NOT NULL DEFAULT '',
    conflicts       TEXT        NOT NULL DEFAULT '',
    tags            TEXT        NOT NULL DEFAULT '',
    committed_at    DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    committer_name  TEXT        NOT NULL,
    committer_email TEXT        NOT NULL,
    planned_at      DATETIME    NOT NULL,
    planner_name    TEXT        NOT NULL,
    planner_email   TEXT        NOT NULL,
    PRIMARY KEY (change_id, committed_at)
);

INSERT INTO new_events
SELECT * FROM events;
PRAGMA foreign_keys = OFF;
DROP TABLE events;
ALTER TABLE new_events RENAME TO events;
PRAGMA foreign_keys = ON;

COMMIT;
