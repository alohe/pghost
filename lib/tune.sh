#!/usr/bin/env bash
# pghost tune - performance tuning, maintenance, and PgBouncer

# ─── tune ────────────────────────────────────────────────────────────────────
# Re-tunes PostgreSQL memory settings based on current container memory limit.
# Safe to run on a live instance — applies without restart via pg_reload_conf().

cmd_tune() {
    require_root
    require_docker

    local name="$1"
    if [ -z "$name" ]; then
        error "Usage: pghost tune <instance-name>"
        echo ""
        info "Examples:"
        dim "  pghost tune myapp"
        echo ""
        exit 1
    fi

    load_instance "$name"
    local container=$(container_name "$name")

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$" 2>/dev/null; then
        error "Instance '$name' is not running. Start it first: pghost start $name"
        echo ""
        exit 1
    fi

    header "Tuning: $name"

    # Parse memory limit to MB
    local mem_mb
    mem_mb=$(echo "$MEMORY_LIMIT" | sed 's/[Mm]$//' | sed 's/[Gg]$/*1024/' | bc 2>/dev/null || echo 512)

    # Compute tuned values
    local shared_buffers work_mem maintenance_work_mem effective_cache_size
    shared_buffers=$(echo "scale=0; $mem_mb / 4" | bc)MB
    work_mem=$(echo "scale=0; $mem_mb / ($MAX_CONNECTIONS * 2)" | bc)
    [ "$work_mem" -lt 4 ] && work_mem=4
    work_mem="${work_mem}MB"
    maintenance_work_mem=$(echo "scale=0; $mem_mb / 8" | bc)
    [ "$maintenance_work_mem" -lt 64 ] && maintenance_work_mem=64
    maintenance_work_mem="${maintenance_work_mem}MB"
    effective_cache_size=$(echo "scale=0; $mem_mb * 3 / 4" | bc)MB

    step "Applying tuned settings for ${MEMORY_LIMIT} RAM..."
    dim "  shared_buffers      = $shared_buffers"
    dim "  work_mem            = $work_mem"
    dim "  maintenance_work_mem= $maintenance_work_mem"
    dim "  effective_cache_size= $effective_cache_size"
    echo ""

    local sql_output
    if ! sql_output=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -c "
        ALTER SYSTEM SET shared_buffers = '$shared_buffers';
        ALTER SYSTEM SET work_mem = '$work_mem';
        ALTER SYSTEM SET maintenance_work_mem = '$maintenance_work_mem';
        ALTER SYSTEM SET effective_cache_size = '$effective_cache_size';
        ALTER SYSTEM SET wal_buffers = '16MB';
        ALTER SYSTEM SET checkpoint_completion_target = '0.9';
        ALTER SYSTEM SET random_page_cost = '1.1';
        ALTER SYSTEM SET autovacuum = 'on';
        ALTER SYSTEM SET autovacuum_vacuum_scale_factor = '0.05';
        ALTER SYSTEM SET autovacuum_analyze_scale_factor = '0.02';
        ALTER SYSTEM SET autovacuum_vacuum_cost_delay = '2ms';
        ALTER SYSTEM SET log_min_duration_statement = '1000';
        SELECT pg_reload_conf();
    " 2>&1); then
        warn "Some settings could not be applied: $sql_output"
    else
        success "Settings applied (no restart needed)"
    fi

    # shared_buffers requires restart to take full effect
    warn "shared_buffers requires a restart to fully take effect."
    echo -n "  Restart '$name' now? [y/N]: "
    read -r reply
    if [[ "$reply" =~ ^[Yy]$ ]]; then
        docker restart "$container" > /dev/null 2>&1 && success "Restarted." || warn "Restart failed"
    fi

    echo ""
}

# ─── maintain ────────────────────────────────────────────────────────────────
# Runs VACUUM ANALYZE on all tables and reports bloat/stats.

