#!/usr/bin/env bash
set -uo pipefail

SSH_PORT="${SSH_PORT:-2409}"
SSH_KEY="${SSH_KEY:-/root/.ssh/root_id_ed25519}"
SSH_TIMEOUT="${SSH_TIMEOUT:-15}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESCRIBE_IPS="${DESCRIBE_IPS:-$SCRIPT_DIR/describe-ips.sh}"
WARNINGS=0
ERRORS=0
K8S_CONTROL_HOST=""
K8S_CONTROL_CONTAINER=""
CEPH_CONTROL_HOST=""
CEPH_CONTROL_CONTAINER=""
CONTAINER_COUNT=0
RUNNING_COUNT=0
MICROK8S_COUNT=0
MICROCEPH_COUNT=0

declare -A NAME_LOCATIONS=()
declare -A HOSTNAME_LOCATIONS=()
declare -A VPN_LOCATIONS=()
declare -A IPV4_LOCATIONS=()
declare -a DISCOVERED_HOSTS=()
declare -a DISCOVERED_CONTAINERS=()
declare -a DISCOVERED_HOSTNAMES=()

if [[ -t 1 ]]; then
    RED=$'\033[31m'
    YELLOW=$'\033[33m'
    GREEN=$'\033[32m'
    BLUE=$'\033[34m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    RED=""
    YELLOW=""
    GREEN=""
    BLUE=""
    BOLD=""
    RESET=""
fi

usage() {
    cat <<EOF
Uso: $(basename "$0") [--ssh-key CAMINHO] [--ssh-port PORTA] [--timeout SEGUNDOS]

Variaveis equivalentes: SSH_KEY, SSH_PORT, SSH_TIMEOUT e DESCRIBE_IPS.
Saida: 0=saudavel, 1=avisos, 2=erros.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-key)
            SSH_KEY="$2"
            shift 2
            ;;
        --ssh-port)
            SSH_PORT="$2"
            shift 2
            ;;
        --timeout)
            SSH_TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Opcao desconhecida: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

section() {
    printf '\n%s%s=== %s ===%s\n' "$BOLD" "$BLUE" "$1" "$RESET"
}

ok() {
    printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$*"
}

warn() {
    printf '%s[AVISO]%s %s\n' "$YELLOW" "$RESET" "$*"
    WARNINGS=$((WARNINGS + 1))
}

error() {
    printf '%s[ERRO]%s %s\n' "$RED" "$RESET" "$*"
    ERRORS=$((ERRORS + 1))
}

sshrun() {
    local ip="$1"
    shift
    timeout "$SSH_TIMEOUT" sudo ssh \
        -o BatchMode=yes \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        -o StrictHostKeyChecking=accept-new \
        -i "$SSH_KEY" \
        -p "$SSH_PORT" \
        "root@$ip" -- bash -lc "$(printf '%q' "$*")"
}

container_run() {
    local ip="$1"
    local cname="$2"
    shift 2
    local cname_q command_q
    printf -v cname_q '%q' "$cname"
    printf -v command_q '%q' "$*"
    sshrun "$ip" "incus exec $cname_q -- bash -lc $command_q"
}

remember_value() {
    local map_name="$1"
    local value="$2"
    local location="$3"
    [[ -n "$value" ]] || return 0
    local -n map_ref="$map_name"
    if [[ -n "${map_ref[$value]:-}" ]]; then
        map_ref[$value]="${map_ref[$value]} $location"
    else
        map_ref[$value]="$location"
    fi
}

check_duplicates() {
    local title="$1"
    local map_name="$2"
    local -n map_ref="$map_name"
    local value locations
    local found=0
    for value in "${!map_ref[@]}"; do
        locations="${map_ref[$value]}"
        if [[ "$locations" == *" "* ]]; then
            warn "$title duplicado: $value em $locations"
            found=1
        fi
    done
    [[ "$found" -eq 1 ]] || ok "Sem duplicidade de $title"
}

for cmd in timeout sudo ssh awk grep sort cut head tr; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "Dependencia local ausente: $cmd"
    fi
