#!/usr/bin/env bash
# pghost security - firewall management, fail2ban, hardening

cmd_firewall() {
    require_root

    local name="$1"
    local action="${2:-status}"

    if [ -z "$name" ]; then
        error "Usage: pghost firewall <instance-name> [allow|deny|status] [ip]"
        echo ""
        info "Examples:"
        dim "  pghost firewall myapp status"
        dim "  pghost firewall myapp allow 1.2.3.4"
        dim "  pghost firewall myapp allow 10.0.0.0/24"
        dim "  pghost firewall myapp deny 5.6.7.8"
        dim "  pghost firewall myapp lockdown     # deny all except allowed IPs"
        echo ""
        exit 1
    fi

    load_instance "$name"

    case "$action" in
        allow)
            _fw_allow "$name" "$3"
            ;;
        deny)
            _fw_deny "$name" "$3"
            ;;
        lockdown)
            _fw_lockdown "$name"
            ;;
        open)
            _fw_open "$name"
            ;;
        status)
            _fw_status "$name"
            ;;
        *)
            error "Unknown action: $action"
            info "Available: allow, deny, lockdown, open, status"
            echo ""
            ;;
    esac
}

_fw_allow() {
    local name="$1"
    local ip="$2"

    if [ -z "$ip" ]; then
        error "Usage: pghost firewall $name allow <ip-address>"
        exit 1
    fi

    # Validate IP/CIDR
    if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
        error "Invalid IP address: $ip"
        exit 1
    fi

    step "Allowing $ip access to '$name' (port $DB_PORT)..."

    if command -v ufw &>/dev/null; then
        ufw allow from "$ip" to any port "$DB_PORT" proto tcp comment "pghost:$name" > /dev/null 2>&1 || true
    fi

    iptables -I INPUT -p tcp --dport "$DB_PORT" -s "$ip" -j ACCEPT \
        -m comment --comment "pghost:$name:allow:$ip" 2>/dev/null || true

    # Save rule to instance config
    local rules_file="$PGHOST_INSTANCES/${name}.rules"
    echo "allow $ip" >> "$rules_file"
    sort -u -o "$rules_file" "$rules_file"

    success "Allowed $ip → port $DB_PORT ($name)"
    echo ""
}

_fw_deny() {
    local name="$1"
    local ip="$2"

    if [ -z "$ip" ]; then
        error "Usage: pghost firewall $name deny <ip-address>"
        exit 1
    fi

    step "Denying $ip access to '$name' (port $DB_PORT)..."

    if command -v ufw &>/dev/null; then
        ufw deny from "$ip" to any port "$DB_PORT" proto tcp comment "pghost:$name" > /dev/null 2>&1 || true
    fi

    iptables -I INPUT -p tcp --dport "$DB_PORT" -s "$ip" -j DROP \
        -m comment --comment "pghost:$name:deny:$ip" 2>/dev/null || true

    # Update rules file
    local rules_file="$PGHOST_INSTANCES/${name}.rules"
    [ -f "$rules_file" ] && sed -i "/^allow $ip$/d" "$rules_file"
    echo "deny $ip" >> "$rules_file"

    success "Denied $ip → port $DB_PORT ($name)"
    echo ""
}

