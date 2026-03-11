# pghost

Self-hosted PostgreSQL manager. Spin up databases like Neon, but on your own VPS. No compute limits, no surprises.

## Install

SSH into your VPS and run:

```bash
# One-liner install
curl -sSL https://raw.githubusercontent.com/alohe/pghost/main/install.sh | sudo bash
```

# Or clone and install
git clone https://github.com/alohe/pghost.git
cd pghost && sudo ./pghost install
```

## Quick Start

```bash
# Create an instance — you get a DATABASE_URL instantly
pghost create myapp

# Add a domain with auto-SSL (shows you the DNS records to add)
pghost domain myapp db.myapp.com

# Lock it down — only your IP can connect
pghost firewall myapp allow $(curl -s ifconfig.me)
pghost firewall myapp lockdown

# Check stats
pghost metrics myapp

# Set up daily backups
pghost cron myapp daily
```

## What You Get

When you run `pghost create myapp`, you get:

```
✓ Instance 'myapp' created successfully!

  DATABASE_URL:

  postgresql://myapp_user:a8Kj2mNx9pQrSt@123.45.67.89:5432/myapp_db?sslmode=require

  Host:     123.45.67.89
  Port:     5432
  Database: myapp_db
  User:     myapp_user
  Password: a8Kj2mNx9pQrSt
  SSL:      enabled (TLS 1.2+)
```

When you run `pghost domain myapp db.myapp.com`, you get:

```
  Step 1: Add these DNS records

  ┌──────────┬──────────────────────┬──────────────────┬───────┐
  │ Type     │ Name                 │ Value            │ TTL   │
  ├──────────┼──────────────────────┼──────────────────┼───────┤
  │ A        │ db.myapp.com         │ 123.45.67.89     │ 300   │
  └──────────┴──────────────────────┴──────────────────┴───────┘

  ...automatically obtains Let's Encrypt SSL certificate...

  ✓ Domain configured!

  DATABASE_URL (via domain):
  postgresql://myapp_user:a8Kj2mNx9pQrSt@db.myapp.com:5432/myapp_db?sslmode=require
```

## Commands

### Instances

```bash
pghost create <name> [options]     # Create a new instance
pghost delete <name> [--force]     # Delete an instance
pghost list                        # List all instances
pghost start <name>                # Start an instance
pghost stop <name>                 # Stop an instance
pghost restart <name>              # Restart an instance
pghost url <name>                  # Show DATABASE_URL
pghost logs <name> [lines]         # View logs
```

### Create Options

```bash
pghost create myapp                          # Defaults
pghost create myapp --memory 1g              # 1GB RAM limit
pghost create myapp --max-conn 200           # 200 max connections
pghost create myapp --port 5433              # Custom port
pghost create myapp --user admin --database proddb  # Custom user/db
```

### Domains

```bash
pghost domain myapp db.myapp.com             # Add domain + SSL
pghost domain myapp db.myapp.com remove      # Remove domain
```

### Monitoring

```bash
pghost metrics                    # Overview of all instances
pghost metrics myapp              # Detailed stats for one instance
```

Shows: CPU, memory, disk, connections, database size, cache hit ratio, transaction stats, top tables by size, SSL status.

### Security

```bash
pghost firewall myapp status             # Show rules
pghost firewall myapp allow 1.2.3.4      # Allow an IP
pghost firewall myapp allow 10.0.0.0/24  # Allow a subnet
pghost firewall myapp deny 5.6.7.8       # Block an IP
pghost firewall myapp lockdown           # Block everything except allowed
pghost firewall myapp open               # Remove lockdown
pghost harden                            # Full system hardening
```

### Backups

```bash
pghost backup myapp                      # Create backup
pghost backup myapp /path/to/file.sql.gz # Backup to specific file
pghost restore myapp backup.sql.gz       # Restore from backup
pghost backups                           # List all backups
pghost backups myapp                     # List backups for instance
pghost cron myapp daily                  # Automated daily backups
pghost cron myapp hourly                 # Automated hourly backups
```

## Security Features

- **SSL/TLS enforced** — all remote connections require TLS 1.2+
- **Non-SSL rejected** — plaintext remote connections are blocked at the database level
- **scram-sha-256 auth** — modern password hashing, no md5
- **Per-instance firewall** — iptables rules per database port
- **Lockdown mode** — deny-all except explicitly allowed IPs
- **fail2ban integration** — auto-ban after 5 failed login attempts
- **Let's Encrypt SSL** — auto-renewing certificates for domains
- **Connection logging** — all connects/disconnects logged
- **Resource isolation** — each instance has memory and CPU limits
- **Auto security updates** — unattended-upgrades configured

## Multiple Instances

Run as many databases as your VPS can handle:

```bash
pghost create app-prod --memory 1g --port 5432
pghost create app-staging --memory 256m --port 5433
pghost create analytics --memory 512m --port 5434

pghost list
# NAME           STATUS     PORT     DATABASE           DOMAIN
# app-prod       running    5432     app-prod_db        db.myapp.com
# app-staging    running    5433     app-staging_db     -
# analytics      running    5434     analytics_db       -

pghost metrics
# NAME         STATUS   CPU        MEMORY     CONNS    DB SIZE  DISK
# app-prod     running  2.3%       189MiB     12       1.2GB    1.4G
# app-staging  running  0.1%       45MiB      2        84MB     112M
# analytics    running  1.1%       128MiB     5        3.4GB    3.8G
```

## VPS Recommendations

| Provider | Plan | Cost | RAM | Storage |
|----------|------|------|-----|---------|
| **Hetzner** | CX11 | €4.5/mo | 2GB | 40GB |
| **Hetzner** | CX21 | €8/mo | 4GB | 80GB |
| DigitalOcean | Basic | $6/mo | 1GB | 25GB |
| Vultr | Cloud | $6/mo | 1GB | 25GB |
| Linode | Nanode | $5/mo | 1GB | 25GB |

**Hetzner CX21 at €8/month** can comfortably run 3-5 PostgreSQL instances.

## File Structure

```
/opt/pghost/
├── cli/              # pghost CLI
│   ├── pghost        # Main CLI
│   └── lib/          # Command modules
├── data/             # Database data (per instance)
├── certs/            # SSL certificates (per instance)
├── backups/          # Backups (per instance)
├── instances/        # Instance configs (.env files)
└── logs/             # Logs
```

## vs Neon

| | Neon Free | Neon Pro | pghost (Hetzner CX11) |
|---|---|---|---|
| Cost | $0/mo | $19/mo | €4.5/mo |
| Compute | 100 hrs | 300 hrs | **Unlimited** |
| Storage | 512MB | 10GB | **40GB** |
| Instances | 1 | 10 | **Unlimited** |
| Custom domain | No | No | **Yes** |
| Firewall | No | No | **Yes** |
| Backups | 7 days | 30 days | **Custom** |
| SSL | Yes | Yes | **Yes** |

## License

MIT
