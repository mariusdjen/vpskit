#!/bin/bash
set -euo pipefail

# ============================================
# Sauvegarde et restauration des applications VPS
#
# Usage interactif : bash backup.sh
# Usage CI/CD :      bash backup.sh -ip IP -key CLE -user USER [-app NOM] [-dest /chemin/local]
# Restauration :     bash backup.sh -ip IP -key CLE -user USER -app NOM --restore fichier.tar.gz
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
APP_NAME=""
DEST_DIR="."
RESTORE=false
RESTORE_FILE=""
INTERACTIVE=true

while [ $# -gt 0 ]; do
    case "$1" in
        -ip)     VPS_IP="$2"; shift 2; INTERACTIVE=false ;;
        -key)    SSH_KEY="$2"; shift 2 ;;
        -user)   USERNAME="$2"; shift 2 ;;
        -app)    APP_NAME="$2"; shift 2 ;;
        -dest)   DEST_DIR="$2"; shift 2 ;;
        --restore)
            RESTORE=true
            if [ $# -lt 2 ] || [[ "$2" == -* ]]; then
                err "L'option --restore necessite un fichier en argument."
                echo "  Usage : --restore fichier.tar.gz"
                exit 1
            fi
            RESTORE_FILE="$2"
            shift 2
            ;;
        *)
            err "Argument inconnu : $1"
            echo "  Usage : bash backup.sh -ip IP -key CLE -user USER [-app NOM] [-dest /chemin]"
            echo "  Restore : bash backup.sh -ip IP -key CLE -user USER -app NOM --restore fichier.tar.gz"
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
    echo -e "  ${BOLD}VPS BACKUP${NC}"
    echo "  Sauvegarde et restauration de vos apps"
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

    echo ""

    # Choix : sauvegarder ou restaurer
    echo -e "${BOLD}${YELLOW}[>] Que souhaitez-vous faire ?${NC}"
    echo ""
    echo "    1) Sauvegarder une ou toutes les applications"
    echo "    2) Restaurer une application depuis un fichier de sauvegarde"
    echo ""
    read -p "  Votre choix (1/2) : " BACKUP_CHOICE
    echo ""

    if [ "$BACKUP_CHOICE" = "2" ]; then
        RESTORE=true

        # Demander le fichier de sauvegarde
        echo "  Indiquez le chemin du fichier de sauvegarde (.tar.gz)."
        echo "  Vous pouvez glisser-deposer le fichier dans le terminal."
        echo ""
        read -p "  Fichier de sauvegarde : " RESTORE_FILE
        RESTORE_FILE=$(echo "$RESTORE_FILE" | sed "s|^['\"]||;s|['\"]$||;s|^~|$HOME|;s|\\\\ | |g;s|[[:space:]]*$||")

        if [ ! -f "$RESTORE_FILE" ]; then
            err "Fichier introuvable : $RESTORE_FILE"
            exit 1
        fi

        # Demander le nom de l'app
        read -p "  Nom de l'application a restaurer : " APP_NAME
    else
        # Lister les apps et proposer le choix
        info "Recuperation des applications deployees..."
        APPS_LIST=$(ssh -i "$SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes "${USERNAME}@${VPS_IP}" "ls -1 ~/apps/ 2>/dev/null" || true)

        if [ -z "$APPS_LIST" ]; then
            err "Aucune application deployee sur ce serveur."
            exit 1
        fi

        echo ""
        echo "  Applications deployees :"
        echo ""
        INDEX=1
        while IFS= read -r app; do
            echo "    $INDEX) $app"
            INDEX=$((INDEX + 1))
        done <<< "$APPS_LIST"
        echo ""
        echo "    $INDEX) Toutes les applications"
        echo ""
        read -p "  Quelle application sauvegarder ? : " APP_CHOICE

        if ! [[ "$APP_CHOICE" =~ ^[0-9]+$ ]]; then
            err "Choix invalide : entrez un numero."
            exit 1
        fi

        if [ "$APP_CHOICE" = "$INDEX" ]; then
            APP_NAME=""
        else
            APP_NAME=$(echo "$APPS_LIST" | sed -n "${APP_CHOICE}p")
            if [ -z "$APP_NAME" ]; then
                err "Choix invalide."
                exit 1
            fi
        fi

        # Dossier de destination
        echo ""
        read -p "  Dossier de destination (defaut: dossier courant) : " DEST_INPUT
        DEST_DIR=${DEST_INPUT:-.}
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
if [ "$RESTORE" = true ]; then
    if [ -z "$APP_NAME" ]; then
        err "Nom de l'application requis pour la restauration."
        ERRORS=$((ERRORS + 1))
    fi
    if [ -z "$RESTORE_FILE" ] || [ ! -f "$RESTORE_FILE" ]; then
        err "Fichier de sauvegarde introuvable : ${RESTORE_FILE:-non specifie}"
        ERRORS=$((ERRORS + 1))
    fi
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
success "Connexion SSH verifiee."

# =========================================
# MODE RESTAURATION
# =========================================

if [ "$RESTORE" = true ]; then
    info "Envoi du fichier de sauvegarde sur le serveur..."
    scp -i "$SSH_KEY" "$RESTORE_FILE" "${USERNAME}@${VPS_IP}:/tmp/vps-restore.tar.gz"
    success "Fichier envoye."

    TMPSCRIPT=$(mktemp)
    trap 'rm -f "$TMPSCRIPT"' EXIT
    cat > "$TMPSCRIPT" << 'RESTORE_EOF'
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
RESTORE_TMP="/tmp/vps-restore-work"

info()    { echo -e "${BLUE}[INFO] $1${NC}"; }
success() { echo -e "${GREEN}[OK] $1${NC}"; }
warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }
err()     { echo -e "${RED}[ERR] $1${NC}"; }

