#! /bin/bash

#############################################
# Get stable encryption key or generate new #
#############################################

ENCRYPTION_PATH="$PWD/credentials/encryption.key"
mkdir -p "${ENCRYPTION_PATH%/*}"

ENCRYPTION_KEY=$(<"${ENCRYPTION_PATH}") || echo encryption key not found. Creating new encryption key
if [[ -z $ENCRYPTION_KEY ]];then
    ENCRYPTION_KEY=$(openssl genpkey --outform PEM --algorithm RSA --quiet)
    echo "$ENCRYPTION_KEY" > "$ENCRYPTION_PATH"
fi