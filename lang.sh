#!/bin/bash
# ============================================
# Chargeur de langue pour VPS Kit
# Source ce fichier depuis les scripts principaux
# ============================================

_lang_read_var() {
    grep "^${2}=" "$1" 2>/dev/null | head -1 | cut -d'=' -f2- | sed 's/^"//;s/"$//'
}

_find_lang_dir() {
    # Chercher le dossier lang/ a cote du script appelant
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" 2>/dev/null && pwd)"
    if [ -d "${script_dir}/lang" ]; then
        echo "${script_dir}/lang"
        return
    fi
    # Chercher a cote de ce fichier (lang.sh)
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    if [ -d "${script_dir}/lang" ]; then
        echo "${script_dir}/lang"
        return
    fi
    # Fallback : cache local
    local cache_dir="$HOME/.ssh/.vpskit-lang-cache"
    mkdir -p "$cache_dir"
    echo "$cache_dir"
}

choose_language() {
    echo "" >&2
    echo "  Select language / Choisir la langue :" >&2
    echo "" >&2
    echo "    1) Francais" >&2
    echo "    2) English" >&2
    echo "" >&2
    read -p "  Choice / Choix (1/2) : " _lang_choice >&2
    case "$_lang_choice" in
        2) echo "en" ;;
        *) echo "fr" ;;
    esac
}

save_lang_preference() {
    local code="$1"
    local settings_file
    if [ "$OS" = "windows" ] 2>/dev/null; then
        settings_file="$USERPROFILE/.ssh/.vpskit-settings"
    else
        settings_file="$HOME/.ssh/.vpskit-settings"
    fi

    if [ ! -f "$settings_file" ]; then
        printf 'LANG="%s"\n' "$code" > "$settings_file"
        chmod 600 "$settings_file"
    elif grep -q "^LANG=" "$settings_file" 2>/dev/null; then
        if [ "$(uname -s)" = "Darwin" ]; then
            sed -i '' "s|^LANG=.*|LANG=\"${code}\"|" "$settings_file"
        else
            sed -i "s|^LANG=.*|LANG=\"${code}\"|" "$settings_file"
        fi
    else
        printf 'LANG="%s"\n' "$code" >> "$settings_file"
    fi
}

load_lang() {
    local lang_code=""
    local settings_file
    if [ "$OS" = "windows" ] 2>/dev/null; then
        settings_file="$USERPROFILE/.ssh/.vpskit-settings"
    else
        settings_file="$HOME/.ssh/.vpskit-settings"
    fi

    # 1. Lire depuis le fichier de parametres
    if [ -f "$settings_file" ]; then
        lang_code=$(_lang_read_var "$settings_file" "LANG")
    fi

    # 2. Fallback : variable d'environnement VPSKIT_LANG
    if [ -z "$lang_code" ] && [ -n "${VPSKIT_LANG:-}" ]; then
        lang_code="$VPSKIT_LANG"
    fi

    # 3. Si aucune langue trouvee : demander (premier lancement, mode interactif)
    if [ -z "$lang_code" ]; then
        if [ -t 0 ]; then
            lang_code=$(choose_language)
            save_lang_preference "$lang_code"
        else
            lang_code="fr"
        fi
    fi

    # 4. Charger le fichier de langue
    local lang_dir
    lang_dir=$(_find_lang_dir)
    local lang_file="${lang_dir}/${lang_code}.sh"

    if [ ! -f "$lang_file" ]; then
        # Essayer de telecharger si on est en mode curl
        local repo_base="${REPO_BASE:-https://raw.githubusercontent.com/mariusdjen/vpskit/main}"
        if command -v curl &>/dev/null; then
            curl -fsSL "${repo_base}/lang/${lang_code}.sh" -o "$lang_file" 2>/dev/null || true
        elif command -v wget &>/dev/null; then
            wget -qO "$lang_file" "${repo_base}/lang/${lang_code}.sh" 2>/dev/null || true
        fi
    fi

    if [ ! -f "$lang_file" ]; then
        # Dernier fallback : francais
        lang_file="${lang_dir}/fr.sh"
    fi

    if [ -f "$lang_file" ]; then
        # shellcheck source=/dev/null
        . "$lang_file"
    fi

    VPSKIT_LANG_CODE="${lang_code}"
}

# Fonction pour injecter les messages dans un script distant
inject_lang_into_remote() {
    local tmpscript="$1"
    local lang_dir
    lang_dir=$(_find_lang_dir)
    local lang_file="${lang_dir}/${VPSKIT_LANG_CODE:-fr}.sh"

    if [ ! -f "$lang_file" ]; then
        return
    fi

    local tmpscript_new
    tmpscript_new=$(mktemp)

    {
        echo '#!/bin/bash'
        echo '# --- Langue injectee par le script local ---'
        grep '^RMSG_' "$lang_file" || true
        grep '^LANG_' "$lang_file" || true
        echo '# --- Fin bloc langue ---'
        echo ''
        # Tout sauf le shebang original
        tail -n +2 "$tmpscript"
    } > "$tmpscript_new"
    mv "$tmpscript_new" "$tmpscript"
}

load_lang
