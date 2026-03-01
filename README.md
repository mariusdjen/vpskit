# vpskit

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-blue.svg)](vpskit.sh)

Set up, secure and deploy on your VPS from your terminal. No third-party service, no data sent anywhere. Everything runs locally on your machine.

**Website: [vpskit.pro](https://vpskit.pro)**

## Quick Start

```bash
bash <(curl -sL https://raw.githubusercontent.com/mariusdjen/vpskit/main/vpskit.sh)
```

That's it. The script guides you through everything.

## What It Does

```
$ bash vpskit.sh

========================================
  VPSKIT
  Set up and secure your server
========================================

[>] Step 1/9 : System update             [OK]
[>] Step 2/9 : User creation             [OK]
[>] Step 3/9 : SSH key setup             [OK]
[>] Step 4/9 : SSH hardening             [OK]
[>] Step 5/9 : Firewall                  [OK]
[>] Step 6/9 : Docker                    [OK]
[>] Step 7/9 : Caddy (reverse proxy)     [OK]
[>] Step 8/9 : Auto-updates              [OK]
[>] Step 9/9 : Dashboard MOTD            [OK]

=== YOUR SERVER IS READY! ===
  ssh deploy@your-server-ip
```

### Part 1: Preparation (on your machine)

| Step | Description |
|------|-------------|
| SSH key | Checks if a key exists, creates one if needed |
| Server IP | Asks for your VPS IP address |
| Key transfer | Sends your public key to the server (last password you'll type) |

### Part 2: Security and setup (on the VPS)

| Step | Description |
|------|-------------|
| System update | Updates the OS and installs git, curl, wget |
| User creation | Creates a non-root user with sudo access |
| SSH key | Copies the SSH key to the new user |
| SSH hardening | Disables root login and password authentication |
| Firewall | Enables UFW or firewalld (ports 22, 80, 443) |
| Fail2ban | Blocks IPs after 5 failed SSH attempts (1h ban) |
| Docker | Installs Docker and Docker Compose with log rotation |
| Caddy | Reverse proxy with automatic SSL (Let's Encrypt) |
| Auto-updates | Enables automatic security updates |
| Dashboard MOTD | Server status on every SSH login (CPU, RAM, disk, Docker) |

### Part 3: Post-setup

- Displays the SSH connection command
- Offers to create an SSH shortcut (`ssh vps` instead of `ssh -i ~/.ssh/key user@ip`)

## Deploy an Application

After setup, deploy your apps with one command:

```bash
bash <(curl -sL https://raw.githubusercontent.com/mariusdjen/vpskit/main/vpskit.sh)
# Then choose "Deploy an application"
```

The script asks for:
- Your Git repository URL (HTTPS or SSH, both work)
- The application name
- The domain name
- The application port (default: 3000)
- A `.env` file if needed

It automatically detects `docker-compose.yml` or `Dockerfile` in your repository.

### What deploy.sh does

1. Connects to the VPS (reuses the setup.sh session)
2. Configures GitHub SSH access if needed (multi-account support)
3. Clones the repository (or runs `git pull` if already deployed)
4. Installs the `.env` file if provided
5. Detects and runs `docker-compose.yml` or `Dockerfile`
6. Configures Caddy (reverse proxy + SSL + www redirect)
7. Verifies that the application responds

### Public and private repositories

- **Public repo** (HTTPS): cloned directly, no configuration needed
- **Private repo**: the script detects the failure, generates an SSH key and guides you step by step to add it on GitHub

### Multiple GitHub accounts

The script supports multiple GitHub accounts on the same VPS. Each account gets its own SSH key. On the first deployment, the script generates the key and walks you through adding it on GitHub. On subsequent deployments, you pick which account to use.

### Deploy a branch or tag

In interactive mode, the script lets you pick a branch or tag. In CI/CD:

```bash
# Deploy a specific branch
bash deploy.sh -ip IP -key KEY -user USER -app NAME -repo URL -domain DOMAIN -branch staging

# Deploy a tag
bash deploy.sh -ip IP -key KEY -user USER -app NAME -repo URL -domain DOMAIN -tag v1.2.0
```

### CI/CD usage

```bash
bash deploy.sh -ip IP -key KEY -user USER -app NAME -repo URL -domain DOMAIN [-port PORT] [-env FILE] [-branch BRANCH] [-tag TAG]
```

GitHub Actions example:

```yaml
name: Deploy
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup SSH key
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.VPS_SSH_KEY }}" > ~/.ssh/deploy_key
          chmod 600 ~/.ssh/deploy_key

      - name: Deploy
        run: |
          curl -sL https://raw.githubusercontent.com/mariusdjen/vpskit/main/deploy.sh -o deploy.sh
          bash deploy.sh \
            -ip ${{ secrets.VPS_IP }} \
            -key ~/.ssh/deploy_key \
            -user deploy \
            -app myapp \
            -repo git@github.com:${{ github.repository }}.git \
            -domain myapp.example.com \
            -port 3000
```

### Redeployment

Run `deploy.sh` again with the same parameters. The script runs `git pull` and restarts the containers.

### Rollback

If a deployment goes wrong, roll back to the previous version:

```bash
bash <(curl -sL https://raw.githubusercontent.com/mariusdjen/vpskit/main/vpskit.sh)
# Then choose "Deploy" > "Rollback"
```

The script automatically saves the commit hash before each `git pull`. Rollback restores that commit and restarts the containers.

CI/CD usage:

```bash
bash deploy.sh -ip IP -key KEY -user USER -app NAME --rollback
```

## Server Status

```bash
bash <(curl -sL https://raw.githubusercontent.com/mariusdjen/vpskit/main/vpskit.sh)
# Then choose "Check VPS status"
```

Shows the full status of your server and all deployed applications:
- Server info: OS, uptime, CPU, RAM, disk
- Per application: Docker status, domain, port, last commit
- Docker containers summary

CI/CD usage:

```bash
bash status.sh -ip IP -key KEY -user USER
```

## Backup and Restore

### Backup

```bash
bash <(curl -sL https://raw.githubusercontent.com/mariusdjen/vpskit/main/vpskit.sh)
# Then choose "Backup / Restore"
```

For each application, the script saves:
- The `.env` file
- Docker volumes (persistent data)
- The Caddyfile (domain configuration)
- Metadata (commit, domain, port, date)

Everything is downloaded to your machine as a `vps-backup-DATE-APP.tar.gz` file.

CI/CD usage:

```bash
# Backup a single app
bash backup.sh -ip IP -key KEY -user USER -app NAME [-dest /local/path]

# Backup all apps
bash backup.sh -ip IP -key KEY -user USER [-dest /local/path]
```

### Restore

```bash
bash <(curl -sL https://raw.githubusercontent.com/mariusdjen/vpskit/main/vpskit.sh)
# Then choose "Backup / Restore" > "Restore"
```

CI/CD usage:

```bash
bash backup.sh -ip IP -key KEY -user USER -app NAME --restore file.tar.gz
```

## Requirements

| System | Required |
|--------|----------|
| macOS | Terminal (built-in) |
| Linux | Terminal (built-in) |
| Windows | [Git Bash](https://git-scm.com/download/win) or WSL |

Your VPS must run a supported distribution with root access.

## Supported Distributions

| Family | Distributions |
|--------|--------------|
| Debian | Ubuntu, Debian |
| RHEL | AlmaLinux, Rocky Linux, CentOS, Fedora |

The script auto-detects the server distribution and adapts its commands (apt/dnf, ufw/firewalld, etc.).

## Installation by OS

### macOS / Linux

```bash
bash <(curl -sL https://raw.githubusercontent.com/mariusdjen/vpskit/main/vpskit.sh)
```

### Windows - Git Bash

1. Install [Git for Windows](https://git-scm.com/download/win)
2. Open **Git Bash**
3. Run the command above

### Windows - WSL

1. Enable WSL: `wsl --install` (PowerShell as admin)
2. Open the Ubuntu terminal
3. Run the command above

### Windows - PowerShell

```powershell
curl.exe -sL https://raw.githubusercontent.com/mariusdjen/vpskit/main/vpskit.sh -o vpskit.sh
wsl bash vpskit.sh
```

## Security

Everything runs locally on your machine. No account, no cloud service, no data sent to any third party. The script connects directly to your server via SSH. Your keys stay on your machine.

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT - [Marius Djen](https://github.com/mariusdjen)