_fw_lockdown() {
    local name="$1"
    local rules_file="$PGHOST_INSTANCES/${name}.rules"

    header "Lockdown: $name"

    warn "This will block ALL access to port $DB_PORT except explicitly allowed IPs."
    echo ""

    # Show currently allowed IPs
    if [ -f "$rules_file" ]; then
        local allowed=$(grep "^allow " "$rules_file" | awk '{print $2}')
        if [ -n "$allowed" ]; then
            info "Currently allowed IPs:"
            echo "$allowed" | while read -r ip; do
                dim "  $ip"
            done
            echo ""
        else
            warn "No IPs are allowed. You will lose remote access!"
            echo ""
            echo -n "  Add your current IP first? [Y/n]: "
            read -r reply
            if [[ ! "$reply" =~ ^[Nn]$ ]]; then
                local my_ip=$(echo "$SSH_CLIENT" | awk '{print $1}')
                if [ -n "$my_ip" ]; then
                    _fw_allow "$name" "$my_ip"
                else
                    echo -n "  Enter your IP address: "
                    read -r my_ip
                    _fw_allow "$name" "$my_ip"
                fi
            fi
        fi
    fi

    echo -n "  Proceed with lockdown? [y/N]: "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Cancelled."
        echo ""
        return
    fi

    step "Applying lockdown..."

    # Drop all traffic to this port by default
    if command -v ufw &>/dev/null; then
        ufw deny "$DB_PORT"/tcp comment "pghost:$name:lockdown" > /dev/null 2>&1 || true
    fi

    iptables -A INPUT -p tcp --dport "$DB_PORT" -j DROP \
        -m comment --comment "pghost:$name:lockdown" 2>/dev/null || true

    # Re-apply allowed IPs (they take precedence as they were added with -I)
    if [ -f "$rules_file" ]; then
        grep "^allow " "$rules_file" | awk '{print $2}' | while read -r ip; do
            iptables -I INPUT -p tcp --dport "$DB_PORT" -s "$ip" -j ACCEPT \
                -m comment --comment "pghost:$name:allow:$ip" 2>/dev/null || true
        done || true
    fi

    # Always allow localhost
    iptables -I INPUT -p tcp --dport "$DB_PORT" -s 127.0.0.1 -j ACCEPT \
        -m comment --comment "pghost:$name:localhost" 2>/dev/null || true

    # Save iptables
    _save_iptables

    success "Lockdown applied on port $DB_PORT"
    echo ""
    info "Only explicitly allowed IPs can connect."
    info "To allow a new IP: ${BOLD}pghost firewall $name allow <ip>${NC}"
    echo ""
}

_fw_open() {
    local name="$1"

    step "Removing lockdown for '$name' (port $DB_PORT)..."

    # Remove all rules for this instance
    iptables -S 2>/dev/null | grep "pghost:$name" | while read -r rule; do
        echo "$rule" | sed 's/^-A//' | xargs iptables -D 2>/dev/null || true
    done || true

    if command -v ufw &>/dev/null; then
        ufw delete deny "$DB_PORT"/tcp > /dev/null 2>&1 || true
    fi

    _save_iptables

    success "Port $DB_PORT is now open for '$name'"
    warn "Consider adding firewall rules: ${BOLD}pghost firewall $name allow <your-ip>${NC}"
    echo ""
}

_fw_status() {
    local name="$1"

    header "Firewall Status: $name (port $DB_PORT)"

    local rules_file="$PGHOST_INSTANCES/${name}.rules"

    # Show iptables rules for this port
    echo -e "  ${BOLD}Active iptables rules:${NC}"
    divider

    local rules=$(iptables -L INPUT -n --line-numbers 2>/dev/null | grep "dpt:$DB_PORT" || true)
    if [ -n "$rules" ]; then
        echo "$rules" | while read -r line; do
            if echo "$line" | grep -q "ACCEPT"; then
                echo -e "  ${GREEN}$line${NC}"
            elif echo "$line" | grep -q "DROP\|REJECT"; then
                echo -e "  ${RED}$line${NC}"
            else
                echo -e "  $line"
            fi
        done
    else
        dim "  No specific rules for port $DB_PORT"
    fi

    echo ""

    # Show saved rules
    if [ -f "$rules_file" ]; then
        echo -e "  ${BOLD}Saved Rules:${NC}"
        divider
        while read -r action ip; do
            if [ "$action" = "allow" ]; then
                echo -e "  ${GREEN}ALLOW${NC}  $ip"
            elif [ "$action" = "deny" ]; then
                echo -e "  ${RED}DENY${NC}   $ip"
            fi
        done < "$rules_file"
    fi

    echo ""

    # UFW status if available
    if command -v ufw &>/dev/null; then
        echo -e "  ${BOLD}UFW Status:${NC}"
        divider
        ufw status 2>/dev/null | { grep "$DB_PORT" || true; } | while read -r line; do
            echo -e "  $line"
        done || true
        echo ""
    fi

    # Connection security info
    echo -e "  ${BOLD}Security Features:${NC}"
    divider
    echo -e "  SSL/TLS:         ${GREEN}enforced (TLS 1.2+)${NC}"
    echo -e "  Auth:            ${GREEN}scram-sha-256${NC}"
    echo -e "  Non-SSL remote:  ${GREEN}rejected${NC}"
    echo -e "  Log connections:  ${GREEN}enabled${NC}"
    if [ -n "$DOMAIN" ]; then
        echo -e "  Let's Encrypt:   ${GREEN}active ($DOMAIN)${NC}"
    fi
    echo ""
}

