#!/bin/bash

set -e

PGVERSION=${PGVERSION:=${1:-"$(curl -s https://ftp.postgresql.org/pub/latest/ | perl -ne '/postgresql-(\d+)/ && print($1) && exit')"}}
[[ $PGVERSION =~ ^[0-9]$ ]] && PGVERSION+=.0
echo "Installing PostgreSQL $PGVERSION"

curl -O https://salsa.debian.org/postgresql/postgresql-common/-/raw/master/pgdg/apt.postgresql.org.sh
sudo sh apt.postgresql.org.sh -i -t -v $PGVERSION
sudo pg_createcluster --start $PGVERSION test -p 5432 --locale=C -- -A trust -E UTF8

if [[ -n "$GITHUB_PATH" ]]; then
    echo "/usr/lib/postgresql/$POSTGRES/bin" >> "$GITHUB_PATH"
fi
