#!/usr/bin/env bash
# pghost domain - configure domains with DNS instructions and SSL via Let's Encrypt

cmd_domain() {
    require_root
    require_docker

    local name="$1"
    local domain="$2"
    local action="${3:-add}"

    if [ -z "$name" ] || [ -z "$domain" ]; then
        error "Usage: pghost domain <instance-name> <domain.com>"
        echo ""
        info "Examples:"
        dim "  pghost domain myapp db.myapp.com"
        dim "  pghost domain myapp db.myapp.com remove"
        echo ""
        exit 1
    fi

    load_instance "$name"

    if [ "$action" = "remove" ]; then
        _domain_remove "$name" "$domain"
        return
    fi

    local server_ip=$(get_server_ip)

    header "Domain Setup: $domain → $name"

    # Step 1: Show DNS instructions
    echo -e "  ${BOLD}Step 1: Add these DNS records${NC}"
    echo ""
    echo -e "  Go to your domain's DNS settings and add:"
    echo ""
    echo -e "  ┌──────────┬──────────────────────┬──────────────────┬───────┐"
    echo -e "  │ ${BOLD}Type${NC}     │ ${BOLD}Name${NC}                 │ ${BOLD}Value${NC}            │ ${BOLD}TTL${NC}   │"
    echo -e "  ├──────────┼──────────────────────┼──────────────────┼───────┤"
    printf   "  │ %-8s │ %-20s │ %-16s │ %-5s │\n" "A" "$domain" "$server_ip" "300"
    echo -e "  └──────────┴──────────────────────┴──────────────────┴───────┘"
    echo ""

    # If it's a subdomain, show the alternative CNAME approach
    local subdomain=$(echo "$domain" | cut -d. -f1)
    local parent=$(echo "$domain" | cut -d. -f2-)
    if [ "$subdomain" != "$domain" ] && echo "$parent" | grep -q '\.'; then
        dim "  Alternative (if using a subdomain):"
        echo ""
        echo -e "  ┌──────────┬──────────────────────┬──────────────────┬───────┐"
        echo -e "  │ ${BOLD}Type${NC}     │ ${BOLD}Name${NC}                 │ ${BOLD}Value${NC}            │ ${BOLD}TTL${NC}   │"
        echo -e "  ├──────────┼──────────────────────┼──────────────────┼───────┤"
        printf   "  │ %-8s │ %-20s │ %-16s │ %-5s │\n" "A" "$subdomain" "$server_ip" "300"
        echo -e "  └──────────┴──────────────────────┴──────────────────┴───────┘"
        echo ""
    fi

    divider
    echo ""

    # Step 2: Verify DNS
    echo -e "  ${BOLD}Step 2: Verifying DNS propagation...${NC}"
    echo ""

    local dns_ok=false
    local resolved_ip=""

    # Check DNS resolution
    if command -v dig &>/dev/null; then
        resolved_ip=$(dig +short "$domain" A 2>/dev/null | head -1)
    elif command -v nslookup &>/dev/null; then
        resolved_ip=$(nslookup "$domain" 2>/dev/null | awk '/^Address: / { print $2 }' | tail -1)
    elif command -v host &>/dev/null; then
        resolved_ip=$(host "$domain" 2>/dev/null | awk '/has address/ { print $4 }' | head -1)
    fi

    if [ "$resolved_ip" = "$server_ip" ]; then
        success "DNS is pointing to this server ($server_ip)"
        dns_ok=true
    elif [ -n "$resolved_ip" ]; then
        warn "DNS points to $resolved_ip (expected $server_ip)"
        echo ""
        info "If you just added the DNS record, it may take a few minutes to propagate."
        echo ""
        echo -n "  Continue anyway? [y/N]: "
        read -r reply
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            echo ""
            info "Run this command again after DNS propagates:"
            dim "  pghost domain $name $domain"
            echo ""
            return
        fi
    else
        warn "Could not resolve $domain"
        echo ""
        info "Add the DNS record above, wait for propagation, then run:"
        dim "  pghost domain $name $domain"
        echo ""
        echo -n "  Continue without verification? [y/N]: "
        read -r reply
        if [[ ! "$reply" =~ ^[Yy]$ ]]; then
            echo ""
            return
        fi
    fi

    echo ""
    divider
    echo ""

    # Step 3: Install certbot and get SSL certificate
    echo -e "  ${BOLD}Step 3: Setting up SSL certificate (Let's Encrypt)${NC}"
    echo ""

    # Install nginx if not present
    if ! command -v nginx &>/dev/null; then
        step "Installing nginx..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq nginx certbot python3-certbot-nginx > /dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y -q nginx certbot python3-certbot-nginx > /dev/null 2>&1
        fi
        systemctl enable nginx > /dev/null 2>&1
        systemctl start nginx > /dev/null 2>&1
        success "nginx installed"
    fi

    # Install certbot if not present
    if ! command -v certbot &>/dev/null; then
        step "Installing certbot..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq certbot python3-certbot-nginx > /dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y -q certbot python3-certbot-nginx > /dev/null 2>&1
        fi
        success "certbot installed"
    fi

    # Create nginx stream config for PostgreSQL SSL passthrough
    # We use nginx TCP stream proxy for database connections
    step "Configuring nginx TCP proxy..."

    # Ensure nginx has stream module config directory
    mkdir -p /etc/nginx/stream.d

    # Add stream include to main nginx.conf if not present
    if ! grep -q "stream.d" /etc/nginx/nginx.conf 2>/dev/null; then
        echo "" >> /etc/nginx/nginx.conf
        echo "stream {" >> /etc/nginx/nginx.conf
        echo "    include /etc/nginx/stream.d/*.conf;" >> /etc/nginx/nginx.conf
        echo "}" >> /etc/nginx/nginx.conf
    fi

    # Create stream proxy config for this instance
    cat > "/etc/nginx/stream.d/pghost-$name.conf" << NGINXSTREAM
# pghost: $name -> $domain
upstream pghost_${name} {
    server 127.0.0.1:${DB_PORT};
}

server {
    listen 5433 ssl;
    proxy_pass pghost_${name};

    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    proxy_timeout 600s;
    proxy_connect_timeout 10s;
}
NGINXSTREAM

    # Create basic HTTP config for certbot validation
    mkdir -p "$PGHOST_NGINX_DIR"
    cat > "$PGHOST_NGINX_DIR/pghost-$name.conf" << NGINXHTTP
server {
    listen 80;
    server_name $domain;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
NGINXHTTP

    nginx -t > /dev/null 2>&1 && nginx -s reload > /dev/null 2>&1
    success "nginx configured"

    # Get SSL certificate
    step "Obtaining SSL certificate from Let's Encrypt..."
    if certbot certonly --nginx -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email --quiet 2>/dev/null; then
        success "SSL certificate obtained"

        # Copy Let's Encrypt certs for PostgreSQL too
        cp "/etc/letsencrypt/live/$domain/fullchain.pem" "$PGHOST_CERTS/$name/server.crt"
        cp "/etc/letsencrypt/live/$domain/privkey.pem" "$PGHOST_CERTS/$name/server.key"
        chmod 600 "$PGHOST_CERTS/$name/server.key"
        chown 70:70 "$PGHOST_CERTS/$name/server.key" "$PGHOST_CERTS/$name/server.crt"

        # Restart PostgreSQL to use new certs
        docker restart "$(container_name "$name")" > /dev/null 2>&1

        # Reload nginx with stream SSL config
        nginx -t > /dev/null 2>&1 && nginx -s reload > /dev/null 2>&1

        # Set up auto-renewal hook
        cat > "/etc/letsencrypt/renewal-hooks/deploy/pghost-$name.sh" << HOOK
#!/bin/bash
cp "/etc/letsencrypt/live/$domain/fullchain.pem" "$PGHOST_CERTS/$name/server.crt"
cp "/etc/letsencrypt/live/$domain/privkey.pem" "$PGHOST_CERTS/$name/server.key"
chmod 600 "$PGHOST_CERTS/$name/server.key"
chown 70:70 "$PGHOST_CERTS/$name/server.key" "$PGHOST_CERTS/$name/server.crt"
docker restart $(container_name "$name")
nginx -s reload
HOOK
        chmod +x "/etc/letsencrypt/renewal-hooks/deploy/pghost-$name.sh"
        success "Auto-renewal configured"
    else
        warn "Could not obtain Let's Encrypt certificate."
        info "Using self-signed certificate instead."
        info "Make sure port 80 is open and DNS is pointing to this server."
    fi

    echo ""

    # Update instance config
    local domain_url="postgresql://${DB_USER}:${DB_PASSWORD}@${domain}:${DB_PORT}/${DB_NAME}?sslmode=require"
    sed -i "s|^DOMAIN=.*|DOMAIN=\"$domain\"|" "$PGHOST_INSTANCES/$name.env"

    # Add domain URL line if not present, otherwise update it
    if grep -q "^DOMAIN_URL=" "$PGHOST_INSTANCES/$name.env"; then
        sed -i "s|^DOMAIN_URL=.*|DOMAIN_URL=\"$domain_url\"|" "$PGHOST_INSTANCES/$name.env"
    else
        echo "DOMAIN_URL=\"$domain_url\"" >> "$PGHOST_INSTANCES/$name.env"
    fi

    divider
    echo ""
    success "${BOLD}Domain configured!${NC}"
    echo ""
    divider
    echo ""
    echo -e "  ${BOLD}DATABASE_URL (via domain):${NC}"
    echo ""
    echo -e "  ${GREEN}$domain_url${NC}"
    echo ""
    echo -e "  ${BOLD}DATABASE_URL (via IP):${NC}"
    echo ""
    echo -e "  ${GREEN}$DATABASE_URL${NC}"
    echo ""
    divider
    echo ""
    echo -e "  ${DIM}SSL:${NC}        ${GREEN}Let's Encrypt (auto-renews)${NC}"
    echo -e "  ${DIM}Domain:${NC}     $domain"
    echo -e "  ${DIM}Host:${NC}       $server_ip"
    echo -e "  ${DIM}Port:${NC}       $DB_PORT"
    echo ""
    info "For your .env:"
    echo ""
    echo "  DATABASE_URL=\"$domain_url\""
    echo ""
}

_domain_remove() {
    local name="$1"
    local domain="$2"

    step "Removing domain '$domain' from instance '$name'..."

    rm -f "$PGHOST_NGINX_DIR/pghost-$name.conf"
    rm -f "/etc/nginx/stream.d/pghost-$name.conf"
    nginx -t > /dev/null 2>&1 && nginx -s reload > /dev/null 2>&1

    rm -f "/etc/letsencrypt/renewal-hooks/deploy/pghost-$name.sh"

    sed -i "s|^DOMAIN=.*|DOMAIN=\"\"|" "$PGHOST_INSTANCES/$name.env"
    sed -i "/^DOMAIN_URL=/d" "$PGHOST_INSTANCES/$name.env"

    success "Domain removed from instance '$name'."
    echo ""
}
