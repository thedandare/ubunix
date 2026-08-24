#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-letta-app-server:local}"

cd "$(dirname "$0")"
echo "=== Building $IMAGE ==="
docker build --tag "$IMAGE" .

echo "=== Importing $IMAGE into the local MicroK8s image cache ==="
microk8s ctr image import <(docker save "$IMAGE")

echo "=== Image ready: $IMAGE ==="
