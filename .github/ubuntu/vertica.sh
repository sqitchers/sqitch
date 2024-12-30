#!/bin/bash

set -e

if [ -z "$SKIP_DEPENDS" ]; then
    sudo apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -qq unixodbc-dev odbcinst unixodbc
    cat t/odbc/odbcinst.ini | sudo tee -a /etc/odbcinst.ini
fi

cat t/odbc/vertica.ini | sudo tee -a /etc/vertica.ini

# https://www.vertica.com/download/vertica/client-drivers/
curl -sSLO https://www.vertica.com/client_drivers/24.2.x/24.2.0-1/vertica-client-24.2.0-1.x86_64.tar.gz
sudo tar -xzf vertica-client-24.2.0-1.x86_64.tar.gz -C /

if [[ -n "$GITHUB_PATH" ]]; then
    echo "/opt/vertica/bin" >> "$GITHUB_PATH"
fi
