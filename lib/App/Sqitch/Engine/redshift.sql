BEGIN;

CREATE SCHEMA :"registry";

COMMENT ON SCHEMA :"registry" IS 'Sqitch database deployment metadata v1.0.';

CREATE TABLE :"registry".releases (
    version         REAL        PRIMARY KEY,
    installed_at    TIMESTAMP   NOT NULL DEFAULT GETDATE(),
    installer_name  TEXT        NOT NULL,
    installer_email TEXT        NOT NULL
);

COMMENT ON TABLE  :"registry".releases                 IS 'Sqitch registry releases.';
COMMENT ON COLUMN :"registry".releases.version         IS 'Version of the Sqitch registry.';
COMMENT ON COLUMN :"registry".releases.installed_at    IS 'Date the registry release was installed.';
COMMENT ON COLUMN :"registry".releases.installer_name  IS 'Name of the user who installed the registry release.';
COMMENT ON COLUMN :"registry".releases.installer_email IS 'Email address of the user who installed the registry release.';

CREATE TABLE :"registry".projects (
    project         TEXT        PRIMARY KEY,
    uri             TEXT            NULL UNIQUE,
    created_at      TIMESTAMP   NOT NULL DEFAULT GETDATE(),
    creator_name    TEXT        NOT NULL,
    creator_email   TEXT        NOT NULL
):tableopts;

COMMENT ON TABLE  :"registry".projects                IS 'Sqitch projects deployed to this database.';
COMMENT ON COLUMN :"registry".projects.project        IS 'Unique Name of a project.';
COMMENT ON COLUMN :"registry".projects.uri            IS 'Optional project URI';
COMMENT ON COLUMN :"registry".projects.created_at     IS 'Date the project was added to the database.';
COMMENT ON COLUMN :"registry".projects.creator_name   IS 'Name of the user who added the project.';
COMMENT ON COLUMN :"registry".projects.creator_email  IS 'Email address of the user who added the project.';

CREATE TABLE :"registry".changes (
    change_id       TEXT        PRIMARY KEY,
    script_hash     TEXT            NULL,
    change          TEXT        NOT NULL,
    project         TEXT        NOT NULL REFERENCES :"registry".projects(project),
    note            TEXT        NOT NULL DEFAULT '',
    committed_at    TIMESTAMP   NOT NULL DEFAULT GETDATE(),
    committer_name  TEXT        NOT NULL,
    committer_email TEXT        NOT NULL,
    planned_at      TIMESTAMP   NOT NULL,
    planner_name    TEXT        NOT NULL,
    planner_email   TEXT        NOT NULL,
    UNIQUE(project, script_hash)
):tableopts;

COMMENT ON TABLE  :"registry".changes                 IS 'Tracks the changes currently deployed to the database.';
COMMENT ON COLUMN :"registry".changes.change_id       IS 'Change primary key.';
COMMENT ON COLUMN :"registry".changes.script_hash     IS 'Deploy script SHA-1 hash.';
COMMENT ON COLUMN :"registry".changes.change          IS 'Name of a deployed change.';
COMMENT ON COLUMN :"registry".changes.project         IS 'Name of the Sqitch project to which the change belongs.';
COMMENT ON COLUMN :"registry".changes.note            IS 'Description of the change.';
COMMENT ON COLUMN :"registry".changes.committed_at    IS 'Date the change was deployed.';
COMMENT ON COLUMN :"registry".changes.committer_name  IS 'Name of the user who deployed the change.';
COMMENT ON COLUMN :"registry".changes.committer_email IS 'Email address of the user who deployed the change.';
COMMENT ON COLUMN :"registry".changes.planned_at      IS 'Date the change was added to the plan.';
COMMENT ON COLUMN :"registry".changes.planner_name    IS 'Name of the user who planed the change.';
COMMENT ON COLUMN :"registry".changes.planner_email   IS 'Email address of the user who planned the change.';

CREATE TABLE :"registry".tags (
    tag_id          TEXT        PRIMARY KEY,
    "tag"           TEXT        NOT NULL,
    project         TEXT        NOT NULL REFERENCES :"registry".projects(project),
    change_id       TEXT        NOT NULL REFERENCES :"registry".changes(change_id),
    note            TEXT        NOT NULL DEFAULT '',
    committed_at    TIMESTAMP   NOT NULL DEFAULT GETDATE(),
    committer_name  TEXT        NOT NULL,
    committer_email TEXT        NOT NULL,
    planned_at      TIMESTAMP   NOT NULL,
    planner_name    TEXT        NOT NULL,
    planner_email   TEXT        NOT NULL,
    UNIQUE(project, "tag")
):tableopts;

