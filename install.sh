#!/bin/bash
set -e

# =============================================================================
# Script info
# =============================================================================
SCRIPT_NAME="Prestashop Docker Toolbox"
SCRIPT_VERSION="1.2.5"

# GitHub repository for auto-update (owner/repo format)
GITHUB_REPO="PublikoFR/PrestashopDockerToolbox"

# =============================================================================
# Configuration - Load from .env.install
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.install"

if [[ -f "${ENV_FILE}" ]]; then
    source "${ENV_FILE}"
else
    echo -e "\033[0;31m✗ Error:\033[0m .env.install file not found"
    echo -e "  Copy .env.install.example to .env.install and configure it"
    exit 1
fi

# Validate required variables
[[ -z "${PRESTASHOP_PATH:-}" ]] && echo -e "\033[0;31m✗ Error:\033[0m PRESTASHOP_PATH not defined in .env.install" && exit 1
[[ -z "${DOCKER_CONTAINER:-}" ]] && echo -e "\033[0;31m✗ Error:\033[0m DOCKER_CONTAINER not defined in .env.install" && exit 1

# Backwards compatibility: MODULE_NAME -> NAME
[[ -z "${NAME:-}" && -n "${MODULE_NAME:-}" ]] && NAME="${MODULE_NAME}"
[[ -z "${NAME:-}" ]] && echo -e "\033[0;31m✗ Error:\033[0m NAME not defined in .env.install" && exit 1

# Default TYPE to module for backwards compatibility
[[ -z "${TYPE:-}" ]] && TYPE="module"
[[ "$TYPE" != "module" && "$TYPE" != "theme" ]] && echo -e "\033[0;31m✗ Error:\033[0m TYPE must be 'module' or 'theme'" && exit 1
# =============================================================================

# Set paths based on TYPE
SOURCE_DIR="${SCRIPT_DIR}/${NAME}"
if [[ "$TYPE" == "module" ]]; then
    TARGET_DIR="${PRESTASHOP_PATH}/modules/${NAME}"
    ITEM_VERSION=$(grep "this->version" "${SOURCE_DIR}/${NAME}.php" 2>/dev/null | head -1 | grep -oP "'[0-9]+\.[0-9]+\.[0-9]+'" | tr -d "'" || echo "1.0.0")
    TYPE_LABEL="Module"
else
    TARGET_DIR="${PRESTASHOP_PATH}/themes/${NAME}"
    ITEM_VERSION=$(grep "version:" "${SOURCE_DIR}/config/theme.yml" 2>/dev/null | head -1 | sed 's/.*: *//' || echo "1.0.0")
    TYPE_LABEL="Theme"
fi

BACKUP_DIR="${SCRIPT_DIR}/.backups"
MAX_BACKUPS=5

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# =============================================================================
# Utility functions
# =============================================================================
success_msg() {
    echo -e "${GREEN}✓${NC} $1"
}

error_msg() {
    echo -e "${RED}✗ Error:${NC} $1"
    return 1
}

info_msg() {
    echo -e "${BLUE}→${NC} $1"
}

check_prerequisites() {
    if [[ "$TYPE" == "module" ]]; then
        [[ ! -d "${SOURCE_DIR}" ]] && error_msg "Source folder ${NAME}/ not found"
    else
        [[ ! -f "${SOURCE_DIR}/config/theme.yml" ]] && error_msg "config/theme.yml not found in ${NAME}/"
    fi
    [[ ! -d "${PRESTASHOP_PATH}" ]] && error_msg "PrestaShop not found: ${PRESTASHOP_PATH}"
    docker ps --format '{{.Names}}' | grep -q "^${DOCKER_CONTAINER}$" || error_msg "Docker container '${DOCKER_CONTAINER}' not running"
}

# =============================================================================
# Auto-update
# =============================================================================
LATEST_VERSION=""