cmd_maintain() {
    require_root
    require_docker

    local name="$1"
    if [ -z "$name" ]; then
        error "Usage: pghost maintain <instance-name>"
        echo ""
        info "Examples:"
        dim "  pghost maintain myapp"
        echo ""
        exit 1
    fi

    load_instance "$name"
    local container=$(container_name "$name")

    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$" 2>/dev/null; then
        error "Instance '$name' is not running. Start it first: pghost start $name"
        echo ""
        exit 1
    fi

    header "Maintenance: $name"

    step "Running VACUUM ANALYZE on all tables..."
    local sql_output
    if ! sql_output=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -c "VACUUM ANALYZE;" 2>&1); then
        warn "VACUUM ANALYZE reported issues: $sql_output"
    else
        success "VACUUM ANALYZE complete"
    fi

    step "Updating table statistics..."
    docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -c "ANALYZE;" > /dev/null 2>&1 || true
    success "Statistics updated"

    echo ""

    # Show table bloat
    echo -e "  ${BOLD}Table Stats${NC}"
    divider
    local table_stats
    table_stats=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc "
        SELECT
            schemaname || '.' || relname,
            pg_size_pretty(pg_total_relation_size(schemaname || '.' || relname)),
            n_live_tup,
            n_dead_tup,
            CASE WHEN n_live_tup > 0
                THEN round(100.0 * n_dead_tup / n_live_tup, 1)
                ELSE 0
            END AS bloat_pct,
            to_char(last_vacuum, 'YYYY-MM-DD HH24:MI'),
            to_char(last_analyze, 'YYYY-MM-DD HH24:MI')
        FROM pg_stat_user_tables
        ORDER BY pg_total_relation_size(schemaname || '.' || relname) DESC
        LIMIT 10;
    " 2>/dev/null || true)

    if [ -n "$table_stats" ]; then
        printf "  ${BOLD}%-35s %-8s %-10s %-10s %-8s %-16s %-16s${NC}\n" \
            "TABLE" "SIZE" "LIVE" "DEAD" "BLOAT%" "LAST VACUUM" "LAST ANALYZE"
        divider
        while IFS='|' read -r tbl size live dead bloat vac ana; do
            local bloat_color="$GREEN"
            local bloat_num=${bloat%.*}
            [ "${bloat_num:-0}" -gt 10 ] 2>/dev/null && bloat_color="$YELLOW"
            [ "${bloat_num:-0}" -gt 30 ] 2>/dev/null && bloat_color="$RED"
            printf "  %-35s %-8s %-10s %-10s ${bloat_color}%-8s${NC} %-16s %-16s\n" \
                "$tbl" "${size// /}" "${live// /}" "${dead// /}" "${bloat// /}%" \
                "${vac:-never}" "${ana:-never}"
        done <<< "$table_stats"
    else
        dim "  No user tables found."
    fi

    echo ""

    # Show missing index warnings (sequential scans on large tables)
    echo -e "  ${BOLD}Potential Missing Indexes${NC}"
    divider
    local seq_scans
    seq_scans=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc "
        SELECT schemaname || '.' || relname, seq_scan, idx_scan,
               pg_size_pretty(pg_total_relation_size(schemaname || '.' || relname))
        FROM pg_stat_user_tables
        WHERE seq_scan > 100
          AND (idx_scan = 0 OR seq_scan > idx_scan * 10)
          AND pg_total_relation_size(schemaname || '.' || relname) > 1048576
        ORDER BY seq_scan DESC
        LIMIT 5;
    " 2>/dev/null || true)

    if [ -n "$seq_scans" ]; then
        warn "These tables have heavy sequential scans — consider adding indexes:"
        echo ""
        while IFS='|' read -r tbl seqs idxs size; do
            printf "  ${YELLOW}%-35s${NC} seq_scans=%-8s idx_scans=%-8s size=%s\n" \
                "${tbl// /}" "${seqs// /}" "${idxs// /}" "${size// /}"
        done <<< "$seq_scans"
        echo ""
        dim "  Example: CREATE INDEX idx_<table>_<col> ON <table>(<column>);"
    else
        success "No obvious missing indexes detected"
    fi

    echo ""

    # Show slow query log summary
    echo -e "  ${BOLD}Slow Queries (>1s, from pg_stat_statements if available)${NC}"
    divider
    local slow_queries
    slow_queries=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc "
        SELECT round(mean_exec_time::numeric, 0) || 'ms avg',
               calls,
               left(query, 80)
        FROM pg_stat_statements
        WHERE mean_exec_time > 1000
        ORDER BY mean_exec_time DESC
        LIMIT 5;
    " 2>/dev/null || true)

    if [ -n "$slow_queries" ]; then
        warn "Slow queries detected:"
        echo ""
        while IFS='|' read -r avg calls q; do
            printf "  ${YELLOW}%-12s${NC} calls=%-8s %s\n" "${avg// /}" "${calls// /}" "${q// /}"
        done <<< "$slow_queries"
    else
        dim "  No slow query data (pg_stat_statements not enabled or no data yet)"
    fi

    echo ""
    success "Maintenance complete."
    info "Run weekly: ${BOLD}pghost cron $name weekly${NC} handles backups automatically."
    echo ""
}

