#!/usr/bin/env bash
set -Eeuo pipefail

# ====================================
# - Moonstone - Bitoreum Smartnode Setup Tool
# - Linux only (exits on macOS/Windows)
# - Enforces daemon stopped
# - Installs dialog nano fail2ban unzip curl jq openssl iproute2
# - RAM/swap policy (single /swapfile; skip if >=4GB RAM)
# - Finds latest release (bootstrap.zip, powcache.dat)
# - Downloads matching Linux binary tarball for device (Oracle/Pi special rules)
# - Handles prior failed attempts, user reuse/delete
# - Oracle network nuance + firewall handling
# - Non-Oracle UFW handling (22, 15168) with reload/enable
# - Builds bitoreum.conf (BLS PRIVKEY REQUIRED)
# - Creates systemd service <username>.service
# - Logs successful usernames to /opt/moonstone/users
# - Robust local logging to ./logs/
# ====================================

# --- Logging ---
RUN_DIR="$(pwd -P)"
LOG_DIR="$RUN_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"

_ts() { date +"%Y-%m-%d %H:%M:%S"; }
_log_raw() { echo "[$(_ts)] $*" | tee -a "$LOG_FILE"; }
say()  { _log_raw "[INFO]  $*"; }
warn() { _log_raw "[WARN]  $*"; }
err()  { _log_raw "[ERROR] $*" >&2; }

ask() { local _ans; read -rp "$1" _ans; printf -v "$2" "%s" "$_ans"; _log_raw "[ASK ] $1 -> ${_ans:-<empty>}"; }
confirm() { local _ans; read -rp "$1 [y/N]: " _ans; _log_raw "[ASK?] $1 -> ${_ans:-<empty>}"; [[ "${_ans,,}" == "y" || "${_ans,,}" == "yes" ]]; }

trap 'err "Script failed at line $LINENO."; exit 1' ERR

# --- Guard: Linux only ---
OS_KERNEL="$(uname -s || true)"
case "$OS_KERNEL" in
  Linux) ;;
  Darwin) err "This script only supports Linux. (Detected macOS)"; exit 1 ;;
  MINGW*|MSYS*|CYGWIN*) err "This script only supports Linux. (Detected Windows)"; exit 1 ;;
  *)      err "This script only supports Linux. (Detected: $OS_KERNEL)"; exit 1 ;;
esac

# --- Root/sudo ---
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    warn "Not running as root. Re-executing with sudo..."
    exec sudo -E bash "$0"
  else
    err "Please run as root or with sudo."
    exit 1
  fi
fi

# --- Check daemon stopped ---
say "Has the Bitoreum daemon been stopped? (yes / maybe / no)"
read -rp "> " DAEMON_ANSWER
_log_raw "[ANS ] daemon-stopped -> ${DAEMON_ANSWER:-<empty>}"
case "${DAEMON_ANSWER,,}" in
  yes|y) ;;
  maybe|no|n|"") err "Please stop the daemon first (e.g., 'bitoreum-cli stop') and run this script again."; exit 1 ;;
  *) err "Invalid response. Please answer yes, maybe, or no."; exit 1 ;;
esac

# --- Packages ---
say "Updating apt and installing prerequisites (dialog nano fail2ban unzip curl jq ca-certificates lsb-release openssl iproute2)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y | tee -a "$LOG_FILE"
apt-get install -y dialog nano fail2ban unzip curl jq ca-certificates lsb-release openssl iproute2 | tee -a "$LOG_FILE"

# --- Memory & Swap checks ---
mem_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo || echo 0)
swap_kb=$(awk '/SwapTotal:/ {print $2}' /proc/meminfo || echo 0)
mem_mb=$(( mem_kb / 1024 ))
swap_mb=$(( swap_kb / 1024 ))

say "Detected RAM: ${mem_mb} MB, Swap: ${swap_mb} MB"

if (( mem_mb >= 4096 )); then
  say ">= 4GB RAM detected; skipping swap configuration."
