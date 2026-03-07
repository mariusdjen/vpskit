#!/bin/bash
set -euo pipefail

# ============================================
# Déploiement d'une application sur un VPS
# Utilise la session de vps-bootstrap
#
# Usage interactif : bash deploy.sh
# Usage CI/CD :      bash deploy.sh -ip IP -key CLÉ -user USER -app NOM -repo URL -domain DOMAINE [-port PORT] [-env FICHIER]
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
# DÉTECTION OS LOCAL
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

# =========================================
# ARGUMENTS (MODE CI/CD)
# =========================================

VPS_IP=""
SSH_KEY=""
USERNAME=""
APP_NAME=""
REPO_URL=""
DOMAIN=""
APP_PORT="3000"
ENV_FILE=""
INTERACTIVE=true
ROLLBACK=false
DEPLOY_BRANCH=""
DEPLOY_TAG=""

while [ $# -gt 0 ]; do
    case "$1" in
        -ip)     VPS_IP="$2"; shift 2; INTERACTIVE=false ;;
        -key)    SSH_KEY="$2"; shift 2 ;;
        -user)   USERNAME="$2"; shift 2 ;;
        -app)    APP_NAME="$2"; shift 2 ;;
        -repo)   REPO_URL="$2"; shift 2 ;;
        -domain) DOMAIN="$2"; shift 2 ;;
        -port)   APP_PORT="$2"; shift 2 ;;
        -env)    ENV_FILE="$2"; shift 2 ;;
        -branch) DEPLOY_BRANCH="$2"; shift 2 ;;
        -tag)    DEPLOY_TAG="$2"; shift 2 ;;
        --rollback) ROLLBACK=true; shift ;;
        *)
            err "$(printf "$MSG_DEPLOY_UNKNOWN_ARG" "$1")"
            echo "$MSG_DEPLOY_USAGE_CICD"
            exit 1
            ;;
    esac
done

# Si les deux sont fournis, le tag a priorite
if [ -n "$DEPLOY_TAG" ] && [ -n "$DEPLOY_BRANCH" ]; then
    warn "$MSG_DEPLOY_BRANCH_TAG_EXCLUSIVE"
    DEPLOY_BRANCH=""
fi

# =========================================
# MODE INTERACTIF
# =========================================