COMMENT ON TABLE  :"registry".tags                 IS 'Tracks the tags currently applied to the database.';
COMMENT ON COLUMN :"registry".tags.tag_id          IS 'Tag primary key.';
COMMENT ON COLUMN :"registry".tags."tag"           IS 'Project-unique tag name.';
COMMENT ON COLUMN :"registry".tags.project         IS 'Name of the Sqitch project to which the tag belongs.';
COMMENT ON COLUMN :"registry".tags.change_id       IS 'ID of last change deployed before the tag was applied.';
COMMENT ON COLUMN :"registry".tags.note            IS 'Description of the tag.';
COMMENT ON COLUMN :"registry".tags.committed_at    IS 'Date the tag was applied to the database.';
COMMENT ON COLUMN :"registry".tags.committer_name  IS 'Name of the user who applied the tag.';
COMMENT ON COLUMN :"registry".tags.committer_email IS 'Email address of the user who applied the tag.';
COMMENT ON COLUMN :"registry".tags.planned_at      IS 'Date the tag was added to the plan.';
COMMENT ON COLUMN :"registry".tags.planner_name    IS 'Name of the user who planed the tag.';
COMMENT ON COLUMN :"registry".tags.planner_email   IS 'Email address of the user who planned the tag.';

CREATE TABLE :"registry".dependencies (
    change_id       TEXT        NOT NULL REFERENCES :"registry".changes(change_id),
    type            TEXT        NOT NULL,
    dependency      TEXT        NOT NULL,
    dependency_id   TEXT            NULL REFERENCES :"registry".changes(change_id),
    PRIMARY KEY (change_id, dependency)
):tableopts;

COMMENT ON TABLE  :"registry".dependencies               IS 'Tracks the currently satisfied dependencies.';
COMMENT ON COLUMN :"registry".dependencies.change_id     IS 'ID of the depending change.';
COMMENT ON COLUMN :"registry".dependencies.type          IS 'Type of dependency.';
COMMENT ON COLUMN :"registry".dependencies.dependency    IS 'Dependency name.';
COMMENT ON COLUMN :"registry".dependencies.dependency_id IS 'Change ID the dependency resolves to.';

CREATE TABLE :"registry".events (
    event           TEXT        NOT NULL,
    change_id       TEXT        NOT NULL,
    change          TEXT        NOT NULL,
    project         TEXT        NOT NULL REFERENCES :"registry".projects(project),
    note            TEXT        NOT NULL DEFAULT '',
    requires        TEXT        NOT NULL DEFAULT '{}',
    conflicts       TEXT        NOT NULL DEFAULT '{}',
    tags            TEXT        NOT NULL DEFAULT '{}',
    committed_at    TIMESTAMP   NOT NULL DEFAULT GETDATE(),
    committer_name  TEXT        NOT NULL,
    committer_email TEXT        NOT NULL,
    planned_at      TIMESTAMP   NOT NULL,
    planner_name    TEXT        NOT NULL,
    planner_email   TEXT        NOT NULL,
    PRIMARY KEY (change_id, committed_at)
):tableopts;

COMMENT ON TABLE  :"registry".events                 IS 'Contains full history of all deployment events.';
COMMENT ON COLUMN :"registry".events.event           IS 'Type of event.';
COMMENT ON COLUMN :"registry".events.change_id       IS 'Change ID.';
COMMENT ON COLUMN :"registry".events.change          IS 'Change name.';
COMMENT ON COLUMN :"registry".events.project         IS 'Name of the Sqitch project to which the change belongs.';
COMMENT ON COLUMN :"registry".events.note            IS 'Description of the change.';
COMMENT ON COLUMN :"registry".events.requires        IS 'Array of the names of required changes.';
COMMENT ON COLUMN :"registry".events.conflicts       IS 'Array of the names of conflicting changes.';
COMMENT ON COLUMN :"registry".events.tags            IS 'Tags associated with the change.';
COMMENT ON COLUMN :"registry".events.committed_at    IS 'Date the event was committed.';
COMMENT ON COLUMN :"registry".events.committer_name  IS 'Name of the user who committed the event.';
COMMENT ON COLUMN :"registry".events.committer_email IS 'Email address of the user who committed the event.';
COMMENT ON COLUMN :"registry".events.planned_at      IS 'Date the event was added to the plan.';
COMMENT ON COLUMN :"registry".events.planner_name    IS 'Name of the user who planed the change.';
COMMENT ON COLUMN :"registry".events.planner_email   IS 'Email address of the user who plan planned the change.';

COMMIT;