else
  meets_minimum=false
  if   (( mem_mb >= 2048 )); then meets_minimum=true
  elif (( mem_mb >= 1024 )) && (( swap_mb >= 2048 )); then meets_minimum=true
  fi

  if [[ "$meets_minimum" == false ]]; then
    if (( mem_mb < 700 )); then err "Minimum resources not met (need >=700MB RAM at least). Aborting."; exit 1; fi
    target_swap_mb=2048
    if (( mem_mb >= 700 && mem_mb < 1000 )); then target_swap_mb=3072; fi

    say "Configuring a single swapfile at /swapfile of size ${target_swap_mb} MB (removing any existing swap entries)."
    swapoff -a || true
    if grep -Eq '^[^#].*\s+swap\s+' /etc/fstab; then cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"; sed -ri '/\s+swap\s+/d' /etc/fstab; fi

    blocks=$(( target_swap_mb * 1024 )) # 1k blocks
    bash -c "
      set -Eeuo pipefail
      dd if=/dev/zero of=/swapfile bs=1k count=${blocks} status=progress
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      echo '/swapfile swap swap auto 0 0' | tee -a /etc/fstab >/dev/null
      sysctl -w vm.swappiness=10
      if ! grep -q '^vm.swappiness' /etc/sysctl.conf 2>/dev/null; then
        echo 'vm.swappiness = 10' | tee -a /etc/sysctl.conf >/dev/null
      else
        sed -ri 's/^vm\.swappiness.*/vm.swappiness = 10/' /etc/sysctl.conf
      fi
    " | tee -a "$LOG_FILE"
    say "Swap configured."
  else
    say "Memory requirements already satisfied."
  fi
fi

# --- Versions & architecture ---
BITD_PATH="/usr/bin/bitoreumd"
BITCLI_PATH="/usr/bin/bitoreum-cli"
bitd_ver=""; bitcli_ver=""
if [[ -x "$BITD_PATH" ]]; then bitd_ver="$("$BITD_PATH" --version 2>/dev/null | head -n1 || true)"; fi
if [[ -x "$BITCLI_PATH" ]]; then bitcli_ver="$("$BITCLI_PATH" --version 2>/dev/null | head -n1 || true)"; fi
say "Detected versions:"
say "  bitoreumd:    ${bitd_ver:-<not found>}"
say "  bitoreum-cli: ${bitcli_ver:-<not found>}"

machine=$(uname -m)
case "$machine" in
  x86_64) ARCH_FAMILY="x86_64"; ARCH_LABEL="x86_64" ;;
  i386|i686) ARCH_FAMILY="x86";  ARCH_LABEL="i686"   ;;
  aarch64|arm64) ARCH_FAMILY="ARM"; ARCH_LABEL="aarch64" ;;
  armv7l|armv6l|armv7) ARCH_FAMILY="ARM"; ARCH_LABEL="armhf" ;;
  *) ARCH_FAMILY="$machine"; ARCH_LABEL="$machine" ;;
esac
say "Architecture: ${ARCH_FAMILY} (${ARCH_LABEL})"

# --- Hardware detection (Ampere / Raspberry Pi) ---
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

# --- Oracle VPS special handling flag ---
is_oracle=false
if confirm "Is this an Oracle VPS instance?"; then is_oracle=true; fi
say "Oracle mode: $is_oracle"

# --- Fail2Ban Setup ---
say "Configuring Fail2Ban for SSH (maxretry=3)..."
if [[ -f /etc/fail2ban/jail.local ]]; then cp -a /etc/fail2ban/jail.local "/etc/fail2ban/jail.local.bak.$(date +%s)"; fi
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
say "Fail2Ban is configured and restarted."

