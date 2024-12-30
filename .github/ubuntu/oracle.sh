#!/bin/bash

set -e

version=23.6.0.24.10
icdr=2360000

# Download dependencies.
if [ -z "$SKIP_DEPENDS" ]; then
    # Install libaio and bsdtar, required to get --strip-components for a zip file.
    sudo apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -qq libarchive-tools libaio1t64

    # instantclient still wants libaio.so.1. https://askubuntu.com/a/1514001
    sudo ln -s /usr/lib/x86_64-linux-gnu/libaio.so.1t64 /usr/lib/x86_64-linux-gnu/libaio.so.1
fi

# Download Instant Client.
# https://www.oracle.com/database/technologies/instant-client/downloads.html
baseurl="https://download.oracle.com/otn_software/linux/instantclient/${icdr}"
curl -sSLO "${baseurl}/instantclient-basic-linux.x64-${version}.zip"
curl -sSLO "${baseurl}/instantclient-sqlplus-linux.x64-${version}.zip"
curl -sSLO "${baseurl}/instantclient-sdk-linux.x64-${version}.zip"

# Unpack Intant Client.
mkdir -p /opt/instantclient
bsdtar -C /opt/instantclient --strip-components 1 -zxf "instantclient-basic-linux.x64-${version}.zip"
bsdtar -C /opt/instantclient --strip-components 1 -zxf "instantclient-sqlplus-linux.x64-${version}.zip"
bsdtar -C /opt/instantclient --strip-components 1 -zxf "instantclient-sdk-linux.x64-${version}.zip"

if [[ -n "$GITHUB_PATH" ]]; then
    echo "/opt/instantclient" >> "$GITHUB_PATH"
fi

if [[ -n "$GITHUB_ENV" ]]; then
    echo "ORACLE_HOME=/opt/instantclient" >> "$GITHUB_ENV"
    if [[ -z "$LD_LIBRARY_PATH" ]]; then
        echo "LD_LIBRARY_PATH=/opt/instantclient" >> "$GITHUB_ENV"
    else
        echo "LD_LIBRARY_PATH=/opt/instantclient:$LD_LIBRARY_PATH" >> "$GITHUB_ENV"
    fi
fi