done
[[ -r "$SSH_KEY" ]] || error "Chave SSH nao legivel: $SSH_KEY"
[[ -x "$DESCRIBE_IPS" ]] || error "Descoberta de instancias indisponivel: $DESCRIBE_IPS"
if [[ "$ERRORS" -gt 0 ]]; then
    exit 2
fi

section "Descoberta das instancias AWS"
ZONES=()
IDS=()
IPS=()
while IFS=$'\t' read -r zone instance_id public_ip; do
    [[ -n "$public_ip" && "$public_ip" != "None" ]] || continue
    ZONES+=("$zone")
    IDS+=("$instance_id")
    IPS+=("$public_ip")
done < <("$DESCRIBE_IPS" 2>/dev/null)

if [[ "${#IPS[@]}" -eq 0 ]]; then
    error "Nenhuma instancia com IP publico foi encontrada"
    exit 2
fi
printf '%-16s %-22s %-16s\n' "ZONE" "INSTANCE" "PUBLIC IP"
for i in "${!IPS[@]}"; do
    printf '%-16s %-22s %-16s\n' "${ZONES[$i]}" "${IDS[$i]}" "${IPS[$i]}"
done

section "Hosts Incus, containers, VPN, MicroK8s e MicroCeph"
for i in "${!IPS[@]}"; do
    host_ip="${IPS[$i]}"
    instance_id="${IDS[$i]}"
    printf '\n%sHost %s (%s)%s\n' "$BOLD" "$host_ip" "$instance_id" "$RESET"

    if ! sshrun "$host_ip" "true" >/dev/null 2>&1; then
        error "$host_ip: SSH indisponivel"
        continue
    fi
    ok "$host_ip: SSH acessivel"
    DISCOVERED_HOSTS+=("$host_ip")

    if ! incus_rows=$(sshrun "$host_ip" "incus list -c n,s --format csv" 2>/dev/null); then
        error "$host_ip: Incus indisponivel"
        continue
    fi

    mapfile -t host_containers < <(printf '%s\n' "$incus_rows" | awk -F, '$1 ~ /^amnix-/ {print $1 "," $2}' | sort -V)
    if [[ "${#host_containers[@]}" -eq 0 ]]; then
        warn "$host_ip: nenhum container amnix encontrado"
        continue
    fi

    for row in "${host_containers[@]}"; do
        cname="${row%%,*}"
        state="${row#*,}"
        location="$host_ip/$cname"
        CONTAINER_COUNT=$((CONTAINER_COUNT + 1))
        DISCOVERED_CONTAINERS+=("$cname")
        remember_value NAME_LOCATIONS "$cname" "$location"

        printf '  %-42s estado=%-8s\n' "$cname" "$state"
        if [[ "$state" != "RUNNING" ]]; then
            error "$location: container $state"
            continue
        fi
        RUNNING_COUNT=$((RUNNING_COUNT + 1))

        hostname=$(container_run "$host_ip" "$cname" "hostname" 2>/dev/null | head -1 || true)
        eth0_ip=$(container_run "$host_ip" "$cname" "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1 | head -1" 2>/dev/null || true)
        tailscale_ip=$(container_run "$host_ip" "$cname" "command -v tailscale >/dev/null 2>&1 && tailscale ip -4 | head -1" 2>/dev/null || true)
        netbird_ip=$(container_run "$host_ip" "$cname" "ip -4 -o addr show dev wt0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -1" 2>/dev/null || true)
        vpn_ip="${tailscale_ip:-$netbird_ip}"
        vpn_name="nenhuma"
        [[ -n "$tailscale_ip" ]] && vpn_name="tailscale"
        [[ -z "$tailscale_ip" && -n "$netbird_ip" ]] && vpn_name="netbird"

        DISCOVERED_HOSTNAMES+=("$hostname")
        remember_value HOSTNAME_LOCATIONS "$hostname" "$location"
        remember_value IPV4_LOCATIONS "$eth0_ip" "$location"
        remember_value VPN_LOCATIONS "$vpn_ip" "$location"

        printf '    hostname=%s eth0=%s vpn=%s:%s\n' \
            "${hostname:-indisponivel}" "${eth0_ip:-indisponivel}" "$vpn_name" "${vpn_ip:-indisponivel}"
        [[ -n "$hostname" ]] || warn "$location: hostname indisponivel"
        [[ -n "$vpn_ip" ]] || warn "$location: IP VPN indisponivel"

        if container_run "$host_ip" "$cname" "command -v microk8s >/dev/null 2>&1 && sudo microk8s status --wait-ready --timeout 5 >/dev/null" >/dev/null 2>&1; then
            ok "$location: MicroK8s pronto"
            MICROK8S_COUNT=$((MICROK8S_COUNT + 1))
            node_ip=$(container_run "$host_ip" "$cname" "grep '^--node-ip=' /var/snap/microk8s/current/args/kubelet | tail -1 | cut -d= -f2" 2>/dev/null || true)
            printf '    kubelet node-ip=%s\n' "${node_ip:-automatico}"
            if [[ -n "$vpn_ip" && "$node_ip" != "$vpn_ip" ]]; then
                warn "$location: kubelet nao usa o IP VPN $vpn_ip"
            fi
            if [[ -z "$K8S_CONTROL_HOST" ]] && container_run "$host_ip" "$cname" "sudo microk8s kubectl get nodes -o name" >/dev/null 2>&1; then
                K8S_CONTROL_HOST="$host_ip"
                K8S_CONTROL_CONTAINER="$cname"
            fi
        else
            warn "$location: MicroK8s ausente ou nao pronto"
        fi

        if container_run "$host_ip" "$cname" "command -v microceph >/dev/null 2>&1" >/dev/null 2>&1; then
            MICROCEPH_COUNT=$((MICROCEPH_COUNT + 1))
            if container_run "$host_ip" "$cname" "sudo microceph status" >/dev/null 2>&1; then
                ok "$location: MicroCeph ativo"
                if [[ -z "$CEPH_CONTROL_HOST" ]]; then
                    CEPH_CONTROL_HOST="$host_ip"
                    CEPH_CONTROL_CONTAINER="$cname"
                fi
            else
                error "$location: MicroCeph instalado, mas sem status saudavel"
            fi
        else
            printf '    MicroCeph=nao instalado\n'
        fi
    done
