#!/bin/bash
set -euo pipefail

# ============================================
# Audit de securite du VPS
#
# Usage interactif : bash security.sh
# Usage CI/CD :      bash security.sh -ip IP -key CLE -user USER
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
            err "$(printf "$MSG_SECURITY_UNKNOWN_ARG" "$1")"
            echo "$MSG_SECURITY_USAGE"
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
    echo -e "  ${BOLD}VPS SECURITY${NC}"
    echo "  $MSG_SECURITY_HEADER"
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
        success "$MSG_SECURITY_SESSION_FOUND"
        echo ""
        echo "    $(printf "$MSG_SECURITY_SESSION_IP" "$VPS_IP")"
        echo "    $(printf "$MSG_SECURITY_SESSION_KEY" "$(basename "$SSH_KEY")")"
        echo "    $(printf "$MSG_SECURITY_SESSION_USER" "$USERNAME")"
        echo ""
        read -p "$MSG_SECURITY_SESSION_CONFIRM" USE_SESSION
        if [[ "$USE_SESSION" != "o" && "$USE_SESSION" != "O" && "$USE_SESSION" != "y" && "$USE_SESSION" != "Y" ]]; then
            VPS_IP=""
            SSH_KEY=""
            USERNAME=""
        fi
    else
        info "$MSG_SECURITY_NO_SESSION"
        echo "$MSG_SECURITY_RUN_SETUP"
        echo ""
    fi

    if [ -z "$VPS_IP" ]; then
        read -p "$MSG_SECURITY_PROMPT_IP" VPS_IP
    fi
    if [ -z "$SSH_KEY" ]; then
        read -p "$MSG_SECURITY_PROMPT_KEY" SSH_KEY
    fi
    if [ -z "$USERNAME" ]; then
        read -p "$MSG_SECURITY_PROMPT_USER" USERNAME
        USERNAME=${USERNAME:-deploy}
    fi
fi

# =========================================
# VALIDATION
# =========================================

ERRORS=0

if [ -z "$VPS_IP" ]; then
    err "$MSG_SECURITY_ERR_IP_REQUIRED"
    ERRORS=$((ERRORS + 1))
fi
if [ -z "$SSH_KEY" ] || [ ! -f "$SSH_KEY" ]; then
    err "$(printf "$MSG_SECURITY_ERR_KEY_NOT_FOUND" "${SSH_KEY:-N/A}")"
    ERRORS=$((ERRORS + 1))
fi
if [ -z "$USERNAME" ]; then
    err "$MSG_SECURITY_ERR_USER_REQUIRED"
    ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -gt 0 ]; then
    exit 1
fi

# --- Validation IP ---
if ! echo "$VPS_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    err "$(printf "$MSG_SECURITY_ERR_IP_INVALID" "$VPS_IP")"
    echo "$MSG_SECURITY_ERR_IP_FORMAT"
    exit 1
fi

# --- Test connexion SSH ---
info "$MSG_SECURITY_CONNECTING"
SSH_USER="$USERNAME"
if ! ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes "${SSH_USER}@${VPS_IP}" "echo ok" &>/dev/null; then
    warn "$(printf "$MSG_SECURITY_WARN_USER_FAILED" "$USERNAME")"
    info "$MSG_SECURITY_TRYING_ROOT"
    if ! ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes "root@${VPS_IP}" "echo ok" &>/dev/null; then
        err "$(printf "$MSG_SECURITY_ERR_CONNECT" "$USERNAME" "$VPS_IP")"
        echo ""
        echo "$MSG_SECURITY_ERR_CONNECT_HINT"
        exit 1
    fi
    SSH_USER="root"
    warn "$MSG_SECURITY_CONNECTED_AS_ROOT"
fi

# =========================================
# GENERATION DU SCRIPT DISTANT
# =========================================

TMPSCRIPT=$(mktemp)
_CLEANUP_FILES+=("$TMPSCRIPT")
cat > "$TMPSCRIPT" << 'SECURITY_EOF'
#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

USERNAME="__USERNAME__"
SCORE=0
TOTAL=0

check_ok()   { TOTAL=$((TOTAL + 1)); SCORE=$((SCORE + 1)); echo -e "    ${GREEN}[OK]${NC}   $1"; }
check_warn() { TOTAL=$((TOTAL + 1)); echo -e "    ${YELLOW}[WARN]${NC} $1"; }
check_err()  { TOTAL=$((TOTAL + 1)); echo -e "    ${RED}[ERR]${NC}  $1"; }
check_info() { echo -e "    ${BLUE}[INFO]${NC} $1"; }