echo ""
echo "========================================="
echo -e "  ${BOLD}RESTAURATION : $APP_NAME${NC}"
echo "========================================="
echo ""

# Extraire l'archive
rm -rf "$RESTORE_TMP"
mkdir -p "$RESTORE_TMP"
tar xzf /tmp/vps-restore.tar.gz -C "$RESTORE_TMP"
rm -f /tmp/vps-restore.tar.gz

# Creer le dossier de l'app si necessaire
mkdir -p "$APP_DIR"

# Restaurer le fichier .env
if [ -f "$RESTORE_TMP/env" ]; then
    cp "$RESTORE_TMP/env" "$APP_DIR/.env"
    chown "$USERNAME:$USERNAME" "$APP_DIR/.env"
    chmod 600 "$APP_DIR/.env"
    success "Fichier .env restaure."
fi

# Restaurer les metadonnees
if [ -f "$RESTORE_TMP/deploy-domain" ]; then
    cp "$RESTORE_TMP/deploy-domain" "$APP_DIR/.deploy-domain"
    chown "$USERNAME:$USERNAME" "$APP_DIR/.deploy-domain"
fi
if [ -f "$RESTORE_TMP/deploy-port" ]; then
    cp "$RESTORE_TMP/deploy-port" "$APP_DIR/.deploy-port"
    chown "$USERNAME:$USERNAME" "$APP_DIR/.deploy-port"
fi

# Restaurer le Caddyfile
if [ -f "$RESTORE_TMP/Caddyfile" ]; then
    cp "$RESTORE_TMP/Caddyfile" /etc/caddy/Caddyfile
    if command -v caddy &>/dev/null; then
        if caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null; then
            systemctl reload caddy 2>/dev/null || true
            success "Caddyfile restaure et recharge."
        else
            warn "Caddyfile restaure mais la validation a echoue."
        fi
    else
        success "Caddyfile restaure."
    fi
fi

