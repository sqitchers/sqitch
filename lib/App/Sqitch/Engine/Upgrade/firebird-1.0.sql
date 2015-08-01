SET AUTOddl OFF;

CREATE TABLE releases (
    version         FLOAT         NOT NULL PRIMARY KEY,
    installed_at    TIMESTAMP     DEFAULT CURRENT_TIMESTAMP NOT NULL,
    installer_name  VARCHAR(255)  NOT NULL,
    installer_email VARCHAR(255)  NOT NULL
);

COMMENT ON TABLE  releases                 IS 'Sqitch registry releases.';
COMMENT ON COLUMN releases.version         IS 'Version of the Sqitch registry.';
COMMENT ON COLUMN releases.installed_at    IS 'Date the registry release was installed.';
COMMENT ON COLUMN releases.installer_name  IS 'Name of the user who installed the registry release.';
COMMENT ON COLUMN releases.installer_email IS 'Email address of the user who installed the registry release.';

-- Add the script_hash column to the changes table.
ALTER TABLE changes ADD script_hash VARCHAR(40) UNIQUE;
COMMIT;
UPDATE changes SET script_hash = change_id;
COMMENT ON COLUMN changes.script_hash IS 'Deploy script SHA-1 hash.';

-- Allow "merge" events.
SET TERM ^;
EXECUTE BLOCK AS
    DECLARE trig VARCHAR(64);
BEGIN
    SELECT TRIM(cc.rdb$constraint_name)
      FROM rdb$relation_constraints rc
      JOIN rdb$check_constraints cc ON rc.rdb$constraint_name = cc.rdb$constraint_name
      JOIN rdb$triggers trg         ON cc.rdb$trigger_name       = trg.rdb$trigger_name
     WHERE rc.rdb$relation_name   = 'EVENTS'
       AND rc.rdb$constraint_type = 'CHECK'
       AND trg.rdb$trigger_type   = 1
      INTO trig;
    EXECUTE STATEMENT 'ALTER TABLE EVENTS DROP CONSTRAINT ' || trig;
END^

SET TERM ;^
COMMIT;

ALTER TABLE events ADD CONSTRAINT check_event_type CHECK (
    event IN ('deploy', 'revert', 'fail', 'merge')
);

COMMIT;
