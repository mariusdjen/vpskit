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
            err "Argument inconnu : $1"
            echo "  Usage : bash deploy.sh -ip IP -key CLÉ -user USER -app NOM -repo URL -domain DOMAINE [-port PORT] [-env FICHIER] [-branch BRANCHE] [-tag TAG] [--rollback]"
            exit 1
            ;;
    esac
done

# Si les deux sont fournis, le tag a priorite
if [ -n "$DEPLOY_TAG" ] && [ -n "$DEPLOY_BRANCH" ]; then
    warn "Les options -branch et -tag sont mutuellement exclusives. Le tag sera utilise."
    DEPLOY_BRANCH=""
fi

# =========================================
# MODE INTERACTIF
# =========================================

if [ "$INTERACTIVE" = true ]; then

    echo ""
    echo "========================================="
    echo -e "  ${BOLD}VPS DEPLOY${NC}"
    echo "  Déploie une application sur votre VPS"
    echo "========================================="
    echo ""
    echo "  Ce script va :"
    echo "    1. Se connecter à votre VPS"
    echo "    2. Configurer l'accès à votre dépôt GitHub (si besoin)"
    echo "    3. Télécharger votre application"
    echo "    4. La lancer avec Docker"
    echo "    5. La rendre accessible sur votre domaine (HTTPS automatique)"
    echo ""
    echo "  On y va étape par étape."
    echo ""

    # =========================================
    # ÉTAPE 1 : CONNEXION AU VPS
    # =========================================

    echo -e "${BOLD}${YELLOW}[>] Étape 1 : Connexion au VPS${NC}"
    echo "  On a besoin des informations de votre serveur."
    echo ""

    SSH_DIR="$HOME/.ssh"
    LOCAL_STATE="$SSH_DIR/.vps-bootstrap-local"

    if [ -f "$LOCAL_STATE" ]; then
        VPS_IP=$(read_state_var "$LOCAL_STATE" "VPS_IP")
        SSH_KEY=$(read_state_var "$LOCAL_STATE" "SSH_KEY")
        USERNAME=$(read_state_var "$LOCAL_STATE" "USERNAME")
        success "Session vps-bootstrap détectée :"
        echo ""
        echo "    Serveur  : $VPS_IP"
        echo "    Clé SSH  : $(basename "$SSH_KEY")"
        echo "    User     : $USERNAME"
        echo ""
        read -p "  C'est bien votre serveur ? (o/N) : " USE_SESSION
        if [[ "$USE_SESSION" != "o" && "$USE_SESSION" != "O" ]]; then
            VPS_IP=""
            SSH_KEY=""
            USERNAME=""
        fi
    else
        info "Aucune session vps-bootstrap trouvée."
        echo "  Si vous avez utilisé setup.sh avant, les infos sont normalement sauvegardées."
        echo "  Sinon, pas de souci, on va les demander."
        echo ""
    fi

    if [ -z "$VPS_IP" ]; then
        echo "  L'adresse IP de votre VPS se trouve dans le tableau de bord"
        echo "  de votre hébergeur (OVH, Hetzner, DigitalOcean, etc.)."
        echo ""
        read -p "  Adresse IP du VPS : " VPS_IP
    fi
    if [ -z "$SSH_KEY" ]; then
        echo ""
        echo "  La clé SSH est le fichier qui vous permet de vous connecter"
        echo "  au serveur sans mot de passe. Elle se trouve dans ~/.ssh/"
        echo ""
        read -p "  Chemin de la clé SSH (ex: ~/.ssh/id_ed25519) : " SSH_KEY
    fi
    if [ -z "$USERNAME" ]; then
        echo ""
        read -p "  Nom d'utilisateur sur le VPS (défaut: deploy) : " USERNAME
        USERNAME=${USERNAME:-deploy}
    fi

    echo ""

    # =========================================
    # DERNIERS DEPLOIEMENTS
    # =========================================

    DEPLOY_HISTORY=$(ssh -i "$SSH_KEY" -o ConnectTimeout=5 -o BatchMode=yes "${USERNAME}@${VPS_IP}" "tail -n 5 ~/.deploy-history 2>/dev/null" 2>/dev/null || true)
    if [ -n "$DEPLOY_HISTORY" ]; then
        info "Derniers deploiements :"
        echo ""
        while IFS= read -r line; do
            echo "    $line"
        done <<< "$DEPLOY_HISTORY"
        echo ""
    fi

    # =========================================
    # CHOIX : DEPLOYER OU REVENIR EN ARRIERE
    # =========================================

    echo -e "${BOLD}${YELLOW}[>] Que souhaitez-vous faire ?${NC}"
    echo ""
    echo "    1) Déployer une application"
    echo "    2) Revenir en arrière (rollback)"
    echo ""
    read -p "  Votre choix (1/2) : " DEPLOY_CHOICE
    echo ""

    if [ "$DEPLOY_CHOICE" = "2" ]; then
        ROLLBACK=true

        # Lister les apps existantes sur le serveur
        info "Récupération des applications déployées..."
        APPS_LIST=$(ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes "${USERNAME}@${VPS_IP}" "ls -1 ~/apps/ 2>/dev/null" || true)

        if [ -z "$APPS_LIST" ]; then
            err "Aucune application déployée sur ce serveur."
            exit 1
        fi

        echo ""
        echo "  Applications déployées :"
        echo ""
        INDEX=1
        while IFS= read -r app; do
            echo "    $INDEX) $app"
            INDEX=$((INDEX + 1))
        done <<< "$APPS_LIST"
        echo ""
        read -p "  Quelle application restaurer ? : " APP_CHOICE

        if ! [[ "$APP_CHOICE" =~ ^[0-9]+$ ]]; then
            err "Choix invalide : entrez un numero."
            exit 1
        fi

        APP_NAME=$(echo "$APPS_LIST" | sed -n "${APP_CHOICE}p")
        if [ -z "$APP_NAME" ]; then
            err "Choix invalide."
            exit 1
        fi

        success "Application sélectionnée : $APP_NAME"

        # Vérifier qu'un commit précédent existe
        HAS_PREVIOUS=$(ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes "${USERNAME}@${VPS_IP}" "cat ~/apps/${APP_NAME}/.last-working-commit 2>/dev/null" || true)
        if [ -z "$HAS_PREVIOUS" ]; then
            err "Aucun commit précédent trouvé pour $APP_NAME."
            echo "  Le rollback n'est possible qu'après au moins une mise à jour."
            exit 1
        fi

        echo ""
        info "Commit précédent : $HAS_PREVIOUS"
        read -p "  Confirmer le rollback ? (o/N) : " CONFIRM_ROLLBACK
        if [[ "$CONFIRM_ROLLBACK" != "o" && "$CONFIRM_ROLLBACK" != "O" ]]; then
            info "Rollback annulé."
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

    echo -e "${BOLD}${YELLOW}[>] Étape 2 : Votre application${NC}"
    echo "  On a besoin de l'adresse de votre dépôt Git."
    echo ""
    echo "  Où trouver l'URL ?"
    echo "    - Allez sur votre dépôt GitHub"
    echo "    - Cliquez le bouton vert 'Code'"
    echo "    - Copiez l'URL (HTTPS ou SSH, les deux fonctionnent)"
    echo ""
    read -p "  URL du dépôt Git : " REPO_URL

    # Suggestion du nom depuis le repo
    SUGGESTED_NAME=""
    if echo "$REPO_URL" | grep -q '/'; then
        SUGGESTED_NAME=$(basename "$REPO_URL" .git)
    fi

    echo ""
    echo "  Le nom de l'application sert à identifier votre projet sur le serveur."
    echo "  Il sera utilisé comme nom de dossier dans ~/apps/"
    echo ""
    if [ -n "$SUGGESTED_NAME" ]; then
        read -p "  Nom de l'application (défaut: $SUGGESTED_NAME) : " APP_NAME_INPUT
        APP_NAME=${APP_NAME_INPUT:-$SUGGESTED_NAME}
    else
        read -p "  Nom de l'application : " APP_NAME
    fi

    # =========================================
    # CHOIX DE LA BRANCHE / TAG
    # =========================================

    echo ""
    echo "  Par defaut, la branche principale (main/master) sera deployee."
    echo "  Vous pouvez aussi choisir une branche ou un tag specifique."
    echo ""
    echo "    1) Branche par defaut (main/master)"
    echo "    2) Choisir une branche"
    echo "    3) Choisir un tag"
    echo ""
    read -p "  Votre choix (1/2/3) : " BRANCH_CHOICE
    case "$BRANCH_CHOICE" in
        2)
            read -p "  Nom de la branche : " DEPLOY_BRANCH
            ;;
        3)
            read -p "  Nom du tag : " DEPLOY_TAG
            ;;
        *)
            :
            ;;
    esac

    # =========================================
    # ÉTAPE 3 : DOMAINE ET CONFIGURATION
    # =========================================

    echo ""
    echo -e "${BOLD}${YELLOW}[>] Étape 3 : Domaine et configuration${NC}"
    echo "  Pour que votre application soit accessible sur internet,"
    echo "  vous avez besoin d'un nom de domaine qui pointe vers votre VPS."
    echo ""
    echo "  Assurez-vous que le DNS de votre domaine pointe vers $VPS_IP"
    echo "  (enregistrement A chez votre registrar : OVH, Namecheap, etc.)"
    echo ""
    read -p "  Nom de domaine (ex: monapp.example.com) : " DOMAIN
    # Nettoyer le domaine (retirer https://, http://, slash final)
    DOMAIN=$(echo "$DOMAIN" | sed 's|^https://||;s|^http://||;s|/$||')

    echo ""
    echo "  Le port est le numéro sur lequel votre application écoute."
    echo "  Si vous ne savez pas, laissez la valeur par défaut."
    echo ""
    read -p "  Port de l'application (défaut: 3000) : " APP_PORT_INPUT
    APP_PORT=${APP_PORT_INPUT:-3000}

    # =========================================
    # ÉTAPE 4 : VARIABLES D'ENVIRONNEMENT
    # =========================================

    echo ""
    echo -e "${BOLD}${YELLOW}[>] Étape 4 : Variables d'environnement${NC}"
    echo "  Certaines applications ont besoin d'un fichier .env"
    echo "  (clés API, mots de passe de base de données, etc.)"
    echo ""
    read -p "  Votre application a-t-elle un fichier .env ? (o/N) : " NEED_ENV
    CREATE_EMPTY_ENV="false"
    if [[ "$NEED_ENV" == "o" || "$NEED_ENV" == "O" ]]; then
        echo ""
        echo "  Indiquez le chemin du fichier .env sur votre machine."
        echo "  Vous pouvez aussi glisser-déposer le fichier dans le terminal."
        echo ""
        read -p "  Chemin du fichier .env : " ENV_FILE

        # Nettoyage du chemin (espaces, guillemets, ~, antislash macOS drag-and-drop, slash final)
        ENV_FILE=$(echo "$ENV_FILE" | sed "s|^['\"]||;s|['\"]$||;s|^~|$HOME|;s|\\\\ | |g;s|[[:space:]]*$||;s|/$||")

        # Si c'est un dossier, chercher .env dedans
        if [ -d "$ENV_FILE" ]; then
            if [ -f "$ENV_FILE/.env" ]; then
                ENV_FILE="$ENV_FILE/.env"
                success "Fichier trouvé : $ENV_FILE"
            fi
        fi

        # Si toujours introuvable, proposer des alternatives
        while [ -n "$ENV_FILE" ] && [ ! -f "$ENV_FILE" ]; do
            echo ""
            warn "Fichier introuvable : $ENV_FILE"
            echo ""
            echo "  Que souhaitez-vous faire ?"
            echo "    1) Entrer un autre chemin"
            echo "    2) Continuer sans fichier .env (vous le remplirez sur le serveur)"
            echo ""
            read -p "  Votre choix (1/2) : " ENV_CHOICE
            case "$ENV_CHOICE" in
                1)
                    echo ""
                    read -p "  Nouveau chemin du fichier .env : " ENV_FILE
                    ENV_FILE=$(echo "$ENV_FILE" | sed "s|^['\"]||;s|['\"]$||;s|^~|$HOME|;s|\\\\ | |g;s|[[:space:]]*$||;s|/$||")
                    if [ -d "$ENV_FILE" ]; then
                        if [ -f "$ENV_FILE/.env" ]; then
                            ENV_FILE="$ENV_FILE/.env"
                            success "Fichier trouvé : $ENV_FILE"
                        fi
                    fi
                    ;;
                *)
                    ENV_FILE=""
                    CREATE_EMPTY_ENV="true"
                    echo ""
                    info "Un fichier .env vide sera créé sur le serveur."
                    echo "  Après le déploiement, connectez-vous et remplissez-le :"
                    echo ""
                    echo "    ssh -i ~/.ssh/$(basename "$SSH_KEY") ${USERNAME}@${VPS_IP}"
                    echo "    nano ~/apps/${APP_NAME}/.env"
                    echo ""
                    ;;
            esac
        done

        if [ -f "$ENV_FILE" ] 2>/dev/null; then
            success "Fichier .env trouvé : $ENV_FILE"
        fi
    fi

    # =========================================
    # RÉCAPITULATIF AVANT DÉPLOIEMENT
    # =========================================

    echo ""
    echo "========================================="
    echo -e "  ${BOLD}Récapitulatif${NC}"
    echo "========================================="
    echo ""
    echo "    Serveur     : $VPS_IP ($USERNAME)"
    echo "    Application : $APP_NAME"
    echo "    Dépôt Git   : $REPO_URL"
    echo "    Domaine     : $DOMAIN"
    echo "    Port        : $APP_PORT"
    if [ -n "$DEPLOY_TAG" ]; then
        echo "    Tag         : $DEPLOY_TAG"
    elif [ -n "$DEPLOY_BRANCH" ]; then
        echo "    Branche     : $DEPLOY_BRANCH"
    fi
    if [ -n "$ENV_FILE" ]; then
        echo "    Fichier .env: $ENV_FILE"
    elif [ "$CREATE_EMPTY_ENV" = "true" ]; then
        echo "    Fichier .env: (vide, à remplir sur le serveur)"
    fi
    echo ""
    read -p "  Lancer le déploiement ? (o/N) : " CONFIRM_DEPLOY
    if [[ "$CONFIRM_DEPLOY" != "o" && "$CONFIRM_DEPLOY" != "O" ]]; then
        info "Déploiement annulé."
        exit 0
    fi

    fi  # fin du else (deploy vs rollback)
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
    err "Clé SSH introuvable : ${SSH_KEY:-non spécifiée}"
    ERRORS=$((ERRORS + 1))
