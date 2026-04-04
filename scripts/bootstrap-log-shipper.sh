#!/bin/sh
set -eu

GITHUB_REPO="${GITHUB_REPO:-callumj/infra}"
GITHUB_REF="${GITHUB_REF:-main}"
CHECKOUT_DIR="${CHECKOUT_DIR:-/opt/infra}"
PLAYBOOK_PATH="${PLAYBOOK_PATH:-playbooks/log-shipper.yml}"
VICTORIALOGS_SCHEME="${VICTORIALOGS_SCHEME:-http}"
VICTORIALOGS_HOST="${VICTORIALOGS_HOST:-192.168.52.124}"
VICTORIALOGS_PORT="${VICTORIALOGS_PORT:-9428}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

log() {
  printf '[log-shipper-bootstrap] %s\n' "$*"
}

fatal() {
  printf '[log-shipper-bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fatal "run as root, for example: curl -fsSL <raw-url> | sudo sh"
  fi
}

detect_pkg_manager() {
  for pm in apt-get apk; do
    if command -v "$pm" >/dev/null 2>&1; then
      printf '%s\n' "$pm"
      return 0
    fi
  done
  return 1
}

install_packages() {
  pm="$1"

  case "$pm" in
    apt-get)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y ca-certificates curl git ansible-core tar
      ;;
    apk)
      apk add --no-cache ca-certificates curl git ansible-core tar
      ;;
    *)
      fatal "unsupported package manager: $pm"
      ;;
  esac
}

ensure_prereqs() {
  pm="$(detect_pkg_manager)" || fatal "only apt-get and apk based systems are supported by this bootstrap script"

  missing=""
  for cmd in git ansible-playbook curl tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing="yes"
      break
    fi
  done

  if [ -n "$missing" ]; then
    log "installing bootstrap prerequisites via $pm"
    install_packages "$pm"
  fi
}

repo_url() {
  if [ -n "$GITHUB_TOKEN" ]; then
    printf 'https://x-access-token:%s@github.com/%s.git\n' "$GITHUB_TOKEN" "$GITHUB_REPO"
  else
    printf 'https://github.com/%s.git\n' "$GITHUB_REPO"
  fi
}

sync_repo() {
  url="$(repo_url)"

  if [ -d "$CHECKOUT_DIR/.git" ]; then
    log "updating existing checkout at $CHECKOUT_DIR"
    git -C "$CHECKOUT_DIR" fetch --depth 1 origin "$GITHUB_REF"
    git -C "$CHECKOUT_DIR" checkout -q -B "$GITHUB_REF" FETCH_HEAD
  else
    log "cloning $GITHUB_REPO@$GITHUB_REF to $CHECKOUT_DIR"
    mkdir -p "$(dirname "$CHECKOUT_DIR")"
    git clone --depth 1 --branch "$GITHUB_REF" "$url" "$CHECKOUT_DIR"
  fi
}

run_playbook() {
  log "running $PLAYBOOK_PATH against localhost"
  cd "$CHECKOUT_DIR"
  ansible-playbook \
    -i localhost, \
    -c local \
    "$PLAYBOOK_PATH" \
    -e "victorialogs_scheme=$VICTORIALOGS_SCHEME" \
    -e "victorialogs_host=$VICTORIALOGS_HOST" \
    -e "victorialogs_port=$VICTORIALOGS_PORT"
}

main() {
  require_root
  ensure_prereqs
  sync_repo
  run_playbook
}

main "$@"
