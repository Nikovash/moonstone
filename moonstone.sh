#!/usr/bin/env bash
set -Eeuo pipefail

# ===========================================
# Moonstone - Bitoreum Smartnode Setup Tool =
# ===========================================

# --- Logging ---
RUN_DIR="$(pwd -P)"
LOG_DIR="$RUN_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"

_ts(){ date +"%Y-%m-%d %H:%M:%S"; }
_log(){ echo "[$(_ts)] $*" | tee -a "$LOG_FILE"; }
say(){ _log "[INFO]  $*"; }
warn(){ _log "[WARN]  $*"; }
err(){ _log "[ERROR] $*" >&2; }

ask(){ # ask "Prompt: " VAR
  local _ans; read -rp "$1" _ans
  printf -v "$2" "%s" "$_ans"
  _log "[ASK ] $1 -> ${_ans:-<empty>}"
}
confirm(){ # confirm "Question?"  -> 0=yes
  local _ans; read -rp "$1 [y/N]: " _ans
  _log "[ASK?] $1 -> ${_ans:-<empty>}"
  [[ "${_ans,,}" == "y" || "${_ans,,}" == "yes" ]]
}

trap 'err "Script failed at line $LINENO."; exit 1' ERR

# --- Guard: Linux only ---
OS_KERNEL="$(uname -s || true)"
case "$OS_KERNEL" in
  Linux) ;;
  Darwin) err "This script only supports Linux (detected macOS)"; exit 1 ;;
  MINGW*|MSYS*|CYGWIN*) err "This script only supports Linux (detected Windows)"; exit 1 ;;
  *) err "Unsupported kernel: $OS_KERNEL"; exit 1 ;;
esac

# --- Root/sudo ---
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    warn "Not root; re-executing with sudo..."
    exec sudo -E bash "$0"
  else
    err "Please run as root or with sudo."
    exit 1
  fi
fi

# --- Daemon stopped check ---
say "Has the Bitoreum daemon been stopped? (yes / maybe / no)"
read -rp "> " DAEMON_ANSWER
_log "[ANS ] daemon-stopped -> ${DAEMON_ANSWER:-<empty>}"
case "${DAEMON_ANSWER,,}" in
  yes|y) ;;
  maybe|no|n|"") err "Stop the daemon first (e.g. 'bitoreum-cli stop') then re-run."; exit 1 ;;
  *) err "Invalid response. Answer yes, maybe, or no."; exit 1 ;;
esac

# --- Packages ---
say "Updating apt & installing prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y | tee -a "$LOG_FILE"
apt-get install -y dialog nano fail2ban unzip curl jq ca-certificates lsb-release openssl iproute2 htop | tee -a "$LOG_FILE"

# --- Memory & Swap ---
mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo || echo 0)
swap_kb=$(awk '/SwapTotal:/ {print $2}' /proc/meminfo || echo 0)
mem_mb=$(( mem_kb / 1024 ))
swap_mb=$(( swap_kb / 1024 ))
say "Detected RAM: ${mem_mb} MB, Swap: ${swap_mb} MB"

if (( mem_mb >= 4096 )); then
  say "RAM >= 4GB; skipping swap configuration."
else
  meets_min=false
  if   (( mem_mb >= 2048 )); then meets_min=true
  elif (( mem_mb >= 1024 )) && (( swap_mb >= 2048 )); then meets_min=true
  fi
  if [[ "$meets_min" == false ]]; then
    if (( mem_mb < 700 )); then err "Minimum resources not met (>=700MB RAM). Aborting."; exit 1; fi
    target_swap_mb=2048
    if (( mem_mb >= 700 && mem_mb < 1000 )); then target_swap_mb=3072; fi
    say "Creating /swapfile of ${target_swap_mb} MB..."
    swapoff -a || true
    if grep -Eq '^[^#].*\s+swap\s+' /etc/fstab; then
      cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"
      sed -ri '/\s+swap\s+/d' /etc/fstab
    fi
    blocks=$(( target_swap_mb * 1024 )) # 1k blocks
    dd if=/dev/zero of=/swapfile bs=1k count="${blocks}" status=progress
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile swap swap auto 0 0' >> /etc/fstab
    sysctl -w vm.swappiness=10
    if ! grep -q '^vm\.swappiness' /etc/sysctl.conf 2>/dev/null; then
      echo 'vm.swappiness = 10' >> /etc/sysctl.conf
    else
      sed -ri 's/^vm\.swappiness.*/vm.swappiness = 10/' /etc/sysctl.conf
    fi
    say "Swap configured."
  else
    say "Memory requirements already satisfied; no swap changes."
  fi
