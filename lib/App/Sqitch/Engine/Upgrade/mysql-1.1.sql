DROP INDEX script_hash ON changes;
ALTER TABLE changes ADD UNIQUE(project, script_hash);
