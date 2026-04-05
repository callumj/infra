#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_URL="${BOOTSTRAP_URL:-https://raw.githubusercontent.com/callumj/infra/main/bootstrap-callumj.sh}"
TARGET_USER="${TARGET_USER:-callumj}"
KEYS_URL="${KEYS_URL:-https://github.com/callumj.keys}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
VICTORIALOGS_SCHEME="${VICTORIALOGS_SCHEME:-}"
VICTORIALOGS_HOST="${VICTORIALOGS_HOST:-}"
VICTORIALOGS_PORT="${VICTORIALOGS_PORT:-}"
DEBIAN_JOURNALD_INITIAL_POSITION="${DEBIAN_JOURNALD_INITIAL_POSITION:-}"

STARTED_HERE=()
SUCCEEDED=()
FAILED=()

log() {
  printf '[proxmox-bootstrap] %s\n' "$*"
}

warn() {
  printf '[proxmox-bootstrap] WARN: %s\n' "$*" >&2
}

fatal() {
  printf '[proxmox-bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    fatal "run as root on the Proxmox host"
  fi
}

require_pct() {
  command -v pct >/dev/null 2>&1 || fatal "pct not found; run this on a Proxmox host"
}

usage() {
  cat <<'EOF'
Usage:
  bootstrap-proxmox-lxcs.sh [CTID ...]

Behavior:
  - With no CTIDs, processes every LXC returned by `pct list`
  - Stopped containers are started temporarily and returned to stopped state
  - Runs the remote bootstrap script as root inside each container

Environment:
  BOOTSTRAP_URL  Raw URL for the guest bootstrap script
  TARGET_USER    User to create inside each guest
  KEYS_URL       SSH public keys URL for authorized_keys
  GITHUB_TOKEN   Optional token for fetching a private GitHub raw URL
  VICTORIALOGS_SCHEME  Optional passthrough for log shipper bootstrap
  VICTORIALOGS_HOST    Optional passthrough for log shipper bootstrap
  VICTORIALOGS_PORT    Optional passthrough for log shipper bootstrap
  DEBIAN_JOURNALD_INITIAL_POSITION  Optional passthrough for log shipper bootstrap
EOF
}

cleanup() {
  local ctid

  for ctid in "${STARTED_HERE[@]}"; do
    if pct status "$ctid" 2>/dev/null | grep -q "status: running"; then
      log "stopping CT $ctid to restore original state"
      pct stop "$ctid" >/dev/null 2>&1 || warn "failed to stop CT $ctid during cleanup"
    fi
  done
}

list_ctids() {
  pct list | awk 'NR > 1 { print $1 }'
}

ct_is_running() {
  local ctid="$1"
  pct status "$ctid" 2>/dev/null | grep -q "status: running"
}

start_ct_if_needed() {
  local ctid="$1"

  if ct_is_running "$ctid"; then
    return 0
  fi

  log "starting CT $ctid"
  pct start "$ctid"
  STARTED_HERE+=("$ctid")
}

restore_ct_if_needed() {
  local ctid="$1"
  local kept_running=()
  local started_ct

  for started_ct in "${STARTED_HERE[@]}"; do
    if [[ "$started_ct" != "$ctid" ]]; then
      kept_running+=("$started_ct")
    fi
  done

  if [[ ${#kept_running[@]} -ne ${#STARTED_HERE[@]} ]]; then
    if ct_is_running "$ctid"; then
      log "stopping CT $ctid to restore original state"
      pct stop "$ctid"
    fi
    STARTED_HERE=("${kept_running[@]}")
  fi
}

run_bootstrap_in_ct() {
  local ctid="$1"
  local remote_script

  IFS= read -r -d '' remote_script <<'EOF' || true
set -eu

detect_pm() {
  for pm in apt-get dnf yum zypper apk pacman; do
    if command -v "$pm" >/dev/null 2>&1; then
      printf '%s\n' "$pm"
      return 0
    fi
  done
  return 1
}

install_pkgs() {
  pm="$1"
  shift

  case "$pm" in
    apt-get)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    zypper)
      zypper --non-interactive install --no-confirm "$@"
      ;;
    apk)
      apk add --no-cache "$@"
      ;;
    pacman)
      pacman -Sy --noconfirm "$@"
      ;;
    *)
      echo "unsupported package manager: $pm" >&2
      exit 1
      ;;
  esac
}

