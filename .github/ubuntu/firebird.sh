#!/bin/bash

set -e

# Download dependencies.
if [ -z "$SKIP_DEPENDS" ]; then
    sudo apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -qq firebird-dev firebird3.0-utils
fi

# Tell DBD::Firebird where to find the libraries.
if [[ ! -z "$GITHUB_ENV" ]]; then
    echo "FIREBIRD_HOME=/usr" >> $GITHUB_ENV
fi