fi
if [ -z "$USERNAME" ]; then
    err "Nom d'utilisateur requis."
    ERRORS=$((ERRORS + 1))
fi
if [ -z "$APP_NAME" ]; then
    err "Nom de l'application requis."
    ERRORS=$((ERRORS + 1))
fi

if [ "$ROLLBACK" = false ]; then
    if [ -z "$REPO_URL" ]; then
        err "URL du dépôt Git requise."
        ERRORS=$((ERRORS + 1))
    fi
    if [ -z "$DOMAIN" ]; then
        err "Nom de domaine requis."
        ERRORS=$((ERRORS + 1))
    fi
    if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]]; then
        err "Port invalide : $APP_PORT"
        ERRORS=$((ERRORS + 1))
    fi
    if [ -n "$ENV_FILE" ] && [ ! -f "$ENV_FILE" ]; then
        # En mode CI/CD, bloquer. En mode interactif, déjà géré.
        if [ "$INTERACTIVE" = false ]; then
            err "Fichier .env introuvable : $ENV_FILE"
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
    warn "Nom d'application nettoyé : $CLEAN_APP_NAME"
    APP_NAME="$CLEAN_APP_NAME"
fi

# --- Validation IP ---
if ! echo "$VPS_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    err "Adresse IP invalide : $VPS_IP"
    echo "  L'adresse doit être au format : 123.45.67.89"
    exit 1
