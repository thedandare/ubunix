#!/usr/bin/env bash
# microk8s-microceph-whiptail.sh
# Automatiza o máximo possível da instalação do MicroCeph e integração com MicroK8s via rook-ceph.
#
# Modos suportados:
# - local: roda tudo no host atual.
# - ssh: controla nós remotos via SSH.
# - incus_cmd: Incus mode padrão; seleciona VMs/instâncias e executa um comando avulso via `incus exec`.
# - incus_microceph: fluxo completo MicroCeph + MicroK8s dentro das VMs Incus.
#
# Uso recomendado:
#   chmod +x microk8s-microceph-whiptail.sh
#   ./microk8s-microceph-whiptail.sh
#   ./microk8s-microceph-whiptail.sh --incus       # abre direto o executor Incus, sem exigir MicroK8s
#   ./microk8s-microceph-whiptail.sh --incus-cmd   # alias do modo acima
#   ./microk8s-microceph-whiptail.sh --incus-microceph # fluxo MicroCeph + MicroK8s em VMs Incus
#
# Premissas:
# - Local/SSH: rodar em um nó do MicroK8s, preferencialmente control-plane.
# - Incus cmd: rodar no host Incus; as VMs/instâncias selecionadas só precisam estar RUNNING.
# - Incus MicroCeph: as VMs selecionadas devem estar RUNNING e ter MicroK8s/snapd.
# - Nós Ubuntu/snap-compatible com snapd.
# - Para modo multi-node via SSH: SSH root ou sudo sem senha nos nós remotos.
# - Discos físicos selecionados serão apagados quando --wipe for usado.

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="${LOG_FILE:-/tmp/${SCRIPT_NAME%.sh}-$(date +%Y%m%d-%H%M%S).log}"
DEFAULT_SSH_PORT="${SSH_PORT:-2409}"
DEFAULT_SSH_USER="${SSH_USER:-root}"
DEFAULT_MICROCEPH_CHANNEL="${MICROCEPH_CHANNEL:-latest/stable}"

# EXEC_MODE controla como root_exec_on/root_capture_on chegam ao alvo.
# Valores: local, ssh, incus_cmd, incus_microceph.
EXEC_MODE="local"
CONTROL_TARGET=""
SSH_USER="$DEFAULT_SSH_USER"
SSH_PORT="$DEFAULT_SSH_PORT"
INCUS_PROJECT="${INCUS_PROJECT:-default}"
INCUS_REMOTE="${INCUS_REMOTE:-}"
INCUS_USE_SUDO="no"
INCUS_INSTANCE_KIND="vm"

# ─────────────────────────────────────────────────────────────────────────────
# UI helpers
# ─────────────────────────────────────────────────────────────────────────────
install_whiptail_if_possible() {
  if command -v whiptail >/dev/null 2>&1; then
    return 0
  fi

  echo "whiptail não encontrado. Tentando instalar via apt..."
  if command -v apt-get >/dev/null 2>&1; then
    if [[ "$(id -u)" -eq 0 ]]; then
      apt-get update && apt-get install -y whiptail
    else
      sudo apt-get update && sudo apt-get install -y whiptail
    fi
  fi

  if ! command -v whiptail >/dev/null 2>&1; then
    echo "ERRO: whiptail é obrigatório. Instale com: sudo apt-get install -y whiptail" >&2
    exit 1
  fi
}

msg() {
  whiptail --title "$SCRIPT_NAME" --msgbox "$1" 18 78
}

info() {
  whiptail --title "$SCRIPT_NAME" --infobox "$1" 10 78
  sleep 1
}

ask_yesno() {
  local text="$1"
  whiptail --title "$SCRIPT_NAME" --yesno "$text" 16 78
}

input_box() {
  local text="$1"
  local default="${2:-}"
  whiptail --title "$SCRIPT_NAME" --inputbox "$text" 14 78 "$default" 3>&1 1>&2 2>&3
}

menu_box() {
  local text="$1"
  shift
  whiptail --title "$SCRIPT_NAME" --menu "$text" 22 90 12 "$@" 3>&1 1>&2 2>&3
}

checklist_box() {
  local text="$1"
  shift
  whiptail --title "$SCRIPT_NAME" --checklist "$text" 24 96 14 "$@" 3>&1 1>&2 2>&3
}

fatal() {
  local text="ERRO: $1\n\nLog: $LOG_FILE"
  echo "$text" | tee -a "$LOG_FILE" >&2
  whiptail --title "$SCRIPT_NAME" --msgbox "$text" 18 78 || true
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >/dev/null
}

