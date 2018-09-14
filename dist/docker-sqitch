#!/bin/bash

user=${USER-$(whoami)}
if [ "Darwin" = $(uname) ]; then
    fullname=$(id -P $user | awk -F '[:]' '{print $8}')
else
    fullname=$(getent passwd $user | cut -d: -f5 | cut -d, -f1)
fi

docker run -it \
    --mount "type=bind,src=$(pwd),dst=/repo" \
    --mount "type=bind,src=$HOME,dst=/home" \
    -e "SQITCH_USER=$user" \
    -e "SQITCH_USER_NAME=$fullname" \
    -e "SQITCH_USER_NAME=$user@$(hostname)" \
    -e "TZ=$(date +%Z)" \
    -e "LESS=${LESS:--R}" \
    sqitch $@
