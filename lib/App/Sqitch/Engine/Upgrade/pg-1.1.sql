BEGIN;

ALTER TABLE :"registry".changes DROP CONSTRAINT changes_script_hash_key;
ALTER TABLE :"registry".changes ADD CONSTRAINT  changes_script_hash_key
            UNIQUE (project, script_hash);

COMMIT;
