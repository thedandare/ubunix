#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# HTTPS setup with Let's Encrypt via Traefik ACME
# ------------------------------------------------------------------
# Usage:
#   LE_EMAIL=you@example.com ./setup_https.sh
#
# This script:
#   1. Configures Traefik with an ACME certificate resolver named 'le'.
#   2. Updates the nginx-ingress to use web + websecure entrypoints.
#   3. Requests a TLS certificate for gcm.6nix.pl from Let's Encrypt.
# ------------------------------------------------------------------

# SSH / cluster settings
SSH_HOST="root@35.215.39.218"
SSH_KEY="/mnt/c/Users/leo/.ssh/root_id_ed25519"
if [ -f "/root/.ssh/root_id_ed25519" ]; then
  SSH_KEY="/root/.ssh/root_id_ed25519"
fi
PORT=22

TRAEFIK_VERSION="39.0.8"
REMOTE_DIR="/var/tmp4/k8s-dns"

# Convert Windows path backslashes to forward slashes for git bash / ssh
SSH_KEY_POSIX=$(echo "$SSH_KEY" | sed 's/\\/\//g')

# Domain that will get the TLS certificate
HTTPS_DOMAIN="gcm.6nix.pl"

# Let's Encrypt email (required for account registration)
LE_EMAIL="${LE_EMAIL:-thedandare@gmail.com}"

if [ -z "$LE_EMAIL" ] || [ "$LE_EMAIL" = "your-email@example.com" ]; then
  echo "ERROR: Set LE_EMAIL to a valid email address before running this script."
  echo "Example: LE_EMAIL=your-email@example.com ./setup_https.sh"
  exit 1
fi

echo "=== Copying ACME values to remote server ==="
ssh -i "$SSH_KEY_POSIX" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" "mkdir -p $REMOTE_DIR"

# Substitute the placeholder email in the values file and send it to the server
sed "s#your-email@example.com#$LE_EMAIL#g" traefik-values-acme.yaml | \
  ssh -i "$SSH_KEY_POSIX" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" \
    "cat > $REMOTE_DIR/traefik-values-acme.yaml"

echo "=== Upgrading Traefik with Let's Encrypt resolver 'le' ==="
ssh -i "$SSH_KEY_POSIX" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" \
  "microk8s helm3 upgrade traefik traefik/traefik \
    --version $TRAEFIK_VERSION \
    --namespace ingress \
    --reuse-values \
    --skip-schema-validation \
    -f $REMOTE_DIR/traefik-values-acme.yaml"

echo "=== Waiting for Traefik DaemonSet rollout ==="
ssh -i "$SSH_KEY_POSIX" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" \
  "microk8s kubectl rollout status ds/traefik -n ingress --timeout=180s"

echo "=== Applying HTTPS nginx-ingress ==="
ssh -i "$SSH_KEY_POSIX" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" \
  "cat > $REMOTE_DIR/nginx-ingress-https.yaml" <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-ingress
  namespace: default
  annotations:
    external-dns.alpha.kubernetes.io/target: "35.215.39.218"
    traefik.ingress.kubernetes.io/router.entrypoints: "web,websecure"
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.certresolver: "le"
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - gcm.6nix.pl
    secretName: gce-6nix-pl-tls
  rules:
  - host: gcm.6nix.pl
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx
            port:
              number: 80
EOF

ssh -i "$SSH_KEY_POSIX" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" \
  "microk8s kubectl apply -f $REMOTE_DIR/nginx-ingress-https.yaml"

echo "=== Waiting for certificate issuance (up to 5 minutes) ==="
for i in $(seq 1 30); do
  if ssh -i "$SSH_KEY_POSIX" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" \
       "microk8s kubectl get secret gce-6nix-pl-tls -n default >/dev/null 2>&1"; then
    echo "TLS secret gce-6nix-pl-tls is ready."
    break
  fi
  echo "  certificate not ready yet... waiting 10s"
  sleep 10
done

echo "=== Verification ==="
echo "Ingress routers:"
ssh -i "$SSH_KEY_POSIX" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" \
  "microk8s kubectl get ingress nginx-ingress -n default"

echo ""
echo "TLS secret:"
ssh -i "$SSH_KEY_POSIX" -p $PORT -o StrictHostKeyChecking=no "$SSH_HOST" \
  "microk8s kubectl get secret gce-6nix-pl-tls -n default 2>/dev/null || echo 'Secret not ready yet - check Traefik logs.'"

echo ""
echo "Done. Test with: https://$HTTPS_DOMAIN"
echo ""
echo "NOTE: ACME storage is a hostPath directory on each node (/opt/traefik-acme)."
echo "      For a production setup with many nodes, consider cert-manager instead."
echo ""
echo "To enable HTTPS for other ingresses, add the same annotations and a tls: block."
echo "  traefik.ingress.kubernetes.io/router.entrypoints: web,websecure"
echo "  traefik.ingress.kubernetes.io/router.tls: true"
echo "  traefik.ingress.kubernetes.io/router.tls.certresolver: le"