# --- Firewall setup ---
if [[ "$is_oracle" == true ]]; then
  say "Oracle VPS detected — updating iptables rules directly."
  iptables_rule_file="/etc/iptables/rules.v4"
  if ! dpkg -s iptables-persistent >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent; fi
  iptables-save > "$iptables_rule_file"
  if ! grep -q -- "-A INPUT -p tcp -m state --state NEW -m tcp --dport 15168 -j ACCEPT" "$iptables_rule_file"; then
    if grep -q -- "-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT" "$iptables_rule_file"; then
      say "Inserting Bitoreum port (15168) rule after SSH (22)."
      sed -i '/-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT/a -A INPUT -p tcp -m state --state NEW -m tcp --dport 15168 -j ACCEPT' "$iptables_rule_file"
    else
      warn "SSH rule not found; appending Bitoreum port rule."
      echo "-A INPUT -p tcp -m state --state NEW -m tcp --dport 15168 -j ACCEPT" >> "$iptables_rule_file"
    fi
    iptables-restore < "$iptables_rule_file"
    if command -v netfilter-persistent >/dev/null 2>&1; then netfilter-persistent save; fi
  else
    say "Iptables already allows port 15168."
  fi
else
  say "Non-Oracle VPS detected — configuring ufw."
  if ! command -v ufw >/dev/null 2>&1; then apt-get install -y ufw; fi
  ufw allow 22/tcp
  ufw allow 15168/tcp
  if ! ufw status | grep -q "^Status: active"; then
    say "Enabling ufw..."; ufw --force enable
  else
    say "Reloading ufw with new rules..."; ufw reload
  fi
  ufw status verbose | tee -a "$LOG_FILE"
fi

# --- Latest release (GitHub API) ---
say "Querying latest Bitoreum release info from GitHub..."
LATEST_JSON="$(curl -fsSL https://api.github.com/repos/Nikovash/bitoreum/releases/latest || true)"
LATEST_TAG="$(jq -r '.tag_name // empty' <<<"$LATEST_JSON" || true)"
ASSETS_JSON="$(jq -r '.assets // []' <<<"$LATEST_JSON" || echo '[]')"
say "Latest tag: ${LATEST_TAG:-<unknown>}"

bootstrap_url="$(jq -r '.[] | select(.name|test("bootstrap\\.zip$";"i")) | .browser_download_url' <<<"$ASSETS_JSON" | head -n1 || true)"
powcache_url="$(jq -r '.[] | select(.name|test("powcache\\.dat$";"i")) | .browser_download_url' <<<"$ASSETS_JSON" | head -n1 || true)"
say "bootstrap.zip: ${bootstrap_url:-<not found>}"
say "powcache.dat: ${powcache_url:-<not found>}"

# Log available assets to help debugging
say "Available assets in latest release:"
jq -r '.[].name' <<<"$ASSETS_JSON" | sed 's/^/  - /' | tee -a "$LOG_FILE"

# --- Versions mismatch info ---
mismatch=true
if [[ -n "$LATEST_TAG" && -n "$bitd_ver" && -n "$bitcli_ver" ]]; then
  if grep -q "$LATEST_TAG" <<<"$bitd_ver" && grep -q "$LATEST_TAG" <<<"$bitcli_ver"; then mismatch=false; fi
fi
[[ "$mismatch" == true ]] && warn "Installed versions differ from latest (${LATEST_TAG:-unknown}) or from each other."

# --- Arch-aware binary download (flexible matching; install to /usr/bin) ---
say "Selecting Linux binary asset for this hardware..."
# Build a prioritized list of regexes. DO NOT require the tag in the filename (some releases omit it in the asset name).
declare -a REGEXES=()

lower_arch_token() {
  case "$1" in
    aarch64) echo '(aarch64|arm[_-]?64)';;
    armhf)   echo '(armhf|arm[_-]?32|armv7|arm32)';;
    x86_64)  echo '(x86[_-]?64|amd64|64bit)';;
    i686)    echo '(x86[_-]?32|i[3-6]86|32bit)';;
    *)       echo '(linux)';;
  esac
}

ARCH_TOKEN="$(lower_arch_token "$ARCH_LABEL")"

# Raspberry Pi < 4 → force ARM_32
force_arm32=false
if [[ "$is_pi" == true && "$is_pi4" == false ]]; then
  warn "Raspberry Pi model < 4 detected — forcing ARM_32 build; this may be unstable."
  force_arm32=true
  ARCH_TOKEN='(armhf|arm[_-]?32|armv7|arm32)'
