#!/bin/bash
set -e

# =============================================================================
# Script info
# =============================================================================
SCRIPT_NAME="Publiko Module Installer"
SCRIPT_VERSION="1.2.0"

# GitHub repository for auto-update (owner/repo format)
GITHUB_REPO="publiko/PrestashopModuleInstaller"

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
[[ -z "${MODULE_NAME:-}" ]] && echo -e "\033[0;31m✗ Error:\033[0m MODULE_NAME not defined in .env.install" && exit 1
# =============================================================================

SOURCE_DIR="${SCRIPT_DIR}/${MODULE_NAME}"
TARGET_DIR="${PRESTASHOP_PATH}/modules/${MODULE_NAME}"
BACKUP_DIR="${SCRIPT_DIR}/.backups"
MAX_BACKUPS=5
MODULE_VERSION=$(grep "this->version" "${SOURCE_DIR}/${MODULE_NAME}.php" 2>/dev/null | head -1 | grep -oP "'[0-9]+\.[0-9]+\.[0-9]+'" | tr -d "'" || echo "1.0.0")

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
    [[ ! -d "${SOURCE_DIR}" ]] && error_msg "Source folder ${MODULE_NAME}/ not found"
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

    # Fetch latest tag from GitHub API
    LATEST_VERSION=$(curl -s --connect-timeout 5 "https://api.github.com/repos/${GITHUB_REPO}/tags" 2>/dev/null \
        | grep -oP '"name":\s*"\K[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1 || echo "")

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
        echo -e "${CYAN}║${NC}  Module: ${BOLD}${MODULE_NAME}${NC} v${YELLOW}${MODULE_VERSION}${NC}"
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
                '[A') [[ $selected -gt 0 ]] && selected=$((selected - 1)) || true ;;
                '[B') [[ $selected -lt $((${#backups[@]} - 1)) ]] && selected=$((selected + 1)) || true ;;
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
# Basic actions
# =============================================================================
sync_files() {
    backup_target
    info_msg "Synchronizing files..."
    mkdir -p "${TARGET_DIR}"
    cp -r "${SOURCE_DIR}/"* "${TARGET_DIR}/"
    success_msg "Files copied to ${TARGET_DIR}"
}

delete_files() {
    info_msg "Deleting module files..."
    if [[ -d "${TARGET_DIR}" ]]; then
        rm -rf "${TARGET_DIR:?}/"*
        success_msg "Files deleted"
    else
        info_msg "Folder does not exist, nothing to delete"
    fi
}

PS_EXEC="docker exec -e SERVER_PORT=80 -e HTTP_HOST=localhost ${DOCKER_CONTAINER}"
PS_CONSOLE="php -d memory_limit=1G /var/www/html/bin/console"

clear_cache() {
    info_msg "Clearing cache..."
    docker exec ${DOCKER_CONTAINER} sh -c "rm -rf /var/www/html/var/cache/* && mkdir -p /var/www/html/var/cache/dev && chown -R www-data:www-data /var/www/html/var/cache && chmod -R 775 /var/www/html/var/cache" 2>/dev/null || true
    success_msg "Cache cleared"
}

do_install() {
    info_msg "Installing module..."
    if ${PS_EXEC} ${PS_CONSOLE} prestashop:module install ${MODULE_NAME} 2>&1 | grep -q "réussi\|successful"; then
        success_msg "Module installed"
    else
        error_msg "Installation failed"
    fi
}

do_uninstall() {
    info_msg "Uninstalling module..."
    ${PS_EXEC} ${PS_CONSOLE} prestashop:module uninstall ${MODULE_NAME} 2>&1 | grep -q "réussi\|successful" || true
    success_msg "Module uninstalled"
}

# =============================================================================
# Composite actions
# =============================================================================
action_install_reinstall() {
    sync_files
    do_install
    clear_cache
}

action_uninstall() {
    do_uninstall
    clear_cache
}

action_uninstall_reinstall() {
    do_uninstall
    sync_files
    do_install
    clear_cache
}

action_delete() {
    do_uninstall
    delete_files
    clear_cache
}

action_delete_reinstall() {
    do_uninstall
    delete_files
    sync_files
    do_install
    clear_cache
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

action_build_zip() {
    local zip_name="${MODULE_NAME}_v${MODULE_VERSION}.zip"
    local temp_dir=$(mktemp -d)

    rm -f "${SCRIPT_DIR}/${zip_name}"

    info_msg "Copying files..."
    cp -r "${SOURCE_DIR}" "${temp_dir}/${MODULE_NAME}"

    info_msg "Cleaning up..."
    find "${temp_dir}/${MODULE_NAME}" -name ".git*" -exec rm -rf {} + 2>/dev/null || true
    find "${temp_dir}/${MODULE_NAME}" -name ".claude*" -exec rm -rf {} + 2>/dev/null || true
    find "${temp_dir}/${MODULE_NAME}" -name ".grepai*" -exec rm -rf {} + 2>/dev/null || true
    find "${temp_dir}/${MODULE_NAME}" -name "CLAUDE.md" -exec rm -f {} + 2>/dev/null || true
    find "${temp_dir}/${MODULE_NAME}" -name "TODO.md" -exec rm -f {} + 2>/dev/null || true
    find "${temp_dir}/${MODULE_NAME}" -name "*.zip" -exec rm -f {} + 2>/dev/null || true
    find "${temp_dir}/${MODULE_NAME}" -name ".DS_Store" -exec rm -f {} + 2>/dev/null || true
    find "${temp_dir}/${MODULE_NAME}" -name "*.swp" -exec rm -f {} + 2>/dev/null || true
    find "${temp_dir}/${MODULE_NAME}" -name "*~" -exec rm -f {} + 2>/dev/null || true
    rm -rf "${temp_dir}/${MODULE_NAME}/vendor" 2>/dev/null || true
    rm -rf "${temp_dir}/${MODULE_NAME}/node_modules" 2>/dev/null || true

    info_msg "Creating archive..."
    cd "${temp_dir}"
    zip -rq "${SCRIPT_DIR}/${zip_name}" "${MODULE_NAME}"
    cd "${SCRIPT_DIR}"

    rm -rf "${temp_dir}"

    local zip_size=$(du -h "${SCRIPT_DIR}/${zip_name}" | cut -f1)
    success_msg "Archive created: ${zip_name} (${zip_size})"
}

# =============================================================================
# Interactive menu
# =============================================================================
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
    "Update script"
    "Quit"
)

print_menu() {
    local selected=$1
    local status_msg=$2

    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}${SCRIPT_NAME}${NC} v${YELLOW}${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}║${NC}  Module: ${BOLD}${MODULE_NAME}${NC} v${YELLOW}${MODULE_VERSION}${NC}"
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
                '[A') [[ $selected -gt 0 ]] && selected=$((selected - 1)) || true ;;
                '[B') [[ $selected -lt $((${#MENU_OPTIONS[@]} - 1)) ]] && selected=$((selected + 1)) || true ;;
            esac
            continue
        fi

        case "$key" in
            '')  # Enter
                local action_name="${MENU_OPTIONS[$selected]}"
                local result=0

                case $selected in
                    10) tput cnorm 2>/dev/null || true; clear; echo -e "${DIM}Goodbye!${NC}"; exit 0 ;;
                    *)
                        tput cnorm 2>/dev/null || true
                        clear
                        echo ""
                        echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
                        echo -e "${CYAN}║${NC}  ${BOLD}${action_name}${NC}"
                        echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
                        echo ""

                        # Execute action and capture result
                        set +e
                        case $selected in
                            0) action_install_reinstall ;;
                            1) action_uninstall ;;
                            2) action_uninstall_reinstall ;;
                            3) action_delete ;;
                            4) action_delete_reinstall ;;
                            5) action_restore ;;
                            6) action_clear_cache ;;
                            7) action_restart_docker ;;
                            8) action_build_zip ;;
                            9) action_update_script ;;
                        esac
                        result=$?
                        set -e

                        if [[ $result -eq 0 ]]; then
                            # Success
                            last_status="${action_name} - Done!"
                        elif [[ $result -eq 2 ]]; then
                            # Cancelled
                            last_status="${action_name} - Cancelled"
                        else
                            # Error: wait for key press
                            echo ""
                            echo -e "${DIM}Press any key to continue...${NC}"
                            read -rsn1
                            last_status=""
                        fi
                        tput civis 2>/dev/null || true
                        ;;
                esac
                ;;
            'q'|'Q')  # Quit
                tput cnorm 2>/dev/null || true
                clear
                echo -e "${DIM}Goodbye!${NC}"
                exit 0
                ;;
            'k')  # vim: up
                [[ $selected -gt 0 ]] && selected=$((selected - 1)) || true
                ;;
            'j')  # vim: down
                [[ $selected -lt $((${#MENU_OPTIONS[@]} - 1)) ]] && selected=$((selected + 1)) || true
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
    echo -e "Without option: launches interactive menu"
    echo ""
    echo -e "CLI Options:"
    echo -e "  ${GREEN}--install${NC}      Install / Reinstall"
    echo -e "  ${GREEN}--uninstall${NC}    Uninstall"
    echo -e "  ${GREEN}--reinstall${NC}    Uninstall then Reinstall"
    echo -e "  ${GREEN}--delete${NC}       Delete"
    echo -e "  ${GREEN}--reset${NC}        Delete then Reinstall"
    echo -e "  ${GREEN}--restore${NC}      Restore a backup"
    echo -e "  ${GREEN}--cache${NC}        Clear cache"
    echo -e "  ${GREEN}--restart${NC}      Restart Docker Containers"
    echo -e "  ${GREEN}--zip${NC}          Build zip archive"
    echo -e "  ${GREEN}--update-script${NC}  Update script"
    echo -e "  ${GREEN}--help${NC}         Show this help"
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

case "${1:-}" in
    --install)     run_cli_action "Install / Reinstall" action_install_reinstall ;;
    --uninstall)   run_cli_action "Uninstall" action_uninstall ;;
    --reinstall)   run_cli_action "Uninstall then Reinstall" action_uninstall_reinstall ;;
    --delete)      run_cli_action "Delete" action_delete ;;
    --reset)       run_cli_action "Delete then Reinstall" action_delete_reinstall ;;
    --restore)     run_cli_action "Restore a backup" action_restore ;;
    --cache)       run_cli_action "Clear cache" action_clear_cache ;;
    --restart)     run_cli_action "Restart Docker Containers" action_restart_docker ;;
    --zip)         run_cli_action "Build ZIP" action_build_zip ;;
    --update-script) run_cli_action "Update script" action_update_script ;;
    --help|-h)     show_help ;;
    "")            run_menu ;;
    *)             error_msg "Unknown option: $1. Use --help for help." ;;
esac
