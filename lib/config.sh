#!/usr/bin/env bash
# pghost - shared configuration and helpers

PGHOST_VERSION="1.0.0"
PGHOST_DIR="/opt/pghost"
PGHOST_DATA="$PGHOST_DIR/data"
PGHOST_CERTS="$PGHOST_DIR/certs"
PGHOST_BACKUPS="$PGHOST_DIR/backups"
PGHOST_LOGS="$PGHOST_DIR/logs"
PGHOST_INSTANCES="$PGHOST_DIR/instances"
PGHOST_NGINX_DIR="/etc/nginx/conf.d"

DOCKER_NETWORK="pghost-net"
PG_IMAGE="postgres:16-alpine"
NGINX_CONTAINER="pghost-nginx"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

header() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}$1${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

info()    { echo -e "  ${BLUE}ℹ${NC}  $1"; }
success() { echo -e "  ${GREEN}✓${NC}  $1"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $1"; }
error()   { echo -e "  ${RED}✗${NC}  $1"; }
step()    { echo -e "  ${CYAN}→${NC}  $1"; }
dim()     { echo -e "  ${DIM}$1${NC}"; }

divider() {
    echo -e "  ${DIM}──────────────────────────────────────────────────────${NC}"
}

gen_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-32
}

get_server_ip() {
    curl -4 -s --max-time 5 ifconfig.me 2>/dev/null \
        || curl -4 -s --max-time 5 icanhazip.com 2>/dev/null \
        || curl -4 -s --max-time 5 api.ipify.org 2>/dev/null \
        || hostname -I | awk '{print $1}'
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        error "This command requires root privileges. Run with sudo."
        exit 1
    fi
}

require_docker() {
    if ! command -v docker &> /dev/null; then
        error "Docker is not installed. Run: pghost install"
        exit 1
    fi
}

ensure_dirs() {
    mkdir -p "$PGHOST_DATA" "$PGHOST_CERTS" "$PGHOST_BACKUPS" "$PGHOST_LOGS" "$PGHOST_INSTANCES"
}

ensure_network() {
    if ! docker network inspect "$DOCKER_NETWORK" &>/dev/null; then
        docker network create "$DOCKER_NETWORK" --driver bridge > /dev/null 2>&1
    fi
}

instance_exists() {
    local name="$1"
    [ -f "$PGHOST_INSTANCES/$name.env" ]
}

load_instance() {
    local name="$1"
    if ! instance_exists "$name"; then
        error "Instance '$name' does not exist."
        echo ""
        info "Run ${BOLD}pghost list${NC} to see available instances."
        exit 1
    fi
    source "$PGHOST_INSTANCES/$name.env"
}

container_name() {
    echo "pghost-$1"
}

next_available_port() {
    local port=5432
    while true; do
        if ! docker ps --format '{{.Ports}}' | grep -q ":${port}->" 2>/dev/null; then
            if ! ss -tlnp 2>/dev/null | grep -q ":${port} " 2>/dev/null; then
                echo "$port"
                return
            fi
        fi
        port=$((port + 1))
    done
}

format_bytes() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        echo "$(echo "scale=1; $bytes / 1073741824" | bc)GB"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$(echo "scale=1; $bytes / 1048576" | bc)MB"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$(echo "scale=1; $bytes / 1024" | bc)KB"
    else
        echo "${bytes}B"
    fi
}
