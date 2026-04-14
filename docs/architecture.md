# Architecture of setup.sh

## Overview

The script runs in 3 phases:

```
Local machine                    VPS
=============                    ===
1. Preparation          --->     2. Security setup (9 steps)
   - OS detection                   - Distro detection
   - Mode selection                 - Package manager abstraction
   - SSH key                        - Persistent progress tracking
   - Server IP
   - Connection test
                                 3. Post-setup
                                    - Connection command
                                    - SSH shortcut
```

## Execution flow

### Launch
```
detect_os()
  |
  v
Local session exists?
  |-- yes --> Offer to resume
  |-- no  --> Ask for mode
  v
Mode?
  |-- new    --> SSH key, IP, send key to root, test root
  |-- update --> SSH key, IP, username, test user/root
  v
Save local session
  |
  v
Generate remote script (mktemp)
  |
  v
scp script --> VPS
  |
  v
ssh execute script (with sudo if update mode)
```

### Remote script (on the VPS)

```
detect_distro() via /etc/os-release
  |
  v
Load progress (/root/.vpskit-progress)
  |
  v
For each step 1-9:
  |-- already done? --> skip_step()
  |-- otherwise     --> confirm_step() --> execute --> mark_done()
```

## Problems solved

### Heredoc inside $(cat)
The pattern `$(cat << 'EOF' ... EOF)` breaks when the content has `case` patterns
because the `)` are interpreted as closing the `$(`.
Solution: write to a temp file, scp, ssh.

### Root disabled after step 4
After SSH hardening, root can no longer connect.
The "update" mode tries connecting as the created user first,
then root as fallback.

### sed -i between macOS and Linux
macOS: `sed -i '' 's/...'`
Linux: `sed -i 's/...'`
The script detects the local OS to adapt the syntax.

### Existing user
If the user already exists on the VPS, the script checks that they are in
the sudo/wheel group and have a sudoers file, instead of just saying
"already exists".

## Multi-distribution abstraction

| Function | Debian | RHEL |
|----------|--------|------|
| pkg_update | apt update && apt upgrade -y | dnf update -y |
| pkg_install | apt install -y | dnf install -y |
| sudo_group | sudo | wheel |
| create_user | adduser --disabled-password | useradd -m -s /bin/bash |
| setup_firewall | ufw | firewalld |
| setup_caddy | apt repo cloudsmith | dnf copr |
| setup_auto_updates | unattended-upgrades | dnf-automatic |
| setup_motd | /etc/update-motd.d/ | /etc/profile.d/ |
| restart_ssh | systemctl restart ssh | systemctl restart sshd |
