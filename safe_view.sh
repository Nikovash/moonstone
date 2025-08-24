#!/usr/bin/env bash
set -Eeuo pipefail

# ===========================================
# safe_view.sh  Safe config viewer (read-only)
# - Requires root/sudo (auto-elevates)
# - Arg:  <username>   -> view that user's conf
# - No arg: iterate through /opt/moonstone/users and ask
# - Prints sanitized bitoreum.conf to stdout
# - Redacts ONLY: smartnodeblsprivkey
# ===========================================

err(){ echo "[ERROR] $*" >&2; exit 1; }
say(){ echo "[INFO]  $*"; }
confirm(){ local a; read -rp "$1 [y/N]: " a; [[ "${a,,}" == "y" || "${a,,}" == "yes" ]]; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo -E bash "$0" "$@"
    else
      exit 1
    fi
  fi
}

pick_user_from_list(){
  local list_file="/opt/moonstone/users" u
  [[ -r "$list_file" ]] || err "User list not found: $list_file"
  mapfile -t USERS < <(grep -v '^[[:space:]]*$' "$list_file" 2>/dev/null || true)
  (( ${#USERS[@]} > 0 )) || err "No users recorded in $list_file"
  for u in "${USERS[@]}"; do
    if confirm "View config for user '$u'?"; then
      echo "$u"; return 0
    fi
  done
  err "No user selected."
}

sanitize_and_print(){
  # Redact ONLY smartnodeblsprivkey value, preserving comment state/format
  awk '
    BEGIN { IGNORECASE=1 }
    {
      # Match lines with optional comment, then key, then "="
      if (match($0, /^[[:space:]]*(#?)[[:space:]]*smartnodeblsprivkey[[:space:]]*=/)) {
        comment = substr($0, RSTART, RLENGTH)
        # Determine if original was commented
        if (comment ~ /#/) {
          print "#smartnodeblsprivkey=<redacted>"
        } else {
          print "smartnodeblsprivkey=<redacted>"
        }
        next
      }
      print
    }
  ' "$1"
}

main(){
  require_root "$@"

  local TARGET_USER="${1:-}"
  if [[ -z "$TARGET_USER" ]]; then
    TARGET_USER="$(pick_user_from_list)"
  fi

  # Validate system user and conf path
  id "$TARGET_USER" >/dev/null 2>&1 || err "User '$TARGET_USER' does not exist."
  local USER_HOME DATADIR CONF
  USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [[ -n "$USER_HOME" && -d "$USER_HOME" ]] || err "Cannot resolve home for '$TARGET_USER'."
  DATADIR="${USER_HOME}/.bitoreumcore"
  CONF="${DATADIR}/bitoreum.conf"
  [[ -f "$CONF" ]] || err "Conf not found: $CONF"

  say "Displaying sanitized (read-only) view of: $CONF"
  echo "------------------------------------------------------------"
  sanitize_and_print "$CONF"
  echo "------------------------------------------------------------"
  say "Read-only view complete. (No changes were made.)"
}

main "$@"
