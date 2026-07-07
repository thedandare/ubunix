#!/usr/bin/env bash
set -euo pipefail

SCRIPT_TAILSCALE="./init_tailscale.sh"
SCRIPT_MICROCEPH="./microceph_cluster_join.sh"
TEMPLATE_YAML="cloud-init.template.yaml"
OUTPUT_YAML="cloud-init.yaml"

log() { printf '%s\n' "$*"; }

sed_escape() {
  # Escapa &, barra e pipe para uso seguro em sed s|...|...|g.
  printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

b64_one_line() {
  base64 -w 0 "$1"
}

log "=== Compilacao declarativa do cloud-init ==="

if [ ! -f "$SCRIPT_MICROCEPH" ]; then
  log "MicroCeph nao encontrado; criando stub k8s-only: $SCRIPT_MICROCEPH"
  cat > "$SCRIPT_MICROCEPH" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "MicroCeph desativado nesta fase k8s-only."
exit 0
STUB
  chmod +x "$SCRIPT_MICROCEPH"
fi

for FILE in "$SCRIPT_TAILSCALE" "$SCRIPT_MICROCEPH" "$TEMPLATE_YAML"; do
  if [ ! -f "$FILE" ]; then
    log "ERRO: componente obrigatorio nao localizado: $FILE"
    exit 1
  fi
done

TS_ID="${TAILSCALE_CLIENT_ID:-}"
TS_SECRET="${TAILSCALE_CLIENT_SECRET:-}"

if [ -z "$TS_ID" ] || [ -z "$TS_SECRET" ]; then
  log "AVISO: TAILSCALE_CLIENT_ID ou TAILSCALE_CLIENT_SECRET vazios."
  log "O Ubuntu subira, mas o pareamento Tailscale deve falhar ate as credenciais serem fornecidas."
fi

log "Convertendo scripts para Base64..."
B64_TAILSCALE="$(b64_one_line "$SCRIPT_TAILSCALE")"
B64_MICROCEPH="$(b64_one_line "$SCRIPT_MICROCEPH")"

ESC_TS_ID="$(sed_escape "$TS_ID")"
ESC_TS_SECRET="$(sed_escape "$TS_SECRET")"

log "Gerando $OUTPUT_YAML..."
sed \
  -e "s|content: INJECT_TAILSCALE_B64_HERE|content: $B64_TAILSCALE|g" \
  -e "s|content: INJECT_MICROCEPH_B64_HERE|content: $B64_MICROCEPH|g" \
  -e "s|TAILSCALE_CLIENT_ID=\"\"|TAILSCALE_CLIENT_ID=\"$ESC_TS_ID\"|g" \
  -e "s|TAILSCALE_CLIENT_SECRET=\"\"|TAILSCALE_CLIENT_SECRET=\"$ESC_TS_SECRET\"|g" \
  "$TEMPLATE_YAML" > "$OUTPUT_YAML"

log "=== cloud-init.yaml gerado com sucesso ==="
