/*
 * Sqitch database deployment metadata v1.0.;
 */

/*
 * Required PAGE SIZE = 16384 to avoid error: "key size exceeds
 * implementation restriction for index..."
 */

-- Table: releases

CREATE TABLE releases (
    version         FLOAT         NOT NULL PRIMARY KEY,
    installed_at    TIMESTAMP     DEFAULT CURRENT_TIMESTAMP NOT NULL,
    installer_name  VARCHAR(255)  NOT NULL,
    installer_email VARCHAR(255)  NOT NULL
);

UPDATE RDB$RELATIONS SET
    RDB$DESCRIPTION = 'Sqitch registry releases.'
    WHERE RDB$RELATION_NAME = 'RELEASES';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Version of the Sqitch registry.'
    WHERE RDB$RELATION_NAME = 'RELEASES' AND RDB$FIELD_NAME = 'VERSION';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Date the registry release was installed.'
    WHERE RDB$RELATION_NAME = 'VERSIONS' AND RDB$FIELD_NAME = 'INSTALLED_AT';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Name of the user who installed the registry release.'
    WHERE RDB$RELATION_NAME = 'VERSIONS' AND RDB$FIELD_NAME = 'INSTALLER_NAME';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Email address of the user who installed the registry release.'
    WHERE RDB$RELATION_NAME = 'VERSIONS' AND RDB$FIELD_NAME = 'INSTALLER_EMAIL';

-- Table: projects

CREATE TABLE projects (
    project         VARCHAR(255)  NOT NULL PRIMARY KEY,
    uri             VARCHAR(255)  UNIQUE,
    created_at      TIMESTAMP     DEFAULT CURRENT_TIMESTAMP NOT NULL,
    creator_name    VARCHAR(255)  NOT NULL,
    creator_email   VARCHAR(255)  NOT NULL
);

-- Description (comments)

UPDATE RDB$RELATIONS SET
    RDB$DESCRIPTION = 'Sqitch projects deployed to this database.'
    WHERE RDB$RELATION_NAME = 'PROJECTS';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Unique Name of a project.'
    WHERE RDB$RELATION_NAME = 'PROJECTS' AND RDB$FIELD_NAME = 'PROJECT';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Optional project URI.'
    WHERE RDB$RELATION_NAME = 'PROJECTS' AND RDB$FIELD_NAME = 'URI';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Date the project was added to the database.'
    WHERE RDB$RELATION_NAME = 'PROJECTS' AND RDB$FIELD_NAME = 'CREATED_AT';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Name of the user who added the project.'
    WHERE RDB$RELATION_NAME = 'PROJECTS' AND RDB$FIELD_NAME = 'CREATOR_NAME';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Email address of the user who added the project.'
    WHERE RDB$RELATION_NAME = 'PROJECTS' AND RDB$FIELD_NAME = 'CREATOR_EMAIL';

-- Table: changes

CREATE TABLE changes (
    change_id       VARCHAR(40)   NOT NULL PRIMARY KEY,
    script_hash     VARCHAR(40)            UNIQUE,
    change          VARCHAR(255)  NOT NULL,
    project         VARCHAR(255)  NOT NULL REFERENCES projects(project)
                                       ON UPDATE CASCADE,
    note            BLOB SUB_TYPE TEXT DEFAULT '' NOT NULL,
    committed_at    TIMESTAMP     DEFAULT CURRENT_TIMESTAMP NOT NULL,
    committer_name  VARCHAR(255)  NOT NULL,
    committer_email VARCHAR(255)  NOT NULL,
    planned_at      TIMESTAMP     NOT NULL,
    planner_name    VARCHAR(255)  NOT NULL,
    planner_email   VARCHAR(255)  NOT NULL
);

-- Description (comments)

