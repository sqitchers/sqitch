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

DECLARE
    CURSOR c_event_constraints IS
        SELECT constraint_name
          FROM user_cons_columns
         WHERE table_name = 'EVENTS' AND column_name = 'EVENT';
    rec_consname c_event_constraints%ROWTYPE;
BEGIN
    OPEN c_event_constraints;
    LOOP
        FETCH c_event_constraints INTO rec_consname;
        IF c_event_constraints%NOTFOUND THEN EXIT; END IF;

        -- Drop the constraint.
        EXECUTE IMMEDIATE 'ALTER TABLE &registry..events DROP CONSTRAINT '
                       || rec_consname.constraint_name;
    END LOOP;
    CLOSE c_event_constraints;

    -- Use EXECUTE IMMEDIATE because ALTER isn't allowed in PL/SQL.
    EXECUTE IMMEDIATE 'ALTER TABLE &registry..events MODIFY event NOT NULL';
    EXECUTE IMMEDIATE 'ALTER TABLE &registry..events ADD CONSTRAINT check_event_type CHECK (event IN (''deploy'', ''revert'', ''fail'', ''merge''))';
END;
/
