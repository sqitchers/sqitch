CREATE TABLE releases (
    version         REAL COMMENT 'Version of the Sqitch registry.' PRIMARY KEY,
    installed_at    DATETIME64(6, 'UTC') NOT NULL DEFAULT now64(6, 'UTC')
                    COMMENT 'Date the registry release was installed.',
    installer_name  TEXT                 NOT NULL
                    COMMENT 'Name of the user who installed the registry release.',
    installer_email TEXT                 NOT NULL
                    COMMENT 'Email address of the user who installed the registry release.'
) ENGINE = MergeTree
  SETTINGS enable_block_number_column = 1, enable_block_offset_column = 1
  COMMENT 'Sqitch registry releases.';

-- Add the script_hash column to the changes table. Copy change_id for now.
ALTER TABLE changes ADD COLUMN script_hash TEXT COMMENT 'Deploy script SHA-1 hash.';
UPDATE changes SET script_hash = change_id WHERE TRUE;

-- Allow "merge" events.
ALTER TABLE events DROP CONSTRAINT IF EXISTS events_event_check;
ALTER TABLE events ADD  CONSTRAINT events_event_check
      CHECK (event IN ('deploy', 'revert', 'fail', 'merge'));