# Restaurer les volumes Docker
for VOL_ARCHIVE in "$RESTORE_TMP"/volume-*.tar.gz; do
    [ -f "$VOL_ARCHIVE" ] || continue
    VOL_NAME=$(basename "$VOL_ARCHIVE" .tar.gz | sed 's/^volume-//')
    info "Restauration du volume Docker : $VOL_NAME"

    # Creer le volume s'il n'existe pas
    docker volume create "$VOL_NAME" 2>/dev/null || true

    # Restaurer les donnees
    docker run --rm -v "$VOL_NAME":/data -v "$RESTORE_TMP":/backup alpine sh -c "cd /data && tar xzf /backup/$(basename "$VOL_ARCHIVE") --strip-components=1 2>/dev/null || tar xzf /backup/$(basename "$VOL_ARCHIVE") 2>/dev/null"
    success "Volume $VOL_NAME restaure."
done

# Relancer les conteneurs si possible
if [ -d "$APP_DIR" ]; then
    cd "$APP_DIR"
    COMPOSE_FILE=""
    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        if [ -f "$APP_DIR/$f" ]; then
            COMPOSE_FILE="$f"
            break
        fi
    done

    if [ -n "$COMPOSE_FILE" ]; then
        info "Relancement de l'application..."
        sudo -u "$USERNAME" docker compose up -d --build 2>&1 || true
        success "Application relancee."
    fi
fi

# Nettoyage
rm -rf "$RESTORE_TMP"

echo ""
echo "========================================="
echo -e "  ${GREEN}RESTAURATION TERMINEE !${NC}"
echo "========================================="
echo ""
echo "  Application : $APP_NAME"
echo "  Dossier     : $APP_DIR"
echo "========================================="
RESTORE_EOF

    SAFE_APP=$(sed_escape "$APP_NAME")
    SAFE_USER=$(sed_escape "$USERNAME")
    if [ "$OS" = "mac" ]; then
        sed -i '' "s|__APP_NAME__|$SAFE_APP|g" "$TMPSCRIPT"
        sed -i '' "s|__USERNAME__|$SAFE_USER|g" "$TMPSCRIPT"
    else
        sed -i "s|__APP_NAME__|$SAFE_APP|g" "$TMPSCRIPT"
        sed -i "s|__USERNAME__|$SAFE_USER|g" "$TMPSCRIPT"
    fi

    scp -i "$SSH_KEY" "$TMPSCRIPT" "${USERNAME}@${VPS_IP}:/tmp/vps-restore-remote.sh"
    rm -f "$TMPSCRIPT"

    if [ -t 0 ]; then
        SSH_TTY_FLAG="-t"
    else
        SSH_TTY_FLAG=""
    fi

    ssh $SSH_TTY_FLAG -i "$SSH_KEY" "${USERNAME}@${VPS_IP}" "chmod 700 /tmp/vps-restore-remote.sh; sudo bash /tmp/vps-restore-remote.sh; rm -f /tmp/vps-restore-remote.sh"

    echo ""
    echo -e "${BOLD}=== RESTAURATION TERMINEE ===${NC}"
    echo ""
    exit 0
fi

# =========================================
# MODE SAUVEGARDE
# =========================================

TMPSCRIPT=$(mktemp)
trap 'rm -f "$TMPSCRIPT"' EXIT
cat > "$TMPSCRIPT" << 'BACKUP_EOF'
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
APPS_DIR="/home/$USERNAME/apps"
BACKUP_DIR="/tmp/vps-backup-work"
DATE=$(date +%Y-%m-%d)

info()    { echo -e "${BLUE}[INFO] $1${NC}"; }
success() { echo -e "${GREEN}[OK] $1${NC}"; }
warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }
err()     { echo -e "${RED}[ERR] $1${NC}"; }

