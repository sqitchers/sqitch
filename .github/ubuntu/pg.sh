#!/bin/bash

set -e

PGVERSION=${PGVERSION:=${1:-14}}
[[ $PGVERSION =~ ^[0-9]$ ]] && PGVERSION+=.0

curl -O https://salsa.debian.org/postgresql/postgresql-common/-/raw/master/pgdg/apt.postgresql.org.sh
sudo sh apt.postgresql.org.sh -i -t -v $PGVERSION
sudo pg_createcluster --start $PGVERSION test -p 5432 --locale=C -- -A trust -E UTF8

if [[ ! -z "$GITHUB_PATH" ]]; then
    echo "/usr/lib/postgresql/$POSTGRES/bin" >> $GITHUB_PATH
fi
