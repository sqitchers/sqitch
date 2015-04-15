SET TERM ^;
EXECUTE BLOCK AS
    DECLARE uniq VARCHAR(64);
BEGIN
    SELECT TRIM(rdb$constraint_name)
      FROM rdb$relation_constraints
     WHERE rdb$relation_name   = 'CHANGES'
       AND rdb$constraint_type = 'UNIQUE'
      INTO uniq;
    EXECUTE STATEMENT 'ALTER TABLE CHANGES DROP CONSTRAINT ' || uniq;
END^

SET TERM ;^
COMMIT;

ALTER TABLE changes ADD CONSTRAINT changes_script_hash_unique UNIQUE (project, script_hash);

