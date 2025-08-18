#!/usr/bin/env bash
set -Eeuo pipefail

# =================================
# update_ip.sh — Moonstone helper =
# =================================

err(){ echo "[ERROR] $*" >&2; exit 1; }
say(){ echo "[INFO]  $*"; }
warn(){ echo "[WARN]  $*"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -E bash "$0" "$@"
    else
      exit 1
    fi
  fi
}

confirm(){ # confirm "question"
  local _ans
  read -rp "$1 [y/N]: " _ans
  [[ "${_ans,,}" == "y" || "${_ans,,}" == "yes" ]]
}

pick_user_from_list(){
  local list_file="/opt/moonstone/users" u
  [[ -r "$list_file" ]] || err "User list not found: $list_file"
  mapfile -t USERS < <(grep -v '^[[:space:]]*$' "$list_file" 2>/dev/null || true)
  (( ${#USERS[@]} > 0 )) || err "No users recorded in $list_file"

  for u in "${USERS[@]}"; do
    if confirm "Modify networking for user '$u'?"; then
      echo "$u"
      return 0
    fi
  done
  err "No user selected."
}

parse_conf_val(){ # parse_conf_val <file> <KeyName>
  local file="$1" key="$2"
  awk -F'=' -v k="$key" '
    $0 !~ /^[[:space:]]*#/ && $1==k {
      val=$2; sub(/^[[:space:]]+/,"",val); sub(/[[:space:]]+$/,"",val);
      print val; exit
    }' "$file" 2>/dev/null || true
}

set_key(){ # set_key <file> <KeyName> <Value>
  local file="$1" key="$2" val="$3"
  local esc_key
  esc_key="$(printf '%s\n' "$key" | sed 's/[.[\*^$()+?{}|]/\\&/g')"
  if grep -Eq "^[[:space:]]*${esc_key}[[:space:]]*=" "$file"; then
    sed -i "s|^[[:space:]]*${esc_key}[[:space:]]*=.*|${key}=${val}|" "$file"
  elif grep -Eq "^[[:space:]]*#[:space:]*${esc_key}[[:space:]]*=" "$file"; then
# --- Replace commented form with active setting ---
    sed -i "s|^[[:space:]]*#[:space:]*${esc_key}[[:space:]]*=.*|${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

normalize_external(){
# --- normalize_external <input> -> prints ip[:port], appending :15168 if no port ---
  local in="${1//[[:space:]]/}" port="15168"
  if [[ -z "$in" ]]; then
    echo ""
    return 0
  fi
  if [[ "$in" == *:* ]]; then
    echo "$in"
  else
    echo "${in}:${port}"
  fi
}

main(){
  require_root "$@"

  local TARGET_USER="${1:-}"
  if [[ -z "$TARGET_USER" ]]; then
    TARGET_USER="$(pick_user_from_list)"
  fi

# --- Validate system user ---
  id "$TARGET_USER" >/dev/null 2>&1 || err "User '$TARGET_USER' does not exist on this system."

  local USER_HOME DATADIR CONF
  USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [[ -n "$USER_HOME" && -d "$USER_HOME" ]] || err "Cannot resolve home for '$TARGET_USER'."
  DATADIR="${USER_HOME}/.bitoreumcore"
  CONF="${DATADIR}/bitoreum.conf"
  [[ -f "$CONF" ]] || err "Conf file not found: $CONF"

  local SERVICE_NAME="${TARGET_USER}.service"
  local was_active=false
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    say "Service $SERVICE_NAME is running; stopping it for safe edits..."
    was_active=true
    systemctl stop "$SERVICE_NAME"
  else
    say "Service $SERVICE_NAME is not active."
  fi

# --- Backup ---
  local TS; TS="$(date +%Y%m%d-%H%M%S)"
  local BACKUP="${CONF}.bak.${TS}"
  cp -a "$CONF" "$BACKUP"
  say "Backup saved: $BACKUP"

# --- Current Values ---
  local CUR_BIND CUR_EXT
  CUR_BIND="$(parse_conf_val "$CONF" "bind" || true)"
  CUR_EXT="$(parse_conf_val "$CONF" "externalip" || true)"

  [[ -n "$CUR_BIND" ]] && say "Current bind: ${CUR_BIND}" || say "Current bind: <empty or commented>"
  [[ -n "$CUR_EXT"  ]] && say "Current externalip: ${CUR_EXT}" || say "Current externalip: <empty or commented>"

# --- Prompt for new values (blank = keep current) ---
  local NEW_BIND NEW_EXT
  read -rp "New bind IPv4 (blank to keep current): " NEW_BIND
  read -rp "New external/ephemeral IPv4 (blank to keep current; :port optional): " NEW_EXT

# --- Normalize external to ensure :15168 ---
  if [[ -n "$NEW_EXT" ]]; then
    NEW_EXT="$(normalize_external "$NEW_EXT")"
  fi

# --- Apply changes if provided ---
  if [[ -n "$NEW_BIND" ]]; then
    set_key "$CONF" "bind" "$NEW_BIND"
    say "Updated bind=${NEW_BIND}"
  else
    say "bind unchanged."
  fi

  if [[ -n "$NEW_EXT" ]]; then
    set_key "$CONF" "externalip" "$NEW_EXT"
    say "Updated externalip=${NEW_EXT}"
  else
    say "externalip unchanged."
  fi

# --- Permissions ---
  chown -R "${TARGET_USER}:${TARGET_USER}" "$DATADIR"

# --- Restart if it was active ---
  if [[ "$was_active" == true ]]; then
    say "Restarting $SERVICE_NAME..."
    systemctl start "$SERVICE_NAME"
    systemctl is-active --quiet "$SERVICE_NAME" && say "Service restarted." || err "Service failed to start."
  else
    say "Leaving $SERVICE_NAME stopped (it was not running)."
  fi

  say "Done."
}

main "$@"
