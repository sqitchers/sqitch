BEGIN;

CREATE TABLE releases (
    version         DOUBLE      PRIMARY KEY,
    installed_at    TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    installer_name  VARCHAR     NOT NULL,
    installer_email VARCHAR     NOT NULL
);

CREATE TABLE projects (
    project         VARCHAR     PRIMARY KEY,
    uri             VARCHAR         NULL UNIQUE,
    created_at      TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    creator_name    VARCHAR     NOT NULL,
    creator_email   VARCHAR     NOT NULL
);

CREATE TABLE changes (
    change_id       VARCHAR     PRIMARY KEY,
    script_hash     VARCHAR         NULL,
    change          VARCHAR     NOT NULL,
    project         VARCHAR     NOT NULL REFERENCES projects(project) ON UPDATE CASCADE,
    note            VARCHAR     NOT NULL DEFAULT '',
    committed_at    TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    committer_name  VARCHAR     NOT NULL,
    committer_email VARCHAR     NOT NULL,
    planned_at      TIMESTAMP   NOT NULL,
    planner_name    VARCHAR     NOT NULL,
    planner_email   VARCHAR     NOT NULL,
    UNIQUE(project, script_hash)
);

CREATE TABLE tags (
    tag_id          VARCHAR     PRIMARY KEY,
    tag             VARCHAR     NOT NULL,
    project         VARCHAR     NOT NULL REFERENCES projects(project) ON UPDATE CASCADE,
    change_id       VARCHAR     NOT NULL REFERENCES changes(change_id) ON UPDATE CASCADE,
    note            VARCHAR     NOT NULL DEFAULT '',
    committed_at    TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    committer_name  VARCHAR     NOT NULL,
    committer_email VARCHAR     NOT NULL,
    planned_at      TIMESTAMP   NOT NULL,
    planner_name    VARCHAR     NOT NULL,
    planner_email   VARCHAR     NOT NULL,
    UNIQUE(project, tag)
);

CREATE TABLE dependencies (
    change_id       VARCHAR     NOT NULL REFERENCES changes(change_id) ON UPDATE CASCADE ON DELETE CASCADE,
    type            VARCHAR     NOT NULL,
    dependency      VARCHAR     NOT NULL,
    dependency_id   VARCHAR         NULL REFERENCES changes(change_id) ON UPDATE CASCADE
                                     CONSTRAINT dependencies_check CHECK (
            (type = 'require'  AND dependency_id IS NOT NULL)
         OR (type = 'conflict' AND dependency_id IS NULL)
    ),
    PRIMARY KEY (change_id, dependency)
);

CREATE TABLE events (
    event           VARCHAR     NOT NULL CONSTRAINT events_event_check CHECK (
        event IN ('deploy', 'revert', 'fail', 'merge')
    ),
    change_id       VARCHAR     NOT NULL,
    change          VARCHAR     NOT NULL,
    project         VARCHAR     NOT NULL REFERENCES projects(project) ON UPDATE CASCADE,
    note            VARCHAR     NOT NULL DEFAULT '',
    requires        VARCHAR     NOT NULL DEFAULT '',
    conflicts       VARCHAR     NOT NULL DEFAULT '',
    tags            VARCHAR     NOT NULL DEFAULT '',
    committed_at    TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    committer_name  VARCHAR     NOT NULL,
    committer_email VARCHAR     NOT NULL,
    planned_at      TIMESTAMP   NOT NULL,
    planner_name    VARCHAR     NOT NULL,
    planner_email   VARCHAR     NOT NULL,
    PRIMARY KEY (change_id, committed_at)
);

COMMIT;