fi

# --- Versions & arch ---
BITD_PATH="/usr/bin/bitoreumd"
BITCLI_PATH="/usr/bin/bitoreum-cli"
bitd_ver=""; bitcli_ver=""
[[ -x "$BITD_PATH" ]] && bitd_ver="$("$BITD_PATH" --version 2>/dev/null | head -n1 || true)"
[[ -x "$BITCLI_PATH" ]] && bitcli_ver="$("$BITCLI_PATH" --version 2>/dev/null | head -n1 || true)"
say "Detected binaries:"
say "  bitoreumd:    ${bitd_ver:-<not found>}"
say "  bitoreum-cli: ${bitcli_ver:-<not found>}"

machine=$(uname -m)
case "$machine" in
  x86_64) ARCH_LABEL="x86_64" ;;
  i386|i686) ARCH_LABEL="i686" ;;
  aarch64|arm64) ARCH_LABEL="aarch64" ;;
  armv7l|armv6l|armv7) ARCH_LABEL="armhf" ;;
  *) ARCH_LABEL="$machine" ;;
esac
say "Architecture: ${ARCH_LABEL}"

# --- Hardware detect (Ampere/Oracle, Raspberry Pi) ---
is_ampere=false
if lscpu 2>/dev/null | grep -qiE 'ampere|neoverse-?n1'; then is_ampere=true; fi

is_pi=false; is_pi4=false; pi_model=""
if [[ -r /proc/device-tree/model ]]; then
  pi_model="$(tr -d '\0' </proc/device-tree/model)"
  if echo "$pi_model" | grep -qi 'raspberry pi'; then
    is_pi=true
    if echo "$pi_model" | grep -Eq 'Raspberry Pi [4-9]'; then is_pi4=true; fi
  fi
fi
say "Hardware hints: Ampere=${is_ampere} Pi=${is_pi} Pi4plus=${is_pi4} (${pi_model:-unknown})"

# --- Oracle flag (auto-detect) ---
has_cmd(){ command -v "$1" >/dev/null 2>&1; }

detect_oracle() {
  local hits=0 v
# --- DMI strings ---
  for f in /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name /sys/class/dmi/id/board_vendor /sys/class/dmi/id/bios_vendor; do
    if [[ -r "$f" ]]; then
      v="$(tr -d '\0' <"$f" | tr '[:upper:]' '[:lower:]')"
      if grep -qE 'oracle|oci|oracle cloud' <<<"$v"; then
        ((hits++))
        break
      fi
    fi
  done
# --- cloud-init datasource ---
  if [[ -r /var/lib/cloud/instance/datasource ]]; then
    v="$(tr -d '\0' </var/lib/cloud/instance/datasource | tr '[:upper:]' '[:lower:]')"
    if grep -qE 'oracle|oci' <<<"$v"; then ((hits++)); fi
  fi
# --- Oracle Cloud Agent package ---
  if dpkg -l 2>/dev/null | awk '{print $2}' | grep -q '^oracle-cloud-agent$'; then ((hits++)); fi
  # OCI metadata service
  if has_cmd curl && curl -4 -m 1 -sS --noproxy '*' http://169.254.169.254/opc/v1/ >/dev/null; then ((hits++)); fi
  [[ $hits -ge 2 ]]
}

# --- Final Oracle mode flag ---
if detect_oracle; then
  is_oracle=true
else
  is_oracle=false
fi
say "Oracle mode (auto-detected): $is_oracle"

