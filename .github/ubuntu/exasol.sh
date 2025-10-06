#!/bin/bash

set -e

# Download dependencies.
if [ -z "$SKIP_DEPENDS" ]; then
    sudo apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -qq curl unixodbc-dev odbcinst unixodbc default-jre
    cat t/odbc/odbcinst.ini | sudo tee -a /etc/odbcinst.ini
fi

# Prepare the configuration.
mkdir -p /opt/exasol

# Download and unpack Exasol ODBC Driver & EXAplus.
curl -sSLO https://x-up.s3.amazonaws.com/7.x/25.2.4/Exasol_ODBC-25.2.4-Linux_x86_64.tar.gz
curl -sSLO https://x-up.s3.amazonaws.com/7.x/25.2.5/EXAplus-25.2.5.tar.gz
sudo tar -xzf Exasol_ODBC-25.2.4-Linux_x86_64.tar.gz -C /opt/exasol --strip-components 2
sudo tar -xzf EXAplus-25.2.5.tar.gz                  -C /opt/exasol --strip-components 2

# Add to the path.
if [[ -n "$GITHUB_PATH" ]]; then
    echo "/opt/exasol" >> "$GITHUB_PATH"
fi