fi

# --- Test connexion SSH ---
info "Test de connexion au serveur..."
if ! ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes "${USERNAME}@${VPS_IP}" "echo ok" &>/dev/null; then
    err "Impossible de se connecter à ${USERNAME}@${VPS_IP}"
    echo ""
    echo "  Causes possibles :"
    echo "    - L'adresse IP est incorrecte"
    echo "    - Le VPS est éteint ou redémarre"
    echo "    - Le pare-feu bloque le port 22"
    echo "    - La clé SSH n'est pas la bonne"
    echo ""
    echo "  Pour diagnostiquer :"
    echo "    ssh -v -i $SSH_KEY ${USERNAME}@${VPS_IP}"
    exit 1
fi
success "Connexion SSH vérifiée."

# =========================================
# MODE ROLLBACK
# =========================================

if [ "$ROLLBACK" = true ]; then
    TMPSCRIPT=$(mktemp)
    trap 'rm -f "$TMPSCRIPT"' EXIT
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
echo -e "  ${BOLD}ROLLBACK : $APP_NAME${NC}"
echo "========================================="
echo ""

if [ ! -d "$APP_DIR" ]; then
    err "Application introuvable : $APP_DIR"
    exit 1
fi

cd "$APP_DIR"

LAST_COMMIT_FILE="$APP_DIR/.last-working-commit"