# --- Fail2Ban ---
say "Configuring Fail2Ban for SSH..."
[[ -f /etc/fail2ban/jail.local ]] && cp -a /etc/fail2ban/jail.local "/etc/fail2ban/jail.local.bak.$(date +%s)"
cat > /etc/fail2ban/jail.local <<'JAIL'
[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
JAIL
systemctl restart fail2ban
systemctl enable fail2ban >/dev/null 2>&1 || true
say "Fail2Ban ready."

# --- Firewall ---
if [[ "$is_oracle" == true ]]; then
  say "Configuring iptables-persistent for Oracle..."
  if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
  fi
  iptables_rule_file="/etc/iptables/rules.v4"
  iptables-save > "$iptables_rule_file"
  if ! grep -q -- "-A INPUT -p tcp -m state --state NEW -m tcp --dport 15168 -j ACCEPT" "$iptables_rule_file"; then
    if grep -q -- "-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT" "$iptables_rule_file"; then
      sed -i '/-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT/a -A INPUT -p tcp -m state --state NEW -m tcp --dport 15168 -j ACCEPT' "$iptables_rule_file"
    else
      echo "-A INPUT -p tcp -m state --state NEW -m tcp --dport 15168 -j ACCEPT" >> "$iptables_rule_file"
    fi
    iptables-restore < "$iptables_rule_file"
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save
  fi
  say "Oracle firewall configured."
else
  say "Configuring UFW..."
  command -v ufw >/dev/null 2>&1 || apt-get install -y ufw
  ufw allow 22/tcp
  ufw allow 15168/tcp
  if ! ufw status | grep -q "^Status: active"; then ufw --force enable; else ufw reload; fi
  ufw status verbose | tee -a "$LOG_FILE"
fi

# --- Latest GitHub release (powcache + assets list) ---
say "Querying latest Bitoreum release..."
LATEST_JSON="$(curl -4 -fsSL https://api.github.com/repos/Nikovash/bitoreum/releases/latest || true)"
LATEST_TAG="$(jq -r '.tag_name // empty' <<<"$LATEST_JSON" || true)"
ASSETS_JSON="$(jq -r '.assets // []' <<<"$LATEST_JSON" || echo '[]')"
say "Latest tag: ${LATEST_TAG:-<unknown>}"

powcache_url="$(jq -r '.[] | select(.name|test("powcache\\.dat$";"i")) | .browser_download_url' <<<"$ASSETS_JSON" | head -n1 || true)"
say "powcache.dat: ${powcache_url:-<not found>}"

# --- Decide if we actually need to download binaries ---
NEED_BIN_DL=true
if [[ -n "$LATEST_TAG" ]]; then
  if [[ -n "$bitd_ver" && -n "$bitcli_ver" ]] \
     && grep -q "$LATEST_TAG" <<<"$bitd_ver" \
     && grep -q "$LATEST_TAG" <<<"$bitcli_ver"; then
    say "Installed binaries already match latest ($LATEST_TAG); skipping binary download."
    NEED_BIN_DL=false
  fi
fi

# --- Binary tarball selection + install (only if needed) ---
if [[ "$NEED_BIN_DL" == true ]]; then
  say "Available release assets:"
  jq -r '.[].name' <<<"$ASSETS_JSON" | sed 's/^/  - /' | tee -a "$LOG_FILE"

  say "Selecting Linux binary tarball for this hardware..."
  lower_arch_token(){
    case "$1" in
      aarch64) echo '(aarch64|arm[_-]?64)';;
      armhf)   echo '(armhf|arm[_-]?32|armv7|arm32)';;
      x86_64)  echo '(x86[_-]?64|amd64|64bit)';;
      i686)    echo '(x86[_-]?32|i[3-6]86|32bit)';;
      *)       echo '(linux)';;
    esac
  }
  ARCH_TOKEN="$(lower_arch_token "$ARCH_LABEL")"

  force_arm32=false
  if [[ "$is_pi" == true && "$is_pi4" == false ]]; then
    warn "Raspberry Pi < 4 detected — forcing ARM_32 build; may be unstable."
    force_arm32=true
    ARCH_TOKEN='(armhf|arm[_-]?32|armv7|arm32)'
  fi

  declare -a REGEXES=()
  if [[ "$ARCH_LABEL" == "aarch64" && ( "$is_ampere" == true || "$is_oracle" == true ) && "$force_arm32" == false ]]; then
    REGEXES+=("^.*(linux|ubuntu).*(oracle|ampere).*(arm[_-]?64|aarch64).*\\.tar\\.gz$")
  fi
  if [[ "$ARCH_LABEL" == "aarch64" && "$is_pi4" == true && "$force_arm32" == false ]]; then
    REGEXES+=("^.*(linux|ubuntu).*(pi4).*?(arm[_-]?64|aarch64).*\\.tar\\.gz$")
  fi
  REGEXES+=("^.*(linux|ubuntu).*$ARCH_TOKEN.*\\.tar\\.gz$")
  REGEXES+=("^.*linux.*\\.tar\\.gz$")

  pick_asset(){
    local rx="$1"
    jq -r --arg rx "$rx" '.[] | select(.name|test($rx; "i")) | .browser_download_url' <<<"$ASSETS_JSON" | head -n1
  }
  BINARY_URL=""
  for rx in "${REGEXES[@]}"; do
    BINARY_URL="$(pick_asset "$rx")"
    if [[ -n "$BINARY_URL" && "$BINARY_URL" != "null" ]]; then
      say "Matched asset with regex: $rx"
      break
    fi
  done
  if [[ -z "${BINARY_URL:-}" || "${BINARY_URL}" == "null" ]]; then
    err "No matching Linux tarball found in latest release assets."
  fi

  say "Downloading binary tarball: $BINARY_URL"
  TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD" || true' EXIT
  ARCHIVE_PATH="$TMPD/bitoreum.tar.gz"
  if ! curl -4 -L --fail --progress-bar "$BINARY_URL" -o "$ARCHIVE_PATH"; then
    err "Failed to download the Bitoreum tarball."
  fi
  say "Extracting tarball..."
  mkdir -p "$TMPD/extract"
  tar -xzf "$ARCHIVE_PATH" -C "$TMPD/extract"

  find_and_install(){
    local bin="$1"
    local p
    p="$(find "$TMPD/extract" -type f -name "$bin" -perm -111 | head -n1 || true)"
    [[ -z "$p" ]] && err "Executable $bin not found in archive."
    say "Installing $bin -> /usr/bin/$bin"
    install -m 0755 -T "$p" "/usr/bin/$bin"
  }
  find_and_install bitoreumd
  find_and_install bitoreum-cli
  hash -r || true
  command -v bitoreumd >/dev/null 2>&1 || err "bitoreumd not on PATH after install."
  command -v bitoreum-cli >/dev/null 2>&1 || err "bitoreum-cli not on PATH after install."
  say "Binary install complete."
