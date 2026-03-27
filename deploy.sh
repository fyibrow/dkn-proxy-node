#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  Dria Node Deployer — Cloud API Proxy Edition
#
#  Usage:
#    bash deploy.sh              → interactive (auto-scans existing wallet folders)
#    bash deploy.sh --rebuild    → force rebuild Docker image
#    bash deploy.sh --no-start   → generate compose files only, don't start
#
#  Folder layout created:
#    /root/dria-nodes/
#    ├── .env            ← your API config (VIKEY_API_URL, VIKEY_API_KEY, etc.)
#    ├── proxy.env       ← generated: PROXY_* names used by the binary
#    ├── dria-node-0xAAA/
#    │   └── docker-compose.yml  (NODE_COUNT services, all same wallet key)
#    ├── dria-node-0xBBB/
#    │   └── docker-compose.yml
#    └── ...
#
#  Compatible with existing dria-node-0x* folders from the old ollama-server-fake
#  setup — wallet private keys are read automatically from existing compose files.
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
NODES_DIR="${NODES_DIR:-/root/dria-nodes}"
REPO_DIR="${REPO_DIR:-/root/dkn-proxy-node}"
REPO_URL="https://github.com/fyibrow/dkn-proxy-node"
DOCKER_IMAGE="dria-proxy-node:latest"
NETWORK_NAME="dria-nodes"
PROXY_ENV="$NODES_DIR/proxy.env"

# ── Colors ────────────────────────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'; N='\033[0m'
log()  { echo -e "${G}[✓]${N} $*"; }
info() { echo -e "${B}[i]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[✗] $*${N}" >&2; exit 1; }
step() { echo -e "\n${C}${W}══ $* ══${N}\n"; }
ask()  { read -rp $'\033[0;36m[?] \033[0m'"$* " REPLY; echo "$REPLY"; }

