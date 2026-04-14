#!/bin/bash
set -euo pipefail

# ============================================
# Affiche l'etat du VPS et des applications
#
# Usage : bash status.sh
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

# --- Chargement de la langue ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -f "${SCRIPT_DIR}/lang.sh" ]; then
    . "${SCRIPT_DIR}/lang.sh"
else
    _LANG_TMP=$(mktemp)
    _CLEANUP_FILES+=("$_LANG_TMP")
    # shellcheck disable=SC1090
    curl -fsSL "https://raw.githubusercontent.com/mariusdjen/vpskit/main/lang.sh" -o "$_LANG_TMP" 2>/dev/null && . "$_LANG_TMP"
fi

VPS_IP=""
SSH_KEY=""
USERNAME=""

# =========================================
# MODE INTERACTIF
# =========================================

    echo ""
    echo "========================================="
    echo -e "  ${BOLD}VPS STATUS${NC}"
    echo "  $MSG_STATUS_HEADER"
    echo "========================================="
    echo ""

    SSH_DIR="$HOME/.ssh"
    LOCAL_STATE="$SSH_DIR/.vpskit-local"
    LOCAL_STATE_LEGACY="$SSH_DIR/.vps-bootstrap-local"
    if [ ! -f "$LOCAL_STATE" ] && [ -f "$LOCAL_STATE_LEGACY" ]; then
        mv "$LOCAL_STATE_LEGACY" "$LOCAL_STATE"
    fi

    if [ -f "$LOCAL_STATE" ]; then
        VPS_IP=$(read_state_var "$LOCAL_STATE" "VPS_IP")
        SSH_KEY=$(read_state_var "$LOCAL_STATE" "SSH_KEY")
        USERNAME=$(read_state_var "$LOCAL_STATE" "USERNAME")
        success "$MSG_STATUS_SESSION_FOUND"
        echo ""
        echo "    $(printf "$MSG_STATUS_SESSION_IP" "$VPS_IP")"
        echo "    $(printf "$MSG_STATUS_SESSION_KEY" "$(basename "$SSH_KEY")")"
        echo "    $(printf "$MSG_STATUS_SESSION_USER" "$USERNAME")"
        echo ""
        read -p "$MSG_STATUS_SESSION_CONFIRM" USE_SESSION
        if [[ "$USE_SESSION" != "o" && "$USE_SESSION" != "O" && "$USE_SESSION" != "y" && "$USE_SESSION" != "Y" ]]; then
            VPS_IP=""
            SSH_KEY=""
            USERNAME=""
        fi
    else
        info "$MSG_STATUS_NO_SESSION"
        echo "$MSG_STATUS_RUN_SETUP"
        echo ""
    fi

    if [ -z "$VPS_IP" ]; then
        read -p "$MSG_STATUS_PROMPT_IP" VPS_IP
    fi
    if [ -z "$SSH_KEY" ]; then
        read -p "$MSG_STATUS_PROMPT_KEY" SSH_KEY
    fi
    if [ -z "$USERNAME" ]; then
        read -p "$MSG_STATUS_PROMPT_USER" USERNAME
        USERNAME=${USERNAME:-deploy}
    fi

# =========================================
# VALIDATION
# =========================================

ERRORS=0

if [ -z "$VPS_IP" ]; then
    err "$MSG_STATUS_ERR_IP_REQUIRED"
    ERRORS=$((ERRORS + 1))
fi
if [ -z "$SSH_KEY" ] || [ ! -f "$SSH_KEY" ]; then
    err "$(printf "$MSG_STATUS_ERR_KEY_NOT_FOUND" "${SSH_KEY:-N/A}")"
    ERRORS=$((ERRORS + 1))
fi
if [ -z "$USERNAME" ]; then
    err "$MSG_STATUS_ERR_USER_REQUIRED"
    ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -gt 0 ]; then
    exit 1
fi

# --- Validation IP ---
if ! echo "$VPS_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    err "$(printf "$MSG_STATUS_ERR_IP_INVALID" "$VPS_IP")"
    echo "$MSG_STATUS_ERR_IP_FORMAT"
    exit 1
fi

# --- Test connexion SSH ---
info "$MSG_STATUS_CONNECTING"
if ! ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes "${USERNAME}@${VPS_IP}" "echo ok" &>/dev/null; then
    err "$(printf "$MSG_STATUS_ERR_CONNECT" "$USERNAME" "$VPS_IP")"
    echo ""
    echo "$MSG_STATUS_ERR_CONNECT_HINT"
    exit 1
