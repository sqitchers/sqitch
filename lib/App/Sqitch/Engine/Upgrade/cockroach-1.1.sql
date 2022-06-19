SET client_min_messages = warning;
DROP INDEX :"registry".changes_script_hash_key CASCADE;
ALTER TABLE :"registry".changes ADD UNIQUE (project, script_hash);
COMMENT ON SCHEMA :"registry" IS 'Sqitch database deployment metadata v1.1.';
