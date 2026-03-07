#!/bin/bash
set -euo pipefail

# ============================================
# Setup complet VPS neuf
# Distributions : Ubuntu, Debian, AlmaLinux, Rocky Linux, CentOS, Fedora
# Fonctionne sur Mac, Linux et Windows (Git Bash / WSL)
# Reprend automatiquement en cas de déconnexion.
#
# Usage : bash <(curl -sL https://raw.githubusercontent.com/mariusdjen/vps-bootstrap/main/setup.sh)
# ============================================

# --- Couleurs ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO] $1${NC}"; }
success() { echo -e "${GREEN}[OK] $1${NC}"; }
warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }
err()     { echo -e "${RED}[ERR] $1${NC}"; }
step()    { echo -e "\n${BOLD}${YELLOW}[>] $1${NC}\n  $2\n"; }

confirm() {
    read -p "  $MSG_SETUP_NEW_STEP3_CONFIRM" REPLY
    [[ "$REPLY" == "o" || "$REPLY" == "O" || "$REPLY" == "y" || "$REPLY" == "Y" ]]
}

# Echapper les caracteres speciaux pour sed (evite l'injection de commandes)
# Echappe : \ (escape), & (back-reference), | (delimiteur)
sed_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/|/\\|/g'
}

# Fichiers temporaires a nettoyer au EXIT
_CLEANUP_FILES=()
cleanup() { rm -f "${_CLEANUP_FILES[@]}"; }
trap cleanup EXIT

# Lire une variable depuis un fichier key="value" de facon securisee
read_state_var() {
    local file="$1" var="$2"
    grep "^${var}=" "$file" 2>/dev/null | head -1 | cut -d'=' -f2- | sed 's/^"//;s/"$//'
}

# =========================================
# DÉTECTION DE L'ENVIRONNEMENT
# =========================================

detect_os() {
    case "$(uname -s)" in
        Darwin)  OS="mac" ;;
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                OS="wsl"
            else
                OS="linux"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)  OS="windows" ;;
        *)  OS="unknown" ;;
    esac
}

detect_os

# --- Chargement de la langue ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -f "${SCRIPT_DIR}/lang.sh" ]; then
    . "${SCRIPT_DIR}/lang.sh"
else
    _LANG_TMP=$(mktemp)
    _CLEANUP_FILES+=("$_LANG_TMP")
    curl -fsSL "https://raw.githubusercontent.com/mariusdjen/vpskit/main/lang.sh" -o "$_LANG_TMP" 2>/dev/null && . "$_LANG_TMP"
fi

echo ""
echo "========================================="
echo -e "  ${BOLD}VPS BOOTSTRAP${NC}"
echo "  $MSG_SETUP_BANNER_SUBTITLE"
echo "  $MSG_SETUP_BANNER_SUBTITLE2"
echo ""
echo "  $MSG_SETUP_BANNER_AUTHOR"
echo "  $MSG_SETUP_BANNER_WEBSITE"
echo "========================================="
echo ""

case "$OS" in
    mac)      info "$MSG_SETUP_OS_MAC" ;;
    linux)    info "$MSG_SETUP_OS_LINUX" ;;
    windows)  info "$MSG_SETUP_OS_WINDOWS_GITBASH" ;;
    wsl)      info "$MSG_SETUP_OS_WSL" ;;
    *)
        err "$MSG_SETUP_OS_UNKNOWN_ERR"
        echo "  $MSG_SETUP_OS_UNKNOWN_COMPAT"
        echo "  $MSG_SETUP_OS_UNKNOWN_MACOS"
        echo "  $MSG_SETUP_OS_UNKNOWN_LINUX"
        echo "  $MSG_SETUP_OS_UNKNOWN_WINDOWS"
        echo ""
        echo "  $MSG_SETUP_OS_WINDOWS_INSTALL"
        echo "    $MSG_SETUP_OS_WINDOWS_STEP1"
        echo "    $MSG_SETUP_OS_WINDOWS_STEP2"
        echo "    $MSG_SETUP_OS_WINDOWS_STEP3"
        exit 1
        ;;
esac

# --- Vérifier que ssh est disponible ---
if ! command -v ssh &>/dev/null; then
    err "$MSG_SETUP_SSH_NOT_FOUND_ERR"
    case "$OS" in
        windows)
            echo "  $MSG_SETUP_SSH_INSTALL_WINDOWS"
            echo "  $MSG_SETUP_SSH_INSTALL_WINDOWS_ALT"
            ;;
        *)
            echo "  $MSG_SETUP_SSH_INSTALL_OTHER"
            ;;
    esac
    exit 1
fi

