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
    read -p "  Continuer ? (o/N) : " REPLY
    [[ "$REPLY" == "o" || "$REPLY" == "O" ]]
}

# Echapper les caracteres speciaux pour sed (evite l'injection de commandes)
# Echappe : \ (escape), & (back-reference), | (delimiteur)
sed_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/|/\\|/g'
}

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

echo ""
echo "========================================="
echo -e "  ${BOLD}VPS BOOTSTRAP${NC}"
echo "  Sécurise et prépare un VPS Linux"
echo "  neuf, de A à Z."
echo ""
echo "  Par Marius Djenontin"
echo "  marius-djenontin.com"
echo "========================================="
echo ""

case "$OS" in
    mac)      info "Système détecté : macOS" ;;
    linux)    info "Système détecté : Linux" ;;
    windows)  info "Système détecté : Windows (Git Bash)" ;;
    wsl)      info "Système détecté : Windows (WSL)" ;;
    *)
        err "Système non reconnu."
        echo "  Ce script fonctionne sur :"
        echo "    - macOS (Terminal)"
        echo "    - Linux (Terminal)"
        echo "    - Windows (Git Bash ou WSL)"
        echo ""
        echo "  Sur Windows sans Git Bash :"
        echo "    1. Installez Git : https://git-scm.com/download/win"
        echo "    2. Ouvrez 'Git Bash'"
        echo "    3. Relancez ce script"
        exit 1
        ;;
esac

