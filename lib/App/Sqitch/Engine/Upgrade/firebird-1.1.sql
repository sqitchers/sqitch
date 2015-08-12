SET AUTOddl OFF;

SET TERM ^;
EXECUTE BLOCK AS
    DECLARE uniq VARCHAR(64);
BEGIN
    SELECT TRIM(rdb$constraint_name)
      FROM rdb$relation_constraints
     WHERE rdb$relation_name   = 'CHANGES'
       AND rdb$constraint_type = 'UNIQUE'
      INTO uniq;
    EXECUTE STATEMENT 'ALTER TABLE :prefix:changes DROP CONSTRAINT ' || uniq;
END^

EXECUTE BLOCK AS
    DECLARE trig VARCHAR(64);
BEGIN
    SELECT TRIM(cc.rdb$constraint_name)
      FROM rdb$relation_constraints rc
      JOIN rdb$check_constraints cc ON rc.rdb$constraint_name = cc.rdb$constraint_name
      JOIN rdb$triggers trg         ON cc.rdb$trigger_name       = trg.rdb$trigger_name
     WHERE rc.rdb$relation_name   = UPPER(':prefix:dependencies')
       AND rc.rdb$constraint_type = 'CHECK'
       AND trg.rdb$trigger_type   = 1
      INTO trig;
    EXECUTE STATEMENT 'ALTER TABLE :prefix:dependencies DROP CONSTRAINT ' || trig;
END^

SET TERM ;^
COMMIT;

-- Drop check_event_type; we give it a new name below.
ALTER TABLE :prefix:events DROP CONSTRAINT check_event_type;
COMMIT;

-- Create the new unique constraint.
ALTER TABLE :prefix:changes ADD UNIQUE (project, script_hash);

-- Give the check constraints name consistent with other engines.
ALTER TABLE :prefix:dependencies ADD CONSTRAINT dependencies_check CHECK (
       (type = 'require'  AND dependency_id IS NOT NULL)
    OR (type = 'conflict' AND dependency_id IS NULL)
);

ALTER TABLE :prefix:events ADD CONSTRAINT events_event_check CHECK (
    event IN ('deploy', 'revert', 'fail', 'merge')
);

COMMIT;
