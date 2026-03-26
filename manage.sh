#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  Dria Node Manager — Cloud API Proxy Edition
#  Usage: manage.sh <command> [args]
#
#  Manages all dria-node-0x* Docker Compose folders under NODES_DIR.
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

NODES_DIR="${NODES_DIR:-/root/dria-nodes}"
PROXY_ENV="$NODES_DIR/proxy.env"
DOCKER_IMAGE="dria-proxy-node:latest"
REPO_DIR="${REPO_DIR:-/root/dkn-proxy-node}"

# Load START_DELAY (and other overrides) from .env if present
# Done via grep to avoid side-effects of full source
_load_env_var() {
    local key="$1" file="$NODES_DIR/.env"
    [ -f "$file" ] && grep -E "^${key}=" "$file" | cut -d= -f2- | tr -d "'\"\r " | head -1 || true
}
_val=$(_load_env_var START_DELAY)
START_DELAY="${_val:-${START_DELAY:-180}}"

# ── Colors ────────────────────────────────────────────────────────────────────
G='\033[0;32m'; B='\033[0;34m'; Y='\033[1;33m'
R='\033[0;31m'; C='\033[0;36m'; W='\033[1;37m'; N='\033[0m'
log()  { echo -e "${G}[✓]${N} $*"; }
info() { echo -e "${B}[i]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[✗] $*${N}" >&2; exit 1; }

# ── Find all wallet compose files ─────────────────────────────────────────────
find_composes() {
    find "$NODES_DIR" -maxdepth 2 -name "docker-compose.yml" -type f 2>/dev/null | sort
}

find_wallet_dirs() {
    find "$NODES_DIR" -maxdepth 1 -type d -name "dria-node-0x*" 2>/dev/null | sort
}

# ── Migration helpers ──────────────────────────────────────────────────────────

# Returns 0 (true) if compose file uses old firstbatch image
_is_old_format() {
    grep -q "firstbatch/dkn-compute-node\|dkn-compute-node:latest" "$1" 2>/dev/null
}

# Derive Ethereum address from 64-char hex private key using Node.js/ethers
_derive_address() {
    local key="$1"
    local gen_dir="$NODES_DIR/.wallet-gen"

    if command -v node &>/dev/null && [ -d "$gen_dir/node_modules/ethers" ]; then
        node -e "
const {Wallet}=require('$gen_dir/node_modules/ethers');
try{process.stdout.write(new Wallet('0x$key').address);}
catch(e){process.stdout.write('0x'+'$key'.slice(0,40));}
" 2>/dev/null || echo "0x${key:0:40}"
    else
        echo "0x${key:0:40}"
    fi
}

# Rewrite a compose file from old format to new proxy format
# Usage: _migrate_compose <compose_file>
_migrate_compose() {
    local compose="$1"
    local dir; dir=$(dirname "$compose")

    [ -f "$PROXY_ENV" ] || { warn "No proxy.env at $PROXY_ENV — run deploy.sh first"; return 1; }

    # Extract wallet private key from old compose
    local raw
    raw=$(grep -E '(DKN_WALLET_SECRET_KEY|DRIA_WALLET)[[:space:]]*[:=][[:space:]]*' "$compose" 2>/dev/null \
          | grep -oE '(0x)?[a-fA-F0-9]{64}' | head -1)
    [ -n "$raw" ] || { warn "Cannot extract wallet key from $compose"; return 1; }

    local key="${raw#0x}"
    local addr; addr=$(_derive_address "$key")
    local short="${addr:2:8}"

    local node_count
    node_count=$(_load_env_var NODE_COUNT)
    node_count="${node_count:-5}"

    # Stop old containers first
    info "Stopping old containers in $(basename "$dir")..."
    (cd "$dir" && docker compose down 2>/dev/null) || true

    # Write new compose file
    {
        echo "# dria-proxy-node — wallet: ${addr}"
        echo "# migrated from old format: $(date)"
        echo "# services: ${node_count}"
        echo "networks:"
        echo "  dria-nodes:"
        echo "    external: true"
        echo ""
        echo "services:"
    } > "$compose"

    for i in $(seq 1 "$node_count"); do
        cat >> "$compose" << SVC
  node_${i}:
    image: "${DOCKER_IMAGE}"
    container_name: dria-${short}-${i}
    extra_hosts:
      - "host.docker.internal:host-gateway"
    env_file:
      - ../proxy.env
    environment:
      DRIA_WALLET: "0x${key}"
    restart: "on-failure"
    networks:
      - dria-nodes
    logging:
      driver: "json-file"
      options:
        max-size: "5m"
        max-file: "2"

SVC
    done

    log "Migrated $(basename "$dir") → ${node_count} service(s) using ${DOCKER_IMAGE}"
    return 0
}