if [ ! -f "$LAST_COMMIT_FILE" ]; then
    err "Aucun commit precedent trouve."
    echo "  Le rollback n'est possible qu'apres au moins une mise a jour."
    exit 1
fi

LAST_COMMIT=$(cat "$LAST_COMMIT_FILE")
CURRENT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "inconnu")

info "Commit actuel    : $CURRENT_COMMIT"
info "Rollback vers    : $LAST_COMMIT"
echo ""

# Restaurer le commit precedent
info "Restauration du code..."
sudo -u "$USERNAME" git checkout "$LAST_COMMIT" 2>/dev/null
success "Code restaure."

# Rebuild Docker
echo ""
info "Reconstruction et relancement de l'application..."

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
    success "Application relancee avec Docker Compose."
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
    success "Application relancee."
else
    warn "Aucun fichier Docker trouve. Code restaure mais application non relancee."
fi

# Historique
HISTORY_FILE="/home/$USERNAME/.deploy-history"
DEPLOY_DATE=$(date '+%Y-%m-%d %H:%M:%S')
ROLLBACK_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "inconnu")
ROLLBACK_DOMAIN=""
if [ -f "$APP_DIR/.deploy-domain" ]; then
    ROLLBACK_DOMAIN=$(cat "$APP_DIR/.deploy-domain")
fi
echo "$DEPLOY_DATE | $APP_NAME | $ROLLBACK_COMMIT | rollback | $ROLLBACK_DOMAIN | rollback" >> "$HISTORY_FILE"
chown "$USERNAME:$USERNAME" "$HISTORY_FILE"

echo ""
echo "========================================="
echo -e "  ${GREEN}ROLLBACK TERMINE !${NC}"
echo "========================================="
echo ""
echo "  Application  : $APP_NAME"
echo "  Commit       : $LAST_COMMIT"
echo "  Dossier      : $APP_DIR"
echo ""
echo "  Pour revenir a la derniere version :"
echo "    cd $APP_DIR && git checkout main && docker compose up -d --build"
echo "========================================="
ROLLBACK_EOF

    SAFE_APP=$(sed_escape "$APP_NAME")
    SAFE_USER=$(sed_escape "$USERNAME")
    if [ "$OS" = "mac" ]; then
        sed -i '' "s|__APP_NAME__|$SAFE_APP|g" "$TMPSCRIPT"
        sed -i '' "s|__USERNAME__|$SAFE_USER|g" "$TMPSCRIPT"
    else
        sed -i "s|__APP_NAME__|$SAFE_APP|g" "$TMPSCRIPT"
        sed -i "s|__USERNAME__|$SAFE_USER|g" "$TMPSCRIPT"
    fi

    info "Envoi du script de rollback..."
    scp -i "$SSH_KEY" "$TMPSCRIPT" "${USERNAME}@${VPS_IP}:/tmp/vps-rollback-remote.sh"
    rm -f "$TMPSCRIPT"

    if [ -t 0 ]; then
        SSH_TTY_FLAG="-t"
    else
        SSH_TTY_FLAG=""
    fi

    ssh $SSH_TTY_FLAG -i "$SSH_KEY" "${USERNAME}@${VPS_IP}" "chmod 700 /tmp/vps-rollback-remote.sh; sudo bash /tmp/vps-rollback-remote.sh; rm -f /tmp/vps-rollback-remote.sh"

    echo ""
    echo -e "${BOLD}=== ROLLBACK TERMINE ===${NC}"
    echo ""
    exit 0
fi

# =========================================
# GÉNÉRATION DU SCRIPT DISTANT
# =========================================

TMPSCRIPT=$(mktemp)
trap 'rm -f "$TMPSCRIPT"' EXIT
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

echo ""
echo "========================================="
echo -e "  ${BOLD}DÉPLOIEMENT : $APP_NAME${NC}"
echo "========================================="
echo ""

# --- Vérifications préalables ---
if ! command -v docker &>/dev/null; then
    err "Docker n'est pas installé. Lancez d'abord setup.sh."
    exit 1
fi

if ! command -v git &>/dev/null; then
    err "Git n'est pas installé. Lancez d'abord setup.sh."
    exit 1
fi

# =========================================
# CONNEXION GITHUB SSH (multi-comptes)
# =========================================