fi

# Highest priority: Oracle Ampere on ARM64 when applicable
if [[ "$ARCH_LABEL" == "aarch64" && ( "$is_ampere" == true || "$is_oracle" == true ) && "$force_arm32" == false ]]; then
  REGEXES+=("^.*(linux|ubuntu).*(oracle|ampere).*(arm[_-]?64|aarch64).*\\.tar\\.gz$")
fi
# Pi4+ special tarball
if [[ "$ARCH_LABEL" == "aarch64" && "$is_pi4" == true && "$force_arm32" == false ]]; then
  REGEXES+=("^.*(linux|ubuntu).*(pi4).*?(arm[_-]?64|aarch64).*\\.tar\\.gz$")
fi
# Generic for detected arch
REGEXES+=("^.*(linux|ubuntu).*$ARCH_TOKEN.*\\.tar\\.gz$")
# Super-generic fallback to any linux tarball
REGEXES+=("^.*linux.*\\.tar\\.gz$")

pick_asset_by_regex() {
  local rx="$1"
  jq -r --arg rx "$rx" '.[] | select(.name|test($rx; "i")) | .browser_download_url' <<<"$ASSETS_JSON" | head -n1
}

BINARY_URL=""
for rx in "${REGEXES[@]}"; do
  BINARY_URL="$(pick_asset_by_regex "$rx")"
  if [[ -n "$BINARY_URL" && "$BINARY_URL" != "null" ]]; then
    say "Matched asset with regex: $rx"
    break
  fi
done

if [[ -z "${BINARY_URL:-}" || "${BINARY_URL}" == "null" ]]; then
  err "No matching Linux binary asset found for this hardware. Check the asset list above; you may need to install from source."
fi

say "Downloading binary tarball: ${BINARY_URL}"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD" || true' EXIT
ARCHIVE_PATH="$TMPD/bitoreum.tar.gz"
if ! curl -fSLo "$ARCHIVE_PATH" "$BINARY_URL"; then
  err "Failed to download the Bitoreum binary tarball."
fi

say "Extracting tarball..."
mkdir -p "$TMPD/extract"
tar -xzf "$ARCHIVE_PATH" -C "$TMPD/extract"

find_and_install () {
  local bin_name="$1"
  local found
  found="$(find "$TMPD/extract" -type f -name "$bin_name" -perm -111 | head -n1 || true)"
  if [[ -z "$found" ]]; then err "Executable $bin_name not found inside the archive."; fi
  say "Installing $bin_name -> /usr/bin/$bin_name"
  install -m 0755 -T "$found" "/usr/bin/$bin_name"
}
find_and_install "bitoreumd"
find_and_install "bitoreum-cli"
hash -r || true
if ! command -v bitoreumd >/dev/null 2>&1; then err "bitoreumd not found on PATH after install."; fi
if ! command -v bitoreum-cli >/dev/null 2>&1; then err "bitoreum-cli not found on PATH after install."; fi
say "Binary install complete."

# --- Prior attempt detection & cleanup path ---
say "Have you (a) successfully installed a smartnode already, or (b) tried and failed?"
say "Enter one: success / failed / new"
read -rp "> " INSTALL_STATE
INSTALL_STATE="${INSTALL_STATE,,}"
_log_raw "[ANS ] install-state -> ${INSTALL_STATE:-<empty>}"

