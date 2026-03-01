# Changelog

## v2.3.1

- Security fix: escape user inputs in sed (anti-injection)
- Replace `source` with secure parsing for session file
- Fix PubkeyAuthentication sed (single-step activation)
- mark_done SSH (step4) only on sshd -t success
- Prevent division by zero for RAM in MOTD and status.sh
- Integer validation for rollback choice (APP_CHOICE)
- Clean up git-clone-err.log after successful clone
- Fix Caddy block deletion (support nested blocks with awk)
- Fix --restore without file in backup.sh (clear error message)
- Fix backup archive permissions (readable by scp user)
- Portable CPU usage in status.sh (via /proc/stat instead of top -bn1)
- Fix docker compose ps parsing (Go template format)
- Set 700 permissions on remote temporary scripts
- Trap cleanup for local temporary files
- Set 600 permissions on local session file
- Quote sudoers and home directory paths
- Rewrite sed_escape() with explicit substitutions (portable across all sed implementations)
- Exact domain matching in Caddy block deletion (prevents false positives on subdomains)
- Integer validation of APP_CHOICE in backup.sh (consistent with deploy.sh)

## v2.3.0

- Deploy specific branch/tag (-branch, -tag) in deploy.sh
- Automatic Docker cleanup after each deployment (prune images + cache)
- Fail2ban in setup.sh: SSH brute-force protection (5 attempts, 1h ban)
- Docker log rotation in setup.sh (10 MB x 3 files max)
- Deployment history in ~/.deploy-history (last 50 entries)
- Display recent deployments on deploy.sh launch

## v2.2.0

- status.sh script: display VPS and application status
- Rollback in deploy.sh: revert to previous commit in one command
- backup.sh script: backup and restore applications
  - Backup: .env, Docker volumes, Caddyfile, metadata
  - Restore: upload and extract archive, restart containers
- Deployment metadata saved (.deploy-domain, .deploy-port)
- Commit saved before each git pull (.last-working-commit)

## v2.1.0

- DNS verification before Caddy configuration
- Health check after deployment (verify app responds)
- Automatic www to non-www redirect
- Docker logs displayed on build failure
- IP format validation
- More detailed SSH error messages
- sshd -t validation before SSH restart
- scp/ssh error checking
- Caddy: proper domain name escaping
- err() function added in setup.sh

## v2.0.0

- deploy.sh script: deploy applications in one command
- Multi-account GitHub SSH management on VPS
- Automatic detection of docker-compose.yml or Dockerfile
- Automatic Caddy configuration (reverse proxy + SSL)
- CI/CD mode with arguments (GitHub Actions compatible)
- Public (HTTPS) and private (SSH) repo support
- .env file management (secure upload or empty creation)

## v1.3.1

- Per-OS execution commands in README (macOS, Linux, Git Bash, WSL, PowerShell)

## v1.3.0

- New VPS / update mode on launch
- Session saved in ~/.ssh/.vps-bootstrap-local

## v1.2.0

- Fix heredoc syntax (remote scripts via temp file)
- Handle existing user
- Dashboard MOTD (server status on every SSH login)

## v1.1.0

- Multi-distribution support (Debian + RHEL)
- Automatic detection via /etc/os-release
- Abstraction functions (pkg_update, pkg_install, setup_firewall, etc.)

## v1.0.0

- Initial script (Ubuntu only)
- SSH hardening, firewall, Docker, Caddy
- Automatic security updates
