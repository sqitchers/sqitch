/*
 * Sqitch database deployment metadata v1.0.;
 */

/*
 * Required PAGE SIZE = 16384 to avoid error: "key size exceeds
 * implementation restriction for index..."
 */

-- Table: releases

CREATE TABLE releases (
    version         FLOAT         NOT NULL PRIMARY KEY,
    installed_at    TIMESTAMP     DEFAULT CURRENT_TIMESTAMP NOT NULL,
    installer_name  VARCHAR(255)  NOT NULL,
    installer_email VARCHAR(255)  NOT NULL
);

COMMENT ON TABLE  releases                 IS 'Sqitch registry releases.';
COMMENT ON COLUMN releases.version         IS 'Version of the Sqitch registry.';
COMMENT ON COLUMN releases.installed_at    IS 'Date the registry release was installed.';
COMMENT ON COLUMN releases.installer_name  IS 'Name of the user who installed the registry release.';
COMMENT ON COLUMN releases.installer_email IS 'Email address of the user who installed the registry release.';

-- Table: projects

CREATE TABLE projects (
    project         VARCHAR(255)  NOT NULL PRIMARY KEY,
    uri             VARCHAR(255)  UNIQUE,
    created_at      TIMESTAMP     DEFAULT CURRENT_TIMESTAMP NOT NULL,
    creator_name    VARCHAR(255)  NOT NULL,
    creator_email   VARCHAR(255)  NOT NULL
);

COMMENT ON TABLE  projects                IS 'Sqitch projects deployed to this database.';
COMMENT ON COLUMN projects.project        IS 'Unique Name of a project.';
COMMENT ON COLUMN projects.uri            IS 'Optional project URI';
COMMENT ON COLUMN projects.created_at     IS 'Date the project was added to the database.';
COMMENT ON COLUMN projects.creator_name   IS 'Name of the user who added the project.';
COMMENT ON COLUMN projects.creator_email  IS 'Email address of the user who added the project.';

-- Table: changes

CREATE TABLE changes (
    change_id       VARCHAR(40)   NOT NULL PRIMARY KEY,
    script_hash     VARCHAR(40),
    change          VARCHAR(255)  NOT NULL,
    project         VARCHAR(255)  NOT NULL REFERENCES projects(project)
                                       ON UPDATE CASCADE,
    note            BLOB SUB_TYPE TEXT DEFAULT '' NOT NULL,
    committed_at    TIMESTAMP     DEFAULT CURRENT_TIMESTAMP NOT NULL,
    committer_name  VARCHAR(255)  NOT NULL,
    committer_email VARCHAR(255)  NOT NULL,
    planned_at      TIMESTAMP     NOT NULL,
    planner_name    VARCHAR(255)  NOT NULL,
    planner_email   VARCHAR(255)  NOT NULL,
    UNIQUE(project, script_hash)
);

COMMENT ON TABLE  changes                 IS 'Tracks the changes currently deployed to the database.';
COMMENT ON COLUMN changes.change_id       IS 'Change primary key.';
COMMENT ON COLUMN changes.script_hash     IS 'Deploy script SHA-1 hash.';
COMMENT ON COLUMN changes.change          IS 'Name of a deployed change.';
COMMENT ON COLUMN changes.project         IS 'Name of the Sqitch project to which the change belongs.';
COMMENT ON COLUMN changes.note            IS 'Description of the change.';
COMMENT ON COLUMN changes.committed_at    IS 'Date the change was deployed.';
COMMENT ON COLUMN changes.committer_name  IS 'Name of the user who deployed the change.';
COMMENT ON COLUMN changes.committer_email IS 'Email address of the user who deployed the change.';
COMMENT ON COLUMN changes.planned_at      IS 'Date the change was added to the plan.';
COMMENT ON COLUMN changes.planner_name    IS 'Name of the user who planed the change.';
COMMENT ON COLUMN changes.planner_email   IS 'Email address of the user who planned the change.';

-- Table: tags

CREATE TABLE tags (
    tag_id          CHAR(40)      NOT NULL PRIMARY KEY,
    tag             VARCHAR(250)  NOT NULL,
    project         VARCHAR(255)  NOT NULL REFERENCES projects(project)
                                        ON UPDATE CASCADE,
    change_id       CHAR(40)      NOT NULL REFERENCES changes(change_id)
                                        ON UPDATE CASCADE,
    note            BLOB SUB_TYPE TEXT DEFAULT '' NOT NULL,
    committed_at    TIMESTAMP     DEFAULT CURRENT_TIMESTAMP NOT NULL,
    committer_name  VARCHAR(512)  NOT NULL,
    committer_email VARCHAR(512)  NOT NULL,
    planned_at      TIMESTAMP     NOT NULL,
    planner_name    VARCHAR(512)  NOT NULL,
    planner_email   VARCHAR(512)  NOT NULL,
    UNIQUE(project, tag)
);