say "Searching for existing bitoreum.conf files (this may take a moment)..."
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
    if (( ${#FOUND_CONFS[@]} > 0 )); then say "If one of the above paths belongs to another user, you can enter that username to clean it."; fi
    ask "Enter previous username to reuse (or press Enter to skip): " REUSE_USER_NAME || true
    REUSE_USER_NAME="${REUSE_USER_NAME:-}"
    if [[ -n "$REUSE_USER_NAME" ]]; then
      if [[ "$REUSE_USER_NAME" == "root" ]]; then
        err "Refusing to reuse 'root' as a runtime user."; REUSE_USER_NAME=""
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
    _log_raw "[ANS ] target-user -> $TARGET_USER"
    if [[ -z "$TARGET_USER" ]]; then warn "Empty username."; continue; fi
    if [[ "$TARGET_USER" == "root" ]]; then err "Username cannot be 'root'."; continue; fi
    break
  done

  if ! id "$TARGET_USER" >/dev/null 2>&1; then
    say "Creating user '$TARGET_USER' (non-sudo)..."
    while true; do
      read -rsp "Enter password for $TARGET_USER: " PW1; echo
      read -rsp "Confirm password for $TARGET_USER: " PW2; echo
      if [[ "$PW1" == "$PW2" ]]; then break; fi
      err "Passwords do not match. Try again."
    done
    useradd -m -s /bin/bash "$TARGET_USER"
    echo "${TARGET_USER}:${PW1}" | chpasswd
  else
    say "User '$TARGET_USER' already exists; will use it."
  fi
fi

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
DATADIR="${USER_HOME}/.bitoreumcore"
mkdir -p "$DATADIR"
touch "${DATADIR}/debug.log"

# --- Download powcache.dat & bootstrap.zip (with fallbacks) ---
cd "$DATADIR"

if [[ -n "${powcache_url:-}" ]]; then
  say "Downloading powcache.dat..."
  if ! curl -fSLo powcache.dat "$powcache_url"; then warn "Failed to download powcache.dat from latest release."; fi
else
  warn "No powcache.dat found in latest release."
  if confirm "Provide a custom powcache.dat URL?"; then
    read -rp "powcache.dat URL: " pcurl
    _log_raw "[ANS ] powcache-url -> ${pcurl:-<empty>}"
    if [[ -n "$pcurl" ]]; then if ! curl -fSLo powcache.dat "$pcurl"; then warn "Failed to download powcache.dat"; fi
    else warn "Skipped powcache.dat"; fi
  else
    warn "Initial sync may take up to ~72 hours without powcache.dat."
  fi
fi

BOOT_TMP=""
try_bootstrap_fallback () {
  local url
  for url in \
    "https://bitoreum.cc/depends/bootstrap.zip" \
    "https://www.bitoreum.cc/depends/bootstrap.zip" \
    "https://bitoruem.cc/depends/bootstrap.zip"
  do
    say "Attempting fallback bootstrap from $url ..."
    if curl -fSLo bootstrap.zip "$url"; then BOOT_TMP="bootstrap.zip"; return 0; fi
  done
  return 1
}

if [[ -n "${bootstrap_url:-}" ]]; then
  say "Downloading bootstrap.zip..."
  if curl -fSLo bootstrap.zip "$bootstrap_url"; then BOOT_TMP="bootstrap.zip"
  else warn "Failed to download bootstrap.zip from latest release."; try_bootstrap_fallback || true
  fi
else
  warn "No bootstrap.zip found in latest release."
  try_bootstrap_fallback || true
  if [[ -z "$BOOT_TMP" ]]; then
    if confirm "Provide a custom bootstrap.zip URL?"; then
      read -rp "bootstrap.zip URL: " bcurl
      _log_raw "[ANS ] bootstrap-url -> ${bcurl:-<empty>}"
      if [[ -n "$bcurl" ]]; then if curl -fSLo bootstrap.zip "$bcurl"; then BOOT_TMP="bootstrap.zip"; else warn "Failed to download bootstrap.zip"; fi
      else warn "Skipped bootstrap.zip"; fi
    else
      warn "Sync without bootstrap may take 30 min to several hours."
    fi
  fi
fi

if [[ -f "$BOOT_TMP" ]]; then
  say "Unzipping bootstrap..."
  if ! unzip -o "$BOOT_TMP" | tee -a "$LOG_FILE"; then warn "Unzip failed (continuing)."; fi
fi

# --- Determine IPs (IPv4 only) ---
PRIVATE_IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
EXTERNAL_IP="$(curl -fsSL https://api.ipify.org || curl -fsSL https://ifconfig.me || echo "")"

if [[ "$is_oracle" == true ]]; then
  say "Oracle mode: using PRIVATE=$PRIVATE_IP and EPHEMERAL=$EXTERNAL_IP"
else
  say "Non-Oracle: PRIVATE=$PRIVATE_IP, EXTERNAL=$EXTERNAL_IP"
fi

if [[ -z "$PRIVATE_IP" ]]; then read -rp "Enter private IPv4: " PRIVATE_IP; fi
if [[ -z "$EXTERNAL_IP" ]]; then read -rp "Enter external/ephemeral IPv4: " EXTERNAL_IP; fi
_log_raw "[IP  ] private=$PRIVATE_IP external=$EXTERNAL_IP"

# --- Collect smartnode details (BLS private REQUIRED) ---
say "Enter smartnode parameters (from your wallet holding the funds)."
say "NOTE: CollateralHash = TXID of the collateral transaction."
read -rp "CollateralHash (or leave blank to comment out): " COLL_HASH
read -rp "smartnodePublicKey (BLS pub): " BLS_PUB
while true; do
  read -rsp "smartnodeblsprivkey (BLS private) [hidden]: " BLS_PRIV; echo
  if [[ -n "$BLS_PRIV" ]]; then break; fi
  err "smartnodeblsprivkey is required — cannot continue without it."
done
read -rp "OwnerAddress (or leave blank to comment out): " OWNER_ADDR
read -rp "VotingAddress (or leave blank to comment out): " VOTE_ADDR
_log_raw "[SN  ] got pub/owner/vote; priv (required) entered"

# --- RPC port selection ---
DEFAULT_RPC_START=8901
get_unused_port() { local p=$1; while ss -ltn | awk '{print $4}' | grep -qE "[:.]${p}\$"; do p=$((p+1)); done; echo "$p"; }
RPC_PORT="$(get_unused_port "$DEFAULT_RPC_START")"
say "Selected unused RPC port: $RPC_PORT"

# --- Write bitoreum.conf ---
CONF_PATH="${DATADIR}/bitoreum.conf"
say "Writing ${CONF_PATH} ..."
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
  echo "# RPC credentials"
  echo "rpcbind=127.0.0.1"
  echo "rpcallowip=127.0.0.1"
  echo "rpcport=${RPC_PORT}"
  echo
  echo "# Smartnode Settings"
  echo "smartnodeblsprivkey=${BLS_PRIV}"
  echo
  echo "# Define IP (IPv4 only)"
  echo "onlynet=ipv4"
  echo "bind=${PRIVATE_IP}"
  echo "externalip=${EXTERNAL_IP}"
} > "$CONF_PATH"

# --- Permissions ---
chown -R "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}"

# --- Systemd service ---
SERVICE_NAME="${TARGET_USER}.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
say "Creating systemd service ${SERVICE_PATH} ..."
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
ExecStart=/usr/bin/bitoreumd \\
   -datadir=${DATADIR} \\
   -conf=${CONF_PATH} \\
   -daemon
ExecStop=/usr/bin/bitoreum-cli \\
   -datadir=${DATADIR} \\
   -conf=${CONF_PATH} \\
   stop

# Recommended hardening
PrivateTmp=true
ProtectSystem=full
NoNewPrivileges=true
PrivateDevices=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
EOF

# Reload, enable, start
say "Reloading systemd, enabling and starting service..."
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" | tee -a "$LOG_FILE"
if systemctl start "${SERVICE_NAME}"; then
  say "Service started."
  mkdir -p /opt/moonstone
  touch /opt/moonstone/users
  if ! grep -Fxq "$TARGET_USER" /opt/moonstone/users 2>/dev/null; then echo "$TARGET_USER" >> /opt/moonstone/users; fi
else
  err "Failed to start service. Check ${DATADIR}/debug.log and 'journalctl -u ${SERVICE_NAME}'."
  exit 1
fi

say "Tailing ${DATADIR}/debug.log (Ctrl+C to stop)..."
tail -n 50 -F "${DATADIR}/debug.log"