# --- Vérifier que ssh est disponible ---
if ! command -v ssh &>/dev/null; then
    err "La commande 'ssh' n'est pas disponible."
    case "$OS" in
        windows)
            echo "  Installez Git Bash : https://git-scm.com/download/win"
            echo "  Ou activez OpenSSH : Paramètres > Applications > Fonctionnalités facultatives > OpenSSH Client"
            ;;
        *)
            echo "  Installez OpenSSH : sudo apt install openssh-client"
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
        info "Clés SSH trouvées sur votre machine :"
        echo ""
        for i in "${!KEYS[@]}"; do
            KEYNAME=$(basename "${KEYS[$i]}")
            KEYTYPE=$(awk '{print $1}' "${KEYS[$i]}.pub" | sed 's/ssh-//')
            NUM=$((i + 1))
            echo "  ${NUM}) ${KEYNAME} (${KEYTYPE})"
        done
        NEW_NUM=$((${#KEYS[@]} + 1))
        echo ""
        echo -e "  ${NEW_NUM}) ${YELLOW}Créer une nouvelle clé${NC}"
        echo ""
        read -p "  Votre choix (1-${NEW_NUM}) : " KEY_CHOICE

        if [[ "$KEY_CHOICE" == "$NEW_NUM" ]]; then
            read -p "  Nom de la nouvelle clé (défaut: vps) : " CUSTOM_KEY_NAME
            CUSTOM_KEY_NAME=${CUSTOM_KEY_NAME:-vps}
            SSH_KEY="$SSH_DIR/$CUSTOM_KEY_NAME"
            ssh-keygen -t ed25519 -C "vps-bootstrap" -f "$SSH_KEY"
            success "Nouvelle clé créée : $SSH_KEY"
        elif [[ "$KEY_CHOICE" =~ ^[0-9]+$ ]] && [ "$KEY_CHOICE" -ge 1 ] && [ "$KEY_CHOICE" -le "${#KEYS[@]}" ]; then
            SSH_KEY="${KEYS[$((KEY_CHOICE - 1))]}"
            success "Clé sélectionnée : $(basename "$SSH_KEY")"
        else
            echo -e "${RED}Choix invalide. Annulé.${NC}"
            exit 1
        fi
    else
        info "Aucune clé SSH trouvée. On va en créer une."
        echo ""
        read -p "  Nom de la clé (défaut: id_ed25519) : " CUSTOM_KEY_NAME
        if [[ -n "$CUSTOM_KEY_NAME" ]]; then
            SSH_KEY="$SSH_DIR/$CUSTOM_KEY_NAME"
        else
            SSH_KEY="$SSH_DIR/id_ed25519"
        fi
        ssh-keygen -t ed25519 -C "vps-bootstrap" -f "$SSH_KEY"
        success "Clé SSH créée : $SSH_KEY"
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
        warn "Session précédente détectée :"
        echo "    IP       : $VPS_IP"
        echo "    Clé SSH  : $(basename "$SSH_KEY")"
        echo "    User     : $USERNAME"
        echo ""
        read -p "  Reprendre cette session ? (o/N) : " RESUME_REPLY
        if [[ "$RESUME_REPLY" == "o" || "$RESUME_REPLY" == "O" ]]; then
            MODE="update"
        fi
    fi
fi

# Sinon, demander le mode
if [ -z "$MODE" ]; then
    echo ""
    echo "  1) Configurer un nouveau VPS"
    echo "  2) Mettre à jour un VPS déjà configuré"
    echo ""
    read -p "  Votre choix (1/2) : " MODE_CHOICE
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
    echo -e "${BOLD}=== PARTIE 1 : PRÉPARATION (sur votre machine) ===${NC}"

    # --- Clé SSH ---
    step "Étape 1/3 : Clé SSH" "Une clé SSH est comme un badge d'accès. Au lieu d'un mot de passe,
  votre machine prouve son identité avec cette clé. C'est plus sûr et
  impossible à deviner par un pirate."

    select_ssh_key

    echo ""
    info "Clé publique (celle qui sera envoyée au serveur) :"
    echo ""
    echo "  $(cat "${SSH_KEY}.pub")"
    echo ""

    # --- IP du serveur ---
    step "Étape 2/3 : Adresse du serveur" "Entrez l'adresse IP de votre VPS.
  Vous la trouvez dans le dashboard de votre hébergeur (Hostinger, OVH, DigitalOcean, etc.)."

    read -p "  Adresse IP du VPS : " VPS_IP

    if [[ -z "$VPS_IP" ]]; then
        err "Adresse IP requise. Annulé."
        exit 1
    fi

    if ! echo "$VPS_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        err "Adresse IP invalide : $VPS_IP"
        echo "  L'adresse doit être au format : 123.45.67.89"
        exit 1
    fi

    # --- Envoyer la clé SSH ---
    step "Étape 3/3 : Envoi de la clé SSH sur le serveur" "On va envoyer votre clé publique sur le VPS pour pouvoir
  se connecter sans mot de passe par la suite.
  Il vous demandera le mot de passe root UNE DERNIÈRE FOIS."

    if confirm; then
        if command -v ssh-copy-id &>/dev/null; then
            ssh-copy-id -i "${SSH_KEY}.pub" "root@${VPS_IP}"
        else
            info "Envoi manuel de la clé (ssh-copy-id non disponible)..."
            cat "${SSH_KEY}.pub" | ssh "root@${VPS_IP}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
        fi
        success "Clé SSH envoyée sur le serveur."
    else
        warn "Étape ignorée. Assurez-vous que votre clé est sur le serveur."
    fi

    # --- Test de connexion ---
    echo ""
    info "Test de connexion SSH..."
    if ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o BatchMode=yes "root@${VPS_IP}" "echo ok" &>/dev/null; then
        success "Connexion SSH réussie !"
    else
        err "Impossible de se connecter. Vérifiez l'IP et que la clé est bien sur le serveur."
        exit 1
    fi

    # --- Nom d'utilisateur ---
    echo ""
    echo -e "${BOLD}=== PARTIE 2 : SÉCURISATION DU VPS ===${NC}"
    echo ""

    read -p "Nom d'utilisateur à créer sur le serveur (défaut: deploy) : " USERNAME
    USERNAME=${USERNAME:-deploy}

    SSH_USER="root"
    USE_SUDO=false

# =========================================
# MODE 2 : MISE À JOUR D'UN VPS EXISTANT
# =========================================

elif [ "$MODE" = "update" ]; then

    echo ""
    echo -e "${BOLD}=== MISE À JOUR DU VPS ===${NC}"

    # Si pas de session sauvegardée, demander les infos
    if [ -z "${SSH_KEY:-}" ]; then
        echo ""
        select_ssh_key
    fi

    if [ -z "${VPS_IP:-}" ]; then
        echo ""
        read -p "  Adresse IP du VPS : " VPS_IP
        if [[ -z "$VPS_IP" ]]; then
            err "Adresse IP requise. Annulé."
            exit 1
        fi
        if ! echo "$VPS_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
            err "Adresse IP invalide : $VPS_IP"
            echo "  L'adresse doit être au format : 123.45.67.89"
            exit 1
        fi
    fi

    if [ -z "${USERNAME:-}" ]; then
        read -p "  Nom d'utilisateur sur le serveur (défaut: deploy) : " USERNAME
        USERNAME=${USERNAME:-deploy}
    fi

    # --- Test de connexion (user d'abord, root en fallback) ---
    echo ""
    info "Test de connexion au serveur..."
    if ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o BatchMode=yes "${USERNAME}@${VPS_IP}" "echo ok" &>/dev/null; then
        SSH_USER="$USERNAME"
        USE_SUDO=true
        success "Connecté en tant que $USERNAME."
    elif ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o BatchMode=yes "root@${VPS_IP}" "echo ok" &>/dev/null; then
        SSH_USER="root"
        USE_SUDO=false
        success "Connecté en tant que root."
    else
        err "Impossible de se connecter (ni $USERNAME, ni root)."
        echo "  Vérifiez l'IP, la clé SSH et le nom d'utilisateur."
        exit 1
    fi

fi

# --- Sauvegarder la session locale ---
cat > "$LOCAL_STATE" << LOCALEOF
VPS_IP="$VPS_IP"
SSH_KEY="$SSH_KEY"
USERNAME="$USERNAME"
LOCALEOF
chmod 600 "$LOCAL_STATE"

# =========================================
# PARTIE 2 : SÉCURISATION DU VPS (avec reprise)
# =========================================

# Créer le script distant dans un fichier temporaire
# (évite les conflits de parsing avec les case/esac dans $(cat << ...))
TMPSCRIPT=$(mktemp)
trap 'rm -f "$TMPSCRIPT"' EXIT
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
        DISTRO_NAME="inconnu"
    fi
}

detect_distro

if [ "$DISTRO_FAMILY" = "unknown" ]; then
    err "Distribution non supportée : ${DISTRO_NAME}"
    echo "  Distributions supportées :"
    echo "    - Ubuntu, Debian (famille APT)"
    echo "    - AlmaLinux, Rocky Linux, CentOS, Fedora (famille DNF)"
    exit 1
fi

echo -e "${BLUE}[INFO] Distribution détectée : ${DISTRO_NAME} (famille ${DISTRO_FAMILY})${NC}"

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
    DOCKER_LINE="  Docker     : ${DOCKER_COUNT} conteneur(s) actif(s)"
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
echo "  CPU        : ${CPU_CORES} coeur(s)"
echo -e "  RAM        : ${RAM_USED} Mo / ${RAM_TOTAL} Mo ($(color_pct $RAM_PCT))"
echo -e "  Swap       : ${SWAP_USED} Mo / ${SWAP_TOTAL} Mo ($(color_pct $SWAP_PCT))"
echo -e "  Disque     : ${DISK_USED} / ${DISK_TOTAL} ($(color_pct $DISK_PCT))"
echo ""
echo "  IP         : ${IP}"
if [ -n "$DOCKER_LINE" ]; then
    echo "$DOCKER_LINE"
fi
echo "========================================="
echo ""
'

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
    read -p "  Exécuter ? (o/N) : " REPLY
    [[ "$REPLY" == "o" || "$REPLY" == "O" ]]
}

done_step() {
    echo -e "  ${GREEN}[OK] $1${NC}"
}

skip_step() {
    echo -e "  ${GREEN}[OK] $1 (déjà fait)${NC}"
}

# =========================================
# ÉTAPES DE SÉCURISATION
# =========================================

# === 1/9 ===
if is_done "step1"; then
    skip_step "Étape 1/9 : Mise à jour système"
elif confirm_step "Étape 1/9 : Mise à jour système" "Met à jour tous les paquets et installe git, curl, wget."; then
    pkg_update
    pkg_install git curl wget
    mark_done "step1"
    done_step "Système à jour, git/curl/wget installés."
fi

# === 2/9 ===
if is_done "step2"; then
    skip_step "Étape 2/9 : Création utilisateur $USERNAME"
elif confirm_step "Étape 2/9 : Création utilisateur $USERNAME" "Crée un utilisateur non-root avec accès sudo."; then
    if ! id "$USERNAME" &>/dev/null; then
        create_user "$USERNAME"
        done_step "Utilisateur $USERNAME créé avec sudo."
    else
        echo -e "  ${BLUE}[INFO] L'utilisateur $USERNAME existe déjà. Vérification des droits...${NC}"
        SUDO_GRP=$(sudo_group)
        if ! groups "$USERNAME" | grep -q "$SUDO_GRP"; then
            usermod -aG "$SUDO_GRP" "$USERNAME"
            echo -e "  ${BLUE}[INFO] Ajouté au groupe $SUDO_GRP.${NC}"
        fi
        if [ ! -f "/etc/sudoers.d/$USERNAME" ]; then
            echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USERNAME"
            chmod 440 "/etc/sudoers.d/$USERNAME"
            echo -e "  ${BLUE}[INFO] Configuration sudoers ajoutée.${NC}"
        fi
        done_step "Utilisateur $USERNAME prêt (existait déjà, droits vérifiés)."
    fi
    mark_done "step2"
fi

# === 3/9 ===
if is_done "step3"; then
    skip_step "Étape 3/9 : Copie clé SSH vers $USERNAME"
elif confirm_step "Étape 3/9 : Copie clé SSH vers $USERNAME" "Copie votre clé SSH pour que $USERNAME puisse se connecter."; then
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
    done_step "Clé SSH copiée vers $USERNAME."
fi

# === 4/9 ===
if is_done "step4"; then
    skip_step "Étape 4/9 : Durcissement SSH"
elif confirm_step "Étape 4/9 : Durcissement SSH" "Désactive l'accès root et l'authentification par mot de passe. Après ça, seule votre clé SSH permet de se connecter."; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    if sshd -t 2>/dev/null; then
        restart_ssh
        mark_done "step4"
        done_step "SSH durci : root désactivé, mot de passe désactivé."
    else
        echo -e "${RED}[ERR] Configuration SSH invalide. Restauration...${NC}"
        cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
        restart_ssh
        echo -e "${YELLOW}[WARN] Configuration SSH restaurée. Le durcissement n'a pas été appliqué.${NC}"
    fi
fi

# === 5/9 ===
if is_done "step5"; then
    skip_step "Étape 5/9 : Firewall"
elif confirm_step "Étape 5/9 : Firewall" "Bloque tout sauf SSH (22), HTTP (80), HTTPS (443). Vos bases de données et apps restent invisibles de l'extérieur."; then
    setup_firewall
    mark_done "step5"
    done_step "Firewall activé : ports 22, 80, 443."
fi

# === Fail2ban ===
if is_done "step_fail2ban"; then
    skip_step "Fail2ban (protection anti-brute-force)"
elif confirm_step "Fail2ban (protection anti-brute-force)" "Bloque automatiquement les IP qui tentent trop de connexions SSH echouees (5 tentatives max, ban 1h)."; then
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
    done_step "Fail2ban active : 5 tentatives max, ban 1h."
fi

# === 6/9 ===
if is_done "step6"; then
    skip_step "Étape 6/9 : Installation Docker"
elif confirm_step "Étape 6/9 : Installation Docker" "Installe Docker pour faire tourner vos applications dans des conteneurs isolés."; then
    if ! command -v docker &>/dev/null; then
        curl -fsSL https://get.docker.com | sh
        usermod -aG docker "$USERNAME"
        done_step "Docker installé."
    else
        done_step "Docker déjà installé."
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
        done_step "Rotation des logs Docker configuree (10 Mo x 3 fichiers)."
    fi

    mark_done "step6"
fi

# === 7/9 ===
if is_done "step7"; then
    skip_step "Étape 7/9 : Installation Caddy"
elif confirm_step "Étape 7/9 : Installation Caddy (reverse proxy)" "Caddy redirige vos domaines vers vos apps et gère les certificats SSL (HTTPS) automatiquement."; then
    if ! command -v caddy &>/dev/null; then
        setup_caddy
        done_step "Caddy installé."
    else
        done_step "Caddy déjà installé."
    fi
    mark_done "step7"
fi

# === 8/9 ===
if is_done "step8"; then
    skip_step "Étape 8/9 : Mises à jour automatiques"
elif confirm_step "Étape 8/9 : Mises à jour automatiques" "Le serveur installera les patchs de sécurité tout seul, sans redémarrer."; then
    setup_auto_updates
    mark_done "step8"
    done_step "Mises à jour automatiques activées."
fi

# === 9/9 ===
if is_done "step9"; then
    skip_step "Étape 9/9 : Dashboard de connexion (MOTD)"
elif confirm_step "Étape 9/9 : Dashboard de connexion (MOTD)" "Affiche l'état du serveur (CPU, RAM, disque, Docker) à chaque connexion SSH."; then
    setup_motd
    mark_done "step9"
    done_step "Dashboard MOTD installé."
fi

# === Dossier apps ===
mkdir -p "/home/$USERNAME/apps"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/apps"

echo ""
echo "========================================="
echo -e "  ${GREEN}SERVEUR SÉCURISÉ !${NC}"
echo "========================================="
echo ""
echo "  Distribution : $DISTRO_NAME"
echo ""
echo "  Installé :"
echo "    [OK] Utilisateur $USERNAME (sudo)"
echo "    [OK] SSH par clé uniquement"
echo "    [OK] Root désactivé"
echo "    [OK] Firewall (22, 80, 443)"
echo "    [OK] Fail2ban (anti-brute-force)"
echo "    [OK] Docker + rotation des logs"
echo "    [OK] Caddy (reverse proxy + SSL)"
echo "    [OK] Git"
echo "    [OK] Mises à jour automatiques"
echo "    [OK] Dashboard MOTD (état serveur à la connexion)"
echo "========================================="
REMOTE_EOF

# Remplacer le placeholder USERNAME (compatible macOS et Linux)
SAFE_USERNAME=$(sed_escape "$USERNAME")
if [ "$OS" = "mac" ]; then
    sed -i '' "s|__USERNAME__|$SAFE_USERNAME|g" "$TMPSCRIPT"
else
    sed -i "s|__USERNAME__|$SAFE_USERNAME|g" "$TMPSCRIPT"
fi

# Envoyer le script sur le serveur et l'exécuter
if ! scp -i "$SSH_KEY" "$TMPSCRIPT" "${SSH_USER}@${VPS_IP}:/tmp/vps-bootstrap-remote.sh"; then
    err "Impossible d'envoyer le script sur le serveur. Vérifiez la connexion."
    rm -f "$TMPSCRIPT"
    exit 1
fi
rm -f "$TMPSCRIPT"

if [ "$USE_SUDO" = true ]; then
    ssh -t -i "$SSH_KEY" "${SSH_USER}@${VPS_IP}" "chmod 700 /tmp/vps-bootstrap-remote.sh; sudo bash /tmp/vps-bootstrap-remote.sh; rm -f /tmp/vps-bootstrap-remote.sh"
else
    ssh -t -i "$SSH_KEY" "${SSH_USER}@${VPS_IP}" "chmod 700 /tmp/vps-bootstrap-remote.sh; bash /tmp/vps-bootstrap-remote.sh; rm -f /tmp/vps-bootstrap-remote.sh"
fi

# =========================================
# PARTIE 3 : INSTRUCTIONS POST-SETUP
# =========================================

echo ""
echo -e "${BOLD}=== PARTIE 3 : C'EST TERMINÉ ! ===${NC}"
echo ""
echo "  Pour vous connecter au serveur :"
echo ""
echo -e "    ${GREEN}ssh ${USERNAME}@${VPS_IP}${NC}"
echo ""

if [[ "$SSH_KEY" != "$SSH_DIR/id_ed25519" ]]; then
    echo "  (avec votre clé spécifique) :"
    echo ""
    echo -e "    ${GREEN}ssh -i ${SSH_KEY} ${USERNAME}@${VPS_IP}${NC}"
    echo ""
fi

echo "  Voulez-vous simplifier la connexion ?"
echo "  On peut ajouter un raccourci pour taper juste : ssh vps"
echo ""
read -p "  Créer le raccourci ? (o/N) : " CREATE_CONFIG
if [[ "$CREATE_CONFIG" == "o" || "$CREATE_CONFIG" == "O" ]]; then
    read -p "  Nom du raccourci (défaut: vps) : " SSH_ALIAS
    SSH_ALIAS=${SSH_ALIAS:-vps}

    {
        echo ""
        echo "Host $SSH_ALIAS"
        echo "    HostName ${VPS_IP}"
        echo "    User ${USERNAME}"
        echo "    IdentityFile ${SSH_KEY}"
    } >> "$SSH_DIR/config"
    chmod 600 "$SSH_DIR/config"

    success "Raccourci créé ! Connectez-vous avec :"
    echo ""
    echo -e "    ${GREEN}ssh ${SSH_ALIAS}${NC}"
else
    info "Pas de raccourci créé."
fi

echo ""
echo "  Vos apps se déploient dans : ~/apps/"
echo ""
echo "========================================="
echo -e "  ${GREEN}SETUP COMPLET !${NC}"
echo "========================================="
