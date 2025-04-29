#!/bin/bash

set -e

# Set up Snowflake.
if [ -z "$SKIP_DEPENDS" ]; then
    sudo apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -qq unixodbc-dev odbcinst unixodbc
    cat t/odbc/odbcinst.ini | sudo tee -a /etc/odbcinst.ini
fi

# Set the SnowSQL workspace.
export WORKSPACE=/opt/snowflake

# https://docs.snowflake.net/manuals/release-notes/client-change-log-snowsql.html
# https://sfc-repo.snowflakecomputing.com/index.html
curl -sSLo snowsql.bash https://sfc-repo.snowflakecomputing.com/snowsql/bootstrap/1.3/linux_x86_64/snowsql-1.3.2-linux_x86_64.bash
curl -sSLo snowdbc.tgz https://sfc-repo.snowflakecomputing.com/odbc/linux/latest/snowflake_linux_x8664_odbc-3.5.0.tgz

# Install and configure ODBC.
mkdir -p "$WORKSPACE/.snowsql"
sudo tar --strip-components 1 -C "$WORKSPACE" -xzf snowdbc.tgz
sudo mv "$WORKSPACE/ErrorMessages/en-US" "$WORKSPACE/lib/"

# Set up the DSN for key pair auth.
perl -npE 's/KEY_PASSWORD/$ENV{SNOWFLAKE_KEY_PASSWORD}/g' t/odbc/snowflake.ini | sudo tee -a /etc/odbc.ini
printf "%s" "${SNOWFLAKE_KEY_FILE}" > "$WORKSPACE/rsa_key.p8"

# Install, update, and configure SnowSQL.
sed -e '1,/^exit$/d' snowsql.bash | sudo tar -C "$WORKSPACE" -zxf -
"$WORKSPACE/snowsql" -Uv
(
    printf "[connections]\nprivate_key_path=%s/rsa_key.p8\n\n" "$WORKSPACE"
    printf "[options]\nnoup = true\n"
) > "$WORKSPACE/.snowsql/config"

# Add to the path.
if [[ -n "$GITHUB_PATH" ]]; then
    echo "$WORKSPACE" >> "$GITHUB_PATH"
fi

# Tell SnowSQL where to find the config.
if [[ -n "$GITHUB_ENV" ]]; then
    echo "WORKSPACE=$WORKSPACE" >> "$GITHUB_ENV"
fi
