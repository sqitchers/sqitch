BEGIN;

SET SESSION sql_mode = ansi;

CREATE TABLE :prefix:releases (
    version         FLOAT(4, 1)   PRIMARY KEY
                    COMMENT 'Version of the Sqitch registry.',
    installed_at    DATETIME(6)   NOT NULL
                    COMMENT 'Date the registry release was installed.',
    installer_name  VARCHAR(255)  NOT NULL
                    COMMENT 'Name of the user who installed the registry release.',
    installer_email VARCHAR(255)  NOT NULL
                    COMMENT 'Email address of the user who installed the registry release.'
) ENGINE  InnoDB,
  CHARACTER SET 'utf8',
  COMMENT 'Sqitch registry releases.'
;

CREATE TABLE :prefix:projects (
    project         VARCHAR(255) PRIMARY KEY
                    COMMENT 'Unique Name of a project.',
    uri             VARCHAR(255) NULL UNIQUE
                    COMMENT 'Optional project URI',
    created_at      DATETIME(6)  NOT NULL
                    COMMENT 'Date the project was added to the database.',
    creator_name    VARCHAR(255) NOT NULL
                    COMMENT 'Name of the user who added the project.',
    creator_email   VARCHAR(255) NOT NULL
                    COMMENT 'Email address of the user who added the project.'
) ENGINE  InnoDB,
  CHARACTER SET 'utf8',
  COMMENT 'Sqitch projects deployed to this database.'
;

CREATE TABLE :prefix:changes (
    change_id       VARCHAR(40)  PRIMARY KEY
                    COMMENT 'Change primary key.',
    script_hash     VARCHAR(40)      NULL
                    COMMENT 'Deploy script SHA-1 hash.',
    "change"        VARCHAR(255) NOT NULL
                    COMMENT 'Name of a deployed change.',
    project         VARCHAR(255) NOT NULL
                    COMMENT 'Name of the Sqitch project to which the change belongs.'
                    REFERENCES :prefix:projects(project) ON UPDATE CASCADE,
    note            TEXT         NOT NULL
                    COMMENT 'Description of the change.',
    committed_at    DATETIME(6)  NOT NULL
                    COMMENT 'Date the change was deployed.',
    committer_name  VARCHAR(255) NOT NULL
                    COMMENT 'Name of the user who deployed the change.',
    committer_email VARCHAR(255) NOT NULL
                    COMMENT 'Email address of the user who deployed the change.',
    planned_at      DATETIME(6)  NOT NULL
                    COMMENT 'Date the change was added to the plan.',
    planner_name    VARCHAR(255) NOT NULL
                    COMMENT 'Name of the user who planed the change.',
    planner_email   VARCHAR(255) NOT NULL
                    COMMENT 'Email address of the user who planned the change.',
    UNIQUE(project, script_hash)
) ENGINE  InnoDB,
  CHARACTER SET 'utf8',
  COMMENT 'Tracks the changes currently deployed to the database.'
;

CREATE TABLE :prefix:tags (
    tag_id          VARCHAR(40)  PRIMARY KEY
                    COMMENT 'Tag primary key.',
    tag             VARCHAR(255) NOT NULL
                    COMMENT 'Project-unique tag name.',
    project         VARCHAR(255) NOT NULL
                    COMMENT 'Name of the Sqitch project to which the tag belongs.'
                    REFERENCES :prefix:projects(project) ON UPDATE CASCADE,
    change_id       VARCHAR(40)  NOT NULL
                    COMMENT 'ID of last change deployed before the tag was applied.'
                    REFERENCES :prefix:changes(change_id) ON UPDATE CASCADE,
    note            VARCHAR(255) NOT NULL
                    COMMENT 'Description of the tag.',
    committed_at    DATETIME(6)  NOT NULL
                    COMMENT 'Date the tag was applied to the database.',
    committer_name  VARCHAR(255) NOT NULL
                    COMMENT 'Name of the user who applied the tag.',
    committer_email VARCHAR(255) NOT NULL
                    COMMENT 'Email address of the user who applied the tag.',
    planned_at      DATETIME(6)  NOT NULL
                    COMMENT 'Date the tag was added to the plan.',
    planner_name    VARCHAR(255) NOT NULL
                    COMMENT 'Name of the user who planed the tag.',
    planner_email   VARCHAR(255) NOT NULL
                    COMMENT 'Email address of the user who planned the tag.',
    UNIQUE(project, tag)
) ENGINE  InnoDB,
  CHARACTER SET 'utf8',
  COMMENT 'Tracks the tags currently applied to the database.'
