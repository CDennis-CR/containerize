# containerize

Containerize is a set of scripts that allow for running of a demo suite of containers on VMs in a well structured and production ready way.

Its purpose is a demonstration of methods to run small microservice infrastructures using containers. It is a supplementary resource for the write up of internal container management within Comic Relief.

## Usage

It is designed to be run on a fresh Virtual Machine using Ubuntu OS, by simply using `rsync`to copy the files across, then running:

```bash
# container management using 
# - Microk8s
# - Kong gateway 
# - Longhorn
cd containerize/kubernetes && bash start.sh 
```
or 
```bash
# container management using
# - Podman
# - Caddy
cd containerize/podman && bash start.sh
```
As a test case, both scenarios run N8N containers with a Postgres data store.

This is usually enough to get setup. It is best practise to update the username/passwords/etc in the manifest before running to suite your needs.