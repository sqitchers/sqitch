#!/bin/bash

set -e

version=23.6.0.24.10
icdr=2360000

# Install bsdtar, required to get --strip-components for a zip file.
if [ -z "$SKIP_DEPENDS" ]; then
    sudo apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -qq libarchive-tools
fi

# Download Instant Client.
# https://www.oracle.com/database/technologies/instant-client/downloads.html
baseurl="https://download.oracle.com/otn_software/linux/instantclient/${icdr}"
curl -sSLO "${baseurl}/instantclient-basic-linux.x64-${version}.zip"
curl -sSLO "${baseurl}/instantclient-sqlplus-linux.x64-${version}.zip"
curl -sSLO "${baseurl}/instantclient-sdk-linux.x64-${version}.zip"

ld --verbose | grep SEARCH_DIR | tr -s ' ;' \\012

# Unpack Intant Client.
sudo bsdtar -C /usr/local/lib --strip-components 1 -zxf "instantclient-basic-linux.x64-${version}.zip"
sudo bsdtar -C /usr/local/lib --strip-components 1 -zxf "instantclient-sqlplus-linux.x64-${version}.zip"
sudo bsdtar -C /usr/local/lib --strip-components 1 -zxf "instantclient-sdk-linux.x64-${version}.zip"

if [[ ! -z "$GITHUB_PATH" ]]; then
    echo "/usr/local/lib" >> $GITHUB_PATH
fi
