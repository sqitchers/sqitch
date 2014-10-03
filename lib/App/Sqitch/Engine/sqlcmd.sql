CREATE TABLE dbo.projects(
	project varchar(255) NOT NULL,
	uri varchar(255) NULL,
	created_at datetime2 NOT NULL,
	creator_name varchar(255) NOT NULL,
	creator_email varchar(255) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	project ASC
),
UNIQUE NONCLUSTERED 
(
	uri ASC
)
) 

CREATE TABLE dbo.events(
	event varchar(6) NOT NULL,
	change_id varchar(40) NOT NULL,
	change varchar(255) NOT NULL,
	project varchar(255) NOT NULL,
	note varchar(8000) NOT NULL,
	requires varchar(8000) NOT NULL,
	conflicts varchar(8000) NOT NULL,
	tags varchar(8000) NOT NULL,
	committed_at datetime2 NOT NULL,
	committer_name varchar(255) NOT NULL,
	committer_email varchar(255) NOT NULL,
	planned_at datetime2 NOT NULL,
	planner_name varchar(255) NOT NULL,
	planner_email varchar(255) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	change_id ASC,
	committed_at ASC
)
) 

CREATE TABLE dbo.changes(
	change_id varchar(40) NOT NULL,
	change varchar(255) NOT NULL,
	project varchar(255) NOT NULL,
	note varchar(8000) NOT NULL,
	committed_at datetime2 NOT NULL,
	committer_name varchar(255) NOT NULL,
	committer_email varchar(255) NOT NULL,
	planned_at datetime2 NOT NULL,
	planner_name varchar(255) NOT NULL,
	planner_email varchar(255) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	change_id ASC
)
) 

CREATE TABLE dbo.tags(
	tag_id varchar(40) NOT NULL,
	tag varchar(255) NOT NULL,
	project varchar(255) NOT NULL,
	change_id varchar(40) NOT NULL,
	note varchar(255) NOT NULL,
	committed_at datetime2 NOT NULL,
	committer_name varchar(255) NOT NULL,
	committer_email varchar(255) NOT NULL,
	planned_at datetime2 NOT NULL,
	planner_name varchar(255) NOT NULL,
	planner_email varchar(255) NOT NULL,
PRIMARY KEY CLUSTERED 
(
	tag_id ASC
),
UNIQUE NONCLUSTERED 
(
	project ASC,
	tag ASC
)
) 

CREATE TABLE dbo.dependencies(
	change_id varchar(40) NOT NULL,
	type varchar(8) NOT NULL,
	dependency varchar(255) NOT NULL,
	dependency_id varchar(40) NULL,
PRIMARY KEY CLUSTERED 
(
	change_id ASC,
	dependency ASC
)
)

ALTER TABLE dbo.dependencies  WITH CHECK ADD  CONSTRAINT ck_dependency CHECK  ((type='require' AND dependency_id IS NOT NULL OR type='conflict' AND dependency_id IS NULL))

ALTER TABLE dbo.dependencies CHECK CONSTRAINT ck_dependency


ALTER TABLE dbo.events  WITH CHECK ADD  CONSTRAINT ck_event CHECK  ((event='deploy' OR event='revert' OR event='fail'))

ALTER TABLE dbo.events CHECK CONSTRAINT ck_event


ALTER TABLE dbo.changes  WITH CHECK ADD FOREIGN KEY(project)
REFERENCES dbo.projects (project)
ON UPDATE CASCADE


ALTER TABLE dbo.dependencies  WITH CHECK ADD FOREIGN KEY(change_id)
REFERENCES dbo.changes (change_id)
ON UPDATE CASCADE
ON DELETE CASCADE


ALTER TABLE dbo.dependencies  WITH CHECK ADD FOREIGN KEY(dependency_id)
REFERENCES dbo.changes (change_id)


ALTER TABLE dbo.events  WITH CHECK ADD FOREIGN KEY(project)
REFERENCES dbo.projects (project)
ON UPDATE CASCADE


ALTER TABLE dbo.tags  WITH CHECK ADD FOREIGN KEY(change_id)
REFERENCES dbo.changes (change_id)


ALTER TABLE dbo.tags  WITH CHECK ADD FOREIGN KEY(project)
REFERENCES dbo.projects (project)
ON UPDATE CASCADE