banner() {
echo -e "${C}${W}"
cat << 'EOF'
  ____       _         _   _           _
 |  _ \ _ __(_) __ _  | \ | | ___   __| | ___
 | | | | '__| |/ _` | |  \| |/ _ \ / _` |/ _ \
 | |_| | |  | | (_| | | |\  | (_) | (_| |  __/
 |____/|_|  |_|\__,_| |_| \_|\___/ \__,_|\___|
        Multi-Wallet · Cloud API Proxy · No GPU needed
EOF
echo -e "${N}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DEPENDENCIES
# ═══════════════════════════════════════════════════════════════════════════════
install_deps() {
    step "Checking dependencies"

    local need_update=false
    for pkg in curl git jq; do
        if ! command -v "$pkg" &>/dev/null; then
            need_update=true
            break
        fi
        log "$pkg OK"
    done
    $need_update && sudo apt-get update -qq && sudo apt-get install -y -qq curl git jq

    # Docker
    if ! command -v docker &>/dev/null; then
        info "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        sudo usermod -aG docker "$USER" 2>/dev/null || true
        warn "You may need to logout/login for Docker group membership."
    else
        log "Docker OK ($(docker --version | awk '{print $3}' | tr -d ','))"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# DOCKER IMAGE
# ═══════════════════════════════════════════════════════════════════════════════
build_image() {
    local force="${1:-false}"

    if ! $force && docker image inspect "$DOCKER_IMAGE" &>/dev/null 2>&1; then
        log "Docker image exists: $DOCKER_IMAGE"
        return
    fi

    step "Building Docker image"

    # Install Rust if not present
    if ! command -v cargo &>/dev/null; then
        info "Installing Rust toolchain..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --quiet
        # shellcheck disable=SC1091
        source "$HOME/.cargo/env"
    fi
    source "$HOME/.cargo/env" 2>/dev/null || true

    # Clone or update source
    if [ -d "$REPO_DIR/.git" ]; then
        info "Updating source..."
        git -C "$REPO_DIR" pull --ff-only 2>/dev/null || warn "Could not pull, using current source"
    else
        info "Cloning $REPO_URL..."
        git clone "$REPO_URL" "$REPO_DIR" || err "Clone failed: check $REPO_URL"
    fi

    info "Building image (5-15 min first time)..."
    docker build -t "$DOCKER_IMAGE" "$REPO_DIR"
    log "Image built: $DOCKER_IMAGE"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DOCKER NETWORK
# ═══════════════════════════════════════════════════════════════════════════════
setup_network() {
    if ! docker network inspect "$NETWORK_NAME" &>/dev/null 2>&1; then
        docker network create "$NETWORK_NAME"
        log "Created Docker network: $NETWORK_NAME"
    else
        log "Docker network exists: $NETWORK_NAME"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# LOAD & TRANSLATE .env
# ═══════════════════════════════════════════════════════════════════════════════
load_env_file() {
    local env_file="$1"
    [ -f "$env_file" ] || err "No .env file at $env_file"

    info "Loading config from $env_file"

    # Source the file to populate variables
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
        export "$line" 2>/dev/null || true
    done < "$env_file"

    # Map VIKEY_* → PROXY_* (backward compat with ollama-server-fake)
    export PROXY_API_URL="${PROXY_API_URL:-${VIKEY_API_URL:-}}"
    export PROXY_API_KEY="${PROXY_API_KEY:-${VIKEY_API_KEY:-}}"
    export PROXY_DEFAULT_MODEL="${PROXY_DEFAULT_MODEL:-${DEFAULT_MODEL:-meta-llama/Llama-3.3-70B-Instruct}}"

    [ -n "$PROXY_API_URL" ]  || err "VIKEY_API_URL (or PROXY_API_URL) is not set in $env_file"
    [ -n "$PROXY_API_KEY" ]  || err "VIKEY_API_KEY (or PROXY_API_KEY) is not set in $env_file"

    # Defaults
    export NODE_COUNT="${NODE_COUNT:-1}"
    export DRIA_MODELS="${DRIA_MODELS:-qwen3.5:9b}"
    export DRIA_MAX_CONCURRENT="${DRIA_MAX_CONCURRENT:-4}"
    export PROXY_MODELS="${PROXY_MODELS:-}"
    export RUST_LOG="${RUST_LOG:-info}"
    export START_DELAY="${START_DELAY:-180}"

    log "API: $PROXY_API_URL"
    log "Model: $PROXY_DEFAULT_MODEL"
    log "Dria models: $DRIA_MODELS"
    log "Nodes per wallet: $NODE_COUNT"
    log "Start delay: ${START_DELAY}s between wallets"
}

# Write the translated proxy.env (with PROXY_* names) used by all containers
write_proxy_env() {
    mkdir -p "$NODES_DIR"
    cat > "$PROXY_ENV" << CONF
PROXY_API_URL=${PROXY_API_URL}
PROXY_API_KEY=${PROXY_API_KEY}
PROXY_DEFAULT_MODEL=${PROXY_DEFAULT_MODEL}
DRIA_MODELS=${DRIA_MODELS}
PROXY_MODELS=${PROXY_MODELS}
DRIA_MAX_CONCURRENT=${DRIA_MAX_CONCURRENT}
DRIA_SKIP_UPDATE=true
RUST_LOG=${RUST_LOG}
CONF
    chmod 600 "$PROXY_ENV"
    log "Proxy config: $PROXY_ENV"
}

# ═══════════════════════════════════════════════════════════════════════════════
# WALLET DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

# Extract unique wallet private keys from all existing docker-compose.yml files
# Supports: DKN_WALLET_SECRET_KEY (old format) and DRIA_WALLET (new format)
scan_existing_wallets() {
    local keys=()
    local seen=()

    while IFS= read -r compose; do
        # Match 64 or 66-char (0x + 64) hex strings after known key variable names
        local raw
        raw=$(grep -E '(DKN_WALLET_SECRET_KEY|DRIA_WALLET)[[:space:]]*[:=][[:space:]]*' "$compose" 2>/dev/null \
              | grep -oE '(0x)?[a-fA-F0-9]{64}' | head -1)
        [ -z "$raw" ] && continue

        # Strip 0x prefix
        local key="${raw#0x}"
        [ ${#key} -eq 64 ] || continue

        # Deduplicate
        local dup=false
        for s in "${seen[@]+"${seen[@]}"}"; do
            [ "$s" = "$key" ] && dup=true && break
        done
        $dup && continue

        seen+=("$key")
        keys+=("$key")
    done < <(find "$NODES_DIR" -maxdepth 3 -name "docker-compose.yml" -type f 2>/dev/null | sort)

    printf '%s\n' "${keys[@]+"${keys[@]}"}"
}

# Derive Ethereum address from a private key (requires Node.js + ethers)
derive_address() {
    local key="$1"
    local gen_dir="$NODES_DIR/.wallet-gen"
    mkdir -p "$gen_dir"

    if [ ! -d "$gen_dir/node_modules/ethers" ]; then
        (cd "$gen_dir" \
            && npm init -y >/dev/null 2>&1 \
            && npm install ethers@5 --save-quiet >/dev/null 2>&1) 2>/dev/null || true
    fi

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

# Install Node + ethers for wallet generation
setup_node_env() {
    if ! command -v node &>/dev/null; then
        info "Installing Node.js LTS..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - -qq
        sudo apt-get install -y -qq nodejs
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# GENERATE docker-compose.yml FOR ONE WALLET
# ═══════════════════════════════════════════════════════════════════════════════
generate_compose() {
    local wallet_key="$1"  # 64 hex chars, no 0x
    local wallet_addr="$2" # 0xFULLADDRESS
    local count="${NODE_COUNT:-1}"

    # If any existing folder already has this key, reuse it instead of creating
    # a new folder (prevents duplicate folders when derive_address() falls back)
    local wallet_dir="$NODES_DIR/dria-node-${wallet_addr}"
    local existing
    existing=$(find "$NODES_DIR" -maxdepth 2 -name "docker-compose.yml" -type f 2>/dev/null \
        | xargs grep -l "DRIA_WALLET.*${wallet_key}" 2>/dev/null | head -1)
    if [ -n "$existing" ]; then
        local existing_dir; existing_dir=$(dirname "$existing")
        if [ "$existing_dir" != "$wallet_dir" ]; then
            info "Key already exists in: $(basename "$existing_dir") — updating in place"
            wallet_dir="$existing_dir"
        fi
    fi

    mkdir -p "$wallet_dir"

    local compose="$wallet_dir/docker-compose.yml"

    # Header
    cat > "$compose" << HDR
# dria-proxy-node — wallet: ${wallet_addr}
# generated: $(date)
# services: ${count}
networks:
  ${NETWORK_NAME}:
    external: true

services:
HDR

    # N identical services per wallet (parallel node instances)
    # container_name intentionally omitted — Docker Compose auto-generates:
    #   {folder_name}-node_{i}-1  e.g. dria-node-0x040dc19a...-node_1-1
    for i in $(seq 1 "$count"); do
        cat >> "$compose" << SVC
  node_${i}:
    image: "${DOCKER_IMAGE}"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    env_file:
      - ../proxy.env
    environment:
      DRIA_WALLET: "0x${wallet_key}"
    volumes:
      - ${NODES_DIR}/.env:/etc/dria/proxy.env:ro
    restart: "on-failure"
    networks:
      - ${NETWORK_NAME}
    logging:
      driver: "json-file"
      options:
        max-size: "5m"
        max-file: "2"

SVC
    done

    log "Compose: $compose ($count service(s))"
}

# ═══════════════════════════════════════════════════════════════════════════════
# START ALL CONTAINERS
# ═══════════════════════════════════════════════════════════════════════════════
start_all() {
    step "Starting all nodes"

    local delay="${START_DELAY:-180}"
    local composes=()
    while IFS= read -r f; do composes+=("$f"); done \
        < <(find "$NODES_DIR" -maxdepth 2 -name "docker-compose.yml" -type f | sort)

    local total="${#composes[@]}"
    local started=0

    local skipped=0
    for compose in "${composes[@]}"; do
        local dir; dir=$(dirname "$compose")
        local name; name=$(basename "$dir")
        (( started++ )) || true

        # Skip old-format compose files (firstbatch/dkn-compute-node)
        # They should have been migrated by manage.sh migrate step above
        if grep -q "firstbatch/dkn-compute-node\|dkn-compute-node:latest" "$compose" 2>/dev/null; then
            warn "[$started/$total] Skipping old-format: $name (run manage.sh migrate)"
            (( skipped++ )) || true
            continue
        fi

        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        info "Starting node [$started/$total]: $name"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        # Strip leftover container_name lines
        sed -i '/^[[:space:]]*container_name:/d' "$compose" 2>/dev/null || true

        if (cd "$dir" && docker compose up -d); then
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
    log "Started: $((total - skipped)) folder(s) — skipped (old format): $skipped"
    [ "$skipped" -gt 0 ] && warn "Run: bash $REPO_DIR/manage.sh migrate  to convert skipped folders"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    docker ps --filter "name=dria-" \
        --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# GENERATE WALLETS (fresh install only)
# ═══════════════════════════════════════════════════════════════════════════════
generate_fresh_wallets() {
    local count="$1"
    setup_node_env

    local gen_dir="$NODES_DIR/.wallet-gen"
    mkdir -p "$gen_dir"
    [ -d "$gen_dir/node_modules/ethers" ] || \
        (cd "$gen_dir" && npm init -y >/dev/null 2>&1 && npm install ethers@5 --save-quiet >/dev/null 2>&1)

    node << JSEOF 2>/dev/null
const {Wallet}=require('$gen_dir/node_modules/ethers');
for(let i=0;i<$count;i++){
  const w=Wallet.createRandom();
  process.stdout.write(w.privateKey.slice(2)+'\n');
  process.stderr.write('  [' + (i+1) + '] ' + w.address + '\n');
  process.stderr.write('       ' + w.privateKey + '\n\n');
}
JSEOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
main() {
    banner

    local do_rebuild=false
    local do_start=true
    local env_file=""

    for arg in "$@"; do
        case "$arg" in
        --rebuild)   do_rebuild=true ;;
        --no-start)  do_start=false ;;
        --env=*)     env_file="${arg#--env=}" ;;
        esac
    done

    # ── 1. Dependencies ────────────────────────────────────────────────────────
    install_deps

    # ── 2. Locate .env ─────────────────────────────────────────────────────────
    step "Configuration"
    mkdir -p "$NODES_DIR"

    if [ -z "$env_file" ]; then
        # Check common locations
        if [ -f "$NODES_DIR/.env" ]; then
            env_file="$NODES_DIR/.env"
        elif [ -f ".env" ]; then
            env_file=".env"
        elif [ -f "$REPO_DIR/.env" ]; then
            env_file="$REPO_DIR/.env"
        else
            warn "No .env file found."
            echo ""
            echo "  Expected locations:"
            echo "    $NODES_DIR/.env   ← recommended"
            echo "    $REPO_DIR/.env.example  ← template"
            echo ""
            local create; create=$(ask "Create $NODES_DIR/.env from template now? [y/N]:")
            if [[ "$create" =~ ^[Yy]$ ]]; then
                local tmpl="$REPO_DIR/.env.example"
                [ -f "$tmpl" ] || err "Template not found: $tmpl"
                cp "$tmpl" "$NODES_DIR/.env"
                warn "Edit $NODES_DIR/.env with your API key, then re-run deploy.sh"
                exit 0
            else
                err "Cannot continue without .env. Set VIKEY_API_KEY and VIKEY_API_URL."
            fi
        fi
    fi

    load_env_file "$env_file"
    # Copy .env to NODES_DIR if not already there
    [ "$(realpath "$env_file")" != "$(realpath "$NODES_DIR/.env" 2>/dev/null || echo '')" ] \
        && cp "$env_file" "$NODES_DIR/.env" && log "Copied .env to $NODES_DIR/.env"
    write_proxy_env

    # ── 3. Docker image ────────────────────────────────────────────────────────
    build_image "$do_rebuild"

    # ── 4. Docker network ──────────────────────────────────────────────────────
    setup_network

    # ── 5. Collect wallet keys ─────────────────────────────────────────────────
    step "Wallets"

    local wallet_keys=()
    readarray -t scanned < <(scan_existing_wallets)

    if [ ${#scanned[@]} -gt 0 ]; then
        echo -e "  Found ${#scanned[@]} wallet key(s) in existing compose files:"
        setup_node_env
        for key in "${scanned[@]}"; do
            local addr; addr=$(derive_address "$key")
            echo "    • ${addr}"
            wallet_keys+=("$key")
        done
        echo ""
        local add_more; add_more=$(ask "Add more wallets? [y/N]:")
        [[ "$add_more" =~ ^[Yy]$ ]] && _collect_extra_wallets wallet_keys
    else
        echo "  No existing wallet folders found."
        echo "  1) Generate new wallets"
        echo "  2) Enter private keys manually"
        echo ""
        local wmethod; wmethod=$(ask "Choose [1/2]:")
        case "$wmethod" in
        1)
            local wcount; wcount=$(ask "How many wallets to generate?")
            [[ "$wcount" =~ ^[0-9]+$ ]] || err "Invalid number"
            setup_node_env
            while IFS= read -r key; do
                [ -n "$key" ] && wallet_keys+=("$key")
            done < <(generate_fresh_wallets "$wcount")
            warn "Back up the private keys shown above — they cannot be recovered!"
            ;;
        2)
            _collect_extra_wallets wallet_keys
            ;;
        *) err "Invalid choice" ;;
        esac
    fi

    [ ${#wallet_keys[@]} -gt 0 ] || err "No wallet keys to deploy"
    log "Total wallets: ${#wallet_keys[@]}"

    # ── 6. Generate docker-compose files ───────────────────────────────────────
    step "Generating compose files"
    setup_node_env

    for key in "${wallet_keys[@]}"; do
        local addr; addr=$(derive_address "$key")
        generate_compose "$key" "$addr"
    done

    # ── 7. Migrate any remaining old-format compose files ─────────────────────
    local old_count
    old_count=$(find "$NODES_DIR" -maxdepth 2 -name "docker-compose.yml" \
        -exec grep -l "firstbatch/dkn-compute-node" {} \; 2>/dev/null | wc -l)
    if [ "$old_count" -gt 0 ]; then
        step "Migrating $old_count old-format compose file(s)"
        bash "$REPO_DIR/manage.sh" migrate 2>&1 || warn "Some migrations may have failed"
    fi

    # ── 8. Start ───────────────────────────────────────────────────────────────
    if $do_start; then
        start_all
    else
        warn "--no-start: compose files generated but containers not started"
        echo "  Start manually: bash manage.sh start"
    fi

    # ── Summary ────────────────────────────────────────────────────────────────
    echo -e "${G}${W}═══════════════════════════════════════════${N}"
    echo -e "${G}${W}  Deployment complete!${N}"
    echo -e "${G}${W}═══════════════════════════════════════════${N}"
    echo ""
    echo "  Node count : ${#wallet_keys[@]} wallet(s) × $NODE_COUNT service(s) = $((${#wallet_keys[@]} * NODE_COUNT)) containers"
    echo "  API config : $PROXY_ENV"
    echo "  Nodes dir  : $NODES_DIR"
    echo ""
    echo "  Manage with:"
    echo "    bash $REPO_DIR/manage.sh status"
    echo "    bash $REPO_DIR/manage.sh logs"
    echo "    bash $REPO_DIR/manage.sh restart"
    echo ""
}

# Prompt user to enter private key(s) manually
_collect_extra_wallets() {
    local -n _arr=$1
    while true; do
        local k; k=$(ask "Enter private key (64 hex, with or without 0x), or ENTER to finish:")
        [ -z "$k" ] && break
        k="${k#0x}"
        if [ ${#k} -ne 64 ]; then
            warn "Key must be 64 hex chars (got ${#k}). Try again."
            continue
        fi
        _arr+=("$k")
        log "Added wallet key ${k:0:8}..."
    done
}

main "$@"
