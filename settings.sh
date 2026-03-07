#!/bin/bash
set -euo pipefail

# ============================================
# Parametres VPS Kit
# Gere les raccourcis SSH, les cles SSH,
# la langue et la session locale.
#
# Usage : bash settings.sh
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
    curl -fsSL "https://raw.githubusercontent.com/mariusdjen/vpskit/main/lang.sh" -o "$_LANG_TMP" 2>/dev/null && . "$_LANG_TMP"
fi

# --- Chemins ---
if [ "$OS" = "windows" ]; then
    SSH_DIR="$USERPROFILE/.ssh"
else
    SSH_DIR="$HOME/.ssh"
fi

LOCAL_STATE="$SSH_DIR/.vps-bootstrap-local"
SETTINGS_FILE="$SSH_DIR/.vpskit-settings"

# =========================================
# ECRITURE SECURISEE DES PARAMETRES
# =========================================

write_setting() {
    local key="$1" value="$2"
    if [ ! -f "$SETTINGS_FILE" ]; then
        printf '%s="%s"\n' "$key" "$value" > "$SETTINGS_FILE"
        chmod 600 "$SETTINGS_FILE"
    elif grep -q "^${key}=" "$SETTINGS_FILE" 2>/dev/null; then
        local safe_val
        safe_val=$(sed_escape "$value")
        if [ "$OS" = "mac" ]; then
            sed -i '' "s|^${key}=.*|${key}=\"${safe_val}\"|" "$SETTINGS_FILE"
        else
            sed -i "s|^${key}=.*|${key}=\"${safe_val}\"|" "$SETTINGS_FILE"
        fi
    else
        printf '%s="%s"\n' "$key" "$value" >> "$SETTINGS_FILE"
    fi
}

# =========================================
# GESTION DES RACCOURCIS SSH
# =========================================

