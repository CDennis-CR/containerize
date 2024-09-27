#! /bin/bash

# This bash script is intended to setup a fresh Ubuntu VM to host a fully functional 
# production ready N8N deploy on microk8s Kubernetes distrobution, capable of 
# scalling up to at least a half dozen machine cluster. 
#
# This script should be run from the same dir (cd into it) so it can access
# the K8s manifests located in the same file. There should be 3 manifests supporting
# this script: 
# 
# - kong.k8s.yaml (sets up the reverse proxy gateway into the cluster)
# - postgres.k8s.yaml ( sets up a single replica postgres instance with persistant volume claim on the longhorn storage class)
# - n8n.k8s.yaml ( the n8n deploy )
#
# And one Kustomisation file within a parent dir
# - longhorn ( modifies an environment variable on the distributed storage service setup )
#
# It uses only kubectl and Helm - puposely to keep it simple, light weight and understanderble. 
# In future it will be better extendible to organise manifests as a Kustomize compiled project
# or use ArgoCD for the UI friendliness. 
#
# After go live the cluster can be used to host other applications - organised by namespace
#  and even share the database

#################################################
# Convenience - Generate encryption key for N8N #
#################################################
. "$PWD/keygen.sh"

##############################
# Setup microk8s environment #
##############################
sudo snap install microk8s --classic
microk8s status --wait-ready # if microk8s was already installed and stopped you may have to run `microk8s start`
microk8s enable dns
microk8s enable helm
microk8s enable metallb:10.240.0.0-10.240.255.255 # this is an CIDR block range that microk8s can distribute to objects

#######################
# Distributed storage #
#######################
# Install Longhorn:: https://longhorn.io/docs/1.7.1/deploy/install/install-with-kubectl/
# Note: this creates a default storageClass named longhorn which, to start, is fine to use out the box in prod
# docs:: https://longhorn.io/docs/1.7.1/best-practices/#storageclass
#
# Also Note: Longhorn has a UI frontend to monitor storage health with. It can be exposed by
# port forwarding using kubectl or providing an httpRoute to the longhorn-frontend service
# in the longhorn-system namespace.It is both trivial and non critical and thus is not done here
#
# Note that Microk8s has a non standard Kublet directory so applying the 
# manifests as per the docs on the website directlt results in deployment/longhorn-driver-deployer
# entering an infinite CrashLookBackoff loop. See: https://longhorn.io/kb/troubleshooting-none-standard-kubelet-dir/
# Fixed by setting the KUBELET_ROOT_DIR envar on the container. Done in the kustomization file with remote resource:
microk8s kubectl apply -k longhorn


##############
# Networking #
##############
# Install Kong K8s Gateway API operator:: https://docs.konghq.com/gateway-operator/latest/install/
microk8s helm repo add kong https://charts.konghq.com
microk8s helm repo update kong
microk8s helm upgrade --install kgo kong/gateway-operator -n kong-system --create-namespace --set image.tag=1.3
microk8s kubectl -n kong-system wait --for=condition=Available=true --timeout=120s deployment/kgo-gateway-operator-controller-manager
# Config a Gateway which will provision a Loadbalancer service in the background
microk8s kubectl apply -f "$PWD/kong.k8s.yaml"

#####################
# Application Stack #
#####################
# Install a postgres db to namespace `data-stores`
microk8s kubectl apply -f "$PWD/postgres.n8n.k8s.yaml"
# Install N8N as a statefulset with only one instance to namespace `comic-n8n`
microk8s kubectl apply -f "$PWD/n8n.k8s.yaml"

###############
# VM firewall #
###############
#sudo ufw default deny incoming # default to no incoming traffic
#sudo ufw default allow outgoing # default to allow all outgoing traffic
#sudo ufw allow 80 # assume Lightsail LB to VM cluster is unencrypted http to conventional port 80
#sudo ufw enable