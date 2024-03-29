CREATE SCHEMA :"registry";

COMMENT ON SCHEMA :"registry" IS 'Sqitch database deployment metadata v1.1.';

CREATE TABLE :"registry".releases (
    version         FLOAT          PRIMARY KEY ENABLED,
    installed_at    TIMESTAMPTZ    NOT NULL DEFAULT clock_timestamp(),
    installer_name  VARCHAR(1024)  NOT NULL,
    installer_email VARCHAR(1024)  NOT NULL
);

COMMENT ON TABLE  :"registry".releases IS 'Sqitch registry releases.';

CREATE TABLE :"registry".projects (
    project         VARCHAR(1024) PRIMARY KEY ENABLED ENCODING AUTO,
    uri             VARCHAR(1024) NULL UNIQUE ENABLED,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT clock_timestamp(),
    creator_name    VARCHAR(1024) NOT NULL,
    creator_email   VARCHAR(1024) NOT NULL
);

COMMENT ON TABLE :"registry".projects IS 'Sqitch projects deployed to this database.';

CREATE TABLE :"registry".changes (
    change_id       CHAR(40)       PRIMARY KEY ENABLED ENCODING AUTO,
    script_hash     CHAR(40)           NULL UNIQUE ENABLED,
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

COMMENT ON TABLE :"registry".changes IS 'Tracks the changes currently deployed to the database.';

CREATE TABLE :"registry".tags (
    tag_id          CHAR(40)       PRIMARY KEY ENABLED ENCODING AUTO,
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
    UNIQUE(project, tag) ENABLED
);

COMMENT ON TABLE :"registry".tags IS 'Tracks the tags currently applied to the database.';

CREATE TABLE :"registry".dependencies (
    change_id       CHAR(40)      NOT NULL REFERENCES :"registry".changes(change_id),
    type            VARCHAR(8)    NOT NULL ENCODING AUTO,
    dependency      VARCHAR(2048) NOT NULL,
    dependency_id   CHAR(40)      NULL REFERENCES :"registry".changes(change_id),
    PRIMARY KEY (change_id, dependency) ENABLED
);

COMMENT ON TABLE :"registry".dependencies IS 'Tracks the currently satisfied dependencies.';

CREATE TABLE :"registry".events (
    event           VARCHAR(6)     NOT NULL ENCODING AUTO,
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
    PRIMARY KEY (change_id, committed_at) ENABLED
);

COMMENT ON TABLE :"registry".events  IS 'Contains full history of all deployment events.';