check_for_update() {
    local update_available=false

    info_msg "Checking for updates..."

    # Fetch latest tag from GitHub API (portable grep without -P)
    LATEST_VERSION=$(curl -s --connect-timeout 5 "https://api.github.com/repos/${GITHUB_REPO}/tags" 2>/dev/null \
        | grep -o '"name": *"[0-9.]*"' \
        | head -1 \
        | sed 's/[^0-9.]//g' || echo "")

    if [[ -z "$LATEST_VERSION" ]]; then
        error_msg "Unable to check for updates (no connection or no tags?)"
        return 1
    fi

    if [[ "$LATEST_VERSION" != "$SCRIPT_VERSION" ]]; then
        # Compare versions (simple semver)
        if [[ "$(printf '%s\n' "$SCRIPT_VERSION" "$LATEST_VERSION" | sort -V | tail -n1)" == "$LATEST_VERSION" ]]; then
            update_available=true
        fi
    fi

    if [[ "$update_available" == true ]]; then
        echo ""
        echo -e "${YELLOW}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║${NC}  ${BOLD}New version available!${NC}"
        echo -e "${YELLOW}║${NC}  Current: ${RED}${SCRIPT_VERSION}${NC} → New: ${GREEN}${LATEST_VERSION}${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  Update now? [y/N] "
        read -rsn1 answer
        echo ""

        if [[ "$answer" == "o" || "$answer" == "O" || "$answer" == "y" || "$answer" == "Y" ]]; then
            do_update
        else
            info_msg "Update skipped"
        fi
    else
        success_msg "You are using the latest version (${SCRIPT_VERSION})"
    fi
}

do_update() {
    local temp_script
    local download_url="https://raw.githubusercontent.com/${GITHUB_REPO}/${LATEST_VERSION}/install.sh"
    temp_script=$(mktemp)

    info_msg "Downloading version ${LATEST_VERSION}..."

    if curl -s --connect-timeout 10 "$download_url" -o "$temp_script" 2>/dev/null; then
        # Verify downloaded file is valid (starts with #!/bin/bash)
        if head -1 "$temp_script" | grep -q "^#!/bin/bash"; then
            # Backup old version
            cp "${SCRIPT_DIR}/install.sh" "${SCRIPT_DIR}/install.sh.bak"

            # Replace script
            mv "$temp_script" "${SCRIPT_DIR}/install.sh"
            chmod +x "${SCRIPT_DIR}/install.sh"

            success_msg "Update complete!"
            echo -e "${DIM}  Old script saved: install.sh.bak${NC}"
            echo ""
            echo -e "${YELLOW}Restart the script to use the new version.${NC}"
            exit 0
        else
            rm -f "$temp_script"
            error_msg "Downloaded file is invalid"
            return 1
        fi
    else
        rm -f "$temp_script"
        error_msg "Download failed"
        return 1
    fi
}

action_update_script() {
    check_for_update
}

# =============================================================================
# Backup functions
# =============================================================================
backup_target() {
    # Skip if target doesn't exist
    if [[ ! -d "${TARGET_DIR}" ]]; then
        info_msg "No target to backup"
        return 0
    fi

    local timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    local backup_path="${BACKUP_DIR}/${timestamp}"

    info_msg "Backing up target..."
    mkdir -p "${backup_path}"
    cp -r "${TARGET_DIR}/." "${backup_path}/"
    success_msg "Backup created: ${timestamp}"

    # Cleanup old backups
    cleanup_old_backups
}