if [ "$INTERACTIVE" = true ]; then

    echo ""
    echo "========================================="
    echo -e "  ${BOLD}VPS DEPLOY${NC}"
    echo "  $MSG_DEPLOY_TITLE"
    echo "========================================="
    echo ""
    echo "$MSG_DEPLOY_INTRO_LINE1"
    echo "$MSG_DEPLOY_INTRO_STEP1"
    echo "$MSG_DEPLOY_INTRO_STEP2"
    echo "$MSG_DEPLOY_INTRO_STEP3"
    echo "$MSG_DEPLOY_INTRO_STEP4"
    echo "$MSG_DEPLOY_INTRO_STEP5"
    echo ""
    echo "$MSG_DEPLOY_INTRO_READY"
    echo ""

    # =========================================
    # ÉTAPE 1 : CONNEXION AU VPS
    # =========================================

    echo -e "${BOLD}${YELLOW}$MSG_DEPLOY_STEP1_TITLE${NC}"
    echo "$MSG_DEPLOY_STEP1_INTRO"
    echo ""

    SSH_DIR="$HOME/.ssh"
    LOCAL_STATE="$SSH_DIR/.vps-bootstrap-local"

    if [ -f "$LOCAL_STATE" ]; then
        VPS_IP=$(read_state_var "$LOCAL_STATE" "VPS_IP")
        SSH_KEY=$(read_state_var "$LOCAL_STATE" "SSH_KEY")
        USERNAME=$(read_state_var "$LOCAL_STATE" "USERNAME")
        success "$MSG_DEPLOY_SESSION_FOUND"
        echo ""
        echo "    $(printf "$MSG_DEPLOY_SESSION_IP" "$VPS_IP")"
        echo "    $(printf "$MSG_DEPLOY_SESSION_KEY" "$(basename "$SSH_KEY")")"
        echo "    $(printf "$MSG_DEPLOY_SESSION_USER" "$USERNAME")"
        echo ""
        read -p "$MSG_DEPLOY_SESSION_CONFIRM_PROMPT" USE_SESSION
        if [[ ! "$USE_SESSION" =~ ^[oOyY]$ ]]; then
            VPS_IP=""
            SSH_KEY=""
            USERNAME=""
        fi
    else
        info "$MSG_DEPLOY_SESSION_NOT_FOUND"
        echo "$MSG_DEPLOY_SESSION_NOT_FOUND_HINT1"
        echo "$MSG_DEPLOY_SESSION_NOT_FOUND_HINT2"
        echo ""
    fi

    if [ -z "$VPS_IP" ]; then
        echo "$MSG_DEPLOY_IP_HINT1"
        echo "$MSG_DEPLOY_IP_HINT2"
        echo ""
        read -p "$MSG_DEPLOY_IP_PROMPT" VPS_IP
    fi
    if [ -z "$SSH_KEY" ]; then
        echo ""
        echo "$MSG_DEPLOY_KEY_HINT1"
        echo "$MSG_DEPLOY_KEY_HINT2"
        echo ""
        read -p "$MSG_DEPLOY_KEY_PROMPT" SSH_KEY
    fi
    if [ -z "$USERNAME" ]; then
        echo ""
        read -p "$MSG_DEPLOY_USERNAME_PROMPT" USERNAME
        USERNAME=${USERNAME:-deploy}
    fi

    echo ""

    # =========================================
    # DERNIERS DEPLOIEMENTS
    # =========================================

    DEPLOY_HISTORY=$(ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o BatchMode=yes "${USERNAME}@${VPS_IP}" "tail -n 5 ~/.deploy-history 2>/dev/null" 2>/dev/null || true)
    if [ -n "$DEPLOY_HISTORY" ]; then
        info "$MSG_DEPLOY_LAST_DEPLOYS"
        echo ""
        while IFS= read -r line; do
            echo "    $line"
        done <<< "$DEPLOY_HISTORY"
        echo ""
    fi

    # =========================================
    # CHOIX : DEPLOYER OU REVENIR EN ARRIERE
    # =========================================

    echo -e "${BOLD}${YELLOW}$MSG_DEPLOY_ACTION_TITLE${NC}"
    echo ""
    echo "$MSG_DEPLOY_ACTION_DEPLOY"
    echo "$MSG_DEPLOY_ACTION_ROLLBACK"
    echo ""
    read -p "$MSG_DEPLOY_ACTION_PROMPT" DEPLOY_CHOICE
    echo ""

    if [ "$DEPLOY_CHOICE" = "2" ]; then
        ROLLBACK=true

        # Lister les apps existantes sur le serveur
        info "$MSG_DEPLOY_ROLLBACK_FETCHING"
        APPS_LIST=$(ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes "${USERNAME}@${VPS_IP}" "ls -1 ~/apps/ 2>/dev/null" || true)

        if [ -z "$APPS_LIST" ]; then
            err "$MSG_DEPLOY_ROLLBACK_NO_APPS"
            exit 1
        fi

        echo ""
        echo "$MSG_DEPLOY_ROLLBACK_APPS_LIST"
        echo ""
        INDEX=1
        while IFS= read -r app; do
            echo "    $INDEX) $app"
            INDEX=$((INDEX + 1))
        done <<< "$APPS_LIST"
        echo ""
        read -p "$MSG_DEPLOY_ROLLBACK_SELECT_PROMPT" APP_CHOICE

        if ! [[ "$APP_CHOICE" =~ ^[0-9]+$ ]]; then
            err "$MSG_DEPLOY_ROLLBACK_INVALID_CHOICE"
            exit 1
        fi

        APP_NAME=$(echo "$APPS_LIST" | sed -n "${APP_CHOICE}p")
        if [ -z "$APP_NAME" ]; then
            err "$MSG_DEPLOY_ROLLBACK_INVALID_CHOICE_EMPTY"
            exit 1
        fi

        success "$(printf "$MSG_DEPLOY_ROLLBACK_APP_SELECTED" "$APP_NAME")"

        # Vérifier qu'un commit précédent existe
        HAS_PREVIOUS=$(ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes "${USERNAME}@${VPS_IP}" "cat ~/apps/${APP_NAME}/.last-working-commit 2>/dev/null" || true)
        if [ -z "$HAS_PREVIOUS" ]; then
            err "$(printf "$MSG_DEPLOY_ROLLBACK_NO_PREVIOUS" "$APP_NAME")"
            echo "$MSG_DEPLOY_ROLLBACK_NEED_UPDATE"
            exit 1
        fi

        echo ""
        info "$(printf "$MSG_DEPLOY_ROLLBACK_PREVIOUS_COMMIT" "$HAS_PREVIOUS")"
        read -p "$MSG_DEPLOY_ROLLBACK_CONFIRM_PROMPT" CONFIRM_ROLLBACK
        if [[ ! "$CONFIRM_ROLLBACK" =~ ^[oOyY]$ ]]; then
            info "$MSG_DEPLOY_ROLLBACK_CANCELLED"
            exit 0
        fi
    fi

    if [ "$ROLLBACK" = true ]; then
        # Sauter les étapes de déploiement standard
        # On va directement à la validation puis au rollback
        REPO_URL="rollback"
        DOMAIN="rollback"
        :
    else

    # =========================================
    # ÉTAPE 2 : CHOIX DE L'APPLICATION
    # =========================================

    echo -e "${BOLD}${YELLOW}$MSG_DEPLOY_STEP2_TITLE${NC}"
    echo "$MSG_DEPLOY_STEP2_INTRO"
    echo ""
    echo "$MSG_DEPLOY_REPO_FIND_HINT1"
    echo "$MSG_DEPLOY_REPO_FIND_HINT2"
    echo "$MSG_DEPLOY_REPO_FIND_HINT3"
    echo "$MSG_DEPLOY_REPO_FIND_HINT4"
    echo ""
    read -p "$MSG_DEPLOY_REPO_URL_PROMPT" REPO_URL

    # Suggestion du nom depuis le repo
    SUGGESTED_NAME=""
    if echo "$REPO_URL" | grep -q '/'; then
        SUGGESTED_NAME=$(basename "$REPO_URL" .git)
    fi

    echo ""
    echo "$MSG_DEPLOY_APP_NAME_HINT1"
    echo "$MSG_DEPLOY_APP_NAME_HINT2"
    echo ""
    if [ -n "$SUGGESTED_NAME" ]; then
        read -p "$(printf "$MSG_DEPLOY_APP_NAME_PROMPT_DEFAULT" "$SUGGESTED_NAME")" APP_NAME_INPUT
        APP_NAME=${APP_NAME_INPUT:-$SUGGESTED_NAME}
    else
        read -p "$MSG_DEPLOY_APP_NAME_PROMPT" APP_NAME
    fi

    # =========================================
    # CHOIX DE LA BRANCHE / TAG
    # =========================================

    echo ""
    echo "$MSG_DEPLOY_BRANCH_TAG_HINT1"
    echo "$MSG_DEPLOY_BRANCH_TAG_HINT2"
    echo ""
    echo "$MSG_DEPLOY_BRANCH_TAG_OPT1"
    echo "$MSG_DEPLOY_BRANCH_TAG_OPT2"
    echo "$MSG_DEPLOY_BRANCH_TAG_OPT3"
    echo ""
    read -p "$MSG_DEPLOY_BRANCH_TAG_CHOICE_PROMPT" BRANCH_CHOICE
    case "$BRANCH_CHOICE" in
        2)
            read -p "$MSG_DEPLOY_BRANCH_NAME_PROMPT" DEPLOY_BRANCH
            ;;
        3)
            read -p "$MSG_DEPLOY_TAG_NAME_PROMPT" DEPLOY_TAG
            ;;
        *)
            :
            ;;
    esac

    # =========================================
    # ÉTAPE 3 : DOMAINE ET CONFIGURATION
    # =========================================

    echo ""
    echo -e "${BOLD}${YELLOW}$MSG_DEPLOY_STEP3_TITLE${NC}"
    echo "$MSG_DEPLOY_STEP3_INTRO1"
    echo "$MSG_DEPLOY_STEP3_INTRO2"
    echo ""
    echo "$(printf "$MSG_DEPLOY_STEP3_DNS_HINT" "$VPS_IP")"
    echo "$MSG_DEPLOY_STEP3_DNS_REGISTRAR"
    echo ""
    read -p "$MSG_DEPLOY_DOMAIN_PROMPT" DOMAIN
    # Nettoyer le domaine (retirer https://, http://, slash final)
    DOMAIN=$(echo "$DOMAIN" | sed 's|^https://||;s|^http://||;s|/$||')

    echo ""
    echo "$MSG_DEPLOY_PORT_HINT1"
    echo "$MSG_DEPLOY_PORT_HINT2"
    echo ""
    read -p "$MSG_DEPLOY_PORT_PROMPT" APP_PORT_INPUT
    APP_PORT=${APP_PORT_INPUT:-3000}

    # =========================================
    # ÉTAPE 4 : VARIABLES D'ENVIRONNEMENT
    # =========================================

    echo ""
    echo -e "${BOLD}${YELLOW}$MSG_DEPLOY_STEP4_TITLE${NC}"
    echo "$MSG_DEPLOY_STEP4_INTRO1"
    echo "$MSG_DEPLOY_STEP4_INTRO2"
    echo ""
    read -p "$MSG_DEPLOY_ENV_NEED_PROMPT" NEED_ENV
    CREATE_EMPTY_ENV="false"
    if [[ "$NEED_ENV" =~ ^[oOyY]$ ]]; then
        echo ""
        echo "$MSG_DEPLOY_ENV_PATH_HINT1"
        echo "$MSG_DEPLOY_ENV_PATH_HINT2"
        echo ""
        read -p "$MSG_DEPLOY_ENV_PATH_PROMPT" ENV_FILE

        # Nettoyage du chemin (espaces, guillemets, ~, antislash macOS drag-and-drop, slash final)
        ENV_FILE=$(echo "$ENV_FILE" | sed "s|^['\"]||;s|['\"]$||;s|^~|$HOME|;s|\\\\ | |g;s|[[:space:]]*$||;s|/$||")

        # Si c'est un dossier, chercher .env dedans
        if [ -d "$ENV_FILE" ]; then
            if [ -f "$ENV_FILE/.env" ]; then
                ENV_FILE="$ENV_FILE/.env"
                success "$(printf "$MSG_DEPLOY_ENV_FOUND" "$ENV_FILE")"
            fi
        fi

        # Si toujours introuvable, proposer des alternatives
        while [ -n "$ENV_FILE" ] && [ ! -f "$ENV_FILE" ]; do
            echo ""
            warn "$(printf "$MSG_DEPLOY_ENV_NOT_FOUND" "$ENV_FILE")"
            echo ""
            echo "$MSG_DEPLOY_ENV_RETRY_TITLE"
            echo "$MSG_DEPLOY_ENV_RETRY_OPT1"
            echo "$MSG_DEPLOY_ENV_RETRY_OPT2"
            echo ""
            read -p "$MSG_DEPLOY_ENV_RETRY_CHOICE_PROMPT" ENV_CHOICE
            case "$ENV_CHOICE" in
                1)
                    echo ""
                    read -p "$MSG_DEPLOY_ENV_NEW_PATH_PROMPT" ENV_FILE
                    ENV_FILE=$(echo "$ENV_FILE" | sed "s|^['\"]||;s|['\"]$||;s|^~|$HOME|;s|\\\\ | |g;s|[[:space:]]*$||;s|/$||")
                    if [ -d "$ENV_FILE" ]; then
                        if [ -f "$ENV_FILE/.env" ]; then
                            ENV_FILE="$ENV_FILE/.env"
                            success "$(printf "$MSG_DEPLOY_ENV_FOUND" "$ENV_FILE")"
                        fi
                    fi
                    ;;
                *)
                    ENV_FILE=""
                    CREATE_EMPTY_ENV="true"
                    echo ""
                    info "$MSG_DEPLOY_ENV_EMPTY_CREATED"
                    echo "$MSG_DEPLOY_ENV_EMPTY_HOW_TO_FILL"
                    echo ""
                    echo "    ssh -i ~/.ssh/$(basename "$SSH_KEY") ${USERNAME}@${VPS_IP}"
                    echo "    nano ~/apps/${APP_NAME}/.env"
                    echo ""
                    ;;
            esac
        done

        if [ -f "$ENV_FILE" ] 2>/dev/null; then
            success "$(printf "$MSG_DEPLOY_ENV_FOUND" "$ENV_FILE")"
        fi
    fi

    # =========================================
    # RÉCAPITULATIF AVANT DÉPLOIEMENT
    # =========================================

    echo ""
    echo "========================================="
    echo -e "  ${BOLD}$MSG_DEPLOY_RECAP_TITLE${NC}"
    echo "========================================="
    echo ""
    echo "    $(printf "$MSG_DEPLOY_RECAP_SERVER" "$VPS_IP" "$USERNAME")"
    echo "    $(printf "$MSG_DEPLOY_RECAP_APP" "$APP_NAME")"
    echo "    $(printf "$MSG_DEPLOY_RECAP_REPO" "$REPO_URL")"
    echo "    $(printf "$MSG_DEPLOY_RECAP_DOMAIN" "$DOMAIN")"
    echo "    $(printf "$MSG_DEPLOY_RECAP_PORT" "$APP_PORT")"
    if [ -n "$DEPLOY_TAG" ]; then
        echo "    $(printf "$MSG_DEPLOY_RECAP_TAG" "$DEPLOY_TAG")"
    elif [ -n "$DEPLOY_BRANCH" ]; then
        echo "    $(printf "$MSG_DEPLOY_RECAP_BRANCH" "$DEPLOY_BRANCH")"
    fi
    if [ -n "$ENV_FILE" ]; then
        echo "    $(printf "$MSG_DEPLOY_RECAP_ENV" "$ENV_FILE")"
    elif [ "$CREATE_EMPTY_ENV" = "true" ]; then
        echo "    $MSG_DEPLOY_RECAP_ENV_EMPTY"
    fi
    echo ""
    read -p "$MSG_DEPLOY_CONFIRM_LAUNCH_PROMPT" CONFIRM_DEPLOY
    if [[ ! "$CONFIRM_DEPLOY" =~ ^[oOyY]$ ]]; then
        info "$MSG_DEPLOY_CANCELLED"
        exit 0
    fi

    fi  # fin du else (deploy vs rollback)
