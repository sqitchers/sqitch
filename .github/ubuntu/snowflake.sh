#!/bin/bash

set -e

# Set up Snowflake.
if [ -z "$SKIP_DEPENDS" ]; then
    sudo apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -qq unixodbc-dev odbcinst unixodbc
    cat t/odbc/odbcinst.ini | sudo tee -a /etc/odbcinst.ini
fi

# https://docs.snowflake.net/manuals/release-notes/client-change-log-snowsql.html
# https://sfc-repo.snowflakecomputing.com/index.html
curl -sSLo snowsql.bash https://sfc-repo.snowflakecomputing.com/snowsql/bootstrap/1.2/linux_x86_64/snowsql-1.2.21-linux_x86_64.bash
curl -sSLo snowdbc.tgz https://sfc-repo.snowflakecomputing.com/odbc/linux/latest/snowflake_linux_x8664_odbc-3.5.0.tgz

# Install and configure ODBC.
mkdir -p /opt/snowflake
sudo tar --strip-components 1 -C /opt/snowflake -xzf snowdbc.tgz
sudo mv /opt/snowflake/ErrorMessages/en-US /opt/snowflake/lib/

# Install, update, and configure SnowSQL.
sed -e '1,/^exit$/d' snowsql.bash | sudo tar -C /opt/snowflake -zxf -
/opt/snowflake/snowsql -Uv
printf "[options]\nnoup = true\n" > /opt/snowflake/config

# Add to the path.
if [[ -n "$GITHUB_PATH" ]]; then
    echo "/opt/snowflake" >> "$GITHUB_PATH"
fi

# Tell SnowSQL where to find the config.
if [[ -n "$GITHUB_ENV" ]]; then
    echo "WORKSPACE=/opt/snowflake" >> "$GITHUB_ENV"
fi
