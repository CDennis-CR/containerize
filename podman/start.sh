#! /bin/env bash

##################
# Prepare the VM #
################## 

# Update the registry of applications and get the latest version entries
sudo apt-get update
## This will upgrade ALL apt managed software on your VM - much of which you will not use
## Uncomment to automate mass upgrading of all apt managed software on the VM
#sudo apt-get upgrade -y

## Install the latest version of Podman
sudo apt-get -y install podman
## Install sqlite3 CLI to automate the backups via bash
sudo apt-get install sqlite3
## Install rclone to do the backup to object store
sudo snap install rclone
## Install cron to run regular updates - likely already installed on Ubuntu
sudo apt-get install cron

##############################
# Prepare Networking Options #
##############################

## Install networking Passt for use in rootless networking
echo "use PASTA for networking:" 
read -r -p "(y/n): " PASST
if [[  ${PASST,,} == "y" || ${PASST,,} ==  "yes" ]];then 
    sudo apt-get update
    sudo apt-get install -y passt
fi

################
# Create a Pod #
################

## Name of the pod used for encapsulation
POD_NAME="n8n"

## Create a new pod with the requested networking strategy
## Create pod exposing only Caddy ports
NETWORK_PASTA=pasta
NETWORK_SLIRP4NETNS="slirp4netns:port_handler=slirp4netns,allow_host_loopback=true"
NETWORK=$NETWORK_SLIRP4NETNS
if [[  ${PASST,,} == "y" || ${PASST,,} ==  "yes" ]];then 
    NETWORK=${NETWORK_PASTA}
fi
    podman pod create \
    --network ${NETWORK} \
    --name "${POD_NAME}" \
    -p 5678:5678 \
    -p 9000:9000 \
    -p 9001:9001 #9000 and 9001 for Minio during testing - remove in prod

########################
# Verify Caddy configs #
########################

## Location on host of the Caddyfile to mount which defines the operation of the reverse proxy
CADDY_FILE="$PWD/caddy/config/Caddyfile"
## Location on host of the TLS dir to mount with the cert and key used for terminating TLS and mutual TLS
CADDY_TLS="$PWD/caddy/config/tls"
## Location of dir on host to mount and persist reverse proxy data
CADDY_DATA="$PWD/caddy/data"

mkdir -p "${CADDY_TLS}"
mkdir -p "${CADDY_DATA}"

#format Caddy config
podman run \
--tty \
--rm \
--name caddy-format \
-v "${CADDY_FILE}":/etc/caddy/Caddyfile \
-v "${CADDY_DATA}":/data \
docker.io/library/caddy:2 caddy fmt --overwrite  /etc/caddy/Caddyfile || exit 1

#check Caddy config is valid
podman run \
--tty \
--rm \
--name caddy-validate \
-v "${CADDY_FILE}":/etc/caddy/Caddyfile \
-v "${CADDY_TLS}":/etc/caddy/tls \
-v "${CADDY_DATA}":/data \
docker.io/library/caddy:2 caddy validate --config /etc/caddy/Caddyfile || exit 1

#################################################
# Start Caddy as gateway reverse proxy into Pod #
#################################################

#run Caddy
podman run \
--pod ${POD_NAME} \
-dit \
--restart always \
--name caddy \
-v "${CADDY_FILE}":/etc/caddy/Caddyfile \
-v "${CADDY_TLS}":/etc/caddy/tls \
-v "${CADDY_DATA}":/data \
docker.io/library/caddy:2 caddy run --config /etc/caddy/Caddyfile #--watch


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


##########################################
# Start application stack within the Pod #
##########################################

## Start MinIO as a test S3 object store for backups with ephemeral data volume
## Uses ports 9000 for API and 9001 for the console (exposed on the pod)
##
##This means 
## https://hub.docker.com/r/minio/minio
podman run \
--dit \
--name minio \
--pod ${POD_NAME} \
quay.io/minio/minio server /data --console-address ":9001"


## Start N8N container
## Exposes port 5678 through the pod interface
##
## By default the database is located inside the container at: `~/.n8n/database.sqlite`
##
## Envar options: https://docs.n8n.io/hosting/configuration/environment-variables/deployment/
## Removes calls to n8n.io servers
##
## Sets N8N_ENCRYPTION_KEY so values can be recovered after failure. 
## Otherwise n8n regenerates and previous encrypted items are lost
##
## N8N_USER_FOLDER can change the dir of the .n8n directory - defaults to "~/"

N8N_DATA_DIR="$PWD/data"
SQLITE_DATA_FILE="${N8N_DATA_DIR}"/database.sqlite

mkdir -p "$N8N_DATA_DIR"

podman run \
-dit \
--name n8n \
--pod ${POD_NAME} \
-v "$N8N_DATA_DIR":/home/node/.n8n \
--env N8N_DIAGNOSTICS_ENABLED=false \
--env N8N_VERSION_NOTIFICATIONS_ENABLED=false \
--env N8N_TEMPLATES_ENABLED=false \
--env DB_TYPE=sqlite \
--env DB_SQLITE_VACUUM_ON_STARTUP=false \
--env N8N_ENCRYPTION_KEY="${ENCRYPTION_KEY}" \
--env GENERIC_TIMEZONE="Europe/London" \
--env WORKFLOWS_DEFAULT_NAME="CR_Workflow" \
--env N8N_PUSH_BACKEND="sse" \
--env N8N_HIRING_BANNER_ENABLED=false \
docker.n8n.io/n8nio/n8n


###################
# Set VM firewall #
###################
echo "Enable firewall?" 
read -r -p "(y/n): " FIREWALL
if [[ ${FIREWALL,,} == "y" || ${FIREWALL,,} ==  "yes" ]];then 
    echo configuring firewalls...
    sudo ufw default deny incoming # default to no incoming traffic
    sudo ufw default allow outgoing # default to allow all outgoing traffic
    sudo ufw allow 5678
    sudo ufw enable
fi


#############################################
# CRON the VACUUM INTO command on SQLite db #
#############################################