backup_app() {
    local APP="$1"
    local APP_PATH="$APPS_DIR/$APP"
    local WORK="/tmp/vps-backup-$APP"

    echo ""
    echo -e "${BOLD}[>] Sauvegarde : $APP${NC}"

    if [ ! -d "$APP_PATH" ]; then
        warn "Application introuvable : $APP_PATH"
        return
    fi

    rm -rf "$WORK"
    mkdir -p "$WORK"

    # Fichier .env
    if [ -f "$APP_PATH/.env" ]; then
        cp "$APP_PATH/.env" "$WORK/env"
        success "  .env sauvegarde"
    fi

    # Metadonnees
    DOMAIN=""
    PORT=""
    COMMIT=""

    if [ -f "$APP_PATH/.deploy-domain" ]; then
        DOMAIN=$(cat "$APP_PATH/.deploy-domain")
        cp "$APP_PATH/.deploy-domain" "$WORK/deploy-domain"
    fi
    if [ -f "$APP_PATH/.deploy-port" ]; then
        PORT=$(cat "$APP_PATH/.deploy-port")
        cp "$APP_PATH/.deploy-port" "$WORK/deploy-port"
    fi
    if [ -d "$APP_PATH/.git" ]; then
        COMMIT=$(cd "$APP_PATH" && git rev-parse HEAD 2>/dev/null || echo "")
    fi

    # Metadonnees JSON
    cat > "$WORK/metadata.json" << META_BLOCK
{
    "app": "$APP",
    "date": "$DATE",
    "domain": "$DOMAIN",
    "port": "$PORT",
    "commit": "$COMMIT"
}
META_BLOCK
    success "  Metadonnees sauvegardees"

    # Caddyfile
    if [ -f /etc/caddy/Caddyfile ]; then
        cp /etc/caddy/Caddyfile "$WORK/Caddyfile"
        success "  Caddyfile sauvegarde"
    fi

    # Volumes Docker
    COMPOSE_FILE=""
    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        if [ -f "$APP_PATH/$f" ]; then
            COMPOSE_FILE="$f"
            break
        fi
    done

    if [ -n "$COMPOSE_FILE" ]; then
        # Recuperer les volumes depuis docker compose
        VOLUMES=$(cd "$APP_PATH" && docker compose config --volumes 2>/dev/null || true)
        PROJECT_NAME=$(cd "$APP_PATH" && docker compose config --format json 2>/dev/null | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "$APP")

        if [ -n "$VOLUMES" ]; then
            while IFS= read -r vol; do
                [ -z "$vol" ] && continue
                FULL_VOL="${PROJECT_NAME}_${vol}"
                # Verifier que le volume existe
                if docker volume inspect "$FULL_VOL" &>/dev/null; then
                    info "  Sauvegarde du volume : $FULL_VOL"
                    docker run --rm -v "$FULL_VOL":/data -v "$WORK":/backup alpine tar czf "/backup/volume-${FULL_VOL}.tar.gz" /data 2>/dev/null
                    success "  Volume $FULL_VOL sauvegarde"
                elif docker volume inspect "$vol" &>/dev/null; then
                    info "  Sauvegarde du volume : $vol"
                    docker run --rm -v "$vol":/data -v "$WORK":/backup alpine tar czf "/backup/volume-${vol}.tar.gz" /data 2>/dev/null
                    success "  Volume $vol sauvegarde"
                fi
            done <<< "$VOLUMES"
        fi
    fi

    # Creer l'archive finale
    ARCHIVE_NAME="vps-backup-${DATE}-${APP}.tar.gz"
    tar czf "/tmp/$ARCHIVE_NAME" -C "$WORK" .
    rm -rf "$WORK"

    success "Archive creee : /tmp/$ARCHIVE_NAME"
    echo "$ARCHIVE_NAME" >> /tmp/vps-backup-files.txt
}

# Nettoyage
rm -f /tmp/vps-backup-files.txt

echo ""
echo "========================================="
echo -e "  ${BOLD}SAUVEGARDE VPS${NC}"
echo "========================================="

if [ -n "$APP_NAME" ]; then
    backup_app "$APP_NAME"
