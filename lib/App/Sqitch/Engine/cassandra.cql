CREATE KEYSPACE :"registry"
WITH COMMENT = 'Sqitch database deployment metadata v1.0.',
AND REPLICATION = {
	'class': 'SimpleStrategy'
	'replication_factor': 1
},
AND DURABLE_WRITES = true;

CREATE TABLE :"registry".releases (
	version         FLOAT PRIMARY KEY,
	installed_at    TIMESTAMP.
	installer_name  TEXT,
	installer_email TEXT
)
WITH COMMENT = 'Sqitch registry releases.',
AND CACHING = {
	'keys': 'NONE',
	'rows_per_partition': 'NONE'
},
AND GC_GRACE_SECONDS = 0,
AND COMPRESSION = {
	'class': 'LZ4Compressor'
},
AND CLUSTERING ORDER BY (version);

CREATE TABLE :"registry".projects (
	project       TEXT PRIMARY KEY,
	uri           TEXT,
	created_at    TIMESTAMP,
	creator_name  TEXT,
	creator_email TEXT
)
WITH COMMENT = 'Sqitch projects deployed to this database.',
AND CACHING = {
	'keys': 'NONE',
	'rows_per_partition': 'NONE'
},
AND GC_GRACE_SECONDS = 0,
AND COMPRESSION = {
	'class': 'LZ4Compressor'
},
AND CLUSTERING ORDER BY (project);

CREATE TABLE :"registry".changes (
	change_id       TEXT PRIMARY KEY,
	script_hash     TEXT,
	change          TEXT,
	project         TEXT,
	note            TEXT,
	committed_at    TIMESTAMP,
	committer_name  TEXT,
	committer_email TEXT,
	planned_at      TIMESTAMP,
	planner_name    TEXT,
	planner_email   TEXT
)
WITH COMMENT = 'Tracks the changes currently deployed to the database.',
AND CACHING = {
	'keys': 'NONE',
	'rows_per_partition': 'NONE'
},
AND GC_GRACE_SECONDS = 0,
AND COMPRESSION = {
	'class': 'LZ4Compressor'
},
AND CLUSTERING ORDER BY (change_id);

CREATE TABLE :"registry".tags (
	tag_id          TEXT PRIMARY KEY,
	tag             TEXT,
	project         TEXT,
	change_id       TEXT,
	note            TEXT,
	committed_at    TIMESTAMP,
	committer_name  TEXT,
	committer_email TEXT,
	planned_at      TIMESTAMP,
	planner_name    TEXT,
	planner_email   TEXT
)
WITH COMMENT = 'Tracks the tags currently applied to the database.'
AND CACHING = {
	'keys': 'NONE',
	'rows_per_partition': 'NONE'
},
AND GC_GRACE_SECONDS = 0,
AND COMPRESSION = {
	'class': 'LZ4Compressor'
},
AND CLUSTERING ORDER BY (tag_id);

CREATE TABLE :"registry".dependencies (
	change_id       TEXT,
	type            TEXT,
	dependency      TEXT,
	dependency_id   TEXT,
	PRIMARY KEY (change_id, dependency)
)
WITH COMMENT = 'Tracks the currently satisfied dependencies.',
AND CACHING = {
	'keys': 'NONE',
	'rows_per_partition': 'NONE'
},
AND GC_GRACE_SECONDS = 0,
AND COMPRESSION = {
	'class': 'LZ4Compressor'
},
AND CLUSTERING ORDER BY (change_id);

CREATE TABLE :"registry".events (
    event           TEXT,
    change_id       TEXT,
    change          TEXT,
    project         TEXT,
    note            TEXT,
    requires        LIST<TEXT>,
    conflicts       LIST<TEXT>,
    tags            LIST<TEXT>,
    committed_at    TIMESTAMP,
    committer_name  TEXT,
    committer_email TEXT,
    planned_at      TIMESTAMP,
    planner_name    TEXT,
    planner_email   TEXT,
    PRIMARY KEY (change_id, committed_at)
)
WITH COMMENT = 'Contains full history of all deployment events.',
AND CACHING = {
	'keys': 'NONE',
	'rows_per_partition': 'NONE'
},
AND GC_GRACE_SECONDS = 0,
AND COMPRESSION = {
	'class': 'LZ4Compressor'
},
AND CLUSTERING ORDER BY (change_id);

CREATE FUNCTION :"registry".dt_format(dt TIMESTAMP)
RETURNS NULL ON NULL INPUT
RETURNS TEXT
LANGUAGE java
AS $$
	return "year:"
	+ new java.util.SimpleDateFormat("yyyy:").format(dt)
	+ "month:"
	+ new java.util.SimpleDateFormat("MM:").format(dt)
	+ "day:"
	+ new java.util.SimpleDateFormat("dd:").format(dt)
	+ "hour:"
	+ new java.util.SimpleDateFormat("HH:").format(dt)
	+ "minute:"
	+ new java.util.SimpleDateFormat("mm:").format(dt)
	+ "second:"
	+ new java.util.SimpleDateFormat("ss:").format(dt)
	+ "time_zone:"
	+ new java.util.SimpleDateFormat("z").format(dt);
$$;
