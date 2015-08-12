CREATE TABLE :prefix:releases (
    version         FLOAT         PRIMARY KEY
                    COMMENT 'Version of the Sqitch registry.',
    installed_at    TIMESTAMP     NOT NULL
                    COMMENT 'Date the registry release was installed.',
    installer_name  VARCHAR(255)  NOT NULL
                    COMMENT 'Name of the user who installed the registry release.',
    installer_email VARCHAR(255)  NOT NULL
                    COMMENT 'Email address of the user who installed the registry release.'
) ENGINE  InnoDB,
  CHARACTER SET 'utf8',
  COMMENT 'Sqitch registry releases.'
;

-- Add the script_hash column to the changes table. Copy change_id for now.
ALTER TABLE :prefix:changes ADD COLUMN script_hash VARCHAR(40) NULL UNIQUE AFTER change_id;
UPDATE :prefix:changes SET script_hash = change_id;

-- Allow "merge" events.
ALTER TABLE :prefix:events CHANGE event event ENUM ('deploy', 'fail', 'merge', 'revert') NOT NULL;
