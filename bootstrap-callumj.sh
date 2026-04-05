#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${TARGET_USER:-callumj}"
KEYS_URL="${KEYS_URL:-https://github.com/callumj.keys}"

log() {
  printf '[bootstrap] %s\n' "$*"
}

fatal() {
  printf '[bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    fatal "run as root (or with sudo)"
  fi
}

detect_pkg_manager() {
  local pm
  for pm in apt-get dnf yum zypper apk pacman; do
    if command -v "$pm" >/dev/null 2>&1; then
      printf '%s\n' "$pm"
      return 0
    fi
  done
  return 1
}

group_exists() {
  local group_name="$1"

  if command -v getent >/dev/null 2>&1; then
    getent group "$group_name" >/dev/null 2>&1
  else
    grep -q "^${group_name}:" /etc/group
  fi
}

get_user_home() {
  local username="$1"

  if command -v getent >/dev/null 2>&1; then
    getent passwd "$username" | cut -d: -f6
  else
    awk -F: -v user="$username" '$1 == user { print $6 }' /etc/passwd
  fi
}

add_user_to_group() {
  local username="$1"
  local group_name="$2"

  if command -v usermod >/dev/null 2>&1; then
    usermod -aG "$group_name" "$username"
  elif command -v addgroup >/dev/null 2>&1; then
    addgroup "$username" "$group_name"
  else
    fatal "no supported command found to add '$username' to group '$group_name'"
  fi
}

install_packages() {
  local pm="$1"
  shift
  local pkgs=("$@")

  case "$pm" in
    apt-get)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    zypper)
      zypper --non-interactive install --no-confirm "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    pacman)
      pacman -Sy --noconfirm "${pkgs[@]}"
      ;;
    *)
      fatal "unsupported package manager: $pm"
      ;;
  esac
}

ensure_prereqs() {
  local pm
  pm="$(detect_pkg_manager)" || fatal "no supported package manager found"

  case "$pm" in
    apt-get) install_packages "$pm" sudo openssh-server curl ;;
    dnf|yum) install_packages "$pm" sudo openssh-server curl ;;
    zypper) install_packages "$pm" sudo openssh curl ;;
    apk) install_packages "$pm" sudo openssh curl ;;
    pacman) install_packages "$pm" sudo openssh curl ;;
  esac
}

ensure_user() {
  local shell_path="/bin/sh"
  if [[ -x /bin/bash ]]; then
    shell_path="/bin/bash"
  fi

  if id -u "$TARGET_USER" >/dev/null 2>&1; then
    log "user '$TARGET_USER' already exists"
  else
    if command -v useradd >/dev/null 2>&1; then
      useradd -m -s "$shell_path" "$TARGET_USER"
    elif command -v adduser >/dev/null 2>&1; then
      adduser -D -s "$shell_path" "$TARGET_USER"
    else
      fatal "no supported command found to create user '$TARGET_USER'"
    fi
    log "created user '$TARGET_USER'"
  fi
}

ensure_sudo_access() {
  local sudoers_file="/etc/sudoers.d/90-${TARGET_USER}"
  local sudo_group=""

  if group_exists sudo; then
    sudo_group="sudo"
  elif group_exists wheel; then
    sudo_group="wheel"
  fi

  if [[ -n "$sudo_group" ]]; then
    add_user_to_group "$TARGET_USER" "$sudo_group"
    log "added '$TARGET_USER' to group '$sudo_group'"
  fi

  mkdir -p /etc/sudoers.d
  printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$TARGET_USER" >"$sudoers_file"
  chmod 0440 "$sudoers_file"
  visudo -cf "$sudoers_file" >/dev/null
  log "ensured sudoers entry at $sudoers_file"
}

