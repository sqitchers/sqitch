ALTER TABLE :"registry".changes DROP CONSTRAINT c_unique;
ALTER TABLE :"registry".changes ADD UNIQUE(project, script_hash);
