BEGIN;

SET client_min_messages = warning;
CREATE SCHEMA :"sqitch_schema";

COMMENT ON SCHEMA :"sqitch_schema" IS 'Sqitch database deployment metadata v1.0.';

CREATE TABLE :"sqitch_schema".steps (
    sha1        TEXT        PRIMARY KEY,
    step        TEXT        NOT NULL,
    deployed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    deployed_by TEXT        NOT NULL DEFAULT current_user,
    requires    TEXT[]      NOT NULL DEFAULT '{}',
    conflicts   TEXT[]      NOT NULL DEFAULT '{}',
    body        BYTEA       NOT NULL
);

COMMENT ON TABLE :"sqitch_schema".steps
IS 'Tracks the steps currently deployed to the database.';
COMMENT ON COLUMN :"sqitch_schema".steps.sah1        IS 'Step primary key.';
COMMENT ON COLUMN :"sqitch_schema".steps.step        IS 'Name of a deployed step.';
COMMENT ON COLUMN :"sqitch_schema".steps.requires    IS 'Array of the names of prerequisite steps.';
COMMENT ON COLUMN :"sqitch_schema".steps.conflicts   IS 'Array of the names of conflicting steps.';
COMMENT ON COLUMN :"sqitch_schema".steps.deployed_at IS 'Date the step was deployed.';
COMMENT ON COLUMN :"sqitch_schema".steps.deployed_by IS 'Name of the user who deployed the step';

CREATE TABLE :"sqitch_schema".tags (
    tag        TEXT        PRIMARY KEY,
    step_sha1  TEXT        NOT NULL REFERENCES :"sqitch_schema".steps(sha1),
    applied_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    applied_by TEXT        NOT NULL DEFAULT current_user
);

COMMENT ON TABLE :"sqitch_schema".tags
IS 'Tracks the tags currently applied to the database.';
COMMENT ON COLUMN :"sqitch_schema".tags.tag        IS 'Unique tag name.';
COMMENT ON COLUMN :"sqitch_schema".tags.step_sha1  IS 'SHA1 of last step deployed before the tag was applied';
COMMENT ON COLUMN :"sqitch_schema".tags.applied_at IS 'Date the tag was applied to the database.';
COMMENT ON COLUMN :"sqitch_schema".tags.applied_by IS 'Name  of the user who applied the tag.';

CREATE TABLE :"sqitch_schema".events (
    event     TEXT        NOT NULL CHECK (event IN ('deploy', 'revert', 'fail', 'apply', 'remove')),
    node      TEXT        NOT NULL,
    logged_by TEXT        NOT NULL DEFAULT current_user,
    logged_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

COMMENT ON TABLE :"sqitch_schema".events
IS 'Contains full history of all deployment events.';
COMMENT ON COLUMN :"sqitch_schema".events.event     IS 'Type of event.';
COMMENT ON COLUMN :"sqitch_schema".events.node      IS 'Name of the event node.';
COMMENT ON COLUMN :"sqitch_schema".events.logged_at IS 'Date the event.';
COMMENT ON COLUMN :"sqitch_schema".events.logged_by IS 'Name of the user who logged the event.';

COMMIT;