cleanup_old_backups() {
    [[ ! -d "${BACKUP_DIR}" ]] && return 0

    local backup_count=$(find "${BACKUP_DIR}" -maxdepth 1 -mindepth 1 -type d | wc -l)

    if [[ $backup_count -gt $MAX_BACKUPS ]]; then
        info_msg "Cleaning up old backups..."
        ls -1dt "${BACKUP_DIR}"/*/ | tail -n +$((MAX_BACKUPS + 1)) | while read -r dir; do
            rm -rf "$dir"
        done
        success_msg "Old backups removed (keeping last ${MAX_BACKUPS})"
    fi
}

list_backups() {
    if [[ ! -d "${BACKUP_DIR}" ]] || [[ -z "$(ls -A "${BACKUP_DIR}" 2>/dev/null)" ]]; then
        echo ""
        return 1
    fi
    ls -1t "${BACKUP_DIR}" 2>/dev/null
}

action_restore() {
    local backups=($(list_backups))

    if [[ ${#backups[@]} -eq 0 ]]; then
        info_msg "No backup available"
        return 0
    fi

    # Add "Cancel" option at the end
    backups+=("Cancel")

    local selected=0
    local key

    while true; do
        clear
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}  ${BOLD}${SCRIPT_NAME}${NC} v${YELLOW}${SCRIPT_VERSION}${NC}"
        echo -e "${CYAN}║${NC}  ${TYPE_LABEL}: ${BOLD}${NAME}${NC} v${YELLOW}${ITEM_VERSION}${NC}"
        echo -e "${CYAN}║${NC}  ${DIM}Restore a backup${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
        echo ""

        for i in "${!backups[@]}"; do
            if [[ $i -eq $selected ]]; then
                echo -e "  ${GREEN}▸${NC} ${BOLD}${backups[$i]}${NC}"
            else
                echo -e "    ${DIM}${backups[$i]}${NC}"
            fi
        done

        echo ""
        echo -e "${DIM}  ↑↓ Navigate  ⏎ Select  Esc Cancel${NC}"

        IFS= read -rsn1 key

        if [[ "$key" == $'\x1b' ]]; then
            read -rsn1 -t 0.3 k1
            if [[ -z "$k1" ]]; then
                info_msg "Restore cancelled"
                return 2
            fi
            read -rsn1 -t 0.3 k2
            case "${k1}${k2}" in
                '[A') [[ $selected -gt 0 ]] && selected=$((selected - 1)) || selected=$((${#backups[@]} - 1)) ;;
                '[B') [[ $selected -lt $((${#backups[@]} - 1)) ]] && selected=$((selected + 1)) || selected=0 ;;
            esac
            continue
        fi

        case "$key" in
            '')  # Enter
                # Check if "Cancel" selected (last option)
                if [[ $selected -eq $((${#backups[@]} - 1)) ]]; then
                    info_msg "Restore cancelled"
                    return 2
                fi

                local selected_backup="${backups[$selected]}"
                local backup_path="${BACKUP_DIR}/${selected_backup}"

                clear
                echo ""
                info_msg "Restoring ${selected_backup}..."

                rm -rf "${TARGET_DIR:?}"
                mkdir -p "${TARGET_DIR}"
                cp -r "${backup_path}/." "${TARGET_DIR}/"

                success_msg "Backup restored: ${selected_backup}"
                clear_cache
                return 0
                ;;
            'q'|'Q')
                info_msg "Restore cancelled"
                return 2
                ;;
        esac
    done
}

# =============================================================================
# Common actions
# =============================================================================
PS_EXEC="docker exec -e SERVER_PORT=80 -e HTTP_HOST=localhost ${DOCKER_CONTAINER}"
PS_CONSOLE="php -d memory_limit=1G /var/www/html/bin/console"

clear_cache() {
    info_msg "Clearing cache..."
    docker exec ${DOCKER_CONTAINER} sh -c "rm -rf /var/www/html/var/cache/* && mkdir -p /var/www/html/var/cache/dev && chown -R www-data:www-data /var/www/html/var/cache && chmod -R 775 /var/www/html/var/cache" 2>/dev/null || true
    success_msg "Cache cleared"
}

action_clear_cache() {
    clear_cache
}

action_restart_docker() {
    info_msg "Stopping containers..."
    cd "${PRESTASHOP_PATH}"
    docker compose down
    info_msg "Restarting containers..."
    docker compose up -d
    cd "${SCRIPT_DIR}"
    success_msg "Containers restarted"
}

action_update_translations() {
    local script_path="${SCRIPT_DIR}/generate_translations.php"

    if [[ ! -f "$script_path" ]]; then
        error_msg "generate_translations.php not found"
        return 1
    fi

    cd "${SOURCE_DIR}"
    php "$script_path" --stats-only
    cd "${SCRIPT_DIR}"
}

action_build_zip() {
    local zip_name="${NAME}_v${ITEM_VERSION}.zip"
    local temp_dir=$(mktemp -d)

    rm -f "${SCRIPT_DIR}/${zip_name}"

    info_msg "Copying files..."
    cp -r "${SOURCE_DIR}" "${temp_dir}/${NAME}"

    info_msg "Cleaning up..."
    find "${temp_dir}/${NAME}" -name ".git*" -exec rm -rf {} + 2>/dev/null || true
    find "${temp_dir}/${NAME}" -name ".claude*" -exec rm -rf {} + 2>/dev/null || true
    find "${temp_dir}/${NAME}" -name ".grepai*" -exec rm -rf {} + 2>/dev/null || true
    find "${temp_dir}/${NAME}" -name "CLAUDE.md" -exec rm -f {} + 2>/dev/null || true
    find "${temp_dir}/${NAME}" -name "TODO.md" -exec rm -f {} + 2>/dev/null || true
    find "${temp_dir}/${NAME}" -name "*.zip" -exec rm -f {} + 2>/dev/null || true
    find "${temp_dir}/${NAME}" -name "*.sh" -exec rm -f {} + 2>/dev/null || true
    find "${temp_dir}/${NAME}" -name ".DS_Store" -exec rm -f {} + 2>/dev/null || true
    find "${temp_dir}/${NAME}" -name "*.swp" -exec rm -f {} + 2>/dev/null || true
    find "${temp_dir}/${NAME}" -name "*~" -exec rm -f {} + 2>/dev/null || true
    rm -rf "${temp_dir}/${NAME}/vendor" 2>/dev/null || true
    rm -rf "${temp_dir}/${NAME}/node_modules" 2>/dev/null || true
    rm -rf "${temp_dir}/${NAME}/.idea" 2>/dev/null || true

    info_msg "Creating archive..."
    cd "${temp_dir}"
    zip -rq "${SCRIPT_DIR}/${zip_name}" "${NAME}"
    cd "${SCRIPT_DIR}"

    rm -rf "${temp_dir}"

    local zip_size=$(du -h "${SCRIPT_DIR}/${zip_name}" | cut -f1)
    success_msg "Archive created: ${zip_name} (${zip_size})"
}

# =============================================================================
# Module-specific actions
# =============================================================================
sync_files_module() {
    backup_target
    info_msg "Synchronizing files..."
    mkdir -p "${TARGET_DIR}"
    cp -r "${SOURCE_DIR}/"* "${TARGET_DIR}/"
    success_msg "Files copied to ${TARGET_DIR}"
}

delete_files_module() {
    info_msg "Deleting module files..."
    if [[ -d "${TARGET_DIR}" ]]; then
        rm -rf "${TARGET_DIR:?}/"*
        success_msg "Files deleted"
    else
        info_msg "Folder does not exist, nothing to delete"
    fi
}

do_install_module() {
    info_msg "Installing module..."
    if ${PS_EXEC} ${PS_CONSOLE} prestashop:module install ${NAME} 2>&1 | grep -q "réussi\|successful"; then
        success_msg "Module installed"
    else
        error_msg "Installation failed"
    fi
}

do_uninstall_module() {
    info_msg "Uninstalling module..."
    ${PS_EXEC} ${PS_CONSOLE} prestashop:module uninstall ${NAME} 2>&1 | grep -q "réussi\|successful" || true
    success_msg "Module uninstalled"
}

# Module composite actions
action_module_install() {
    sync_files_module || return 1
    do_install_module || return 1
    clear_cache
}

action_module_uninstall() {
    do_uninstall_module || return 1
    clear_cache
}

action_module_uninstall_reinstall() {
    do_uninstall_module || return 1
    sync_files_module || return 1
    do_install_module || return 1
    clear_cache
}

action_module_delete() {
    do_uninstall_module || return 1
    delete_files_module || return 1
    clear_cache
}

action_module_delete_reinstall() {
    do_uninstall_module || return 1
    delete_files_module || return 1
    sync_files_module || return 1
    do_install_module || return 1
    clear_cache
}

# =============================================================================
# Theme-specific actions
# =============================================================================
sync_files_theme() {
    backup_target
    info_msg "Synchronizing files..."
    mkdir -p "${TARGET_DIR}"

    rsync -av "${SOURCE_DIR}/" "${TARGET_DIR}/" \
        --exclude '.git' \
        --exclude '.gitignore' \
        --exclude '.grepai' \
        --exclude '.idea' \
        --exclude '.claude' \
        --exclude 'CLAUDE.md' \
        --exclude '*.sh' \
        --exclude '*.zip' \
        --exclude 'node_modules' \
        --exclude '.DS_Store' \
        --exclude 'assets/cache/*' \
        --delete

    success_msg "Files synced to ${TARGET_DIR}"
}

delete_files_theme() {
    info_msg "Deleting theme files..."
    if [[ -d "${TARGET_DIR}" ]]; then
        rm -rf "${TARGET_DIR:?}"
        success_msg "Theme folder deleted"
    else
        info_msg "Folder does not exist, nothing to delete"
    fi
}

do_enable_theme() {
    info_msg "Enabling theme..."
    if ${PS_EXEC} ${PS_CONSOLE} prestashop:theme:enable ${NAME} 2>&1 | grep -qi "enabled\|activé\|success"; then
        success_msg "Theme enabled"
    else
        # Check if already active
        local result=$(${PS_EXEC} ${PS_CONSOLE} prestashop:theme:enable ${NAME} 2>&1 || true)
        if echo "$result" | grep -qi "already"; then
            success_msg "Theme already active"
        else
            error_msg "Enable failed"
        fi
    fi
}

# Theme composite actions
action_theme_sync() {
    sync_files_theme || return 1
    clear_cache
}

action_theme_sync_enable() {
    sync_files_theme || return 1
    do_enable_theme || return 1
    clear_cache
}

action_theme_delete() {
    delete_files_theme || return 1
    clear_cache
}

action_theme_delete_reinstall() {
    delete_files_theme || return 1
    sync_files_theme || return 1
    do_enable_theme || return 1
    clear_cache
}

# =============================================================================
# Interactive menu
# =============================================================================

# Check if translation script exists
HAS_TRANSLATION_SCRIPT=false
[[ -f "${SCRIPT_DIR}/generate_translations.php" ]] && HAS_TRANSLATION_SCRIPT=true

if [[ "$TYPE" == "module" ]]; then
    MENU_OPTIONS=(
        "Install / Reinstall"
        "Uninstall"
        "Uninstall then Reinstall"
        "Delete"
        "Delete then Reinstall"
        "Restore a backup"
        "Clear cache"
        "Restart Docker Containers"
        "Build ZIP"
    )
    # Add translation option if script exists
    if [[ "$HAS_TRANSLATION_SCRIPT" == true ]]; then
        MENU_OPTIONS+=("Update translations hash")
    fi
    MENU_OPTIONS+=("Update script" "Quit")
    MENU_QUIT_INDEX=$((${#MENU_OPTIONS[@]} - 1))
else
    MENU_OPTIONS=(
        "Sync files"
        "Sync + Enable theme"
        "Delete theme"
        "Delete + Reinstall"
        "Restore a backup"
        "Clear cache"
        "Restart Docker Containers"
        "Build ZIP"
        "Update script"
        "Quit"
    )
    MENU_QUIT_INDEX=9
fi

print_menu() {
    local selected=$1
    local status_msg=$2

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}${SCRIPT_NAME}${NC} v${YELLOW}${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}║${NC}  ${TYPE_LABEL}: ${BOLD}${NAME}${NC} v${YELLOW}${ITEM_VERSION}${NC}"
    if [[ -n "$status_msg" ]]; then
        echo -e "${CYAN}║${NC}  ${GREEN}✓${NC} ${status_msg}"
    fi
    echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    for i in "${!MENU_OPTIONS[@]}"; do
        if [[ $i -eq $selected ]]; then
            echo -e "  ${GREEN}▸${NC} ${BOLD}${MENU_OPTIONS[$i]}${NC}"
        else
            echo -e "    ${DIM}${MENU_OPTIONS[$i]}${NC}"
        fi
    done

    echo ""
    echo -e "${DIM}  ↑↓ Navigate  ⏎ Select  Esc/q Quit${NC}"
}

execute_menu_action() {
    local selected=$1
    local action_name="${MENU_OPTIONS[$selected]}"

    # Use action name for matching (more robust with dynamic menu)
    case "$action_name" in
        "Install / Reinstall")       action_module_install ;;
        "Uninstall")                 action_module_uninstall ;;
        "Uninstall then Reinstall")  action_module_uninstall_reinstall ;;
        "Delete")                    action_module_delete ;;
        "Delete then Reinstall")     action_module_delete_reinstall ;;
        "Sync files")                action_theme_sync ;;
        "Sync + Enable theme")       action_theme_sync_enable ;;
        "Delete theme")              action_theme_delete ;;
        "Delete + Reinstall")        action_theme_delete_reinstall ;;
        "Restore a backup")          action_restore ;;
        "Clear cache")               action_clear_cache ;;
        "Restart Docker Containers") action_restart_docker ;;
        "Build ZIP")                 action_build_zip ;;
        "Update translations hash")  action_update_translations ;;
        "Update script")             action_update_script ;;
    esac
}

run_menu() {
    local selected=0
    local key
    local last_status=""

    # Hide cursor
    tput civis 2>/dev/null || true

    # Restore cursor on exit
    trap 'tput cnorm 2>/dev/null || true; exit' EXIT INT TERM

    while true; do
        # Clear screen and display menu
        clear
        print_menu $selected "$last_status"

        # Read a key
        IFS= read -rsn1 key

        # Handle escape sequences (arrows or Esc alone)
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn1 -t 0.3 k1
            if [[ -z "$k1" ]]; then
                # Esc alone: quit
                tput cnorm 2>/dev/null || true
                clear
                echo -e "${DIM}Goodbye!${NC}"
                exit 0
            fi
            read -rsn1 -t 0.3 k2
            case "${k1}${k2}" in
                '[A') [[ $selected -gt 0 ]] && selected=$((selected - 1)) || selected=$((${#MENU_OPTIONS[@]} - 1)) ;;
                '[B') [[ $selected -lt $((${#MENU_OPTIONS[@]} - 1)) ]] && selected=$((selected + 1)) || selected=0 ;;
            esac
            continue
        fi

        case "$key" in
            '')  # Enter
                local action_name="${MENU_OPTIONS[$selected]}"
                local result=0

                if [[ $selected -eq $MENU_QUIT_INDEX ]]; then
                    tput cnorm 2>/dev/null || true
                    clear
                    echo -e "${DIM}Goodbye!${NC}"
                    exit 0
                fi

                tput cnorm 2>/dev/null || true
                clear
                echo ""
                echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
                echo -e "${CYAN}║${NC}  ${BOLD}${action_name}${NC}"
                echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
                echo ""

                # Execute action and capture result
                set +e
                execute_menu_action $selected
                result=$?
                set -e

                if [[ $result -eq 0 ]]; then
                    # Success
                    last_status="${action_name} - Done!"
                    sleep 2
                elif [[ $result -eq 2 ]]; then
                    # Cancelled
                    last_status="${action_name} - Cancelled"
                    sleep 2
                else
                    # Error: wait for key press
                    echo ""
                    echo -e "${DIM}Press any key to continue...${NC}"
                    read -rsn1
                    last_status=""
                fi
                tput civis 2>/dev/null || true
                ;;
            'q'|'Q')  # Quit
                tput cnorm 2>/dev/null || true
                clear
                echo -e "${DIM}Goodbye!${NC}"
                exit 0
                ;;
            'k')  # vim: up
                [[ $selected -gt 0 ]] && selected=$((selected - 1)) || selected=$((${#MENU_OPTIONS[@]} - 1))
                ;;
            'j')  # vim: down
                [[ $selected -lt $((${#MENU_OPTIONS[@]} - 1)) ]] && selected=$((selected + 1)) || selected=0
                ;;
            [1-9])  # Direct selection by number
                local num=$((key - 1))
                [[ $num -lt ${#MENU_OPTIONS[@]} ]] && selected=$num || true
                ;;
        esac
    done
}

show_help() {
    echo -e "${CYAN}Usage:${NC} ./install.sh [option]"
    echo ""
    echo -e "Current mode: ${BOLD}${TYPE}${NC}"
    echo ""
    echo -e "Without option: launches interactive menu"
    echo ""
    if [[ "$TYPE" == "module" ]]; then
        echo -e "CLI Options (module):"
        echo -e "  ${GREEN}--install${NC}        Install / Reinstall"
        echo -e "  ${GREEN}--uninstall${NC}      Uninstall"
        echo -e "  ${GREEN}--reinstall${NC}      Uninstall then Reinstall"
        echo -e "  ${GREEN}--delete${NC}         Delete"
        echo -e "  ${GREEN}--reset${NC}          Delete then Reinstall"
        if [[ "$HAS_TRANSLATION_SCRIPT" == true ]]; then
            echo -e "  ${GREEN}--translations${NC}   Update translations hash"
        fi
    else
        echo -e "CLI Options (theme):"
        echo -e "  ${GREEN}--sync${NC}           Sync files"
        echo -e "  ${GREEN}--install${NC}        Sync + Enable theme"
        echo -e "  ${GREEN}--delete${NC}         Delete theme"
        echo -e "  ${GREEN}--reset${NC}          Delete + Reinstall"
    fi
    echo -e "  ${GREEN}--restore${NC}        Restore a backup"
    echo -e "  ${GREEN}--cache${NC}          Clear cache"
    echo -e "  ${GREEN}--restart${NC}        Restart Docker Containers"
    echo -e "  ${GREEN}--zip${NC}            Build zip archive"
    echo -e "  ${GREEN}--update-script${NC}  Update script"
    echo -e "  ${GREEN}--help${NC}           Show this help"
    echo ""
}

# =============================================================================
# Main
# =============================================================================
run_cli_action() {
    local title=$1
    local action=$2
    echo ""
    echo -e "${BOLD}${title}${NC}"
    echo -e "${DIM}─────────────────────────${NC}"
    $action
    echo ""
    success_msg "Done!"
}

cd "${SCRIPT_DIR}"
check_prerequisites

if [[ "$TYPE" == "module" ]]; then
    case "${1:-}" in
        --install)       run_cli_action "Install / Reinstall" action_module_install ;;
        --uninstall)     run_cli_action "Uninstall" action_module_uninstall ;;
        --reinstall)     run_cli_action "Uninstall then Reinstall" action_module_uninstall_reinstall ;;
        --delete)        run_cli_action "Delete" action_module_delete ;;
        --reset)         run_cli_action "Delete then Reinstall" action_module_delete_reinstall ;;
        --restore)       run_cli_action "Restore a backup" action_restore ;;
        --cache)         run_cli_action "Clear cache" action_clear_cache ;;
        --restart)       run_cli_action "Restart Docker Containers" action_restart_docker ;;
        --zip)           run_cli_action "Build ZIP" action_build_zip ;;
        --translations)  run_cli_action "Update translations hash" action_update_translations ;;
        --update-script) run_cli_action "Update script" action_update_script ;;
        --help|-h)       show_help ;;
        "")              run_menu ;;
        *)               error_msg "Unknown option: $1. Use --help for help." ;;
    esac
else
    case "${1:-}" in
        --sync)          run_cli_action "Sync files" action_theme_sync ;;
        --install)       run_cli_action "Sync + Enable theme" action_theme_sync_enable ;;
        --delete)        run_cli_action "Delete theme" action_theme_delete ;;
        --reset)         run_cli_action "Delete + Reinstall" action_theme_delete_reinstall ;;
        --restore)       run_cli_action "Restore a backup" action_restore ;;
        --cache)         run_cli_action "Clear cache" action_clear_cache ;;
        --restart)       run_cli_action "Restart Docker Containers" action_restart_docker ;;
        --zip)           run_cli_action "Build ZIP" action_build_zip ;;
        --update-script) run_cli_action "Update script" action_update_script ;;
        --help|-h)       show_help ;;
        "")              run_menu ;;
        *)               error_msg "Unknown option: $1. Use --help for help." ;;
    esac
fi
