#!/bin/bash
# 1. Create a dedicated service account in the kube-system namespace
kubectl -n kube-system create serviceaccount headlamp-admin

# 2. Grant cluster-admin privileges to this service account
kubectl create clusterrolebinding headlamp-admin \
  --serviceaccount=kube-system:headlamp-admin \
  --clusterrole=cluster-admin