UPDATE RDB$RELATIONS SET
    RDB$DESCRIPTION = 'Tracks the changes currently deployed to the database.'
    WHERE RDB$RELATION_NAME = 'CHANGES';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Change primary key.'
    WHERE RDB$RELATION_NAME = 'CHANGES' AND RDB$FIELD_NAME = 'CHANGE_ID';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Deploy script SHA-1 hash.'
    WHERE RDB$RELATION_NAME = 'CHANGES' AND RDB$FIELD_NAME = 'SCRIPT_HASH';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Name of a deployed change.'
    WHERE RDB$RELATION_NAME = 'CHANGES' AND RDB$FIELD_NAME = 'CHANGE';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Name of the Sqitch project to which the change belongs.'
    WHERE RDB$RELATION_NAME = 'CHANGES' AND RDB$FIELD_NAME = 'PROJECT';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Description of the change.'
    WHERE RDB$RELATION_NAME = 'CHANGES' AND RDB$FIELD_NAME = 'NOTE';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Date the change was deployed.'
    WHERE RDB$RELATION_NAME = 'CHANGES' AND RDB$FIELD_NAME = 'COMMITTED_AT';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Name of the user who deployed the change.'
    WHERE RDB$RELATION_NAME = 'CHANGES' AND RDB$FIELD_NAME = 'COMMITTER_NAME';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Email address of the user who deployed the change.'
    WHERE RDB$RELATION_NAME = 'CHANGES' AND RDB$FIELD_NAME = 'COMMITTER_EMAIL';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Date the change was added to the plan.'
    WHERE RDB$RELATION_NAME = 'CHANGES' AND RDB$FIELD_NAME = 'PLANNED_AT';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Name of the user who planed the change.'
    WHERE RDB$RELATION_NAME = 'CHANGES' AND RDB$FIELD_NAME = 'PLANNER_NAME';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Email address of the user who planned the change.'
    WHERE RDB$RELATION_NAME = 'CHANGES' AND RDB$FIELD_NAME = 'PLANNER_EMAIL';

-- Table: tags

CREATE TABLE tags (
    tag_id          CHAR(40)      NOT NULL PRIMARY KEY,
    tag             VARCHAR(250)  NOT NULL,
    project         VARCHAR(255)  NOT NULL REFERENCES projects(project)
                                       ON UPDATE CASCADE,
    change_id       CHAR(40)      NOT NULL REFERENCES changes(change_id)
                                       ON UPDATE CASCADE,
    note            BLOB SUB_TYPE TEXT DEFAULT '' NOT NULL,
    committed_at    TIMESTAMP     DEFAULT CURRENT_TIMESTAMP NOT NULL,
    committer_name  VARCHAR(512)  NOT NULL,
    committer_email VARCHAR(512)  NOT NULL,
    planned_at      TIMESTAMP     NOT NULL,
    planner_name    VARCHAR(512)  NOT NULL,
    planner_email   VARCHAR(512)  NOT NULL,
    UNIQUE(project, tag)
);

-- Description (comments)

UPDATE RDB$RELATIONS SET
    RDB$DESCRIPTION = 'Tracks the tags currently applied to the database.'
    WHERE RDB$RELATION_NAME = 'TAGS';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Tag primary key.'
    WHERE RDB$RELATION_NAME = 'TAGS' AND RDB$FIELD_NAME = 'TAG_ID';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Project-unique tag name.'
    WHERE RDB$RELATION_NAME = 'TAGS' AND RDB$FIELD_NAME = 'TAG';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Name of the Sqitch project to which the tag belongs.'
    WHERE RDB$RELATION_NAME = 'TAGS' AND RDB$FIELD_NAME = 'PROJECT';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'ID of last change deployed before the tag was applied.'
    WHERE RDB$RELATION_NAME = 'TAGS' AND RDB$FIELD_NAME = 'CHANGE_ID';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Description of the tag.'
    WHERE RDB$RELATION_NAME = 'TAGS' AND RDB$FIELD_NAME = 'NOTE';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Date the tag was applied to the database.'
    WHERE RDB$RELATION_NAME = 'TAGS' AND RDB$FIELD_NAME = 'COMMITTED_AT';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Name of the user who applied the tag.'
    WHERE RDB$RELATION_NAME = 'TAGS' AND RDB$FIELD_NAME = 'COMMITTER_NAME';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Email address of the user who applied the tag.'
    WHERE RDB$RELATION_NAME = 'TAGS' AND RDB$FIELD_NAME = 'COMMITTER_EMAIL';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Date the tag was added to the plan.'
    WHERE RDB$RELATION_NAME = 'TAGS' AND RDB$FIELD_NAME = 'PLANNED_AT';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Name of the user who planed the tag.'
    WHERE RDB$RELATION_NAME = 'TAGS' AND RDB$FIELD_NAME = 'PLANNER_NAME';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Email address of the user who planned the tag.'
    WHERE RDB$RELATION_NAME = 'TAGS' AND RDB$FIELD_NAME = 'PLANNER_EMAIL';

-- Table: dependencies

CREATE TABLE dependencies (
    change_id       CHAR(40)      NOT NULL REFERENCES changes(change_id)
                                       ON UPDATE CASCADE ON DELETE CASCADE,
    type            VARCHAR(8)    NOT NULL,
    dependency      VARCHAR(512)  NOT NULL,
    dependency_id   CHAR(40)      REFERENCES changes(change_id)
                                       ON UPDATE CASCADE CHECK (
                          (type = 'require'  AND dependency_id IS NOT NULL)
                       OR (type = 'conflict' AND dependency_id IS NULL)
    ),
    PRIMARY KEY (change_id, dependency)
);

