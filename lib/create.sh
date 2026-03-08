#!/usr/bin/env bash
# pghost create - spin up a new PostgreSQL instance

cmd_create() {
    require_root
    require_docker
    ensure_dirs
    ensure_network

    local name=""
    local db_name=""
    local db_user=""
    local db_password=""
    local port=""
    local max_connections=100
    local memory_limit="512m"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name|-n)       name="$2"; shift 2 ;;
            --database|-d)   db_name="$2"; shift 2 ;;
            --user|-u)       db_user="$2"; shift 2 ;;
            --password|-p)   db_password="$2"; shift 2 ;;
            --port)          port="$2"; shift 2 ;;
            --max-conn)      max_connections="$2"; shift 2 ;;
            --memory)        memory_limit="$2"; shift 2 ;;
            *)
                if [ -z "$name" ]; then
                    name="$1"
                fi
                shift
                ;;
        esac
    done

    # Interactive mode if no name given
    if [ -z "$name" ]; then
        header "Create New PostgreSQL Instance"
        echo -n "  Instance name: "
        read -r name
    fi

    # Validate name
    if [[ ! "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        error "Invalid name. Use letters, numbers, hyphens, underscores. Must start with a letter."
        exit 1
    fi

    if instance_exists "$name"; then
        error "Instance '$name' already exists."
        exit 1
    fi

    # Defaults
    db_name="${db_name:-${name}_db}"
    db_user="${db_user:-${name}_user}"
    db_password="${db_password:-$(gen_password)}"
    port="${port:-$(next_available_port)}"

    local container=$(container_name "$name")
    local server_ip=$(get_server_ip)

    header "Creating Instance: $name"

    step "Container: $container"
    step "Port: $port"
    step "Database: $db_name"
    step "User: $db_user"
    echo ""

    # Create data directory
    mkdir -p "$PGHOST_DATA/$name"

    # Generate SSL certificates for this instance
    step "Generating SSL certificates..."
    mkdir -p "$PGHOST_CERTS/$name"
    if ! openssl req -new -x509 -days 3650 -nodes \
        -subj "/CN=pghost-$name" \
        -keyout "$PGHOST_CERTS/$name/server.key" \
        -out "$PGHOST_CERTS/$name/server.crt" \
        2>/dev/null; then
        error "Failed to generate SSL certificates. Is openssl installed?"
        exit 1
    fi
    chmod 600 "$PGHOST_CERTS/$name/server.key"
    chmod 644 "$PGHOST_CERTS/$name/server.crt"
    # PostgreSQL requires key owned by uid 70 (postgres in alpine)
    chown 70:70 "$PGHOST_CERTS/$name/server.key" "$PGHOST_CERTS/$name/server.crt"
    success "SSL certificates generated"

    # Create custom pg_hba.conf (strict auth)
    cat > "$PGHOST_DATA/$name/pg_hba.conf" << 'PGHBA'
# pghost: strict authentication
local   all             all                                     scram-sha-256
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
hostssl all             all             0.0.0.0/0               scram-sha-256
hostssl all             all             ::/0                    scram-sha-256
# Reject non-SSL remote connections
hostnossl all           all             0.0.0.0/0               reject
hostnossl all           all             ::/0                    reject
PGHBA
    chown 70:70 "$PGHOST_DATA/$name/pg_hba.conf"

    # Auto-tune memory based on container limit
    local mem_mb
    mem_mb=$(echo "$memory_limit" | sed 's/[Mm]$//' | sed 's/[Gg]$/*1024/' | bc 2>/dev/null || echo 512)
    local shared_buffers work_mem maintenance_work_mem effective_cache_size
    # shared_buffers = 25% of RAM, work_mem = RAM / (max_connections * 2), effective_cache = 75%
    shared_buffers="${mem_mb}MB"
    shared_buffers=$(echo "scale=0; $mem_mb / 4" | bc)MB
    work_mem=$(echo "scale=0; $mem_mb / ($max_connections * 2)" | bc)
    [ "$work_mem" -lt 4 ] && work_mem=4
    work_mem="${work_mem}MB"
    maintenance_work_mem=$(echo "scale=0; $mem_mb / 8" | bc)
    [ "$maintenance_work_mem" -lt 64 ] && maintenance_work_mem=64
    maintenance_work_mem="${maintenance_work_mem}MB"
    effective_cache_size=$(echo "scale=0; $mem_mb * 3 / 4" | bc)MB

    # Create custom postgresql.conf additions
    cat > "$PGHOST_DATA/$name/extra.conf" << PGCONF
# pghost security & performance (auto-tuned for ${memory_limit} RAM)
ssl = on
ssl_cert_file = '/var/lib/postgresql/certs/server.crt'
ssl_key_file = '/var/lib/postgresql/certs/server.key'
ssl_min_protocol_version = 'TLSv1.2'
ssl_ciphers = 'HIGH:MEDIUM:+3DES:!aNULL'

password_encryption = scram-sha-256
max_connections = $max_connections
shared_buffers = $shared_buffers
work_mem = $work_mem
maintenance_work_mem = $maintenance_work_mem
effective_cache_size = $effective_cache_size

# Autovacuum (always on)
autovacuum = on
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02
autovacuum_vacuum_cost_delay = 2ms

# WAL & checkpoints
wal_buffers = 16MB
checkpoint_completion_target = 0.9
random_page_cost = 1.1

log_connections = on
log_disconnections = on
log_statement = 'ddl'
log_min_duration_statement = 1000
log_line_prefix = '%m [%p] %u@%d '

hba_file = '/var/lib/postgresql/data/pg_hba.conf'
PGCONF

    # Remove any stale container from a previous failed attempt
    if docker ps -a --format '{{.Names}}' | grep -q "^${container}$" 2>/dev/null; then
        step "Removing stale container from previous attempt..."
        docker rm -f "$container" > /dev/null 2>&1 || true
    fi

    step "Starting PostgreSQL container..."
    local docker_output
    if ! docker_output=$(docker run -d \
        --name "$container" \
        --network "$DOCKER_NETWORK" \
        --restart unless-stopped \
        --memory "$memory_limit" \
        --cpus 1 \
        -e POSTGRES_DB="$db_name" \
        -e POSTGRES_USER="$db_user" \
        -e POSTGRES_PASSWORD="$db_password" \
        -e POSTGRES_INITDB_ARGS="--auth-host=scram-sha-256 --auth-local=scram-sha-256" \
        -p "${port}:5432" \
        -v "$PGHOST_DATA/$name/pgdata:/var/lib/postgresql/data" \
        -v "$PGHOST_CERTS/$name:/var/lib/postgresql/certs:ro" \
        "$PG_IMAGE" \
        postgres -c "config_file=/var/lib/postgresql/data/postgresql.conf" \
        2>&1); then
        error "Failed to start container:"
        echo "  $docker_output"
        exit 1
    fi

    # Wait for custom config - on first run pg_hba.conf gets overwritten by initdb
    sleep 2

    # Copy config after initdb completes
    docker cp "$PGHOST_DATA/$name/pg_hba.conf" "$container:/var/lib/postgresql/data/pg_hba.conf" 2>/dev/null || true
    docker cp "$PGHOST_DATA/$name/extra.conf" "$container:/var/lib/postgresql/data/conf.d/" 2>/dev/null || true

    # Wait for PostgreSQL to be ready
    step "Waiting for PostgreSQL..."
    local retries=0
    while [ $retries -lt 30 ]; do
        if docker exec "$container" pg_isready -U "$db_user" > /dev/null 2>&1; then
            break
        fi
        retries=$((retries + 1))
        sleep 1
    done

    if [ $retries -eq 30 ]; then
        error "PostgreSQL failed to start. Check: docker logs $container"
        exit 1
    fi

    success "PostgreSQL is running"

    # Apply SSL and strict config
    step "Applying security configuration..."
    local sql_output
    if ! sql_output=$(docker exec -e PGPASSWORD="$db_password" "$container" psql -U "$db_user" -d "$db_name" -c "
        ALTER SYSTEM SET ssl = 'on';
        ALTER SYSTEM SET ssl_cert_file = '/var/lib/postgresql/certs/server.crt';
        ALTER SYSTEM SET ssl_key_file = '/var/lib/postgresql/certs/server.key';
        ALTER SYSTEM SET ssl_min_protocol_version = 'TLSv1.2';
        ALTER SYSTEM SET password_encryption = 'scram-sha-256';
        ALTER SYSTEM SET log_connections = 'on';
        ALTER SYSTEM SET log_disconnections = 'on';
        ALTER SYSTEM SET max_connections = '$max_connections';
        SELECT pg_reload_conf();
    " 2>&1); then
        warn "Some security settings could not be applied: $sql_output"
    else
        success "Security configuration applied"
    fi

    # Restrict default user permissions
    step "Hardening permissions..."
    if ! sql_output=$(docker exec -e PGPASSWORD="$db_password" "$container" psql -U "$db_user" -d "$db_name" -c "
        REVOKE CREATE ON SCHEMA public FROM PUBLIC;
        GRANT ALL ON SCHEMA public TO $db_user;
    " 2>&1); then
        warn "Could not harden permissions: $sql_output"
    else
        success "Permissions hardened"
    fi

    # Open port in firewall so the instance is reachable from anywhere by default
    if command -v ufw &>/dev/null; then
        ufw allow "$port"/tcp comment "pghost:$name" > /dev/null 2>&1 || true
    fi
    if command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT \
            -m comment --comment "pghost:$name:open" 2>/dev/null || true
    fi

    # Build connection URLs
    local url_ssl="postgresql://${db_user}:${db_password}@${server_ip}:${port}/${db_name}?sslmode=require"
    local url_domain=""

    # Save instance config
    cat > "$PGHOST_INSTANCES/$name.env" << EOF
INSTANCE_NAME="$name"
CONTAINER_NAME="$container"
DB_NAME="$db_name"
DB_USER="$db_user"
DB_PASSWORD="$db_password"
DB_PORT="$port"
SERVER_IP="$server_ip"
MEMORY_LIMIT="$memory_limit"
MAX_CONNECTIONS="$max_connections"
CREATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
DOMAIN=""
DATABASE_URL="$url_ssl"
EOF
    chmod 600 "$PGHOST_INSTANCES/$name.env"

    # Save backup of credentials
    mkdir -p "$PGHOST_BACKUPS/$name"

    echo ""
    divider
    echo ""
    success "${BOLD}Instance '$name' created successfully!${NC}"
    echo ""
    divider
    echo ""
    echo -e "  ${BOLD}DATABASE_URL:${NC}"
    echo ""
    echo -e "  ${GREEN}$url_ssl${NC}"
    echo ""
    divider
    echo ""
    echo -e "  ${DIM}Host:${NC}     $server_ip"
    echo -e "  ${DIM}Port:${NC}     $port"
    echo -e "  ${DIM}Database:${NC} $db_name"
    echo -e "  ${DIM}User:${NC}     $db_user"
    echo -e "  ${DIM}Password:${NC} $db_password"
    echo -e "  ${DIM}SSL:${NC}      ${GREEN}enabled (TLS 1.2+)${NC}"
    echo ""
    divider
    echo ""
    echo -e "  ${DIM}For your .env file:${NC}"
    echo ""
    echo -e "  DATABASE_URL=\"$url_ssl\""
    echo ""
    info "Run ${BOLD}pghost domain $name yourdomain.com${NC} to add a domain."
    info "Run ${BOLD}pghost metrics $name${NC} to see usage stats."
    info "Run ${BOLD}pghost firewall $name${NC} to restrict access."
    echo ""
    echo -e "  ${BOLD}Performance Tips:${NC}"
    divider
    dim "  Memory auto-tuned: shared_buffers=$shared_buffers, work_mem=$work_mem"
    dim "  Autovacuum:        enabled (scale factor 5%)"
    dim "  Slow query log:    queries >1s are logged"
    echo ""
    dim "  Add indexes for your most-queried columns:"
    dim "    CREATE INDEX idx_table_col ON table(column);"
    dim "  Use BIGSERIAL or UUID for primary keys."
    dim "  Run pghost maintain $name weekly for VACUUM ANALYZE."
    dim "  Run pghost bouncer $name if you have many app connections."
    echo ""
}