else
  say "Keeping existing /usr/bin/bitoreumd and /usr/bin/bitoreum-cli."
fi

# --- Prior attempt detection & cleanup path ---
say "Have you (a) successfully installed a smartnode already, or (b) tried and failed?"
say "Enter one: success / failed / new"
read -rp "> " INSTALL_STATE
INSTALL_STATE="${INSTALL_STATE,,}"
_log "[ANS ] install-state -> ${INSTALL_STATE:-<empty>}"

say "Searching for existing bitoreum.conf files..."
FOUND_CONFS=()
while IFS= read -r -d '' f; do FOUND_CONFS+=("$f"); done < <(find /home /root -type f -name "bitoreum.conf" -print0 2>/dev/null || true)
if (( ${#FOUND_CONFS[@]} > 0 )); then
  say "Found possible configs:"; for p in "${FOUND_CONFS[@]}"; do echo "  - $p" | tee -a "$LOG_FILE"; done
else
  say "No existing configs found."
fi

REUSE_USER_NAME=""
if [[ "$INSTALL_STATE" == "failed" ]]; then
  if confirm "Start over from scratch (remove previous smartnode data/users/services)?"; then
    if (( ${#FOUND_CONFS[@]} > 0 )); then say "If one of the above paths belongs to another user, enter that username to clean it."; fi
    ask "Enter previous username to reuse (or press Enter to skip): " REUSE_USER_NAME || true
    REUSE_USER_NAME="${REUSE_USER_NAME:-}"
    if [[ -n "$REUSE_USER_NAME" ]]; then
      if [[ "$REUSE_USER_NAME" == "root" ]]; then
        err "Refusing to reuse 'root' as runtime user."; REUSE_USER_NAME=""
      elif id "$REUSE_USER_NAME" >/dev/null 2>&1; then
        if confirm "Delete user '$REUSE_USER_NAME' entirely (REMOVES HOME)?"; then
          systemctl stop "${REUSE_USER_NAME}.service" 2>/dev/null || true
          systemctl disable "${REUSE_USER_NAME}.service" 2>/dev/null || true
          rm -f "/etc/systemd/system/${REUSE_USER_NAME}.service" 2>/dev/null || true
          userdel -f -r "$REUSE_USER_NAME" || true
          say "Deleted user $REUSE_USER_NAME and removed service if present."
          REUSE_USER_NAME=""
        else
          if confirm "Reuse user '$REUSE_USER_NAME' (will clean ~/.bitoreumcore and local binaries)?"; then
            su - "$REUSE_USER_NAME" -c 'rm -rf ~/.bitoreumcore' || true
            su - "$REUSE_USER_NAME" -c 'rm -f ~/bin/bitoreum{d,-cli,-tx,-qt} 2>/dev/null || true' || true
          else
            REUSE_USER_NAME=""
          fi
        fi
      else
        warn "User '$REUSE_USER_NAME' not found; continuing without reuse."
        REUSE_USER_NAME=""
      fi
    fi

    say "Scanning for systemd services referencing bitoreumd..."
    mapfile -t svc_hits < <(grep -RIl "bitoreumd" /etc/systemd/system /lib/systemd/system 2>/dev/null || true)
    for svc in "${svc_hits[@]}"; do
      svc_name="$(basename "$svc")"
      say "Disabling $svc_name"
      systemctl stop "$svc_name" 2>/dev/null || true
      systemctl disable "$svc_name" 2>/dev/null || true
      if confirm "Delete service $svc_name now?"; then rm -f "$svc"; say "Deleted $svc_name"; fi
    done
  fi
fi

# --- Choose / Create runtime user (NEVER root) ---
TARGET_USER=""
if [[ -n "$REUSE_USER_NAME" ]]; then
  TARGET_USER="$REUSE_USER_NAME"
else
  while true; do
    read -rp "Enter username to run the smartnode under (non-root): " TARGET_USER
    _log "[ANS ] target-user -> $TARGET_USER"
    [[ -z "$TARGET_USER" ]] && { warn "Empty username."; continue; }
    [[ "$TARGET_USER" == "root" ]] && { err "Username cannot be 'root'."; continue; }
    break
  done
  if ! id "$TARGET_USER" >/dev/null 2>&1; then
    say "Creating user '$TARGET_USER' (non-sudo)..."
    while true; do
      read -rsp "Enter password for $TARGET_USER: " PW1; echo
      read -rsp "Confirm password for $TARGET_USER: " PW2; echo
      [[ "$PW1" == "$PW2" ]] && break
      err "Passwords do not match. Try again."
    done
    useradd -m -s /bin/bash "$TARGET_USER"
    echo "${TARGET_USER}:${PW1}" | chpasswd
  else
    say "User '$TARGET_USER' exists; using it."
  fi
fi

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
DATADIR="${USER_HOME}/.bitoreumcore"
CONF_PATH="${DATADIR}/bitoreum.conf"
mkdir -p "$DATADIR"
: > "${DATADIR}/debug.log"

# --- powcache.dat download (IPv4) ---
cd "$DATADIR"
if [[ -n "${powcache_url:-}" && "${powcache_url}" != "null" ]]; then
  say "Downloading powcache.dat ..."
  if ! curl -4 -L --fail --progress-bar "$powcache_url" -o "powcache.dat"; then
    warn "Failed to download powcache.dat from latest release."
  fi
else
  warn "powcache.dat not found in latest release."
  if confirm "Provide a custom powcache.dat URL?"; then
    read -rp "powcache.dat URL: " pcurl
    _log "[ANS ] powcache-url -> ${pcurl:-<empty>}"
    [[ -n "$pcurl" ]] && curl -4 -L --fail --progress-bar "$pcurl" -o "powcache.dat" || warn "Skipped powcache.dat"
  else
    warn "Sync may take much longer without powcache.dat."
  fi
fi

# --- Bootstrap chain data (IPv4, unzip into $DATADIR) ---
BOOTSTRAP_URL="https://bitoreum.cc/bootstrap/bootstrap.zip"
BOOTSTRAP_TMP="/tmp/bootstrap.zip"

say "Bootstrap option: download pre-synced chain data into ${DATADIR}."
if confirm "Download and extract bootstrap.zip now?"; then
  say "Fetching bootstrap.zip from ${BOOTSTRAP_URL} ..."
  mkdir -p "$DATADIR"
  if curl -4 -L --fail --progress-bar "$BOOTSTRAP_URL" -o "$BOOTSTRAP_TMP"; then
    say "Bootstrap archive downloaded to $BOOTSTRAP_TMP"
    (
      cd "$DATADIR"
      if unzip -o "$BOOTSTRAP_TMP" | tee -a "$LOG_FILE"; then
        say "Bootstrap extracted into $DATADIR."
      else
        warn "Unzip reported an issue; continuing without bootstrap."
      fi
    )
    rm -f "$BOOTSTRAP_TMP"
  else
    warn "Failed to download bootstrap.zip from $BOOTSTRAP_URL (IPv4). Skipping bootstrap."
  fi
else
  warn "User declined bootstrap download; initial sync may take longer."
fi

# --- Determine IPs (IPv4 only) ---
PRIVATE_IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
EXTERNAL_IP="$(curl -4 -fsSL https://api.ipify.org || curl -4 -fsSL https://ifconfig.me || echo "")"

if [[ "$is_oracle" == true ]]; then
  say "Oracle mode: PRIVATE=$PRIVATE_IP, EPHEMERAL=$EXTERNAL_IP"
else
  say "Non-Oracle: PRIVATE=$PRIVATE_IP, EXTERNAL=$EXTERNAL_IP"
fi

[[ -z "$PRIVATE_IP"  ]] && read -rp "Enter private IPv4: " PRIVATE_IP
[[ -z "$EXTERNAL_IP" ]] && read -rp "Enter external/ephemeral IPv4 (you may include :port): " EXTERNAL_IP

# --- Ensure externalip includes :15168 ---
ANNOUNCE_PORT=15168
EXTERNAL_IP="${EXTERNAL_IP//[[:space:]]/}"           # strip whitespace
if [[ -n "$EXTERNAL_IP" && "$EXTERNAL_IP" != *:* ]]; then
  EXTERNAL_ANNOUNCE="${EXTERNAL_IP}:${ANNOUNCE_PORT}"
else
  EXTERNAL_ANNOUNCE="$EXTERNAL_IP"                   # already has :port (or empty)
fi
_log "[IP  ] private=$PRIVATE_IP external=$EXTERNAL_ANNOUNCE"

# --- Reuse values from existing conf if present ---
FOUND_RPCPORT=""; FOUND_BLS_PUB=""; FOUND_BLS_PRIV=""
if [[ -f "$CONF_PATH" ]]; then
  say "Existing conf found at $CONF_PATH — attempting to reuse rpcport/BLS values."
  FOUND_RPCPORT="$(awk -F= '$1=="rpcport"{gsub(/[[:space:]]/,"",$2);print $2}' "$CONF_PATH" 2>/dev/null || true)"
  FOUND_BLS_PUB="$(awk -F= '$1=="smartnodePublicKey"{sub(/^[[:space:]]+/,"",$2);sub(/[[:space:]]+$/,"",$2);print $2}' "$CONF_PATH" 2>/dev/null || true)"
  FOUND_BLS_PRIV="$(awk -F= '$1=="smartnodeblsprivkey"{sub(/^[[:space:]]+/,"",$2);sub(/[[:space:]]+$/,"",$2);print $2}' "$CONF_PATH" 2>/dev/null || true)"
  [[ -n "$FOUND_RPCPORT" ]] && say "Reusing rpcport=$FOUND_RPCPORT"
  [[ -n "$FOUND_BLS_PUB"  ]] && say "Reusing smartnodePublicKey (present)"
  [[ -n "$FOUND_BLS_PRIV" ]] && say "Reusing smartnodeblsprivkey (present)"
fi

# --- Smartnode details ---
say "Enter smartnode parameters (from your wallet)."
say "NOTE: CollateralHash = TXID of the collateral transaction."
read -rp "CollateralHash (or leave blank to comment): " COLL_HASH

if [[ -n "$FOUND_BLS_PUB" ]]; then
  BLS_PUB="$FOUND_BLS_PUB"
else
  read -rp "smartnodePublicKey (BLS pub): " BLS_PUB
fi

if [[ -n "$FOUND_BLS_PRIV" ]]; then
  BLS_PRIV="$FOUND_BLS_PRIV"
else
  while true; do
    read -rsp "smartnodeblsprivkey (BLS private) [hidden]: " BLS_PRIV; echo
    [[ -n "$BLS_PRIV" ]] && break
    err "smartnodeblsprivkey is required — cannot continue without it."
  done
fi

read -rp "OwnerAddress (or leave blank to comment): " OWNER_ADDR
read -rp "VotingAddress (or leave blank to comment): " VOTE_ADDR
_log "[SN  ] collected pub/owner/vote; priv present"

# --- RPC port (reuse if found) ---
DEFAULT_RPC_START=8901
get_unused_port(){ local p=$1; while ss -ltn | awk '{print $4}' | grep -qE "[:.]${p}\$"; do p=$((p+1)); done; echo "$p"; }
if [[ -n "$FOUND_RPCPORT" ]]; then
  RPC_PORT="$FOUND_RPCPORT"
else
  RPC_PORT="$(get_unused_port "$DEFAULT_RPC_START")"
fi
say "RPC port: $RPC_PORT"

# --- Write bitoreum.conf ---
say "Writing $CONF_PATH ..."
{
  [[ -n "$COLL_HASH" ]] && echo "CollateralHash=${COLL_HASH}" || echo "#CollateralHash=<User Provided>"
  echo "#ProTXHash="
  [[ -n "$BLS_PUB"  ]] && echo "smartnodePublicKey=${BLS_PUB}" || echo "#smartnodePublicKey=<User Provided>"
  [[ -n "$OWNER_ADDR" ]] && echo "OwnerAddress=${OWNER_ADDR}" || echo "#OwnerAddress=<User Provided>"
  [[ -n "$VOTE_ADDR"  ]] && echo "VotingAddress=${VOTE_ADDR}" || echo "#VotingAddress=<User Provided>"
  echo
  echo "# Basic settings"
  echo "daemon=1"
  echo "listen=1"
  echo "txindex=1"
  echo
  echo "# RPC"
  echo "rpcbind=127.0.0.1"
  echo "rpcallowip=127.0.0.1"
  echo "rpcport=${RPC_PORT}"
  echo
  echo "# Smartnode"
  echo "smartnodeblsprivkey=${BLS_PRIV}"
  echo
  echo "# Networking (IPv4 only)"
  echo "onlynet=ipv4"
  echo "bind=${PRIVATE_IP}"
  echo "externalip=${EXTERNAL_ANNOUNCE}"
} > "$CONF_PATH"

# --- Permissions ---
chown -R "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}"

# --- Systemd service ---
SERVICE_NAME="${TARGET_USER}.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
say "Creating systemd unit ${SERVICE_PATH} ..."
cat > "$SERVICE_PATH" <<EOF
########################################################
##     Bitoreum Smartnode Systemd Service Always Alive #
########################################################
[Unit]
Description=Bitoreum Node Daemon
After=network.target

[Service]
Type=forking
User=${TARGET_USER}
RuntimeDirectory=bitoreum
RuntimeDirectoryMode=0750
Restart=on-failure

# Truncate debug.log on each start
ExecStartPre=/bin/sh -c ': > /home/${TARGET_USER}/.bitoreumcore/debug.log'

ExecStart=/usr/bin/bitoreumd \\
   -datadir=${DATADIR} \\
   -conf=${CONF_PATH} \\
   -daemon
ExecStop=/usr/bin/bitoreum-cli \\
   -datadir=${DATADIR} \\
   -conf=${CONF_PATH} \\
   stop

# Hardening
PrivateTmp=true
ProtectSystem=full
NoNewPrivileges=true
PrivateDevices=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
EOF

# --- Start service ---
say "Reloading systemd, enabling and starting service..."
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" | tee -a "$LOG_FILE"
if systemctl start "${SERVICE_NAME}"; then
  say "Service started."
  mkdir -p /opt/moonstone
  touch /opt/moonstone/users
  if ! grep -Fxq "$TARGET_USER" /opt/moonstone/users 2>/dev/null; then
    echo "$TARGET_USER" >> /opt/moonstone/users
  fi
else
  err "Failed to start service. Check ${DATADIR}/debug.log and 'journalctl -u ${SERVICE_NAME}'."
  exit 1
fi

say "Tailing ${DATADIR}/debug.log (Ctrl+C to stop)..."
tail -n 50 -F "${DATADIR}/debug.log"
