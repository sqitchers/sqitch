CREATE SCHEMA IF NOT EXISTS &registry;

COMMENT ON SCHEMA &registry IS 'Sqitch database deployment metadata v1.0.';

CREATE TABLE &registry.projects (
    project         TEXT         PRIMARY KEY,
    uri             TEXT             NULL UNIQUE,
    created_at      TIMESTAMP_TZ NOT NULL DEFAULT current_timestamp,
    creator_name    TEXT         NOT NULL,
    creator_email   TEXT         NOT NULL
);

CREATE TABLE &registry.changes (
    change_id       TEXT         PRIMARY KEY,
    change          TEXT         NOT NULL,
    project         TEXT         NOT NULL REFERENCES &registry.projects(project) ON UPDATE CASCADE,
    note            TEXT         NOT NULL DEFAULT '',
    committed_at    TIMESTAMP_TZ NOT NULL DEFAULT current_timestamp,
    committer_name  TEXT         NOT NULL,
    committer_email TEXT         NOT NULL,
    planned_at      TIMESTAMP_TZ NOT NULL,
    planner_name    TEXT         NOT NULL,
    planner_email   TEXT         NOT NULL
);

CREATE TABLE &registry.tags (
    tag_id          TEXT        PRIMARY KEY,
    tag             TEXT        NOT NULL,
    project         TEXT        NOT NULL REFERENCES &registry.projects(project) ON UPDATE CASCADE,
    change_id       TEXT        NOT NULL REFERENCES &registry.changes(change_id) ON UPDATE CASCADE,
    note            TEXT        NOT NULL DEFAULT '',
    committed_at    TIMESTAMPTZ NOT NULL DEFAULT current_timestamp,
    committer_name  TEXT        NOT NULL,
    committer_email TEXT        NOT NULL,
    planned_at      TIMESTAMPTZ NOT NULL,
    planner_name    TEXT        NOT NULL,
    planner_email   TEXT        NOT NULL,
    UNIQUE(project, tag)
);

CREATE TABLE &registry.dependencies (
    change_id       TEXT        NOT NULL REFERENCES &registry.changes(change_id) ON UPDATE CASCADE ON DELETE CASCADE,
    type            TEXT        NOT NULL,
    dependency      TEXT        NOT NULL,
    dependency_id   TEXT            NULL REFERENCES &registry.changes(change_id) ON UPDATE CASCADE,
    PRIMARY KEY (change_id, dependency)
);

CREATE TABLE &registry.events (
    event           TEXT        NOT NULL,
    change_id       TEXT        NOT NULL,
    change          TEXT        NOT NULL,
    project         TEXT        NOT NULL REFERENCES &registry.projects(project) ON UPDATE CASCADE,
    note            TEXT        NOT NULL DEFAULT '',
    requires        ARRAY       NOT NULL DEFAULT '{}',
    conflicts       ARRAY       NOT NULL DEFAULT '{}',
    tags            ARRAY       NOT NULL DEFAULT '{}',
    committed_at    TIMESTAMPTZ NOT NULL DEFAULT current_timestamp,
    committer_name  TEXT        NOT NULL,
    committer_email TEXT        NOT NULL,
    planned_at      TIMESTAMPTZ NOT NULL,
    planner_name    TEXT        NOT NULL,
    planner_email   TEXT        NOT NULL,
    PRIMARY KEY (change_id, committed_at)
);

COMMIT;
