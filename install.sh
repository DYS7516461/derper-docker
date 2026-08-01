#!/usr/bin/env bash
set -Eeuo pipefail

NONINTERACTIVE="${DERPER_INSTALL_NONINTERACTIVE:-0}"
DRY_RUN="${DERPER_INSTALL_DRY_RUN:-0}"
DEFAULT_IMAGE="ghcr.io/your-github-name/derper-docker:latest"
DERPMAP_FILE="derpMap.hujson"

usage() {
  cat <<'EOF'
DERPer Docker installer

Usage:
  bash install.sh [--dry-run] [--non-interactive]

Environment variables for non-interactive mode:
  DERPER_INSTALL_HOSTNAME
  DERPER_INSTALL_IMAGE
  DERPER_INSTALL_NETWORK              host or bridge
  DERPER_INSTALL_CERT_MODE            manual or letsencrypt
  DERPER_INSTALL_CERT_FULLCHAIN
  DERPER_INSTALL_CERT_PRIVKEY
  DERPER_INSTALL_HTTP_PORT
  DERPER_INSTALL_HTTPS_PORT
  DERPER_INSTALL_STUN_PORT
  DERPER_INSTALL_VERIFY_CLIENTS       true or false
  DERPER_INSTALL_IPV4                 optional public IPv4 for derpMap
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --non-interactive)
      NONINTERACTIVE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

info() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is_true() {
  case "${1,,}" in
    1|y|yes|true|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

prompt_value() {
  local env_name="$1"
  local label="$2"
  local default_value="$3"
  local current_value="${!env_name:-}"
  local input

  if [[ -n "$current_value" ]]; then
    printf '%s' "$current_value"
    return
  fi

  if [[ "$NONINTERACTIVE" == "1" ]]; then
    printf '%s' "$default_value"
    return
  fi

  if [[ -n "$default_value" ]]; then
    read -r -p "$label [$default_value]: " input
    printf '%s' "${input:-$default_value}"
  else
    read -r -p "$label: " input
    printf '%s' "$input"
  fi
}

prompt_choice() {
  local env_name="$1"
  local label="$2"
  local default_value="$3"
  shift 3
  local choices=("$@")
  local env_value="${!env_name:-}"
  local value
  local choice

  if [[ -n "$env_value" ]]; then
    for choice in "${choices[@]}"; do
      if [[ "$env_value" == "$choice" ]]; then
        printf '%s' "$env_value"
        return
      fi
    done
    die "$env_name must be one of: ${choices[*]}"
  fi

  while true; do
    value="$(prompt_value "$env_name" "$label" "$default_value")"
    for choice in "${choices[@]}"; do
      if [[ "$value" == "$choice" ]]; then
        printf '%s' "$value"
        return
      fi
    done
    if [[ "$NONINTERACTIVE" == "1" ]]; then
      die "$env_name must be one of: ${choices[*]}"
    fi
    warn "Please choose one of: ${choices[*]}"
  done
}

prompt_yes_no() {
  local env_name="$1"
  local label="$2"
  local default_value="$3"
  local current_value="${!env_name:-}"
  local prompt
  local input

  if [[ -n "$current_value" ]]; then
    case "${current_value,,}" in
      1|y|yes|true|on)
        return 0
        ;;
      0|n|no|false|off)
        return 1
        ;;
      *)
        die "$env_name must be true or false."
        ;;
    esac
  fi

  if [[ "$NONINTERACTIVE" == "1" ]]; then
    if is_true "$default_value"; then
      return 0
    fi
    return 1
  fi

  if is_true "$default_value"; then
    prompt="Y/n"
  else
    prompt="y/N"
  fi

  read -r -p "$label [$prompt]: " input
  input="${input:-$default_value}"
  is_true "$input"
}

as_root() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    die "This action needs root privileges. Re-run as root or install sudo."
  fi
}

