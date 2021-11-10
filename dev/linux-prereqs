#!/bin/bash

set -e

sudo apt-get update -qq
sudo apt-get install -qq libicu-dev gettext aspell-en software-properties-common
cat t/odbc/odbcinst.ini | sudo tee -a /etc/odbcinst.ini
