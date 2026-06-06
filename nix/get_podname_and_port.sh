#!/bin/sh
# Get the application URL by running these commands:
export NODE_PORT=$(microk8s kubectl get --namespace portainer -o jsonpath="{.spec.ports[1].nodePort}" services portainer)
export NODE_IP=$(microk8s kubectl get nodes --namespace portainer -o jsonpath="{.items[0].status.addresses[0].address}")
echo https://$NODE_IP:$NODE_PORT
