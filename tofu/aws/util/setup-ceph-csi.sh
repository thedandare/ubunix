#!/bin/bash
set -e

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERRO: $*" >&2; exit 1; }

KUBECTL="sudo microk8s kubectl"
ROOK_NS="rook-ceph"
EXTERNAL_NS="rook-ceph-external"

# Obter mons do MicroCeph via mon dump
log "Obtendo mons do MicroCeph..."
MON_JSON_FILE=$(mktemp)
sudo ceph mon dump --format json 2>/dev/null > "$MON_JSON_FILE" || fail "ceph mon dump falhou"
MON_LIST=$(python3 - "$MON_JSON_FILE" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
for mon in d.get('mons', []):
    addr = mon.get('public_addr', '')
    if not addr:
        # try addrvec
        for a in mon.get('public_addrs', {}).get('addrvec', []):
            addr = a.get('addr', '')
            if addr:
                break
    if addr:
        print(addr)
PY
)
rm -f "$MON_JSON_FILE"

if [ -z "$MON_LIST" ]; then
    fail "Nao foi possivel obter mons do Ceph"
fi

MONITORS_JSON=$(python3 - <<PY
import json, sys
mons = [l.strip() for l in sys.stdin if l.strip()]
print(json.dumps(mons))
PY
<<< "$MON_LIST")

log "Monitores: $MONITORS_JSON"

FSID=$(sudo ceph fsid 2>/dev/null)
[ -z "$FSID" ] && fail "Nao foi possivel obter FSID"
log "FSID: $FSID"

# Copy secrets
log "Copiando secrets do namespace $EXTERNAL_NS para $ROOK_NS..."
for secret in rook-ceph-mon rook-csi-rbd-node rook-csi-rbd-provisioner; do
    if ! $KUBECTL get secret "$secret" -n "$ROOK_NS" >/dev/null 2>&1; then
        if $KUBECTL get secret "$secret" -n "$EXTERNAL_NS" >/dev/null 2>&1; then
            $KUBECTL get secret "$secret" -n "$EXTERNAL_NS" -o yaml | sed "s/namespace: $EXTERNAL_NS/namespace: $ROOK_NS/" | $KUBECTL apply -f - || true
            log "Secret $secret copiado para $ROOK_NS"
        fi
    fi
done

# Create config JSON
CONFIG_JSON=$(python3 - "$MONITORS_JSON" <<'PY'
import json, sys
monitors = json.loads(sys.argv[1])
config = [
    {
        "clusterID": "rook-ceph-external",
        "monitors": monitors,
        "cephFS": {
            "netNamespaceFilePath": "",
            "subvolumeGroup": "csi",
            "kernelMountOptions": "",
            "fuseMountOptions": ""
        },
        "rbd": {
            "radosNamespace": "",
            "netNamespaceFilePath": ""
        },
        "nfs": {
            "netNamespaceFilePath": ""
        },
        "readAffinity": {
            "enabled": False,
            "crushLocationLabels": []
        }
    }
]
print(json.dumps(config, indent=2))
PY
)

# Create/update ConfigMap
log "Criando ConfigMap ceph-csi-config..."
TEMP_CM=$(mktemp)
cat > "$TEMP_CM" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: ceph-csi-config
  namespace: rook-ceph
data:
  cluster-config.json: |
YAML
# indent json
python3 - "$CONFIG_JSON" <<'PY'
import sys
for line in sys.argv[1].splitlines():
    print("    " + line)
PY
 >> "$TEMP_CM"

$KUBECTL apply -f "$TEMP_CM"
rm -f "$TEMP_CM"

# Restart Ceph CSI
log "Reiniciando pods Ceph CSI..."
$KUBECTL rollout restart deployment rook-ceph.rbd.csi.ceph.com-ctrlplugin -n rook-ceph || true
$KUBECTL rollout restart daemonset rook-ceph.rbd.csi.ceph.com-nodeplugin -n rook-ceph || true

log "Aguardando pods..."
$KUBECTL rollout status deployment rook-ceph.rbd.csi.ceph.com-ctrlplugin -n rook-ceph --timeout=120s || true
$KUBECTL rollout status daemonset rook-ceph.rbd.csi.ceph.com-nodeplugin -n rook-ceph --timeout=120s || true

log "Configuracao concluida."
