#!/usr/bin/env bash
set -Eeuo pipefail

# Gentoo Desktop Setup Script (OpenRC)
# Version: 2.0 - Unattended installation mode (2025-01-13)
LOG="/var/log/setup-desktop.log"
mkdir -p "$(dirname "$LOG")"
touch "$LOG"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "[ERROR] Command failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# Global variable to track which display server was selected
DISPLAY_SERVER_CHOICE=""

info() { echo "==> $*"; }
warn() { echo "!!  $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "This script must be run as root."
  fi
}

require_openrc() {
  if ! have_cmd rc-update; then
    die "OpenRC not detected (rc-update not found). This script targets OpenRC."
  fi
}

ask_yn() {
  local prompt="$1"; local def="${2:-y}"; local ans
  if [ -n "${YES_TO_ALL:-}" ]; then echo y; return; fi
  while true; do
    read -r -p "$prompt [y/n] (default: $def): " ans
    ans="${ans:-$def}"
    case "${ans,,}" in
      y|yes) echo y; return;;
      n|no)  echo n; return;;
      *) echo "Please answer y or n.";;
    esac
  done
}

ask_choice() {
  local prompt="$1"; local def="$2"; shift 2
  local options=("$@"); local ans
  if [ -n "${YES_TO_ALL:-}" ]; then echo "$def"; return; fi
  local joined; joined=$(IFS=/; echo "${options[*]}")
  while true; do
    read -r -p "$prompt [$joined] (default: $def): " ans
    ans="${ans:-$def}"
    for o in "${options[@]}"; do
      if [ "${ans,,}" = "${o,,}" ]; then echo "$o"; return; fi
    done
    echo "Invalid choice: $ans"
  done
}

ask_text() {
  local prompt="$1"; local def="${2:-}"; local ans
  while true; do
    if [ -n "$def" ]; then
      read -r -p "$prompt (default: $def): " ans
      ans="${ans:-$def}"
    else
      read -r -p "$prompt: " ans
    fi
    [ -n "$ans" ] && { echo "$ans"; return; }
  done
}

emerge_install() {
  local pkgs=("$@")
  [ "${#pkgs[@]}" -eq 0 ] && return 0
  info "Installing with emerge: ${pkgs[*]}"
  
  local attempt=1
  local max_attempts=3
  
  while [ $attempt -le $max_attempts ]; do
    info "Installation attempt $attempt/$max_attempts"
    
    local emerge_cmd="emerge --quiet-build=y --ask=n --noreplace"
    
    if [ $attempt -gt 1 ]; then
      emerge_cmd="$emerge_cmd --autounmask=y --autounmask-write --autounmask-continue"
    fi
    
    if $emerge_cmd "${pkgs[@]}" 2>&1 | tee -a "$LOG"; then
      info "Installation successful"
      return 0
    fi
    
    warn "Installation attempt $attempt failed"
    
    if [ $attempt -lt $max_attempts ]; then
      info "Attempting to apply configuration changes..."
      
      yes | etc-update --automode -5 2>/dev/null || true
      
      if grep -q "exactly-one-of.*elogind.*systemd" "$LOG" 2>/dev/null; then
        warn "Detected elogind/systemd REQUIRED_USE conflict. Enabling elogind globally for OpenRC."
        mkdir -p /etc/portage/package.use
        if ! grep -q "# Enable elogind for OpenRC" /etc/portage/package.use/elogind 2>/dev/null; then
          echo "# Enable elogind for OpenRC (added by setup script)" >> /etc/portage/package.use/elogind
          echo "*/* elogind" >> /etc/portage/package.use/elogind
        fi
      fi
      
      # Only enable wayland+opengl if NOT using XLibre
      if grep -q "wayland? ( opengl )" "$LOG" 2>/dev/null && [ "${DISPLAY_SERVER_CHOICE,,}" != "xlibre" ]; then
        warn "Detected wayland/opengl REQUIRED_USE conflict. Enabling opengl for packages that use wayland."
        mkdir -p /etc/portage/package.use
        if ! grep -q "# Wayland requires OpenGL" /etc/portage/package.use/wayland-opengl 2>/dev/null; then
          echo "# Wayland requires OpenGL (added by setup script)" >> /etc/portage/package.use/wayland-opengl
          echo "*/*::gentoo wayland opengl" >> /etc/portage/package.use/wayland-opengl
        fi
      fi
      
      attempt=$((attempt + 1))
    else
      die "Installation failed after $max_attempts attempts. Check $LOG for details."
    fi
  done
}

