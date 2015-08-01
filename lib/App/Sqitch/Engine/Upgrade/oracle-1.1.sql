COLUMN cname for a30 new_value check_name;

SELECT u.constraint_name AS cname
  FROM user_constraints u
  JOIN user_cons_columns c ON u.constraint_name = c.constraint_name
 WHERE u.table_name = 'CHANGES'
   AND u.constraint_type = 'U'
   AND c.column_name = 'SCRIPT_HASH';

ALTER TABLE &registry..changes DROP CONSTRAINT &check_name;
ALTER TABLE &registry..changes ADD CONSTRAINT &check_name UNIQUE (project, script_hash);

-- Rename the changes check constraint.
ALTER TABLE &registry..events RENAME CONSTRAINT check_event_type TO events_event_check;

-- Rename the dependencies check constraint.
SELECT constraint_name AS cname
  FROM user_cons_columns
 WHERE table_name = 'DEPENDENCIES'
   AND column_name = 'DEPENDENCY_ID'
   AND constraint_name IN (
       SELECT constraint_name
         FROM user_cons_columns
        WHERE table_name = 'DEPENDENCIES'
          AND column_name = 'TYPE'
   );

ALTER TABLE &registry..dependencies
      RENAME CONSTRAINT &check_name TO dependencies_check;