ensure_guest_prereqs() {
  need_bash=0
  need_fetcher=0

  if ! command -v bash >/dev/null 2>&1; then
    need_bash=1
  fi

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    need_fetcher=1
  fi

  if [ "$need_bash" -eq 0 ] && [ "$need_fetcher" -eq 0 ]; then
    return 0
  fi

  pm="$(detect_pm)" || {
    echo "no supported package manager found in container" >&2
    exit 1
  }

  set --
  if [ "$need_bash" -eq 1 ]; then
    set -- "$@" bash
  fi
  if [ "$need_fetcher" -eq 1 ]; then
    set -- "$@" curl
  fi

  install_pkgs "$pm" "$@"
}

run_bootstrap() {
  tmp_script="$(mktemp)"
  trap 'rm -f "$tmp_script"' EXIT

  if command -v curl >/dev/null 2>&1; then
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      curl -4fsSL --retry 5 --retry-delay 2 -H "Authorization: Bearer ${GITHUB_TOKEN}" "${BOOTSTRAP_URL}" -o "${tmp_script}"
    else
      curl -4fsSL --retry 5 --retry-delay 2 "${BOOTSTRAP_URL}" -o "${tmp_script}"
    fi
    env TARGET_USER="${TARGET_USER}" KEYS_URL="${KEYS_URL}" VICTORIALOGS_SCHEME="${VICTORIALOGS_SCHEME:-}" VICTORIALOGS_HOST="${VICTORIALOGS_HOST:-}" VICTORIALOGS_PORT="${VICTORIALOGS_PORT:-}" DEBIAN_JOURNALD_INITIAL_POSITION="${DEBIAN_JOURNALD_INITIAL_POSITION:-}" bash "${tmp_script}"
    rm -f "${tmp_script}"
    trap - EXIT
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      wget -4 -qO "${tmp_script}" --tries=5 --waitretry=2 --header="Authorization: Bearer ${GITHUB_TOKEN}" "${BOOTSTRAP_URL}"
    else
      wget -4 -qO "${tmp_script}" --tries=5 --waitretry=2 "${BOOTSTRAP_URL}"
    fi
    env TARGET_USER="${TARGET_USER}" KEYS_URL="${KEYS_URL}" VICTORIALOGS_SCHEME="${VICTORIALOGS_SCHEME:-}" VICTORIALOGS_HOST="${VICTORIALOGS_HOST:-}" VICTORIALOGS_PORT="${VICTORIALOGS_PORT:-}" DEBIAN_JOURNALD_INITIAL_POSITION="${DEBIAN_JOURNALD_INITIAL_POSITION:-}" bash "${tmp_script}"
    rm -f "${tmp_script}"
    trap - EXIT
    return
  fi

  echo "no supported HTTP client found in container" >&2
  exit 1
}

ensure_guest_prereqs
run_bootstrap
EOF

  pct exec "$ctid" -- env \
    "BOOTSTRAP_URL=$BOOTSTRAP_URL" \
    "TARGET_USER=$TARGET_USER" \
    "KEYS_URL=$KEYS_URL" \
    "GITHUB_TOKEN=$GITHUB_TOKEN" \
    "VICTORIALOGS_SCHEME=$VICTORIALOGS_SCHEME" \
    "VICTORIALOGS_HOST=$VICTORIALOGS_HOST" \
    "VICTORIALOGS_PORT=$VICTORIALOGS_PORT" \
    "DEBIAN_JOURNALD_INITIAL_POSITION=$DEBIAN_JOURNALD_INITIAL_POSITION" \
    sh -lc "$remote_script"
}

main() {
  local ctids=()
  local ctid

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  require_root
  require_pct

  trap cleanup EXIT

  if [[ "$#" -gt 0 ]]; then
    ctids=("$@")
  else
    mapfile -t ctids < <(list_ctids)
  fi

  [[ "${#ctids[@]}" -gt 0 ]] || fatal "no LXCs found"

  for ctid in "${ctids[@]}"; do
    log "processing CT $ctid"

    if ! pct config "$ctid" >/dev/null 2>&1; then
      warn "skipping CT $ctid because it does not exist"
      FAILED+=("$ctid")
      continue
    fi

    start_ct_if_needed "$ctid"

    if run_bootstrap_in_ct "$ctid"; then
      log "bootstrap succeeded for CT $ctid"
      SUCCEEDED+=("$ctid")
    else
      warn "bootstrap failed for CT $ctid"
      FAILED+=("$ctid")
    fi

    restore_ct_if_needed "$ctid"
  done

  log "successful CTs: ${SUCCEEDED[*]:-none}"

  if [[ "${#FAILED[@]}" -gt 0 ]]; then
    warn "failed CTs: ${FAILED[*]}"
    exit 1
  fi
}

main "$@"