# --- Detection distribution ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
else
    DISTRO_ID="unknown"
fi

case "$DISTRO_ID" in
    ubuntu|debian) DISTRO_FAMILY="debian" ;;
    almalinux|rocky|centos|fedora|rhel) DISTRO_FAMILY="rhel" ;;
    *) DISTRO_FAMILY="unknown" ;;
esac

echo ""
echo "========================================="
echo -e "  ${BOLD}$RMSG_SECURITY_TITLE${NC}"
echo "========================================="

# =========================================
# SSH
# =========================================

echo ""
echo -e "${BOLD}$RMSG_SECURITY_SSH_SECTION${NC}"

SSHD_CONFIG="/etc/ssh/sshd_config"

if grep -qE "^\s*PermitRootLogin\s+no" "$SSHD_CONFIG" 2>/dev/null; then
    check_ok "$RMSG_SECURITY_SSH_ROOT_OK"
else
    check_err "$RMSG_SECURITY_SSH_ROOT_ERR"
fi

if grep -qE "^\s*PasswordAuthentication\s+no" "$SSHD_CONFIG" 2>/dev/null; then
    check_ok "$RMSG_SECURITY_SSH_PASSWORD_OK"
else
    check_err "$RMSG_SECURITY_SSH_PASSWORD_ERR"
fi

if grep -qE "^\s*PubkeyAuthentication\s+yes" "$SSHD_CONFIG" 2>/dev/null; then
    check_ok "$RMSG_SECURITY_SSH_PUBKEY_OK"
else
    check_warn "$RMSG_SECURITY_SSH_PUBKEY_WARN"
fi

# =========================================
# FIREWALL
# =========================================

echo ""
echo -e "${BOLD}$RMSG_SECURITY_FIREWALL_SECTION${NC}"

FW_FOUND=0
if command -v ufw &>/dev/null; then
    FW_FOUND=1
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        check_ok "$(printf "$RMSG_SECURITY_FIREWALL_ACTIVE_OK" "ufw")"
    else
        check_err "$RMSG_SECURITY_FIREWALL_INACTIVE_ERR"
    fi
elif command -v firewall-cmd &>/dev/null; then
    FW_FOUND=1
    if firewall-cmd --state 2>/dev/null | grep -q running; then
        check_ok "$(printf "$RMSG_SECURITY_FIREWALL_ACTIVE_OK" "firewalld")"
    else
        check_err "$RMSG_SECURITY_FIREWALL_INACTIVE_ERR"
    fi
fi

if [ "$FW_FOUND" -eq 0 ]; then
    check_err "$RMSG_SECURITY_FIREWALL_NOT_INSTALLED"
fi

# Fallback pour nouvelles variables (compatibilite cache langue)
: "${RMSG_SECURITY_PORT_PUBLIC:=Port %s exposed publicly (0.0.0.0) - %s}"
: "${RMSG_SECURITY_PORT_LOCAL:=Port %s local only (127.0.0.1) - %s}"

# Ports ouverts inattendus (distinguer public vs local)
if command -v ss &>/dev/null; then
    ss -tlnp 2>/dev/null | awk 'NR>1 {
        split($4, addr, ":")
        port = addr[length(addr)]
        bind = substr($4, 1, length($4)-length(port)-1)
        proc = $0
        gsub(/.*users:\(\("/, "", proc)
        gsub(/".*/, "", proc)
        print port, bind, proc
    }' | sort -t' ' -k1,1 -un | while read -r PORT BIND PROC; do
        case "$PORT" in
            22|80|443) ;;
            *)
                if echo "$BIND" | grep -qE '^(127\.|::1|\[::1\])'; then
                    check_ok "$(printf "$RMSG_SECURITY_PORT_LOCAL" "$PORT" "$PROC")"
                else
                    check_warn "$(printf "$RMSG_SECURITY_PORT_PUBLIC" "$PORT" "$PROC")"
                fi
                ;;
        esac
    done
fi

# =========================================
# FAIL2BAN
# =========================================

echo ""
echo -e "${BOLD}$RMSG_SECURITY_FAIL2BAN_SECTION${NC}"

if systemctl is-active fail2ban &>/dev/null; then
    check_ok "$RMSG_SECURITY_FAIL2BAN_ACTIVE_OK"

    # IP bannies (tester sshd puis ssh)
    BANNED=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}' || true)
    [ -z "$BANNED" ] && BANNED=$(fail2ban-client status ssh 2>/dev/null | grep "Currently banned" | awk '{print $NF}' || true)
    [ -z "$BANNED" ] && BANNED="0"
    check_info "$(printf "$RMSG_SECURITY_FAIL2BAN_BANNED" "$BANNED")"

    # Tentatives echouees 24h
    FAILED_24H=$(journalctl --since "24 hours ago" 2>/dev/null | grep -c "Failed password" || echo "0")
    if [ "$FAILED_24H" -gt 50 ]; then
        check_warn "$(printf "$RMSG_SECURITY_FAIL2BAN_FAILED_24H" "$FAILED_24H")"
    else
        check_info "$(printf "$RMSG_SECURITY_FAIL2BAN_FAILED_24H" "$FAILED_24H")"
    fi