done

section "Unicidade de identidades e enderecos"
check_duplicates "nome de container" NAME_LOCATIONS
check_duplicates "hostname" HOSTNAME_LOCATIONS
check_duplicates "IP VPN" VPN_LOCATIONS
check_duplicates "IPv4 eth0" IPV4_LOCATIONS

section "Cluster MicroK8s"
if [[ -z "$K8S_CONTROL_HOST" ]]; then
    error "Nenhum endpoint de controle MicroK8s foi encontrado"
else
    ok "Endpoint: $K8S_CONTROL_HOST/$K8S_CONTROL_CONTAINER"
    printf '\nNodes:\n'
    container_run "$K8S_CONTROL_HOST" "$K8S_CONTROL_CONTAINER" \
        "sudo microk8s kubectl get nodes -o wide" 2>&1 || error "Falha ao listar nodes MicroK8s"

    not_ready=$(container_run "$K8S_CONTROL_HOST" "$K8S_CONTROL_CONTAINER" \
        "sudo microk8s kubectl get nodes --no-headers | awk '\$2 != \"Ready\" {count++} END {print count+0}'" 2>/dev/null || echo 0)
    if [[ "$not_ready" =~ ^[0-9]+$ && "$not_ready" -eq 0 ]]; then
        ok "Todos os nodes Kubernetes estao Ready"
    else
        error "Nodes Kubernetes nao Ready: ${not_ready:-desconhecido}"
    fi

    printf '\nPods fora de Running/Succeeded:\n'
    non_running=$(container_run "$K8S_CONTROL_HOST" "$K8S_CONTROL_CONTAINER" \
        "sudo microk8s kubectl get pods -A --no-headers | awk '\$4 != \"Running\" && \$4 != \"Completed\" {print}'" 2>/dev/null || true)
    if [[ -z "$non_running" ]]; then
        ok "Todos os pods estao Running ou Completed"
    else
        printf '%s\n' "$non_running"
        warn "Existem pods fora de Running/Completed"
    fi

    if container_run "$K8S_CONTROL_HOST" "$K8S_CONTROL_CONTAINER" \
        "sudo microk8s kubectl get storageclass ceph-rbd" >/dev/null 2>&1; then
        ok "StorageClass ceph-rbd disponivel"
    else
        warn "StorageClass ceph-rbd nao encontrada"
    fi

    printf '\nStorageClasses:\n'
    container_run "$K8S_CONTROL_HOST" "$K8S_CONTROL_CONTAINER" \
        "sudo microk8s kubectl get storageclass" 2>&1 || warn "Falha ao listar StorageClasses"
    printf '\nPods Rook/Ceph:\n'
    rook_rows=$(container_run "$K8S_CONTROL_HOST" "$K8S_CONTROL_CONTAINER" \
        "sudo microk8s kubectl get pods -A | grep -Ei 'rook|ceph'" 2>/dev/null || true)
    if [[ -n "$rook_rows" ]]; then
        printf '%s\n' "$rook_rows"
    else
        warn "Nenhum pod Rook/Ceph encontrado"
    fi
    printf '\nPVCs:\n'
    container_run "$K8S_CONTROL_HOST" "$K8S_CONTROL_CONTAINER" \
        "sudo microk8s kubectl get pvc -A" 2>&1 || warn "Falha ao listar PVCs"
