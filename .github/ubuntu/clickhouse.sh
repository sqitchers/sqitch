#!/bin/bash

set -e

if [ -z "$SKIP_DEPENDS" ]; then
    sudo apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -qq unixodbc-dev odbcinst unixodbc
    cat t/odbc/odbcinst.ini | sudo tee -a /etc/odbcinst.ini
fi

ODBC_VERSION=1.4.3
ODBC_DATE=20250807

# Install the ClickHouse app.
# https://clickhouse.com/docs/install
TSV_URL=https://raw.githubusercontent.com/ClickHouse/ClickHouse/master/utils/list-versions/version_date.tsv
ARCH=$(dpkg --print-architecture)
LATEST_VERSION=$(curl -s "${TSV_URL}" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -V -r | head -n 1)

curl -sSL "https://packages.clickhouse.com/tgz/stable/clickhouse-common-static-$LATEST_VERSION-${ARCH}.tgz" \
    | sudo tar --strip-components 3 -C /usr/bin -zxf - "clickhouse-common-static-$LATEST_VERSION/usr/bin/clickhouse"

# Install the ODBC driver.
# https://github.com/ClickHouse/clickhouse-odbc/releases
mkdir -p /opt/clickhouse
curl -sSLO https://github.com/ClickHouse/clickhouse-odbc/releases/download/${ODBC_VERSION}.${ODBC_DATE}/clickhouse-odbc-linux-Clang-UnixODBC-Release.zip
unzip -p clickhouse-odbc-linux-Clang-UnixODBC-Release.zip "clickhouse-odbc-${ODBC_VERSION}-Linux.tar.gz" | tar -xzf - -C /opt/clickhouse --strip-components 1
