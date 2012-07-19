BEGIN;

SET client_min_messages = warning;
CREATE SCHEMA :"sqitch_schema";

COMMENT ON SCHEMA :"sqitch_schema" IS 'Sqitch database deployment metadata v1.0.';

CREATE TABLE :"sqitch_schema".changes (
    change_id       TEXT        PRIMARY KEY,
    change          TEXT        NOT NULL,
    requires        TEXT[]      NOT NULL DEFAULT '{}',
    conflicts       TEXT[]      NOT NULL DEFAULT '{}',
    committed_at    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    committer_name  TEXT        NOT NULL,
    committer_email TEXT        NOT NULL,
    planned_at      TIMESTAMPTZ NOT NULL,
    planner_name    TEXT        NOT NULL,
    planner_email   TEXT        NOT NULL
);

COMMENT ON TABLE :"sqitch_schema".changes
IS 'Tracks the changes currently deployed to the database.';
COMMENT ON COLUMN :"sqitch_schema".changes.change_id       IS 'Change primary key.';
COMMENT ON COLUMN :"sqitch_schema".changes.change          IS 'Name of a deployed change.';
COMMENT ON COLUMN :"sqitch_schema".changes.requires        IS 'Array of the names of required changes.';
COMMENT ON COLUMN :"sqitch_schema".changes.conflicts       IS 'Array of the names of conflicting changes.';
COMMENT ON COLUMN :"sqitch_schema".changes.committed_at    IS 'Date the change was deployed.';
COMMENT ON COLUMN :"sqitch_schema".changes.committer_name  IS 'Name of the user who deployed the change';
COMMENT ON COLUMN :"sqitch_schema".changes.committer_email IS 'Email address of the user who deployed the change';
COMMENT ON COLUMN :"sqitch_schema".changes.planned_at      IS 'Date the change was added to the plan.';
COMMENT ON COLUMN :"sqitch_schema".changes.planner_name    IS 'Name of the user who planed the change.';
COMMENT ON COLUMN :"sqitch_schema".changes.planner_email   IS 'Email address of the user who planned the change.';

CREATE TABLE :"sqitch_schema".tags (
    tag_id          TEXT        PRIMARY KEY,
    tag             TEXT        NOT NULL UNIQUE,
    change_id       TEXT        NOT NULL REFERENCES :"sqitch_schema".changes(change_id),
    committed_at    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    committer_name  TEXT        NOT NULL,
    committer_email TEXT        NOT NULL,
    planned_at      TIMESTAMPTZ NOT NULL,
    planner_name    TEXT        NOT NULL,
    planner_email   TEXT        NOT NULL
);

COMMENT ON TABLE :"sqitch_schema".tags
IS 'Tracks the tags currently applied to the database.';
COMMENT ON COLUMN :"sqitch_schema".tags.tag_id          IS 'Tag primary key';
COMMENT ON COLUMN :"sqitch_schema".tags.tag             IS 'Unique tag name.';
COMMENT ON COLUMN :"sqitch_schema".tags.change_id       IS 'ID of last change deployed before the tag was applied';
COMMENT ON COLUMN :"sqitch_schema".tags.committed_at    IS 'Date the tag was applied to the database.';
COMMENT ON COLUMN :"sqitch_schema".tags.committer_name  IS 'Name of the user who applied the tag.';
COMMENT ON COLUMN :"sqitch_schema".tags.committer_email IS 'Email address of the user who applied the tag.';
COMMENT ON COLUMN :"sqitch_schema".tags.planned_at      IS 'Date the tag was added to the plan.';
COMMENT ON COLUMN :"sqitch_schema".tags.planner_name    IS 'Name of the user who planed the tag.';
COMMENT ON COLUMN :"sqitch_schema".tags.planner_email   IS 'Email address of the user who planned the tag.';

CREATE TABLE :"sqitch_schema".events (
    event           TEXT        NOT NULL CHECK (event IN ('deploy', 'revert', 'fail')),
    change_id       TEXT        NOT NULL,
    change          TEXT        NOT NULL,
    requires        TEXT[]      NOT NULL DEFAULT '{}',
    conflicts       TEXT[]      NOT NULL DEFAULT '{}',
    tags            TEXT[]      NOT NULL DEFAULT '{}',
    committed_at    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    committer_name  TEXT        NOT NULL,
    committer_email TEXT        NOT NULL,
    planned_at      TIMESTAMPTZ NOT NULL,
    planner_name    TEXT        NOT NULL,
    planner_email   TEXT        NOT NULL
);

COMMENT ON TABLE :"sqitch_schema".events
IS 'Contains full history of all deployment events.';
COMMENT ON COLUMN :"sqitch_schema".events.event           IS 'Type of event.';
COMMENT ON COLUMN :"sqitch_schema".events.change_id       IS 'Change ID';
COMMENT ON COLUMN :"sqitch_schema".events.change          IS 'Change name.';
COMMENT ON COLUMN :"sqitch_schema".events.requires        IS 'Array of the names of required changes.';
COMMENT ON COLUMN :"sqitch_schema".events.conflicts       IS 'Array of the names of conflicting changes.';
COMMENT ON COLUMN :"sqitch_schema".events.tags            IS 'Tags associated with the change';
COMMENT ON COLUMN :"sqitch_schema".events.committed_at    IS 'Date the event was committed.';
COMMENT ON COLUMN :"sqitch_schema".events.committer_name  IS 'Name of the user who committed the event.';
COMMENT ON COLUMN :"sqitch_schema".events.committer_email IS 'Email address of the user who committed the event.';
COMMENT ON COLUMN :"sqitch_schema".events.planned_at      IS 'Date the event was added to the plan.';
COMMENT ON COLUMN :"sqitch_schema".events.planner_name    IS 'Name of the user who planed the change.';
COMMENT ON COLUMN :"sqitch_schema".events.planner_email   IS 'Email address of the user who plan planned the change.';

COMMIT;
