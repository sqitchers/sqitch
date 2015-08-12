DROP INDEX script_hash ON :prefix:changes;
ALTER TABLE :prefix:changes ADD UNIQUE(project, script_hash);