run_quiet() {
  log "+ $*"
  "$@" >>"$LOG_FILE" 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# Root / local / SSH / Incus helpers
# ─────────────────────────────────────────────────────────────────────────────
LOCAL_HOST_SHORT="$(hostname -s)"
LOCAL_HOST_FQDN="$(hostname -f 2>/dev/null || hostname -s)"

is_local_target() {
  local target="$1"
  [[ "$target" == "localhost" || "$target" == "127.0.0.1" || "$target" == "$LOCAL_HOST_SHORT" || "$target" == "$LOCAL_HOST_FQDN" || "$target" == "$(hostname)" ]]
}

root_exec_local() {
  local cmd="$1"
  log "[local] # $cmd"
  if [[ "$(id -u)" -eq 0 ]]; then
    bash -lc "set -Eeuo pipefail; $cmd" >>"$LOG_FILE" 2>&1
  else
    sudo bash -lc "set -Eeuo pipefail; $cmd" >>"$LOG_FILE" 2>&1
  fi
}

root_capture_local() {
  local cmd="$1"
  log "[local/capture] # $cmd"
  if [[ "$(id -u)" -eq 0 ]]; then
    bash -lc "set -Eeuo pipefail; $cmd" 2>>"$LOG_FILE"
  else
    sudo bash -lc "set -Eeuo pipefail; $cmd" 2>>"$LOG_FILE"
  fi
}

root_exec_remote() {
  local target="$1"
  local cmd="$2"
  local wrapped quoted
  wrapped="set -Eeuo pipefail; $cmd"
  quoted="$(printf '%q' "$wrapped")"
  log "[$target/ssh] # $cmd"

  # -tt permite sudo interativo se necessário, mas o ideal é SSH root ou sudo NOPASSWD.
  ssh -tt \
    -o StrictHostKeyChecking=accept-new \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=4 \
    -p "$SSH_PORT" \
    "${SSH_USER}@${target}" \
    "if [ \"\$(id -u)\" -eq 0 ]; then bash -lc $quoted; else sudo bash -lc $quoted; fi" \
    >>"$LOG_FILE" 2>&1
}

root_capture_remote() {
  local target="$1"
  local cmd="$2"
  local wrapped quoted
  wrapped="set -Eeuo pipefail; $cmd"
  quoted="$(printf '%q' "$wrapped")"
  log "[$target/ssh/capture] # $cmd"

  ssh \
    -o StrictHostKeyChecking=accept-new \
    -o BatchMode=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=4 \
    -p "$SSH_PORT" \
    "${SSH_USER}@${target}" \
    "if [ \"\$(id -u)\" -eq 0 ]; then bash -lc $quoted; else sudo -n bash -lc $quoted; fi" \
    2>>"$LOG_FILE"
}

incus_target_name() {
  local target="$1"
  if [[ -n "$INCUS_REMOTE" ]]; then
    printf '%s:%s' "$INCUS_REMOTE" "$target"
  else
    printf '%s' "$target"
  fi
}

incus_cmd() {
  local argv=()
  if [[ "$INCUS_USE_SUDO" == "yes" ]]; then
    argv+=(sudo -n)
  fi
  argv+=(incus)
  if [[ -n "$INCUS_PROJECT" ]]; then
    argv+=(--project "$INCUS_PROJECT")
  fi
  "${argv[@]}" "$@"
}

detect_incus_access() {
  command -v incus >/dev/null 2>&1 || command -v sudo >/dev/null 2>&1 || fatal "incus não encontrado no PATH e sudo indisponível."

  INCUS_USE_SUDO="no"
  if incus --version >/dev/null 2>&1 && incus_cmd list --format csv -c n >/dev/null 2>>"$LOG_FILE"; then
    log "Incus acessível sem sudo."
    return 0
  fi

  if command -v sudo >/dev/null 2>&1 && sudo -n incus --version >/dev/null 2>&1; then
    INCUS_USE_SUDO="yes"
    if incus_cmd list --format csv -c n >/dev/null 2>>"$LOG_FILE"; then
      log "Incus acessível via sudo -n."
      return 0
    fi
  fi

  fatal "não consegui acessar o Incus. Rode como root, entre no grupo incus-admin, ou configure sudo sem senha para incus."
}

root_exec_incus() {
  local target="$1"
  local cmd="$2"
  local inst
  inst="$(incus_target_name "$target")"
  log "[$inst/incus] # $cmd"
  incus_cmd exec "$inst" -- bash -lc "set -Eeuo pipefail; $cmd" >>"$LOG_FILE" 2>&1
}

root_capture_incus() {
  local target="$1"
  local cmd="$2"
  local inst
  inst="$(incus_target_name "$target")"
  log "[$inst/incus/capture] # $cmd"
  incus_cmd exec "$inst" -- bash -lc "set -Eeuo pipefail; $cmd" 2>>"$LOG_FILE"
}

root_exec_on() {
  local target="$1"
  local cmd="$2"

  if [[ "$EXEC_MODE" == "incus_cmd" || "$EXEC_MODE" == "incus_microceph" ]]; then
    root_exec_incus "$target" "$cmd"
  elif is_local_target "$target"; then
    root_exec_local "$cmd"
  else
    root_exec_remote "$target" "$cmd"
  fi
}

root_capture_on() {
  local target="$1"
  local cmd="$2"

  if [[ "$EXEC_MODE" == "incus_cmd" || "$EXEC_MODE" == "incus_microceph" ]]; then
    root_capture_incus "$target" "$cmd"
  elif is_local_target "$target"; then
    root_capture_local "$cmd"
  else
    root_capture_remote "$target" "$cmd"
  fi
}

host_short_on() {
  local target="$1"
  root_capture_on "$target" "hostname -s" | tr -d '\r' | tail -n1
}

array_contains_local_target() {
  local item
  for item in "$@"; do
    if is_local_target "$item"; then
      return 0
    fi
  done
  return 1
}

parse_whiptail_selection() {
  # whiptail checklist normalmente retorna: "vm1" "vm2".
  # Nomes Incus não têm espaços; então xargs funciona bem aqui.
  local selection="$1"
  printf '%s\n' "$selection" | xargs -n1 | sed 's/^"//;s/"$//' | sed '/^$/d'
}

local_microk8s_bin_exists() {
  command -v microk8s >/dev/null 2>&1
}

local_incus_bin_exists() {
  command -v incus >/dev/null 2>&1 || { command -v sudo >/dev/null 2>&1 && sudo -n incus --version >/dev/null 2>&1; }
}

switch_from_host_microk8s_mode_if_needed() {
  # Evita o problema comum no host Incus: o host não tem MicroK8s,
  # mas as VMs têm. O script antigo abortava antes de chegar no modo Incus.
  if [[ "$MODE" != "local" && "$MODE" != "ssh" ]]; then
    return 0
  fi

  if local_microk8s_bin_exists; then
    return 0
  fi

  if local_incus_bin_exists; then
    if ask_yesno "Este host não tem o comando microk8s.\n\nIsso é normal quando você está no HOST Incus e o MicroK8s está DENTRO das VMs.\n\nQuer trocar para um modo Incus agora?"; then
      MODE="$(menu_box "Escolha o modo Incus" \
        incus_cmd "Selecionar VMs e executar um comando avulso; NÃO exige MicroK8s" \
        incus_microceph "Fluxo completo MicroCeph + MicroK8s dentro das VMs")" || exit 1
      EXEC_MODE="$MODE"
    else
      fatal "microk8s não encontrado neste host. Para local/ssh, rode em um nó MicroK8s; para host Incus, escolha modo Incus."
    fi
  else
    fatal "microk8s não encontrado neste host. Para local/ssh, rode em um nó MicroK8s; para Incus, instale/use o cliente incus no host."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Incus selection / command runner
# ─────────────────────────────────────────────────────────────────────────────
incus_list_running_instances() {
  local kind="$1"
  local list_args=()

  if [[ -n "$INCUS_REMOTE" ]]; then
    list_args+=("${INCUS_REMOTE}:")
  fi

  if [[ "$kind" == "vm" ]]; then
    list_args+=("type=virtual-machine")
  fi
  list_args+=("status=running")

  # Colunas: name,state. CSV sem cabeçalho facilita whiptail/script.
  incus_cmd list "${list_args[@]}" --format csv -c ns 2>>"$LOG_FILE" || true
}

select_incus_targets() {
  local purpose="${1:-Selecione as VMs Incus}"
  local selected raw line name status desc
  local checklist_args=()

  INCUS_PROJECT="$(input_box "Projeto Incus" "${INCUS_PROJECT:-default}")" || exit 1
  INCUS_REMOTE="$(input_box "Remote Incus opcional. Deixe vazio para o daemon local.\nExemplo: prod" "${INCUS_REMOTE:-}")" || exit 1

  detect_incus_access

  INCUS_INSTANCE_KIND="$(menu_box "Que tipo de instância listar?" \
    vm "Somente VMs Incus RUNNING" \
    all "VMs e containers RUNNING")" || exit 1

  raw="$(incus_list_running_instances "$INCUS_INSTANCE_KIND")"

  if [[ -z "$(printf '%s' "$raw" | xargs || true)" && "$INCUS_INSTANCE_KIND" == "vm" ]]; then
    if ask_yesno "Não encontrei VMs Incus RUNNING neste projeto/remote.\n\nListar também containers RUNNING?"; then
      INCUS_INSTANCE_KIND="all"
      raw="$(incus_list_running_instances "$INCUS_INSTANCE_KIND")"
    fi
  fi

  [[ -n "$(printf '%s' "$raw" | xargs || true)" ]] || fatal "nenhuma instância Incus RUNNING encontrada."

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=',' read -r name status <<<"$line"
    [[ -n "$name" ]] || continue
    desc="${status:-UNKNOWN}/${INCUS_INSTANCE_KIND}"
    checklist_args+=("$name" "$desc" "OFF")
  done <<<"$raw"

  selected="$(checklist_box "$purpose\n\nProjeto: ${INCUS_PROJECT:-default}\nRemote: ${INCUS_REMOTE:-local}" "${checklist_args[@]}")" || exit 1
  mapfile -t TARGETS < <(parse_whiptail_selection "$selected")
  [[ "${#TARGETS[@]}" -ge 1 ]] || fatal "nenhuma instância selecionada."

  if [[ "${#TARGETS[@]}" -eq 1 ]]; then
    CONTROL_TARGET="${TARGETS[0]}"
  else
    local menu_args=()
    local t
    for t in "${TARGETS[@]}"; do
      menu_args+=("$t" "usar como nó de controle/bootstrap/MicroK8s")
    done
    CONTROL_TARGET="$(menu_box "Escolha a VM/instância de controle.\nÉ nela que rodam microceph cluster bootstrap e microk8s connect-external-ceph." "${menu_args[@]}")" || exit 1
  fi
}

run_custom_command_on_selected_targets() {
  local cmd tmp target rc

  [[ "${#TARGETS[@]}" -ge 1 ]] || fatal "nenhuma VM/instância selecionada para executar comando."

  cmd="$(input_box "Comando a executar como root dentro das instâncias selecionadas" "hostname -s && uptime")" || exit 1
  [[ -n "$cmd" ]] || fatal "comando vazio."

  tmp="/tmp/${SCRIPT_NAME%.sh}-incus-cmd-$(date +%Y%m%d-%H%M%S).txt"
  : >"$tmp"

  for target in "${TARGETS[@]}"; do
    {
      echo "===== ${target} ====="
      echo "# $cmd"
    } | tee -a "$LOG_FILE" >>"$tmp"

    set +e
    root_capture_on "$target" "$cmd" >>"$tmp" 2>>"$LOG_FILE"
    rc=$?
    set -e

    {
      echo
      echo "[exit_code=$rc]"
      echo
    } >>"$tmp"
  done

  whiptail --title "$SCRIPT_NAME - saída Incus" --textbox "$tmp" 30 120
  msg "Comando concluído.\n\nSaída: $tmp\nLog: $LOG_FILE"
}

run_incus_custom_command_mode() {
  select_incus_targets "Selecione uma ou mais VMs/instâncias para executar um comando avulso"
  run_custom_command_on_selected_targets
}

# ─────────────────────────────────────────────────────────────────────────────
# Kubernetes / MicroK8s helpers
# ─────────────────────────────────────────────────────────────────────────────
microk8s_nodes_guess() {
  if command -v microk8s >/dev/null 2>&1; then
    root_capture_local "microk8s status --wait-ready >/dev/null && microk8s kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{end}'" 2>/dev/null || true
  fi
}

addon_enabled_on_control() {
  local addon="$1"
  root_capture_on "$CONTROL_TARGET" "microk8s status" 2>/dev/null | grep -Eq "^[[:space:]]*${addon}:[[:space:]]*enabled"
}

validate_microk8s_on_control() {
  local where="$CONTROL_TARGET"
  [[ -n "$where" ]] || fatal "CONTROL_TARGET vazio."

  if ! root_capture_on "$where" "command -v microk8s >/dev/null && echo ok" | grep -q '^ok$'; then
    if [[ "$EXEC_MODE" == "incus_microceph" ]]; then
      msg "MicroK8s NÃO foi encontrado dentro da VM/instância de controle:\n\n$where\n\nPara o fluxo MicroCeph + MicroK8s, o MicroK8s precisa existir dentro desta VM.\n\nSe sua intenção era só selecionar VMs e rodar um comando, usei o caminho errado: vamos abrir o executor Incus agora."
      if ask_yesno "Executar um comando avulso nas VMs/instâncias já selecionadas?"; then
        run_custom_command_on_selected_targets
        exit 0
      fi
    fi
    fatal "microk8s não encontrado no alvo de controle: $where"
  fi

  if ! root_exec_on "$where" "microk8s status --wait-ready"; then
    if [[ "$EXEC_MODE" == "incus_microceph" ]]; then
      msg "Encontrei o comando microk8s em $where, mas 'microk8s status --wait-ready' falhou.\n\nVocê ainda pode usar o modo de comando avulso para diagnosticar as VMs."
      if ask_yesno "Executar comando diagnóstico nas VMs/instâncias selecionadas?"; then
        run_custom_command_on_selected_targets
        exit 0
      fi
    fi
    fatal "microk8s status --wait-ready falhou em $where."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MicroCeph steps
# ─────────────────────────────────────────────────────────────────────────────
install_microceph_on() {
  local target="$1"
  info "Instalando/verificando MicroCeph em: $target"
  root_exec_on "$target" "
    if ! command -v snap >/dev/null 2>&1; then
      echo 'snap não encontrado neste nó. MicroCeph via snap requer snapd.' >&2
      exit 20
    fi
    if ! snap list microceph >/dev/null 2>&1; then
      snap install microceph --channel '$MICROCEPH_CHANNEL'
    else
      echo 'MicroCeph já instalado.'
    fi
    snap refresh --hold microceph || true
  "
}

microceph_status_ok_on() {
  local target="$1"
  root_capture_on "$target" "microceph status >/dev/null 2>&1 && echo ok || true" | grep -q '^ok$'
}

bootstrap_microceph_control_if_needed() {
  info "Inicializando cluster MicroCeph no controle ($CONTROL_TARGET), se necessário..."
  if microceph_status_ok_on "$CONTROL_TARGET"; then
    log "MicroCeph já parece inicializado em $CONTROL_TARGET. Pulando bootstrap."
    return 0
  fi
  root_exec_on "$CONTROL_TARGET" "microceph cluster bootstrap"
}

join_microceph_node_if_needed() {
  local target="$1"
  local node_name token

  if [[ "$target" == "$CONTROL_TARGET" ]]; then
    return 0
  fi
  if [[ "$EXEC_MODE" != "incus_cmd" && "$EXEC_MODE" != "incus_microceph" ]] && is_local_target "$target" && is_local_target "$CONTROL_TARGET"; then
    return 0
  fi

  info "Entrando o nó $target no cluster MicroCeph..."

  if microceph_status_ok_on "$target"; then
    log "MicroCeph já inicializado em $target. Pulando join."
    return 0
  fi

  node_name="$(host_short_on "$target")"
  [[ -n "$node_name" ]] || fatal "não consegui descobrir hostname curto de $target."

  token="$(root_capture_on "$CONTROL_TARGET" "microceph cluster add '$node_name'" | tr -d '\r' | tail -n1)"
  [[ -n "$token" ]] || fatal "não consegui gerar token MicroCeph para $node_name."

  root_exec_on "$target" "microceph cluster join '$token'"
}

add_physical_disks_on() {
  local target="$1"
  local disks="$2"
  info "Adicionando discos físicos em $target: $disks"
  # shellcheck disable=SC2086
  root_exec_on "$target" "microceph disk add $disks --wipe"
}

add_all_available_on() {
  local target="$1"
  info "Adicionando todos os discos disponíveis em $target"
  root_exec_on "$target" "microceph disk add --all-available --wipe"
}

add_loop_osds_on() {
  local target="$1"
  local count="$2"
  local size="$3"
  info "Criando $count OSD(s) loop de $size em $target"

  root_exec_on "$target" "
    mkdir -p /var/snap/microceph/common/loop-osd
    letters=(a b c d e f g h i j k l m n o p q r s t u v w x y z)
    count='$count'
    size='$size'
    if [ \"\$count\" -gt 26 ]; then
      echo 'máximo de 26 loop OSDs por execução' >&2
      exit 30
    fi
    for ((i=0; i<count; i++)); do
      letter=\"\${letters[\$i]}\"
      loop_file=\"\$(mktemp -p /var/snap/microceph/common/loop-osd microceph-osd-XXXXXX.img)\"
      truncate -s \"\$size\" \"\$loop_file\"
      loop_dev=\"\$(losetup --show -f \"\$loop_file\")\"
      minor=\"\${loop_dev##/dev/loop}\"
      alias_dev=\"/dev/sdi\${letter}\"
      rm -f \"\$alias_dev\"
      mknod -m 0660 \"\$alias_dev\" b 7 \"\$minor\"
      microceph disk add --wipe \"\$alias_dev\"
    done
  "
}

configure_ceph_defaults() {
  local replica_size="$1"
  local single_node="$2"

  info "Aplicando defaults do Ceph no controle ($CONTROL_TARGET): replica size=$replica_size"
  root_exec_on "$CONTROL_TARGET" "microceph.ceph config set global osd_pool_default_size '$replica_size'"
  root_exec_on "$CONTROL_TARGET" "microceph.ceph config set mgr mgr_standby_modules false || true"

  if [[ "$single_node" == "yes" ]]; then
    # Em cluster de 1 host, permitir réplicas em OSDs no mesmo host. Não é HA; é para lab/single-node.
    root_exec_on "$CONTROL_TARGET" "microceph.ceph config set osd osd_crush_chooseleaf_type 0"
  fi
}

connect_microceph_to_microk8s() {
  local make_default="$1"
  local run_test="$2"

  info "Conectando MicroCeph ao MicroK8s via rook-ceph no controle ($CONTROL_TARGET)..."

  root_exec_on "$CONTROL_TARGET" "modprobe rbd || true"
  root_exec_on "$CONTROL_TARGET" "microk8s status --wait-ready" || fatal "MicroK8s não ficou ready em $CONTROL_TARGET. Veja $LOG_FILE"

  if addon_enabled_on_control rook-ceph; then
    log "Addon rook-ceph já está habilitado em $CONTROL_TARGET."
  else
    root_exec_on "$CONTROL_TARGET" "microk8s enable rook-ceph"
  fi

  # O operador pode demorar um pouco para aparecer; não aborta se a versão/namespace variar.
  root_exec_on "$CONTROL_TARGET" "microk8s kubectl -n rook-ceph rollout status deploy/rook-ceph-operator --timeout=300s || true"

  # O helper sem argumentos funciona quando MicroCeph está no mesmo host/VM do MicroK8s de controle.
  root_exec_on "$CONTROL_TARGET" "microk8s connect-external-ceph"

  root_exec_on "$CONTROL_TARGET" "microk8s kubectl get storageclass"

  if [[ "$make_default" == "yes" ]]; then
    info "Marcando ceph-rbd como StorageClass default..."
    root_exec_on "$CONTROL_TARGET" "
      for sc in \$(microk8s kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{\" \"}{end}'); do
        microk8s kubectl patch storageclass \"\$sc\" -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"false\"}}}' || true
      done
      microk8s kubectl patch storageclass ceph-rbd -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'
    "
  fi

  if [[ "$run_test" == "yes" ]]; then
    info "Testando PVC ceph-rbd de 1Gi..."
    root_exec_on "$CONTROL_TARGET" "
      cat <<'YAML' | microk8s kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: microceph-test
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rbd-smoke-test
  namespace: microceph-test
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ceph-rbd
  resources:
    requests:
      storage: 1Gi
YAML
      microk8s kubectl -n microceph-test wait --for=jsonpath='{.status.phase}'=Bound pvc/rbd-smoke-test --timeout=180s
      microk8s kubectl -n microceph-test get pvc rbd-smoke-test
    "
  fi
}

show_status() {
  local tmp="/tmp/microceph-final-status.txt"
  info "Coletando status final em $CONTROL_TARGET..."

  root_capture_on "$CONTROL_TARGET" "
    echo '===== microceph status ====='
    microceph status || true
    echo
    echo '===== ceph status ====='
    microceph.ceph status || true
    echo
    echo '===== microceph disk list ====='
    microceph disk list || true
    echo
    echo '===== storageclasses ====='
    microk8s kubectl get storageclass || true
    echo
    echo '===== rook-ceph pods ====='
    microk8s kubectl -n rook-ceph get pods -o wide || true
  " | tee -a "$LOG_FILE" >"$tmp"

  whiptail --title "$SCRIPT_NAME - status final" --textbox "$tmp" 30 110
}

# ─────────────────────────────────────────────────────────────────────────────
# Main flow
# ─────────────────────────────────────────────────────────────────────────────
main() {
  install_whiptail_if_possible
  : >"$LOG_FILE"

  # Guarda dura: --incus e --incus-cmd são SOMENTE executor de comandos.
  # Não pode existir nenhuma checagem de microk8s antes deste desvio.
  case "${1:-}" in
    --incus|--incus-cmd|--incus_cmd)
      MODE="incus_cmd"
      EXEC_MODE="incus_cmd"
      run_incus_custom_command_mode
      exit 0
      ;;
  esac

  msg "Este script instala/configura MicroCeph e conecta ao MicroK8s via rook-ceph.\n\nATENÇÃO: opções com discos físicos usam --wipe e APAGAM os discos selecionados.\n\nNovo: modo Incus padrão lista VMs/instâncias RUNNING e executa comandos via incus exec, sem exigir MicroK8s no host.\n\nLog:\n$LOG_FILE"

  REQUESTED_MODE="${1:-}"
  case "$REQUESTED_MODE" in
    --local) MODE="local" ;;
    --ssh) MODE="ssh" ;;
    --incus|--incus-cmd|--incus_cmd) MODE="incus_cmd" ;;
    --incus-microceph|--incus_microceph) MODE="incus_microceph" ;;
    "")
      MODE="$(menu_box "Modo de operação" \
        incus_cmd "Incus mode: selecionar VMs e executar comando; NÃO exige MicroK8s" \
        incus_microceph "Incus MicroCeph: fluxo completo dentro das VMs; exige MicroK8s na VM de controle" \
        local "Local: instala MicroCeph neste host MicroK8s" \
        ssh "SSH: usa este host MicroK8s como controle e entra nós remotos")" || exit 1
      ;;
    *)
      fatal "opção desconhecida: $REQUESTED_MODE\n\nUse: --incus, --incus-cmd, --incus-microceph, --local ou --ssh"
      ;;
  esac

  EXEC_MODE="$MODE"

  # IMPORTANTÍSSIMO:
  # O "Incus mode" pedido aqui é apenas um executor de comandos em VMs/instâncias.
  # Ele NÃO deve validar MicroK8s no host nem dentro das VMs, senão volta o erro
  # "microk8s não encontrado" antes de o usuário conseguir rodar diagnósticos.
  if [[ "$MODE" == "incus_cmd" ]]; then
    run_incus_custom_command_mode
    exit 0
  fi

  switch_from_host_microk8s_mode_if_needed

  # Se o usuário entrou em local/ssh por engano em um host Incus sem microk8s
  # e aceitou trocar para o executor Incus, precisamos sair AGORA para não cair
  # no fluxo MicroCeph/MicroK8s abaixo.
  if [[ "$MODE" == "incus_cmd" ]]; then
    EXEC_MODE="incus_cmd"
    run_incus_custom_command_mode
    exit 0
  fi

  TARGETS=("$LOCAL_HOST_SHORT")
  CONTROL_TARGET="$LOCAL_HOST_SHORT"

  case "$MODE" in
    local)
      command -v microk8s >/dev/null 2>&1 || fatal "microk8s não encontrado neste host. Rode em um nó do MicroK8s ou use --incus-cmd/--incus no host Incus."
      root_exec_local "microk8s status --wait-ready" || fatal "microk8s status --wait-ready falhou."
      ;;
    ssh)
      command -v microk8s >/dev/null 2>&1 || fatal "microk8s não encontrado neste host. No modo SSH, o host local continua sendo o controle MicroK8s/MicroCeph; no host Incus use --incus-cmd/--incus."
      root_exec_local "microk8s status --wait-ready" || fatal "microk8s status --wait-ready falhou."

      guessed="$(microk8s_nodes_guess | xargs || true)"
      [[ -n "$guessed" ]] || guessed="$LOCAL_HOST_SHORT"

      SSH_USER="$(input_box "Usuário SSH para nós remotos" "$DEFAULT_SSH_USER")" || exit 1
      SSH_PORT="$(input_box "Porta SSH" "$DEFAULT_SSH_PORT")" || exit 1

      targets_line="$(input_box "Nós/targets SSH separados por espaço.\nUse nomes resolvíveis via SSH.\nO nó local será incluído automaticamente se faltar." "$guessed")" || exit 1
      read -r -a TARGETS <<<"$targets_line"
      [[ "${#TARGETS[@]}" -ge 1 ]] || fatal "nenhum target informado."
      if ! array_contains_local_target "${TARGETS[@]}"; then
        TARGETS=("$LOCAL_HOST_SHORT" "${TARGETS[@]}")
      fi
      CONTROL_TARGET="$LOCAL_HOST_SHORT"

      # Teste básico de SSH antes de mexer em cluster.
      for target in "${TARGETS[@]}"; do
        if is_local_target "$target"; then
          continue
        fi
        info "Testando SSH em $target..."
        root_capture_remote "$target" "hostname -s" >/dev/null || fatal "falha no SSH/sudo em $target. Configure SSH root ou sudo NOPASSWD."
      done
      ;;
    incus_microceph)
      select_incus_targets "Selecione uma ou mais VMs/instâncias Incus para formar o cluster MicroCeph"
      validate_microk8s_on_control
      ;;
    *)
      fatal "modo desconhecido: $MODE"
      ;;
  esac

  MICROCEPH_CHANNEL="$(input_box "Canal snap do MicroCeph" "$DEFAULT_MICROCEPH_CHANNEL")" || exit 1
  [[ -n "$MICROCEPH_CHANNEL" ]] || fatal "canal MicroCeph vazio."

  # Seleção de storage/OSD.
  STORAGE_MODE="$(menu_box "Como adicionar storage/OSDs?" \
    physical_same "Usar mesmos discos físicos em todos os nós, ex: /dev/vdb" \
    all_available "Usar TODOS os discos disponíveis em cada nó: perigoso" \
    loop_lab "Criar loop OSDs: apenas lab/teste, não produção" \
    skip "Não adicionar discos agora")" || exit 1

  DISKS=""
  LOOP_COUNT="3"
  LOOP_SIZE="10G"

  case "$STORAGE_MODE" in
    physical_same)
      DISKS="$(input_box "Discos físicos a adicionar em CADA nó.\nExemplo: /dev/vdb ou /dev/sdb /dev/sdc\n\nEles serão apagados com --wipe." "/dev/vdb")" || exit 1
      [[ -n "$DISKS" ]] || fatal "lista de discos vazia."
      confirm="$(input_box "Digite exatamente WIPE para confirmar que estes discos serão apagados:\n$DISKS" "")" || exit 1
      [[ "$confirm" == "WIPE" ]] || fatal "confirmação WIPE não recebida. Abortando."
      ;;
    all_available)
      confirm="$(input_box "PERIGO: todos os discos físicos disponíveis em cada nó serão usados com --all-available --wipe.\nDigite exatamente WIPE_ALL para confirmar." "")" || exit 1
      [[ "$confirm" == "WIPE_ALL" ]] || fatal "confirmação WIPE_ALL não recebida. Abortando."
      ;;
    loop_lab)
      LOOP_COUNT="$(input_box "Quantidade de loop OSDs por nó" "3")" || exit 1
      LOOP_SIZE="$(input_box "Tamanho de cada loop OSD. Ex: 10G, 50G, 100G" "10G")" || exit 1
      if ! [[ "$LOOP_COUNT" =~ ^[0-9]+$ ]] || [[ "$LOOP_COUNT" -lt 1 ]]; then
        fatal "quantidade de loop OSDs inválida."
      fi
      ;;
    skip)
      ;;
  esac

  target_count="${#TARGETS[@]}"
  default_replica="3"
  if [[ "$target_count" -lt 3 ]]; then
    default_replica="$target_count"
  fi
  [[ "$default_replica" -lt 1 ]] && default_replica="1"

  REPLICA_SIZE="$(input_box "Replica count Ceph para novos pools.\n3 é o normal para 3+ nós.\n1 só para single-node/lab.\n2 para cluster pequeno de 2 nós." "$default_replica")" || exit 1
  if ! [[ "$REPLICA_SIZE" =~ ^[0-9]+$ ]] || [[ "$REPLICA_SIZE" -lt 1 ]]; then
    fatal "replica count inválido."
  fi

  MAKE_DEFAULT="no"
  if ask_yesno "Marcar ceph-rbd como StorageClass default do cluster?"; then
    MAKE_DEFAULT="yes"
  fi

  RUN_TEST="no"
  if ask_yesno "Criar um PVC de teste de 1Gi para validar o provisionamento?"; then
    RUN_TEST="yes"
  fi

  summary="Modo: $MODE\nControle: $CONTROL_TARGET\nTargets: ${TARGETS[*]}\nMicroCeph channel: $MICROCEPH_CHANNEL\nStorage mode: $STORAGE_MODE\nReplica size: $REPLICA_SIZE\nStorageClass default: $MAKE_DEFAULT\nPVC test: $RUN_TEST"
  if [[ "$MODE" == "incus_microceph" ]]; then
    summary="$summary\nIncus project: ${INCUS_PROJECT:-default}\nIncus remote: ${INCUS_REMOTE:-local}\nIncus kind: $INCUS_INSTANCE_KIND"
  fi
  summary="$summary\n\nContinuar?"
  ask_yesno "$summary" || exit 1

  # Instala MicroCeph em todos os nós selecionados.
  for target in "${TARGETS[@]}"; do
    install_microceph_on "$target"
  done

  bootstrap_microceph_control_if_needed

  # Join dos demais nós no cluster MicroCeph.
  for target in "${TARGETS[@]}"; do
    join_microceph_node_if_needed "$target"
  done

  # Pequena pausa para o cluster convergir.
  sleep 3

  # Adiciona storage/OSDs.
  case "$STORAGE_MODE" in
    physical_same)
      for target in "${TARGETS[@]}"; do add_physical_disks_on "$target" "$DISKS"; done
      ;;
    all_available)
      for target in "${TARGETS[@]}"; do add_all_available_on "$target"; done
      ;;
    loop_lab)
      for target in "${TARGETS[@]}"; do add_loop_osds_on "$target" "$LOOP_COUNT" "$LOOP_SIZE"; done
      ;;
    skip)
      log "Storage/OSD não adicionado por escolha do usuário."
      ;;
  esac

  single_node="no"
  if [[ "${#TARGETS[@]}" -eq 1 ]]; then
    single_node="yes"
  fi
  configure_ceph_defaults "$REPLICA_SIZE" "$single_node"

  connect_microceph_to_microk8s "$MAKE_DEFAULT" "$RUN_TEST"

  show_status

  msg "Concluído.\n\nLog completo:\n$LOG_FILE\n\nDicas:\n- Ver Ceph: sudo microceph.ceph status\n- Ver discos: sudo microceph disk list\n- Ver StorageClass: microk8s kubectl get sc\n- Ver Rook: microk8s kubectl -n rook-ceph get pods"
}

main "$@"
