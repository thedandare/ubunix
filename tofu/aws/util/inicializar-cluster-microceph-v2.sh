    #!/usr/bin/env bash
    set -euo pipefail

    # ==============================================================================
    # inicializar-cluster-microceph-v2.sh
    #
    # Orquestrador local para bootstrap/join de cluster MicroCeph.
    # Correcoes em relacao a v1:
    #   - Sem espera pelo MicroCeph antes da instalacao
    #   - Token de join gerado individualmente por worker
    #   - Nomes unicos validados para todos os membros
    #   - Primeiro worker obtido a partir do worker selecionado
    #   - Scripts remotos nao fazem purge automatico
    #   - Canal fixo do snap (squid/stable) e rede publica configuravel
    #   - Arquivos temporarios com mktemp e limpeza via trap
    #   - Lock local com flock para evitar execucoes concorrentes
    #   - Log persistente da execucao
    # ==============================================================================

    SSH_PORT=2409
    SSH_KEY=/root/.ssh/root_id_ed25519
    BOOTSTRAP_SCRIPT_PATH="/osnix/ubunix/tofu/aws/util/microceph_bootstrap.sh"
    JOIN_SCRIPT_PATH="/osnix/ubunix/tofu/aws/util/microceph_join.sh"
    INTEGRATION_SCRIPT_PATH="/osnix/ubunix/tofu/aws/util/integrar-microceph-microk8s.sh"
    MICROCEPH_CHANNEL="${MICROCEPH_CHANNEL:-squid/stable}"
    MICROCEPH_PUBLIC_NETWORK="${MICROCEPH_PUBLIC_NETWORK:-}"
    MICROCEPH_OSD_DEVICE="${MICROCEPH_OSD_DEVICE:-loop,4G,1}"

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # ==============================================================================
    # Logging
    # ==============================================================================
    LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/microceph-$(date +%Y%m%d-%H%M%S).log"
    # Mantem stdout e stderr separados para command substitutions, mas loga ambos
    exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

    log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
    warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] AVISO: $*" >&2; }
    fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERRO: $*" >&2; exit 1; }

    # ==============================================================================
    # Lock de execucao unica
    # ==============================================================================
    LOCK_FILE="/tmp/inicializar-cluster-microceph.lock"
    # Remove lock stale de execucoes anteriores com outro owner
    [[ -e "$LOCK_FILE" ]] && rm -f "$LOCK_FILE" 2>/dev/null || true
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        fail "Outro processo deste orquestrador ja esta em execucao."
    fi

    # ==============================================================================
    # Arquivos temporarios
    # ==============================================================================
    TMP_DIR=$(mktemp -d)
    cleanup() {
        log "Limpando arquivos temporarios..."
        rm -rf "$TMP_DIR"

        local target ip cname
        for target in "${CLEANUP_TARGETS[@]:-}"; do
            [[ -n "$target" ]] || continue
            IFS='|' read -r ip cname <<< "$target"
            [[ -n "$ip" && -n "$cname" ]] || continue
            sshrun "$ip" "incus exec $(printf '%q' "$cname") -- rm -f /tmp/microceph_bootstrap.sh /tmp/microceph_join.sh" >/dev/null 2>&1 || true
        done
    }
    trap cleanup EXIT INT TERM
    CLEANUP_TARGETS=()

    # ==============================================================================
    # Validacao de dependencias locais
    # ==============================================================================
    log "Validando dependencias locais..."
    for cmd in dialog ssh scp timeout grep sed awk sort mktemp flock tee; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            fail "Dependencia local ausente: $cmd"
        fi
    done

    if [[ ! -r "$SSH_KEY" ]]; then
        fail "Chave SSH nao legivel: $SSH_KEY"
    fi

    if [[ ! -f "$BOOTSTRAP_SCRIPT_PATH" || ! -f "$JOIN_SCRIPT_PATH" ]]; then
        fail "Scripts remotos nao encontrados: $BOOTSTRAP_SCRIPT_PATH ou $JOIN_SCRIPT_PATH"
    fi

    # ==============================================================================
    # SSH / execucao remota
    # ==============================================================================
    # sshrun <public-ip> <comando...>
    # Recomendacao: passar comando como array; aqui usamos printf '%q' para cada arg
    sshrun() {
        local ip="$1"; shift
        local args=()
        for a in "$@"; do
            args+=("$(printf '%q' "$a")")
        done
        sudo ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -i "$SSH_KEY" -p "$SSH_PORT" \
            "root@$ip" -- bash -lc "${args[*]}"
    }

    # Verifica dependencias remotas basicas no host (nao no container)
    validate_remote_host() {
        local pub_ip="$1"
        if ! sshrun "$pub_ip" "command -v incus" >/dev/null 2>&1; then
            fail "Host $pub_ip: dependencia remota ausente: incus"
        fi
    }

    # ==============================================================================
    # VPN e containers
    # ==============================================================================
    get_tailscale_ip() {
        local pub_ip="$1"
        local first_container
        first_container=$(sshrun "$pub_ip" "incus list -c n --format csv" 2>/dev/null | grep 'amnix-' | sort -V | head -1 | tr -d '\n')
        if [[ -z "$first_container" ]]; then
            warn "Nenhum container amnix encontrado em $pub_ip"
            return 1
        fi
        sshrun "$pub_ip" "incus exec $first_container -- tailscale ip -4" 2>/dev/null | head -1
    }

    get_container_vpn_ip() {
        local pub_ip="$1"
        local cname="$2"
        if [[ "$VPN_CHOICE" == "netbird" ]]; then
            sshrun "$pub_ip" "incus exec $cname -- ip addr show wt0" 2>/dev/null \
                | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1
        else
            sshrun "$pub_ip" "incus exec $cname -- tailscale ip -4" 2>/dev/null | head -1
        fi
    }

    # Lista containers amnix em estado RUNNING
    get_running_containers() {
        local pub_ip="$1"
        sshrun "$pub_ip" "incus list -c ns --format csv" 2>/dev/null \
            | grep 'amnix-' | grep ',RUNNING$' | cut -d',' -f1 | sort -V | tr '\n' ' ' || echo ""
    }

    # Obtem hostname de um container
    get_container_hostname() {
        local pub_ip="$1"
        local cname="$2"
        sshrun "$pub_ip" "incus exec $cname -- hostname" 2>/dev/null | head -1
    }

    # ==============================================================================
    # Copia de scripts para container
    # ==============================================================================
    copy_script_to_container() {
        local host_ip="$1"
        local cname="$2"
        local local_script="$3"
        local remote_path="$4"

        log "Copiando $local_script para ${host_ip}/${cname}:${remote_path}"

        local temp_file
        temp_file="/tmp/$(basename "$local_script")"

        sudo scp -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" -P "$SSH_PORT" \
            "$local_script" "root@${host_ip}:${temp_file}" || {
            fail "Falha ao copiar script para host $host_ip"
        }

        sshrun "$host_ip" "incus file push ${temp_file} ${cname}${remote_path} >/dev/null" || {
            fail "Falha ao copiar script para container ${cname}"
        }

        sshrun "$host_ip" "incus exec ${cname} -- chmod 700 ${remote_path}" || {
            fail "Falha ao ajustar permissoes de ${remote_path}"
        }

        sshrun "$host_ip" "rm -f ${temp_file}" || true

        CLEANUP_TARGETS+=("${host_ip}|${cname}")
        log "Script copiado e permissao 700 aplicada."
    }

    # ==============================================================================
    # Bootstrap
    # ==============================================================================
    do_bootstrap() {
        local target_ip="$1"
        local cname="$2"
        local first_worker_name="$3"

        log ">>> [${target_ip}/${cname}] Bootstrap do MicroCeph"

        copy_script_to_container "$target_ip" "$cname" "$BOOTSTRAP_SCRIPT_PATH" "/tmp/microceph_bootstrap.sh" || return 1

        local env_vars
        env_vars="MICROCEPH_CHANNEL='$(printf '%q' "$MICROCEPH_CHANNEL")' OSD_DEVICE='$(printf '%q' "$MICROCEPH_OSD_DEVICE")' FRESH_INSTALL='$(printf '%q' "${FRESH_INSTALL:-0}")' VPN_INTERFACE='$(printf '%q' "$VPN_INTERFACE")'"
        if [[ -n "$MICROCEPH_PUBLIC_NETWORK" ]]; then
            env_vars="$env_vars PUBLIC_NETWORK='$(printf '%q' "$MICROCEPH_PUBLIC_NETWORK")'"
        fi

        log "Executando bootstrap com primeiro worker: $first_worker_name"
        local bootstrap_out
        bootstrap_out=$(sshrun "$target_ip" "incus exec ${cname} -- bash -lc '${env_vars} /tmp/microceph_bootstrap.sh $(printf '%q' "$first_worker_name")'")

        if [[ -z "$bootstrap_out" ]]; then
            fail "Bootstrap nao retornou token em stdout"
        fi

        local NODE_TOKEN
        NODE_TOKEN=$(printf '%s\n' "$bootstrap_out" | extract_join_token)

        if [[ -z "$NODE_TOKEN" ]]; then
            fail "Token de join vazio"
        fi

        log "Token extraido: ${NODE_TOKEN:0:16}..."
        echo "$NODE_TOKEN"
    }

    # ==============================================================================
    # Join
    # ==============================================================================
    do_join() {
        local target_ip="$1"
        local cname="$2"
        local token="$3"
        local master_ip="$4"

        log ">>> [${target_ip}/${cname}] Join do MicroCeph"

        copy_script_to_container "$target_ip" "$cname" "$JOIN_SCRIPT_PATH" "/tmp/microceph_join.sh" || return 1

        local env_vars
        env_vars="MICROCEPH_CHANNEL='$(printf '%q' "$MICROCEPH_CHANNEL")' OSD_DEVICE='$(printf '%q' "$MICROCEPH_OSD_DEVICE")' FRESH_INSTALL='$(printf '%q' "${FRESH_INSTALL:-0}")' VPN_INTERFACE='$(printf '%q' "$VPN_INTERFACE")'"
        if [[ -n "$MICROCEPH_PUBLIC_NETWORK" ]]; then
            env_vars="$env_vars PUBLIC_NETWORK='$(printf '%q' "$MICROCEPH_PUBLIC_NETWORK")'"
        fi

        local join_cmd
        join_cmd="${env_vars} /tmp/microceph_join.sh '$(printf '%q' "$token")' '$(printf '%q' "$master_ip")'"

        if sshrun "$target_ip" "incus exec ${cname} -- bash -lc '${join_cmd}'"; then
            log "OK: ${target_ip}/${cname} entrou no cluster."
        else
            warn "Join falhou para ${target_ip}/${cname}"
            return 1
        fi
    }

    # ==============================================================================
    # Integracao MicroCeph -> MicroK8s
    # ==============================================================================
    do_integrate_microk8s() {
        local target_ip="$1"
        local cname="$2"

        log ">>> [${target_ip}/${cname}] Integrando MicroCeph com MicroK8s"

        if [[ ! -f "$INTEGRATION_SCRIPT_PATH" ]]; then
            warn "Script de integracao nao encontrado: $INTEGRATION_SCRIPT_PATH"
            return 1
        fi

        copy_script_to_container "$target_ip" "$cname" "$INTEGRATION_SCRIPT_PATH" "/tmp/integrar-microceph-microk8s.sh" || return 1

        if sshrun "$target_ip" "incus exec ${cname} -- bash -lc '/tmp/integrar-microceph-microk8s.sh'"; then
            log "Integracao MicroCeph -> MicroK8s concluida com sucesso."
            return 0
        else
            warn "Integracao MicroCeph -> MicroK8s falhou"
            return 1
        fi
    }

    # Normaliza a saida de 'microceph cluster add', extraindo apenas o token
    # O token do MicroCeph e uma string base64 compacta
    extract_join_token() {
        grep -oE '^[A-Za-z0-9+/]+={0,2}$' | tail -n1
    }

    # Gera um novo token no master para um worker especifico
    generate_join_token() {
        local master_ip="$1"
        local master_cname="$2"
        local worker_name="$3"
        local token
        token=$(sshrun "$master_ip" "incus exec ${master_cname} -- sudo microceph cluster add '$(printf '%q' "$worker_name")'" 2>/dev/null | extract_join_token)
        if [[ -z "$token" ]]; then
            fail "Nao foi possivel gerar token para $worker_name"
        fi
        log "Token gerado para $worker_name: ${token:0:16}..."
        echo "$token"
    }

    # ==============================================================================
    # 0. Escolha da VPN
    # ==============================================================================
    VPN_CHOICE=$(dialog --title "Escolher VPN" \
        --menu "Escolha qual VPN sera usada para conectividade do cluster:" \
        15 60 2 \
        "tailscale" "Tailscale (padrao)" \
        "netbird" "Netbird (IP range: 100.82.0.0/16)" \
        3>&1 1>&2 2>&3) || exit 0

    if [[ "$VPN_CHOICE" == "netbird" ]]; then
        VPN_NAME="Netbird"
        VPN_INTERFACE="wt0"
        VPN_IP_RANGE="100.82.0.0/16"
    else
        VPN_NAME="Tailscale"
        VPN_INTERFACE="tailscale0"
    fi

    clear
    log "VPN selecionada: $VPN_NAME"

    # Rede publica do Ceph: usa CIDR da VPN escolhida, a menos que o usuario defina outro
    if [[ -z "$MICROCEPH_PUBLIC_NETWORK" ]]; then
        case "$VPN_CHOICE" in
            tailscale)
                MICROCEPH_PUBLIC_NETWORK="100.64.0.0/10"
                ;;
            netbird)
                MICROCEPH_PUBLIC_NETWORK="100.82.0.0/16"
                ;;
        esac
    fi
    log "Rede publica do MicroCeph: $MICROCEPH_PUBLIC_NETWORK"

    # ==============================================================================
    # 1. Coleta de instancias
    # ==============================================================================
    ZONES=(); IDS=(); IPS=(); VPNIPS=()
    while IFS=$'\t' read -r zone id ip; do
        [[ -z "$ip" || "$ip" == "None" ]] && continue
        ZONES+=("$zone")
        IDS+=("$id")
        IPS+=("$ip")
    done < <("$SCRIPT_DIR/describe-ips.sh") || true

    if [[ "${#IPS[@]}" -lt 2 ]]; then
        fail "Necessario pelo menos 2 instancias (1 master + 1 worker)."
    fi

    # ==============================================================================
    # 2. Obtencao de IPs VPN (paralelo)
    # ==============================================================================
    log "Obtendo IPs $VPN_NAME dos hosts (paralelo)..."
    PIDS=()
    TEMP_FILES=()

    get_vpn_ip_bg() {
        local idx="$1"
        local ip="$2"
        local temp_file="$TMP_DIR/vpn_ip_$idx"
        local vpn_ip=""

        if [[ "$VPN_CHOICE" == "netbird" ]]; then
            local first_container
            first_container=$(sshrun "$ip" "incus list -c n --format csv" 2>/dev/null | grep 'amnix-' | sort -V | head -1 | tr -d '\n')
            vpn_ip=$(sshrun "$ip" "incus exec $first_container -- ip addr show wt0" 2>/dev/null \
                | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1) || true
        else
            vpn_ip=$(get_tailscale_ip "$ip") || true
        fi

        echo "$vpn_ip" > "$temp_file"
    }

    for i in "${!IPS[@]}"; do
        temp_file="$TMP_DIR/vpn_ip_$i"
        TEMP_FILES+=("$temp_file")
        get_vpn_ip_bg "$i" "${IPS[$i]}" &
        PIDS+=($!)
    done

    for pid in "${PIDS[@]}"; do
        wait "$pid" || true
    done

    for i in "${!IPS[@]}"; do
        temp_file="$TMP_DIR/vpn_ip_$i"
        vpn_ip=$(cat "$temp_file" 2>/dev/null || echo "")
        if [[ -z "$vpn_ip" ]]; then
            fail "Nao foi possivel obter IP $VPN_NAME do host ${IPS[$i]}"
        fi
        VPNIPS+=("$vpn_ip")
        log "${IPS[$i]} -> $VPN_INTERFACE: $vpn_ip"
    done

    # ==============================================================================
    # 3. Selecao do master
    # ==============================================================================
    AUTO_SELECT="${AUTO_SELECT:-0}"
    if [[ "$AUTO_SELECT" == "1" ]]; then
        MASTER_IDX=0
        log "AUTO_SELECT: master = node${MASTER_IDX} (${IPS[$MASTER_IDX]})"
    else
        MARGS=()
        for i in "${!IPS[@]}"; do
            MARGS+=("node${i}" "${ZONES[$i]}  ${IPS[$i]}  ${VPN_INTERFACE}=${VPNIPS[$i]}  ${IDS[$i]}")
        done

        MASTER_TAG=$(dialog --title "Selecionar node MASTER" \
            --menu "Escolha a instancia que sera o master do cluster MicroCeph:" \
            20 80 12 "${MARGS[@]}" 3>&1 1>&2 2>&3) || exit 0

        MASTER_IDX="${MASTER_TAG#node}"
        MASTER_IDX="${MASTER_IDX//\"/}"
    fi
    MASTER_IP="${IPS[$MASTER_IDX]}"

    # ==============================================================================
    # 4. Selecao dos workers
    # ==============================================================================
    if [[ "$AUTO_SELECT" == "1" ]]; then
        WORKER_IDX=()
        for i in "${!IPS[@]}"; do
            [[ "$i" == "$MASTER_IDX" ]] && continue
            WORKER_IDX+=("$i")
        done
        log "AUTO_SELECT: workers = ${WORKER_IDX[*]}"
    else
        WARGS=()
        for i in "${!IPS[@]}"; do
            [[ "$i" == "$MASTER_IDX" ]] && continue
            WARGS+=("node${i}" "${ZONES[$i]}  ${IPS[$i]}  ${VPN_INTERFACE}=${VPNIPS[$i]}  ${IDS[$i]}" "on")
        done

        WORKERS_SELECTED=$(dialog --title "Selecionar hosts WORKER" \
            --checklist "Cada host tera: 1 container principal (amnix-0)" \
            22 80 14 "${WARGS[@]}" 3>&1 1>&2 2>&3) || exit 0

        if [[ -z "$WORKERS_SELECTED" ]]; then
            fail "Nenhum host worker selecionado."
        fi

        read -ra WORKER_TAGS <<< "$WORKERS_SELECTED"
        WORKER_IDX=()
        for tag in "${WORKER_TAGS[@]}"; do
            WORKER_IDX+=("${tag#node}")
        done
    fi

    # ==============================================================================
    # 5. Validacao de containers e nomes
    # ==============================================================================
    log "Validando containers em execucao e nomes unicos..."

    validate_remote_host "$MASTER_IP"
    MASTER_CONTAINERS=($(get_running_containers "$MASTER_IP"))
    if [[ ${#MASTER_CONTAINERS[@]} -eq 0 ]]; then
        fail "Nenhum container amnix em estado RUNNING no master $MASTER_IP"
    fi
    MASTER_CONTAINER="${MASTER_CONTAINERS[0]}"
    MASTER_HOSTNAME=$(get_container_hostname "$MASTER_IP" "$MASTER_CONTAINER")

    declare -A HOSTNAME_MAP
    HOSTNAME_MAP["$MASTER_HOSTNAME"]="$MASTER_IP/$MASTER_CONTAINER"

    declare -A WORKER_CONTAINERS_MAP
    for i in "${WORKER_IDX[@]}"; do
        validate_remote_host "${IPS[$i]}"
        containers=($(get_running_containers "${IPS[$i]}"))
        if [[ ${#containers[@]} -eq 0 ]]; then
            fail "Nenhum container amnix em estado RUNNING no worker ${IPS[$i]}"
        fi
        WORKER_CONTAINERS_MAP[$i]="${containers[*]}"
        for c in "${containers[@]}"; do
            h=$(get_container_hostname "${IPS[$i]}" "$c")
            if [[ -n "${HOSTNAME_MAP[$h]:-}" ]]; then
                fail "Hostname duplicado detectado: $h em ${IPS[$i]}/$c e ${HOSTNAME_MAP[$h]}"
            fi
            HOSTNAME_MAP["$h"]="${IPS[$i]}/$c"
        done
    done

    clear
    log "Master: pub=${MASTER_IP} container=${MASTER_CONTAINER} hostname=${MASTER_HOSTNAME} ${VPN_INTERFACE}=${VPNIPS[$MASTER_IDX]}"
    log "Workers selecionados: ${#WORKER_IDX[@]}"
    for i in "${WORKER_IDX[@]}"; do
        log "  - pub=${IPS[$i]} containers=${WORKER_CONTAINERS_MAP[$i]} ${VPN_INTERFACE}=${VPNIPS[$i]}"
    done

    MASTER_CONTAINER_VPN_IP="${VPNIPS[$MASTER_IDX]}"
    log "IP $VPN_NAME do master (join endpoint): ${MASTER_CONTAINER_VPN_IP}"

    # Primeiro worker: usa hostname real do container, nao o nome do container
    FIRST_WORKER_IDX="${WORKER_IDX[0]}"
    FIRST_WORKER_HOST_IP="${IPS[$FIRST_WORKER_IDX]}"

    FIRST_WORKER_CONTAINERS_STR="${WORKER_CONTAINERS_MAP[$FIRST_WORKER_IDX]}"
    FIRST_WORKER_CONTAINER="${FIRST_WORKER_CONTAINERS_STR%% *}"
    if [[ -z "$FIRST_WORKER_CONTAINER" ]]; then
        fail "Nao foi encontrado container no primeiro worker selecionado."
    fi

    FIRST_WORKER_HOSTNAME=$(
        get_container_hostname "$FIRST_WORKER_HOST_IP" "$FIRST_WORKER_CONTAINER"
    )
    if [[ -z "$FIRST_WORKER_HOSTNAME" ]]; then
        fail "Nao foi possivel obter o hostname do primeiro worker."
    fi

    log "Primeiro worker para geracao do token inicial: $FIRST_WORKER_HOSTNAME"

    # ==============================================================================
    # 6. Verificacao de cluster existente
    # ==============================================================================
    log "Verificando cluster MicroCeph existente no master..."
    CLUSTER_MEMBERS=$(sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microceph cluster list --format json" 2>/dev/null || echo "[]")
    log "Membros atuais no cluster: ${CLUSTER_MEMBERS:-"(nenhum/nao inicializado)"}"

    # ==============================================================================
    # 7. Bootstrap no master
    # ==============================================================================
    log "--- Executando bootstrap do MicroCeph no master ---"
    BOOTSTRAP_TOKEN=$(do_bootstrap "$MASTER_IP" "$MASTER_CONTAINER" "$FIRST_WORKER_HOSTNAME") || {
        fail "Bootstrap falhou"
    }
    log "Token inicial obtido com sucesso."

    # ==============================================================================
    # 8. Join dos workers
    # ==============================================================================
    log "--- Executando join dos workers ---"
    FAILED_WORKERS=()
    FIRST_WORKER_DONE=0

    for i in "${WORKER_IDX[@]}"; do
        host_ip="${IPS[$i]}"
        containers_str="${WORKER_CONTAINERS_MAP[$i]}"
        read -ra containers <<< "$containers_str"
        WORKER_CONTAINER="${containers[0]}"

        log "--- Host worker: $host_ip ($WORKER_CONTAINER ${VPN_INTERFACE}=${VPNIPS[$i]}) ---"

        # Verifica se ja esta no cluster
        worker_hostname=$(get_container_hostname "$host_ip" "$WORKER_CONTAINER")
        if [[ "$CLUSTER_MEMBERS" == *"$worker_hostname"* ]]; then
            log "[SKIP] $host_ip/$WORKER_CONTAINER ($worker_hostname) ja esta no cluster"
            continue
        fi

        # Primeiro worker usa o token ja gerado pelo bootstrap; demais geram token novo
        if [[ "$FIRST_WORKER_DONE" -eq 0 ]]; then
            worker_token="$BOOTSTRAP_TOKEN"
            FIRST_WORKER_DONE=1
        else
            worker_token=$(generate_join_token "$MASTER_IP" "$MASTER_CONTAINER" "$worker_hostname") || {
                warn "Nao foi possivel gerar token para $worker_hostname"
                FAILED_WORKERS+=("$host_ip/$WORKER_CONTAINER")
                continue
            }
        fi

        if do_join "$host_ip" "$WORKER_CONTAINER" "$worker_token" "$MASTER_CONTAINER_VPN_IP"; then
            log "Join OK: $host_ip/$WORKER_CONTAINER"
        else
            warn "Join falhou: $host_ip/$WORKER_CONTAINER"
            FAILED_WORKERS+=("$host_ip/$WORKER_CONTAINER")
        fi
    done

    # ==============================================================================
    # 9. Health check final
    # ==============================================================================
    log "=== Verificando saude do cluster no master ==="
    sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microceph status" || true
    sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microceph cluster list" || true
    sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microceph disk list" || true
    sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microceph.ceph status" || true
    sshrun "$MASTER_IP" "incus exec ${MASTER_CONTAINER} -- sudo microceph.ceph osd tree" || true

    if [[ ${#FAILED_WORKERS[@]} -gt 0 ]]; then
        warn "Workers que falharam: ${FAILED_WORKERS[*]}"
        exit 2
    fi

    # ==============================================================================
    # 10. Integracao MicroCeph -> MicroK8s
    # ==============================================================================
    INTEGRATE_MICROK8S="${INTEGRATE_MICROK8S:-1}"
    if [[ "$INTEGRATE_MICROK8S" == "1" ]]; then
        log "=== Integrando MicroCeph com MicroK8s ==="
        do_integrate_microk8s "$MASTER_IP" "$MASTER_CONTAINER" || true
    else
        log "Pulando integracao com MicroK8s (INTEGRATE_MICROK8S=$INTEGRATE_MICROK8S)"
    fi

    log "Concluido. Log salvo em: $LOG_FILE"
