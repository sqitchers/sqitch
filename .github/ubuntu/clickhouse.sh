#!/bin/bash

set -e

if [ -z "$SKIP_DEPENDS" ]; then
    sudo apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -qq unixodbc-dev odbcinst unixodbc clickhouse-client
    cat t/odbc/odbcinst.ini | sudo tee -a /etc/odbcinst.ini
fi

cat t/odbc/clickhouse.ini | sudo tee -a /etc/clickhouse.ini

# Prepare the configuration.
mkdir -p /opt/clickhouse

# https://github.com/ClickHouse/clickhouse-odbc/releases
curl -sSLO https://github.com/ClickHouse/clickhouse-odbc/releases/download/1.4.3.20250807/clickhouse-odbc-linux-Clang-UnixODBC-Release.zip
unzip -p clickhouse-odbc-linux-Clang-UnixODBC-Release.zip 'clickhouse-odbc-1.4.3-Linux.tar.gz' | tar -xzf - -C /opt/clickhouse --strip-components 1