fi

# =========================================
# VALIDATION
# =========================================

ERRORS=0

if [ -z "$VPS_IP" ]; then
    err "$MSG_DEPLOY_ERR_NO_IP"
    ERRORS=$((ERRORS + 1))
fi
if [ -z "$SSH_KEY" ] || [ ! -f "$SSH_KEY" ]; then
    err "$(printf "$MSG_DEPLOY_ERR_NO_KEY" "${SSH_KEY:-$MSG_DEPLOY_FALLBACK_UNSPECIFIED}")"
    ERRORS=$((ERRORS + 1))
fi
if [ -z "$USERNAME" ]; then
    err "$MSG_DEPLOY_ERR_NO_USER"
    ERRORS=$((ERRORS + 1))
fi
if [ -z "$APP_NAME" ]; then
    err "$MSG_DEPLOY_ERR_NO_APP"
    ERRORS=$((ERRORS + 1))
fi

if [ "$ROLLBACK" = false ]; then
    if [ -z "$REPO_URL" ]; then
        err "$MSG_DEPLOY_ERR_NO_REPO"
        ERRORS=$((ERRORS + 1))
    fi
    if [ -z "$DOMAIN" ]; then
        err "$MSG_DEPLOY_ERR_NO_DOMAIN"
        ERRORS=$((ERRORS + 1))
    fi
    if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]] || [ "$APP_PORT" -lt 1 ] || [ "$APP_PORT" -gt 65535 ]; then
        err "$(printf "$MSG_DEPLOY_ERR_INVALID_PORT" "$APP_PORT")"
        ERRORS=$((ERRORS + 1))
    fi
    if [ -n "$ENV_FILE" ] && [ ! -f "$ENV_FILE" ]; then
        # En mode CI/CD, bloquer. En mode interactif, déjà géré.
        if [ "$INTERACTIVE" = false ]; then
            err "$(printf "$MSG_DEPLOY_ERR_ENV_NOT_FOUND" "$ENV_FILE")"
            ERRORS=$((ERRORS + 1))
        fi
    fi
fi

if [ "$ERRORS" -gt 0 ]; then
    exit 1
fi

# --- Nettoyage du domaine ---
if [ "$ROLLBACK" = false ]; then
    DOMAIN=$(echo "$DOMAIN" | sed 's|^https://||;s|^http://||;s|/$||')
fi

# --- Nettoyage du nom d'application ---
CLEAN_APP_NAME=$(echo "$APP_NAME" | tr -cd 'a-zA-Z0-9-')
if [ "$CLEAN_APP_NAME" != "$APP_NAME" ]; then
    warn "$(printf "$MSG_DEPLOY_WARN_APP_NAME_CLEANED" "$CLEAN_APP_NAME")"
    APP_NAME="$CLEAN_APP_NAME"
fi

# --- Validation IP ---
if ! echo "$VPS_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    err "$(printf "$MSG_DEPLOY_ERR_INVALID_IP" "$VPS_IP")"
    echo "$MSG_DEPLOY_ERR_INVALID_IP_FORMAT"
    exit 1
fi

# --- Test connexion SSH ---
info "$MSG_DEPLOY_SSH_TESTING"
if ! ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes "${USERNAME}@${VPS_IP}" "echo ok" &>/dev/null; then
    err "$(printf "$MSG_DEPLOY_SSH_FAILED" "$USERNAME" "$VPS_IP")"
    echo ""
    echo "$MSG_DEPLOY_SSH_FAILED_CAUSES_TITLE"
    echo "$MSG_DEPLOY_SSH_FAILED_CAUSE1"
    echo "$MSG_DEPLOY_SSH_FAILED_CAUSE2"
    echo "$MSG_DEPLOY_SSH_FAILED_CAUSE3"
    echo "$MSG_DEPLOY_SSH_FAILED_CAUSE4"
    echo ""
    echo "$MSG_DEPLOY_SSH_FAILED_DIAG"
    echo "    ssh -v -i $SSH_KEY ${USERNAME}@${VPS_IP}"
    exit 1
fi
success "$MSG_DEPLOY_SSH_OK"

# =========================================
# MODE ROLLBACK
# =========================================

if [ "$ROLLBACK" = true ]; then
    TMPSCRIPT=$(mktemp)
    _CLEANUP_FILES+=("$TMPSCRIPT")
    cat > "$TMPSCRIPT" << 'ROLLBACK_EOF'
#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

APP_NAME="__APP_NAME__"
USERNAME="__USERNAME__"
APP_DIR="/home/$USERNAME/apps/$APP_NAME"

info()    { echo -e "${BLUE}[INFO] $1${NC}"; }
success() { echo -e "${GREEN}[OK] $1${NC}"; }
warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }
err()     { echo -e "${RED}[ERR] $1${NC}"; }

echo ""
echo "========================================="
echo -e "  ${BOLD}$(printf "$RMSG_ROLLBACK_TITLE" "$APP_NAME")${NC}"
echo "========================================="
echo ""

if [ ! -d "$APP_DIR" ]; then
    err "$(printf "$RMSG_ROLLBACK_ERR_NOT_FOUND" "$APP_DIR")"
    exit 1
fi

cd "$APP_DIR"

LAST_COMMIT_FILE="$APP_DIR/.last-working-commit"

if [ ! -f "$LAST_COMMIT_FILE" ]; then
    err "$RMSG_ROLLBACK_ERR_NO_COMMIT"
    echo "$RMSG_ROLLBACK_ERR_NO_COMMIT_HINT"
    exit 1
fi

LAST_COMMIT=$(cat "$LAST_COMMIT_FILE")
CURRENT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "$RMSG_ROLLBACK_FALLBACK_UNKNOWN")

info "$(printf "$RMSG_ROLLBACK_CURRENT_COMMIT" "$CURRENT_COMMIT")"
info "$(printf "$RMSG_ROLLBACK_TARGET_COMMIT" "$LAST_COMMIT")"
echo ""

# Restaurer le commit precedent
info "$RMSG_ROLLBACK_RESTORING"
sudo -u "$USERNAME" git checkout "$LAST_COMMIT" 2>/dev/null
success "$RMSG_ROLLBACK_CODE_RESTORED"

# Rebuild Docker
echo ""
info "$RMSG_ROLLBACK_REBUILDING"

COMPOSE_FILE=""
for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [ -f "$APP_DIR/$f" ]; then
        COMPOSE_FILE="$f"
        break
    fi
done

if [ -n "$COMPOSE_FILE" ]; then
    cd "$APP_DIR"
    sudo -u "$USERNAME" docker compose up -d --build 2>&1
    success "$RMSG_ROLLBACK_COMPOSE_SUCCESS"
elif [ -f "$APP_DIR/Dockerfile" ]; then
    sudo -u "$USERNAME" docker build -t "$APP_NAME" "$APP_DIR"
    docker stop "$APP_NAME" 2>/dev/null || true
    docker rm "$APP_NAME" 2>/dev/null || true

    APP_PORT=""
    if [ -f "$APP_DIR/.deploy-port" ]; then
        APP_PORT=$(cat "$APP_DIR/.deploy-port")
    else
        APP_PORT="3000"
    fi

    DOCKER_RUN_ARGS="-d --name $APP_NAME --restart unless-stopped -p 127.0.0.1:${APP_PORT}:${APP_PORT}"
    if [ -f "$APP_DIR/.env" ]; then
        DOCKER_RUN_ARGS="$DOCKER_RUN_ARGS --env-file $APP_DIR/.env"
    fi
    sudo -u "$USERNAME" docker run $DOCKER_RUN_ARGS "$APP_NAME"
    success "$RMSG_ROLLBACK_DOCKER_SUCCESS"