# Fonction : configurer l'accès SSH GitHub (multi-comptes)
setup_github_ssh() {
    echo -e "${BOLD}${YELLOW}[>] Connexion à GitHub${NC}"
    echo "  Pour télécharger votre code depuis GitHub, le serveur"
    echo "  a besoin d'une clé SSH liée à votre compte GitHub."
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
        success "Des comptes GitHub sont déjà configurés sur ce serveur :"
        echo ""
        INDEX=1
        while IFS= read -r host; do
            LABEL=$(echo "$host" | sed 's/^github-//')
            KEY_FILE=$(grep -A3 "^Host $host" "$SSH_CONFIG" | grep "IdentityFile" | awk '{print $2}' | sed "s|~|/home/$USERNAME|")
            if [ -f "${KEY_FILE}.pub" ]; then
                KEY_INFO=$(head -1 "${KEY_FILE}.pub" | awk '{print $3}')
            else
                KEY_INFO="clé introuvable"
            fi
            printf "    %2d) %s (%s)\n" "$INDEX" "$LABEL" "$KEY_INFO"
            INDEX=$((INDEX + 1))
        done <<< "$GITHUB_HOSTS"

        TOTAL=$((INDEX - 1))
        echo ""
        echo "    $INDEX) Connecter un nouveau compte GitHub"
        echo ""
        read -p "  Quel compte utiliser ? : " GH_CHOICE

        if [ "$GH_CHOICE" -le "$TOTAL" ] 2>/dev/null; then
            SELECTED_HOST=$(echo "$GITHUB_HOSTS" | sed -n "${GH_CHOICE}p")
            GH_LABEL=$(echo "$SELECTED_HOST" | sed 's/^github-//')
            success "Compte sélectionné : $GH_LABEL"
        fi
    fi

    # Ajouter un nouveau compte si nécessaire
    if [ -z "$GH_LABEL" ]; then
        echo ""
        echo "  On va connecter votre compte GitHub à ce serveur."
        echo "  Donnez un nom pour identifier ce compte (par exemple"
        echo "  'perso' pour votre GitHub personnel, 'travail' pour celui du boulot)."
        echo ""
        read -p "  Nom du compte (ex: perso, travail) : " GH_LABEL
        GH_LABEL=$(echo "$GH_LABEL" | tr -cd 'a-zA-Z0-9-' | tr '[:upper:]' '[:lower:]')

        if [ -z "$GH_LABEL" ]; then
            GH_LABEL="default"
        fi

        KEY_PATH="$SSH_DIR/github_$GH_LABEL"

        if [ ! -f "$KEY_PATH" ]; then
            echo ""
            info "Génération d'une clé de sécurité pour le compte '$GH_LABEL'..."
            sudo -u "$USERNAME" ssh-keygen -t ed25519 -C "vps-$GH_LABEL" -f "$KEY_PATH" -N ""
            success "Clé générée."
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
        echo -e "  ${YELLOW}IMPORTANT : Ajoutez cette clé sur GitHub${NC}"
        echo "========================================="
        echo ""
        echo "  Copiez toute la ligne ci-dessous :"
        echo ""
        echo -e "  ${GREEN}$(cat "${KEY_PATH}.pub")${NC}"
        echo ""
        echo "  Puis suivez ces étapes :"
        echo ""
        echo "    1. Ouvrez https://github.com/settings/keys"
        echo "       (Connectez-vous à GitHub si besoin)"
        echo ""
        echo "    2. Cliquez le bouton vert 'New SSH key'"
        echo ""
        echo "    3. Dans 'Title', mettez : VPS $GH_LABEL"
        echo ""
        echo "    4. Dans 'Key', collez la ligne copiée plus haut"
        echo ""
        echo "    5. Cliquez 'Add SSH key'"
        echo ""
        echo "========================================="
        echo ""
        read -p "  Appuyez sur Entrée quand c'est fait... "

        # Tester la connexion
        echo ""
        info "Vérification de la connexion avec GitHub..."
        if sudo -u "$USERNAME" ssh -T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$KEY_PATH" git@github.com 2>&1 | grep -qi "successfully authenticated"; then
            success "Connexion GitHub réussie !"
        else
            echo ""
            warn "La connexion n'a pas fonctionné."
            echo ""
            echo "  Vérifiez que :"
            echo "    - Vous avez bien copié TOUTE la clé (la ligne entière)"
            echo "    - Vous avez cliqué 'Add SSH key' sur GitHub"
            echo "    - Vous êtes connecté au bon compte GitHub"
            echo ""
            read -p "  Appuyez sur Entrée pour réessayer... "
            if sudo -u "$USERNAME" ssh -T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$KEY_PATH" git@github.com 2>&1 | grep -qi "successfully authenticated"; then
                success "Connexion GitHub réussie !"
            else
                err "Connexion impossible. Vérifiez la clé sur GitHub et relancez le script."
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
if echo "$REPO_URL" | grep -q "^git@github.com"; then
    setup_github_ssh
fi

# =========================================
# DÉPLOIEMENT DE L'APPLICATION
# =========================================

# === TÉLÉCHARGEMENT DU CODE ===
echo ""
echo -e "${BOLD}${YELLOW}[>] Téléchargement du code source${NC}"

if [ -d "$APP_DIR/.git" ]; then
    info "Dépôt existant détecté. Mise à jour (git pull)..."
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
        success "Code mis a jour (tag : $DEPLOY_TAG)."
    elif [ -n "$DEPLOY_BRANCH" ]; then
        sudo -u "$USERNAME" git checkout "$DEPLOY_BRANCH" 2>/dev/null || sudo -u "$USERNAME" git checkout -b "$DEPLOY_BRANCH" "origin/$DEPLOY_BRANCH"
        sudo -u "$USERNAME" git pull origin "$DEPLOY_BRANCH"
        success "Code mis a jour (branche : $DEPLOY_BRANCH)."
    else
        sudo -u "$USERNAME" git pull
        success "Code mis a jour."
    fi
else
    info "Clonage du depot..."
    mkdir -p "/home/$USERNAME/apps"

    # Tenter le clone. Si HTTPS échoue (repo privé), basculer en SSH.
    if sudo -u "$USERNAME" git clone "$REPO_URL" "$APP_DIR" 2>/tmp/git-clone-err.log; then
        rm -f /tmp/git-clone-err.log
        success "Dépôt cloné dans $APP_DIR"
    else
        # Vérifier si c'est une URL HTTPS GitHub qui a échoué
        if echo "$REPO_URL" | grep -qE "^https?://github\.com/"; then
            echo ""
            warn "Le clonage a échoué."
            echo "  Ce dépôt est probablement privé."
            echo "  GitHub ne permet pas le clonage HTTPS sans authentification."
            echo ""
            echo "  Pas de souci ! On va configurer une clé SSH pour accéder"
            echo "  à vos dépôts privés en toute sécurité."
            echo ""

            # Convertir en SSH et lancer le flow multi-comptes
            convert_https_to_ssh
            setup_github_ssh

            # Retenter le clone avec SSH
            info "Nouvelle tentative de clonage avec la clé SSH..."
            sudo -u "$USERNAME" git clone "$REPO_URL" "$APP_DIR"
            success "Dépôt cloné dans $APP_DIR"
        else
            err "Échec du clonage."
            cat /tmp/git-clone-err.log
            exit 1
        fi
        rm -f /tmp/git-clone-err.log
    fi
fi

cd "$APP_DIR"

# Checkout de la branche ou du tag demande (apres clone)
if [ -n "$DEPLOY_TAG" ]; then
    sudo -u "$USERNAME" git checkout "$DEPLOY_TAG" 2>/dev/null || true
    info "Tag selectionne : $DEPLOY_TAG"
elif [ -n "$DEPLOY_BRANCH" ]; then
    sudo -u "$USERNAME" git checkout "$DEPLOY_BRANCH" 2>/dev/null || true
    info "Branche selectionnee : $DEPLOY_BRANCH"
fi

# === FICHIER .ENV ===
if [ "$HAS_ENV" = "true" ]; then
    echo ""
    echo -e "${BOLD}${YELLOW}[>] Configuration des variables d'environnement${NC}"
    if [ -f "/tmp/.env-$APP_NAME" ]; then
        cp "/tmp/.env-$APP_NAME" "$APP_DIR/.env"
        chown "$USERNAME:$USERNAME" "$APP_DIR/.env"
        chmod 600 "$APP_DIR/.env"
        rm -f "/tmp/.env-$APP_NAME"
        success "Fichier .env installé et sécurisé."
    else
        warn "Fichier .env attendu mais non trouvé sur le serveur."
    fi
elif [ "$CREATE_EMPTY_ENV" = "true" ]; then
    echo ""
    echo -e "${BOLD}${YELLOW}[>] Configuration des variables d'environnement${NC}"
    if [ ! -f "$APP_DIR/.env" ]; then
        touch "$APP_DIR/.env"
        chown "$USERNAME:$USERNAME" "$APP_DIR/.env"
        chmod 600 "$APP_DIR/.env"
        warn "Fichier .env vide créé dans $APP_DIR/.env"
        echo "  Vous devez le remplir avec vos variables d'environnement."
        echo "  Connectez-vous au serveur et éditez-le :"
        echo ""
        echo "    nano $APP_DIR/.env"
        echo ""
        echo "  Puis relancez l'application :"
        echo "    cd $APP_DIR && docker compose up -d --build"
    else
        info "Un fichier .env existe déjà dans $APP_DIR"
    fi
fi

# === BUILD ET DÉMARRAGE ===
echo ""
echo -e "${BOLD}${YELLOW}[>] Construction et lancement de l'application${NC}"
echo "  Détection du type de projet..."
echo ""

COMPOSE_FILE=""
for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [ -f "$APP_DIR/$f" ]; then
        COMPOSE_FILE="$f"
        break
    fi
done

if [ -n "$COMPOSE_FILE" ]; then
    info "Fichier $COMPOSE_FILE détecté."
    echo "  Lancement avec Docker Compose (ça peut prendre quelques minutes)..."
    echo ""
    cd "$APP_DIR"
    if ! sudo -u "$USERNAME" docker compose up -d --build 2>&1; then
        err "Échec du lancement avec Docker Compose."
        echo ""
        echo "  Derniers logs :"
        sudo -u "$USERNAME" docker compose logs --tail=20 2>/dev/null || true
        echo ""
        echo "  Pour voir tous les logs :"
        echo "    cd $APP_DIR && docker compose logs"
        exit 1
    fi
    echo ""
    success "Application lancée avec Docker Compose."
elif [ -f "$APP_DIR/Dockerfile" ]; then
    info "Dockerfile détecté."
    echo "  Construction de l'image Docker (ça peut prendre quelques minutes)..."
    echo ""
    if ! sudo -u "$USERNAME" docker build -t "$APP_NAME" "$APP_DIR"; then
        err "Échec de la construction de l'image Docker."
        echo ""
        echo "  Vérifiez votre Dockerfile et relancez le déploiement."
        exit 1
    fi

    # Arrêter le conteneur existant s'il tourne
    if docker ps -a -q -f "name=^${APP_NAME}$" | grep -q .; then
        info "Arrêt de l'ancienne version..."
        docker stop "$APP_NAME" 2>/dev/null || true
        docker rm "$APP_NAME" 2>/dev/null || true
    fi

    DOCKER_RUN_ARGS="-d --name $APP_NAME --restart unless-stopped -p 127.0.0.1:${APP_PORT}:${APP_PORT}"
    if [ -f "$APP_DIR/.env" ]; then
        DOCKER_RUN_ARGS="$DOCKER_RUN_ARGS --env-file $APP_DIR/.env"
    fi

    if ! sudo -u "$USERNAME" docker run $DOCKER_RUN_ARGS "$APP_NAME"; then
        err "Échec du lancement du conteneur."
        echo ""
        echo "  Derniers logs :"
        docker logs "$APP_NAME" --tail=20 2>/dev/null || true
        exit 1
    fi
    echo ""
    success "Application lancée sur le port $APP_PORT."
else
    err "Impossible de déployer : aucun fichier Docker trouvé."
    echo ""
    echo "  Votre dépôt doit contenir l'un de ces fichiers :"
    echo "    - docker-compose.yml (ou compose.yml)"
    echo "    - Dockerfile"
    echo ""
    echo "  Ajoutez-en un dans votre dépôt et relancez le déploiement."
    exit 1
fi

# === VÉRIFICATION DNS ===
echo ""
echo -e "${BOLD}${YELLOW}[>] Vérification du DNS${NC}"
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
DOMAIN_IP=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' || true)

if [ -z "$DOMAIN_IP" ]; then
    warn "Le domaine $DOMAIN ne pointe vers aucune adresse IP."
    echo "  Le certificat SSL ne pourra pas être généré tant que le DNS"
    echo "  ne pointe pas vers ce serveur ($SERVER_IP)."
    echo ""
    echo "  Configurez un enregistrement A chez votre registrar :"
    echo "    $DOMAIN -> $SERVER_IP"
    echo ""
elif [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
    warn "Le domaine $DOMAIN pointe vers $DOMAIN_IP (et non $SERVER_IP)."
    echo "  Le certificat SSL ne fonctionnera pas tant que le DNS ne pointe"
    echo "  pas vers ce serveur."
    echo ""
else
    success "Le DNS de $DOMAIN pointe bien vers ce serveur."
fi

# === CONFIGURATION DU DOMAINE ===
echo ""
echo -e "${BOLD}${YELLOW}[>] Configuration du domaine et HTTPS${NC}"
echo "  Caddy va rediriger $DOMAIN vers votre application"
echo "  et générer un certificat SSL automatiquement."
echo ""

if ! command -v caddy &>/dev/null; then
    warn "Caddy n'est pas installé sur ce serveur."
    echo "  Lancez d'abord setup.sh pour installer Caddy,"
    echo "  ou configurez le reverse proxy manuellement."
else
    CADDYFILE="/etc/caddy/Caddyfile"

    # Sauvegarder le Caddyfile
    cp "$CADDYFILE" "${CADDYFILE}.bak"

    # Vérifier si le domaine est déjà configuré
    if grep -qF "${DOMAIN}" "$CADDYFILE" 2>/dev/null; then
        info "Le domaine $DOMAIN était déjà configuré, mise à jour..."
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
            success "Domaine configuré ! Caddy va générer le certificat SSL."
        else
            err "Caddy n'a pas pu recharger la configuration."
            echo "  Vérifiez avec : sudo systemctl status caddy"
        fi
    else
        err "Erreur dans la configuration du domaine."
        cp "${CADDYFILE}.bak" "$CADDYFILE"
        systemctl reload caddy 2>/dev/null
        warn "Configuration restaurée. Le domaine n'a pas été ajouté."
    fi
fi

# =========================================
# VÉRIFICATION DE L'APPLICATION
# =========================================

echo ""
echo -e "${BOLD}${YELLOW}[>] Vérification de l'application${NC}"
echo "  Attente du démarrage (5 secondes)..."
sleep 5

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${APP_PORT}" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "000" ]; then
    warn "L'application ne répond pas sur le port $APP_PORT."
    echo ""
    echo "  Ça peut être normal si l'application met du temps à démarrer."
    echo "  Vérifiez les logs :"
    echo "    docker logs $APP_NAME --tail=30"
    echo "    ou : cd $APP_DIR && docker compose logs --tail=30"
elif [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 400 ]; then
    success "L'application répond correctement (HTTP $HTTP_CODE)."
else
    warn "L'application répond avec le code HTTP $HTTP_CODE."
    echo "  Vérifiez les logs : docker logs $APP_NAME --tail=30"
fi

# =========================================
# SAUVEGARDE DES MÉTADONNÉES
# =========================================

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

# =========================================
# HISTORIQUE DE DEPLOIEMENT
# =========================================

HISTORY_FILE="/home/$USERNAME/.deploy-history"
DEPLOY_DATE=$(date '+%Y-%m-%d %H:%M:%S')
DEPLOY_COMMIT=$(cd "$APP_DIR" && sudo -u "$USERNAME" git rev-parse --short HEAD 2>/dev/null || echo "inconnu")
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

# =========================================
# NETTOYAGE DOCKER
# =========================================

echo ""
echo -e "${BOLD}${YELLOW}[>] Nettoyage Docker${NC}"

PRUNE_OUTPUT=$(docker image prune -f 2>/dev/null || true)
PRUNE_SIZE=$(echo "$PRUNE_OUTPUT" | grep -ioE '[0-9.]+ ?[kKmMgGtT]?B' | tail -1 || echo "")
if [ -n "$PRUNE_SIZE" ] && [ "$PRUNE_SIZE" != "0B" ]; then
    success "Images inutilisees supprimees : $PRUNE_SIZE liberes"
else
    info "Aucune image inutilisee a supprimer."
fi

BUILD_OUTPUT=$(docker builder prune -f --filter "until=24h" 2>/dev/null || true)
BUILD_SIZE=$(echo "$BUILD_OUTPUT" | grep -ioE '[0-9.]+ ?[kKmMgGtT]?B' | tail -1 || echo "")
if [ -n "$BUILD_SIZE" ] && [ "$BUILD_SIZE" != "0B" ]; then
    success "Cache de build nettoye : $BUILD_SIZE liberes"
fi

# =========================================
# C'EST TERMINÉ !
# =========================================

echo ""
echo "========================================="
echo -e "  ${GREEN}DÉPLOIEMENT TERMINÉ !${NC}"
echo "========================================="
echo ""
echo "  Application  : $APP_NAME"
echo "  Adresse      : https://$DOMAIN"
if [ -n "$DEPLOY_TAG" ]; then
    echo "  Tag          : $DEPLOY_TAG"
elif [ -n "$DEPLOY_BRANCH" ]; then
    echo "  Branche      : $DEPLOY_BRANCH"
fi
echo "  Dossier      : $APP_DIR"
echo ""
echo "  Le certificat SSL (HTTPS) est généré automatiquement."
echo ""
echo "  Commandes utiles :"
echo "    Voir les logs    : docker logs $APP_NAME --tail=50"
echo "    Redémarrer       : cd $APP_DIR && docker compose restart"
echo "    Arrêter          : cd $APP_DIR && docker compose down"
echo "========================================="
DEPLOY_EOF

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
    sed -i '' "s|__HAS_ENV__|$HAS_ENV|g" "$TMPSCRIPT"
    sed -i '' "s|__CREATE_EMPTY_ENV__|$CREATE_EMPTY_ENV|g" "$TMPSCRIPT"
    sed -i '' "s|__DEPLOY_BRANCH__|$SAFE_BRANCH|g" "$TMPSCRIPT"
    sed -i '' "s|__DEPLOY_TAG__|$SAFE_TAG|g" "$TMPSCRIPT"
else
    sed -i "s|__APP_NAME__|$SAFE_APP|g" "$TMPSCRIPT"
    sed -i "s|__REPO_URL__|$SAFE_REPO|g" "$TMPSCRIPT"
    sed -i "s|__DOMAIN__|$SAFE_DOMAIN|g" "$TMPSCRIPT"
    sed -i "s|__APP_PORT__|$SAFE_PORT|g" "$TMPSCRIPT"
    sed -i "s|__USERNAME__|$SAFE_USER|g" "$TMPSCRIPT"
    sed -i "s|__HAS_ENV__|$HAS_ENV|g" "$TMPSCRIPT"
    sed -i "s|__CREATE_EMPTY_ENV__|$CREATE_EMPTY_ENV|g" "$TMPSCRIPT"
    sed -i "s|__DEPLOY_BRANCH__|$SAFE_BRANCH|g" "$TMPSCRIPT"
    sed -i "s|__DEPLOY_TAG__|$SAFE_TAG|g" "$TMPSCRIPT"
fi

# =========================================
# ENVOI ET EXÉCUTION
# =========================================

# Envoyer le fichier .env si nécessaire
if [ -n "$ENV_FILE" ]; then
    info "Envoi du fichier .env sur le serveur..."
    if ! scp -i "$SSH_KEY" "$ENV_FILE" "${USERNAME}@${VPS_IP}:/tmp/.env-${APP_NAME}"; then
        err "Impossible d'envoyer le fichier .env. Vérifiez la connexion."
        rm -f "$TMPSCRIPT"
        exit 1
    fi
    success "Fichier .env envoyé."
fi

# Envoyer et exécuter le script distant
info "Envoi du script de déploiement..."
if ! scp -i "$SSH_KEY" "$TMPSCRIPT" "${USERNAME}@${VPS_IP}:/tmp/vps-deploy-remote.sh"; then
    err "Impossible d'envoyer le script sur le serveur. Vérifiez la connexion."
    rm -f "$TMPSCRIPT"
    exit 1
fi
rm -f "$TMPSCRIPT"

info "Exécution du déploiement sur le serveur..."

# Détection TTY pour compatibilité CI/CD
if [ -t 0 ]; then
    SSH_TTY_FLAG="-t"
else
    SSH_TTY_FLAG=""
fi

ssh $SSH_TTY_FLAG -i "$SSH_KEY" "${USERNAME}@${VPS_IP}" "chmod 700 /tmp/vps-deploy-remote.sh; sudo bash /tmp/vps-deploy-remote.sh; rm -f /tmp/vps-deploy-remote.sh"

# =========================================
# RÉSUMÉ LOCAL
# =========================================

echo ""
echo -e "${BOLD}=== DÉPLOIEMENT TERMINÉ ===${NC}"
echo ""
echo "  Votre application est accessible à :"
echo ""
echo -e "    ${GREEN}https://${DOMAIN}${NC}"
echo ""
if [ "$CREATE_EMPTY_ENV" = "true" ]; then
    echo ""
    echo -e "  ${YELLOW}[IMPORTANT] N'oubliez pas de remplir le fichier .env :${NC}"
    echo ""
    echo "    ssh -i $SSH_KEY ${USERNAME}@${VPS_IP}"
    echo "    nano ~/apps/${APP_NAME}/.env"
    echo ""
    echo "  Puis relancez les conteneurs :"
    echo "    cd ~/apps/${APP_NAME} && docker compose up -d --build"
fi

echo ""
echo "  Pour redéployer (après un git push) :"
echo ""
if [ "$INTERACTIVE" = true ]; then
    echo -e "    ${GREEN}bash deploy.sh${NC}"
else
    echo -e "    ${GREEN}bash deploy.sh -ip $VPS_IP -key $SSH_KEY -user $USERNAME -app $APP_NAME -repo $REPO_URL -domain $DOMAIN -port $APP_PORT${NC}"
fi
echo ""
echo "========================================="
