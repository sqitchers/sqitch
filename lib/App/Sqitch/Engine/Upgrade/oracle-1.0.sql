CREATE TABLE &registry..releases (
    version           FLOAT                    PRIMARY KEY,
    installed_at      TIMESTAMP WITH TIME ZONE DEFAULT current_timestamp NOT NULL,
    installer_name    VARCHAR2(512 CHAR)       NOT NULL,
    installer_email   VARCHAR2(512 CHAR)       NOT NULL
);

COMMENT ON TABLE  &registry..releases                 IS 'Sqitch registry releases.';
COMMENT ON COLUMN &registry..releases.version         IS 'Version of the Sqitch registry.';
COMMENT ON COLUMN &registry..releases.installed_at    IS 'Date the registry release was installed.';
COMMENT ON COLUMN &registry..releases.installer_name  IS 'Name of the user who installed the registry release.';
COMMENT ON COLUMN &registry..releases.installer_email IS 'Email address of the user who installed the registry release.';

-- Add the script_hash column to the changes table. Copy change_id for now.
ALTER TABLE &registry..changes ADD script_hash CHAR(40) NULL UNIQUE;
UPDATE &registry..changes SET script_hash = change_id;
COMMENT ON COLUMN &registry..changes.script_hash IS 'Deploy script SHA-1 hash.';

-- Allow "merge" events.
SELECT CONSTRAINT_NAME
  FROM user_constraints
 WHERE table_name = 'EVENTS'
   AND SEARCH_CONDITION_VC = 'event IN (''deploy'', ''revert'', ''fail'')';

-- Fetch the name of the event check constraint.
-- http://www.orafaq.com/node/515
COLUMN cname for a30 new_value check_name;
SELECT CONSTRAINT_NAME AS cname
  FROM user_constraints
 WHERE table_name = 'EVENTS'
   AND SEARCH_CONDITION_VC = 'event IN (''deploy'', ''revert'', ''fail'')';

-- Allow "merge" events.
ALTER TABLE &registry..events DROP CONSTRAINT &check_name;
ALTER TABLE &registry..events ADD  CONSTRAINT &check_name
      CHECK (event IN ('deploy', 'revert', 'fail', 'merge'));
