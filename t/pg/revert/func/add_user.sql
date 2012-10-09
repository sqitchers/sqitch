-- Revert func/add_user

BEGIN;

DROP FUNCTION __myapp.add_user(TEXT, TEXT);

COMMIT;
