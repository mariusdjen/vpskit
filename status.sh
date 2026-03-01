#!/bin/bash
set -euo pipefail

# ============================================
# Affiche l'etat du VPS et des applications
#
# Usage interactif : bash status.sh
# Usage CI/CD :      bash status.sh -ip IP -key CLE -user USER
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

# Echapper les caracteres speciaux pour sed
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
# DETECTION OS LOCAL
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

# =========================================
# ARGUMENTS (MODE CI/CD)
# =========================================

VPS_IP=""
SSH_KEY=""
USERNAME=""
INTERACTIVE=true

while [ $# -gt 0 ]; do
    case "$1" in
        -ip)     VPS_IP="$2"; shift 2; INTERACTIVE=false ;;
        -key)    SSH_KEY="$2"; shift 2 ;;
        -user)   USERNAME="$2"; shift 2 ;;
        *)
            err "Argument inconnu : $1"
            echo "  Usage : bash status.sh -ip IP -key CLE -user USER"
            exit 1
            ;;
    esac
done

# =========================================
# MODE INTERACTIF
# =========================================

if [ "$INTERACTIVE" = true ]; then

    echo ""
    echo "========================================="
    echo -e "  ${BOLD}VPS STATUS${NC}"
    echo "  Affiche l'etat de votre VPS"
    echo "========================================="
    echo ""

    SSH_DIR="$HOME/.ssh"
    LOCAL_STATE="$SSH_DIR/.vps-bootstrap-local"

    if [ -f "$LOCAL_STATE" ]; then
        VPS_IP=$(read_state_var "$LOCAL_STATE" "VPS_IP")
        SSH_KEY=$(read_state_var "$LOCAL_STATE" "SSH_KEY")
        USERNAME=$(read_state_var "$LOCAL_STATE" "USERNAME")
        success "Session vps-bootstrap detectee :"
        echo ""
        echo "    Serveur  : $VPS_IP"
        echo "    Cle SSH  : $(basename "$SSH_KEY")"
        echo "    User     : $USERNAME"
        echo ""
        read -p "  C'est bien votre serveur ? (o/N) : " USE_SESSION
        if [[ "$USE_SESSION" != "o" && "$USE_SESSION" != "O" ]]; then
            VPS_IP=""
            SSH_KEY=""
            USERNAME=""
        fi
    else
        info "Aucune session vps-bootstrap trouvee."
        echo "  Lancez d'abord setup.sh pour configurer votre VPS."
        echo ""
    fi

    if [ -z "$VPS_IP" ]; then
        read -p "  Adresse IP du VPS : " VPS_IP
    fi
    if [ -z "$SSH_KEY" ]; then
        read -p "  Chemin de la cle SSH (ex: ~/.ssh/id_ed25519) : " SSH_KEY
    fi
    if [ -z "$USERNAME" ]; then
        read -p "  Nom d'utilisateur sur le VPS (defaut: deploy) : " USERNAME
        USERNAME=${USERNAME:-deploy}
    fi
fi

# =========================================
# VALIDATION
# =========================================

ERRORS=0

if [ -z "$VPS_IP" ]; then
    err "Adresse IP requise."
    ERRORS=$((ERRORS + 1))
fi
if [ -z "$SSH_KEY" ] || [ ! -f "$SSH_KEY" ]; then
    err "Cle SSH introuvable : ${SSH_KEY:-non specifiee}"
    ERRORS=$((ERRORS + 1))
fi
if [ -z "$USERNAME" ]; then
    err "Nom d'utilisateur requis."
    ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -gt 0 ]; then
    exit 1
fi

# --- Validation IP ---
if ! echo "$VPS_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    err "Adresse IP invalide : $VPS_IP"
    echo "  L'adresse doit etre au format : 123.45.67.89"
    exit 1
fi

# --- Test connexion SSH ---
info "Connexion au serveur..."
if ! ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes "${USERNAME}@${VPS_IP}" "echo ok" &>/dev/null; then
    err "Impossible de se connecter a ${USERNAME}@${VPS_IP}"
    echo ""
    echo "  Verifiez l'IP, la cle SSH et le nom d'utilisateur."
    exit 1
fi

# =========================================
# GENERATION DU SCRIPT DISTANT
# =========================================

