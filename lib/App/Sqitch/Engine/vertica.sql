CREATE SCHEMA :"registry";

COMMENT ON SCHEMA :"registry" IS 'Sqitch database deployment metadata v1.0.';

CREATE TABLE :"registry".projects (
    project         VARCHAR(1024) PRIMARY KEY,
    uri             VARCHAR(1024) NULL UNIQUE,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT clock_timestamp(),
    creator_name    VARCHAR(1024) NOT NULL,
    creator_email   VARCHAR(1024) NOT NULL
);

COMMENT ON TABLE :"registry".projects                 IS 'Sqitch projects deployed to this database.';

CREATE TABLE :"registry".changes (
    change_id       CHAR(40)       PRIMARY KEY,
    change          VARCHAR(1024)  NOT NULL,
    project         VARCHAR(1024)  NOT NULL REFERENCES :"registry".projects(project),
    note            VARCHAR(65000) NOT NULL DEFAULT '',
    committed_at    TIMESTAMPTZ    NOT NULL DEFAULT clock_timestamp(),
    committer_name  VARCHAR(1024)  NOT NULL,
    committer_email VARCHAR(1024)  NOT NULL,
    planned_at      TIMESTAMPTZ    NOT NULL,
    planner_name    VARCHAR(1024)  NOT NULL,
    planner_email   VARCHAR(1024)  NOT NULL
);

COMMENT ON TABLE :"registry".changes                  IS 'Tracks the changes currently deployed to the database.';

CREATE TABLE :"registry".tags (
    tag_id          CHAR(40)       PRIMARY KEY,
    tag             VARCHAR(1024)  NOT NULL,
    project         VARCHAR(1024)  NOT NULL REFERENCES :"registry".projects(project),
    change_id       CHAR(40)       NOT NULL REFERENCES :"registry".changes(change_id),
    note            VARCHAR(65000) NOT NULL DEFAULT '',
    committed_at    TIMESTAMPTZ    NOT NULL DEFAULT clock_timestamp(),
    committer_name  VARCHAR(1024)  NOT NULL,
    committer_email VARCHAR(1024)  NOT NULL,
    planned_at      TIMESTAMPTZ    NOT NULL,
    planner_name    VARCHAR(1024)  NOT NULL,
    planner_email   VARCHAR(1024)  NOT NULL,
    UNIQUE(project, tag)
);

COMMENT ON TABLE :"registry".tags                  IS 'Tracks the tags currently applied to the database.';

CREATE TABLE :"registry".dependencies (
    change_id       CHAR(40)      NOT NULL REFERENCES :"registry".changes(change_id),
    type            VARCHAR(8)    NOT NULL,
    dependency      VARCHAR(2048) NOT NULL,
    dependency_id   CHAR(40)      NULL REFERENCES :"registry".changes(change_id),
    PRIMARY KEY (change_id, dependency)
);

COMMENT ON TABLE :"registry".dependencies                IS 'Tracks the currently satisfied dependencies.';

CREATE TABLE :"registry".events (
    event           VARCHAR(6)     NOT NULL,
    change_id       CHAR(40)       NOT NULL,
    change          VARCHAR(1024)  NOT NULL,
    project         VARCHAR(1024)  NOT NULL REFERENCES :"registry".projects(project),
    note            VARCHAR(65000) NOT NULL DEFAULT '',
    requires        LONG VARCHAR   NOT NULL DEFAULT '{}',
    conflicts       LONG VARCHAR   NOT NULL DEFAULT '{}',
    tags            LONG VARCHAR   NOT NULL DEFAULT '{}',
    committed_at    TIMESTAMPTZ    NOT NULL DEFAULT clock_timestamp(),
    committer_name  VARCHAR(1024)  NOT NULL,
    committer_email VARCHAR(1024)  NOT NULL,
    planned_at      TIMESTAMPTZ    NOT NULL,
    planner_name    VARCHAR(1024)  NOT NULL,
    planner_email   VARCHAR(1024)  NOT NULL,
    PRIMARY KEY (change_id, committed_at)
);

COMMENT ON TABLE :"registry".events                  IS 'Contains full history of all deployment events.';