;

CREATE TABLE :prefix:dependencies (
    change_id       VARCHAR(40)  NOT NULL
                    COMMENT 'ID of the depending change.'
                    REFERENCES :prefix:changes(change_id) ON UPDATE CASCADE ON DELETE CASCADE,
    type            VARCHAR(8)   NOT NULL
                    COMMENT 'Type of dependency.',
    dependency      VARCHAR(255) NOT NULL
                    COMMENT 'Dependency name.',
    dependency_id   VARCHAR(40)      NULL
                    COMMENT 'Change ID the dependency resolves to.'
                    REFERENCES :prefix:changes(change_id) ON UPDATE CASCADE,
    PRIMARY KEY (change_id, dependency)
) ENGINE  InnoDB,
  CHARACTER SET 'utf8',
  COMMENT 'Tracks the currently satisfied dependencies.'
;

CREATE TABLE :prefix:events (
    event           ENUM ('deploy', 'fail', 'merge', 'revert') NOT NULL
                    COMMENT 'Type of event.',
    change_id       VARCHAR(40)  NOT NULL
                    COMMENT 'Change ID.',
    "change"        VARCHAR(255) NOT NULL
                    COMMENT 'Change name.',
    project         VARCHAR(255) NOT NULL
                    COMMENT 'Name of the Sqitch project to which the change belongs.'
                    REFERENCES :prefix:projects(project) ON UPDATE CASCADE,
    note            TEXT         NOT NULL
                    COMMENT 'Description of the change.',
    requires        TEXT         NOT NULL
                    COMMENT 'List of the names of required changes.',
    conflicts       TEXT         NOT NULL
                    COMMENT 'List of the names of conflicting changes.',
    tags            TEXT         NOT NULL
                    COMMENT 'List of tags associated with the change.',
    committed_at    DATETIME(6)  NOT NULL
                    COMMENT 'Date the event was committed.',
    committer_name  VARCHAR(255) NOT NULL
                    COMMENT 'Name of the user who committed the event.',
    committer_email VARCHAR(255) NOT NULL
                    COMMENT 'Email address of the user who committed the event.',
    planned_at      DATETIME(6)  NOT NULL
                    COMMENT 'Date the event was added to the plan.',
    planner_name    VARCHAR(255) NOT NULL
                    COMMENT 'Name of the user who planed the change.',
    planner_email   VARCHAR(255) NOT NULL
                    COMMENT 'Email address of the user who plan planned the change.',
    PRIMARY KEY (change_id, committed_at)
) ENGINE  InnoDB,
  CHARACTER SET 'utf8',
  COMMENT 'Contains full history of all deployment events.'
;

-- ## BEGIN 5.5
-- MySQL does not support checks, so we kind of create our own. The checkit()
-- function works sort of like a CHECK: if the first argument is 0 or NULL, it
-- throws the second argument as an exception. Conveniently, verify scripts
-- can also use it to ensure an error is thrown when a change cannot be
-- verified. Requires MySQL 5.5.0.

DELIMITER |

CREATE FUNCTION checkit(doit INTEGER, message VARCHAR(256)) RETURNS INTEGER DETERMINISTIC
BEGIN
    IF doit IS NULL OR doit = 0 THEN
        SIGNAL SQLSTATE 'ERR0R' SET MESSAGE_TEXT = message;
    END IF;
    RETURN doit;
END;
|

CREATE TRIGGER ck_insert_dependency BEFORE INSERT ON :prefix:dependencies
FOR EACH ROW BEGIN
    -- DO does not work. http://bugs.mysql.com/bug.php?id=69647
    SET @dummy := checkit(
            (NEW.type = 'require'  AND NEW.dependency_id IS NOT NULL)
         OR (NEW.type = 'conflict' AND NEW.dependency_id IS NULL),
        'Type must be "require" with dependency_id set or "conflict" with dependency_id not set'
    );
END;
|

CREATE TRIGGER ck_update_dependency BEFORE UPDATE ON :prefix:dependencies
FOR EACH ROW BEGIN
    -- DO does not work. http://bugs.mysql.com/bug.php?id=69647
    SET @dummy := checkit(
            (NEW.type = 'require'  AND NEW.dependency_id IS NOT NULL)
         OR (NEW.type = 'conflict' AND NEW.dependency_id IS NULL),
        'Type must be "require" with dependency_id set or "conflict" with dependency_id not set'
    );
END;
|

DELIMITER ;
-- ## END 5.5

COMMIT;
