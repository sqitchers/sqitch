BEGIN;

-- Create a new changes table with updated unique constraint.
CREATE TABLE new_changes (
    change_id       TEXT        PRIMARY KEY,
    script_hash     TEXT            NULL,
    change          TEXT        NOT NULL,
    project         TEXT        NOT NULL REFERENCES projects(project) ON UPDATE CASCADE,
    note            TEXT        NOT NULL DEFAULT '',
    committed_at    DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    committer_name  TEXT        NOT NULL,
    committer_email TEXT        NOT NULL,
    planned_at      DATETIME    NOT NULL,
    planner_name    TEXT        NOT NULL,
    planner_email   TEXT        NOT NULL,
    UNIQUE(project, script_hash)
);

-- Copy all the data to the new table and move it into place.
INSERT INTO new_changes
SELECT * FROM changes;
PRAGMA foreign_keys = OFF;
DROP TABLE changes;
ALTER TABLE new_changes RENAME TO changes;
PRAGMA foreign_keys = ON;
 
COMMIT;