lock_down_sshd() {
  local sshd_config="/etc/ssh/sshd_config"

  [[ -f "$sshd_config" ]] || fatal "missing $sshd_config"

  upsert_sshd_setting "$sshd_config" "PermitRootLogin" "no"
  upsert_sshd_setting "$sshd_config" "PasswordAuthentication" "no"
  upsert_sshd_setting "$sshd_config" "KbdInteractiveAuthentication" "no"
  upsert_sshd_setting "$sshd_config" "ChallengeResponseAuthentication" "no"
  upsert_sshd_setting "$sshd_config" "PubkeyAuthentication" "yes"
  ensure_sshd_runtime_dir
  ensure_sshd_host_keys

  if command -v sshd >/dev/null 2>&1; then
    sshd -t -f "$sshd_config"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now ssh >/dev/null 2>&1 || true
    systemctl enable --now sshd >/dev/null 2>&1 || true
    systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    service ssh restart >/dev/null 2>&1 || service sshd restart >/dev/null 2>&1 || true
  elif command -v rc-service >/dev/null 2>&1; then
    rc-update add sshd default >/dev/null 2>&1 || true
    rc-service sshd restart >/dev/null 2>&1 || true
  fi

  log "sshd configured and restart attempted"
}

ensure_sshd_runtime_dir() {
  mkdir -p /run/sshd
  chmod 0755 /run/sshd
  chown root:root /run/sshd

  if [[ -d /etc/tmpfiles.d ]]; then
    printf 'd /run/sshd 0755 root root -\n' >/etc/tmpfiles.d/sshd.conf
  fi

  if command -v systemd-tmpfiles >/dev/null 2>&1; then
    systemd-tmpfiles --create /etc/tmpfiles.d/sshd.conf >/dev/null 2>&1 || true
  fi

  log "ensured sshd runtime directory at /run/sshd"
}

ensure_sshd_host_keys() {
  if compgen -G "/etc/ssh/ssh_host_*_key" >/dev/null; then
    log "sshd host keys already exist"
    return
  fi

  if ! command -v ssh-keygen >/dev/null 2>&1; then
    fatal "ssh-keygen not found; unable to generate sshd host keys"
  fi

  ssh-keygen -A
  log "generated sshd host keys"
}

upsert_sshd_setting() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp_file

  tmp_file="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN {
      lk = tolower(k)
      done = 0
    }
    {
      line = $0
      trimmed = line
      sub(/^[[:space:]]+/, "", trimmed)

      if (trimmed ~ /^#/) {
        sub(/^#[[:space:]]*/, "", trimmed)
      }

      split(trimmed, fields, /[[:space:]]+/)
      if (tolower(fields[1]) == lk) {
        if (!done) {
          print k " " v
          done = 1
        }
        next
      }

      print $0
    }
    END {
      if (!done) {
        print k " " v
      }
    }
  ' "$file" >"$tmp_file"

  cat "$tmp_file" >"$file"
  rm -f "$tmp_file"
}

ensure_authorized_keys() {
  local user_home
  local user_group
  local ssh_dir
  local auth_keys
  local tmp_existing
  local fetched_keys=""
  local attempt=1

  user_home="$(get_user_home "$TARGET_USER")"
  [[ -n "$user_home" ]] || fatal "unable to determine home directory for '$TARGET_USER'"
  user_group="$(id -gn "$TARGET_USER")"

  ssh_dir="${user_home}/.ssh"
  auth_keys="${ssh_dir}/authorized_keys"
  mkdir -p "$ssh_dir"
  chmod 0700 "$ssh_dir"
  touch "$auth_keys"
  chmod 0600 "$auth_keys"

  while [[ "$attempt" -le 5 ]]; do
    if fetched_keys="$(curl -4fsSL "$KEYS_URL")"; then
      break
    fi
    sleep 2
    attempt=$((attempt + 1))
  done
  [[ -n "$fetched_keys" ]] || fatal "failed to fetch keys from $KEYS_URL"
  [[ -n "$fetched_keys" ]] || fatal "no keys found at $KEYS_URL"

  tmp_existing="$(mktemp)"
  {
    cat "$auth_keys"
    printf '%s\n' "$fetched_keys"
  } | awk 'NF && !seen[$0]++' >"$tmp_existing"

  cat "$tmp_existing" >"$auth_keys"
  rm -f "$tmp_existing"

  chown -R "$TARGET_USER:$user_group" "$ssh_dir"
  log "authorized_keys updated from $KEYS_URL"
}

main() {
  require_root
  ensure_prereqs
  ensure_user
  ensure_sudo_access
  lock_down_sshd
  ensure_authorized_keys
  log "complete"
}

main "$@"
