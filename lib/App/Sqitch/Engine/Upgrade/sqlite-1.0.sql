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

COMMIT;
