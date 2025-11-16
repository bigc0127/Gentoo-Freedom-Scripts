#!/usr/bin/env bash
set -Eeuo pipefail

# Timekpr-nExT Installation Script for Gentoo Linux
# Repository: https://github.com/polesapart/timekpr-next

APP_ID="timekpr-next"
APP_NAME="Timekpr-nExT"
REPO_URL_DEFAULT="https://github.com/polesapart/timekpr-next.git"
BRANCH_DEFAULT="master"
WORK_BASE="${TMPDIR:-/tmp}/timekpr-next-gentoo-install"
REPO_DIR="$WORK_BASE/src"
LOGFILE="/var/log/${APP_ID}-gentoo-install.log"

AUTO_EMERGE=0
REPO_URL="$REPO_URL_DEFAULT"
BRANCH="$BRANCH_DEFAULT"

usage() {
    cat <<EOF
Usage: $0 [-y] [-b branch] [-r repo_url] [-h]

Options:
  -y, --yes       Install dependencies without prompting (emerge noninteractive)
  -b, --branch    Git branch/tag to clone (default: ${BRANCH_DEFAULT})
                  Use 'v0.5.1' for latest stable release
  -r, --repo      Git repository URL (default: ${REPO_URL_DEFAULT})
  -h, --help      Show this help message

Example:
  $0 -y -b v0.5.1
EOF
}

# Error trap
trap 'echo "ERROR: An error occurred on line $LINENO. See $LOGFILE for details."; exit 1' ERR

# Check root privileges
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# Check for Gentoo system
if ! command -v emerge >/dev/null 2>&1; then
    echo "Gentoo package manager 'emerge' not found. This script is intended for Gentoo."
    exit 1
fi

install_deps() {
    echo "Installing dependencies for Timekpr-nExT..."
    
    local pkgs=(
        dev-vcs/git
        sys-devel/gettext
        x11-misc/xdg-utils
        dev-util/desktop-file-utils
        dev-lang/python:3.11
        dev-python/dbus-python
        dev-python/pygobject:3
        dev-python/psutil
        sys-auth/polkit
        sys-apps/systemd
        x11-libs/gtk+:3
        dev-libs/gobject-introspection
    )
    
    # Try to add AppIndicator support (may not be available in all Gentoo configurations)
    if emerge --pretend --quiet dev-libs/libappindicator:3 >/dev/null 2>&1; then
        pkgs+=(dev-libs/libappindicator:3)
    fi
    if emerge --pretend --quiet dev-libs/libayatana-appindicator >/dev/null 2>&1; then
        pkgs+=(dev-libs/libayatana-appindicator)
    fi
    
    local opts=(--noreplace)
    if [[ "$AUTO_EMERGE" -eq 1 ]]; then
        opts+=(--quiet)
    else
        opts+=(--ask)
    fi
    
    echo "Installing: ${pkgs[*]}"
    emerge "${opts[@]}" "${pkgs[@]}" || {
        echo "WARNING: Some dependencies may be masked or missing; continuing..."
        echo "You may need to manually install missing packages or unmask them."
    }
}

clone_repo() {
    echo "Cloning Timekpr-nExT repository..."
    mkdir -p "$WORK_BASE"
    
    if [[ -d "$REPO_DIR/.git" ]]; then
        echo "Repository already exists, updating..."
        git -C "$REPO_DIR" fetch --all
        git -C "$REPO_DIR" checkout "$BRANCH"
        git -C "$REPO_DIR" reset --hard "origin/${BRANCH}" 2>/dev/null || git -C "$REPO_DIR" reset --hard "$BRANCH"
    else
        git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
    fi
    
    echo "Repository cloned to: $REPO_DIR"
}

