#!/usr/bin/env bash
# pghost metrics - show usage stats per instance

cmd_metrics() {
    require_root
    require_docker

    local name="$1"

    if [ -z "$name" ]; then
        # Show metrics for all instances
        _metrics_all
        return
    fi

    load_instance "$name"

    local container=$(container_name "$name")

    # Check if running
    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$" 2>/dev/null; then
        error "Instance '$name' is not running."
        info "Start it with: ${BOLD}pghost start $name${NC}"
        echo ""
        exit 1
    fi

    header "Metrics: $name"

    # Container resource usage
    local stats=$(docker stats "$container" --no-stream --format '{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}' 2>/dev/null)

    local cpu=$(echo "$stats" | cut -f1)
    local mem_usage=$(echo "$stats" | cut -f2)
    local mem_pct=$(echo "$stats" | cut -f3)
    local net_io=$(echo "$stats" | cut -f4)
    local block_io=$(echo "$stats" | cut -f5)

    echo -e "  ${BOLD}Container Resources${NC}"
    divider
    echo -e "  CPU Usage:        $cpu"
    echo -e "  Memory:           $mem_usage ($mem_pct)"
    echo -e "  Network I/O:      $net_io"
    echo -e "  Disk I/O:         $block_io"
    echo -e "  Memory Limit:     $MEMORY_LIMIT"
    echo ""

    # PostgreSQL stats
    echo -e "  ${BOLD}Database Statistics${NC}"
    divider

    # Connection count
    local conn_count=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
        "SELECT count(*) FROM pg_stat_activity WHERE datname = '$DB_NAME';" 2>/dev/null)
    echo -e "  Active Connections:  ${conn_count:-0} / $MAX_CONNECTIONS"

    # Database size
    local db_size=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
        "SELECT pg_size_pretty(pg_database_size('$DB_NAME'));" 2>/dev/null)
    echo -e "  Database Size:       ${db_size:-unknown}"

    # Total tables
    local table_count=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
        "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null)
    echo -e "  Tables:              ${table_count:-0}"

    # Index count
    local index_count=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
        "SELECT count(*) FROM pg_indexes WHERE schemaname = 'public';" 2>/dev/null)
    echo -e "  Indexes:             ${index_count:-0}"

    # Uptime
    local uptime=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
        "SELECT date_trunc('second', current_timestamp - pg_postmaster_start_time());" 2>/dev/null)
    echo -e "  Uptime:              ${uptime:-unknown}"

    echo ""

    # Transactions stats
    echo -e "  ${BOLD}Transaction Statistics${NC}"
    divider

    local tx_stats=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
        "SELECT xact_commit, xact_rollback, tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted FROM pg_stat_database WHERE datname = '$DB_NAME';" 2>/dev/null)

    if [ -n "$tx_stats" ]; then
        local commits=$(echo "$tx_stats" | cut -d'|' -f1 | xargs)
        local rollbacks=$(echo "$tx_stats" | cut -d'|' -f2 | xargs)
        local returned=$(echo "$tx_stats" | cut -d'|' -f3 | xargs)
        local fetched=$(echo "$tx_stats" | cut -d'|' -f4 | xargs)
        local inserted=$(echo "$tx_stats" | cut -d'|' -f5 | xargs)
        local updated=$(echo "$tx_stats" | cut -d'|' -f6 | xargs)
        local deleted=$(echo "$tx_stats" | cut -d'|' -f7 | xargs)

        echo -e "  Commits:             ${commits:-0}"
        echo -e "  Rollbacks:           ${rollbacks:-0}"
        echo -e "  Rows Returned:       ${returned:-0}"
        echo -e "  Rows Fetched:        ${fetched:-0}"
        echo -e "  Rows Inserted:       ${inserted:-0}"
        echo -e "  Rows Updated:        ${updated:-0}"
        echo -e "  Rows Deleted:        ${deleted:-0}"
    fi

    echo ""

    # Cache hit ratio
    echo -e "  ${BOLD}Performance${NC}"
    divider

    local cache_ratio=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
        "SELECT ROUND(100 * sum(blks_hit) / NULLIF(sum(blks_hit) + sum(blks_read), 0), 2) FROM pg_stat_database WHERE datname = '$DB_NAME';" 2>/dev/null)
    if [ -n "$cache_ratio" ] && [ "$cache_ratio" != "" ]; then
        local cache_color="$GREEN"
        if (( $(echo "$cache_ratio < 90" | bc -l 2>/dev/null || echo 0) )); then
            cache_color="$YELLOW"
        fi
        if (( $(echo "$cache_ratio < 70" | bc -l 2>/dev/null || echo 0) )); then
            cache_color="$RED"
        fi
        echo -e "  Cache Hit Ratio:     ${cache_color}${cache_ratio}%${NC}"
    else
        echo -e "  Cache Hit Ratio:     ${DIM}no data yet${NC}"
    fi

    # SSL status
    local ssl_conns=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
        "SELECT count(*) FROM pg_stat_ssl WHERE ssl = true;" 2>/dev/null)
    local total_conns=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
        "SELECT count(*) FROM pg_stat_ssl;" 2>/dev/null)
    echo -e "  SSL Connections:     ${ssl_conns:-0} / ${total_conns:-0}"

    echo ""

    # Disk usage breakdown
    echo -e "  ${BOLD}Storage${NC}"
    divider

    local data_dir_size=$(du -sh "$PGHOST_DATA/$name" 2>/dev/null | cut -f1)
    local backup_size=$(du -sh "$PGHOST_BACKUPS/$name" 2>/dev/null | cut -f1)
    echo -e "  Data Directory:      ${data_dir_size:-0}"
    echo -e "  Backups:             ${backup_size:-0}"

    # Top 5 largest tables
    local top_tables=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
        "SELECT schemaname || '.' || tablename || '|' || pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename))
         FROM pg_tables
         WHERE schemaname = 'public'
         ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC
         LIMIT 5;" 2>/dev/null)

    if [ -n "$top_tables" ]; then
        echo ""
        echo -e "  ${BOLD}Top Tables by Size${NC}"
        divider
        while IFS='|' read -r tname tsize; do
            [ -z "$tname" ] && continue
            printf "  %-30s %s\n" "$tname" "$tsize"
        done <<< "$top_tables"
    fi

    # Domain info
    if [ -n "$DOMAIN" ]; then
        echo ""
        echo -e "  ${BOLD}Domain${NC}"
        divider
        echo -e "  Domain:              $DOMAIN"
        echo -e "  SSL:                 ${GREEN}Let's Encrypt${NC}"
    fi

    echo ""
}

