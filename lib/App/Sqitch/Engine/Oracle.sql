def sqitch_schema=&1

--BEGIN;

--COMMENT ON SCHEMA &sqitch_schema IS 'Sqitch database deployment metadata v1.0.';

CREATE TABLE &sqitch_schema..projects (
    project         VARCHAR2(512 CHAR)       PRIMARY KEY,
    uri             VARCHAR2(512 CHAR)       NULL UNIQUE,
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT current_timestamp NOT NULL,
    creator_name    VARCHAR2(512 CHAR)       NOT NULL,
    creator_email   VARCHAR2(512 CHAR)       NOT NULL
);

COMMENT ON TABLE &sqitch_schema..projects                 IS 'Sqitch projects deployed to this database.';
COMMENT ON COLUMN &sqitch_schema..projects.project        IS 'Unique Name of a project.';
COMMENT ON COLUMN &sqitch_schema..projects.uri            IS 'Optional project URI';
COMMENT ON COLUMN &sqitch_schema..projects.created_at     IS 'Date the project was added to the database.';
COMMENT ON COLUMN &sqitch_schema..projects.creator_name   IS 'Name of the user who added the project.';
COMMENT ON COLUMN &sqitch_schema..projects.creator_email  IS 'Email address of the user who added the project.';

CREATE TABLE &sqitch_schema..changes (
    change_id       CHAR(40)                 PRIMARY KEY,
    change          VARCHAR2(512 CHAR)       NOT NULL,
    project         VARCHAR2(512 CHAR)       NOT NULL REFERENCES &sqitch_schema..projects(project),
    note            VARCHAR2(4000 CHAR)      DEFAULT '' NOT NULL,
    committed_at    TIMESTAMP WITH TIME ZONE DEFAULT current_timestamp NOT NULL,
    committer_name  VARCHAR2(512 CHAR)       NOT NULL,
    committer_email VARCHAR2(512 CHAR)       NOT NULL,
    planned_at      TIMESTAMP WITH TIME ZONE NOT NULL,
    planner_name    VARCHAR2(512 CHAR)       NOT NULL,
    planner_email   VARCHAR2(512 CHAR)       NOT NULL
);

COMMENT ON TABLE &sqitch_schema..changes                  IS 'Tracks the changes currently deployed to the database.';
COMMENT ON COLUMN &sqitch_schema..changes.change_id       IS 'Change primary key.';
COMMENT ON COLUMN &sqitch_schema..changes.change          IS 'Name of a deployed change.';
COMMENT ON COLUMN &sqitch_schema..changes.project         IS 'Name of the Sqitch project to which the change belongs.';
COMMENT ON COLUMN &sqitch_schema..changes.note            IS 'Description of the change.';
COMMENT ON COLUMN &sqitch_schema..changes.committed_at    IS 'Date the change was deployed.';
COMMENT ON COLUMN &sqitch_schema..changes.committer_name  IS 'Name of the user who deployed the change.';
COMMENT ON COLUMN &sqitch_schema..changes.committer_email IS 'Email address of the user who deployed the change.';
COMMENT ON COLUMN &sqitch_schema..changes.planned_at      IS 'Date the change was added to the plan.';
COMMENT ON COLUMN &sqitch_schema..changes.planner_name    IS 'Name of the user who planed the change.';
COMMENT ON COLUMN &sqitch_schema..changes.planner_email   IS 'Email address of the user who planned the change.';

CREATE TABLE &sqitch_schema..tags (
    tag_id          CHAR(40)                 PRIMARY KEY,
    tag             VARCHAR2(512 CHAR)       NOT NULL,
    project         VARCHAR2(512 CHAR)       NOT NULL REFERENCES &sqitch_schema..projects(project),
    change_id       CHAR(40)                 NOT NULL REFERENCES &sqitch_schema..changes(change_id),
    note            VARCHAR2(4000 CHAR)      DEFAULT '' NOT NULL,
    committed_at    TIMESTAMP WITH TIME ZONE DEFAULT current_timestamp NOT NULL,
    committer_name  VARCHAR2(512 CHAR)       NOT NULL,
    committer_email VARCHAR2(512 CHAR)       NOT NULL,
    planned_at      TIMESTAMP WITH TIME ZONE NOT NULL,
    planner_name    VARCHAR2(512 CHAR)       NOT NULL,
    planner_email   VARCHAR2(512 CHAR)       NOT NULL,
    UNIQUE(project, tag)
);