# ─── bouncer ─────────────────────────────────────────────────────────────────
# Deploys PgBouncer as a Docker sidecar in transaction pooling mode.
# Next.js / app → PgBouncer (port DB_PORT+1) → Postgres (port DB_PORT)

cmd_bouncer() {
    require_root
    require_docker

    local name="$1"
    local action="${2:-status}"

    if [ -z "$name" ]; then
        error "Usage: pghost bouncer <instance-name> [start|stop|status]"
        echo ""
        info "Examples:"
        dim "  pghost bouncer myapp start    # Deploy PgBouncer sidecar"
        dim "  pghost bouncer myapp stop     # Remove PgBouncer"
        dim "  pghost bouncer myapp status   # Show status"
        echo ""
        exit 1
    fi

    load_instance "$name"

    case "$action" in
        start)  _bouncer_start "$name" ;;
        stop)   _bouncer_stop "$name" ;;
        status) _bouncer_status "$name" ;;
        *)
            error "Unknown action: $action. Use: start, stop, status"
            exit 1
            ;;
    esac
}

_bouncer_start() {
    local name="$1"
    local bouncer_container="pghost-bouncer-$name"
    local bouncer_port=$((DB_PORT + 1))

    header "PgBouncer: $name"

    if docker ps -a --format '{{.Names}}' | grep -q "^${bouncer_container}$" 2>/dev/null; then
        warn "PgBouncer already exists for '$name'."
        info "Stop it first: ${BOLD}pghost bouncer $name stop${NC}"
        echo ""
        return
    fi

    step "Deploying PgBouncer on port $bouncer_port..."

    # Write pgbouncer.ini
    local bouncer_dir="$PGHOST_DATA/$name/bouncer"
    mkdir -p "$bouncer_dir"

    cat > "$bouncer_dir/pgbouncer.ini" << BOUNCER
[databases]
${DB_NAME} = host=pghost-${name} port=5432 dbname=${DB_NAME}

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 5432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 20
reserve_pool_size = 5
reserve_pool_timeout = 3
server_tls_sslmode = require
server_tls_ca_file = /etc/pgbouncer/server.crt
log_connections = 1
log_disconnections = 1
BOUNCER

    # Write userlist.txt (md5 hash of password for pgbouncer)
    local pg_pass_hash
    pg_pass_hash=$(docker exec "$(container_name "$name")" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
        "SELECT concat('md5', md5('${DB_PASSWORD}${DB_USER}'));" 2>/dev/null || echo "\"${DB_USER}\" \"${DB_PASSWORD}\"")
    echo "\"${DB_USER}\" \"${DB_PASSWORD}\"" > "$bouncer_dir/userlist.txt"
    chmod 600 "$bouncer_dir/userlist.txt"

    local docker_output
    if ! docker_output=$(docker run -d \
        --name "$bouncer_container" \
        --network "$DOCKER_NETWORK" \
        --restart unless-stopped \
        -p "${bouncer_port}:5432" \
        -v "$bouncer_dir/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro" \
        -v "$bouncer_dir/userlist.txt:/etc/pgbouncer/userlist.txt:ro" \
        -v "$PGHOST_CERTS/$name/server.crt:/etc/pgbouncer/server.crt:ro" \
        bitnami/pgbouncer:latest \
        2>&1); then
        error "Failed to start PgBouncer:"
        echo "  $docker_output"
        exit 1
    fi

    # Save bouncer port to instance env
    if grep -q "^BOUNCER_PORT=" "$PGHOST_INSTANCES/$name.env"; then
        sed -i "s|^BOUNCER_PORT=.*|BOUNCER_PORT=\"$bouncer_port\"|" "$PGHOST_INSTANCES/$name.env"
    else
        echo "BOUNCER_PORT=\"$bouncer_port\"" >> "$PGHOST_INSTANCES/$name.env"
    fi

    local bouncer_url="postgresql://${DB_USER}:${DB_PASSWORD}@${SERVER_IP}:${bouncer_port}/${DB_NAME}?sslmode=require"

    echo ""
    success "PgBouncer deployed!"
    echo ""
    divider
    echo ""
    echo -e "  ${BOLD}Pooled DATABASE_URL (use this in your app):${NC}"
    echo ""
    echo -e "  ${GREEN}$bouncer_url${NC}"
    echo ""
    divider
    echo ""
    dim "  Pool mode:         transaction (best for Next.js / serverless)"
    dim "  Max client conns:  1000"
    dim "  Pool size:         20 per database"
    dim "  Postgres port:     $DB_PORT (direct)"
    dim "  PgBouncer port:    $bouncer_port (pooled — use this)"
    echo ""
    info "Update your app's DATABASE_URL to use port ${bouncer_port}."
    echo ""
}