install_curl_if_missing() {
  if command_exists curl; then
    return
  fi

  info "Installing curl"
  if command_exists apt-get; then
    as_root apt-get update
    as_root apt-get install -y curl ca-certificates
  elif command_exists dnf; then
    as_root dnf install -y curl ca-certificates
  elif command_exists yum; then
    as_root yum install -y curl ca-certificates
  elif command_exists apk; then
    as_root apk add --no-cache curl ca-certificates
  else
    die "curl is missing and this script does not know how to install it on this OS."
  fi
}

ensure_docker() {
  if [[ "$DRY_RUN" == "1" ]]; then
    info "Dry run: skipping Docker installation checks"
    return
  fi

  if command_exists docker && docker compose version >/dev/null 2>&1; then
    info "Docker and Docker Compose are already installed"
    return
  fi

  if ! prompt_yes_no DERPER_INSTALL_DOCKER "Docker or Docker Compose is missing. Install Docker with the official convenience script?" "yes"; then
    die "Docker and Docker Compose are required."
  fi

  install_curl_if_missing
  info "Installing Docker"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  as_root sh /tmp/get-docker.sh

  if command_exists systemctl; then
    as_root systemctl enable docker
    as_root systemctl start docker
  fi

  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is not available after Docker installation."
}

ensure_tailscale() {
  if [[ "$DRY_RUN" == "1" ]]; then
    info "Dry run: skipping Tailscale installation checks"
    return
  fi

  if ! command_exists tailscale; then
    if ! prompt_yes_no DERPER_INSTALL_TAILSCALE "Tailscale is missing. Install it now for DERPer client verification?" "yes"; then
      die "Tailscale is required when DERP_VERIFY_CLIENTS=true."
    fi

    install_curl_if_missing
    info "Installing Tailscale"
    curl -fsSL https://tailscale.com/install.sh -o /tmp/install-tailscale.sh
    as_root sh /tmp/install-tailscale.sh
  fi

  if command_exists systemctl; then
    as_root systemctl enable tailscaled
    as_root systemctl start tailscaled
  fi

  if ! as_root tailscale status >/dev/null 2>&1; then
    warn "Tailscale is installed but this server is not logged in yet."
    if prompt_yes_no DERPER_INSTALL_TAILSCALE_UP "Run tailscale up now?" "yes"; then
      as_root tailscale up
    else
      die "Run 'sudo tailscale up' before enabling DERPer client verification."
    fi
  fi

  [[ -S /var/run/tailscale/tailscaled.sock ]] || die "Missing /var/run/tailscale/tailscaled.sock. Is tailscaled running?"
}

require_linux_for_install() {
  if [[ "$DRY_RUN" == "1" ]]; then
    return
  fi

  [[ "$(uname -s)" == "Linux" ]] || die "This installer is intended for Linux servers."
}

validate_cert_paths() {
  local fullchain="$1"
  local privkey="$2"

  [[ -n "$fullchain" ]] || die "Certificate fullchain path is empty."
  [[ -n "$privkey" ]] || die "Certificate private key path is empty."

  if [[ "$DRY_RUN" == "1" ]]; then
    return
  fi

  [[ -f "$fullchain" ]] || die "Certificate file not found: $fullchain"
  [[ -f "$privkey" ]] || die "Private key file not found: $privkey"
}

