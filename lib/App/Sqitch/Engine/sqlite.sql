BEGIN;

CREATE TABLE releases (
    version         FLOAT       PRIMARY KEY,
    installed_at    DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    installer_name  TEXT        NOT NULL,
    installer_email TEXT        NOT NULL
);

CREATE TABLE projects (
    project         TEXT        PRIMARY KEY,
    uri             TEXT            NULL UNIQUE,
    created_at      DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    creator_name    TEXT        NOT NULL,
    creator_email   TEXT        NOT NULL
);

CREATE TABLE changes (
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

CREATE TABLE tags (
    tag_id          TEXT        PRIMARY KEY,
    tag             TEXT        NOT NULL,
    project         TEXT        NOT NULL REFERENCES projects(project) ON UPDATE CASCADE,
    change_id       TEXT        NOT NULL REFERENCES changes(change_id) ON UPDATE CASCADE,
    note            TEXT        NOT NULL DEFAULT '',
    committed_at    DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    committer_name  TEXT        NOT NULL,
    committer_email TEXT        NOT NULL,
    planned_at      DATETIME    NOT NULL,
    planner_name    TEXT        NOT NULL,
    planner_email   TEXT        NOT NULL,
    UNIQUE(project, tag)
);

CREATE TABLE dependencies (
    change_id       TEXT        NOT NULL REFERENCES changes(change_id) ON UPDATE CASCADE ON DELETE CASCADE,
    type            TEXT        NOT NULL,
    dependency      TEXT        NOT NULL,
    dependency_id   TEXT            NULL REFERENCES changes(change_id) ON UPDATE CASCADE CHECK (
            (type = 'require'  AND dependency_id IS NOT NULL)
         OR (type = 'conflict' AND dependency_id IS NULL)
    ),
    PRIMARY KEY (change_id, dependency)
);

CREATE TABLE events (
    event           TEXT        NOT NULL CHECK (event IN ('deploy', 'revert', 'fail')),
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

COMMIT;
