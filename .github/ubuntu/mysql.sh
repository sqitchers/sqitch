#!/bin/bash

set -e

# Download dependencies.
if [ -z "$SKIP_DEPENDS" ]; then
    sudo apt-get update -qq
    sudo apt-get remove -qq mysql-common # https://github.com/actions/virtual-environments/issues/5067#issuecomment-1038752575
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -qq mariadb-client libmariadbd-dev
fi