enable_service() {
  local svc="$1"
  if rc-update show | grep -Eq "^[[:space:]]*${svc}[[:space:]].*default"; then
    info "Service ${svc} already enabled in default runlevel."
  else
    info "Enabling ${svc} to start on boot."
    rc-update add "$svc" default || warn "Failed to enable ${svc}."
  fi
}

start_service() {
  local svc="$1"
  if rc-service "$svc" status >/dev/null 2>&1; then
    info "Service ${svc} status OK."
  else
    info "Starting ${svc}."
    rc-service "$svc" start || warn "Failed to start ${svc}."
  fi
}

setup_xlibre_overlay() {
  info "Setting up the X11Libre overlay (https://github.com/X11Libre/ports-gentoo)"
  emerge_install dev-vcs/git app-eselect/eselect-repository
  
  if eselect repository list -i | awk '{print $1}' | grep -qx xlibre; then
    info "xlibre overlay already configured."
    return 0
  fi
  
  if ! eselect repository list -i | awk '{print $1}' | grep -qx x11libre; then
    info "Adding xlibre overlay via eselect repository."
    if ! eselect repository add x11libre git https://github.com/X11Libre/ports-gentoo.git; then
      warn "eselect add failed; attempting manual overlay configuration."
      mkdir -p /var/db/repos/xlibre
      if [ -d /var/db/repos/xlibre/.git ]; then
        (cd /var/db/repos/xlibre && git pull --ff-only) || warn "Overlay git pull failed."
      else
        git clone https://github.com/X11Libre/ports-gentoo.git /var/db/repos/xlibre || warn "Overlay git clone failed."
      fi
      mkdir -p /etc/portage/repos.conf
      printf "%s\n" "[xlibre]" "location = /var/db/repos/xlibre" "sync-type = git" "sync-uri = https://github.com/X11Libre/ports-gentoo.git" "priority = 50" "auto-sync = yes" > /etc/portage/repos.conf/xlibre.conf
    fi
  fi
  
  info "Syncing xlibre overlay..."
  emaint sync -r xlibre || emaint sync -r x11libre || warn "emaint sync failed; continuing."
}

