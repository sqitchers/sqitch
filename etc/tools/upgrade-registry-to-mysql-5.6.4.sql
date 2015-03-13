-- This script upgrades the Sqitch registry for MySQL 5.6.4 and higher. Sqitch
-- expects datetime columns to have a precision on 5.6.4 and higher. If you have
-- an existing Sqitch registry that was upgraded from an earlier version of MySQL
-- to 5.6.4 or highher, you'll need to run this script to update it, like so:

--      mysql -u root sqitch --execute "source `sqitch --etc`/tools/upgrade-registry-to-mysql-5.6.4.sql'

ALTER TABLE releases CHANGE installed_at installed_at DATETIME(6) NOT NULL;
ALTER TABLE projects CHANGE created_at   created_at   DATETIME(6) NOT NULL;
ALTER TABLE changes  CHANGE committed_at committed_at DATETIME(6) NOT NULL,
                     CHANGE planned_at   planned_at   DATETIME(6) NOT NULL;
ALTER TABLE tags     CHANGE committed_at committed_at DATETIME(6) NOT NULL,
                     CHANGE planned_at   planned_at   DATETIME(6) NOT NULL;
ALTER TABLE events   CHANGE committed_at committed_at DATETIME(6) NOT NULL,
                     CHANGE planned_at   planned_at   DATETIME(6) NOT NULL;
