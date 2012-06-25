BEGIN;

SET client_min_messages = warning;
CREATE SCHEMA :"sqitch_schema";

COMMENT ON SCHEMA :"sqitch_schema" IS 'Sqitch database deployment metadata v1.0.';

CREATE TABLE :"sqitch_schema".steps (
    step_id     TEXT        PRIMARY KEY,
    step        TEXT        NOT NULL,
    requires    TEXT[]      NOT NULL DEFAULT '{}',
    conflicts   TEXT[]      NOT NULL DEFAULT '{}',
    deployed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deployed_by TEXT        NOT NULL DEFAULT current_user
);

COMMENT ON TABLE :"sqitch_schema".steps
IS 'Tracks the steps currently deployed to the database.';
COMMENT ON COLUMN :"sqitch_schema".steps.step_id     IS 'Step primary key.';
COMMENT ON COLUMN :"sqitch_schema".steps.step        IS 'Name of a deployed step.';
COMMENT ON COLUMN :"sqitch_schema".steps.requires    IS 'Array of the names of required steps.';
COMMENT ON COLUMN :"sqitch_schema".steps.conflicts   IS 'Array of the names of conflicting steps.';
COMMENT ON COLUMN :"sqitch_schema".steps.deployed_at IS 'Date the step was deployed.';
COMMENT ON COLUMN :"sqitch_schema".steps.deployed_by IS 'Name of the user who deployed the step';

CREATE TABLE :"sqitch_schema".tags (
    tag_id     TEXT        PRIMARY KEY,
    tag        TEXT        NOT NULL UNIQUE,
    step_id    TEXT        NOT NULL REFERENCES :"sqitch_schema".steps(step_id),
    applied_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    applied_by TEXT        NOT NULL DEFAULT current_user
);

COMMENT ON TABLE :"sqitch_schema".tags
IS 'Tracks the tags currently applied to the database.';
COMMENT ON COLUMN :"sqitch_schema".tags.tag_id     IS 'Tag primary key';
COMMENT ON COLUMN :"sqitch_schema".tags.tag        IS 'Unique tag name.';
COMMENT ON COLUMN :"sqitch_schema".tags.step_id    IS 'ID of last step deployed before the tag was applied';
COMMENT ON COLUMN :"sqitch_schema".tags.applied_at IS 'Date the tag was applied to the database.';
COMMENT ON COLUMN :"sqitch_schema".tags.applied_by IS 'Name  of the user who applied the tag.';

CREATE TABLE :"sqitch_schema".events (
    event     TEXT        NOT NULL CHECK (event IN ('deploy', 'revert', 'fail')),
    step_id   TEXT        NOT NULL,
    step      TEXT        NOT NULL,
    tags      TEXT[]      NOT NULL DEFAULT '{}',
    logged_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    logged_by TEXT        NOT NULL DEFAULT current_user
);

COMMENT ON TABLE :"sqitch_schema".events
IS 'Contains full history of all deployment events.';
COMMENT ON COLUMN :"sqitch_schema".events.event     IS 'Type of event.';
COMMENT ON COLUMN :"sqitch_schema".events.step_id   IS 'Step ID';
COMMENT ON COLUMN :"sqitch_schema".events.step      IS 'Step name.';
COMMENT ON COLUMN :"sqitch_schema".events.tags      IS 'Tags associated with the step';
COMMENT ON COLUMN :"sqitch_schema".events.logged_at IS 'Date the event.';
COMMENT ON COLUMN :"sqitch_schema".events.logged_by IS 'Name of the user who logged the event.';

COMMIT;
