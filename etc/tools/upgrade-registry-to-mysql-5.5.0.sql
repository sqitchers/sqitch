-- This script upgrades the Sqitch registry for MySQL 5.5.0 and higher. It
-- sets up triggers in the registry to use it to emulate CHECK constraints. If
-- you have an existing Sqitch registry that was upgraded from an earlier
-- version of MySQL to 5.5.0 or higher, you'll need to run this script as a
-- super user to update it, like so:

--      mysql -u root sqitch --execute "source `sqitch --etc`/tools/upgrade-registry-to-mysql-5.5.0.sql'

DELIMITER |
CREATE TRIGGER ck_insert_dependency BEFORE INSERT ON dependencies
FOR EACH ROW BEGIN
    IF (NEW.type = 'require' AND NEW.dependency_id IS NULL)
    OR (NEW.type = 'conflict' AND NEW.dependency_id IS NOT NULL)
    THEN
        SIGNAL SQLSTATE 'ERR0R' SET MESSAGE_TEXT = 'Type must be "require" with dependency_id set or "conflict" with dependency_id not set';
    END IF;
END;
|

CREATE TRIGGER ck_update_dependency BEFORE UPDATE ON dependencies
FOR EACH ROW BEGIN
    IF (NEW.type = 'require'  AND NEW.dependency_id IS NULL)
    OR (NEW.type = 'conflict' AND NEW.dependency_id IS NOT NULL)
    THEN
        SIGNAL SQLSTATE 'ERR0R' SET MESSAGE_TEXT = 'Type must be "require" with dependency_id set or "conflict" with dependency_id not set';
    END IF;
END;
|

DELIMITER ;
