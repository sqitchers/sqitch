ALTER TABLE :"registry".changes DROP CONSTRAINT c_unique;
ALTER TABLE :"registry".changes ADD UNIQUE(project, script_hash);
COMMENT ON SCHEMA :"registry" IS 'Sqitch database deployment metadata v1.1.';