TMPSCRIPT=$(mktemp)
trap 'rm -f "$TMPSCRIPT"' EXIT
cat > "$TMPSCRIPT" << 'STATUS_EOF'
#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

USERNAME="__USERNAME__"

# --- Infos serveur ---
HOSTNAME_STR=$(hostname)
OS_STR=$(. /etc/os-release && echo "$PRETTY_NAME")
UPTIME_STR=$(uptime -p 2>/dev/null | sed 's/up //' || echo "N/A")

CPU_CORES=$(nproc)
# Calcul CPU portable via /proc/stat (moyenne sur 1 seconde)
if [ -f /proc/stat ]; then
    read -r _ c1 c2 c3 c4 c5 c6 c7 < <(head -1 /proc/stat)
    IDLE1=$c4; TOTAL1=$((c1+c2+c3+c4+c5+c6+c7))
    sleep 1
    read -r _ c1 c2 c3 c4 c5 c6 c7 < <(head -1 /proc/stat)
    IDLE2=$c4; TOTAL2=$((c1+c2+c3+c4+c5+c6+c7))
    DIFF_IDLE=$((IDLE2 - IDLE1))
    DIFF_TOTAL=$((TOTAL2 - TOTAL1))
    if [ "$DIFF_TOTAL" -gt 0 ]; then
        CPU_USAGE=$((100 * (DIFF_TOTAL - DIFF_IDLE) / DIFF_TOTAL))
    else
        CPU_USAGE=0
    fi
else
    CPU_USAGE="N/A"
fi

RAM_TOTAL=$(free -h | awk '/Mem:/ {print $2}')
RAM_USED=$(free -h | awk '/Mem:/ {print $3}')
RAM_PCT=$(free | awk '/Mem:/ { if ($2 > 0) printf "%d", $3/$2*100; else print "0" }')

DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
DISK_PCT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "N/A")

echo ""
echo "========================================="
echo -e "  ${BOLD}VPS STATUS${NC} - $SERVER_IP"
echo "========================================="
echo ""
echo "  Serveur :"
echo "    OS       : $OS_STR"
echo "    Uptime   : $UPTIME_STR"
echo "    CPU      : ${CPU_USAGE}% (${CPU_CORES} coeurs)"
echo "    RAM      : $RAM_USED / $RAM_TOTAL (${RAM_PCT}%)"
echo "    Disque   : $DISK_USED / $DISK_TOTAL (${DISK_PCT}%)"

# --- Applications ---
APPS_DIR="/home/$USERNAME/apps"
APP_COUNT=0
DOCKER_RUNNING=0
DOCKER_STOPPED=0

