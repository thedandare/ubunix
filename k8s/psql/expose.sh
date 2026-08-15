#!/usr/bin/env bash
set -euo pipefail

# Exposes the CloudNativePG cluster on 5432 using a plain NodePort Service.
# No Helm, no Traefik: the cloudnative-pg microk8s addon is not a Helm release
# and Traefik is not needed to proxy raw TCP to the primary.

cd "$(dirname "$0")"
. ./common.sh

echo "=== Copying manifest to remote server ==="
remote "mkdir -p $REMOTE_DIR"
copy expose.yaml

echo "=== Removing the old Traefik IngressRouteTCP (if any) ==="
remote "microk8s kubectl delete ingressroutetcp postgres-tcp -n default --ignore-not-found=true"

echo "=== Applying NodePort Service ==="
remote "microk8s kubectl apply -f $REMOTE_DIR/expose.yaml"

echo ""
echo "=== Verification ==="
remote "
echo '--- Service ---'
microk8s kubectl get svc postgres-server-ext -n default -o wide
echo ''
echo '--- Endpoints (must point at the primary pod) ---'
microk8s kubectl get endpointslice -n default -l kubernetes.io/service-name=postgres-server-ext \
  -o custom-columns=NAME:.metadata.name,ADDRESSES:.endpoints[*].addresses,READY:.endpoints[*].conditions.ready
echo ''
echo '--- Primary instance ---'
microk8s kubectl get pods -n default -l cnpg.io/cluster=$CLUSTER_NAME,cnpg.io/instanceRole=primary -o wide
"

echo ""
echo "=== PostgreSQL exposed ==="
echo "    in-cluster : $CLUSTER_NAME-rw.default.svc:5432"
echo "    node port  : <node-ip>:30432"
echo "    external   : 34.1.25.177:5432 / 34.1.28.21:5432 / 34.1.17.21:5432"
echo "    connect    : PGPASSWORD=\$(./get_app_secret.sh) psql -h 34.1.25.177 -U postgres postgres"
