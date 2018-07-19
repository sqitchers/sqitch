BEGIN;
ALTER TABLE &registry.changes DROP UNIQUE(script_hash);
ALTER TABLE &registry.changes ADD UNIQUE(project, script_hash);
COMMIT;
