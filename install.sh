#!/usr/bin/env bash
# pghost installer - one command setup
# Usage: curl -sSL https://raw.githubusercontent.com/alohe/pghost/main/install.sh | sudo bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

echo ""
echo -e "  ${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "  ${BOLD}${CYAN}║${NC}  ${BOLD}pghost installer${NC}"
echo -e "  ${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "  ${RED}✗${NC}  Run as root: curl -sSL <url> | ${BOLD}sudo${NC} bash"
    exit 1
fi

INSTALL_DIR="/opt/pghost/cli"
REPO_URL="https://raw.githubusercontent.com/alohe/pghost/main"

echo -e "  ${CYAN}→${NC}  Downloading pghost..."

mkdir -p "$INSTALL_DIR/lib"

# Download files
for file in pghost lib/config.sh lib/create.sh lib/list.sh lib/domain.sh lib/metrics.sh lib/security.sh lib/backup.sh; do
    curl -sSL "$REPO_URL/$file" -o "$INSTALL_DIR/$file"
done

chmod +x "$INSTALL_DIR/pghost"

# Symlink to PATH
ln -sf "$INSTALL_DIR/pghost" /usr/local/bin/pghost

echo -e "  ${GREEN}✓${NC}  pghost installed to /usr/local/bin/pghost"
echo ""

# Run install command to set up dependencies (call directly, not via symlink)
"$INSTALL_DIR/pghost" install

echo ""
echo -e "  ${BOLD}Quick start:${NC}"
echo ""
echo -e "  ${DIM}  pghost create myapp${NC}"
echo -e "  ${DIM}  pghost domain myapp db.myapp.com${NC}"
echo -e "  ${DIM}  pghost firewall myapp allow \$(curl -s ifconfig.me)${NC}"
echo -e "  ${DIM}  pghost firewall myapp lockdown${NC}"
echo -e "  ${DIM}  pghost metrics myapp${NC}"
echo ""