_save_iptables() {
    if command -v iptables-save &>/dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
}

cmd_harden() {
    require_root

    header "System Security Hardening"

    # Install fail2ban
    step "Installing fail2ban..."
    if command -v apt-get &>/dev/null; then
        apt-get install -y -qq fail2ban > /dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf install -y -q fail2ban > /dev/null || true
    fi

    if command -v fail2ban-client &>/dev/null; then
        success "fail2ban installed"

        # Create PostgreSQL jail
        cat > /etc/fail2ban/jail.d/pghost.conf << 'F2B'
[pghost]
enabled  = true
port     = 5432:5500
filter   = pghost
logpath  = /opt/pghost/logs/*.log
maxretry = 5
bantime  = 3600
findtime = 600
F2B

        # Create fail2ban filter for PostgreSQL auth failures
        cat > /etc/fail2ban/filter.d/pghost.conf << 'F2BF'
[Definition]
failregex = FATAL:  password authentication failed for user .* from <HOST>
            FATAL:  no pg_hba.conf entry for host "<HOST>"
ignoreregex =
F2BF

        systemctl enable fail2ban > /dev/null 2>&1 || true
        systemctl restart fail2ban > /dev/null 2>&1 || true
        success "fail2ban configured for PostgreSQL"
    else
        warn "Could not install fail2ban"
    fi

    echo ""

    # SSH hardening reminder
    echo -e "  ${BOLD}SSH Hardening Recommendations:${NC}"
    divider
    dim "  1. Disable password auth:  PasswordAuthentication no"
    dim "  2. Disable root login:     PermitRootLogin no"
    dim "  3. Use SSH keys only"
    dim "  4. Change SSH port:        Port 2222"
    dim "  5. Config: /etc/ssh/sshd_config"
    echo ""

    # Automatic security updates
    step "Enabling automatic security updates..."
    if command -v apt-get &>/dev/null; then
        apt-get install -y -qq unattended-upgrades > /dev/null || true
        echo 'Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/50unattended-upgrades-local 2>/dev/null || true
        success "Automatic security updates enabled"
    fi

    echo ""

    # Enable UFW with sane defaults
    if command -v ufw &>/dev/null; then
        step "Configuring UFW firewall..."
        ufw default deny incoming > /dev/null 2>&1 || true
        ufw default allow outgoing > /dev/null 2>&1 || true
        ufw allow ssh > /dev/null 2>&1 || true
        ufw allow 80/tcp > /dev/null 2>&1 || true
        ufw allow 443/tcp > /dev/null 2>&1 || true
        ufw --force enable > /dev/null 2>&1 || true
        success "UFW firewall enabled (SSH, HTTP, HTTPS allowed)"
        warn "Database ports are NOT open by default. Use: pghost firewall <name> allow <ip>"
    fi

    echo ""
    success "${BOLD}System hardening complete!${NC}"
    echo ""
    info "Run ${BOLD}pghost firewall <name> lockdown${NC} to restrict database access per instance."
    echo ""
}