# ── Start (sequential with delay) ─────────────────────────────────────────────
cmd_start() {
    local filter="${1:-}"
    local delay="${START_DELAY:-180}"

    # Collect matching compose files
    local composes=()
    while IFS= read -r f; do
        local name; name=$(basename "$(dirname "$f")")
        [ -n "$filter" ] && [[ "$name" != *"$filter"* ]] && continue
        composes+=("$f")
    done < <(find_composes)

    local total="${#composes[@]}"
    if [ "$total" -eq 0 ]; then
        warn "No wallet folders found. Run deploy.sh first."
        return
    fi

    local started=0
    local migrated=0
    for compose in "${composes[@]}"; do
        local dir; dir=$(dirname "$compose")
        local name; name=$(basename "$dir")
        (( started++ )) || true

        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        info "Starting node [$started/$total]: $name"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        # Auto-migrate old format compose files before starting
        if _is_old_format "$compose"; then
            warn "Old format detected (firstbatch/dkn-compute-node) — auto-migrating..."
            if _migrate_compose "$compose"; then
                (( migrated++ )) || true
            else
                warn "Migration failed — skipping $name"
                continue
            fi
        fi

        if (cd "$dir" && docker compose up -d --remove-orphans); then
            log "$name started"
        else
            warn "Failed to start $name"
        fi

        if [ "$started" -lt "$total" ]; then
            local next_time
            next_time=$(date -d "+${delay} seconds" '+%H:%M:%S' 2>/dev/null \
                     || date -v+${delay}S '+%H:%M:%S' 2>/dev/null \
                     || echo "in ${delay}s")
            echo ""
            warn "Waiting ${delay}s before next node..."
            info "Next node at: $next_time"
            sleep "$delay"
        fi
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "All $total wallet folder(s) started ($migrated auto-migrated from old format)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    cmd_status
}

# ── Stop ──────────────────────────────────────────────────────────────────────
cmd_stop() {
    local filter="${1:-}"
    while IFS= read -r compose; do
        local dir; dir=$(dirname "$compose")
        local name; name=$(basename "$dir")
        [ -n "$filter" ] && [[ "$name" != *"$filter"* ]] && continue
        info "Stopping $name..."
        (cd "$dir" && docker compose down) 2>/dev/null || true
    done < <(find_composes)
    log "Done"
}