manage_ssh_shortcuts() {
    local config_file="$SSH_DIR/config"

    if [ ! -f "$config_file" ]; then
        info "$MSG_SETTINGS_SSH_NO_CONFIG"
        echo ""
        return
    fi

    # Collecter les blocs Host (sauf Host *)
    local blocks=()
    local block_names=()
    local current_block=""
    local current_name=""
    local in_block=0

    while IFS= read -r line || [ -n "$line" ]; do
        if echo "$line" | grep -qE "^[Hh][Oo][Ss][Tt][[:space:]]"; then
            # Sauvegarder le bloc precedent
            if [ -n "$current_name" ] && [ "$current_name" != "*" ]; then
                blocks+=("$current_block")
                block_names+=("$current_name")
            fi
            current_name=$(echo "$line" | awk '{print $2}')
            current_block="$line"
            in_block=1
        elif [ $in_block -eq 1 ] && echo "$line" | grep -qE "^[[:space:]]"; then
            current_block="$current_block
$line"
        else
            if [ -n "$current_name" ] && [ "$current_name" != "*" ]; then
                blocks+=("$current_block")
                block_names+=("$current_name")
            fi
            current_name=""
            current_block=""
            in_block=0
        fi
    done < "$config_file"

    # Sauvegarder le dernier bloc
    if [ -n "$current_name" ] && [ "$current_name" != "*" ]; then
        blocks+=("$current_block")
        block_names+=("$current_name")
    fi

    if [ ${#blocks[@]} -eq 0 ]; then
        info "$MSG_SETTINGS_SSH_NO_SHORTCUTS"
        echo ""
        return
    fi

    echo ""
    info "$MSG_SETTINGS_SSH_LIST_TITLE"
    echo ""
    for i in "${!blocks[@]}"; do
        local num=$((i + 1))
        echo -e "  ${GREEN}${num})${NC} ${block_names[$i]}"
        echo "${blocks[$i]}" | tail -n +2 | while IFS= read -r bline; do
            echo "       $bline"
        done
        echo ""
    done
    echo "  0) ${MSG_SETTINGS_CANCEL}"
    echo ""

    read -p "  $(printf "$MSG_SETTINGS_SSH_DELETE_PROMPT" "${#blocks[@]}")" choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -eq 0 ] || [ "$choice" -gt "${#blocks[@]}" ]; then
        info "$MSG_SETTINGS_CANCEL"
        echo ""
        return
    fi

    local idx=$((choice - 1))
    echo ""
    warn "$MSG_SETTINGS_SSH_DELETE_CONFIRM_TITLE"
    echo ""
    echo "${blocks[$idx]}"
    echo ""
    read -p "  $MSG_SETTINGS_SSH_CONFIRM_PROMPT" confirm
    if [[ "$confirm" != "o" && "$confirm" != "O" && "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "$MSG_SETTINGS_CANCEL"
        echo ""
        return
    fi

    # Backup
    cp "$config_file" "${config_file}.bak"

    # Reconstruire le fichier sans le bloc selectionne
    local target_name="${block_names[$idx]}"
    local tmpfile
    tmpfile=$(mktemp)
    trap 'rm -f "$tmpfile"' RETURN

    awk -v target="$target_name" '
    BEGIN { skip=0; blank_buffer="" }
    /^[Hh][Oo][Ss][Tt][ \t]/ {
        name = $2
        if (name == target) {
            skip = 1
            blank_buffer = ""
            next
        } else {
            skip = 0
            if (blank_buffer != "") { printf "%s", blank_buffer; blank_buffer = "" }
            print
            next
        }
    }
    skip == 1 && /^[[:space:]]/ { next }
    skip == 1 && /^$/ { skip = 0; next }
    skip == 1 { skip = 0 }
    /^$/ { blank_buffer = blank_buffer $0 "\n"; next }
    {
        if (blank_buffer != "") { printf "%s", blank_buffer; blank_buffer = "" }
        print
    }
    END {
        if (blank_buffer != "") printf "%s", blank_buffer
    }
    ' "$config_file" > "$tmpfile"

    # Valider la syntaxe SSH
    if ssh -F "$tmpfile" -G localhost &>/dev/null; then
        mv "$tmpfile" "$config_file"
        chmod 600 "$config_file"
        echo ""
        success "$(printf "$MSG_SETTINGS_SSH_DELETED" "$target_name")"
        info "$(printf "$MSG_SETTINGS_SSH_BACKUP_INFO" "${config_file}.bak")"
    else
        echo ""
        err "$MSG_SETTINGS_SSH_INVALID_CONFIG"
        cp "${config_file}.bak" "$config_file"
    fi
    echo ""
}

# =========================================
# GESTION DES CLES SSH
# =========================================

manage_ssh_keys() {
    # Charger la cle active depuis la session
    local active_key=""
    if [ -f "$LOCAL_STATE" ]; then
        active_key=$(read_state_var "$LOCAL_STATE" "SSH_KEY")
    fi

    # Enumerer les keypairs (meme filtre que select_ssh_key dans setup.sh)
    local keys=()
    for key in "$SSH_DIR"/*; do
        if [ -f "$key" ] && \
           [[ "$key" != *.pub ]] && \
           [[ "$(basename "$key")" != "config"* ]] && \
           [[ "$(basename "$key")" != "known_hosts"* ]] && \
           [[ "$(basename "$key")" != ".vps-bootstrap"* ]] && \
           [[ "$(basename "$key")" != ".vpskit"* ]]; then
            if [ -f "${key}.pub" ]; then
                keys+=("$key")
            fi
        fi
    done

    if [ ${#keys[@]} -eq 0 ]; then
        info "$MSG_SETTINGS_KEYS_NONE"
        echo ""
        return
    fi

    echo ""
    info "$MSG_SETTINGS_KEYS_TITLE"
    echo ""
    for i in "${!keys[@]}"; do
        local num=$((i + 1))
        local keyname
        keyname=$(basename "${keys[$i]}")
        local keytype
        keytype=$(awk '{print $1}' "${keys[$i]}.pub" | sed 's/ssh-//')
        local comment
        comment=$(awk '{print $3}' "${keys[$i]}.pub" 2>/dev/null || echo "")

        local label="$keyname ($keytype"
        if [ -n "$comment" ]; then
            label="$label, $comment"
        fi
        label="$label)"

        if [ "${keys[$i]}" = "$active_key" ]; then
            echo -e "  ${GREEN}${num})${NC} $label  ${YELLOW}${MSG_SETTINGS_KEYS_ACTIVE}${NC}"
        else
            echo -e "  ${GREEN}${num})${NC} $label"
        fi
    done
    echo ""
    echo "  0) ${MSG_SETTINGS_CANCEL}"
    echo ""

    read -p "  $(printf "$MSG_SETTINGS_KEYS_DELETE_PROMPT" "${#keys[@]}")" choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -eq 0 ] || [ "$choice" -gt "${#keys[@]}" ]; then
        info "$MSG_SETTINGS_CANCEL"
        echo ""
        return
    fi

    local idx=$((choice - 1))
    local selected_key="${keys[$idx]}"
    local selected_name
    selected_name=$(basename "$selected_key")

    # Avertissement si cle active
    if [ "$selected_key" = "$active_key" ]; then
        echo ""
        warn "$MSG_SETTINGS_KEYS_ACTIVE_WARN1"
        warn "$MSG_SETTINGS_KEYS_ACTIVE_WARN2"
        warn "$MSG_SETTINGS_KEYS_ACTIVE_WARN3"
    fi

    echo ""
    warn "$MSG_SETTINGS_KEYS_DELETE_CONFIRM"
    echo "    $selected_key"
    echo "    ${selected_key}.pub"
    echo ""
    echo -e "  ${RED}${MSG_SETTINGS_KEYS_IRREVERSIBLE}${NC}"
    echo ""
    read -p "  $MSG_SETTINGS_SSH_CONFIRM_PROMPT" confirm
    if [[ "$confirm" != "o" && "$confirm" != "O" && "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "$MSG_SETTINGS_CANCEL"
        echo ""
        return
    fi

    rm -f "$selected_key" "${selected_key}.pub"
    echo ""
    success "$(printf "$MSG_SETTINGS_KEYS_DELETED" "$selected_name")"
    echo ""
}

# =========================================
# CHANGEMENT DE LANGUE
# =========================================

change_language() {
    local current_lang="fr"
    if [ -f "$SETTINGS_FILE" ]; then
        current_lang=$(read_state_var "$SETTINGS_FILE" "LANG") || current_lang="fr"
    fi
    [ -z "$current_lang" ] && current_lang="fr"

    local current_label="Francais"
    [ "$current_lang" = "en" ] && current_label="English"

    echo ""
    info "$(printf "$MSG_SETTINGS_LANG_CURRENT" "$current_label" "$current_lang")"
    echo ""
    echo "  $MSG_SETTINGS_LANG_AVAILABLE"
    echo ""
    if [ "$current_lang" = "fr" ]; then
        echo -e "    1) Francais  ${YELLOW}${MSG_SETTINGS_LANG_ACTIVE_TAG}${NC}"
        echo "    2) English"
    else
        echo "    1) Francais"
        echo -e "    2) English  ${YELLOW}${MSG_SETTINGS_LANG_ACTIVE_TAG}${NC}"
    fi
    echo ""
    echo "    0) ${MSG_SETTINGS_CANCEL}"
    echo ""

    read -p "  ${MSG_SETTINGS_CHOICE_PROMPT}" choice

    case "$choice" in
        1)
            write_setting "LANG" "fr"
            echo ""
            success "$(printf "$MSG_SETTINGS_LANG_UPDATED" "Francais" "fr")"
            ;;
        2)
            write_setting "LANG" "en"
            echo ""
            success "$(printf "$MSG_SETTINGS_LANG_UPDATED" "English" "en")"
            ;;
        *)
            info "$MSG_SETTINGS_CANCEL"
            ;;
    esac
    echo ""
}

# =========================================
# EFFACER LA SESSION LOCALE
# =========================================

clear_session() {
    if [ ! -f "$LOCAL_STATE" ]; then
        info "$MSG_SETTINGS_SESSION_NONE"
        echo ""
        return
    fi

    local vps_ip username ssh_key
    vps_ip=$(read_state_var "$LOCAL_STATE" "VPS_IP")
    username=$(read_state_var "$LOCAL_STATE" "USERNAME")
    ssh_key=$(read_state_var "$LOCAL_STATE" "SSH_KEY")

    echo ""
    info "$MSG_SETTINGS_SESSION_TITLE"
    echo "    $(printf "$MSG_SETTINGS_SESSION_SERVER" "$vps_ip")"
    echo "    $(printf "$MSG_SETTINGS_SESSION_USER" "$username")"
    echo "    $(printf "$MSG_SETTINGS_SESSION_KEY" "$(basename "$ssh_key")")"
    echo ""
    warn "$MSG_SETTINGS_SESSION_CLEAR_WARN1"
    warn "$MSG_SETTINGS_SESSION_CLEAR_WARN2"
    echo ""
    read -p "  $MSG_SETTINGS_SSH_CONFIRM_PROMPT" confirm
    if [[ "$confirm" != "o" && "$confirm" != "O" && "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "$MSG_SETTINGS_CANCEL"
        echo ""
        return
    fi

    rm -f "$LOCAL_STATE"
    echo ""
    success "$MSG_SETTINGS_SESSION_CLEARED"
    echo ""
}

# =========================================
# DEPLOIEMENT AUTOMATIQUE (GITHUB ACTIONS)
# =========================================

setup_autodeploy() {
    local project_path app_name domain port branch deploy_user
    local session_user session_ip session_key
    local used_existing apps_data app_list app_choice workflow_file
    local confirm modify new_val tmp_deploy_user

    echo ""
    info "$MSG_SETTINGS_AUTODEPLOY_TITLE"
    echo ""
    echo "$MSG_SETTINGS_AUTODEPLOY_INTRO"
    echo "$MSG_SETTINGS_AUTODEPLOY_INTRO2"
    echo ""

    # Chemin du projet
    read -p "  $MSG_SETTINGS_AUTODEPLOY_PATH_PROMPT" project_path
    project_path="${project_path:-.}"
    # Expander ~ manuellement
    project_path="${project_path/#\~/$HOME}"
    # Chemin absolu
    project_path="$(cd "$project_path" 2>/dev/null && pwd)" || project_path=""

    if [ -z "$project_path" ] || [ ! -d "$project_path/.git" ]; then
        echo ""
        err "$(printf "$MSG_SETTINGS_AUTODEPLOY_NOT_GIT" "$project_path")"
        info "$MSG_SETTINGS_AUTODEPLOY_NOT_GIT_HINT"
        echo ""
        return
    fi

    echo ""
    success "$(printf "$MSG_SETTINGS_AUTODEPLOY_DETECTED" "$project_path")"
    echo ""

    # Charger la session pour pre-remplir
    session_user="deploy"
    session_ip=""
    session_key=""
    if [ -f "$LOCAL_STATE" ]; then
        local tmp_user
        tmp_user=$(read_state_var "$LOCAL_STATE" "USERNAME")
        [ -n "$tmp_user" ] && session_user="$tmp_user"
        session_key=$(read_state_var "$LOCAL_STATE" "SSH_KEY")
        session_ip=$(read_state_var "$LOCAL_STATE" "VPS_IP")
    fi

    # Tenter de recuperer les apps existantes sur le VPS
    app_name="" domain="" port="3000" branch="main" deploy_user="$session_user"
    used_existing=0

    if [ -n "$session_ip" ] && [ -n "$session_key" ] && [ -f "$session_key" ]; then
        info "$MSG_SETTINGS_AUTODEPLOY_FETCHING"
        apps_data=$(ssh -i "$session_key" -o ConnectTimeout=5 -o BatchMode=yes \
            "${session_user}@${session_ip}" \
            'for d in ~/apps/*/; do
                [ -d "$d" ] || continue
                name=$(basename "$d")
                domain=$(cat "$d/.deploy-domain" 2>/dev/null || echo "")
                port=$(cat "$d/.deploy-port" 2>/dev/null || echo "3000")
                branch=$(cat "$d/.deploy-branch" 2>/dev/null || echo "main")
                echo "${name}|${domain}|${port}|${branch}"
            done' 2>/dev/null || true)

        if [ -n "$apps_data" ]; then
            echo ""
            info "$MSG_SETTINGS_AUTODEPLOY_EXISTING_TITLE"
            echo ""
            local app_list=()
            local i=1
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                app_list+=("$line")
                local a_name a_domain a_port a_branch
                a_name=$(echo "$line" | cut -d'|' -f1)
                a_domain=$(echo "$line" | cut -d'|' -f2)
                a_port=$(echo "$line" | cut -d'|' -f3)
                a_branch=$(echo "$line" | cut -d'|' -f4)
                echo -e "    ${GREEN}${i})${NC} ${a_name}  ${BLUE}${a_domain}${NC}  :${a_port}  (${a_branch})"
                i=$((i + 1))
            done <<< "$apps_data"
            echo -e "    ${GREEN}${i})${NC} $MSG_SETTINGS_AUTODEPLOY_NEW_APP"
            echo ""
            read -p "  $(printf "$MSG_SETTINGS_AUTODEPLOY_SELECT_PROMPT" "$i")" app_choice

            if [[ "$app_choice" =~ ^[0-9]+$ ]] && [ "$app_choice" -ge 1 ] && [ "$app_choice" -lt "$i" ]; then
                local idx=$((app_choice - 1))
                local selected="${app_list[$idx]}"
                app_name=$(echo "$selected" | cut -d'|' -f1)
                domain=$(echo "$selected" | cut -d'|' -f2)
                port=$(echo "$selected" | cut -d'|' -f3)
                branch=$(echo "$selected" | cut -d'|' -f4)
                [ -z "$port" ] && port="3000"
                [ -z "$branch" ] && branch="main"
                used_existing=1
                echo ""
                success "$(printf "$MSG_SETTINGS_AUTODEPLOY_APP_SELECTED" "$app_name")"
            fi
        fi
    fi

    # Si pas d'app existante selectionnee, demander manuellement
    if [ $used_existing -eq 0 ]; then
        read -p "  $MSG_SETTINGS_AUTODEPLOY_APP_PROMPT" app_name
        if [ -z "$app_name" ]; then
            err "$MSG_SETTINGS_AUTODEPLOY_ERR_APP"
            echo ""
            return
        fi
        # Nettoyer le nom (meme logique que deploy.sh)
        app_name=$(printf '%s' "$app_name" | tr -cd 'a-zA-Z0-9_-')

        read -p "  $MSG_SETTINGS_AUTODEPLOY_DOMAIN_PROMPT" domain
        if [ -z "$domain" ]; then
            err "$MSG_SETTINGS_AUTODEPLOY_ERR_DOMAIN"
            echo ""
            return
        fi

        read -p "  $MSG_SETTINGS_AUTODEPLOY_PORT_PROMPT" port
        port="${port:-3000}"

        read -p "  $MSG_SETTINGS_AUTODEPLOY_BRANCH_PROMPT" branch
        branch="${branch:-main}"
    fi

    # Confirmer/modifier les valeurs pre-remplies
    if [ $used_existing -eq 1 ]; then
        echo ""
        info "$MSG_SETTINGS_AUTODEPLOY_PREFILLED"
        echo "    $(printf "$MSG_SETTINGS_AUTODEPLOY_SHOW_DOMAIN" "$domain")"
        echo "    $(printf "$MSG_SETTINGS_AUTODEPLOY_SHOW_PORT" "$port")"
        echo "    $(printf "$MSG_SETTINGS_AUTODEPLOY_SHOW_BRANCH" "$branch")"
        echo ""
        read -p "  $(printf "$MSG_SETTINGS_AUTODEPLOY_MODIFY" "$LANG_YES_PROMPT")" modify
        if [[ "$modify" =~ [$LANG_YES_CHARS] ]]; then
            local new_val
            read -p "    $(printf "$MSG_SETTINGS_AUTODEPLOY_DOMAIN_CHANGE" "$domain")" new_val
            [ -n "$new_val" ] && domain="$new_val"
            read -p "    $(printf "$MSG_SETTINGS_AUTODEPLOY_PORT_CHANGE" "$port")" new_val
            [ -n "$new_val" ] && port="$new_val"
            read -p "    $(printf "$MSG_SETTINGS_AUTODEPLOY_BRANCH_CHANGE" "$branch")" new_val
            [ -n "$new_val" ] && branch="$new_val"
        fi
    fi

    # Utilisateur SSH
    read -p "  $(printf "$MSG_SETTINGS_AUTODEPLOY_USER_PROMPT")" tmp_deploy_user
    deploy_user="${tmp_deploy_user:-$deploy_user}"

    echo ""

    # Verifier si le fichier existe deja
    local workflow_file="$project_path/.github/workflows/deploy.yml"
    if [ -f "$workflow_file" ]; then
        warn "$MSG_SETTINGS_AUTODEPLOY_ALREADY_EXISTS"
        read -p "  $(printf "$MSG_SETTINGS_AUTODEPLOY_OVERWRITE" "$LANG_YES_PROMPT")" confirm
        if [[ ! "$confirm" =~ [$LANG_YES_CHARS] ]]; then
            info "$MSG_SETTINGS_AUTODEPLOY_CANCELLED"
            echo ""
            return
        fi
        echo ""
    fi

    # Confirmation
    read -p "  $(printf "$MSG_SETTINGS_AUTODEPLOY_CONFIRM" "$LANG_YES_PROMPT")" confirm
    if [[ ! "$confirm" =~ [$LANG_YES_CHARS] ]]; then
        info "$MSG_SETTINGS_AUTODEPLOY_CANCELLED"
        echo ""
        return
    fi

    # Creer le dossier
    mkdir -p "$project_path/.github/workflows"

    # Generer le workflow
    cat > "$workflow_file" << WORKFLOW_EOF
name: Deploy

on:
  push:
    branches: [$branch]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup SSH key
        run: |
          mkdir -p ~/.ssh
          echo "\${{ secrets.VPS_SSH_KEY }}" > ~/.ssh/deploy_key
          chmod 600 ~/.ssh/deploy_key

      - name: Deploy
        run: |
          curl -sL https://raw.githubusercontent.com/mariusdjen/vpskit/main/deploy.sh -o deploy.sh
          bash deploy.sh \\
            -ip "\${{ secrets.VPS_IP }}" \\
            -key ~/.ssh/deploy_key \\
            -user $deploy_user \\
            -app $app_name \\
            -repo "git@github.com:\${{ github.repository }}.git" \\
            -domain $domain \\
            -port $port
WORKFLOW_EOF

    echo ""
    success "$(printf "$MSG_SETTINGS_AUTODEPLOY_CREATED" "$workflow_file")"
    echo ""
    info "$MSG_SETTINGS_AUTODEPLOY_SECRETS_TITLE"
    echo ""
    echo "  $MSG_SETTINGS_AUTODEPLOY_SECRETS_INTRO"
    echo "  $MSG_SETTINGS_AUTODEPLOY_SECRETS_INTRO2"
    echo ""
    echo "  $MSG_SETTINGS_AUTODEPLOY_SECRET_IP"
    echo "  $MSG_SETTINGS_AUTODEPLOY_SECRET_KEY"
    echo ""

    if [ -n "$session_key" ]; then
        info "$MSG_SETTINGS_AUTODEPLOY_KEY_HINT"
        echo "    cat $session_key"
    fi
    echo ""
}

# =========================================
# BANNIERE
# =========================================

show_banner() {
    echo ""
    echo -e "${BOLD}=========================================${NC}"
    echo -e "  ${BOLD}${MSG_SETTINGS_BANNER_TITLE}${NC}"
    echo -e "  ${MSG_SETTINGS_BANNER_SUBTITLE}"
    echo "========================================="
    echo ""

    # Afficher la session si elle existe
    if [ -f "$LOCAL_STATE" ]; then
        local vps_ip username ssh_key_name
        vps_ip=$(read_state_var "$LOCAL_STATE" "VPS_IP")
        username=$(read_state_var "$LOCAL_STATE" "USERNAME")
        ssh_key_name=$(basename "$(read_state_var "$LOCAL_STATE" "SSH_KEY")")
        info "$(printf "$MSG_SETTINGS_SESSION_ACTIVE" "$username" "$vps_ip" "$ssh_key_name")"
        echo ""
    fi
}

# =========================================
# BACKUP DISTANT (S3 + CRON)
# =========================================

setup_remote_backup() {
    echo ""
    echo -e "${BOLD}${MSG_SETTINGS_RBACKUP_TITLE}${NC}"
    echo ""
    echo "  $MSG_SETTINGS_RBACKUP_INTRO"
    echo "  $MSG_SETTINGS_RBACKUP_INTRO2"
    echo ""

    # Verifier la session
    if [ ! -f "$LOCAL_STATE" ]; then
        err "$MSG_SETTINGS_RBACKUP_ERR_NO_SESSION"
        echo ""
        return
    fi

    local vps_ip username ssh_key
    vps_ip=$(read_state_var "$LOCAL_STATE" "VPS_IP")
    username=$(read_state_var "$LOCAL_STATE" "USERNAME")
    ssh_key=$(read_state_var "$LOCAL_STATE" "SSH_KEY")

    # Configuration du stockage
    echo -e "${BOLD}[>] ${MSG_SETTINGS_RBACKUP_PROVIDER_HINT}${NC}"
    echo ""
    echo "$MSG_SETTINGS_RBACKUP_R2_STEP1"
    echo "$MSG_SETTINGS_RBACKUP_R2_STEP2"
    echo "$MSG_SETTINGS_RBACKUP_R2_STEP3"
    echo "$MSG_SETTINGS_RBACKUP_R2_STEP4"
    echo ""

    local s3_endpoint s3_bucket s3_access s3_secret

    read -p "$MSG_SETTINGS_RBACKUP_ENDPOINT_PROMPT" s3_endpoint
    if [ -z "$s3_endpoint" ]; then
        err "$MSG_SETTINGS_RBACKUP_ERR_ENDPOINT"
        echo ""
        return
    fi

    read -p "$MSG_SETTINGS_RBACKUP_BUCKET_PROMPT" s3_bucket
    if [ -z "$s3_bucket" ]; then
        err "$MSG_SETTINGS_RBACKUP_ERR_BUCKET"
        echo ""
        return
    fi

    read -p "$MSG_SETTINGS_RBACKUP_ACCESS_PROMPT" s3_access
    read -s -p "$MSG_SETTINGS_RBACKUP_SECRET_PROMPT" s3_secret
    echo ""
    if [ -z "$s3_access" ] || [ -z "$s3_secret" ]; then
        err "$MSG_SETTINGS_RBACKUP_ERR_KEYS"
        echo ""
        return
    fi

    # Cron
    echo ""
    echo -e "${BOLD}[>] ${MSG_SETTINGS_RBACKUP_CRON_TITLE}${NC}"
    echo ""
    echo "    1) $MSG_SETTINGS_RBACKUP_CRON_DAILY"
    echo "    2) $MSG_SETTINGS_RBACKUP_CRON_WEEKLY"
    echo "    3) $MSG_SETTINGS_RBACKUP_CRON_NONE"
    echo ""
    read -p "$MSG_SETTINGS_RBACKUP_CRON_PROMPT" cron_choice

    local cron_schedule="none"
    local cron_expr=""
    local cron_label=""
    case "$cron_choice" in
        1) cron_schedule="daily"; cron_expr="0 3 * * *"; cron_label="$MSG_SETTINGS_RBACKUP_CRON_DAILY_LABEL" ;;
        2) cron_schedule="weekly"; cron_expr="0 3 * * 0"; cron_label="$MSG_SETTINGS_RBACKUP_CRON_WEEKLY_LABEL" ;;
        *) cron_schedule="none" ;;
    esac

    # Retention
    read -p "$MSG_SETTINGS_RBACKUP_RETENTION_PROMPT" retention
    retention="${retention:-30}"

    # Sauvegarder la config en local
    local s3_config="$SSH_DIR/.vpskit-s3"
    printf 'S3_ENDPOINT="%s"\nS3_BUCKET="%s"\nS3_ACCESS_KEY="%s"\nS3_SECRET_KEY="%s"\nS3_RETENTION_DAYS="%s"\nS3_CRON_SCHEDULE="%s"\n' \
        "$s3_endpoint" "$s3_bucket" "$s3_access" "$s3_secret" "$retention" "$cron_schedule" > "$s3_config"
    chmod 600 "$s3_config"
    echo ""
    success "$MSG_SETTINGS_RBACKUP_SAVED"

    # Installer rclone + config sur le VPS
    echo ""
    info "$MSG_SETTINGS_RBACKUP_INSTALLING_RCLONE"

    local TMPSCRIPT
    TMPSCRIPT=$(mktemp)
    trap 'rm -f "$TMPSCRIPT"' RETURN

    local safe_endpoint safe_bucket safe_access safe_secret safe_retention safe_username
    safe_endpoint=$(sed_escape "$s3_endpoint")
    safe_bucket=$(sed_escape "$s3_bucket")
    safe_access=$(sed_escape "$s3_access")
    safe_secret=$(sed_escape "$s3_secret")
    safe_retention=$(sed_escape "$retention")
    safe_username=$(sed_escape "$username")

    cat > "$TMPSCRIPT" << 'RCLONE_EOF'
#!/bin/bash
set -euo pipefail

USERNAME="__USERNAME__"
S3_ENDPOINT="__S3_ENDPOINT__"
S3_BUCKET="__S3_BUCKET__"
S3_ACCESS="__S3_ACCESS__"
S3_SECRET="__S3_SECRET__"
RETENTION="__RETENTION__"
CRON_EXPR="__CRON_EXPR__"

# Installer rclone si absent
if ! command -v rclone &>/dev/null; then
    curl -fsSL https://rclone.org/install.sh | sudo bash 2>/dev/null
fi

# Configurer rclone
RCLONE_DIR="/home/$USERNAME/.config/rclone"
mkdir -p "$RCLONE_DIR"
cat > "$RCLONE_DIR/rclone.conf" << RCONF
[s3backup]
type = s3
provider = Cloudflare
access_key_id = $S3_ACCESS
secret_access_key = $S3_SECRET
endpoint = $S3_ENDPOINT
RCONF
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"
chmod 600 "$RCLONE_DIR/rclone.conf"

# Tester la connexion
if sudo -u "$USERNAME" rclone lsd "s3backup:$S3_BUCKET" &>/dev/null; then
    echo "[OK] Connexion au bucket reussie."
else
    echo "[WARN] Impossible de lister le bucket. Verifiez les credentials."
fi

# Configurer le cron si demande
if [ -n "$CRON_EXPR" ]; then
    # Creer le script de backup cron
    CRON_SCRIPT="/home/$USERNAME/backup-cron.sh"
    cat > "$CRON_SCRIPT" << 'CRONSCRIPT'
#!/bin/bash
set -euo pipefail
APPS_DIR="$HOME/apps"
DATE=$(date +%Y-%m-%d)
BUCKET="__CRON_BUCKET__"
RETENTION="__CRON_RETENTION__"

for APP_PATH in "$APPS_DIR"/*/; do
    [ -d "$APP_PATH" ] || continue
    APP=$(basename "$APP_PATH")
    WORK="/tmp/vps-backup-cron-$APP"
    rm -rf "$WORK"
    mkdir -p "$WORK"

    # .env
    [ -f "$APP_PATH/.env" ] && cp "$APP_PATH/.env" "$WORK/env"

    # Metadonnees
    [ -f "$APP_PATH/.deploy-domain" ] && cp "$APP_PATH/.deploy-domain" "$WORK/deploy-domain"
    [ -f "$APP_PATH/.deploy-port" ] && cp "$APP_PATH/.deploy-port" "$WORK/deploy-port"

    # Caddyfile
    [ -f /etc/caddy/Caddyfile ] && cp /etc/caddy/Caddyfile "$WORK/Caddyfile"

    # Dump SQL
    COMPOSE_FILE=""
    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        [ -f "$APP_PATH/$f" ] && COMPOSE_FILE="$f" && break
    done
    if [ -n "$COMPOSE_FILE" ]; then
        SERVICES=$(cd "$APP_PATH" && docker compose ps --format '{{.Service}}:{{.Image}}' 2>/dev/null || true)
        while IFS= read -r svc_info; do
            [ -z "$svc_info" ] && continue
            SVC=$(echo "$svc_info" | cut -d: -f1)
            IMG=$(echo "$svc_info" | cut -d: -f2-)
            if echo "$IMG" | grep -qi "postgres"; then
                DB_USER=$(cd "$APP_PATH" && docker compose exec -T "$SVC" printenv POSTGRES_USER 2>/dev/null || echo "postgres")
                DB_NAME=$(cd "$APP_PATH" && docker compose exec -T "$SVC" printenv POSTGRES_DB 2>/dev/null || echo "")
                if [ -z "$DB_NAME" ]; then
                    docker compose -f "$APP_PATH/$COMPOSE_FILE" exec -T "$SVC" pg_dumpall -U "$DB_USER" 2>/dev/null | gzip > "$WORK/db-postgres-${SVC}.sql.gz" || true
                else
                    docker compose -f "$APP_PATH/$COMPOSE_FILE" exec -T "$SVC" pg_dump -U "$DB_USER" "$DB_NAME" 2>/dev/null | gzip > "$WORK/db-postgres-${SVC}.sql.gz" || true
                fi
            fi
            if echo "$IMG" | grep -qiE "mysql|mariadb"; then
                DB_PASS=$(cd "$APP_PATH" && docker compose exec -T "$SVC" printenv MYSQL_ROOT_PASSWORD 2>/dev/null || echo "")
                if [ -n "$DB_PASS" ]; then
                    docker compose -f "$APP_PATH/$COMPOSE_FILE" exec -T "$SVC" mysqldump --all-databases -uroot -p"$DB_PASS" 2>/dev/null | gzip > "$WORK/db-mysql-${SVC}.sql.gz" || true
                else
                    docker compose -f "$APP_PATH/$COMPOSE_FILE" exec -T "$SVC" mysqldump --all-databases -uroot 2>/dev/null | gzip > "$WORK/db-mysql-${SVC}.sql.gz" || true
                fi
            fi
            if echo "$IMG" | grep -qi "mongo"; then
                docker compose -f "$APP_PATH/$COMPOSE_FILE" exec -T "$SVC" mongodump --archive 2>/dev/null | gzip > "$WORK/db-mongo-${SVC}.archive.gz" || true
            fi
        done <<< "$SERVICES"

        # Volumes
        VOLUMES=$(cd "$APP_PATH" && docker compose config --volumes 2>/dev/null || true)
        PROJECT_NAME=$(cd "$APP_PATH" && docker compose config --format json 2>/dev/null | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "$APP")
        if [ -n "$VOLUMES" ]; then
            while IFS= read -r vol; do
                [ -z "$vol" ] && continue
                FULL_VOL="${PROJECT_NAME}_${vol}"
                if docker volume inspect "$FULL_VOL" &>/dev/null; then
                    docker run --rm -v "$FULL_VOL":/data -v "$WORK":/backup alpine tar czf "/backup/volume-${FULL_VOL}.tar.gz" /data 2>/dev/null || true
                elif docker volume inspect "$vol" &>/dev/null; then
                    docker run --rm -v "$vol":/data -v "$WORK":/backup alpine tar czf "/backup/volume-${vol}.tar.gz" /data 2>/dev/null || true
                fi
            done <<< "$VOLUMES"
        fi
    fi

    # Archive
    ARCHIVE="/tmp/vps-backup-${DATE}-${APP}.tar.gz"
    tar czf "$ARCHIVE" -C "$WORK" .
    rm -rf "$WORK"

    # Upload
    rclone copy "$ARCHIVE" "s3backup:$BUCKET/" 2>/dev/null || true
    rm -f "$ARCHIVE"
done

# Rotation
if [ -n "$RETENTION" ] && [ "$RETENTION" -gt 0 ] 2>/dev/null; then
    rclone delete "s3backup:$BUCKET/" --min-age "${RETENTION}d" 2>/dev/null || true
fi

echo "[$(date)] Backup cron termine" >> "$HOME/backup-cron.log"
CRONSCRIPT

    # Remplacer les placeholders du script cron (echapper pour sed)
    SAFE_CRON_BUCKET=$(printf '%s' "$S3_BUCKET" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/|/\\|/g')
    SAFE_CRON_RETENTION=$(printf '%s' "$RETENTION" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/|/\\|/g')
    sed -i "s|__CRON_BUCKET__|$SAFE_CRON_BUCKET|g" "$CRON_SCRIPT"
    sed -i "s|__CRON_RETENTION__|$SAFE_CRON_RETENTION|g" "$CRON_SCRIPT"

    chmod 700 "$CRON_SCRIPT"
    chown "$USERNAME:$USERNAME" "$CRON_SCRIPT"

    # Installer le cron
    (sudo -u "$USERNAME" crontab -l 2>/dev/null | grep -v "backup-cron.sh"; echo "$CRON_EXPR $CRON_SCRIPT >> /home/$USERNAME/backup-cron.log 2>&1") | sudo -u "$USERNAME" crontab -
fi
RCLONE_EOF

    if [ "$OS" = "mac" ]; then
        sed -i '' "s|__USERNAME__|$safe_username|g" "$TMPSCRIPT"
        sed -i '' "s|__S3_ENDPOINT__|$safe_endpoint|g" "$TMPSCRIPT"
        sed -i '' "s|__S3_BUCKET__|$safe_bucket|g" "$TMPSCRIPT"
        sed -i '' "s|__S3_ACCESS__|$safe_access|g" "$TMPSCRIPT"
        sed -i '' "s|__S3_SECRET__|$safe_secret|g" "$TMPSCRIPT"
        sed -i '' "s|__RETENTION__|$safe_retention|g" "$TMPSCRIPT"
        sed -i '' "s|__CRON_EXPR__|$cron_expr|g" "$TMPSCRIPT"
    else
        sed -i "s|__USERNAME__|$safe_username|g" "$TMPSCRIPT"
        sed -i "s|__S3_ENDPOINT__|$safe_endpoint|g" "$TMPSCRIPT"
        sed -i "s|__S3_BUCKET__|$safe_bucket|g" "$TMPSCRIPT"
        sed -i "s|__S3_ACCESS__|$safe_access|g" "$TMPSCRIPT"
        sed -i "s|__S3_SECRET__|$safe_secret|g" "$TMPSCRIPT"
        sed -i "s|__RETENTION__|$safe_retention|g" "$TMPSCRIPT"
        sed -i "s|__CRON_EXPR__|$cron_expr|g" "$TMPSCRIPT"
    fi

    local REMOTE_TMP
    REMOTE_TMP=$(ssh -i "$ssh_key" -o BatchMode=yes "${username}@${vps_ip}" "mktemp /tmp/vps-XXXXXXXXXX.sh")
    scp -i "$ssh_key" "$TMPSCRIPT" "${username}@${vps_ip}:${REMOTE_TMP}"
    rm -f "$TMPSCRIPT"

    ssh -i "$ssh_key" "${username}@${vps_ip}" "chmod 700 '${REMOTE_TMP}'; sudo bash '${REMOTE_TMP}'; rm -f '${REMOTE_TMP}'"

    echo ""
    success "$MSG_SETTINGS_RBACKUP_RCLONE_OK"
    success "$MSG_SETTINGS_RBACKUP_CONFIG_OK"
    if [ -n "$cron_expr" ]; then
        success "$(printf "$MSG_SETTINGS_RBACKUP_CRON_OK" "$cron_label")"
    fi
    echo ""
    success "$MSG_SETTINGS_RBACKUP_DONE"
    echo "  $MSG_SETTINGS_RBACKUP_TEST_HINT"
    echo ""
}

show_menu() {
    echo -e "${BOLD}${MSG_SETTINGS_MENU_TITLE}${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} ${MSG_SETTINGS_MENU_1}"
    echo -e "  ${GREEN}2)${NC} ${MSG_SETTINGS_MENU_2}"
    echo -e "  ${GREEN}3)${NC} ${MSG_SETTINGS_MENU_3}"
    echo -e "  ${GREEN}4)${NC} ${MSG_SETTINGS_MENU_4}"
    echo -e "  ${GREEN}5)${NC} ${MSG_SETTINGS_MENU_5}"
    echo -e "  ${GREEN}6)${NC} ${MSG_SETTINGS_MENU_6}"
    echo -e "  ${GREEN}7)${NC} ${MSG_SETTINGS_MENU_7}"
    echo ""
}

main() {
    show_banner

    while true; do
        show_menu
        read -p "  $MSG_SETTINGS_CHOICE_PROMPT" choice

        case "$choice" in
            1)
                echo ""
                manage_ssh_shortcuts
                ;;
            2)
                echo ""
                manage_ssh_keys
                ;;
            3)
                change_language
                ;;
            4)
                clear_session
                ;;
            5)
                setup_autodeploy
                ;;
            6)
                setup_remote_backup
                ;;
            7)
                echo ""
                info "$MSG_SETTINGS_BACK"
                echo ""
                exit 0
                ;;
            *)
                echo ""
                warn "$MSG_SETTINGS_INVALID_CHOICE"
                echo ""
                ;;
        esac
    done
}

main "$@"
