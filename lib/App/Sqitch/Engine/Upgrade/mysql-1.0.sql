CREATE TABLE releases (
    version         FLOAT         PRIMARY KEY
                    COMMENT 'Version of the Sqitch registry.',
    installed_at    TIMESTAMP     NOT NULL
                    COMMENT 'Date the registry release was installed.',
    installer_name  VARCHAR(255)  NOT NULL
                    COMMENT 'Name of the user who installed the registry release.',
    installer_email VARCHAR(255)  NOT NULL
                    COMMENT 'Email address of the user who installed the registry release.'
) ENGINE  InnoDB,
  CHARACTER SET 'utf8',
  COMMENT 'Sqitch registry releases.'
;
