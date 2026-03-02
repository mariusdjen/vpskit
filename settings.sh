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
# MENU PRINCIPAL
# =========================================

show_menu() {
    echo -e "${BOLD}${MSG_SETTINGS_MENU_TITLE}${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} ${MSG_SETTINGS_MENU_1}"
    echo -e "  ${GREEN}2)${NC} ${MSG_SETTINGS_MENU_2}"
    echo -e "  ${GREEN}3)${NC} ${MSG_SETTINGS_MENU_3}"
    echo -e "  ${GREEN}4)${NC} ${MSG_SETTINGS_MENU_4}"
    echo -e "  ${GREEN}5)${NC} ${MSG_SETTINGS_MENU_5}"
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