else
    check_err "$RMSG_SECURITY_FAIL2BAN_INACTIVE_ERR"
fi

# =========================================
# SYSTEME
# =========================================

echo ""
echo -e "${BOLD}$RMSG_SECURITY_SYSTEM_SECTION${NC}"

# Mises a jour en attente
if [ "$DISTRO_FAMILY" = "debian" ]; then
    apt update -qq 2>/dev/null
    PENDING=$(apt list --upgradable 2>/dev/null | grep -c "upgradable" || echo "0")
elif [ "$DISTRO_FAMILY" = "rhel" ]; then
    PENDING=$(dnf check-update --quiet 2>/dev/null | grep -cE "^[a-zA-Z]" || echo "0")
else
    PENDING="N/A"
fi

if [ "$PENDING" = "0" ]; then
    check_ok "$RMSG_SECURITY_UPDATES_NONE"
else
    check_warn "$(printf "$RMSG_SECURITY_UPDATES_PENDING" "$PENDING")"
fi

# Mises a jour automatiques
AUTO_UPDATES=0
if [ "$DISTRO_FAMILY" = "debian" ]; then
    if dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
        AUTO_UPDATES=1
    fi
elif [ "$DISTRO_FAMILY" = "rhel" ]; then
    if systemctl is-active dnf-automatic.timer &>/dev/null; then
        AUTO_UPDATES=1
    fi
fi

if [ "$AUTO_UPDATES" -eq 1 ]; then
    check_ok "$RMSG_SECURITY_AUTO_UPDATES_OK"
else
    check_err "$RMSG_SECURITY_AUTO_UPDATES_ERR"
fi

# Uptime
UPTIME_DAYS=$(awk '{print int($1/86400)}' /proc/uptime 2>/dev/null || echo "0")
if [ "$UPTIME_DAYS" -gt 90 ]; then
    check_warn "$(printf "$RMSG_SECURITY_UPTIME_WARN" "$UPTIME_DAYS")"
else
    check_ok "$(printf "$RMSG_SECURITY_UPTIME_OK" "$UPTIME_DAYS")"
fi

# =========================================
# DOCKER
# =========================================

echo ""
echo -e "${BOLD}$RMSG_SECURITY_DOCKER_SECTION${NC}"

if command -v docker &>/dev/null; then
    # Log rotation
    if [ -f /etc/docker/daemon.json ] && grep -q "max-size" /etc/docker/daemon.json 2>/dev/null; then
        check_ok "$RMSG_SECURITY_DOCKER_LOG_OK"
    else
        check_err "$RMSG_SECURITY_DOCKER_LOG_ERR"
    fi

    # Socket permissions
    if [ -S /var/run/docker.sock ]; then
        SOCK_PERMS=$(stat -c "%a" /var/run/docker.sock 2>/dev/null || echo "unknown")
        if [ "$SOCK_PERMS" = "660" ] || [ "$SOCK_PERMS" = "600" ]; then
            check_ok "$RMSG_SECURITY_DOCKER_SOCKET_OK"
        else
            check_warn "$(printf "$RMSG_SECURITY_DOCKER_SOCKET_WARN" "$SOCK_PERMS")"
        fi
    fi
else
    check_info "$RMSG_SECURITY_DOCKER_NOT_INSTALLED"
fi

# =========================================
# CERTIFICATS SSL
# =========================================

echo ""
echo -e "${BOLD}$RMSG_SECURITY_SSL_SECTION${NC}"