validate_hostname() {
  local value="$1"

  if [[ -z "$value" || ${#value} -gt 253 ]]; then
    die "Invalid DERP hostname: $value"
  fi

  if [[ "$value" == .* || "$value" == *. || "$value" == *..* ]]; then
    die "Invalid DERP hostname: $value"
  fi

  if ! [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]]; then
    die "Invalid DERP hostname: $value"
  fi
}

validate_port() {
  local label="$1"
  local value="$2"
  local allow_disabled="${3:-false}"

  if [[ "$allow_disabled" == "true" && "$value" == "-1" ]]; then
    return
  fi

  if ! [[ "$value" =~ ^[0-9]+$ ]] || (( 10#$value < 1 || 10#$value > 65535 )); then
    die "Invalid $label port: $value"
  fi
}

validate_ipv4() {
  local value="$1"
  local octet

  [[ -n "$value" ]] || return 0

  if ! [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    die "Invalid public IPv4: $value"
  fi

  IFS='.' read -r -a octets <<< "$value"
  for octet in "${octets[@]}"; do
    if (( 10#$octet > 255 )); then
      die "Invalid public IPv4: $value"
    fi
  done
}

detect_default_image() {
  local remote
  local repo

  remote="$(git config --get remote.origin.url 2>/dev/null || true)"

  case "$remote" in
    https://github.com/*/*.git|https://github.com/*/*)
      repo="${remote#https://github.com/}"
      ;;
    git@github.com:*/*.git|git@github.com:*/*)
      repo="${remote#git@github.com:}"
      ;;
    *)
      printf '%s\n' "$DEFAULT_IMAGE"
      return
      ;;
  esac

  repo="${repo%.git}"
  printf 'ghcr.io/%s:latest\n' "${repo,,}"
}

write_env_file() {
  cat > .env <<EOF
# Generated by install.sh
DERP_HOSTNAME=$hostname
DERPER_IMAGE=$image
TZ=$timezone

DERP_CERT_MODE=$cert_mode
DERP_CERT_DIR=/var/lib/derper/certs
DERP_CERT_FULLCHAIN=$cert_fullchain
DERP_CERT_PRIVKEY=$cert_privkey
DERP_HTTP_PORT=$http_port
DERP_HTTPS_PORT=$https_port
DERP_STUN_PORT=$stun_port
DERP_VERIFY_CLIENTS=$verify_clients
EOF
}

write_derp_map() {
  cat > "$DERPMAP_FILE" <<EOF
"derpMap": {
  // Keep official DERP nodes as fallback at first. Enable this later if needed.
  // "OmitDefaultRegions": true,
  "Regions": {
    "900": {
      "RegionID": 900,
      "RegionCode": "myderp",
      "RegionName": "Custom DERP",
      "Nodes": [
        {
          "Name": "900a",
          "RegionID": 900,
          "HostName": "$hostname",
EOF

  if [[ -n "$public_ipv4" ]]; then
    printf '          "IPv4": "%s",\n' "$public_ipv4" >> "$DERPMAP_FILE"
  fi

  cat >> "$DERPMAP_FILE" <<EOF
          "DERPPort": $https_port,
          "STUNPort": $stun_port
        }
      ]
    }
  }
}
EOF
}

print_command() {
  local arg
  for arg in "$@"; do
    printf '%s ' "$arg"
  done
  printf '\n'
}

build_compose_command() {
  compose_cmd=(docker compose)

  if [[ "$network_mode" == "host" ]]; then
    compose_cmd+=(-f docker-compose.host.yml)
  else
    compose_cmd+=(-f docker-compose.bridge.yml)
  fi

  if [[ "$cert_mode" == "manual" ]]; then
    compose_cmd+=(-f docker-compose.manual-cert.yml)
  fi

  if [[ "$verify_clients" == "true" ]]; then
    compose_cmd+=(-f docker-compose.verify-clients.yml)
  fi

  compose_cmd+=(up -d)
}

run_deploy() {
  build_compose_command
  info "Deployment command"
  print_command "${compose_cmd[@]}"

  if [[ "$DRY_RUN" == "1" ]]; then
    info "Dry run: not starting containers"
    return
  fi

  "${compose_cmd[@]}"
}

info "DERPer Docker guided installer"

require_linux_for_install

hostname="$(prompt_value DERPER_INSTALL_HOSTNAME "DERP domain name" "derp.example.com")"
validate_hostname "$hostname"
[[ "$hostname" != "derp.example.com" ]] || warn "You are using the example domain. Replace it with your real domain before production use."

image_default="$(detect_default_image)"
image="$(prompt_value DERPER_INSTALL_IMAGE "DERPer Docker image" "$image_default")"
timezone="$(prompt_value DERPER_INSTALL_TZ "Timezone" "Asia/Shanghai")"
network_mode="$(prompt_choice DERPER_INSTALL_NETWORK "Network mode: host or bridge" "host" host bridge)"

baota_cert_dir="/www/server/panel/vhost/cert/$hostname"
baota_fullchain="$baota_cert_dir/fullchain.pem"
baota_privkey="$baota_cert_dir/privkey.pem"

cert_mode="${DERPER_INSTALL_CERT_MODE:-}"
cert_fullchain="${DERPER_INSTALL_CERT_FULLCHAIN:-}"
cert_privkey="${DERPER_INSTALL_CERT_PRIVKEY:-}"

if [[ -z "$cert_mode" ]]; then
  if [[ -f "$baota_fullchain" && -f "$baota_privkey" ]]; then
    if prompt_yes_no DERPER_INSTALL_USE_BAOTA_CERT "Detected BaoTa certificate for $hostname. Use it?" "yes"; then
      cert_mode="manual"
      cert_fullchain="$baota_fullchain"
      cert_privkey="$baota_privkey"
    fi
  fi
fi

if [[ -z "$cert_mode" ]]; then
  cert_mode="$(prompt_choice DERPER_INSTALL_CERT_MODE "Certificate mode: manual or letsencrypt" "manual" manual letsencrypt)"
fi

case "$cert_mode" in
  manual|letsencrypt)
    ;;
  *)
    die "DERPER_INSTALL_CERT_MODE must be manual or letsencrypt."
    ;;
esac

if [[ "$cert_mode" == "manual" ]]; then
  cert_fullchain="$(DERPER_INSTALL_CERT_FULLCHAIN="$cert_fullchain" prompt_value DERPER_INSTALL_CERT_FULLCHAIN "fullchain.pem path" "${baota_fullchain}")"
  cert_privkey="$(DERPER_INSTALL_CERT_PRIVKEY="$cert_privkey" prompt_value DERPER_INSTALL_CERT_PRIVKEY "privkey.pem path" "${baota_privkey}")"
  validate_cert_paths "$cert_fullchain" "$cert_privkey"
fi

if [[ "$cert_mode" == "letsencrypt" ]]; then
  http_default="80"
  https_default="443"
else
  http_default="-1"
  https_default="4443"
fi

http_port="$(prompt_value DERPER_INSTALL_HTTP_PORT "DERPer HTTP port (-1 disables it)" "$http_default")"
https_port="$(prompt_value DERPER_INSTALL_HTTPS_PORT "DERPer HTTPS port" "$https_default")"
stun_port="$(prompt_value DERPER_INSTALL_STUN_PORT "DERPer STUN UDP port" "3478")"
public_ipv4="$(prompt_value DERPER_INSTALL_IPV4 "Optional public IPv4 for derpMap, blank to omit" "")"

validate_port "DERPer HTTP" "$http_port" true
validate_port "DERPer HTTPS" "$https_port"
validate_port "DERPer STUN UDP" "$stun_port"
validate_ipv4 "$public_ipv4"

if prompt_yes_no DERPER_INSTALL_VERIFY_CLIENTS "Enable DERPer client verification with host tailscaled?" "no"; then
  verify_clients="true"
else
  verify_clients="false"
fi

ensure_docker
if [[ "$verify_clients" == "true" ]]; then
  ensure_tailscale
fi

info "Writing .env"
write_env_file

info "Writing $DERPMAP_FILE"
write_derp_map

run_deploy

cat <<EOF

DERPer deployment files are ready.

Open firewall/security group:
  TCP $https_port
  UDP $stun_port
EOF

if [[ "$cert_mode" == "letsencrypt" && "$http_port" != "-1" ]]; then
  cat <<EOF
  TCP $http_port
EOF
fi

cat <<EOF

Paste the generated DERP map into your Tailscale policy file:
  $DERPMAP_FILE

After saving the policy, verify from a client:
  tailscale netcheck
EOF