install_files() {
    echo "Installing files based on debian/install mapping..."
    local install_file="$REPO_DIR/debian/install"
    
    if [[ ! -f "$install_file" ]]; then
        echo "ERROR: debian/install file not found!"
        exit 1
    fi
    
    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))
        
        # Skip empty lines and comments
        line="${line#"${line%%[![:space:]]*}"}"  # trim leading whitespace
        line="${line%"${line##*[![:space:]]}"}"  # trim trailing whitespace
        [[ -z "$line" ]] && continue
        [[ "${line:0:1}" == "#" ]] && continue
        
        # Parse source and destination
        local src dest
        src=$(echo "$line" | awk '{print $1}')
        dest=$(echo "$line" | awk '{print $2}')
        
        [[ -z "$src" || -z "$dest" ]] && continue
        
        local src_path="$REPO_DIR/$src"
        local dest_path="/$dest"
        
        if [[ ! -e "$src_path" ]]; then
            echo "WARN: Source not found: $src_path (skipping)"
            continue
        fi
        
        mkdir -p "$dest_path"
        
        if [[ -d "$src_path" ]]; then
            echo "  Copying directory: $src -> $dest_path"
            rsync -a "$src_path/" "$dest_path/$(basename "$src")/"
        else
            echo "  Installing: $src -> $dest_path"
            install -m 644 "$src_path" "$dest_path/"
        fi
    done < "$install_file"
}

set_permissions() {
    echo "Setting file permissions..."
    
    # Executables
    if ls /usr/bin/timekpr* >/dev/null 2>&1; then
        chmod 755 /usr/bin/timekpr* || true
        chown root:root /usr/bin/timekpr* || true
    fi
    
    # Python modules
    if [[ -d /usr/lib/python3/dist-packages/timekpr ]]; then
        find /usr/lib/python3/dist-packages/timekpr -type d -exec chmod 755 {} \; 2>/dev/null || true
        find /usr/lib/python3/dist-packages/timekpr -type f -exec chmod 644 {} \; 2>/dev/null || true
        chown -R root:root /usr/lib/python3/dist-packages/timekpr || true
    fi
    
    # Configuration files
    if [[ -d /etc/timekpr ]]; then
        find /etc/timekpr -type d -exec chmod 755 {} \; || true
        find /etc/timekpr -type f -exec chmod 644 {} \; || true
        chown -R root:root /etc/timekpr || true
    fi
    
    # D-Bus config
    if [[ -f /etc/dbus-1/system.d/timekpr.conf ]]; then
        chmod 644 /etc/dbus-1/system.d/timekpr.conf || true
        chown root:root /etc/dbus-1/system.d/timekpr.conf || true
    fi
    
    # PolicyKit action
    if [[ -f /usr/share/polkit-1/actions/com.ubuntu.timekpr.pkexec.policy ]]; then
        chmod 644 /usr/share/polkit-1/actions/com.ubuntu.timekpr.pkexec.policy || true
        chown root:root /usr/share/polkit-1/actions/com.ubuntu.timekpr.pkexec.policy || true
    fi
    
    # Systemd service
    if [[ -f /lib/systemd/system/timekpr.service ]]; then
        chmod 644 /lib/systemd/system/timekpr.service || true
        chown root:root /lib/systemd/system/timekpr.service || true
    fi
    
    # Working directories
    mkdir -p /var/lib/timekpr/config /var/lib/timekpr/work
    chown -R root:root /var/lib/timekpr || true
    chmod -R 755 /var/lib/timekpr || true
}

compile_python_modules() {
    echo "Byte-compiling Python modules..."
    
    if [[ -d /usr/lib/python3/dist-packages/timekpr ]]; then
        local python_exec
        python_exec=$(command -v python3 || command -v python || echo "")
        
        if [[ -n "$python_exec" ]]; then
            "$python_exec" -m compileall -q /usr/lib/python3/dist-packages/timekpr || {
                echo "WARN: Python byte-compilation failed (non-fatal)"
            }
        else
            echo "WARN: No Python interpreter found for byte-compilation"
        fi
    fi
}

