#!/bin/bash

set -e

sudo apt-get update -qq
sudo apt-get remove -qq mysql-common # https://github.com/actions/virtual-environments/issues/5067#issuecomment-1038752575
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -qq \
    libicu-dev gettext aspell-en software-properties-common \
    curl unixodbc-dev odbcinst unixodbc \
    default-jre \
    firebird-dev firebird3.0-utils \
    mysql-client default-libmysqlclient-dev \
    libarchive-tools \
    libaio1t64
cat t/odbc/odbcinst.ini | sudo tee -a /etc/odbcinst.ini

# instantclient still wants libaio.so.1. https://askubuntu.com/a/1514001
sudo ln -s /usr/lib/x86_64-linux-gnu/libaio.so.1t64 /usr/lib/x86_64-linux-gnu/libaio.so.1
