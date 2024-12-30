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
# https://downloads.exasol.com/clients-and-drivers
curl -sSLO https://x-up.s3.amazonaws.com/7.x/7.1.17/EXASOL_ODBC-7.1.17.tar.gz
curl -sSLO https://x-up.s3.amazonaws.com/7.x/7.1.17/EXAplus-7.1.17.tar.gz
sudo tar -xzf EXASOL_ODBC-7.1.17.tar.gz -C /opt/exasol --strip-components 1
sudo tar -xzf EXAplus-7.1.17.tar.gz     -C /opt/exasol --strip-components 1

# The v8 CLIs aren't working because of a TLS error. If you get it working, be
# sure to change `odbcinst.ini`'s Exasol config to:
# Driver      = /opt/exasol/lib/libexaodbc.so
#
# curl -sSLO https://x-up.s3.amazonaws.com/7.x/24.2.0/Exasol_ODBC-24.2.0-Linux_x86_64.tar.gz
# curl -sSLO https://x-up.s3.amazonaws.com/7.x/24.2.1/EXAplus-24.2.1.tar.gz
# sudo tar -xzf Exasol_ODBC-24.2.0-Linux_x86_64.tar.gz -C /opt/exasol --strip-components 2
# sudo tar -xzf EXAplus-24.2.1.tar.gz                  -C /opt/exasol --strip-components 2

# Add to the path.
if [[ ! -z "$GITHUB_PATH" ]]; then
    echo "/opt/exasol" >> $GITHUB_PATH
fi