else
    warn "$RMSG_ROLLBACK_NO_DOCKER"
fi

# Historique
HISTORY_FILE="/home/$USERNAME/.deploy-history"
DEPLOY_DATE=$(date '+%Y-%m-%d %H:%M:%S')
ROLLBACK_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "$RMSG_ROLLBACK_FALLBACK_UNKNOWN")
ROLLBACK_DOMAIN=""
if [ -f "$APP_DIR/.deploy-domain" ]; then
    ROLLBACK_DOMAIN=$(cat "$APP_DIR/.deploy-domain")
fi
echo "$DEPLOY_DATE | $APP_NAME | $ROLLBACK_COMMIT | rollback | $ROLLBACK_DOMAIN | rollback" >> "$HISTORY_FILE"
chown "$USERNAME:$USERNAME" "$HISTORY_FILE"

echo ""
echo "========================================="
echo -e "  ${GREEN}$RMSG_ROLLBACK_DONE_TITLE${NC}"
echo "========================================="
echo ""
echo "$(printf "$RMSG_ROLLBACK_DONE_APP" "$APP_NAME")"
echo "$(printf "$RMSG_ROLLBACK_DONE_COMMIT" "$LAST_COMMIT")"
echo "$(printf "$RMSG_ROLLBACK_DONE_DIR" "$APP_DIR")"
echo ""
echo "$RMSG_ROLLBACK_DONE_REVERT_HINT"
echo "    cd $APP_DIR && git checkout main && docker compose up -d --build"
echo "========================================="
ROLLBACK_EOF

    inject_lang_into_remote "$TMPSCRIPT"

    SAFE_APP=$(sed_escape "$APP_NAME")
    SAFE_USER=$(sed_escape "$USERNAME")
    if [ "$OS" = "mac" ]; then
        sed -i '' "s|__APP_NAME__|$SAFE_APP|g" "$TMPSCRIPT"
        sed -i '' "s|__USERNAME__|$SAFE_USER|g" "$TMPSCRIPT"
    else
        sed -i "s|__APP_NAME__|$SAFE_APP|g" "$TMPSCRIPT"
        sed -i "s|__USERNAME__|$SAFE_USER|g" "$TMPSCRIPT"
    fi

    info "$MSG_DEPLOY_ROLLBACK_SENDING"
    REMOTE_TMP=$(ssh -i "$SSH_KEY" -o BatchMode=yes "${USERNAME}@${VPS_IP}" "mktemp /tmp/vps-XXXXXXXXXX.sh")
    scp -i "$SSH_KEY" "$TMPSCRIPT" "${USERNAME}@${VPS_IP}:${REMOTE_TMP}"
    rm -f "$TMPSCRIPT"

    if [ -t 0 ]; then
        SSH_TTY_FLAG="-t"
    else
        SSH_TTY_FLAG=""
    fi

    ssh $SSH_TTY_FLAG -i "$SSH_KEY" "${USERNAME}@${VPS_IP}" "chmod 700 '${REMOTE_TMP}'; sudo bash '${REMOTE_TMP}'; rm -f '${REMOTE_TMP}'"

    echo ""
    echo -e "${BOLD}$MSG_DEPLOY_ROLLBACK_DONE_TITLE${NC}"
    echo ""
    exit 0
fi

# =========================================
# GÉNÉRATION DU SCRIPT DISTANT
# =========================================

TMPSCRIPT=$(mktemp)
_CLEANUP_FILES+=("$TMPSCRIPT")
cat > "$TMPSCRIPT" << 'DEPLOY_EOF'
#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

APP_NAME="__APP_NAME__"
REPO_URL="__REPO_URL__"
DOMAIN="__DOMAIN__"
APP_PORT="__APP_PORT__"
USERNAME="__USERNAME__"
HAS_ENV="__HAS_ENV__"
CREATE_EMPTY_ENV="__CREATE_EMPTY_ENV__"
DEPLOY_BRANCH="__DEPLOY_BRANCH__"
DEPLOY_TAG="__DEPLOY_TAG__"

APP_DIR="/home/$USERNAME/apps/$APP_NAME"

info()    { echo -e "${BLUE}[INFO] $1${NC}"; }
success() { echo -e "${GREEN}[OK] $1${NC}"; }
warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }
err()     { echo -e "${RED}[ERR] $1${NC}"; }

skip_step() {
    echo -e "  ${GREEN}[OK] $1 $RMSG_DEPLOY_SKIP_STEP${NC}"
}

# --- Progression et reprise ---
PROGRESS_FILE="$APP_DIR/.deploy-progress"
CURRENT_STEP="initialisation"

is_done() {
    [ -f "$PROGRESS_FILE" ] && grep -q "^$1$" "$PROGRESS_FILE" 2>/dev/null
}

mark_done() {
    mkdir -p "$(dirname "$PROGRESS_FILE")"
    echo "$1" >> "$PROGRESS_FILE"
}

# --- Trap ERR : message clair en cas d'echec ---
trap_err() {
    local lineno="$1"
    echo ""
    echo -e "${RED}=========================================${NC}"
    echo -e "${RED}[ERR] $(printf "$RMSG_DEPLOY_ERR_STEP" "$CURRENT_STEP" "$lineno")${NC}"
    echo -e "${RED}=========================================${NC}"
    echo ""
    echo "$RMSG_DEPLOY_ERR_RESUME"
    echo "$RMSG_DEPLOY_ERR_RESUME_HINT"
    echo ""
    echo "$RMSG_DEPLOY_ERR_DOCKER_LOGS_HINT"
    echo "    cd $APP_DIR && docker compose logs --tail=30 2>/dev/null || docker logs $APP_NAME --tail=30 2>/dev/null"
    echo ""
}
trap 'trap_err $LINENO' ERR

echo ""
echo "========================================="
echo -e "  ${BOLD}DEPLOIEMENT : $APP_NAME${NC}"
echo "========================================="
echo ""

# Annonce de la reprise si un deploiement precedent a echoue
if [ -f "$PROGRESS_FILE" ]; then
    warn "$RMSG_DEPLOY_PREVIOUS_FAILED"
    echo "$RMSG_DEPLOY_RESUMING"
    echo ""
fi

# --- Verifications prealables ---
if ! command -v docker &>/dev/null; then
    err "$RMSG_DEPLOY_ERR_NO_DOCKER"
    exit 1
fi

if ! command -v git &>/dev/null; then
    err "$RMSG_DEPLOY_ERR_NO_GIT"
    exit 1
fi

# =========================================
# CONNEXION GITHUB SSH (multi-comptes)
# =========================================