# --- Dossier SSH ---
SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# --- Fichier de sauvegarde locale (IP, clé, user) ---
LOCAL_STATE="$SSH_DIR/.vps-bootstrap-local"

# =========================================
# FONCTION : SÉLECTION DE CLÉ SSH
# =========================================

select_ssh_key() {
    KEYS=()
    for key in "$SSH_DIR"/*; do
        if [ -f "$key" ] && [[ "$key" != *.pub ]] && [[ "$(basename "$key")" != "config"* ]] && [[ "$(basename "$key")" != "known_hosts"* ]] && [[ "$(basename "$key")" != ".vps-bootstrap"* ]]; then
            if [ -f "${key}.pub" ]; then
                KEYS+=("$key")
            fi
        fi
    done

    if [ ${#KEYS[@]} -gt 0 ]; then
        info "$MSG_SETUP_SSH_KEYS_FOUND"
        echo ""
        for i in "${!KEYS[@]}"; do
            KEYNAME=$(basename "${KEYS[$i]}")
            KEYTYPE=$(awk '{print $1}' "${KEYS[$i]}.pub" | sed 's/ssh-//')
            NUM=$((i + 1))
            echo "  ${NUM}) ${KEYNAME} (${KEYTYPE})"
        done
        NEW_NUM=$((${#KEYS[@]} + 1))
        echo ""
        echo -e "  ${NEW_NUM}) ${YELLOW}${MSG_SETUP_SSH_KEY_CREATE_NEW}${NC}"
        echo ""
        read -p "  $(printf "$MSG_SETUP_SSH_KEY_PROMPT_CHOICE" "$NEW_NUM")" KEY_CHOICE

        if [[ "$KEY_CHOICE" == "$NEW_NUM" ]]; then
            read -p "  $MSG_SETUP_SSH_KEY_PROMPT_NEW_NAME" CUSTOM_KEY_NAME
            CUSTOM_KEY_NAME=${CUSTOM_KEY_NAME:-vps}
            SSH_KEY="$SSH_DIR/$CUSTOM_KEY_NAME"
            ssh-keygen -t ed25519 -C "vps-bootstrap" -f "$SSH_KEY"
            success "$(printf "$MSG_SETUP_SSH_KEY_CREATED" "$SSH_KEY")"
        elif [[ "$KEY_CHOICE" =~ ^[0-9]+$ ]] && [ "$KEY_CHOICE" -ge 1 ] && [ "$KEY_CHOICE" -le "${#KEYS[@]}" ]; then
            SSH_KEY="${KEYS[$((KEY_CHOICE - 1))]}"
            success "$(printf "$MSG_SETUP_SSH_KEY_SELECTED" "$(basename "$SSH_KEY")")"
        else
            echo -e "${RED}${MSG_SETUP_SSH_KEY_INVALID_CHOICE}${NC}"
            exit 1
        fi
    else
        info "$MSG_SETUP_SSH_NO_KEY_FOUND"
        echo ""
        read -p "  $MSG_SETUP_SSH_KEY_PROMPT_NAME" CUSTOM_KEY_NAME
        if [[ -n "$CUSTOM_KEY_NAME" ]]; then
            SSH_KEY="$SSH_DIR/$CUSTOM_KEY_NAME"
        else
            SSH_KEY="$SSH_DIR/id_ed25519"
        fi
        ssh-keygen -t ed25519 -C "vps-bootstrap" -f "$SSH_KEY"
        success "$(printf "$MSG_SETUP_SSH_KEY_CREATED_NEW" "$SSH_KEY")"
    fi
}

# =========================================
# CHOIX DU MODE
# =========================================

MODE=""

# Si une session locale existe, proposer la reprise directe
if [ -f "$LOCAL_STATE" ]; then
    VPS_IP=$(read_state_var "$LOCAL_STATE" "VPS_IP")
    SSH_KEY=$(read_state_var "$LOCAL_STATE" "SSH_KEY")
    USERNAME=$(read_state_var "$LOCAL_STATE" "USERNAME")
    if [[ -n "${VPS_IP:-}" && -n "${SSH_KEY:-}" && -n "${USERNAME:-}" ]]; then
        echo ""
        warn "$MSG_SETUP_SESSION_DETECTED"
        echo "    $(printf "$MSG_SETUP_SESSION_IP" "$VPS_IP")"
        echo "    $(printf "$MSG_SETUP_SESSION_KEY" "$(basename "$SSH_KEY")")"
        echo "    $(printf "$MSG_SETUP_SESSION_USER" "$USERNAME")"
        echo ""
        read -p "  $MSG_SETUP_SESSION_RESUME_PROMPT" RESUME_REPLY
        if [[ "$RESUME_REPLY" == "o" || "$RESUME_REPLY" == "O" || "$RESUME_REPLY" == "y" || "$RESUME_REPLY" == "Y" ]]; then
            MODE="update"
        fi
    fi
fi

# Sinon, demander le mode
if [ -z "$MODE" ]; then
    echo ""
    echo "  $MSG_SETUP_MODE_NEW"
    echo "  $MSG_SETUP_MODE_UPDATE"
    echo ""
    read -p "  $MSG_SETUP_MODE_PROMPT" MODE_CHOICE
    case "$MODE_CHOICE" in
        2) MODE="update" ;;
        *) MODE="new" ;;
    esac
fi

# =========================================
# MODE 1 : NOUVEAU VPS
# =========================================

if [ "$MODE" = "new" ]; then

    echo ""
    echo -e "${BOLD}${MSG_SETUP_NEW_PART1_TITLE}${NC}"

    # --- Clé SSH ---
    step "$MSG_SETUP_NEW_STEP1_TITLE" "$(echo -e "$MSG_SETUP_NEW_STEP1_DESC")"

    select_ssh_key

    echo ""
    info "$MSG_SETUP_NEW_PUBKEY_INFO"
    echo ""
    echo "  $(cat "${SSH_KEY}.pub")"
    echo ""

    # --- IP du serveur ---
    step "$MSG_SETUP_NEW_STEP2_TITLE" "$(echo -e "$MSG_SETUP_NEW_STEP2_DESC")"

    read -p "  $MSG_SETUP_NEW_IP_PROMPT" VPS_IP

    if [[ -z "$VPS_IP" ]]; then
        err "$MSG_SETUP_NEW_IP_REQUIRED_ERR"
        exit 1
    fi

    if ! echo "$VPS_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        err "$(printf "$MSG_SETUP_NEW_IP_INVALID_ERR" "$VPS_IP")"
        echo "  $MSG_SETUP_NEW_IP_FORMAT"
        exit 1
    fi

    # --- Envoyer la clé SSH ---
    step "$MSG_SETUP_NEW_STEP3_TITLE" "$(echo -e "$MSG_SETUP_NEW_STEP3_DESC")"

    if confirm; then
        if command -v ssh-copy-id &>/dev/null; then
            ssh-copy-id -i "${SSH_KEY}.pub" "root@${VPS_IP}"
        else
            info "$MSG_SETUP_NEW_STEP3_MANUAL_SEND"
            cat "${SSH_KEY}.pub" | ssh "root@${VPS_IP}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
        fi
        success "$MSG_SETUP_NEW_STEP3_SUCCESS"
    else
        warn "$MSG_SETUP_NEW_STEP3_SKIPPED"
    fi

    # --- Test de connexion ---
    echo ""
    info "$MSG_SETUP_NEW_CONNTEST_INFO"
    if ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o BatchMode=yes "root@${VPS_IP}" "echo ok" &>/dev/null; then
        success "$MSG_SETUP_NEW_CONNTEST_OK"
    else
        err "$MSG_SETUP_NEW_CONNTEST_ERR"
        exit 1
    fi

    # --- Nom d'utilisateur ---
    echo ""
    echo -e "${BOLD}${MSG_SETUP_NEW_PART2_TITLE}${NC}"
    echo ""

    read -p "$MSG_SETUP_NEW_USERNAME_PROMPT" USERNAME
    USERNAME=${USERNAME:-deploy}

    SSH_USER="root"
    USE_SUDO=false

# =========================================
# MODE 2 : MISE À JOUR D'UN VPS EXISTANT
# =========================================

elif [ "$MODE" = "update" ]; then

    echo ""
    echo -e "${BOLD}${MSG_SETUP_UPDATE_TITLE}${NC}"

    # Si pas de session sauvegardée, demander les infos
    if [ -z "${SSH_KEY:-}" ]; then
        echo ""
        select_ssh_key
    fi

    if [ -z "${VPS_IP:-}" ]; then
        echo ""
        read -p "  $MSG_SETUP_UPDATE_IP_PROMPT" VPS_IP
        if [[ -z "$VPS_IP" ]]; then
            err "$MSG_SETUP_UPDATE_IP_REQUIRED_ERR"
            exit 1
        fi
        if ! echo "$VPS_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
            err "$(printf "$MSG_SETUP_UPDATE_IP_INVALID_ERR" "$VPS_IP")"
            echo "  $MSG_SETUP_UPDATE_IP_FORMAT"
            exit 1
        fi
    fi

    if [ -z "${USERNAME:-}" ]; then
        read -p "  $MSG_SETUP_UPDATE_USERNAME_PROMPT" USERNAME
        USERNAME=${USERNAME:-deploy}
    fi

    # --- Test de connexion (user d'abord, root en fallback) ---
    echo ""
    info "$MSG_SETUP_UPDATE_CONNTEST_INFO"
    if ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o BatchMode=yes "${USERNAME}@${VPS_IP}" "echo ok" &>/dev/null; then
        SSH_USER="$USERNAME"
        USE_SUDO=true
        success "$(printf "$MSG_SETUP_UPDATE_CONNTEST_USER_OK" "$USERNAME")"
    elif ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o BatchMode=yes "root@${VPS_IP}" "echo ok" &>/dev/null; then
        SSH_USER="root"
        USE_SUDO=false
        success "$MSG_SETUP_UPDATE_CONNTEST_ROOT_OK"
    else
        err "$(printf "$MSG_SETUP_UPDATE_CONNTEST_ERR" "$USERNAME")"
        echo "  $MSG_SETUP_UPDATE_CONNTEST_HINT"
        exit 1
    fi

fi

# --- Sauvegarder la session locale ---
printf 'VPS_IP="%s"\nSSH_KEY="%s"\nUSERNAME="%s"\n' "$VPS_IP" "$SSH_KEY" "$USERNAME" > "$LOCAL_STATE"
chmod 600 "$LOCAL_STATE"

# =========================================
# PARTIE 2 : SÉCURISATION DU VPS (avec reprise)
# =========================================

# Créer le script distant dans un fichier temporaire
# (évite les conflits de parsing avec les case/esac dans $(cat << ...))
TMPSCRIPT=$(mktemp)
_CLEANUP_FILES+=("$TMPSCRIPT")
cat > "$TMPSCRIPT" << 'REMOTE_EOF'
#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

USERNAME="__USERNAME__"
PROGRESS_FILE="/root/.vps-bootstrap-progress"

# Créer le fichier de progression s'il n'existe pas
touch "$PROGRESS_FILE"

# =========================================
# DÉTECTION DE LA DISTRIBUTION
# =========================================

detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_ID="$ID"
        DISTRO_NAME="${NAME:-$ID}"
        case "$ID" in
            ubuntu|debian)
                DISTRO_FAMILY="debian"
                ;;
            almalinux|rocky|centos|rhel|fedora)
                DISTRO_FAMILY="rhel"
                ;;
            *)
                DISTRO_FAMILY="unknown"
                ;;
        esac
    else
        DISTRO_FAMILY="unknown"
        DISTRO_NAME="unknown"
    fi
}

detect_distro

if [ "$DISTRO_FAMILY" = "unknown" ]; then
    echo -e "${RED}[ERR] $(printf "$RMSG_SETUP_DISTRO_UNKNOWN_ERR" "${DISTRO_NAME}")${NC}"
    echo "  $RMSG_SETUP_DISTRO_SUPPORTED"
    echo "  $RMSG_SETUP_DISTRO_DEBIAN"
    echo "  $RMSG_SETUP_DISTRO_RHEL"
    exit 1
fi

echo -e "${BLUE}[INFO] $(printf "$RMSG_SETUP_DISTRO_DETECTED" "${DISTRO_NAME}" "${DISTRO_FAMILY}")${NC}"

# =========================================
# FONCTIONS D'ABSTRACTION
# =========================================

pkg_update() {
    case "$DISTRO_FAMILY" in
        debian)  apt update && apt upgrade -y ;;
        rhel)    dnf update -y ;;
    esac
}

pkg_install() {
    case "$DISTRO_FAMILY" in
        debian)  apt install -y "$@" ;;
        rhel)    dnf install -y "$@" ;;
    esac
}

sudo_group() {
    case "$DISTRO_FAMILY" in
        debian)  echo "sudo" ;;
        rhel)    echo "wheel" ;;
    esac
}

create_user() {
    local user="$1"
    local grp
    grp=$(sudo_group)
    case "$DISTRO_FAMILY" in
        debian)
            adduser --disabled-password --gecos "" "$user"
            ;;
        rhel)
            useradd -m -s /bin/bash "$user"
            ;;
    esac
    usermod -aG "$grp" "$user"
    echo "$user ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$user"
    chmod 440 "/etc/sudoers.d/$user"
}

restart_ssh() {
    if systemctl list-units --type=service | grep -q "sshd.service"; then
        systemctl restart sshd
    else
        systemctl restart ssh
    fi
}

setup_firewall() {
    case "$DISTRO_FAMILY" in
        debian)
            pkg_install ufw
            ufw default deny incoming
            ufw default allow outgoing
            ufw allow 22/tcp
            ufw allow 80/tcp
            ufw allow 443/tcp
            ufw --force enable
            ;;
        rhel)
            systemctl start firewalld
            systemctl enable firewalld
            firewall-cmd --permanent --add-service=ssh
            firewall-cmd --permanent --add-service=http
            firewall-cmd --permanent --add-service=https
            firewall-cmd --reload
            ;;
    esac
}

setup_caddy() {
    case "$DISTRO_FAMILY" in
        debian)
            pkg_install debian-keyring debian-archive-keyring apt-transport-https curl
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
            apt update
            apt install -y caddy
            ;;
        rhel)
            dnf install -y 'dnf-command(copr)'
            dnf copr enable -y @caddy/caddy
            dnf install -y caddy
            ;;
    esac
}

setup_auto_updates() {
    case "$DISTRO_FAMILY" in
        debian)
            pkg_install unattended-upgrades
            echo 'Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/51auto-upgrades
            dpkg-reconfigure -f noninteractive unattended-upgrades
            ;;
        rhel)
            pkg_install dnf-automatic
            sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf
            systemctl enable --now dnf-automatic.timer
            ;;
    esac
}

setup_motd() {
    local MOTD_SCRIPT='#!/bin/bash
GREEN='"'"'\033[0;32m'"'"'
YELLOW='"'"'\033[1;33m'"'"'
RED='"'"'\033[0;31m'"'"'
BOLD='"'"'\033[1m'"'"'
NC='"'"'\033[0m'"'"'

HOSTNAME=$(hostname)
OS=$(. /etc/os-release && echo "$PRETTY_NAME")
UPTIME=$(uptime -p 2>/dev/null | sed "s/up //" || echo "N/A")
LOAD=$(cat /proc/loadavg | awk "{print \$1, \$2, \$3}")
CPU_CORES=$(nproc)

RAM_TOTAL=$(free -m | awk "/Mem:/ {print \$2}")
RAM_USED=$(free -m | awk "/Mem:/ {print \$3}")
if [ "$RAM_TOTAL" -gt 0 ] 2>/dev/null; then
    RAM_PCT=$((RAM_USED * 100 / RAM_TOTAL))
else
    RAM_PCT=0
fi

SWAP_TOTAL=$(free -m | awk "/Swap:/ {print \$2}")
SWAP_USED=$(free -m | awk "/Swap:/ {print \$3}")
if [ "$SWAP_TOTAL" -gt 0 ] 2>/dev/null; then
    SWAP_PCT=$((SWAP_USED * 100 / SWAP_TOTAL))
else
    SWAP_PCT=0
fi

DISK_TOTAL=$(df -h / | awk "NR==2 {print \$2}")
DISK_USED=$(df -h / | awk "NR==2 {print \$3}")
DISK_PCT=$(df / | awk "NR==2 {print \$5}" | tr -d "%")

IP=$(hostname -I 2>/dev/null | awk "{print \$1}" || echo "N/A")

if command -v docker &>/dev/null; then
    DOCKER_COUNT=$(docker ps -q 2>/dev/null | wc -l | tr -d " ")
    DOCKER_LINE="  Docker     : __MOTD_DOCKER__"
else
    DOCKER_LINE=""
fi

color_pct() {
    if [ "$1" -lt 60 ]; then echo -e "${GREEN}${1}%${NC}"
    elif [ "$1" -lt 85 ]; then echo -e "${YELLOW}${1}%${NC}"
    else echo -e "${RED}${1}%${NC}"
    fi
}

echo ""
echo "========================================="
echo -e "  ${BOLD}${HOSTNAME}${NC} - ${OS}"
echo "========================================="
echo ""
echo "  Uptime     : ${UPTIME}"
echo "  Load       : ${LOAD}"
echo ""
echo "  CPU        : ${CPU_CORES} __MOTD_CORES__"
echo -e "  RAM        : ${RAM_USED} __MOTD_RAM_UNIT__ / ${RAM_TOTAL} __MOTD_RAM_UNIT__ ($(color_pct $RAM_PCT))"
echo -e "  Swap       : ${SWAP_USED} __MOTD_RAM_UNIT__ / ${SWAP_TOTAL} __MOTD_RAM_UNIT__ ($(color_pct $SWAP_PCT))"
echo -e "  __MOTD_DISK__     : ${DISK_USED} / ${DISK_TOTAL} ($(color_pct $DISK_PCT))"
echo ""
echo "  IP         : ${IP}"
if [ -n "$DOCKER_LINE" ]; then
    echo "$DOCKER_LINE"
fi
echo "========================================="
echo ""
'

    # Remplacer les placeholders MOTD par les labels traduits
    MOTD_DOCKER_LABEL=$(printf "$RMSG_MOTD_DOCKER" "\${DOCKER_COUNT}")
    MOTD_SCRIPT="${MOTD_SCRIPT//__MOTD_CORES__/$RMSG_MOTD_CORES}"
    MOTD_SCRIPT="${MOTD_SCRIPT//__MOTD_RAM_UNIT__/$RMSG_MOTD_RAM_UNIT}"
    MOTD_SCRIPT="${MOTD_SCRIPT//__MOTD_DISK__/$RMSG_MOTD_DISK}"
    MOTD_SCRIPT="${MOTD_SCRIPT//__MOTD_DOCKER__/$MOTD_DOCKER_LABEL}"

    case "$DISTRO_FAMILY" in
        debian)
            chmod -x /etc/update-motd.d/* 2>/dev/null || true
            echo "$MOTD_SCRIPT" > /etc/update-motd.d/99-vps-dashboard
            chmod +x /etc/update-motd.d/99-vps-dashboard
            ;;
        rhel)
            echo "$MOTD_SCRIPT" > /etc/profile.d/vps-dashboard.sh
            chmod +x /etc/profile.d/vps-dashboard.sh
            ;;
    esac
}

# =========================================
# PROGRESSION ET INTERACTION
# =========================================

is_done() {
    grep -q "^$1$" "$PROGRESS_FILE" 2>/dev/null
}

mark_done() {
    echo "$1" >> "$PROGRESS_FILE"
}

confirm_step() {
    echo ""
    echo -e "${YELLOW}[>] $1${NC}"
    echo "  $2"
    echo ""
    read -p "  $RMSG_SETUP_STEP_EXECUTE_PROMPT" REPLY
    [[ "$REPLY" == "o" || "$REPLY" == "O" || "$REPLY" == "y" || "$REPLY" == "Y" ]]
}

done_step() {
    echo -e "  ${GREEN}[OK] $1${NC}"
}

skip_step() {
    echo -e "  ${GREEN}[OK] $1 $RMSG_SETUP_STEP_ALREADY_DONE${NC}"
}

# =========================================
# ÉTAPES DE SÉCURISATION
# =========================================

# === 1/9 ===
if is_done "step1"; then
    skip_step "$RMSG_SETUP_STEP1_TITLE"
elif confirm_step "$RMSG_SETUP_STEP1_TITLE" "$RMSG_SETUP_STEP1_DESC"; then
    pkg_update
    pkg_install git curl wget
    mark_done "step1"
    done_step "$RMSG_SETUP_STEP1_DONE"
fi

# === 2/9 ===
if is_done "step2"; then
    skip_step "$(printf "$RMSG_SETUP_STEP2_TITLE" "$USERNAME")"
elif confirm_step "$(printf "$RMSG_SETUP_STEP2_TITLE" "$USERNAME")" "$RMSG_SETUP_STEP2_DESC"; then
    if ! id "$USERNAME" &>/dev/null; then
        create_user "$USERNAME"
        done_step "$(printf "$RMSG_SETUP_STEP2_CREATED" "$USERNAME")"
    else
        echo -e "  ${BLUE}[INFO] $(printf "$RMSG_SETUP_STEP2_ALREADY_EXISTS" "$USERNAME")${NC}"
        SUDO_GRP=$(sudo_group)
        if ! groups "$USERNAME" | grep -q "$SUDO_GRP"; then
            usermod -aG "$SUDO_GRP" "$USERNAME"
            echo -e "  ${BLUE}[INFO] $(printf "$RMSG_SETUP_STEP2_GROUP_ADDED" "$SUDO_GRP")${NC}"
        fi
        if [ ! -f "/etc/sudoers.d/$USERNAME" ]; then
            echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
            chmod 440 "/etc/sudoers.d/$USERNAME"
            echo -e "  ${BLUE}[INFO] $RMSG_SETUP_STEP2_SUDOERS_ADDED${NC}"
        fi
        done_step "$(printf "$RMSG_SETUP_STEP2_DONE_EXISTING" "$USERNAME")"
    fi
    mark_done "step2"
fi

# === 3/9 ===
if is_done "step3"; then
    skip_step "$(printf "$RMSG_SETUP_STEP3_TITLE" "$USERNAME")"
elif confirm_step "$(printf "$RMSG_SETUP_STEP3_TITLE" "$USERNAME")" "$(printf "$RMSG_SETUP_STEP3_DESC" "$USERNAME")"; then
    mkdir -p "/home/$USERNAME/.ssh"
    if [ -f /root/.ssh/authorized_keys ]; then
        cp /root/.ssh/authorized_keys "/home/$USERNAME/.ssh/"
    else
        touch "/home/$USERNAME/.ssh/authorized_keys"
    fi
    chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"
    chmod 700 "/home/$USERNAME/.ssh"
    chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
    mark_done "step3"
    done_step "$(printf "$RMSG_SETUP_STEP3_DONE" "$USERNAME")"
fi

# === 4/9 ===
if is_done "step4"; then
    skip_step "$RMSG_SETUP_STEP4_TITLE"
elif confirm_step "$RMSG_SETUP_STEP4_TITLE" "$RMSG_SETUP_STEP4_DESC"; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    if sshd -t 2>/dev/null; then
        restart_ssh
        mark_done "step4"
        done_step "$RMSG_SETUP_STEP4_DONE"
    else
        echo -e "${RED}[ERR] $RMSG_SETUP_STEP4_INVALID_CONFIG_ERR${NC}"
        cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
        restart_ssh
        echo -e "${YELLOW}[WARN] $RMSG_SETUP_STEP4_RESTORED_WARN${NC}"
    fi
fi

# === 5/9 ===
if is_done "step5"; then
    skip_step "$RMSG_SETUP_STEP5_TITLE"
elif confirm_step "$RMSG_SETUP_STEP5_TITLE" "$RMSG_SETUP_STEP5_DESC"; then
    setup_firewall
    mark_done "step5"
    done_step "$RMSG_SETUP_STEP5_DONE"
fi

# === Fail2ban ===
if is_done "step_fail2ban"; then
    skip_step "$RMSG_SETUP_FAIL2BAN_TITLE"
elif confirm_step "$RMSG_SETUP_FAIL2BAN_TITLE" "$RMSG_SETUP_FAIL2BAN_DESC"; then
    if [ "$DISTRO_FAMILY" = "rhel" ]; then
        pkg_install epel-release 2>/dev/null || true
    fi
    pkg_install fail2ban

    cat > /etc/fail2ban/jail.local << 'F2B_BLOCK'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh
backend = systemd
F2B_BLOCK

    systemctl enable --now fail2ban
    mark_done "step_fail2ban"
    done_step "$RMSG_SETUP_FAIL2BAN_DONE"
fi

# === 6/9 ===
if is_done "step6"; then
    skip_step "$RMSG_SETUP_STEP6_TITLE"
elif confirm_step "$RMSG_SETUP_STEP6_TITLE" "$RMSG_SETUP_STEP6_DESC"; then
    if ! command -v docker &>/dev/null; then
        curl -fsSL https://get.docker.com | sh
        usermod -aG docker "$USERNAME"
        done_step "$RMSG_SETUP_STEP6_INSTALLED"
    else
        done_step "$RMSG_SETUP_STEP6_ALREADY"
    fi

    # Rotation des logs Docker (evite que les logs remplissent le disque)
    if [ ! -f /etc/docker/daemon.json ] || ! grep -q "max-size" /etc/docker/daemon.json 2>/dev/null; then
        mkdir -p /etc/docker
        cat > /etc/docker/daemon.json << 'DOCKER_LOG_BLOCK'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    }
}
DOCKER_LOG_BLOCK
        systemctl restart docker 2>/dev/null || true
        done_step "$RMSG_SETUP_STEP6_LOG_ROTATION"
    fi

    mark_done "step6"
fi

# === 7/9 ===
if is_done "step7"; then
    skip_step "$RMSG_SETUP_STEP7_TITLE"
elif confirm_step "$RMSG_SETUP_STEP7_TITLE" "$RMSG_SETUP_STEP7_DESC"; then
    if ! command -v caddy &>/dev/null; then
        setup_caddy
        done_step "$RMSG_SETUP_STEP7_INSTALLED"
    else
        done_step "$RMSG_SETUP_STEP7_ALREADY"
    fi
    mark_done "step7"
fi

# === 8/9 ===
if is_done "step8"; then
    skip_step "$RMSG_SETUP_STEP8_TITLE"
elif confirm_step "$RMSG_SETUP_STEP8_TITLE" "$RMSG_SETUP_STEP8_DESC"; then
    setup_auto_updates
    mark_done "step8"
    done_step "$RMSG_SETUP_STEP8_DONE"
fi

# === 9/9 ===
if is_done "step9"; then
    skip_step "$RMSG_SETUP_STEP9_TITLE"
elif confirm_step "$RMSG_SETUP_STEP9_TITLE" "$RMSG_SETUP_STEP9_DESC"; then
    setup_motd
    mark_done "step9"
    done_step "$RMSG_SETUP_STEP9_DONE"
fi

# === Dossier apps ===
mkdir -p "/home/$USERNAME/apps"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/apps"

echo ""
echo "========================================="
echo -e "  ${GREEN}${RMSG_SETUP_FINAL_TITLE}${NC}"
echo "========================================="
echo ""
echo "  $(printf "$RMSG_SETUP_FINAL_DISTRO" "$DISTRO_NAME")"
echo ""
echo "  $RMSG_SETUP_FINAL_INSTALLED"
echo "    [OK] $USERNAME (sudo)"
echo "    [OK] SSH key only"
echo "    [OK] Root disabled"
echo "    [OK] Firewall (22, 80, 443)"
echo "    [OK] Fail2ban (anti-brute-force)"
echo "    [OK] Docker + log rotation"
echo "    [OK] Caddy (reverse proxy + SSL)"
echo "    [OK] Git"
echo "    [OK] Auto updates"
echo "    [OK] MOTD dashboard"
echo "========================================="
REMOTE_EOF

# =========================================
# INJECTION DES MESSAGES DE LANGUE
# =========================================

inject_lang_into_remote "$TMPSCRIPT"

# Remplacer le placeholder USERNAME (compatible macOS et Linux)
SAFE_USERNAME=$(sed_escape "$USERNAME")
if [ "$OS" = "mac" ]; then
    sed -i '' "s|__USERNAME__|$SAFE_USERNAME|g" "$TMPSCRIPT"
else
    sed -i "s|__USERNAME__|$SAFE_USERNAME|g" "$TMPSCRIPT"
fi

# Envoyer le script sur le serveur et l'exécuter (nom aleatoire pour eviter les attaques symlink)
REMOTE_TMP=$(ssh -i "$SSH_KEY" -o BatchMode=yes "${SSH_USER}@${VPS_IP}" "mktemp /tmp/vps-XXXXXXXXXX.sh")
if ! scp -i "$SSH_KEY" "$TMPSCRIPT" "${SSH_USER}@${VPS_IP}:${REMOTE_TMP}"; then
    err "$MSG_SETUP_SCP_ERR"
    rm -f "$TMPSCRIPT"
    exit 1
fi
rm -f "$TMPSCRIPT"

if [ "$USE_SUDO" = true ]; then
    ssh -t -i "$SSH_KEY" "${SSH_USER}@${VPS_IP}" "chmod 700 '${REMOTE_TMP}'; sudo bash '${REMOTE_TMP}'; rm -f '${REMOTE_TMP}'"
else
    ssh -t -i "$SSH_KEY" "${SSH_USER}@${VPS_IP}" "chmod 700 '${REMOTE_TMP}'; bash '${REMOTE_TMP}'; rm -f '${REMOTE_TMP}'"
fi

# =========================================
# PARTIE 3 : INSTRUCTIONS POST-SETUP
# =========================================

echo ""
echo -e "${BOLD}${MSG_SETUP_POSTSETUP_TITLE}${NC}"
echo ""
echo "  $MSG_SETUP_POSTSETUP_CONNECT_HINT"
echo ""
echo -e "    ${GREEN}ssh ${USERNAME}@${VPS_IP}${NC}"
echo ""

if [[ "$SSH_KEY" != "$SSH_DIR/id_ed25519" ]]; then
    echo "  $MSG_SETUP_POSTSETUP_SPECIFIC_KEY"
    echo ""
    echo -e "    ${GREEN}ssh -i ${SSH_KEY} ${USERNAME}@${VPS_IP}${NC}"
    echo ""
fi

echo "  $MSG_SETUP_POSTSETUP_SHORTCUT_OFFER"
echo "  $MSG_SETUP_POSTSETUP_SHORTCUT_EXPLAIN"
echo ""
read -p "  $MSG_SETUP_POSTSETUP_SHORTCUT_PROMPT" CREATE_CONFIG
if [[ "$CREATE_CONFIG" == "o" || "$CREATE_CONFIG" == "O" || "$CREATE_CONFIG" == "y" || "$CREATE_CONFIG" == "Y" ]]; then
    read -p "  $MSG_SETUP_POSTSETUP_ALIAS_PROMPT" SSH_ALIAS
    SSH_ALIAS=${SSH_ALIAS:-vps}

    {
        echo ""
        echo "Host $SSH_ALIAS"
        echo "    HostName ${VPS_IP}"
        echo "    User ${USERNAME}"
        echo "    IdentityFile ${SSH_KEY}"
    } >> "$SSH_DIR/config"
    chmod 600 "$SSH_DIR/config"

    success "$MSG_SETUP_POSTSETUP_SHORTCUT_OK"
    echo ""
    echo -e "    ${GREEN}ssh ${SSH_ALIAS}${NC}"
else
    info "$MSG_SETUP_POSTSETUP_SHORTCUT_SKIP"
fi

echo ""
echo "  $MSG_SETUP_POSTSETUP_APPS_DIR"
echo ""
echo "========================================="
echo -e "  ${GREEN}${MSG_SETUP_POSTSETUP_DONE_TITLE}${NC}"
echo "========================================="
