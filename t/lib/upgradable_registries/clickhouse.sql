
CREATE TABLE releases (
    version         REAL                 NOT NULL
                    COMMENT 'Version of the Sqitch registry.',
    installed_at    DATETIME64(6, 'UTC') NOT NULL DEFAULT now64(6, 'UTC')
                    COMMENT 'Date the registry release was installed.',
    installer_name  TEXT                 NOT NULL
                    COMMENT 'Name of the user who installed the registry release.',
    installer_email TEXT                 NOT NULL
                    COMMENT 'Email address of the user who installed the registry release.'
) ENGINE = MergeTree
  PRIMARY KEY version
  ORDER BY version
  SETTINGS enable_block_number_column = 1, enable_block_offset_column = 1
  COMMENT 'Sqitch registry releases.';

CREATE TABLE projects (
    project         TEXT                 NOT NULL
                    COMMENT 'Unique Name of a project.',
    uri             TEXT                 NULL
                    COMMENT 'Optional project URI',
    created_at      DATETIME64(6, 'UTC') NOT NULL DEFAULT now64(6, 'UTC')
                    COMMENT 'Date the project was added to the database.',
    creator_name    TEXT                 NOT NULL
                    COMMENT 'Name of the user who added the project.',
    creator_email   TEXT                 NOT NULL
                    COMMENT 'Email address of the user who added the project.'
) ENGINE = MergeTree
  PRIMARY KEY project
  ORDER BY project
  SETTINGS enable_block_number_column = 1, enable_block_offset_column = 1
  COMMENT 'Sqitch projects deployed to this database.';

CREATE TABLE changes (
    change_id       TEXT        NOT NULL
                    COMMENT 'Change primary key.',
    change          TEXT        NOT NULL
                    COMMENT 'Name of a deployed change.',
    project         TEXT        NOT NULL
                    COMMENT 'Name of the Sqitch project to which the change belongs.',
    note            TEXT        NOT NULL DEFAULT ''
                    COMMENT 'Description of the change.',
    committed_at    DATETIME64(6, 'UTC') NOT NULL DEFAULT now64(6, 'UTC')
                    COMMENT 'Date the change was deployed.',
    committer_name  TEXT        NOT NULL
                    COMMENT 'Name of the user who deployed the change.',
    committer_email TEXT        NOT NULL
                    COMMENT 'Email address of the user who deployed the change.',
    planned_at      DATETIME64(6, 'UTC') NOT NULL
                    COMMENT 'Date the change was added to the plan.',
    planner_name    TEXT        NOT NULL
                    COMMENT 'Name of the user who planed the change.',
    planner_email   TEXT        NOT NULL
                    COMMENT 'Email address of the user who planned the change.'
) ENGINE = MergeTree
  PRIMARY KEY (project, change_id)
  ORDER BY (project, change_id)
  SETTINGS enable_block_number_column = 1, enable_block_offset_column = 1
  COMMENT 'Tracks the changes currently deployed to the database.';

CREATE TABLE tags (
    tag_id          TEXT        NOT NULL
                    COMMENT 'Tag primary key.',
    tag             TEXT        NOT NULL
                    COMMENT 'Project-unique tag name.',
    project         TEXT        NOT NULL
                    COMMENT 'Name of the Sqitch project to which the tag belongs.',
    change_id       TEXT        NOT NULL
                    COMMENT 'ID of last change deployed before the tag was applied.',
    note            TEXT        NOT NULL DEFAULT ''
                    COMMENT 'Description of the tag.',
    committed_at    DATETIME64(6, 'UTC') NOT NULL DEFAULT now64(6, 'UTC')
                    COMMENT 'Date the tag was applied to the database.',
    committer_name  TEXT        NOT NULL
                    COMMENT 'Name of the user who applied the tag.',
    committer_email TEXT        NOT NULL
                    COMMENT 'Email address of the user who applied the tag.',
    planned_at      DATETIME64(6, 'UTC') NOT NULL
                    COMMENT 'Date the tag was added to the plan.',
    planner_name    TEXT        NOT NULL
                    COMMENT 'Name of the user who planed the tag.',
    planner_email   TEXT        NOT NULL
                    COMMENT 'Email address of the user who planned the tag.'
) ENGINE = MergeTree
  PRIMARY KEY (project, change_id, tag_id)
  ORDER BY (project, change_id, tag_id)
  SETTINGS enable_block_number_column = 1, enable_block_offset_column = 1
  COMMENT 'Tracks the tags currently applied to the database.';

CREATE TABLE dependencies (
    change_id       TEXT        NOT NULL
                    COMMENT 'ID of the depending change.',
    type            TEXT        NOT NULL
                    COMMENT 'Type of dependency.',
    dependency      TEXT        NOT NULL
                    COMMENT 'Dependency name.',
    dependency_id   TEXT            NULL
                    COMMENT 'Change ID the dependency resolves to.',
    CONSTRAINT dependencies_check CHECK (
            (type = 'require'  AND dependency_id IS NOT NULL)
         OR (type = 'conflict' AND dependency_id IS NULL)
    )    
) ENGINE = MergeTree
  PRIMARY KEY (change_id, dependency)
  ORDER BY (change_id, dependency)
  SETTINGS enable_block_number_column = 1, enable_block_offset_column = 1
  COMMENT 'Tracks the tags currently applied to the database.';

CREATE TABLE events (
    event           TEXT                 NOT NULL
                    COMMENT 'Type of event.',
    change_id       TEXT                 NOT NULL
                    COMMENT 'Change ID.',
    change          TEXT                 NOT NULL
                    COMMENT 'Change name.',
    project         TEXT                 NOT NULL
                    COMMENT 'Name of the Sqitch project to which the change belongs.',
    note            TEXT                 NOT NULL DEFAULT ''
                    COMMENT 'Description of the change.',
    requires        Array(TEXT)          NOT NULL DEFAULT '[]'
                    COMMENT 'Array of the names of required changes.',
    conflicts       Array(TEXT)          NOT NULL DEFAULT '[]'
                    COMMENT 'Array of the names of conflicting changes.',
    tags            Array(TEXT)          NOT NULL DEFAULT '[]'
                    COMMENT 'Tags associated with the change.',
    committed_at    DATETIME64(6, 'UTC') NOT NULL DEFAULT now64(6, 'UTC')
                    COMMENT 'Date the event was committed.',
    committer_name  TEXT                 NOT NULL
                    COMMENT 'Name of the user who committed the event.',
    committer_email TEXT                 NOT NULL
                    COMMENT 'Email address of the user who committed the event.',
    planned_at      DATETIME64(6, 'UTC') NOT NULL
                    COMMENT 'Date the event was added to the plan.',
    planner_name    TEXT                 NOT NULL
                    COMMENT 'Name of the user who planed the change.',
    planner_email   TEXT                 NOT NULL
                    COMMENT 'Email address of the user who plan planned the change.',
) ENGINE = MergeTree
  PRIMARY KEY (project, committed_at)
  ORDER BY (project, committed_at)
  SETTINGS enable_block_number_column = 1, enable_block_offset_column = 1
  COMMENT 'Contains full history of all deployment events.';
