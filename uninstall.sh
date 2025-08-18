#!/usr/bin/env bash
set -Eeuo pipefail

# ==================================
# uninstall.sh — Moonstone cleanup =
# ==================================

say()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*"; }
err()  { echo "[ERROR] $*" >&2; exit 1; }

# Silent sudo elevation if not root
require_root() {
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -E bash "$0" "$@"
    else
      exit 1
    fi
  fi
}

confirm() { # confirm "Question?"
  local a
  read -rp "$1 [y/N]: " a
  [[ "${a,,}" == "y" || "${a,,}" == "yes" ]]
}

unit_exists() {
  local u="${1%.service}.service"
  systemctl list-units --all --type=service --no-legend | awk '{print $1}' | grep -Fxq "$u" \
  || systemctl list-unit-files --type=service --no-legend | awk '{print $1}' | grep -Fxq "$u"
}

stop_disable_remove_unit() {
  local unit="${1%.service}.service"
  if ! unit_exists "$unit"; then
    say "Unit not present: ${unit%.service} (skipping)"
    return 0
  fi

  if systemctl stop "$unit" 2>/dev/null; then
    say "Stopped unit: ${unit%.service}"
  else
    warn "Failed to stop: ${unit%.service}"
  fi

  systemctl disable "$unit" >/dev/null 2>&1 || true

  local upath
  for upath in "/etc/systemd/system/${unit}" "/lib/systemd/system/${unit}"; do
    if [[ -f "$upath" ]]; then
      say "Removing unit file: $upath"
      rm -f "$upath"
    fi
  done
}

main() {
  require_root "$@"

# --- Input validation ---
  [[ $# -ge 1 ]] || err "Usage: $0 <username>"
  local TARGET_USER="$1"
  [[ "$TARGET_USER" != "root" ]] || err "Refusing to uninstall for 'root'."

  id "$TARGET_USER" >/dev/null 2>&1 || err "System user '$TARGET_USER' does not exist."

  local USERS_FILE="/opt/moonstone/users"
  [[ -r "$USERS_FILE" ]] || err "Installed users list not found: $USERS_FILE"
  grep -Fxq "$TARGET_USER" "$USERS_FILE" || err "'$TARGET_USER' is not recorded in $USERS_FILE"

  local USER_HOME DATADIR CONF UIDN
  USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [[ -n "$USER_HOME" && -d "$USER_HOME" ]] || err "Cannot resolve home for '$TARGET_USER'."
  DATADIR="${USER_HOME}/.bitoreumcore"
  CONF="${DATADIR}/bitoreum.conf"
  UIDN="$(id -u "$TARGET_USER")"

  echo
  warn "You are about to UNINSTALL Bitoreum smartnode for user '$TARGET_USER'."
  warn "This will stop/disable/remove the service, back up the conf,"
  warn "DELETE THE USER ACCOUNT (including home directory), and update the users list."
  echo
  confirm "Proceed with destructive uninstall for '$TARGET_USER'?" || { say "Aborted."; exit 0; }

# --- Stop/disable/remove services ---
  say "Stopping and removing related systemd units..."
  stop_disable_remove_unit "${TARGET_USER}"
  stop_disable_remove_unit "bitoreumd@${TARGET_USER}"

# Also scan for any units that reference this user/datadir ---
  mapfile -t UNIT_FILES < <(grep -RIl -E "User=${TARGET_USER}|-datadir=/home/${TARGET_USER}/\.bitoreumcore" \
    /etc/systemd/system /lib/systemd/system 2>/dev/null || true)
  if (( ${#UNIT_FILES[@]} > 0 )); then
# --- Deduplicate basenames ---
    declare -A seen=()
    for f in "${UNIT_FILES[@]}"; do
      u="$(basename "$f")"
      [[ -z "${seen[$u]:-}" ]] || continue
      seen[$u]=1
      stop_disable_remove_unit "$u"
    done
  fi

  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true

# --- Backup config (copy, not move) ---
BK_DIR="/opt/moonstone/backups"
BK_FILE="${BK_DIR}/${TARGET_USER}-bitoreum.conf"
mkdir -p "$BK_DIR"

if [[ -f "$CONF" ]]; then
  if cp -a "$CONF" "$BK_FILE"; then
    say "Backed up $CONF -> $BK_FILE"
    # Optional: verify non-empty
    if [[ ! -s "$BK_FILE" ]]; then
      err "Backup file is empty — aborting uninstall."
    fi
  else
    err "Failed to back up $CONF — aborting uninstall."
  fi
else
  warn "Config not found at $CONF — no backup created."
fi

# --- Terminate all processes for the user to avoid 'user is used by process' ---
  say "Terminating processes for user '$TARGET_USER'..."
  command -v loginctl >/dev/null 2>&1 && loginctl terminate-user "$TARGET_USER" 2>/dev/null || true
  pkill -u "$TARGET_USER" 2>/dev/null || true
# --- Just in case: target any bitoreum daemons with this datadir ---
  pkill -f "[b]itoreum(d|\-cli).*-datadir=${DATADIR}" 2>/dev/null || true

# --- Wait briefly and escalate if needed ---
  sleep 1
  if pgrep -u "$TARGET_USER" >/dev/null 2>&1; then
    warn "Forcing remaining processes for '$TARGET_USER'..."
    pkill -9 -u "$TARGET_USER" 2>/dev/null || true
    sleep 1
  fi
  if pgrep -u "$TARGET_USER" >/dev/null 2>&1; then
    err "Still seeing processes for '$TARGET_USER'. Please investigate (e.g., lingering shells) and rerun."
  fi

# --- Clean possible lingering runtime dir ---
  if [[ -n "$UIDN" && -d "/run/user/$UIDN" ]]; then
    rm -rf "/run/user/$UIDN" 2>/dev/null || true
  fi

# --- Delete user & home ---
  say "Deleting user '$TARGET_USER' (with home)..."
  userdel -r "$TARGET_USER" || err "Failed to delete user '$TARGET_USER'."

# --- Remove from users file ---
  if [[ -w "$USERS_FILE" ]]; then
    say "Removing '$TARGET_USER' from $USERS_FILE"
    sed -i "\|^${TARGET_USER}$|d" "$USERS_FILE"
  else
    warn "Cannot modify $USERS_FILE to remove '$TARGET_USER'."
  fi

  say "Uninstall for '$TARGET_USER' completed."
}

main "$@"
