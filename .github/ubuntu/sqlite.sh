#!/bin/bash

set -e

SQLITE=${SQLITE:=${1:-3.40.1}}
echo "Instaling SQLite $SQLITE"

# Convert to the SQLITE_VERSION_NUMBER format https://sqlite.org/c3ref/c_source_id.html
SQLITE=$(perl -e 'my @v = split /[.]/, shift; printf "%d%02d%02d%02d\n", @v[0..3]' "$SQLITE")

# Since 3.7.16.1, the URL includes the year in the path.
# 3.18.2, 3.18.1, 3.9.3, and 3.7.11 missing.
# https://sqlite.org/chronology.html
# https://stackoverflow.com/a/37712117/79202
if   (( $SQLITE >= 3480000 )); then YEAR=2025
elif (( $SQLITE >= 3450000 )); then YEAR=2024
elif (( $SQLITE >= 3400200 )); then YEAR=2023
elif (( $SQLITE >= 3370200 )); then YEAR=2022
elif (( $SQLITE >= 3340100 )); then YEAR=2021
elif (( $SQLITE >= 3310000 )); then YEAR=2020
elif (( $SQLITE >= 3270000 )); then YEAR=2019
elif (( $SQLITE >= 3220000 )); then YEAR=2018
elif (( $SQLITE >= 3160000 )); then YEAR=2017
elif (( $SQLITE >= 3100000 )); then YEAR=2016
elif (( $SQLITE >= 3080800 )); then YEAR=2015
elif (( $SQLITE >= 3080300 )); then YEAR=2014
elif (( $SQLITE >= 3071601 )); then YEAR=2013 # Earliest release with year in path.
else
    echo "Unsupported version $SQLITE" >&2
    exit 64
fi

# Download, compile, and install SQLite.
curl -o sqlite.zip https://sqlite.org/$YEAR/sqlite-amalgamation-$SQLITE.zip
unzip -j sqlite.zip -d /opt/sqlite
cd /opt/sqlite
# Build the CLI.
gcc shell.c sqlite3.c -lpthread -ldl -lm -o sqlite3
# Build the shared library
gcc -c -fPIC sqlite3.c
gcc -shared -o libsqlite3.so -fPIC sqlite3.o -ldl -lpthread

# Hand-build DBD::SQLite against the version of SQLite just installed.
DIST=$(cpanm --info DBD::SQLite) # ISHIGAKI/DBD-SQLite-1.70.tar.gz
URL=https://cpan.metacpan.org/authors/id/${DIST:0:1}/${DIST:0:2}/$DIST
curl -o dbd.tar.gz "$URL"
tar zxvf dbd.tar.gz --strip-components 1
perl -i -pe 's/^if\s*\(\s*0\s*\)\s\{/if (1) {/' Makefile.PL
perl Makefile.PL SQLITE_INC=/opt/sqlite SQLITE_LIB=/opt/sqlite
make && make install

if [[ -n "$GITHUB_PATH" ]]; then
    echo "/opt/sqlite" >> "$GITHUB_PATH"
fi

if [[ -n "$GITHUB_ENV" ]]; then
    if [[ -z "$LD_LIBRARY_PATH" ]]; then
        echo "LD_LIBRARY_PATH=/opt/sqlite" >> "$GITHUB_ENV"
    else
        echo "LD_LIBRARY_PATH=/opt/sqlite:$LD_LIBRARY_PATH" >> "$GITHUB_ENV"
    fi
fi