if [ -d "$APPS_DIR" ]; then
    for APP_PATH in "$APPS_DIR"/*/; do
        [ -d "$APP_PATH" ] || continue
        APP=$(basename "$APP_PATH")
        APP_COUNT=$((APP_COUNT + 1))

        # Status Docker
        APP_STATUS="Inconnu"
        APP_TYPE=""
        COMPOSE_FOUND=""
        for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
            if [ -f "$APP_PATH/$f" ]; then
                COMPOSE_FOUND="$f"
                break
            fi
        done

        if [ -n "$COMPOSE_FOUND" ]; then
            APP_TYPE="docker compose"
            RUNNING=$(cd "$APP_PATH" && docker compose ps --format '{{.State}}' 2>/dev/null | grep -c "running" || echo "0")
            TOTAL=$(cd "$APP_PATH" && docker compose ps --format '{{.State}}' 2>/dev/null | grep -c '.' || echo "0")
            if [ "$RUNNING" -gt 0 ] 2>/dev/null; then
                APP_STATUS="En cours ($RUNNING/$TOTAL conteneurs)"
                DOCKER_RUNNING=$((DOCKER_RUNNING + RUNNING))
                STOPPED=$((TOTAL - RUNNING))
                DOCKER_STOPPED=$((DOCKER_STOPPED + STOPPED))
            else
                APP_STATUS="Arrete"
                DOCKER_STOPPED=$((DOCKER_STOPPED + TOTAL))
            fi
        elif [ -f "$APP_PATH/Dockerfile" ]; then
            APP_TYPE="dockerfile"
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${APP}$"; then
                APP_STATUS="En cours"
                DOCKER_RUNNING=$((DOCKER_RUNNING + 1))
            else
                APP_STATUS="Arrete"
                if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${APP}$"; then
                    DOCKER_STOPPED=$((DOCKER_STOPPED + 1))
                fi
            fi
        fi

        # Domaine depuis Caddyfile
        APP_DOMAIN=""
        if [ -f /etc/caddy/Caddyfile ]; then
            APP_PORT_LINE=$(grep -B1 "reverse_proxy localhost:" /etc/caddy/Caddyfile 2>/dev/null || true)
            # Chercher le domaine associe a cette app
            if [ -f "$APP_PATH/.deploy-domain" ]; then
                APP_DOMAIN=$(cat "$APP_PATH/.deploy-domain" 2>/dev/null || true)
            else
                # Essayer de trouver dans le Caddyfile par le port
                APP_DOMAIN=""
            fi
        fi

        # Port
        APP_PORT=""
        if [ -f "$APP_PATH/.deploy-port" ]; then
            APP_PORT=$(cat "$APP_PATH/.deploy-port" 2>/dev/null || true)
        fi

        # Dernier commit
        LAST_COMMIT=""
        if [ -d "$APP_PATH/.git" ]; then
            LAST_COMMIT=$(cd "$APP_PATH" && git log -1 --format="%h - %s (%cr)" 2>/dev/null || true)
        fi

        # Affichage
        echo ""
        echo "  -----------------------------------------"
        echo -e "  ${BOLD}$APP${NC}"
        if echo "$APP_STATUS" | grep -q "En cours"; then
            echo -e "    Status  : ${GREEN}$APP_STATUS${NC}"
        else
            echo -e "    Status  : ${RED}$APP_STATUS${NC}"
        fi
        [ -n "$APP_TYPE" ] && echo "    Type    : $APP_TYPE"
        [ -n "$APP_DOMAIN" ] && echo "    Domaine : $APP_DOMAIN"
        [ -n "$APP_PORT" ] && echo "    Port    : $APP_PORT"
        echo "    Dossier : $APP_PATH"
        [ -n "$LAST_COMMIT" ] && echo "    Commit  : $LAST_COMMIT"
    done
fi

if [ "$APP_COUNT" -eq 0 ]; then
    echo ""
    echo "  Applications :"
    echo "    Aucune application deployee."
    echo "    Utilisez deploy.sh pour deployer votre premiere app."
fi

# --- Resume Docker ---
echo ""
echo "  -----------------------------------------"
TOTAL_DOCKER=$((DOCKER_RUNNING + DOCKER_STOPPED))
if command -v docker &>/dev/null; then
    echo "  Docker : $DOCKER_RUNNING conteneur(s) actif(s), $DOCKER_STOPPED arrete(s)"
else
    echo -e "  Docker : ${RED}non installe${NC}"
fi
echo "========================================="
echo ""
STATUS_EOF

# =========================================
# REMPLACEMENT DES PLACEHOLDERS
# =========================================

SAFE_USER=$(sed_escape "$USERNAME")
if [ "$OS" = "mac" ]; then
    sed -i '' "s|__USERNAME__|$SAFE_USER|g" "$TMPSCRIPT"
else
    sed -i "s|__USERNAME__|$SAFE_USER|g" "$TMPSCRIPT"
fi

# =========================================
# ENVOI ET EXECUTION
# =========================================

info "Envoi du script de status..."
if ! scp -i "$SSH_KEY" "$TMPSCRIPT" "${USERNAME}@${VPS_IP}:/tmp/vps-status-remote.sh"; then
    err "Impossible d'envoyer le script sur le serveur."
    rm -f "$TMPSCRIPT"
    exit 1
fi
rm -f "$TMPSCRIPT"

# Detection TTY pour compatibilite CI/CD
if [ -t 0 ]; then
    SSH_TTY_FLAG="-t"
else
    SSH_TTY_FLAG=""
fi

ssh $SSH_TTY_FLAG -i "$SSH_KEY" "${USERNAME}@${VPS_IP}" "chmod 700 /tmp/vps-status-remote.sh; sudo bash /tmp/vps-status-remote.sh; rm -f /tmp/vps-status-remote.sh"
