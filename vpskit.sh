#!/bin/bash
set -euo pipefail

# ============================================
# VPSKIT - Point d'entree unique
# Configure, deploie, surveille et sauvegarde votre VPS
#
# Usage : bash <(curl -sL https://raw.githubusercontent.com/mariusdjen/vpskit/main/vpskit.sh)
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

# --- URL de base du repo ---
REPO_BASE="https://raw.githubusercontent.com/mariusdjen/vpskit/main"

# --- Banniere ---
show_banner() {
    echo ""
    echo -e "${BOLD}${GREEN}"
    echo "  _   _____  _____ _  _____ _____"
    echo " | | / / _ \\/ ___/ |/ /  _/_  __/"
    echo " | |/ / ___/\\__ \\|   // /  / /   "
    echo " |___/_/   /____/_/\\_/___/ /_/    "
    echo -e "${NC}"
    echo -e "  ${BOLD}Set up. Secure. Deploy.${NC}"
    echo -e "  ${BLUE}https://vpskit.pro${NC}"
    echo ""
}

# --- Menu principal ---
show_menu() {
    echo -e "${BOLD}=== Que voulez-vous faire ? ===${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Configurer un nouveau VPS (ou mise a jour)"
    echo -e "  ${GREEN}2)${NC} Deployer une application"
    echo -e "  ${GREEN}3)${NC} Voir l'etat du VPS et des apps"
    echo -e "  ${GREEN}4)${NC} Sauvegarder / Restaurer une app"
    echo -e "  ${GREEN}5)${NC} Quitter"
    echo ""
}

# --- Telecharger et executer un script ---
run_script() {
    local script_name="$1"
    local script_url="${REPO_BASE}/${script_name}"
    local tmp_script

    tmp_script=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_script'" EXIT

    info "Telechargement de ${script_name}..."

    if command -v curl &>/dev/null; then
        if ! curl -fsSL "$script_url" -o "$tmp_script"; then
            err "Impossible de telecharger ${script_name}"
            rm -f "$tmp_script"
            return 1
        fi
    elif command -v wget &>/dev/null; then
        if ! wget -qO "$tmp_script" "$script_url"; then
            err "Impossible de telecharger ${script_name}"
            rm -f "$tmp_script"
            return 1
        fi
    else
        err "curl ou wget requis"
        rm -f "$tmp_script"
        return 1
    fi

    # Verification que le fichier n'est pas vide
    if [ ! -s "$tmp_script" ]; then
        err "Le fichier telecharge est vide"
        rm -f "$tmp_script"
        return 1
    fi

    # Verification syntaxe bash
    if ! bash -n "$tmp_script" 2>/dev/null; then
        err "Le script telecharge contient des erreurs de syntaxe"
        rm -f "$tmp_script"
        return 1
    fi

    success "Script telecharge et verifie"
    echo ""

    bash "$tmp_script"
    rm -f "$tmp_script"
    trap - EXIT
}

# --- Detection si le script est execute en local ---
is_local() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [ -f "${script_dir}/setup.sh" ] && [ -f "${script_dir}/deploy.sh" ]
}

# --- Executer un script local ---
run_local() {
    local script_name="$1"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local script_path="${script_dir}/${script_name}"

    if [ ! -f "$script_path" ]; then
        err "Script introuvable : ${script_path}"
        return 1
    fi

    bash "$script_path"
}

# --- Lancer le bon script ---
launch() {
    local script_name="$1"
    if is_local; then
        run_local "$script_name"
    else
        run_script "$script_name"
    fi
}

# --- Main ---
main() {
    show_banner

    # Si des arguments sont passes, les transmettre directement
    if [ $# -gt 0 ]; then
        case "$1" in
            setup)    shift; launch "setup.sh" "$@" ;;
            deploy)   shift; launch "deploy.sh" "$@" ;;
            status)   shift; launch "status.sh" "$@" ;;
            backup)   shift; launch "backup.sh" "$@" ;;
            *)
                err "Commande inconnue : $1"
                echo ""
                echo "  Usage : bash vpskit.sh [setup|deploy|status|backup]"
                exit 1
                ;;
        esac
        return
    fi

    # Mode interactif : afficher le menu
    while true; do
        show_menu
        read -p "  Votre choix (1-5) : " choice

        case "$choice" in
            1)
                echo ""
                launch "setup.sh"
                echo ""
                ;;
            2)
                echo ""
                launch "deploy.sh"
                echo ""
                ;;
            3)
                echo ""
                launch "status.sh"
                echo ""
                ;;
            4)
                echo ""
                launch "backup.sh"
                echo ""
                ;;
            5)
                echo ""
                info "A bientot !"
                exit 0
                ;;
            *)
                echo ""
                warn "Choix invalide, entrez un nombre entre 1 et 5"
                echo ""
                ;;
        esac
    done
}

main "$@"