_bouncer_stop() {
    local name="$1"
    local bouncer_container="pghost-bouncer-$name"

    step "Stopping PgBouncer for '$name'..."
    docker stop "$bouncer_container" > /dev/null 2>&1 || true
    docker rm "$bouncer_container" > /dev/null 2>&1 || true

    sed -i "/^BOUNCER_PORT=/d" "$PGHOST_INSTANCES/$name.env" 2>/dev/null || true

    success "PgBouncer stopped."
    echo ""
}

_bouncer_status() {
    local name="$1"
    local bouncer_container="pghost-bouncer-$name"

    header "PgBouncer Status: $name"

    if docker ps --format '{{.Names}}' | grep -q "^${bouncer_container}$" 2>/dev/null; then
        success "PgBouncer is running"
        echo ""

        local stats
        stats=$(docker exec "$bouncer_container" psql -U pgbouncer pgbouncer -tAc \
            "SHOW POOLS;" 2>/dev/null || true)

        if [ -n "$stats" ]; then
            echo -e "  ${BOLD}Pool Stats:${NC}"
            divider
            echo "$stats" | while IFS='|' read -r db user cl_active cl_waiting sv_active sv_idle sv_used sv_tested; do
                printf "  db=%-15s user=%-15s active=%-4s waiting=%-4s\n" \
                    "${db// /}" "${user// /}" "${cl_active// /}" "${cl_waiting// /}"
            done
        fi

        echo ""
        local bouncer_port="${BOUNCER_PORT:-$((DB_PORT + 1))}"
        dim "  Pooled URL: postgresql://${DB_USER}:***@${SERVER_IP}:${bouncer_port}/${DB_NAME}?sslmode=require"
    else
        warn "PgBouncer is not running for '$name'."
        info "Start it: ${BOLD}pghost bouncer $name start${NC}"
    fi

    echo ""
}