# Fonction : configurer l'accès SSH GitHub (multi-comptes)
setup_github_ssh() {
    echo -e "${BOLD}${YELLOW}[>] $RMSG_DEPLOY_GH_TITLE${NC}"
    echo "$RMSG_DEPLOY_GH_INTRO1"
    echo "$RMSG_DEPLOY_GH_INTRO2"
    echo ""

    SSH_DIR="/home/$USERNAME/.ssh"
    SSH_CONFIG="$SSH_DIR/config"
    mkdir -p "$SSH_DIR"
    touch "$SSH_CONFIG"
    chown "$USERNAME:$USERNAME" "$SSH_DIR" "$SSH_CONFIG"
    chmod 700 "$SSH_DIR"
    chmod 600 "$SSH_CONFIG"

    # Lister les comptes GitHub déjà configurés
    GITHUB_HOSTS=$(grep -E "^Host github-" "$SSH_CONFIG" 2>/dev/null | awk '{print $2}' || true)

    GH_LABEL=""

    if [ -n "$GITHUB_HOSTS" ]; then
        success "$RMSG_DEPLOY_GH_EXISTING_ACCOUNTS"
        echo ""
        INDEX=1
        while IFS= read -r host; do
            LABEL=$(echo "$host" | sed 's/^github-//')
            KEY_FILE=$(grep -A3 "^Host $host" "$SSH_CONFIG" | grep "IdentityFile" | awk '{print $2}' | sed "s|~|/home/$USERNAME|")
            if [ -f "${KEY_FILE}.pub" ]; then
                KEY_INFO=$(head -1 "${KEY_FILE}.pub" | awk '{print $3}')
            else
                KEY_INFO="$RMSG_DEPLOY_GH_KEY_NOT_FOUND"
            fi
            printf "    %2d) %s (%s)\n" "$INDEX" "$LABEL" "$KEY_INFO"
            INDEX=$((INDEX + 1))
        done <<< "$GITHUB_HOSTS"

        TOTAL=$((INDEX - 1))
        echo ""
        echo "    $INDEX) $RMSG_DEPLOY_GH_NEW_ACCOUNT_OPT"
        echo ""
        read -p "$RMSG_DEPLOY_GH_SELECT_ACCOUNT_PROMPT" GH_CHOICE

        if [ "$GH_CHOICE" -le "$TOTAL" ] 2>/dev/null; then
            SELECTED_HOST=$(echo "$GITHUB_HOSTS" | sed -n "${GH_CHOICE}p")
            GH_LABEL=$(echo "$SELECTED_HOST" | sed 's/^github-//')
            success "$(printf "$RMSG_DEPLOY_GH_ACCOUNT_SELECTED" "$GH_LABEL")"
        fi
    fi

    # Ajouter un nouveau compte si nécessaire
    if [ -z "$GH_LABEL" ]; then
        echo ""
        echo "$RMSG_DEPLOY_GH_CONNECT_INTRO1"
        echo "$RMSG_DEPLOY_GH_CONNECT_INTRO2"
        echo "$RMSG_DEPLOY_GH_CONNECT_INTRO3"
        echo ""
        read -p "$RMSG_DEPLOY_GH_LABEL_PROMPT" GH_LABEL
        GH_LABEL=$(echo "$GH_LABEL" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')

        if [ -z "$GH_LABEL" ]; then
            GH_LABEL="default"
        fi

        KEY_PATH="$SSH_DIR/github_$GH_LABEL"

        if [ ! -f "$KEY_PATH" ]; then
            echo ""
            info "$(printf "$RMSG_DEPLOY_GH_KEY_GENERATING" "$GH_LABEL")"
            sudo -u "$USERNAME" ssh-keygen -t ed25519 -C "vps-$GH_LABEL" -f "$KEY_PATH" -N ""
            success "$RMSG_DEPLOY_GH_KEY_GENERATED"
        fi

        # Ajouter le bloc dans ~/.ssh/config
        if ! grep -q "^Host github-$GH_LABEL" "$SSH_CONFIG" 2>/dev/null; then
            cat >> "$SSH_CONFIG" << SSH_BLOCK

Host github-$GH_LABEL
    HostName github.com
    User git
    IdentityFile ~/.ssh/github_$GH_LABEL
SSH_BLOCK
            chown "$USERNAME:$USERNAME" "$SSH_CONFIG"
            chmod 600 "$SSH_CONFIG"
        fi

        # Afficher la clé publique avec instructions détaillées
        echo ""
        echo "========================================="
        echo -e "  ${YELLOW}$RMSG_DEPLOY_GH_ADD_KEY_TITLE${NC}"
        echo "========================================="
        echo ""
        echo "$RMSG_DEPLOY_GH_ADD_KEY_COPY"
        echo ""
        echo -e "  ${GREEN}$(cat "${KEY_PATH}.pub")${NC}"
        echo ""
        echo "$RMSG_DEPLOY_GH_ADD_KEY_STEPS_INTRO"
        echo ""
        echo "$RMSG_DEPLOY_GH_ADD_KEY_STEP1"
        echo "$RMSG_DEPLOY_GH_ADD_KEY_STEP1B"
        echo ""
        echo "$RMSG_DEPLOY_GH_ADD_KEY_STEP2"
        echo ""
        echo "$(printf "$RMSG_DEPLOY_GH_ADD_KEY_STEP3" "$GH_LABEL")"
        echo ""
        echo "$RMSG_DEPLOY_GH_ADD_KEY_STEP4"
        echo ""
        echo "$RMSG_DEPLOY_GH_ADD_KEY_STEP5"
        echo ""
        echo "========================================="
        echo ""
        read -p "$RMSG_DEPLOY_GH_ADD_KEY_WAIT_PROMPT"

        # Tester la connexion
        echo ""
        info "$RMSG_DEPLOY_GH_TESTING"
        if sudo -u "$USERNAME" ssh -T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$KEY_PATH" git@github.com 2>&1 | grep -qi "successfully authenticated"; then
            success "$RMSG_DEPLOY_GH_SUCCESS"
        else
            echo ""
            warn "$RMSG_DEPLOY_GH_FAILED"
            echo ""
            echo "$RMSG_DEPLOY_GH_FAILED_CHECK1"
            echo "$RMSG_DEPLOY_GH_FAILED_CHECK2"
            echo "$RMSG_DEPLOY_GH_FAILED_CHECK3"
            echo ""
            read -p "$RMSG_DEPLOY_GH_RETRY_PROMPT"
            if sudo -u "$USERNAME" ssh -T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$KEY_PATH" git@github.com 2>&1 | grep -qi "successfully authenticated"; then
                success "$RMSG_DEPLOY_GH_SUCCESS"
            else
                err "$RMSG_DEPLOY_GH_IMPOSSIBLE"
                exit 1
            fi
        fi
    fi

    # Transformer l'URL : git@github.com: → github-<label>:
    REPO_URL=$(echo "$REPO_URL" | sed "s|git@github.com:|github-${GH_LABEL}:|")
}

# Convertir HTTPS GitHub en SSH (pour déclencher le flow multi-comptes)
convert_https_to_ssh() {
    REPO_URL=$(echo "$REPO_URL" | sed -E 's|^https?://github\.com/|git@github.com:|')
}

# Si l'URL est déjà en SSH → configurer directement
CURRENT_STEP="configuration_github_ssh"
if is_done "step_github"; then
    skip_step "$RMSG_DEPLOY_GH_TITLE"
elif echo "$REPO_URL" | grep -q "^git@github.com"; then
    setup_github_ssh
    mark_done "step_github"
fi

# =========================================
# DÉPLOIEMENT DE L'APPLICATION
# =========================================

# === TELECHARGEMENT DU CODE ===
CURRENT_STEP="telechargement_code"
echo ""
echo -e "${BOLD}${YELLOW}[>] $RMSG_DEPLOY_CODE_TITLE${NC}"

# Verifier l'integrite du depot si le dossier existe
if [ -d "$APP_DIR/.git" ]; then
    if ! sudo -u "$USERNAME" git -C "$APP_DIR" rev-parse HEAD &>/dev/null; then
        warn "$RMSG_DEPLOY_REPO_CORRUPT"
        rm -rf "$APP_DIR"
    fi
fi

# Si le dossier existe mais n'est pas un depot git, le supprimer
if [ -d "$APP_DIR" ] && [ ! -d "$APP_DIR/.git" ]; then
    warn "Le dossier $APP_DIR existe mais n'est pas un depot git, suppression..."
    rm -rf "$APP_DIR"
fi

if [ -d "$APP_DIR/.git" ]; then
    info "$RMSG_DEPLOY_REPO_EXISTS"
    cd "$APP_DIR"
    # Sauvegarder le commit actuel avant mise à jour (pour rollback)
    CURRENT_COMMIT=$(sudo -u "$USERNAME" git rev-parse HEAD 2>/dev/null || true)
    if [ -n "$CURRENT_COMMIT" ]; then
        echo "$CURRENT_COMMIT" > "$APP_DIR/.last-working-commit"
        chown "$USERNAME:$USERNAME" "$APP_DIR/.last-working-commit"
    fi
    sudo -u "$USERNAME" git fetch --all 2>/dev/null || true
    if [ -n "$DEPLOY_TAG" ]; then
        sudo -u "$USERNAME" git checkout "$DEPLOY_TAG"
        success "$(printf "$RMSG_DEPLOY_CODE_UPDATED_TAG" "$DEPLOY_TAG")"
    elif [ -n "$DEPLOY_BRANCH" ]; then
        sudo -u "$USERNAME" git checkout "$DEPLOY_BRANCH" 2>/dev/null || sudo -u "$USERNAME" git checkout -b "$DEPLOY_BRANCH" "origin/$DEPLOY_BRANCH"
        sudo -u "$USERNAME" git pull origin "$DEPLOY_BRANCH"
        success "$(printf "$RMSG_DEPLOY_CODE_UPDATED_BRANCH" "$DEPLOY_BRANCH")"
    else
        sudo -u "$USERNAME" git pull
        success "$RMSG_DEPLOY_CODE_UPDATED"
    fi
else
    info "$RMSG_DEPLOY_CLONING"
    mkdir -p "/home/$USERNAME/apps"

    # Tenter le clone. Si HTTPS échoue (repo privé), basculer en SSH.
    GIT_ERR_LOG=$(mktemp /tmp/vps-git-XXXXXXXXXX.log)
    if sudo -u "$USERNAME" git clone "$REPO_URL" "$APP_DIR" 2>"$GIT_ERR_LOG"; then
        rm -f "$GIT_ERR_LOG"
        success "$(printf "$RMSG_DEPLOY_CLONE_SUCCESS" "$APP_DIR")"
    else
        # Vérifier si c'est une URL HTTPS GitHub qui a échoué
        if echo "$REPO_URL" | grep -qE "^https?://github\.com/"; then
            echo ""
            warn "$RMSG_DEPLOY_CLONE_FAILED_PRIVATE"
            echo "$RMSG_DEPLOY_CLONE_PRIVATE_HINT1"
            echo "$RMSG_DEPLOY_CLONE_PRIVATE_HINT2"
            echo ""
            echo "$RMSG_DEPLOY_CLONE_PRIVATE_HINT3"
            echo "$RMSG_DEPLOY_CLONE_PRIVATE_HINT4"
            echo ""

            # Convertir en SSH et lancer le flow multi-comptes
            convert_https_to_ssh
            setup_github_ssh

            # Retenter le clone avec SSH
            info "$RMSG_DEPLOY_CLONE_RETRY_SSH"
            sudo -u "$USERNAME" git clone "$REPO_URL" "$APP_DIR"
            success "$(printf "$RMSG_DEPLOY_CLONE_SUCCESS" "$APP_DIR")"
        else
            err "$RMSG_DEPLOY_CLONE_FAILED"
            cat "$GIT_ERR_LOG"
            rm -f "$GIT_ERR_LOG"
            exit 1
        fi
        rm -f "$GIT_ERR_LOG"
    fi
fi

cd "$APP_DIR"

# Checkout de la branche ou du tag demande (apres clone)
if [ -n "$DEPLOY_TAG" ]; then
    sudo -u "$USERNAME" git checkout "$DEPLOY_TAG" 2>/dev/null || true
    info "$(printf "$RMSG_DEPLOY_TAG_SELECTED" "$DEPLOY_TAG")"
elif [ -n "$DEPLOY_BRANCH" ]; then
    sudo -u "$USERNAME" git checkout "$DEPLOY_BRANCH" 2>/dev/null || true
    info "$(printf "$RMSG_DEPLOY_BRANCH_SELECTED" "$DEPLOY_BRANCH")"
fi

# === FICHIER .ENV ===
CURRENT_STEP="installation_env"
if is_done "step_env"; then
    skip_step "$RMSG_DEPLOY_ENV_TITLE"
elif [ "$HAS_ENV" = "true" ]; then
    echo ""
    echo -e "${BOLD}${YELLOW}[>] $RMSG_DEPLOY_ENV_TITLE${NC}"
    if [ -f "/tmp/.env-$APP_NAME" ]; then
        cp "/tmp/.env-$APP_NAME" "$APP_DIR/.env"
        chown "$USERNAME:$USERNAME" "$APP_DIR/.env"
        chmod 600 "$APP_DIR/.env"
        rm -f "/tmp/.env-$APP_NAME"
        success "$RMSG_DEPLOY_ENV_INSTALLED"
    else
        warn "$RMSG_DEPLOY_ENV_MISSING"
    fi
    mark_done "step_env"
elif [ "$CREATE_EMPTY_ENV" = "true" ]; then
    echo ""
    echo -e "${BOLD}${YELLOW}[>] $RMSG_DEPLOY_ENV_TITLE${NC}"
    if [ ! -f "$APP_DIR/.env" ]; then
        touch "$APP_DIR/.env"
        chown "$USERNAME:$USERNAME" "$APP_DIR/.env"
        chmod 600 "$APP_DIR/.env"
        warn "$(printf "$RMSG_DEPLOY_ENV_EMPTY_CREATED" "$APP_DIR")"
        echo "$RMSG_DEPLOY_ENV_FILL_REMINDER"
        echo "$RMSG_DEPLOY_ENV_FILL_HOW"
        echo ""
        echo "    nano $APP_DIR/.env"
        echo ""
        echo "$RMSG_DEPLOY_ENV_RELAUNCH"
        echo "    cd $APP_DIR && docker compose up -d --build"
    else
        info "$(printf "$RMSG_DEPLOY_ENV_EXISTS" "$APP_DIR")"
    fi
    mark_done "step_env"
fi

# === BUILD ET DEMARRAGE ===
CURRENT_STEP="build_docker"
if is_done "step_docker"; then
    skip_step "$RMSG_DEPLOY_DOCKER_TITLE"
else
echo ""
echo -e "${BOLD}${YELLOW}[>] $RMSG_DEPLOY_DOCKER_TITLE${NC}"
echo "$RMSG_DEPLOY_DOCKER_DETECT"
echo ""

COMPOSE_FILE=""
for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [ -f "$APP_DIR/$f" ]; then
        COMPOSE_FILE="$f"
        break
    fi
done

if [ -n "$COMPOSE_FILE" ]; then
    info "$(printf "$RMSG_DEPLOY_COMPOSE_DETECTED" "$COMPOSE_FILE")"
    echo "$RMSG_DEPLOY_COMPOSE_LAUNCHING"
    echo ""
    cd "$APP_DIR"
    if ! sudo -u "$USERNAME" docker compose up -d --build 2>&1; then
        err "$RMSG_DEPLOY_COMPOSE_FAILED"
        echo ""
        echo "$RMSG_DEPLOY_COMPOSE_FAILED_LOGS"
        sudo -u "$USERNAME" docker compose logs --tail=20 2>/dev/null || true
        echo ""
        echo "$RMSG_DEPLOY_COMPOSE_FAILED_SEE_ALL"
        echo "    cd $APP_DIR && docker compose logs"
        exit 1
    fi
    echo ""
    success "$RMSG_DEPLOY_COMPOSE_SUCCESS"
elif [ -f "$APP_DIR/Dockerfile" ]; then
    info "$RMSG_DEPLOY_DOCKERFILE_DETECTED"
    echo "$RMSG_DEPLOY_DOCKER_BUILD_HINT"
    echo ""
    if ! sudo -u "$USERNAME" docker build -t "$APP_NAME" "$APP_DIR"; then
        err "$RMSG_DEPLOY_DOCKER_BUILD_FAILED"
        echo ""
        echo "$RMSG_DEPLOY_DOCKER_BUILD_FAILED_HINT"
        exit 1
    fi

    # Arrêter le conteneur existant s'il tourne
    if docker ps -a -q -f "name=^${APP_NAME}$" | grep -q .; then
        info "$RMSG_DEPLOY_DOCKER_STOP_OLD"
        docker stop "$APP_NAME" 2>/dev/null || true
        docker rm "$APP_NAME" 2>/dev/null || true
    fi

    DOCKER_RUN_ARGS="-d --name $APP_NAME --restart unless-stopped -p 127.0.0.1:${APP_PORT}:${APP_PORT}"
    if [ -f "$APP_DIR/.env" ]; then
        DOCKER_RUN_ARGS="$DOCKER_RUN_ARGS --env-file $APP_DIR/.env"
    fi

    if ! sudo -u "$USERNAME" docker run $DOCKER_RUN_ARGS "$APP_NAME"; then
        err "$RMSG_DEPLOY_DOCKER_RUN_FAILED"
        echo ""
        echo "$RMSG_DEPLOY_DOCKER_RUN_FAILED_LOGS"
        docker logs "$APP_NAME" --tail=20 2>/dev/null || true
        exit 1
    fi
    echo ""
    success "$(printf "$RMSG_DEPLOY_DOCKER_SUCCESS" "$APP_PORT")"
else
    err "$RMSG_DEPLOY_DOCKER_NONE"
    echo ""
    echo "$RMSG_DEPLOY_DOCKER_NONE_HINT1"
    echo "$RMSG_DEPLOY_DOCKER_NONE_HINT2"
    echo "$RMSG_DEPLOY_DOCKER_NONE_HINT3"
    echo ""
    echo "$RMSG_DEPLOY_DOCKER_NONE_HINT4"
    exit 1
fi

mark_done "step_docker"
fi
# Fin du bloc step_docker

# === VERIFICATION DNS ===
CURRENT_STEP="verification_dns"
echo ""
echo -e "${BOLD}${YELLOW}[>] $RMSG_DEPLOY_DNS_TITLE${NC}"
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
DOMAIN_IP=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' || true)

if [ -z "$DOMAIN_IP" ]; then
    warn "$(printf "$RMSG_DEPLOY_DNS_NO_IP" "$DOMAIN")"
    echo "$RMSG_DEPLOY_DNS_NO_IP_HINT1"
    echo "$(printf "$RMSG_DEPLOY_DNS_NO_IP_HINT2" "$SERVER_IP")"
    echo ""
    echo "$RMSG_DEPLOY_DNS_NO_IP_CONFIGURE"
    echo "    $DOMAIN -> $SERVER_IP"
    echo ""
elif [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
    warn "$(printf "$RMSG_DEPLOY_DNS_WRONG_IP" "$DOMAIN" "$DOMAIN_IP" "$SERVER_IP")"
    echo "$RMSG_DEPLOY_DNS_WRONG_IP_HINT"
    echo ""
else
    success "$(printf "$RMSG_DEPLOY_DNS_OK" "$DOMAIN")"
fi

# === CONFIGURATION DU DOMAINE ===
CURRENT_STEP="configuration_caddy"
if is_done "step_caddy"; then
    skip_step "$RMSG_DEPLOY_CADDY_TITLE"
else
echo ""
echo -e "${BOLD}${YELLOW}[>] $RMSG_DEPLOY_CADDY_TITLE${NC}"
echo "$(printf "$RMSG_DEPLOY_CADDY_INTRO1" "$DOMAIN")"
echo "$RMSG_DEPLOY_CADDY_INTRO2"
echo ""

if ! command -v caddy &>/dev/null; then
    warn "$RMSG_DEPLOY_CADDY_NOT_INSTALLED"
    echo "$RMSG_DEPLOY_CADDY_NOT_INSTALLED_HINT1"
    echo "$RMSG_DEPLOY_CADDY_NOT_INSTALLED_HINT2"
else
    CADDYFILE="/etc/caddy/Caddyfile"

    # Sauvegarder le Caddyfile
    cp "$CADDYFILE" "${CADDYFILE}.bak"

    # Vérifier si le domaine est déjà configuré
    if grep -qF "${DOMAIN}" "$CADDYFILE" 2>/dev/null; then
        info "$(printf "$RMSG_DEPLOY_CADDY_DOMAIN_UPDATING" "$DOMAIN")"
        # Supprimer le bloc Caddy existant (gere les blocs imbriques)
        awk -v domain="$DOMAIN" '
        BEGIN { skip=0; depth=0 }
        skip==0 && /{/ {
            pos = index($0, domain)
            if (pos > 0) {
                before = (pos > 1) ? substr($0, pos-1, 1) : ""
                after = substr($0, pos + length(domain), 1)
                if (before !~ /[a-zA-Z0-9._-]/ && after !~ /[a-zA-Z0-9._-]/) {
                    skip=1; depth=1; next
                }
            }
        }
        skip==1 {
            for (i=1; i<=length($0); i++) {
                c = substr($0, i, 1)
                if (c == "{") depth++
                if (c == "}") depth--
            }
            if (depth <= 0) { skip=0 }
            next
        }
        { print }
        ' "$CADDYFILE" > "${CADDYFILE}.tmp" && mv "${CADDYFILE}.tmp" "$CADDYFILE"
    fi

    # Ajouter le nouveau bloc (avec redirection www si domaine racine)
    if echo "$DOMAIN" | grep -qvE "^(www\.|.*\..*\..*)"; then
        # Domaine racine (ex: dommsoft.com) → ajouter www redirect
        cat >> "$CADDYFILE" << CADDY_BLOCK

${DOMAIN}, www.${DOMAIN} {
    reverse_proxy localhost:${APP_PORT}
}
CADDY_BLOCK
    else
        cat >> "$CADDYFILE" << CADDY_BLOCK

${DOMAIN} {
    reverse_proxy localhost:${APP_PORT}
}
CADDY_BLOCK
    fi

    # Valider la configuration avant de recharger
    if caddy validate --config "$CADDYFILE" --adapter caddyfile 2>/dev/null; then
        if systemctl reload caddy 2>/dev/null; then
            success "$RMSG_DEPLOY_CADDY_SUCCESS"
        else
            err "$RMSG_DEPLOY_CADDY_RELOAD_FAILED"
            echo "$RMSG_DEPLOY_CADDY_RELOAD_FAILED_HINT"
        fi
    else
        err "$RMSG_DEPLOY_CADDY_CONFIG_ERROR"
        cp "${CADDYFILE}.bak" "$CADDYFILE"
        systemctl reload caddy 2>/dev/null
        warn "$RMSG_DEPLOY_CADDY_CONFIG_RESTORED"
    fi
fi

mark_done "step_caddy"
fi
# Fin du bloc step_caddy

# =========================================
# VERIFICATION DE L'APPLICATION
# =========================================

CURRENT_STEP="verification_application"
echo ""
echo -e "${BOLD}${YELLOW}[>] $RMSG_DEPLOY_HEALTH_TITLE${NC}"
echo "$RMSG_DEPLOY_HEALTH_WAIT"
sleep 5

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${APP_PORT}" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "000" ]; then
    warn "$(printf "$RMSG_DEPLOY_HEALTH_NOT_RESPONDING" "$APP_PORT")"
    echo ""
    echo "$RMSG_DEPLOY_HEALTH_NOT_RESPONDING_HINT1"
    echo "$RMSG_DEPLOY_HEALTH_NOT_RESPONDING_HINT2"
    echo "    docker logs $APP_NAME --tail=30"
    echo "    ou : cd $APP_DIR && docker compose logs --tail=30"
elif [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 400 ]; then
    success "$(printf "$RMSG_DEPLOY_HEALTH_OK" "$HTTP_CODE")"
else
    warn "$(printf "$RMSG_DEPLOY_HEALTH_WARN" "$HTTP_CODE")"
fi

# =========================================
# SAUVEGARDE DES METADONNEES
# =========================================

CURRENT_STEP="sauvegarde_metadonnees"
if ! is_done "step_meta"; then
    echo "$DOMAIN" > "$APP_DIR/.deploy-domain"
    echo "$APP_PORT" > "$APP_DIR/.deploy-port"
    chown "$USERNAME:$USERNAME" "$APP_DIR/.deploy-domain" "$APP_DIR/.deploy-port"

    if [ -n "$DEPLOY_TAG" ]; then
        echo "$DEPLOY_TAG" > "$APP_DIR/.deploy-branch"
    elif [ -n "$DEPLOY_BRANCH" ]; then
        echo "$DEPLOY_BRANCH" > "$APP_DIR/.deploy-branch"
    else
        echo "main" > "$APP_DIR/.deploy-branch"
    fi
    chown "$USERNAME:$USERNAME" "$APP_DIR/.deploy-branch"
    mark_done "step_meta"
fi

# =========================================
# HISTORIQUE DE DEPLOIEMENT
# =========================================

CURRENT_STEP="historique"
if ! is_done "step_history"; then
    HISTORY_FILE="/home/$USERNAME/.deploy-history"
    DEPLOY_DATE=$(date '+%Y-%m-%d %H:%M:%S')
    DEPLOY_COMMIT=$(cd "$APP_DIR" && sudo -u "$USERNAME" git rev-parse --short HEAD 2>/dev/null || echo "$RMSG_ROLLBACK_FALLBACK_UNKNOWN")
    DEPLOY_BRANCH_INFO=""
    if [ -n "$DEPLOY_TAG" ]; then
        DEPLOY_BRANCH_INFO="$DEPLOY_TAG"
    elif [ -n "$DEPLOY_BRANCH" ]; then
        DEPLOY_BRANCH_INFO="$DEPLOY_BRANCH"
    else
        DEPLOY_BRANCH_INFO=$(cd "$APP_DIR" && sudo -u "$USERNAME" git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    fi

    echo "$DEPLOY_DATE | $APP_NAME | $DEPLOY_COMMIT | $DEPLOY_BRANCH_INFO | $DOMAIN | deploy" >> "$HISTORY_FILE"

    # Garder les 50 dernieres entrees
    if [ -f "$HISTORY_FILE" ]; then
        TOTAL_LINES=$(wc -l < "$HISTORY_FILE")
        if [ "$TOTAL_LINES" -gt 50 ]; then
            tail -n 50 "$HISTORY_FILE" > "${HISTORY_FILE}.tmp"
            mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
        fi
    fi
    chown "$USERNAME:$USERNAME" "$HISTORY_FILE"
    mark_done "step_history"
fi

# =========================================
# NETTOYAGE DOCKER
# =========================================

CURRENT_STEP="nettoyage_docker"
echo ""
echo -e "${BOLD}${YELLOW}[>] $RMSG_DEPLOY_PRUNE_TITLE${NC}"

PRUNE_OUTPUT=$(docker image prune -f 2>/dev/null || true)
PRUNE_SIZE=$(echo "$PRUNE_OUTPUT" | grep -ioE '[0-9.]+ ?[kKmMgGtT]?B' | tail -1 || echo "")
if [ -n "$PRUNE_SIZE" ] && [ "$PRUNE_SIZE" != "0B" ]; then
    success "$(printf "$RMSG_DEPLOY_PRUNE_IMAGES_DONE" "$PRUNE_SIZE")"
else
    info "$RMSG_DEPLOY_PRUNE_IMAGES_NONE"
fi

BUILD_OUTPUT=$(docker builder prune -f --filter "until=24h" 2>/dev/null || true)
BUILD_SIZE=$(echo "$BUILD_OUTPUT" | grep -ioE '[0-9.]+ ?[kKmMgGtT]?B' | tail -1 || echo "")
if [ -n "$BUILD_SIZE" ] && [ "$BUILD_SIZE" != "0B" ]; then
    success "$(printf "$RMSG_DEPLOY_PRUNE_BUILD_DONE" "$BUILD_SIZE")"
fi

# =========================================
# C'EST TERMINE !
# =========================================

# Supprimer le fichier de progression (deploiement reussi)
rm -f "$PROGRESS_FILE"

echo ""
echo "========================================="
echo -e "  ${GREEN}$RMSG_DEPLOY_DONE_TITLE${NC}"
echo "========================================="
echo ""
echo "$(printf "$RMSG_DEPLOY_DONE_APP" "$APP_NAME")"
echo "$(printf "$RMSG_DEPLOY_DONE_URL" "$DOMAIN")"
if [ -n "$DEPLOY_TAG" ]; then
    echo "$(printf "$RMSG_DEPLOY_DONE_TAG" "$DEPLOY_TAG")"
elif [ -n "$DEPLOY_BRANCH" ]; then
    echo "$(printf "$RMSG_DEPLOY_DONE_BRANCH" "$DEPLOY_BRANCH")"
fi
echo "$(printf "$RMSG_DEPLOY_DONE_DIR" "$APP_DIR")"
echo ""
echo "$RMSG_DEPLOY_DONE_SSL"
echo ""
echo "$RMSG_DEPLOY_DONE_CMDS_TITLE"
echo "$(printf "$RMSG_DEPLOY_DONE_CMD_LOGS" "$APP_NAME")"
echo "$(printf "$RMSG_DEPLOY_DONE_CMD_RESTART" "$APP_DIR")"
echo "$(printf "$RMSG_DEPLOY_DONE_CMD_STOP" "$APP_DIR")"
echo "========================================="
DEPLOY_EOF

inject_lang_into_remote "$TMPSCRIPT"

# =========================================
# REMPLACEMENT DES PLACEHOLDERS
# =========================================

HAS_ENV="false"
if [ -n "$ENV_FILE" ]; then
    HAS_ENV="true"
fi

# CREATE_EMPTY_ENV est défini en mode interactif, sinon false par défaut
CREATE_EMPTY_ENV=${CREATE_EMPTY_ENV:-false}
DEPLOY_BRANCH=${DEPLOY_BRANCH:-}
DEPLOY_TAG=${DEPLOY_TAG:-}

# Echapper toutes les valeurs utilisateur pour sed
SAFE_APP=$(sed_escape "$APP_NAME")
SAFE_REPO=$(sed_escape "$REPO_URL")
SAFE_DOMAIN=$(sed_escape "$DOMAIN")
SAFE_PORT=$(sed_escape "$APP_PORT")
SAFE_USER=$(sed_escape "$USERNAME")
SAFE_BRANCH=$(sed_escape "$DEPLOY_BRANCH")
SAFE_TAG=$(sed_escape "$DEPLOY_TAG")

if [ "$OS" = "mac" ]; then
    sed -i '' "s|__APP_NAME__|$SAFE_APP|g" "$TMPSCRIPT"
    sed -i '' "s|__REPO_URL__|$SAFE_REPO|g" "$TMPSCRIPT"
    sed -i '' "s|__DOMAIN__|$SAFE_DOMAIN|g" "$TMPSCRIPT"
    sed -i '' "s|__APP_PORT__|$SAFE_PORT|g" "$TMPSCRIPT"
    sed -i '' "s|__USERNAME__|$SAFE_USER|g" "$TMPSCRIPT"
    sed -i '' "s|__HAS_ENV__|$(sed_escape "$HAS_ENV")|g" "$TMPSCRIPT"
    sed -i '' "s|__CREATE_EMPTY_ENV__|$(sed_escape "$CREATE_EMPTY_ENV")|g" "$TMPSCRIPT"
    sed -i '' "s|__DEPLOY_BRANCH__|$SAFE_BRANCH|g" "$TMPSCRIPT"
    sed -i '' "s|__DEPLOY_TAG__|$SAFE_TAG|g" "$TMPSCRIPT"
else
    sed -i "s|__APP_NAME__|$SAFE_APP|g" "$TMPSCRIPT"
    sed -i "s|__REPO_URL__|$SAFE_REPO|g" "$TMPSCRIPT"
    sed -i "s|__DOMAIN__|$SAFE_DOMAIN|g" "$TMPSCRIPT"
    sed -i "s|__APP_PORT__|$SAFE_PORT|g" "$TMPSCRIPT"
    sed -i "s|__USERNAME__|$SAFE_USER|g" "$TMPSCRIPT"
    sed -i "s|__HAS_ENV__|$(sed_escape "$HAS_ENV")|g" "$TMPSCRIPT"
    sed -i "s|__CREATE_EMPTY_ENV__|$(sed_escape "$CREATE_EMPTY_ENV")|g" "$TMPSCRIPT"
    sed -i "s|__DEPLOY_BRANCH__|$SAFE_BRANCH|g" "$TMPSCRIPT"
    sed -i "s|__DEPLOY_TAG__|$SAFE_TAG|g" "$TMPSCRIPT"
fi

# =========================================
# ENVOI ET EXÉCUTION
# =========================================

# Envoyer le fichier .env si nécessaire
if [ -n "$ENV_FILE" ]; then
    info "$MSG_DEPLOY_ENV_SENDING"
    if ! scp -i "$SSH_KEY" "$ENV_FILE" "${USERNAME}@${VPS_IP}:/tmp/.env-${APP_NAME}"; then
        err "$MSG_DEPLOY_ENV_SEND_FAILED"
        rm -f "$TMPSCRIPT"
        exit 1
    fi
    success "$MSG_DEPLOY_ENV_SENT"
fi

# Envoyer et exécuter le script distant
info "$MSG_DEPLOY_SCRIPT_SENDING"
REMOTE_TMP=$(ssh -i "$SSH_KEY" -o BatchMode=yes "${USERNAME}@${VPS_IP}" "mktemp /tmp/vps-XXXXXXXXXX.sh")
if ! scp -i "$SSH_KEY" "$TMPSCRIPT" "${USERNAME}@${VPS_IP}:${REMOTE_TMP}"; then
    err "$MSG_DEPLOY_SCRIPT_SEND_FAILED"
    rm -f "$TMPSCRIPT"
    exit 1
fi
rm -f "$TMPSCRIPT"

info "$MSG_DEPLOY_EXECUTING"

# Détection TTY pour compatibilité CI/CD
if [ -t 0 ]; then
    SSH_TTY_FLAG="-t"
else
    SSH_TTY_FLAG=""
fi

ssh $SSH_TTY_FLAG -i "$SSH_KEY" "${USERNAME}@${VPS_IP}" "chmod 700 '${REMOTE_TMP}'; sudo bash '${REMOTE_TMP}'; rm -f '${REMOTE_TMP}'"

# =========================================
# RÉSUMÉ LOCAL
# =========================================

echo ""
echo -e "${BOLD}$MSG_DEPLOY_DONE_TITLE${NC}"
echo ""
echo "$MSG_DEPLOY_DONE_URL"
echo ""
echo -e "    ${GREEN}https://${DOMAIN}${NC}"
echo ""
if [ "$CREATE_EMPTY_ENV" = "true" ]; then
    echo ""
    echo -e "  ${YELLOW}$MSG_DEPLOY_DONE_ENV_REMINDER${NC}"
    echo ""
    echo "    ssh -i $SSH_KEY ${USERNAME}@${VPS_IP}"
    echo "    nano ~/apps/${APP_NAME}/.env"
    echo ""
    echo "$MSG_DEPLOY_DONE_ENV_RESTART"
    echo "    cd ~/apps/${APP_NAME} && docker compose up -d --build"
fi

echo ""
echo "$MSG_DEPLOY_DONE_REDEPLOY"
echo ""
if [ "$INTERACTIVE" = true ]; then
    echo -e "    ${GREEN}bash deploy.sh${NC}"
else
    echo -e "    ${GREEN}bash deploy.sh -ip $VPS_IP -key $SSH_KEY -user $USERNAME -app $APP_NAME -repo $REPO_URL -domain $DOMAIN -port $APP_PORT${NC}"
fi
echo ""
echo "========================================="
