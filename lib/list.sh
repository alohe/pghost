#!/usr/bin/env bash
# pghost list - show all instances with status

cmd_list() {
    require_root
    ensure_dirs

    local instances=("$PGHOST_INSTANCES"/*.env)

    if [ ! -f "${instances[0]}" ]; then
        header "PostgreSQL Instances"
        info "No instances found."
        echo ""
        info "Create one with: ${BOLD}pghost create mydb${NC}"
        echo ""
        return
    fi

    header "PostgreSQL Instances"

    printf "  ${BOLD}%-14s %-10s %-8s %-18s %-20s${NC}\n" "NAME" "STATUS" "PORT" "DATABASE" "DOMAIN"
    divider

    for env_file in "$PGHOST_INSTANCES"/*.env; do
        [ -f "$env_file" ] || continue

        source "$env_file"

        local status="${RED}stopped${NC}"
        local container=$(container_name "$INSTANCE_NAME")

        if docker ps --format '{{.Names}}' | grep -q "^${container}$" 2>/dev/null; then
            status="${GREEN}running${NC}"
        elif docker ps -a --format '{{.Names}}' | grep -q "^${container}$" 2>/dev/null; then
            status="${YELLOW}stopped${NC}"
        fi

        local domain_display="${DOMAIN:-${DIM}-${NC}}"

        printf "  %-14s %-22b %-8s %-18s %-20s\n" \
            "$INSTANCE_NAME" "$status" "$DB_PORT" "$DB_NAME" "$domain_display"
    done

    echo ""
    info "Run ${BOLD}pghost metrics <name>${NC} for detailed stats."
    info "Run ${BOLD}pghost url <name>${NC} to get the connection URL."
    echo ""
}

cmd_url() {
    require_root

    local name="$1"
    if [ -z "$name" ]; then
        error "Usage: pghost url <instance-name>"
        exit 1
    fi

    load_instance "$name"

    echo ""
    echo -e "  ${BOLD}DATABASE_URL for '$name':${NC}"
    echo ""
    echo -e "  ${GREEN}$DATABASE_URL${NC}"
    echo ""

    if [ -n "$DOMAIN" ]; then
        local domain_url="postgresql://${DB_USER}:${DB_PASSWORD}@${DOMAIN}:${DB_PORT}/${DB_NAME}?sslmode=require"
        echo -e "  ${BOLD}Domain URL:${NC}"
        echo ""
        echo -e "  ${GREEN}$domain_url${NC}"
        echo ""
    fi

    echo -e "  ${DIM}For your .env:${NC}"
    echo ""
    echo "  DATABASE_URL=\"$DATABASE_URL\""
    echo ""
}

cmd_stop() {
    require_root
    require_docker

    local name="$1"
    if [ -z "$name" ]; then
        error "Usage: pghost stop <instance-name>"
        exit 1
    fi

    load_instance "$name"
    local container=$(container_name "$name")

    step "Stopping '$name'..."
    if ! docker stop "$container" > /dev/null 2>&1; then
        error "Failed to stop '$name'. It may already be stopped."
        echo ""
        return
    fi
    success "Instance '$name' stopped."
    echo ""
}

cmd_start() {
    require_root
    require_docker

    local name="$1"
    if [ -z "$name" ]; then
        error "Usage: pghost start <instance-name>"
        exit 1
    fi

    load_instance "$name"
    local container=$(container_name "$name")

    step "Starting '$name'..."
    if ! docker start "$container" > /dev/null 2>&1; then
        error "Failed to start container '$container'. Check: docker logs $container"
        echo ""
        return
    fi

    local retries=0
    while [ $retries -lt 15 ]; do
        if docker exec "$container" pg_isready -U "$DB_USER" > /dev/null 2>&1; then
            success "Instance '$name' is running on port $DB_PORT."
            echo ""
            return
        fi
        retries=$((retries + 1))
        sleep 1
    done

    error "Instance failed to start. Check: docker logs $container"
    echo ""
}

cmd_restart() {
    require_root
    require_docker

    local name="$1"
    if [ -z "$name" ]; then
        error "Usage: pghost restart <instance-name>"
        exit 1
    fi

    load_instance "$name"
    local container=$(container_name "$name")

    step "Restarting '$name'..."
    if ! docker restart "$container" > /dev/null 2>&1; then
        error "Failed to restart '$name'. Check: docker logs $container"
        echo ""
        return
    fi
    sleep 2
    success "Instance '$name' restarted."
    echo ""
}

cmd_delete() {
    require_root
    require_docker

    local name="$1"
    local force=false

    if [ "${2:-}" = "--force" ] || [ "${2:-}" = "-f" ]; then
        force=true
    fi

    if [ -z "$name" ]; then
        error "Usage: pghost delete <instance-name> [--force]"
        exit 1
    fi

    load_instance "$name"
    local container=$(container_name "$name")

    if [ "$force" != true ]; then
        echo ""
        warn "This will ${RED}permanently delete${NC} instance '${BOLD}$name${NC}' and all its data."
        echo ""
        echo -n "  Type the instance name to confirm: "
        read -r confirm
        if [ "$confirm" != "$name" ]; then
            info "Cancelled."
            echo ""
            return
        fi
    fi

    echo ""
    step "Stopping container..."
    docker stop "$container" > /dev/null 2>&1 || true
    docker rm "$container" > /dev/null 2>&1 || true

    step "Removing data..."
    rm -rf "$PGHOST_DATA/$name"
    rm -rf "$PGHOST_CERTS/$name"

    # Remove nginx config if exists
    rm -f "$PGHOST_NGINX_DIR/pghost-$name.conf" 2>/dev/null || true
    rm -f "/etc/nginx/stream.d/pghost-$name.conf" 2>/dev/null || true
    nginx -s reload 2>/dev/null || true

    step "Removing instance config..."
    rm -f "$PGHOST_INSTANCES/$name.env"
    rm -f "$PGHOST_INSTANCES/$name.rules"

    echo ""
    success "Instance '$name' deleted."
    echo ""
}

cmd_logs() {
    require_root
    require_docker

    local name="$1"
    local lines="${2:-50}"

    if [ -z "$name" ]; then
        error "Usage: pghost logs <instance-name> [lines]"
        exit 1
    fi

    load_instance "$name"
    local container=$(container_name "$name")

    docker logs --tail "$lines" "$container" 2>&1
}