else
    # Sauvegarder toutes les apps
    for APP_PATH in "$APPS_DIR"/*/; do
        [ -d "$APP_PATH" ] || continue
        APP=$(basename "$APP_PATH")
        backup_app "$APP"
    done
fi

if [ ! -f /tmp/vps-backup-files.txt ]; then
    echo ""
    warn "Aucune application a sauvegarder."
    exit 0
fi

# Rendre les archives lisibles par l'utilisateur (pour scp)
while IFS= read -r f; do
    chown "$USERNAME:$USERNAME" "/tmp/$f" 2>/dev/null || true
done < /tmp/vps-backup-files.txt
chown "$USERNAME:$USERNAME" /tmp/vps-backup-files.txt 2>/dev/null || true

echo ""
echo "========================================="
echo -e "  ${GREEN}SAUVEGARDE TERMINEE !${NC}"
echo "========================================="
echo ""
echo "  Fichiers crees :"
while IFS= read -r f; do
    echo "    - $f"
done < /tmp/vps-backup-files.txt
echo ""
echo "========================================="
BACKUP_EOF

# =========================================
# REMPLACEMENT DES PLACEHOLDERS
# =========================================

SAFE_APP=$(sed_escape "$APP_NAME")
SAFE_USER=$(sed_escape "$USERNAME")
if [ "$OS" = "mac" ]; then
    sed -i '' "s|__APP_NAME__|$SAFE_APP|g" "$TMPSCRIPT"
    sed -i '' "s|__USERNAME__|$SAFE_USER|g" "$TMPSCRIPT"
else
    sed -i "s|__APP_NAME__|$SAFE_APP|g" "$TMPSCRIPT"
    sed -i "s|__USERNAME__|$SAFE_USER|g" "$TMPSCRIPT"
fi

# =========================================
# ENVOI ET EXECUTION
# =========================================

info "Envoi du script de sauvegarde..."
if ! scp -i "$SSH_KEY" "$TMPSCRIPT" "${USERNAME}@${VPS_IP}:/tmp/vps-backup-remote.sh"; then
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

ssh $SSH_TTY_FLAG -i "$SSH_KEY" "${USERNAME}@${VPS_IP}" "chmod 700 /tmp/vps-backup-remote.sh; sudo bash /tmp/vps-backup-remote.sh; rm -f /tmp/vps-backup-remote.sh"

# =========================================
# RECUPERATION DES FICHIERS
# =========================================

echo ""
info "Recuperation des sauvegardes..."

mkdir -p "$DEST_DIR"

# Lister les fichiers crees
BACKUP_FILES=$(ssh -i "$SSH_KEY" -o BatchMode=yes "${USERNAME}@${VPS_IP}" "cat /tmp/vps-backup-files.txt 2>/dev/null" || true)

if [ -z "$BACKUP_FILES" ]; then
    warn "Aucun fichier de sauvegarde a recuperer."
    exit 0
fi

while IFS= read -r BACKUP_FILE; do
    [ -z "$BACKUP_FILE" ] && continue
    info "Telechargement : $BACKUP_FILE"
    scp -i "$SSH_KEY" "${USERNAME}@${VPS_IP}:/tmp/${BACKUP_FILE}" "${DEST_DIR}/${BACKUP_FILE}"
    success "Sauvegarde recuperee : ${DEST_DIR}/${BACKUP_FILE}"
done <<< "$BACKUP_FILES"

# Nettoyage sur le serveur
ssh -i "$SSH_KEY" -o BatchMode=yes "${USERNAME}@${VPS_IP}" "rm -f /tmp/vps-backup-*.tar.gz /tmp/vps-backup-files.txt" 2>/dev/null || true

echo ""
echo "========================================="
echo -e "${BOLD}=== SAUVEGARDE TERMINEE ===${NC}"
echo "========================================="
echo ""
echo "  Fichiers sauvegardes dans : $DEST_DIR"
echo ""
while IFS= read -r BACKUP_FILE; do
    [ -z "$BACKUP_FILE" ] && continue
    echo "    - $BACKUP_FILE"
done <<< "$BACKUP_FILES"
echo ""
echo "  Pour restaurer :"
echo ""
if [ "$INTERACTIVE" = true ]; then
    echo -e "    ${GREEN}bash backup.sh${NC}"
    echo "    (puis choisir 'Restaurer')"
else
    FIRST_FILE=$(echo "$BACKUP_FILES" | head -1)
    echo -e "    ${GREEN}bash backup.sh -ip $VPS_IP -key $SSH_KEY -user $USERNAME -app NOM --restore $FIRST_FILE${NC}"
fi
echo ""
echo "========================================="