fi

# =========================================
# GENERATION DU SCRIPT DISTANT
# =========================================

TMPSCRIPT=$(mktemp)
_CLEANUP_FILES+=("$TMPSCRIPT")
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
    read -r _ c1 c2 c3 c4 c5 c6 c7 _rest < <(head -1 /proc/stat)
    IDLE1=$c4; TOTAL1=$((c1+c2+c3+c4+c5+c6+c7))
    sleep 1
    read -r _ c1 c2 c3 c4 c5 c6 c7 _rest < <(head -1 /proc/stat)
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
echo "$RMSG_STATUS_SERVER_SECTION"
echo "    OS       : $OS_STR"
echo "    Uptime   : $UPTIME_STR"
echo "$(printf "$RMSG_STATUS_CPU_LABEL" "$CPU_USAGE" "$CPU_CORES")"
echo "    RAM      : $RAM_USED / $RAM_TOTAL (${RAM_PCT}%)"
echo "$(printf "$RMSG_STATUS_DISK_LABEL" "$DISK_USED" "$DISK_TOTAL" "$DISK_PCT")"

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
        APP_STATUS="$RMSG_STATUS_APP_STATUS_UNKNOWN"
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
                APP_STATUS="$(printf "$RMSG_STATUS_APP_STATUS_RUNNING" "$RUNNING" "$TOTAL")"
                DOCKER_RUNNING=$((DOCKER_RUNNING + RUNNING))
                STOPPED=$((TOTAL - RUNNING))
                DOCKER_STOPPED=$((DOCKER_STOPPED + STOPPED))
            else
                APP_STATUS="$RMSG_STATUS_APP_STATUS_STOPPED"
                DOCKER_STOPPED=$((DOCKER_STOPPED + TOTAL))
            fi
        elif [ -f "$APP_PATH/Dockerfile" ]; then
            APP_TYPE="dockerfile"
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${APP}$"; then
                APP_STATUS="$RMSG_STATUS_APP_STATUS_RUNNING_SIMPLE"
                DOCKER_RUNNING=$((DOCKER_RUNNING + 1))
            else
                APP_STATUS="$RMSG_STATUS_APP_STATUS_STOPPED"
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
        if echo "$APP_STATUS" | grep -q "$RMSG_STATUS_APP_STATUS_RUNNING_SIMPLE"; then
            echo -e "    Status  : ${GREEN}$APP_STATUS${NC}"
        else
            echo -e "    Status  : ${RED}$APP_STATUS${NC}"
        fi
        [ -n "$APP_TYPE" ] && echo "    Type    : $APP_TYPE"
        [ -n "$APP_DOMAIN" ] && echo "$(printf "$RMSG_STATUS_DOMAIN_LABEL" "$APP_DOMAIN")"
        [ -n "$APP_PORT" ] && echo "$(printf "$RMSG_STATUS_PORT_LABEL" "$APP_PORT")"
        echo "$(printf "$RMSG_STATUS_DIR_LABEL" "$APP_PATH")"
        [ -n "$LAST_COMMIT" ] && echo "    Commit  : $LAST_COMMIT"
    done
fi

if [ "$APP_COUNT" -eq 0 ]; then
    echo ""
    echo "$RMSG_STATUS_NO_APPS_SECTION"
    echo "$RMSG_STATUS_NO_APPS"
    echo "$RMSG_STATUS_NO_APPS_HINT"
fi

# --- Resume Docker ---
echo ""
echo "  -----------------------------------------"
TOTAL_DOCKER=$((DOCKER_RUNNING + DOCKER_STOPPED))
if command -v docker &>/dev/null; then
    printf "$RMSG_STATUS_DOCKER_SUMMARY\n" "$DOCKER_RUNNING" "$DOCKER_STOPPED"
else
    echo -e "${RED}${RMSG_STATUS_DOCKER_NOT_INSTALLED}${NC}"
fi

# --- Securite (resume) ---
echo ""
echo "  -----------------------------------------"
echo -e "${BOLD}$RMSG_STATUS_SECURITY_SECTION${NC}"