# ── Restart (sequential with delay) ───────────────────────────────────────────
cmd_restart() {
    local filter="${1:-}"
    local delay="${START_DELAY:-180}"

    local composes=()
    while IFS= read -r f; do
        local name; name=$(basename "$(dirname "$f")")
        [ -n "$filter" ] && [[ "$name" != *"$filter"* ]] && continue
        composes+=("$f")
    done < <(find_composes)

    local total="${#composes[@]}"
    [ "$total" -eq 0 ] && warn "No wallet folders found." && return

    local current=0
    for compose in "${composes[@]}"; do
        local dir; dir=$(dirname "$compose")
        local name; name=$(basename "$dir")
        (( current++ )) || true

        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        info "Restarting node [$current/$total]: $name"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        # Auto-migrate old format before restarting
        if _is_old_format "$compose"; then
            warn "Old format detected — auto-migrating..."
            _migrate_compose "$compose" || { warn "Migration failed — skipping $name"; continue; }
        fi

        if (cd "$dir" && docker compose down && docker compose up -d); then
            log "$name restarted"
        else
            warn "Failed to restart $name"
        fi

        if [ "$current" -lt "$total" ]; then
            local next_time
            next_time=$(date -d "+${delay} seconds" '+%H:%M:%S' 2>/dev/null \
                     || date -v+${delay}S '+%H:%M:%S' 2>/dev/null \
                     || echo "in ${delay}s")
            echo ""
            warn "Waiting ${delay}s before next node..."
            info "Next node at: $next_time"
            sleep "$delay"
        fi
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "All $total wallet folder(s) restarted"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── Logs ──────────────────────────────────────────────────────────────────────
cmd_logs() {
    local lines="${1:-150}"
    local filter="${2:-}"

    # Collect matching container names
    local containers=()
    while IFS= read -r name; do
        [ -n "$filter" ] && [[ "$name" != *"$filter"* ]] && continue
        containers+=("$name")
    done < <(docker ps --filter "name=dria-" --format "{{.Names}}" 2>/dev/null | sort)

    if [ ${#containers[@]} -eq 0 ]; then
        warn "No running Dria containers found."
        return
    fi

    if [ ${#containers[@]} -eq 1 ]; then
        # Single container — follow mode
        docker logs --tail "$lines" "${containers[0]}" 2>&1
    else
        # Multiple containers — show last N lines each
        for c in "${containers[@]}"; do
            echo -e "${C}═══ $c ═══${N}"
            docker logs --tail "$lines" "$c" 2>&1
            echo ""
        done
    fi
}

# Follow logs in real-time (all or filtered)
cmd_follow() {
    local filter="${1:-}"
    local containers=()
    while IFS= read -r name; do
        [ -n "$filter" ] && [[ "$name" != *"$filter"* ]] && continue
        containers+=("$name")
    done < <(docker ps --filter "name=dria-" --format "{{.Names}}" 2>/dev/null)

    [ ${#containers[@]} -eq 0 ] && warn "No running containers." && return

    if [ ${#containers[@]} -eq 1 ]; then
        docker logs -f "${containers[0]}"
    else
        # Use docker compose logs for a cleaner follow view per wallet
        while IFS= read -r compose; do
            local dir; dir=$(dirname "$compose")
            local name; name=$(basename "$dir")
            [ -n "$filter" ] && [[ "$name" != *"$filter"* ]] && continue
            (cd "$dir" && docker compose logs -f) &
        done < <(find_composes)
        wait
    fi
}

# ── Status ────────────────────────────────────────────────────────────────────
cmd_status() {
    echo ""
    local total
    total=$(docker ps --filter "name=dria-" --format "{{.Names}}" 2>/dev/null | wc -l)

    if [ "$total" -eq 0 ]; then
        warn "No running Dria containers."
        echo ""
        echo "  Start with: $(basename "$0") start"
        echo ""
        return
    fi

    # Per-wallet breakdown
    while IFS= read -r dir; do
        local name; name=$(basename "$dir")
        local short="${name#dria-node-0x}"
        local running
        running=$(docker ps --filter "name=dria-${short:0:8}-" --format "{{.Names}}" 2>/dev/null | wc -l)
        local total_svc
        total_svc=$(docker compose -f "$dir/docker-compose.yml" config --services 2>/dev/null | wc -l)
        echo -e "  ${C}${name}${N}  ${G}${running}${N}/${total_svc} running"
    done < <(find_wallet_dirs)

    echo ""
    docker ps --filter "name=dria-" \
        --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}\t{{.ID}}"
    echo ""
}

# ── Wallets ───────────────────────────────────────────────────────────────────
cmd_wallets() {
    echo ""
    local count=0
    while IFS= read -r dir; do
        local addr; addr=$(basename "$dir" | sed 's/^dria-node-//')
        local running
        running=$(docker ps --filter "name=dria-${addr:2:8}-" --format "{{.Names}}" 2>/dev/null | wc -l)
        echo "  • $addr  (${running} running)"
        (( count++ )) || true
    done < <(find_wallet_dirs)

    echo ""
    [ "$count" -eq 0 ] && warn "No wallet folders in $NODES_DIR" \
                        || info "$count wallet(s) total"
    echo ""
}

# ── Show config ───────────────────────────────────────────────────────────────
cmd_config() {
    echo ""
    if [ -f "$PROXY_ENV" ]; then
        echo -e "${C}${W}── Proxy config ($PROXY_ENV) ──${N}"
        while IFS='=' read -r key val; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${key// }" ]] && continue
            [[ "$key" == *KEY* || "$key" == *SECRET* ]] && val="${val:0:8}***"
            printf "  %-28s = %s\n" "$key" "$val"
        done < "$PROXY_ENV"
    else
        warn "No proxy.env at $PROXY_ENV"
    fi
    echo ""
}

# ── Update API key ─────────────────────────────────────────────────────────────
cmd_update_key() {
    [ -f "$PROXY_ENV" ] || err "No proxy.env found. Run deploy.sh first."
    read -rsp $'\033[0;36m[?]\033[0m New API key: ' new_key
    echo ""
    [ -n "$new_key" ] || err "Key cannot be empty"

    sed -i "s|^PROXY_API_KEY=.*|PROXY_API_KEY=${new_key}|" "$PROXY_ENV"
    log "Updated PROXY_API_KEY in $PROXY_ENV"

    # Update source .env too if present
    [ -f "$NODES_DIR/.env" ] && \
        sed -i "s|^VIKEY_API_KEY=.*|VIKEY_API_KEY=${new_key}|; s|^PROXY_API_KEY=.*|PROXY_API_KEY=${new_key}|" \
            "$NODES_DIR/.env" && log "Updated $NODES_DIR/.env"

    warn "Restart nodes to apply: $(basename "$0") restart"
}

# ── Rebuild Docker image ───────────────────────────────────────────────────────
cmd_rebuild() {
    [ -d "$REPO_DIR" ] || err "Source not found at $REPO_DIR"
    info "Rebuilding Docker image from $REPO_DIR..."
    docker build -t "$DOCKER_IMAGE" "$REPO_DIR"
    log "Image rebuilt: $DOCKER_IMAGE"
    cmd_restart
}

# ── Update binary (rebuild image from latest source) ──────────────────────────
cmd_update() {
    [ -d "$REPO_DIR" ] || err "Source not found at $REPO_DIR"
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env" 2>/dev/null || true

    info "Pulling latest source..."
    git -C "$REPO_DIR" pull --ff-only

    info "Rebuilding Docker image..."
    docker build -t "$DOCKER_IMAGE" "$REPO_DIR"
    log "Image rebuilt"

    cmd_restart
    log "Update complete"
}

# ── Scale: add/remove services in a wallet folder ─────────────────────────────
cmd_scale() {
    local filter="${1:-}"
    local new_count="${2:-}"
    [ -n "$filter" ]    || err "Usage: scale <address_filter> <node_count>"
    [ -n "$new_count" ] || err "Usage: scale <address_filter> <node_count>"
    [[ "$new_count" =~ ^[0-9]+$ ]] || err "node_count must be a number"

    while IFS= read -r dir; do
        local name; name=$(basename "$dir")
        [[ "$name" != *"$filter"* ]] && continue

        info "Scaling $name to $new_count service(s)..."
        # Use docker compose up --scale (for identical services) OR regenerate compose
        # Since our services are named node_1, node_2, etc., we regenerate
        warn "Scale requires re-running deploy.sh with NODE_COUNT=$new_count"
        echo "  Update NODE_COUNT=$new_count in $NODES_DIR/.env and run:"
        echo "    bash $REPO_DIR/deploy.sh --no-start"
        echo "  Then: $(basename "$0") restart $filter"
    done < <(find_wallet_dirs)
}

# ── Migrate all old-format compose files ──────────────────────────────────────
cmd_migrate() {
    local filter="${1:-}"
    local count=0
    local skipped=0

    info "Scanning for old-format compose files (firstbatch/dkn-compute-node)..."

    while IFS= read -r compose; do
        local name; name=$(basename "$(dirname "$compose")")
        [ -n "$filter" ] && [[ "$name" != *"$filter"* ]] && continue

        if ! _is_old_format "$compose"; then
            (( skipped++ )) || true
            continue
        fi

        info "Migrating $name..."
        if _migrate_compose "$compose"; then
            (( count++ )) || true
        else
            warn "Failed to migrate $name"
        fi
    done < <(find_composes)

    echo ""
    if [ "$count" -eq 0 ] && [ "$skipped" -gt 0 ]; then
        log "All $skipped compose file(s) already in new format — nothing to migrate"
    else
        log "Migrated: $count  |  Already up-to-date: $skipped"
        [ "$count" -gt 0 ] && warn "Run '$(basename "$0") start' to start the migrated nodes"
    fi
}

# ── Prune stopped containers ──────────────────────────────────────────────────
cmd_prune() {
    docker container prune -f --filter "name=dria-"
    log "Stopped Dria containers pruned"
}

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
echo ""
echo -e "${C}${W}Dria Node Manager — Cloud API Proxy${N}"
echo ""
cat << 'EOF'
  Usage: manage.sh <command> [args]

  Control:
    start  [filter]           Start all nodes (optional: filter by address)
    stop   [filter]           Stop all nodes
    restart [filter]          Restart all nodes
    status                    Show per-wallet container status

  Logs:
    logs [N] [filter]         Show last N lines (default: 150)
    follow [filter]           Follow logs in real-time
    Examples:
      logs 200                   all nodes, last 200 lines
      logs 100 040dc19           wallet containing "040dc19"
      follow 040dc19             live logs for that wallet

  Info:
    wallets                   List all wallet addresses and running count
    config                    Show current proxy config (key masked)

  Maintenance:
    update-key                Update VIKEY_API_KEY / PROXY_API_KEY in all configs
    update                    Pull latest source, rebuild image, restart
    rebuild                   Rebuild Docker image from local source and restart
    migrate [filter]          Convert old firstbatch/dkn-compute-node compose files to new format
    prune                     Remove stopped Dria containers

  Examples:
    manage.sh start
    manage.sh logs 200
    manage.sh follow 040dc19
    manage.sh status
    manage.sh update-key
    manage.sh restart 040dc19

EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
main() {
    local cmd="${1:-status}"
    shift || true

    case "$cmd" in
    start)      cmd_start "${1:-}" ;;
    stop)       cmd_stop "${1:-}" ;;
    restart)    cmd_restart "${1:-}" ;;
    logs)       cmd_logs "${1:-150}" "${2:-}" ;;
    follow)     cmd_follow "${1:-}" ;;
    status)     cmd_status ;;
    wallets)    cmd_wallets ;;
    config)     cmd_config ;;
    update-key) cmd_update_key ;;
    update)     cmd_update ;;
    rebuild)    cmd_rebuild ;;
    migrate)    cmd_migrate "${1:-}" ;;
    prune)      cmd_prune ;;
    scale)      cmd_scale "${1:-}" "${2:-}" ;;
    help|-h|--help) usage ;;
    *)
        warn "Unknown command: $cmd"
        usage
        exit 1
        ;;
    esac
}

main "$@"
