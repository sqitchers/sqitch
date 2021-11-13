#!/bin/bash

set -e

version=21.3.0.0.0
icdr=213000

# Install bsdtar, required to get --strip-components for a zip file.
sudo apt-get update -qq
sudo apt-get install -qq libarchive-tools

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

if [[ ! -z "$GITHUB_PATH" ]]; then
    echo "/opt/instantclient" >> $GITHUB_PATH
fi

if [[ ! -z "$GITHUB_ENV" ]]; then
    echo "ORACLE_HOME=/opt/instantclient" >> $GITHUB_ENV
    echo "LD_LIBRARY_PATH=/opt/instantclient" >> $GITHUB_ENV
fi