-- Description (comments)

UPDATE RDB$RELATIONS SET
    RDB$DESCRIPTION = 'Tracks the currently satisfied dependencies.'
    WHERE RDB$RELATION_NAME = 'DEPENDENCIES';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'ID of the depending change.'
    WHERE RDB$RELATION_NAME = 'DEPENDENCIES' AND RDB$FIELD_NAME = 'CHANGE_ID';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Type of dependency.'
    WHERE RDB$RELATION_NAME = 'DEPENDENCIES' AND RDB$FIELD_NAME = 'TYPE';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Dependency name.'
    WHERE RDB$RELATION_NAME = 'DEPENDENCIES' AND RDB$FIELD_NAME = 'DEPENDENCY';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Change ID the dependency resolves to.'
    WHERE RDB$RELATION_NAME = 'DEPENDENCIES' AND RDB$FIELD_NAME = 'DEPENDENCY_ID';

-- Table: events

CREATE TABLE events (
    event           VARCHAR(6)    NOT NULL
                               CHECK (event IN ('deploy', 'revert', 'fail')),
    change_id       CHAR(40)      NOT NULL,
    change          VARCHAR(512)  NOT NULL,
    project         VARCHAR(255)  NOT NULL REFERENCES projects(project)
                                       ON UPDATE CASCADE,
    note            BLOB SUB_TYPE TEXT DEFAULT '' NOT NULL,
    requires        BLOB SUB_TYPE TEXT DEFAULT '' NOT NULL,
    conflicts       BLOB SUB_TYPE TEXT DEFAULT '' NOT NULL,
    tags            BLOB SUB_TYPE TEXT DEFAULT '' NOT NULL,
    committed_at    TIMESTAMP     DEFAULT CURRENT_TIMESTAMP NOT NULL,
    committer_name  VARCHAR(512)  NOT NULL,
    committer_email VARCHAR(512)  NOT NULL,
    planned_at      TIMESTAMP     NOT NULL,
    planner_name    VARCHAR(512)  NOT NULL,
    planner_email   VARCHAR(512)  NOT NULL,
    PRIMARY KEY (change_id, committed_at)
);

-- Description (comments)

UPDATE RDB$RELATIONS SET
    RDB$DESCRIPTION = 'Contains full history of all deployment events.'
    WHERE RDB$RELATION_NAME = 'EVENTS';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Type of event.'
    WHERE RDB$RELATION_NAME = 'EVENTS' AND RDB$FIELD_NAME = 'EVENT';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Change ID.'
    WHERE RDB$RELATION_NAME = 'EVENTS' AND RDB$FIELD_NAME = 'CHANGE_ID';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Change name.'
    WHERE RDB$RELATION_NAME = 'EVENTS' AND RDB$FIELD_NAME = 'CHANGE';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Name of the Sqitch project to which the change belongs.'
    WHERE RDB$RELATION_NAME = 'EVENTS' AND RDB$FIELD_NAME = 'PROJECT';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Description of the change.'
    WHERE RDB$RELATION_NAME = 'EVENTS' AND RDB$FIELD_NAME = 'NOTE';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Array of the names of required changes.'
    WHERE RDB$RELATION_NAME = 'EVENTS' AND RDB$FIELD_NAME = 'REQUIRES';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Array of the names of conflicting changes.'
    WHERE RDB$RELATION_NAME = 'EVENTS' AND RDB$FIELD_NAME = 'CONFLICTS';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Tags associated with the change.'
    WHERE RDB$RELATION_NAME = 'EVENTS' AND RDB$FIELD_NAME = 'TAGS';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Date the event was committed.'
    WHERE RDB$RELATION_NAME = 'EVENTS' AND RDB$FIELD_NAME = 'COMMITTED_AT';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Name of the user who committed the event.'
    WHERE RDB$RELATION_NAME = 'EVENTS' AND RDB$FIELD_NAME = 'COMMITTER_NAME';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Email address of the user who committed the event.'
    WHERE RDB$RELATION_NAME = 'EVENTS' AND RDB$FIELD_NAME = 'COMMITTER_EMAIL';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Date the event was added to the plan.'
    WHERE RDB$RELATION_NAME = 'EVENTS' AND RDB$FIELD_NAME = 'PLANNED_AT';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Name of the user who planed the change.'
    WHERE RDB$RELATION_NAME = 'EVENTS' AND RDB$FIELD_NAME = 'PLANNER_NAME';

UPDATE RDB$RELATION_FIELDS
    SET RDB$DESCRIPTION = 'Email address of the user who plan planned the change.'
    WHERE RDB$RELATION_NAME = 'EVENTS' AND RDB$FIELD_NAME = 'PLANNER_EMAIL';

COMMIT;
