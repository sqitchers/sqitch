BEGIN;

SET client_min_messages = warning;
ALTER TABLE :"registry".changes DROP CONSTRAINT changes_script_hash_key;
ALTER TABLE :"registry".changes ADD UNIQUE (project, script_hash);

COMMIT;
