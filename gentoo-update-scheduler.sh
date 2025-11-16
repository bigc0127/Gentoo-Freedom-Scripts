#!/usr/bin/env bash
set -Eeuo pipefail

# gentoo-update-scheduler.sh
# Purpose: Interactively schedule unattended Gentoo system updates via root's crontab.

UPDATE_SCRIPT="/usr/local/bin/gentoo-system-update.sh"
LOG_FILE="/var/log/gentoo-updates.log"

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      echo "[i] This script requires root privileges. Re-running via sudo..."
      exec sudo -E bash "$0" "$@"
    else
      echo "[!] Please run this script as root (e.g., sudo bash $0)"
      exit 1
    fi
  fi
}

write_update_script() {
  echo "[i] Creating or updating ${UPDATE_SCRIPT} ..."
  mkdir -p "$(dirname "$UPDATE_SCRIPT")"
  cat > "$UPDATE_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# gentoo-system-update.sh
# Full unattended Gentoo system update with logging and notifications.
set -Eeuo pipefail
umask 022

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LOG_FILE="/var/log/gentoo-updates.log"

# Ensure log file exists and is writable by root
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0644 "$LOG_FILE" || true

notify() {
  local msg="$1"
  # Try desktop notification if available
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "Gentoo Update" "$msg" || true
  fi
  # Fallback to wall for terminals
  if command -v wall >/dev/null 2>&1; then
    echo "Gentoo Update: $msg" | wall || true
  fi
  # Also log to syslog if logger exists
  if command -v logger >/dev/null 2>&1; then
    logger -t gentoo-system-update "$msg" || true
  fi
}

# Prefix each log line with a timestamp
log_prefix() { awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0; fflush(); }'; }

# Run a command, stream output to both console and log with timestamps, and return its status
run_cmd() {
  "$@" 2>&1 | log_prefix | tee -a "$LOG_FILE"
  return ${PIPESTATUS[0]}
}

notify "Starting full system update (emerge --sync && emerge -uDN @world)"
echo "==== Starting at $(date -u +'%Y-%m-%d %H:%M:%S UTC') ====" | log_prefix | tee -a "$LOG_FILE"

if ! run_cmd emerge --sync; then
  notify "Update failed during 'emerge --sync'. See $LOG_FILE"
  exit 1
fi

if ! run_cmd emerge -uDN @world; then
  notify "Update failed during 'emerge -uDN @world'. See $LOG_FILE"
  exit 1
fi

echo "==== Completed at $(date -u +'%Y-%m-%d %H:%M:%S UTC') ====" | log_prefix | tee -a "$LOG_FILE"
notify "System update completed successfully"
EOF
  chmod 0755 "$UPDATE_SCRIPT"
  chown root:root "$UPDATE_SCRIPT" || true
  echo "[✓] Update script installed at $UPDATE_SCRIPT"
}

add_cron_job() {
  local schedule="$1"
  local job_line="$schedule $UPDATE_SCRIPT"

  echo "[i] Adding cron job to root's crontab: $job_line"

  local tmp
  tmp="$(mktemp)"
  # Preserve existing crontab, but remove any lines that reference this update script to avoid duplicates
  crontab -l 2>/dev/null | grep -vF "$UPDATE_SCRIPT" > "$tmp" || true

  # Append our desired job if not present exactly
  if ! grep -Fxq "$job_line" "$tmp"; then
    echo "$job_line" >> "$tmp"
  fi

  crontab "$tmp"
  rm -f "$tmp"
  echo "[✓] Cron job installed for root"
}

main() {
  require_root "$@"

  echo "==============================================="
  echo " Gentoo System Update Scheduler (runs as root) "
  echo "==============================================="
  echo "This will schedule unattended full system updates"
  echo "at 02:00 on the 28th with the frequency you choose."
  echo
  echo "Choose update frequency:"
  echo "  1) Monthly (on the 28th)"
  echo "  2) Every 3 months (quarterly on the 28th)"
  echo "  3) Every 6 months (bi-annually on the 28th)"
  echo "  4) Every 12 months (annually on the 28th)"
  echo

  read -r -p "Enter choice [1-4]: " choice

  case "$choice" in
    1) CRON_SCHED="0 2 28 * *" ;;
    2) CRON_SCHED="0 2 28 */3 *" ;;
    3) CRON_SCHED="0 2 28 */6 *" ;;
    4) CRON_SCHED="0 2 28 */12 *" ;;
    *)
      echo "[!] Invalid selection. Please run again and choose 1-4."
      exit 1
      ;;
  esac

  # Ensure the update script exists and is correct
  write_update_script

  # Add/refresh the cron job for root
  add_cron_job "$CRON_SCHED"

  echo
  echo "[✓] Setup complete!"
  echo "  - Update script: $UPDATE_SCRIPT"
  echo "  - Log file:      $LOG_FILE"
  echo "  - Cron entry:    $CRON_SCHED $UPDATE_SCRIPT"
  echo
  echo "Updates will run unattended as root and notify when finished."
}

main "$@"
