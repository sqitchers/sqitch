-- Deploy func/add_user
-- requires: users

BEGIN;

CREATE FUNCTION __myapp.add_user(
    nick TEXT,
    pass TEXT
) RETURNS VOID LANGUAGE SQL AS $$
    INSERT INTO __myapp.users VALUES(nick, MD5(pass));
$$;

COMMIT;
