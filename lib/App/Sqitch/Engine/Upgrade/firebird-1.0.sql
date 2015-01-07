CREATE TABLE releases (
    version         FLOAT         NOT NULL PRIMARY KEY,
    installed_at    TIMESTAMP     DEFAULT CURRENT_TIMESTAMP NOT NULL,
    installer_name  VARCHAR(255)  NOT NULL,
    installer_email VARCHAR(255)  NOT NULL
);

UPDATE RDB$RELATIONS SET
    RDB$DESCRIPTION = 'Sqitch registry releases.'
    WHERE RDB$RELATION_NAME = 'RELEASES';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Version of the Sqitch registry.'
    WHERE RDB$RELATION_NAME = 'RELEASES' AND RDB$FIELD_NAME = 'VERSION';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Date the registry release was installed.'
    WHERE RDB$RELATION_NAME = 'VERSIONS' AND RDB$FIELD_NAME = 'INSTALLED_AT';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Name of the user who installed the registry release.'
    WHERE RDB$RELATION_NAME = 'VERSIONS' AND RDB$FIELD_NAME = 'INSTALLER_NAME';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Email address of the user who installed the registry release.'
    WHERE RDB$RELATION_NAME = 'VERSIONS' AND RDB$FIELD_NAME = 'INSTALLER_EMAIL';

-- Add the script_hash column to the changes table.
ALTER TABLE changes ADD script_hash VARCHAR(40) UNIQUE;
UPDATE changes SET script_hash = change_id;
UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Deploy script SHA-1 hash.'
    WHERE RDB$RELATION_NAME = 'CHANGES' AND RDB$FIELD_NAME = 'SCRIPT_HASH';
