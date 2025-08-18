#!/usr/bin/env bash
set -Eeuo pipefail

# ===========================================
# rock_grind.sh — Binary Suggestion Helper  =
# ===========================================
# - Detects arch + hints (Oracle/Ampere,
#   Raspberry Pi 4+)
# - Reads latest GitHub release assets
# - Suggests best-matching Linux tarball to
#   download manually
# - Prints top N suggestions
#   (default 3; change with -n N)
#
# Usage:
#   ./rock_grind.sh
#   ./rock_grind.sh -n 5
#
# Requires: curl, jq
# ===========================================

say(){ echo "[INFO]  $*"; }
warn(){ echo "[WARN]  $*"; }
err(){ echo "[ERROR] $*" >&2; exit 1; }

# --- Args ---
TOP_N=3
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--num)
      shift
      TOP_N="${1:-3}"
      shift || true
      ;;
    *)
      warn "Unknown arg: $1"; shift ;;
  esac
done

# --- Deps ---
command -v curl >/dev/null 2>&1 || err "curl is required."
command -v jq   >/dev/null 2>&1 || err "jq is required."

# --- Arch detect ---
machine=$(uname -m)
case "$machine" in
  x86_64) ARCH_LABEL="x86_64" ;;
  i386|i686) ARCH_LABEL="i686" ;;
  aarch64|arm64) ARCH_LABEL="aarch64" ;;
  armv7l|armv6l|armv7) ARCH_LABEL="armhf" ;;
  *) ARCH_LABEL="$machine" ;;
esac
say "Detected architecture: ${ARCH_LABEL}"

# --- Hardware hints (Ampere/Oracle, Raspberry Pi) ---
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

# --- Oracle auto-detect ---
has_cmd(){ command -v "$1" >/dev/null 2>&1; }
detect_oracle() {
  local hits=0 v
  for f in /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name /sys/class/dmi/id/board_vendor /sys/class/dmi/id/bios_vendor; do
    if [[ -r "$f" ]]; then
      v="$(tr -d '\0' <"$f" | tr '[:upper:]' '[:lower:]')"
      if grep -qE 'oracle|oci|oracle cloud' <<<"$v"; then ((hits++)); break; fi
    fi
  done
  if [[ -r /var/lib/cloud/instance/datasource ]]; then
    v="$(tr -d '\0' </var/lib/cloud/instance/datasource | tr '[:upper:]' '[:lower:]')"
    if grep -qE 'oracle|oci' <<<"$v"; then ((hits++)); fi
  fi
  if dpkg -l 2>/dev/null | awk '{print $2}' | grep -q '^oracle-cloud-agent$'; then ((hits++)); fi
  if has_cmd curl && curl -4 -m 1 -sS --noproxy '*' http://169.254.169.254/opc/v1/ >/dev/null; then ((hits++)); fi
  [[ $hits -ge 2 ]]
}
is_oracle=false
if detect_oracle; then is_oracle=true; fi
say "Oracle mode (auto-detected): ${is_oracle}"

# --- Fetch latest release assets ---
say "Querying latest Bitoreum release (GitHub)..."
LATEST_JSON="$(curl -4 -fsSL https://api.github.com/repos/Nikovash/bitoreum/releases/latest || true)"
[[ -n "$LATEST_JSON" ]] || err "Failed to fetch latest release metadata from GitHub."
LATEST_TAG="$(jq -r '.tag_name // empty' <<<"$LATEST_JSON" || true)"
ASSETS_JSON="$(jq -r '.assets // []' <<<"$LATEST_JSON" || echo '[]')"
[[ "$ASSETS_JSON" != "[]" ]] || err "No assets found in latest release."
say "Latest tag: ${LATEST_TAG:-<unknown>}"

# --- Arch token helper ---
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

# Pi < 4: force ARM_32 token
force_arm32=false
if [[ "$is_pi" == true && "$is_pi4" == false ]]; then
  warn "Raspberry Pi < 4 detected — preferring ARM_32 builds."
  force_arm32=true
  ARCH_TOKEN='(armhf|arm[_-]?32|armv7|arm32)'
fi

# --- Build ordered regex list (with optional 'Release' in the name) ---
# Accept names that might contain "Release" in any sensible position.
REL_OPT='([_-]?release[_-]?)?'     # optional "Release" (case-insensitive via jq flag)

declare -a REGEXES=()

# Strong preferences first (when on ARM64)
if [[ "$ARCH_LABEL" == "aarch64" && "$force_arm32" == false ]]; then
  if [[ "$is_ampere" == true || "$is_oracle" == true ]]; then
    REGEXES+=("^.*(linux|ubuntu).*(oracle|ampere).*(arm[_-]?64|aarch64).*$REL_OPT.*\\.tar\\.gz$")
  fi
  if [[ "$is_pi4" == true ]]; then
    REGEXES+=("^.*(linux|ubuntu).*pi4.*(arm[_-]?64|aarch64).*$REL_OPT.*\\.tar\\.gz$")
  fi
fi

# Generic per-arch candidates (cover both Generic-Linux_ and general linux/ubuntu names)
case "$ARCH_LABEL" in
  aarch64)
    REGEXES+=("^bitoreum-Generic-Linux_ARM_64$REL_OPT.*\\.tar\\.gz$")
    ;;
  armhf)
    REGEXES+=("^bitoreum-Generic-Linux_ARM_32$REL_OPT.*\\.tar\\.gz$")
    ;;
  x86_64)
    REGEXES+=("^bitoreum-Generic-Linux_x86_64$REL_OPT.*\\.tar\\.gz$")
    ;;
  i686)
    REGEXES+=("^bitoreum-Generic-Linux_x86_32$REL_OPT.*\\.tar\\.gz$")
    ;;
esac

# Broad linux/ubuntu per-arch catch-all
REGEXES+=("^.*(linux|ubuntu).*$ARCH_TOKEN.*$REL_OPT.*\\.tar\\.gz$")
# Final fallback: any linux tar.gz
REGEXES+=("^.*linux.*\\.tar\\.gz$")

# --- Matching helper (returns "name|url" lines) ---
match_assets() {
  local rx="$1"
  jq -r --arg rx "$rx" '
    .[] | select(.name | test($rx; "i")) |
    "\(.name)|\(.browser_download_url)"
  ' <<<"$ASSETS_JSON"
}

# --- Collect ordered unique suggestions ---
declare -A seen
declare -a picks
for rx in "${REGEXES[@]}"; do
  while IFS='|' read -r name url; do
    [[ -z "$name" || -z "$url" ]] && continue
    # De-dupe by URL
    if [[ -z "${seen["$url"]+x}" ]]; then
      seen["$url"]=1
      picks+=("$name|$url")
    fi
  done < <(match_assets "$rx")
done

if (( ${#picks[@]} == 0 )); then
  err "No suitable Linux tarball matched for your hardware from the latest release assets."
fi

# --- Output ---
say "Recommended download(s) for your hardware:"
count=0
for item in "${picks[@]}"; do
  name="${item%%|*}"
  url="${item#*|}"
  if (( count == 0 )); then
    echo
    echo "Top pick:"
    echo "  Name: $name"
    echo "  URL : $url"
    echo
    echo "Alternates:"
  else
    echo "  - $name"
    echo "    $url"
  fi
  ((count++))
  (( count >= TOP_N )) && break
done

# Friendly footer
echo
say "If none of these download correctly, check the release assets naming or build from source."