COMMENT ON TABLE  tags                 IS 'Tracks the tags currently applied to the database.';
COMMENT ON COLUMN tags.tag_id          IS 'Tag primary key.';
COMMENT ON COLUMN tags.tag             IS 'Project-unique tag name.';
COMMENT ON COLUMN tags.project         IS 'Name of the Sqitch project to which the tag belongs.';
COMMENT ON COLUMN tags.change_id       IS 'ID of last change deployed before the tag was applied.';
COMMENT ON COLUMN tags.note            IS 'Description of the tag.';
COMMENT ON COLUMN tags.committed_at    IS 'Date the tag was applied to the database.';
COMMENT ON COLUMN tags.committer_name  IS 'Name of the user who applied the tag.';
COMMENT ON COLUMN tags.committer_email IS 'Email address of the user who applied the tag.';
COMMENT ON COLUMN tags.planned_at      IS 'Date the tag was added to the plan.';
COMMENT ON COLUMN tags.planner_name    IS 'Name of the user who planed the tag.';
COMMENT ON COLUMN tags.planner_email   IS 'Email address of the user who planned the tag.';

-- Table: dependencies

CREATE TABLE dependencies (
    change_id       CHAR(40)      NOT NULL REFERENCES changes(change_id)
                                        ON UPDATE CASCADE ON DELETE CASCADE,
    type            VARCHAR(8)    NOT NULL,
    dependency      VARCHAR(512)  NOT NULL,
    dependency_id   CHAR(40)      REFERENCES changes(change_id)
                                        ON UPDATE CASCADE CONSTRAINT dependencies_check CHECK (
                          (type = 'require'  AND dependency_id IS NOT NULL)
                       OR (type = 'conflict' AND dependency_id IS NULL)
    ),
    PRIMARY KEY (change_id, dependency)
);

COMMENT ON TABLE  dependencies               IS 'Tracks the currently satisfied dependencies.';
COMMENT ON COLUMN dependencies.change_id     IS 'ID of the depending change.';
COMMENT ON COLUMN dependencies.type          IS 'Type of dependency.';
COMMENT ON COLUMN dependencies.dependency    IS 'Dependency name.';
COMMENT ON COLUMN dependencies.dependency_id IS 'Change ID the dependency resolves to.';

-- Table: events

CREATE TABLE events (
    event           VARCHAR(6)    NOT NULL
                    CONSTRAINT events_event_check CHECK (event IN ('deploy', 'revert', 'fail', 'merge')),
    change_id       CHAR(40)      NOT NULL,
    change          VARCHAR(512)  NOT NULL,
    project         VARCHAR(255)  NOT NULL REFERENCES projects(project)
                                        ON UPDATE CASCADE,
    note            BLOB SUB_TYPE TEXT DEFAULT '' NOT NULL,
    requires        BLOB SUB_TYPE TEXT DEFAULT '' NOT NULL,
    conflicts       BLOB SUB_TYPE TEXT DEFAULT '' NOT NULL,
    tags            BLOB SUB_TYPE TEXT DEFAULT '' NOT NULL,
    committed_at    TIMESTAMP     DEFAULT CURRENT_TIMESTAMP NOT NULL,
    committer_name  VARCHAR(512)  NOT NULL,
    committer_email VARCHAR(512)  NOT NULL,
    planned_at      TIMESTAMP     NOT NULL,
    planner_name    VARCHAR(512)  NOT NULL,
    planner_email   VARCHAR(512)  NOT NULL,
    PRIMARY KEY (change_id, committed_at)
);

COMMENT ON TABLE  events                 IS 'Contains full history of all deployment events.';
COMMENT ON COLUMN events.event           IS 'Type of event.';
COMMENT ON COLUMN events.change_id       IS 'Change ID.';
COMMENT ON COLUMN events.change          IS 'Change name.';
COMMENT ON COLUMN events.project         IS 'Name of the Sqitch project to which the change belongs.';
COMMENT ON COLUMN events.note            IS 'Description of the change.';
COMMENT ON COLUMN events.requires        IS 'Array of the names of required changes.';
COMMENT ON COLUMN events.conflicts       IS 'Array of the names of conflicting changes.';
COMMENT ON COLUMN events.tags            IS 'Tags associated with the change.';
COMMENT ON COLUMN events.committed_at    IS 'Date the event was committed.';
COMMENT ON COLUMN events.committer_name  IS 'Name of the user who committed the event.';
COMMENT ON COLUMN events.committer_email IS 'Email address of the user who committed the event.';
COMMENT ON COLUMN events.planned_at      IS 'Date the event was added to the plan.';
COMMENT ON COLUMN events.planner_name    IS 'Name of the user who planed the change.';
COMMENT ON COLUMN events.planner_email   IS 'Email address of the user who plan planned the change.';

COMMIT;
