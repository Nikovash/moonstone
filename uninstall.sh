#!/usr/bin/env bash
set -Eeuo pipefail

# ====================================
# uninstall.sh — Moonstone cleanup
# ====================================

say(){ echo "[INFO]  $*"; }
warn(){ echo "[WARN]  $*"; }
err(){ echo "[ERROR] $*" >&2; exit 1; }

# Silent root elevation if needed
require_root() {
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -E bash "$0" "$@"
    else
      exit 1
    fi
  fi
}

confirm(){ # confirm "Question?"
  local _ans
  read -rp "$1 [y/N]: " _ans
  [[ "${_ans,,}" == "y" || "${_ans,,}" == "yes" ]]
}

main() {
  require_root "$@"

  # --- Input validation
  if [[ $# -lt 1 ]]; then
    err "Usage: $0 <username>"
  fi
  local TARGET_USER="$1"

  if [[ "$TARGET_USER" == "root" ]]; then
    err "Refusing to uninstall for 'root'."
  fi

  # Must exist on system
  if ! id "$TARGET_USER" >/dev/null 2>&1; then
    err "System user '$TARGET_USER' does not exist."
  fi

  # Must be in the installed users list
  local USERS_FILE="/opt/moonstone/users"
  if [[ ! -r "$USERS_FILE" ]]; then
    err "Installed users list not found: $USERS_FILE"
  fi
  if ! grep -Fxq "$TARGET_USER" "$USERS_FILE"; then
    err "'$TARGET_USER' is not recorded in $USERS_FILE"
  fi

  # Resolve home/datadir
  local USER_HOME DATADIR CONF
  USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [[ -n "$USER_HOME" && -d "$USER_HOME" ]] || err "Cannot resolve home for '$TARGET_USER'."
  DATADIR="${USER_HOME}/.bitoreumcore"
  CONF="${DATADIR}/bitoreum.conf"

  echo
  warn "You are about to UNINSTALL Bitoreum smartnode for user '$TARGET_USER'."
  warn "This will stop/disable/remove the systemd service, back up the conf,"
  warn "DELETE THE USER ACCOUNT (including home directory), and update the users list."
  echo
  if ! confirm "Proceed with destructive uninstall for '$TARGET_USER'?"; then
    say "Aborted by user."
    exit 0
  fi

  # --- Stop & disable service
  local SERVICE_NAME="${TARGET_USER}.service"
  if systemctl list-units --type=service --all | grep -q "^${SERVICE_NAME}"; then
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      say "Stopping service: $SERVICE_NAME"
      systemctl stop "$SERVICE_NAME" || warn "Failed to stop $SERVICE_NAME (continuing)."
    else
      say "Service $SERVICE_NAME is not active."
    fi
    say "Disabling service: $SERVICE_NAME"
    systemctl disable "$SERVICE_NAME" || warn "Failed to disable $SERVICE_NAME (continuing)."
    # Remove unit file if present
    local UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}"
    if [[ -f "$UNIT_PATH" ]]; then
      say "Removing unit file: $UNIT_PATH"
      rm -f "$UNIT_PATH"
    fi
    say "Reloading systemd daemon..."
    systemctl daemon-reload
  else
    say "Service unit $SERVICE_NAME not found (skipping service steps)."
  fi

  # --- Backup bitoreum.conf
  mkdir -p /opt/moonstone/backups
  if [[ -f "$CONF" ]]; then
    local BK="/opt/moonstone/backups/${TARGET_USER}-bitoreum.conf"
    say "Backing up $CONF -> $BK"
    mv -f "$CONF" "$BK"
  else
    warn "Config file not found at $CONF — skipping backup."
  fi

  # --- Delete system user & home
  say "Deleting user '$TARGET_USER' and home directory..."
  # As an extra safety, ensure we’re not about to delete / or an empty string
  if [[ -n "$TARGET_USER" ]]; then
    userdel -r "$TARGET_USER" || err "Failed to delete user '$TARGET_USER'."
  fi

  # --- Remove from /opt/moonstone/users
  if [[ -w "$USERS_FILE" ]]; then
    say "Removing '$TARGET_USER' from $USERS_FILE"
    # Delete exact matching line
    sed -i "\|^${TARGET_USER}$|d" "$USERS_FILE"
  else
    warn "Cannot write to $USERS_FILE to remove '$TARGET_USER'."
  fi

  say "Uninstall for '$TARGET_USER' completed."
}

main "$@"
