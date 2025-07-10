#!/usr/bin/env bash

set -euo pipefail

: "${CASC_UID:=1000}"
: "${CASC_GID:=${CASC_UID}}"

# Get current UID/GID of casc-user
CURRENT_UID=$(id -u casc-user)
CURRENT_GID=$(id -g casc-user)

# If custom UID or GID is different, update the user/group
if [ "$CASC_UID" -ne "$CURRENT_UID" ] || [ "$CASC_GID" -ne "$CURRENT_GID" ]; then
    # apline does not support usermod -o, so we need to delete and recreate the user
    echo "Updating casc-user UID/GID from $CURRENT_UID:$CURRENT_GID to $CASC_UID:$CASC_GID"
    # Delete the user and group
    deluser casc-user || true
    # Create the group with the new GID
    addgroup -g "$CASC_GID" casc-user
    # Create the user with the new UID and GID, and set home directory
    adduser -D -u "$CASC_UID" -G casc-user -s /bin/bash -h /home/casc-user casc-user
    mkdir -p /home/casc-user/bin
    chown -R "$CASC_UID:$CASC_GID" /home/casc-user
fi

exec gosu casc-user "$@"
