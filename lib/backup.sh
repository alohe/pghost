#!/usr/bin/env bash
# pghost backup - backup and restore instances

cmd_backup() {
    require_root
    require_docker

    local name="$1"
    local output="$2"

    if [ -z "$name" ]; then
        error "Usage: pghost backup <instance-name> [output-file]"
        echo ""
        info "Examples:"
        dim "  pghost backup myapp"
        dim "  pghost backup myapp /path/to/backup.sql.gz"
        echo ""
        exit 1
    fi

    load_instance "$name"

    local container=$(container_name "$name")
    local timestamp=$(date +%Y%m%d_%H%M%S)

    if [ -z "$output" ]; then
        mkdir -p "$PGHOST_BACKUPS/$name"
        output="$PGHOST_BACKUPS/$name/${name}_${timestamp}.sql.gz"
    fi

    step "Backing up '$name'..."

    set +o pipefail
    docker exec "$container" pg_dump -U "$DB_USER" -d "$DB_NAME" --format=plain --no-owner --no-privileges 2>/dev/null \
        | gzip > "$output"
    local backup_exit=$?
    set -o pipefail

    if [ $backup_exit -eq 0 ] && [ -s "$output" ]; then
        local size=$(du -h "$output" | cut -f1)
        success "Backup saved: $output ($size)"
    else
        error "Backup failed. Check: docker logs $container"
        rm -f "$output"
        exit 1
    fi

    # Cleanup old backups (keep last 10)
    if [ -d "$PGHOST_BACKUPS/$name" ]; then
        local count=$(ls -1 "$PGHOST_BACKUPS/$name"/*.sql.gz 2>/dev/null | wc -l)
        if [ "$count" -gt 10 ]; then
            ls -1t "$PGHOST_BACKUPS/$name"/*.sql.gz | tail -n +11 | xargs rm -f
            dim "  Cleaned up old backups (keeping last 10)"
        fi
    fi

    echo ""
}

cmd_restore() {
    require_root
    require_docker

    local name="$1"
    local input="$2"

    if [ -z "$name" ] || [ -z "$input" ]; then
        error "Usage: pghost restore <instance-name> <backup-file>"
        echo ""
        info "Examples:"
        dim "  pghost restore myapp backup.sql.gz"
        dim "  pghost restore myapp /opt/pghost/backups/myapp/myapp_20240101.sql.gz"
        echo ""

        # List available backups
        if [ -n "$name" ] && [ -d "$PGHOST_BACKUPS/$name" ]; then
            info "Available backups for '$name':"
            ls -lh "$PGHOST_BACKUPS/$name"/*.sql.gz 2>/dev/null | while read -r line; do
                dim "  $line"
            done
            echo ""
        fi

        exit 1
    fi

    load_instance "$name"

    if [ ! -f "$input" ]; then
        error "File not found: $input"
        exit 1
    fi

    local container=$(container_name "$name")

    echo ""
    warn "This will ${RED}replace all data${NC} in instance '$name' with the backup."
    echo -n "  Continue? [y/N]: "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Cancelled."
        echo ""
        return
    fi

    # Create a backup before restoring
    step "Creating safety backup..."
    local safety_backup="$PGHOST_BACKUPS/$name/${name}_pre_restore_$(date +%Y%m%d_%H%M%S).sql.gz"
    mkdir -p "$PGHOST_BACKUPS/$name"
    set +o pipefail
    docker exec "$container" pg_dump -U "$DB_USER" -d "$DB_NAME" --format=plain 2>/dev/null | gzip > "$safety_backup" || true
    set -o pipefail
    dim "  Safety backup: $safety_backup"

    step "Restoring '$name' from $input..."

    # Drop and recreate database
    if ! docker exec "$container" psql -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\";" > /dev/null 2>&1; then
        warn "Could not drop existing database (it may have active connections)"
    fi
    if ! docker exec "$container" psql -U "$DB_USER" -d postgres -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";" > /dev/null 2>&1; then
        error "Could not create database. Restore aborted."
        info "Safety backup available at: $safety_backup"
        exit 1
    fi

    # Restore
    local restore_exit=0
    set +o pipefail
    if [[ "$input" == *.gz ]]; then
        gunzip -c "$input" | docker exec -i "$container" psql -U "$DB_USER" -d "$DB_NAME" > /dev/null 2>&1
        restore_exit=$?
    else
        docker exec -i "$container" psql -U "$DB_USER" -d "$DB_NAME" < "$input" > /dev/null 2>&1
        restore_exit=$?
    fi
    set -o pipefail

    if [ $restore_exit -eq 0 ]; then
        success "Restore complete!"
    else
        error "Restore encountered errors. Check: docker logs $container"
        info "Safety backup available at: $safety_backup"
    fi

    echo ""
}

cmd_backups() {
    require_root

    local name="$1"

    if [ -z "$name" ]; then
        # List all backups
        header "All Backups"

        for dir in "$PGHOST_BACKUPS"/*/; do
            [ -d "$dir" ] || continue
            local iname=$(basename "$dir")
            local count=$(ls -1 "$dir"*.sql.gz 2>/dev/null | wc -l)
            local total_size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            echo -e "  ${BOLD}$iname${NC}  ($count backups, $total_size)"

            ls -1t "$dir"*.sql.gz 2>/dev/null | head -3 | while read -r f; do
                local fsize=$(du -h "$f" | cut -f1)
                local fname=$(basename "$f")
                dim "    $fname  ($fsize)"
            done
            echo ""
        done
        return
    fi

    load_instance "$name"

    header "Backups: $name"

    if [ ! -d "$PGHOST_BACKUPS/$name" ] || [ -z "$(ls -A "$PGHOST_BACKUPS/$name" 2>/dev/null)" ]; then
        info "No backups found for '$name'."
        info "Create one with: ${BOLD}pghost backup $name${NC}"
        echo ""
        return
    fi

    printf "  ${BOLD}%-45s %-10s %-20s${NC}\n" "FILE" "SIZE" "DATE"
    divider

    ls -1t "$PGHOST_BACKUPS/$name"/*.sql.gz 2>/dev/null | while read -r f; do
        local fname=$(basename "$f")
        local fsize=$(du -h "$f" | cut -f1)
        local fdate=$(stat -c %y "$f" 2>/dev/null || stat -f %Sm "$f" 2>/dev/null)
        printf "  %-45s %-10s %-20s\n" "$fname" "$fsize" "${fdate:0:19}"
    done

    echo ""
}

cmd_cron() {
    require_root

    local name="$1"
    local schedule="${2:-daily}"

    if [ -z "$name" ]; then
        error "Usage: pghost cron <instance-name> [daily|hourly|weekly]"
        exit 1
    fi

    load_instance "$name"

    local cron_line=""
    case "$schedule" in
        hourly)  cron_line="0 * * * *" ;;
        daily)   cron_line="0 2 * * *" ;;
        weekly)  cron_line="0 2 * * 0" ;;
        *)
            error "Invalid schedule: $schedule. Use: daily, hourly, weekly"
            exit 1
            ;;
    esac

    local cron_cmd="$cron_line $(which pghost || echo /usr/local/bin/pghost) backup $name"

    # Add to crontab if not already there
    ( (crontab -l 2>/dev/null || true) | { grep -v "pghost backup $name" || true; }; echo "$cron_cmd") | crontab -

    success "Automated $schedule backups configured for '$name'"
    dim "  Schedule: $cron_line"
    dim "  Command: pghost backup $name"
    echo ""
}