fi

section "Cluster MicroCeph"
if [[ -z "$CEPH_CONTROL_HOST" ]]; then
    error "Nenhum endpoint MicroCeph ativo foi encontrado"
else
    ok "Endpoint: $CEPH_CONTROL_HOST/$CEPH_CONTROL_CONTAINER"
    for check in \
        "sudo microceph status" \
        "sudo microceph cluster list" \
        "sudo microceph disk list" \
        "sudo microceph.ceph status" \
        "sudo microceph.ceph health detail" \
        "sudo microceph.ceph osd tree"; do
        printf '\n$ %s\n' "$check"
        container_run "$CEPH_CONTROL_HOST" "$CEPH_CONTROL_CONTAINER" "$check" 2>&1 || error "Falha: $check"
    done

    ceph_health=$(container_run "$CEPH_CONTROL_HOST" "$CEPH_CONTROL_CONTAINER" \
        "sudo microceph.ceph health" 2>/dev/null || true)
    if [[ "$ceph_health" == HEALTH_OK* ]]; then
        ok "Ceph HEALTH_OK"
    elif [[ -n "$ceph_health" ]]; then
        warn "Ceph: $ceph_health"
    else
        error "Nao foi possivel obter a saude do Ceph"
    fi
fi

section "Resumo"
printf 'Instancias descobertas: %d\n' "${#IPS[@]}"
printf 'Hosts SSH acessiveis: %d\n' "${#DISCOVERED_HOSTS[@]}"
printf 'Containers amnix: %d total, %d running\n' "$CONTAINER_COUNT" "$RUNNING_COUNT"
printf 'Containers MicroK8s prontos: %d\n' "$MICROK8S_COUNT"
printf 'Containers com MicroCeph: %d\n' "$MICROCEPH_COUNT"
printf 'Avisos: %d\n' "$WARNINGS"
printf 'Erros: %d\n' "$ERRORS"

if [[ "$ERRORS" -gt 0 ]]; then
    printf '%sSTATUS GERAL: CRITICO%s\n' "$RED" "$RESET"
    exit 2
fi
if [[ "$WARNINGS" -gt 0 ]]; then
    printf '%sSTATUS GERAL: ATENCAO%s\n' "$YELLOW" "$RESET"
    exit 1
fi
printf '%sSTATUS GERAL: SAUDAVEL%s\n' "$GREEN" "$RESET"
exit 0
