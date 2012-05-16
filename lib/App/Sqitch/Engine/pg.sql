BEGIN;

SET client_min_messages = warning;
CREATE SCHEMA :"sqitch_schema";

COMMENT ON SCHEMA :"sqitch_schema" IS 'Sqitch database deployment metadata v1.0.';

CREATE TABLE :"sqitch_schema".tags (
    tag_id     SERIAL      PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    applied_by TEXT        NOT NULL DEFAULT current_user
);

COMMENT ON TABLE :"sqitch_schema".tags
IS 'Tracks the tags currently applied to the database.';
COMMENT ON COLUMN :"sqitch_schema".tags.tag_id     IS 'Tag ID.';
COMMENT ON COLUMN :"sqitch_schema".tags.applied_at IS 'Date the tag was applied to the database.';
COMMENT ON COLUMN :"sqitch_schema".tags.applied_by IS 'Name  of the user who applied the tag.';

CREATE TABLE :"sqitch_schema".tag_names (
    tag_name TEXT    PRIMARY KEY,
    tag_id   INTEGER NOT NULL REFERENCES :"sqitch_schema".tags(tag_id)
                              ON DELETE CASCADE
);

COMMENT ON TABLE :"sqitch_schema".tag_names
IS 'Tracks the names of tags currently applied to the database.';
COMMENT ON COLUMN :"sqitch_schema".tag_names.tag_name IS 'Unique tag name.';
COMMENT ON COLUMN :"sqitch_schema".tag_names.tag_id   IS 'Tag ID.';

CREATE TABLE :"sqitch_schema".steps (
    step        TEXT        NOT NULL,
    tag_id      INTEGER     NOT NULL REFERENCES :"sqitch_schema".tags(tag_id),
    deployed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deployed_by TEXT        NOT NULL DEFAULT current_user,
    requires    TEXT[]      NOT NULL DEFAULT '{}',
    conflicts   TEXT[]      NOT NULL DEFAULT '{}',
    PRIMARY KEY (step, tag_id)
);

COMMENT ON TABLE :"sqitch_schema".steps
IS 'Tracks the steps currently deployed to the database.';
COMMENT ON COLUMN :"sqitch_schema".steps.step        IS 'Name of a deployed step.';
COMMENT ON COLUMN :"sqitch_schema".steps.tag_id      IS 'ID of the associated tag.';
COMMENT ON COLUMN :"sqitch_schema".steps.requires    IS 'Array of the names of prerequisite steps.';
COMMENT ON COLUMN :"sqitch_schema".steps.conflicts   IS 'Array of the names of conflicting steps.';
COMMENT ON COLUMN :"sqitch_schema".steps.deployed_at IS 'Date the step was deployed.';
COMMENT ON COLUMN :"sqitch_schema".steps.deployed_by IS 'Name of the user who deployed the step';

CREATE TABLE :"sqitch_schema".events (
    event     TEXT        NOT NULL CHECK (event IN ('deploy', 'revert', 'fail', 'apply', 'remove')),
    step      TEXT        NOT NULL DEFAULT '',
    tags      TEXT[]      NOT NULL,
    logged_by TEXT        NOT NULL DEFAULT current_user,
    logged_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

COMMENT ON TABLE :"sqitch_schema".events
IS 'Contains full history of all deployment events.';
COMMENT ON COLUMN :"sqitch_schema".events.event     IS 'Type of event.';
COMMENT ON COLUMN :"sqitch_schema".events.step      IS 'Name of the event step.';
COMMENT ON COLUMN :"sqitch_schema".events.tags      IS 'Array of event tag names.';
COMMENT ON COLUMN :"sqitch_schema".events.logged_at IS 'Date the event.';
COMMENT ON COLUMN :"sqitch_schema".events.logged_by IS 'Name of the user who logged the event.';

COMMIT;