# Firewall
if command -v ufw &>/dev/null; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        echo -e "    ${GREEN}[OK]${NC}   $(printf "$RMSG_STATUS_SECURITY_FIREWALL_OK" "ufw")"
    else
        echo -e "    ${RED}[ERR]${NC}  $RMSG_STATUS_SECURITY_FIREWALL_ERR"
    fi
elif command -v firewall-cmd &>/dev/null; then
    if firewall-cmd --state 2>/dev/null | grep -q running; then
        echo -e "    ${GREEN}[OK]${NC}   $(printf "$RMSG_STATUS_SECURITY_FIREWALL_OK" "firewalld")"
    else
        echo -e "    ${RED}[ERR]${NC}  $RMSG_STATUS_SECURITY_FIREWALL_ERR"
    fi
else
    echo -e "    ${YELLOW}[WARN]${NC} $RMSG_STATUS_SECURITY_FIREWALL_NONE"
fi

# Fail2ban
if systemctl is-active fail2ban &>/dev/null; then
    BANNED=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}' || true)
    [ -z "$BANNED" ] && BANNED=$(fail2ban-client status ssh 2>/dev/null | grep "Currently banned" | awk '{print $NF}' || true)
    [ -z "$BANNED" ] && BANNED="0"
    echo -e "    ${GREEN}[OK]${NC}   $(printf "$RMSG_STATUS_SECURITY_FAIL2BAN_OK" "$BANNED")"
else
    echo -e "    ${RED}[ERR]${NC}  $RMSG_STATUS_SECURITY_FAIL2BAN_ERR"
fi

# SSH root
if grep -qE "^\s*PermitRootLogin\s+no" /etc/ssh/sshd_config 2>/dev/null; then
    echo -e "    ${GREEN}[OK]${NC}   $RMSG_STATUS_SECURITY_SSH_ROOT_OK"
else
    echo -e "    ${RED}[ERR]${NC}  $RMSG_STATUS_SECURITY_SSH_ROOT_ERR"
fi

# SSL par app (compact)
if command -v openssl &>/dev/null; then
    for SEC_APP_DIR in /home/__USERNAME__/apps/*/; do
        [ -d "$SEC_APP_DIR" ] || continue
        SEC_DOMAIN=$(cat "$SEC_APP_DIR/.deploy-domain" 2>/dev/null || true)
        [ -z "$SEC_DOMAIN" ] && continue
        SEC_EXPIRY=$(echo | timeout 5 openssl s_client -servername "$SEC_DOMAIN" -connect "$SEC_DOMAIN":443 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)
        if [ -n "$SEC_EXPIRY" ]; then
            SEC_DAYS=$(( ($(date -d "$SEC_EXPIRY" +%s 2>/dev/null || echo "0") - $(date +%s)) / 86400 ))
            if [ "$SEC_DAYS" -lt 0 ]; then
                echo -e "    ${RED}[ERR]${NC}  $(printf "$RMSG_STATUS_SECURITY_SSL_ERR" "$SEC_DOMAIN")"
            elif [ "$SEC_DAYS" -lt 30 ]; then
                echo -e "    ${YELLOW}[WARN]${NC} $(printf "$RMSG_STATUS_SECURITY_SSL_WARN" "$SEC_DOMAIN" "$SEC_DAYS")"
            else
                echo -e "    ${GREEN}[OK]${NC}   $(printf "$RMSG_STATUS_SECURITY_SSL_OK" "$SEC_DOMAIN" "$SEC_DAYS")"
            fi
        fi
    done
fi

echo "========================================="
echo ""
STATUS_EOF

# =========================================
# INJECTION DES MESSAGES DE LANGUE
# =========================================

inject_lang_into_remote "$TMPSCRIPT"

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

info "$MSG_STATUS_SENDING"
REMOTE_TMP=$(ssh -i "$SSH_KEY" -o BatchMode=yes "${USERNAME}@${VPS_IP}" "mktemp /tmp/vps-XXXXXXXXXX.sh")
if ! scp -i "$SSH_KEY" "$TMPSCRIPT" "${USERNAME}@${VPS_IP}:${REMOTE_TMP}"; then
    err "$MSG_STATUS_ERR_SEND"
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

ssh $SSH_TTY_FLAG -i "$SSH_KEY" "${USERNAME}@${VPS_IP}" "chmod 700 '${REMOTE_TMP}'; sudo bash '${REMOTE_TMP}'; rm -f '${REMOTE_TMP}'"