COMMENT ON TABLE &sqitch_schema..tags                  IS 'Tracks the tags currently applied to the database.';
COMMENT ON COLUMN &sqitch_schema..tags.tag_id          IS 'Tag primary key.';
COMMENT ON COLUMN &sqitch_schema..tags.tag             IS 'Project-unique tag name.';
COMMENT ON COLUMN &sqitch_schema..tags.project         IS 'Name of the Sqitch project to which the tag belongs.';
COMMENT ON COLUMN &sqitch_schema..tags.change_id       IS 'ID of last change deployed before the tag was applied.';
COMMENT ON COLUMN &sqitch_schema..tags.note            IS 'Description of the tag.';
COMMENT ON COLUMN &sqitch_schema..tags.committed_at    IS 'Date the tag was applied to the database.';
COMMENT ON COLUMN &sqitch_schema..tags.committer_name  IS 'Name of the user who applied the tag.';
COMMENT ON COLUMN &sqitch_schema..tags.committer_email IS 'Email address of the user who applied the tag.';
COMMENT ON COLUMN &sqitch_schema..tags.planned_at      IS 'Date the tag was added to the plan.';
COMMENT ON COLUMN &sqitch_schema..tags.planner_name    IS 'Name of the user who planed the tag.';
COMMENT ON COLUMN &sqitch_schema..tags.planner_email   IS 'Email address of the user who planned the tag.';

CREATE TABLE &sqitch_schema..dependencies (
    change_id       CHAR(40)                 NOT NULL REFERENCES &sqitch_schema..changes(change_id) ON DELETE CASCADE,
    type            VARCHAR2(8)              NOT NULL,
    dependency      VARCHAR2(1024 CHAR)      NOT NULL,
    dependency_id   CHAR(40)                     NULL REFERENCES &sqitch_schema..changes(change_id),
    CHECK (
            (type = 'require'  AND dependency_id IS NOT NULL)
         OR (type = 'conflict' AND dependency_id IS NULL)
    ),
    PRIMARY KEY (change_id, dependency)
);

COMMENT ON TABLE &sqitch_schema..dependencies                IS 'Tracks the currently satisfied dependencies.';
COMMENT ON COLUMN &sqitch_schema..dependencies.change_id     IS 'ID of the depending change.';
COMMENT ON COLUMN &sqitch_schema..dependencies.type          IS 'Type of dependency.';
COMMENT ON COLUMN &sqitch_schema..dependencies.dependency    IS 'Dependency name.';
COMMENT ON COLUMN &sqitch_schema..dependencies.dependency_id IS 'Change ID the dependency resolves to.';

CREATE TYPE &sqitch_schema.sqitch_array AS varray(1024) OF VARCHAR2(512);
/

CREATE TABLE &sqitch_schema..events (
    event           VARCHAR2(6)              NOT NULL CHECK (event IN ('deploy', 'revert', 'fail')),
    change_id       CHAR(40)                 NOT NULL,
    change          VARCHAR2(512 CHAR)       NOT NULL,
    project         VARCHAR2(512 CHAR)       NOT NULL REFERENCES &sqitch_schema..projects(project),
    note            VARCHAR2(4000 CHAR)      DEFAULT '' NOT NULL,
    requires        SQITCH_ARRAY             DEFAULT SQITCH_ARRAY() NOT NULL,
    conflicts       SQITCH_ARRAY             DEFAULT SQITCH_ARRAY() NOT NULL,
    tags            SQITCH_ARRAY             DEFAULT SQITCH_ARRAY() NOT NULL,
    committed_at    TIMESTAMP WITH TIME ZONE DEFAULT current_timestamp NOT NULL,
    committer_name  VARCHAR2(512 CHAR)       NOT NULL,
    committer_email VARCHAR2(512 CHAR)       NOT NULL,
    planned_at      TIMESTAMP WITH TIME ZONE NOT NULL,
    planner_name    VARCHAR2(512 CHAR)       NOT NULL,
    planner_email   VARCHAR2(512 CHAR)       NOT NULL
);

CREATE UNIQUE INDEX events_pkey ON &sqitch_schema..events(change_id, committed_at);

COMMENT ON TABLE &sqitch_schema..events                  IS 'Contains full history of all deployment events.';
COMMENT ON COLUMN &sqitch_schema..events.event           IS 'Type of event.';
COMMENT ON COLUMN &sqitch_schema..events.change_id       IS 'Change ID.';
COMMENT ON COLUMN &sqitch_schema..events.change          IS 'Change name.';
COMMENT ON COLUMN &sqitch_schema..events.project         IS 'Name of the Sqitch project to which the change belongs.';
COMMENT ON COLUMN &sqitch_schema..events.note            IS 'Description of the change.';
COMMENT ON COLUMN &sqitch_schema..events.requires        IS 'Array of the names of required changes.';
COMMENT ON COLUMN &sqitch_schema..events.conflicts       IS 'Array of the names of conflicting changes.';
COMMENT ON COLUMN &sqitch_schema..events.tags            IS 'Tags associated with the change.';
COMMENT ON COLUMN &sqitch_schema..events.committed_at    IS 'Date the event was committed.';
COMMENT ON COLUMN &sqitch_schema..events.committer_name  IS 'Name of the user who committed the event.';
COMMENT ON COLUMN &sqitch_schema..events.committer_email IS 'Email address of the user who committed the event.';
COMMENT ON COLUMN &sqitch_schema..events.planned_at      IS 'Date the event was added to the plan.';
COMMENT ON COLUMN &sqitch_schema..events.planner_name    IS 'Name of the user who planed the change.';
COMMENT ON COLUMN &sqitch_schema..events.planner_email   IS 'Email address of the user who plan planned the change.';

COMMIT;

quit
