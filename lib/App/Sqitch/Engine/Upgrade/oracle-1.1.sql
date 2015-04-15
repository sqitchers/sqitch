COLUMN uname for a30 new_value unique_name;

SELECT u.constraint_name AS uname
  FROM user_constraints u
  JOIN user_cons_columns c ON u.constraint_name = c.constraint_name
 WHERE u.table_name = 'CHANGES'
   AND u.constraint_type = 'U'
   AND c.column_name = 'SCRIPT_HASH';

ALTER TABLE &registry..changes DROP CONSTRAINT &unique_name;
ALTER TABLE &registry..changes ADD CONSTRAINT &unique_name UNIQUE (project, script_hash);