refresh_caches() {
    echo "Refreshing system caches..."
    
    # Update desktop database
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database -q /usr/share/applications || true
    fi
    
    # Update icon cache
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -q -f /usr/share/icons/hicolor || true
    fi
    
    # Reload systemd
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload || true
    fi
}

enable_service() {
    echo ""
    echo "Timekpr-nExT service management:"
    
    if command -v systemctl >/dev/null 2>&1; then
        if [[ "$AUTO_EMERGE" -eq 1 ]]; then
            systemctl enable timekpr.service || true
            echo "  Timekpr service enabled (not started)"
        else
            read -p "Do you want to enable and start Timekpr-nExT service? [Y/n]: " choice
            if [[ "$choice" =~ ^[Yy]?$ ]]; then
                systemctl enable timekpr.service || true
                systemctl start timekpr.service || true
                echo "  Timekpr service enabled and started"
            else
                echo "  You can manually enable it later with: systemctl enable timekpr.service"
                echo "  And start it with: systemctl start timekpr.service"
            fi
        fi
    else
        echo "  systemd not detected. Please manually configure Timekpr-nExT to start at boot."
    fi
}

print_summary() {
    echo ""
    echo "============================================================"
    echo "  Timekpr-nExT Installation Summary"
    echo "============================================================"
    echo "Repository: $REPO_URL"
    echo "Branch/Tag: $BRANCH"
    echo ""
    echo "Installed components:"
    echo ""
    
    echo "Executables:"
    ls -1 /usr/bin/timekpr* 2>/dev/null || echo "  None found"
    echo ""
    
    echo "Configuration:"
    echo "  /etc/timekpr/"
    echo "  /etc/dbus-1/system.d/timekpr.conf"
    echo ""
    
    echo "Python modules:"
    echo "  /usr/lib/python3/dist-packages/timekpr/"
    echo ""
    
    echo "Data directories:"
    echo "  /usr/share/timekpr/"
    echo "  /var/lib/timekpr/"
    echo ""
    
    echo "Desktop files:"
    ls -1 /usr/share/applications/timekpr*.desktop 2>/dev/null | sed 's/^/  /' || echo "  None found"
    echo ""
    
    echo "Service:"
    echo "  /lib/systemd/system/timekpr.service"
    echo ""
    
    if systemctl is-enabled timekpr.service >/dev/null 2>&1; then
        echo "Service status: ENABLED"
    else
        echo "Service status: DISABLED"
    fi
    
    if systemctl is-active timekpr.service >/dev/null 2>&1; then
        echo "Service running: YES"
    else
        echo "Service running: NO"
    fi
    
    echo ""
    echo "============================================================"
    echo "  Next Steps"
    echo "============================================================"
    echo ""
    echo "1. Start the service (if not already running):"
    echo "   systemctl start timekpr.service"
    echo ""
    echo "2. Check service status:"
    echo "   systemctl status timekpr.service"
    echo ""
    echo "3. Launch the admin interface:"
    echo "   timekpra"
    echo "   (or find 'Timekpr-nExT' in your applications menu)"
    echo ""
    echo "4. Users will see the client indicator when they log in"
    echo ""
    echo "5. Configure user limits through the admin interface"
    echo ""
    echo "For more information, visit:"
    echo "  https://github.com/polesapart/timekpr-next"
    echo ""
    echo "Log file: $LOGFILE"
    echo "============================================================"
}

main() {
    mkdir -p "$(dirname "$LOGFILE")"
    : > "$LOGFILE"
    exec > >(tee -a "$LOGFILE")
    exec 2>&1
    
    echo "============================================================"
    echo "  Starting $APP_NAME installation on Gentoo"
    echo "============================================================"
    echo ""
    
    install_deps
    clone_repo
    install_files
    set_permissions
    compile_python_modules
    refresh_caches
    enable_service
    print_summary
    
    echo ""
    echo "Installation completed successfully!"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)
            AUTO_EMERGE=1
            shift
            ;;
        -b|--branch)
            BRANCH="$2"
            shift 2
            ;;
        -r|--repo)
            REPO_URL="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

main