_metrics_all() {
    require_root
    require_docker

    local instances=("$PGHOST_INSTANCES"/*.env)

    if [ ! -f "${instances[0]}" ]; then
        header "Metrics"
        info "No instances found."
        echo ""
        return
    fi

    header "Instance Metrics Overview"

    printf "  ${BOLD}%-12s %-8s %-10s %-10s %-8s %-8s %-12s${NC}\n" \
        "NAME" "STATUS" "CPU" "MEMORY" "CONNS" "DB SIZE" "DISK"
    divider

    for env_file in "$PGHOST_INSTANCES"/*.env; do
        [ -f "$env_file" ] || continue
        source "$env_file"

        local container=$(container_name "$INSTANCE_NAME")
        local status="stopped"
        local cpu="-" mem="-" conns="-" db_size="-" disk="-"

        if docker ps --format '{{.Names}}' | grep -q "^${container}$" 2>/dev/null; then
            status="${GREEN}running${NC}"

            local stats=$(docker stats "$container" --no-stream --format '{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null)
            cpu=$(echo "$stats" | cut -f1)
            mem=$(echo "$stats" | cut -f2 | cut -d'/' -f1 | xargs)

            conns=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
                "SELECT count(*) FROM pg_stat_activity WHERE datname = '$DB_NAME';" 2>/dev/null | xargs)
            db_size=$(docker exec "$container" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
                "SELECT pg_size_pretty(pg_database_size('$DB_NAME'));" 2>/dev/null | xargs)
            disk=$(du -sh "$PGHOST_DATA/$INSTANCE_NAME" 2>/dev/null | cut -f1)
        else
            status="${RED}stopped${NC}"
        fi

        printf "  %-12s %-20b %-10s %-10s %-8s %-8s %-12s\n" \
            "$INSTANCE_NAME" "$status" "$cpu" "$mem" "$conns" "$db_size" "$disk"
    done

    echo ""
    info "Run ${BOLD}pghost metrics <name>${NC} for detailed stats on a specific instance."
    echo ""
}