configure_xlibre_use_flags() {
  info "Configuring USE flags for XLibre (disabling Wayland, enabling X11)"
  mkdir -p /etc/portage/package.use
  
  # Remove conflicting wayland-opengl file if it exists
  if [ -f /etc/portage/package.use/wayland-opengl ]; then
    info "Removing conflicting wayland-opengl configuration"
    rm -f /etc/portage/package.use/wayland-opengl
  fi
  
  # Remove conflicting -opengl entries from zz-autounmask that break wayland requirement
  if [ -f /etc/portage/package.use/zz-autounmask ]; then
    info "Fixing conflicting qtbase -opengl entries in zz-autounmask"
    # Remove lines that disable opengl for qtbase
    sed -i '/qtbase.*-opengl/d' /etc/portage/package.use/zz-autounmask
  fi
  
  # Use zzz- prefix to ensure this file is processed AFTER zz-autounmask
  # This allows us to override any auto-generated wayland requirements
  cat > /etc/portage/package.use/zzz-xlibre << 'EOF'
# XLibre: Disable Wayland support globally, use X11 only (added by setup script)
# This file uses zzz- prefix to override zz-autounmask settings
*/*::gentoo -wayland X opengl

# Qt packages: explicitly disable wayland, enable X11 and OpenGL
# Using package-specific rules (not version-specific) to cover all versions including 9999
dev-qt/qtbase -wayland X opengl
dev-qt/qtwayland -wayland

# KDE Plasma and Frameworks: disable wayland
kde-plasma/* -wayland
kde-frameworks/* -wayland

# OpenCV: enable qt6 to satisfy opengl requirement (needs gtk3, qt6, or wayland)
media-libs/opencv qt6
EOF
  info "Created/updated /etc/portage/package.use/zzz-xlibre with XLibre-specific USE flags"
}

configure_doas() {
  emerge_install app-admin/doas
  local conf="/etc/doas.conf"
  if [ -f "$conf" ]; then
    if grep -Eq '^\s*permit\s+persist\s+(:wheel|:wheel\b)' "$conf"; then
      info "doas.conf already permits wheel with persist."
    else
      warn "Updating $conf to permit wheel with persist; backup at ${conf}.bak"
      cp -a "$conf" "${conf}.bak"
      printf "%s\n" "permit persist :wheel" >> "$conf"
    fi
  else
    printf "%s\n" "permit persist :wheel" > "$conf"
    chmod 440 "$conf"
  fi
  info "doas configured for wheel group."
}

configure_sudo() {
  emerge_install app-admin/sudo
  mkdir -p /etc/sudoers.d
  local f="/etc/sudoers.d/10-wheel"
  if [ -f "$f" ] && grep -Eq '^\s*%wheel\s+ALL=\(ALL(:ALL)?\)\s+ALL\b' "$f"; then
    info "Sudo already allows wheel group."
  else
    printf "%s\n" "%wheel ALL=(ALL:ALL) ALL" > "$f"
    chmod 440 "$f"
  fi
  if have_cmd visudo; then
    visudo -c || warn "visudo syntax check reported issues."
  fi
  info "sudo configured for wheel group."
}

configure_flatpak() {
  local scope="${1:-system}"
  emerge_install sys-apps/flatpak sys-apps/dbus
  enable_service dbus
  start_service dbus

  local args="--if-not-exists"
  if [ "$scope" = "system" ]; then
    args="$args --system"
  else
    args="$args --user"
  fi

  if flatpak remotes $([ "$scope" = "system" ] && echo "--system" || echo "--user") | awk '{print $1}' | grep -qx flathub; then
    info "Flathub remote already configured ($scope)."
  else
    info "Adding Flathub remote ($scope)."
    flatpak remote-add $args flathub https://dl.flathub.org/repo/flathub.flatpakrepo || warn "Failed to add Flathub; ensure network is available."
  fi
}

install_desktop_env() {
  local de="$1"
  local profile="$2"
  case "${de,,}" in
    cli)
      info "CLI selected; skipping desktop environment installation."
      ;;
    kde)
      if [ "${profile,,}" = "full" ]; then
        emerge_install kde-plasma/kde-meta
      else
        emerge_install kde-plasma/plasma-meta
      fi
      ;;
    gnome)
      if [ "${profile,,}" = "full" ]; then
        emerge_install gnome-base/gnome
      else
        emerge_install gnome-base/gnome-light
      fi
      ;;
    mate)
      emerge_install mate-base/mate
      ;;
    lxde)
      emerge_install lxde-base/lxde-meta
      ;;
    *)
      warn "Unknown DE: $de"
      ;;
  esac
}

install_display_server() {
  local ds="$1"
  DISPLAY_SERVER_CHOICE="$ds"
  case "${ds,,}" in
    xorg)
      emerge_install x11-base/xorg-server
      ;;
    wayland)
      emerge_install dev-libs/wayland
      ;;
    xlibre)
      setup_xlibre_overlay
      configure_xlibre_use_flags
      emerge_install x11-base/xlibre-server
      ;;
    *)
      warn "Unknown display server: $ds"
      ;;
  esac
}

install_display_manager() {
  local dm="$1"
  local de="$2"
  local autostart="$3"

  case "${dm,,}" in
    sddm)
      emerge_install x11-misc/sddm
      # Create SDDM init script if it does not exist
      if [ ! -f /etc/init.d/sddm ]; then
        info "Creating SDDM OpenRC init script..."
        cat > /etc/init.d/sddm << 'EOFSCRIPT'
#!/sbin/openrc-run
# Copyright 1999-2023 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

description="Simple Desktop Display Manager"

command="/usr/bin/sddm"
command_background="yes"
pidfile="/run/sddm.pid"

depend() {
    need localmount xdm
    use logger
    after bootmisc
}

start_pre() {
    # Ensure /run/sddm exists
    checkpath -d /run/sddm
}
EOFSCRIPT
        chmod +x /etc/init.d/sddm || warn "Failed to make SDDM init script executable."
      fi
      # Enable xdm service and configure it to use sddm (skip if using XLibre)
      if [ "${DISPLAY_SERVER_CHOICE,,}" != "xlibre" ]; then
        enable_service xdm
        mkdir -p /etc/conf.d
        echo 'DISPLAYMANAGER="sddm"' > /etc/conf.d/xdm
      else
        info "Skipping xdm configuration (XLibre display server selected)."
      fi
      if [ "${autostart,,}" = "y" ]; then
        enable_service sddm
      fi
      ;;
    gdm)
      emerge_install gnome-base/gdm
      # Enable xdm service and configure it to use gdm (skip if using XLibre)
      if [ "${DISPLAY_SERVER_CHOICE,,}" != "xlibre" ]; then
        enable_service xdm
        mkdir -p /etc/conf.d
        echo 'DISPLAYMANAGER="gdm"' > /etc/conf.d/xdm
      else
        info "Skipping xdm configuration (XLibre display server selected)."
      fi
      if [ "${autostart,,}" = "y" ]; then
        enable_service gdm
      fi
      ;;
    lightdm)
      emerge_install x11-misc/lightdm x11-misc/lightdm-gtk-greeter
      mkdir -p /etc/lightdm/lightdm.conf.d
      printf "%s\n" "[Seat:*]" "greeter-session=lightdm-gtk-greeter" > /etc/lightdm/lightdm.conf.d/50-greeter.conf
      # Enable xdm service and configure it to use lightdm (skip if using XLibre)
      if [ "${DISPLAY_SERVER_CHOICE,,}" != "xlibre" ]; then
        enable_service xdm
        mkdir -p /etc/conf.d
        echo 'DISPLAYMANAGER="lightdm"' > /etc/conf.d/xdm
      else
        info "Skipping xdm configuration (XLibre display server selected)."
      fi
      if [ "${autostart,,}" = "y" ]; then
        enable_service lightdm
      fi
      ;;
    *)
      warn "Unknown display manager: $dm"
      ;;
  esac
}

main() {
  require_root
  require_openrc

  info "Gentoo Desktop Setup (OpenRC). Log: $LOG"
  echo
  info "=== CONFIGURATION WIZARD ==="
  info "Please answer all questions upfront. The installation will then run unattended."
  echo

  local default_priv_escalation="doas"
  local default_install_flatpak="yes"
  local default_flatpak_scope="system"
  local default_gui_autostart="y"
  local default_kde_profile="minimal"
  local default_gnome_profile="minimal"

  # ==============================================================================
  # COLLECT ALL USER INPUTS UPFRONT
  # ==============================================================================

  # User management
  local user_action
  user_action=$(ask_choice "User management" "create" create update skip)
  local newuser=""
  local newuser_password=""
  
  case "${user_action,,}" in
    create)
      while true; do
        newuser=$(ask_text "Enter new username")
        if id -u "$newuser" >/dev/null 2>&1; then
          warn "User $newuser already exists. Choose 'update' to modify groups instead."
        else
          info "User $newuser will be created."
          info "Set password for $newuser (you'll be prompted now)"
          read -s -p "Password: " newuser_password
          echo
          read -s -p "Confirm password: " newuser_password_confirm
          echo
          if [ "$newuser_password" != "$newuser_password_confirm" ]; then
            warn "Passwords do not match. Try again."
          else
            break
          fi
        fi
      done
      ;;
    update)
      newuser=$(ask_text "Enter existing username to update groups")
      if ! id -u "$newuser" >/dev/null 2>&1; then
        warn "User $newuser does not exist. Will skip user management."
        user_action="skip"
        newuser=""
      fi
      ;;
    skip)
      ;;
  esac

  # Privilege escalation
  local pe_choice
  pe_choice=$(ask_choice "Install privilege escalation tool" "$default_priv_escalation" doas sudo skip)

  # Flatpak
  local install_flatpak
  install_flatpak=$(ask_choice "Install Flatpak?" "$default_install_flatpak" yes no skip)
  local flatpak_scope=""
  if [ "${install_flatpak,,}" = "yes" ]; then
    flatpak_scope=$(ask_choice "Flatpak scope" "$default_flatpak_scope" system user)
  fi

  # Display server
  local ds_choice
  ds_choice=$(ask_choice "Select display server" "Xorg" Xorg Wayland Xlibre skip)

  # Desktop environment
  local de_choice
  de_choice=$(ask_choice "Select desktop environment" "CLI" CLI KDE Gnome MATE LXDE skip)
  local de_profile=""
  case "${de_choice,,}" in
    kde)
      de_profile=$(ask_choice "KDE profile" "$default_kde_profile" minimal full)
      ;;
    gnome)
      de_profile=$(ask_choice "Gnome profile" "$default_gnome_profile" minimal full)
      ;;
  esac

  # Display manager
  local dm_choice
  dm_choice=$(ask_choice "Select display manager" "SDDM" SDDM GDM LightDM None skip)
  local autostart_gui="n"
  if [ "${dm_choice,,}" != "skip" ] && [ "${dm_choice,,}" != "none" ]; then
    autostart_gui=$(ask_yn "Start GUI on boot?" "$default_gui_autostart")
  fi

  # ==============================================================================
  # SHOW SUMMARY AND CONFIRM
  # ==============================================================================

  echo
  info "=== CONFIGURATION SUMMARY ==="
  echo "  User management:     $user_action $([ -n "$newuser" ] && echo "($newuser)" || echo "")"
  echo "  Priv escalation:     $pe_choice"
  echo "  Flatpak:             $install_flatpak $([ "${install_flatpak,,}" = "yes" ] && echo "($flatpak_scope)" || echo "")"
  echo "  Display server:      $ds_choice"
  echo "  Desktop environment: $de_choice $([ -n "$de_profile" ] && echo "($de_profile)" || echo "")"
  echo "  Display manager:     $dm_choice $([ "$autostart_gui" = "y" ] && echo "(autostart: yes)" || echo "")"
  echo
  
  local confirm
  confirm=$(ask_yn "Proceed with installation?" "y")
  if [ "${confirm,,}" != "y" ]; then
    info "Installation cancelled by user."
    exit 0
  fi

  # ==============================================================================
  # EXECUTE INSTALLATION (UNATTENDED)
  # ==============================================================================

  echo
  info "=== STARTING INSTALLATION ==="
  info "The system will now install selected components. This may take a long time."
  info "You can safely walk away. Progress is logged to: $LOG"
  echo

  # User management
  case "${user_action,,}" in
    create)
      info "Creating user $newuser"
      useradd -m -G wheel,audio,video,usb,portage -s /bin/bash "$newuser"
      echo "$newuser:$newuser_password" | chpasswd
      info "User $newuser created successfully"
      ;;
    update)
      if [ -n "$newuser" ]; then
        info "Updating group membership for $newuser"
        usermod -aG wheel,audio,video,usb,portage "$newuser" || warn "Failed to adjust groups for $newuser"
      fi
      ;;
    skip)
      info "Skipping user management."
      ;;
  esac

  # Privilege escalation
  case "${pe_choice,,}" in
    doas)
      info "Configuring doas..."
      configure_doas
      ;;
    sudo)
      info "Configuring sudo..."
      configure_sudo
      ;;
    skip)
      info "Skipping privilege escalation setup."
      ;;
  esac

  # Flatpak
  if [ "${install_flatpak,,}" = "yes" ]; then
    info "Installing Flatpak (scope: $flatpak_scope)..."
    configure_flatpak "$flatpak_scope"
  else
    info "Skipping Flatpak."
  fi

  # Display server
  if [ "${ds_choice,,}" != "skip" ]; then
    info "Installing display server: $ds_choice..."
    install_display_server "$ds_choice"
  else
    info "Skipping display server installation."
  fi

  # Desktop environment
  case "${de_choice,,}" in
    kde)
      info "Installing KDE ($de_profile profile)..."
      install_desktop_env "KDE" "$de_profile"
      ;;
    gnome)
      info "Installing Gnome ($de_profile profile)..."
      install_desktop_env "Gnome" "$de_profile"
      ;;
    mate)
      info "Installing MATE..."
      install_desktop_env "MATE" ""
      ;;
    lxde)
      info "Installing LXDE..."
      install_desktop_env "LXDE" ""
      ;;
    cli)
      info "CLI-only setup selected."
      install_desktop_env "CLI" ""
      ;;
    skip)
      info "Skipping desktop environment installation."
      ;;
  esac

  # Display manager
  if [ "${dm_choice,,}" != "skip" ]; then
    info "Installing display manager: $dm_choice..."
    install_display_manager "$dm_choice" "$de_choice" "$autostart_gui"
  else
    info "Skipping display manager installation."
  fi

  echo
  echo "Setup complete."
  echo "Summary:"
  echo "  User management:     $user_action $([ -n "$newuser" ] && echo "($newuser)" || echo "")"
  echo "  Priv escalation:     $pe_choice"
  echo "  Flatpak installed:   $install_flatpak $([ "${install_flatpak,,}" = "yes" ] && echo "($flatpak_scope)" || echo "")"
  echo "  Display server:      $ds_choice"
  echo "  Desktop environment: $de_choice $([ -n "$de_profile" ] && echo "($de_profile)" || echo "")"
  echo "  Display manager:     $dm_choice $([ "$autostart_gui" = "y" ] && echo "(autostart: yes)" || echo "")"
  echo
  echo "Notes:"
  echo "  - If you chose 'None' as display manager and installed Xorg/Xlibre, you can use 'startx'."
  echo "  - For startx, ensure ~/.xinitrc runs your session, e.g.:"
  echo "        echo exec startplasma-x11 > ~/.xinitrc      (KDE on X11)"
  echo "        echo exec gnome-session > ~/.xinitrc        (Gnome on X11)"
  echo "        echo exec mate-session > ~/.xinitrc         (MATE on X11)"
  echo "        echo exec startlxde > ~/.xinitrc            (LXDE on X11)"
  echo "  - On OpenRC, services can be managed with rc-update and rc-service."
  echo "  - Ensure VIDEO_CARDS and INPUT_DEVICES are set in /etc/portage/make.conf, then update drivers if needed."
  if [ "${ds_choice,,}" = "xlibre" ]; then
    echo "  - XLibre selected: Wayland has been disabled globally, X11 and OpenGL enabled for all packages."
    echo "  - Qt and KDE will use X11 (XLibre) as the display backend."
  fi
  echo
  echo "Log saved to: $LOG"
}

main "$@"
