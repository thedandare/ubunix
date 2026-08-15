#!/usr/bin/env bash
set -euo pipefail

# Prints the postgres password stored in app-secret.

cd "$(dirname "$0")"
. ./common.sh

remote "microk8s kubectl get secret app-secret -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d"
echo
