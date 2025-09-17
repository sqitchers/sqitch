#!/bin/bash

set -e

if [ -z "$SKIP_DEPENDS" ]; then
    sudo apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -qq unixodbc-dev odbcinst unixodbc
    cat t/odbc/odbcinst.ini | sudo tee -a /etc/odbcinst.ini
fi

# https://clickhouse.com/docs/install
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -qq apt-transport-https ca-certificates curl gnupg
curl -fsSL 'https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key' | sudo gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg
ARCH=$(dpkg --print-architecture)
echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg arch=${ARCH}] https://packages.clickhouse.com/deb stable main" | sudo tee /etc/apt/sources.list.d/clickhouse.list
sudo apt-get update -qq
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -qq clickhouse-client

# Prepare the configuration.
mkdir -p /opt/clickhouse

# https://github.com/ClickHouse/clickhouse-odbc/releases
curl -sSLO https://github.com/ClickHouse/clickhouse-odbc/releases/download/1.4.3.20250807/clickhouse-odbc-linux-Clang-UnixODBC-Release.zip
unzip -p clickhouse-odbc-linux-Clang-UnixODBC-Release.zip 'clickhouse-odbc-1.4.3-Linux.tar.gz' | tar -xzf - -C /opt/clickhouse --strip-components 1
