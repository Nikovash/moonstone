#!/usr/bin/env bash
set -Eeuo pipefail

# ====================================
# update_conf.sh — Moonstone helper
# - Requires root/sudo
# - Reads /opt/moonstone/users for installed usernames
# - If no arg: loops through users asking to pick one
# - If arg (username): uses it directly
# - Stops <username>.service if running, edits conf, restarts if it was running
# - Backs up conf with timestamp
# - Lets you SET/KEEP/COMMENT keys in bitoreum.conf
# ====================================

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

parse_conf_val(){ # parse_conf_val <file> <KeyName>
  local file="$1" key="$2"
  awk -F'=' -v k="$key" '
    $0 !~ /^[[:space:]]*#/ && $1==k {
      val=$2; sub(/^[[:space:]]+/,"",val); sub(/[[:space:]]+$/,"",val);
      print val; exit
    }' "$file" 2>/dev/null || true
}

set_or_comment_key(){ # set_or_comment_key <file> <KeyName> <value|"#">
  local file="$1" key="$2" val="${3:-}"
  local esc_key
  esc_key="$(printf '%s\n' "$key" | sed 's/[.[\*^$()+?{}|]/\\&/g')"

  if [[ "$val" == "#" ]]; then
# --- comment out line (ensure a single commented placeholder) ---
    if grep -Eq "^[[:space:]]*${esc_key}[[:space:]]*=" "$file"; then
      sed -i "s|^[[:space:]]*${esc_key}[[:space:]]*=.*|#${key}=|g" "$file"
    elif ! grep -Eq "^[[:space:]]*#${esc_key}[[:space:]]*=" "$file"; then
      echo "#${key}=" >> "$file"
    fi
  else
# --- set or append ---
    if grep -Eq "^[[:space:]]*${esc_key}[[:space:]]*=" "$file"; then
      sed -i "s|^[[:space:]]*${esc_key}[[:space:]]*=.*|${key}=${val}|g" "$file"
    elif grep -Eq "^[[:space:]]*#${esc_key}[[:space:]]*=" "$file"; then
      sed -i "s|^[[:space:]]*#${esc_key}[[:space:]]*=.*|${key}=${val}|g" "$file"
    else
      echo "${key}=${val}" >> "$file"
    fi
  fi
}

prompt_key(){ # prompt_key <file> <KeyName> <label> <allow_empty_keep:true|false>
  local file="$1" key="$2" label="$3" keep_empty="${4:-true}"
  local current new
  current="$(parse_conf_val "$file" "$key" || true)"
  if [[ -n "$current" ]]; then
    say "$label (current: $current)"
  else
    say "$label (currently commented or empty)"
  fi
  echo " - Enter a new value to SET"
  echo " - Press Enter to KEEP current"
  echo " - Type a single # to COMMENT it out"
  read -rp "> $key: " new

  if [[ -z "$new" ]]; then
    if [[ "$keep_empty" == "true" ]]; then
      say "Keeping $key as-is."
      return 0
    fi
  fi

  if [[ "$new" == "#" ]]; then
    set_or_comment_key "$file" "$key" "#"
    say "Commented $key."
  else
    set_or_comment_key "$file" "$key" "$new"
    say "Set $key."
  fi
}

pick_user_from_list(){
  local list_file="/opt/moonstone/users" u
  [[ -r "$list_file" ]] || err "User list not found: $list_file"
  mapfile -t USERS < <(grep -v '^[[:space:]]*$' "$list_file" 2>/dev/null || true)
  (( ${#USERS[@]} > 0 )) || err "No users recorded in $list_file"

  for u in "${USERS[@]}"; do
    if confirm "Modify user '$u'?"; then
      echo "$u"
      return 0
    fi
  done

  err "No user selected."
}

main(){
  require_root "$@"

  local TARGET_USER="${1:-}"
  if [[ -z "$TARGET_USER" ]]; then
    TARGET_USER="$(pick_user_from_list)"
  fi

# --- Validate user exists on system ---
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

# --- Edit keys ---
  echo
  say "=== Editing $CONF ==="
  prompt_key "$CONF" "CollateralHash"           "Set CollateralHash (TXID)" true
  prompt_key "$CONF" "ProTXHash"                "Set ProTXHash (if known)"  true
  prompt_key "$CONF" "smartnodePublicKey"       "Set smartnodePublicKey (BLS pub)" true
  prompt_key "$CONF" "OwnerAddress"             "Set OwnerAddress"          true
  prompt_key "$CONF" "VotingAddress"            "Set VotingAddress"         true

# --- Ensure permissions ---
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
