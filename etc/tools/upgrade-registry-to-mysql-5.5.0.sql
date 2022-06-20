-- This script upgrades the Sqitch registry for MySQL 5.5.0 and higher. It
-- creates the checkit() function and sets up triggers in the registry to use
-- it to emulate CHECK constraints. It will then also be available for use in
-- verify scripts, as described in sqitchtutorial-mysql. If you have an
-- existing Sqitch registry that was upgraded from an earlier version of MySQL
-- to 5.5.0 or higher, you'll need to run this script to update it, like so:

--      mysql -u root sqitch --execute "source `sqitch --etc`/tools/upgrade-registry-to-mysql-5.5.0.sql'

DELIMITER |

CREATE FUNCTION checkit(doit INTEGER, message VARCHAR(256)) RETURNS INTEGER DETERMINISTIC
BEGIN
    IF doit IS NULL OR doit = 0 THEN
        SIGNAL SQLSTATE 'ERR0R' SET MESSAGE_TEXT = message;
    END IF;
    RETURN doit;
END;
|

CREATE TRIGGER ck_insert_dependency BEFORE INSERT ON dependencies
FOR EACH ROW BEGIN
    -- DO does not work. https://bugs.mysql.com/bug.php?id=69647
    SET @dummy := checkit(
            (NEW.type = 'require'  AND NEW.dependency_id IS NOT NULL)
         OR (NEW.type = 'conflict' AND NEW.dependency_id IS NULL),
        'Type must be "require" with dependency_id set or "conflict" with dependency_id not set'
    );
END;
|

CREATE TRIGGER ck_update_dependency BEFORE UPDATE ON dependencies
FOR EACH ROW BEGIN
    -- DO does not work. https://bugs.mysql.com/bug.php?id=69647
    SET @dummy := checkit(
            (NEW.type = 'require'  AND NEW.dependency_id IS NOT NULL)
         OR (NEW.type = 'conflict' AND NEW.dependency_id IS NULL),
        'Type must be "require" with dependency_id set or "conflict" with dependency_id not set'
    );
END;
|

DELIMITER ;
