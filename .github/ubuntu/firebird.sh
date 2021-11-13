#!/bin/bash

set -e

# Download dependencies.
sudo apt-get update -qq
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -qq firebird-dev firebird3.0-utils
