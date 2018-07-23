ALTER TABLE &registry.changes DROP UNIQUE(script_hash);
ALTER TABLE &registry.changes ADD UNIQUE(project, script_hash);
COMMENT ON SCHEMA &registry IS 'Sqitch database deployment metadata v1.0.';
