CREATE TABLE :"registry".releases (
    version         FLOAT          PRIMARY KEY,
    installed_at    TIMESTAMPTZ    NOT NULL DEFAULT clock_timestamp(),
    installer_name  VARCHAR(1024)  NOT NULL,
    installer_email VARCHAR(1024)  NOT NULL
);

COMMENT ON TABLE  :"registry".releases IS 'Sqitch registry releases.';