SSL_CHECKED=0
if command -v openssl &>/dev/null; then
    for APP_DIR in /home/"$USERNAME"/apps/*/; do
        [ -d "$APP_DIR" ] || continue
        DOMAIN=$(cat "$APP_DIR/.deploy-domain" 2>/dev/null || true)
        [ -z "$DOMAIN" ] && continue
        SSL_CHECKED=1

        EXPIRY_DATE=$(echo | timeout 5 openssl s_client -servername "$DOMAIN" -connect "$DOMAIN":443 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)

        if [ -n "$EXPIRY_DATE" ]; then
            EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s 2>/dev/null || echo "0")
            NOW_EPOCH=$(date +%s)
            DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

            if [ "$DAYS_LEFT" -lt 0 ]; then
                check_err "$(printf "$RMSG_SECURITY_SSL_ERR" "$DOMAIN")"
            elif [ "$DAYS_LEFT" -lt 30 ]; then
                check_warn "$(printf "$RMSG_SECURITY_SSL_WARN" "$DOMAIN" "$DAYS_LEFT")"
            else
                check_ok "$(printf "$RMSG_SECURITY_SSL_OK" "$DOMAIN" "$DAYS_LEFT")"
            fi
        else
            check_warn "$(printf "$RMSG_SECURITY_SSL_NO_CERT" "$DOMAIN")"
        fi
    done
fi

if [ "$SSL_CHECKED" -eq 0 ]; then
    check_info "$RMSG_SECURITY_SSL_NONE"
fi

# =========================================
# PERMISSIONS
# =========================================

echo ""
echo -e "${BOLD}$RMSG_SECURITY_PERMS_SECTION${NC}"

USER_HOME="/home/$USERNAME"

# ~/.ssh/
if [ -d "$USER_HOME/.ssh" ]; then
    SSH_DIR_PERMS=$(stat -c "%a" "$USER_HOME/.ssh" 2>/dev/null || echo "unknown")
    if [ "$SSH_DIR_PERMS" = "700" ]; then
        check_ok "$RMSG_SECURITY_PERMS_SSH_DIR_OK"
    else
        check_err "$(printf "$RMSG_SECURITY_PERMS_SSH_DIR_ERR" "$SSH_DIR_PERMS")"
    fi
fi

# authorized_keys
if [ -f "$USER_HOME/.ssh/authorized_keys" ]; then
    AK_PERMS=$(stat -c "%a" "$USER_HOME/.ssh/authorized_keys" 2>/dev/null || echo "unknown")
    if [ "$AK_PERMS" = "600" ]; then
        check_ok "$RMSG_SECURITY_PERMS_AUTHKEYS_OK"
    else
        check_err "$(printf "$RMSG_SECURITY_PERMS_AUTHKEYS_ERR" "$AK_PERMS")"
    fi
fi

# sshd_config
if [ -f "$SSHD_CONFIG" ]; then
    SSHD_PERMS=$(stat -c "%a" "$SSHD_CONFIG" 2>/dev/null || echo "unknown")
    if [ "$SSHD_PERMS" = "600" ] || [ "$SSHD_PERMS" = "644" ]; then
        check_ok "$RMSG_SECURITY_PERMS_SSHD_OK"
    else
        check_err "$(printf "$RMSG_SECURITY_PERMS_SSHD_ERR" "$SSHD_PERMS")"
    fi
fi

# =========================================
# SCORE FINAL
# =========================================

echo ""
echo "========================================="
echo -e "  ${BOLD}$(printf "$RMSG_SECURITY_SCORE" "$SCORE" "$TOTAL")${NC}"
echo "========================================="
echo ""
SECURITY_EOF

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

info "$MSG_SECURITY_SENDING"
REMOTE_TMP=$(ssh -i "$SSH_KEY" -o BatchMode=yes "${SSH_USER}@${VPS_IP}" "mktemp /tmp/vps-XXXXXXXXXX.sh")
if ! scp -i "$SSH_KEY" "$TMPSCRIPT" "${SSH_USER}@${VPS_IP}:${REMOTE_TMP}"; then
    err "$MSG_SECURITY_ERR_SEND"
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

ssh $SSH_TTY_FLAG -i "$SSH_KEY" "${SSH_USER}@${VPS_IP}" "chmod 700 '${REMOTE_TMP}'; sudo bash '${REMOTE_TMP}'; rm -f '${REMOTE_TMP}'"
