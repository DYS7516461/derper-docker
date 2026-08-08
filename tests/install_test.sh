#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

prepare_workdir() {
  local workdir="$1"
  mkdir -p "$workdir"
  cp "$repo_root"/docker-compose*.yml "$workdir"/
  cp "$repo_root"/.env.example "$workdir"/
  cp "$repo_root"/install.sh "$workdir"/
}

make_certs() {
  local cert_dir="$1"
  mkdir -p "$cert_dir"
  printf '%s\n' 'test fullchain' > "$cert_dir/fullchain.pem"
  printf '%s\n' 'test privkey' > "$cert_dir/privkey.pem"
}

run_installer() {
  local workdir="$1"
  shift
  if ! (
    cd "$workdir"
    env \
      DERPER_INSTALL_NONINTERACTIVE=1 \
      DERPER_INSTALL_DRY_RUN=1 \
      "$@" \
      bash ./install.sh --non-interactive --dry-run > "$workdir/output.txt" 2> "$workdir/error.txt"
  ); then
    cat "$workdir/output.txt" >&2 || true
    cat "$workdir/error.txt" >&2 || true
    return 1
  fi
}

run_installer_expect_failure() {
  local workdir="$1"
  shift
  (
    cd "$workdir"
    env \
      DERPER_INSTALL_NONINTERACTIVE=1 \
      DERPER_INSTALL_DRY_RUN=1 \
      "$@" \
      bash ./install.sh --non-interactive --dry-run > "$workdir/output.txt" 2> "$workdir/error.txt"
  )
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  grep -q -- "$pattern" "$file"
}

test_host_manual_cert_generates_env_derpmap_and_compose_command() {
  local workdir="$tmp_root/host-manual"
  local cert_dir="$workdir/certs"
  prepare_workdir "$workdir"
  make_certs "$cert_dir"

  run_installer "$workdir" \
    DERPER_INSTALL_HOSTNAME=derp.example.com \
    DERPER_INSTALL_IMAGE=ghcr.io/example/derper:latest \
    DERPER_INSTALL_NETWORK=host \
    DERPER_INSTALL_CERT_MODE=manual \
    DERPER_INSTALL_CERT_FULLCHAIN="$cert_dir/fullchain.pem" \
    DERPER_INSTALL_CERT_PRIVKEY="$cert_dir/privkey.pem" \
    DERPER_INSTALL_HTTPS_PORT=4443 \
    DERPER_INSTALL_STUN_PORT=3478 \
    DERPER_INSTALL_VERIFY_CLIENTS=false

  assert_file_contains "$workdir/.env" '^DERP_HOSTNAME="derp.example.com"$'
  assert_file_contains "$workdir/.env" '^DERP_CERT_MODE="manual"$'
  assert_file_contains "$workdir/.env" "^DERP_CERT_FULLCHAIN=\"$cert_dir/fullchain.pem\"$"
  assert_file_contains "$workdir/.env" "^DERP_CERT_PRIVKEY=\"$cert_dir/privkey.pem\"$"
  assert_file_contains "$workdir/.env" '^DERP_HTTPS_PORT=4443$'
  assert_file_contains "$workdir/.env" '^DERP_VERIFY_CLIENTS="false"$'

  assert_file_contains "$workdir/derpMap.hujson" '"HostName": "derp.example.com"'
  assert_file_contains "$workdir/derpMap.hujson" '"DERPPort": 4443'
  assert_file_contains "$workdir/derpMap.hujson" '"STUNPort": 3478'

  assert_file_contains "$workdir/output.txt" 'docker-compose.yml'
  assert_file_contains "$workdir/output.txt" 'docker-compose.manual-cert.yml'
  assert_file_contains "$workdir/output.txt" 'up -d'
}

test_bridge_letsencrypt_uses_default_ports_without_manual_cert_compose() {
  local workdir="$tmp_root/bridge-letsencrypt"
  prepare_workdir "$workdir"

  run_installer "$workdir" \
    DERPER_INSTALL_HOSTNAME=derp.example.net \
    DERPER_INSTALL_NETWORK=bridge \
    DERPER_INSTALL_CERT_MODE=letsencrypt \
    DERPER_INSTALL_VERIFY_CLIENTS=false

  assert_file_contains "$workdir/.env" '^DERP_CERT_MODE="letsencrypt"$'
  assert_file_contains "$workdir/.env" '^DERP_HTTP_PORT=80$'
  assert_file_contains "$workdir/.env" '^DERP_HTTPS_PORT=443$'
  assert_file_contains "$workdir/output.txt" 'docker-compose.bridge.yml'
  ! grep -q 'docker-compose.manual-cert.yml' "$workdir/output.txt"
}

test_bridge_manual_cert_uses_bridge_manual_compose() {
  local workdir="$tmp_root/bridge-manual"
  local cert_dir="$workdir/certs"
  prepare_workdir "$workdir"
  make_certs "$cert_dir"

  run_installer "$workdir" \
    DERPER_INSTALL_HOSTNAME=derp.example.net \
    DERPER_INSTALL_NETWORK=bridge \
    DERPER_INSTALL_CERT_MODE=manual \
    DERPER_INSTALL_CERT_FULLCHAIN="$cert_dir/fullchain.pem" \
    DERPER_INSTALL_CERT_PRIVKEY="$cert_dir/privkey.pem" \
    DERPER_INSTALL_VERIFY_CLIENTS=false

  assert_file_contains "$workdir/.env" '^DERP_HTTP_PORT=-1$'
  assert_file_contains "$workdir/output.txt" 'docker-compose.bridge-manual.yml'
  assert_file_contains "$workdir/output.txt" 'docker-compose.manual-cert.yml'
  ! grep -q 'docker-compose.bridge.yml' "$workdir/output.txt"
}

test_verify_clients_adds_socket_compose_file() {
  local workdir="$tmp_root/verify-clients"
  local cert_dir="$workdir/certs"
  prepare_workdir "$workdir"
  make_certs "$cert_dir"

  run_installer "$workdir" \
    DERPER_INSTALL_HOSTNAME=derp.example.org \
    DERPER_INSTALL_NETWORK=host \
    DERPER_INSTALL_CERT_MODE=manual \
    DERPER_INSTALL_CERT_FULLCHAIN="$cert_dir/fullchain.pem" \
    DERPER_INSTALL_CERT_PRIVKEY="$cert_dir/privkey.pem" \
    DERPER_INSTALL_VERIFY_CLIENTS=true

  assert_file_contains "$workdir/.env" '^DERP_VERIFY_CLIENTS="true"$'
  assert_file_contains "$workdir/output.txt" 'docker-compose.verify-clients.yml'
}

test_valid_ipv4_is_written_to_derpmap() {
  local workdir="$tmp_root/ipv4-valid"
  prepare_workdir "$workdir"

  run_installer "$workdir" \
    DERPER_INSTALL_HOSTNAME=derp.example.org \
    DERPER_INSTALL_NETWORK=host \
    DERPER_INSTALL_CERT_MODE=letsencrypt \
    DERPER_INSTALL_IPV4=122.152.212.66 \
    DERPER_INSTALL_VERIFY_CLIENTS=false

  assert_file_contains "$workdir/derpMap.hujson" '"IPv4": "122.152.212.66"'
}

test_invalid_port_is_rejected() {
  local workdir="$tmp_root/invalid-port"
  prepare_workdir "$workdir"

  if run_installer_expect_failure "$workdir" \
    DERPER_INSTALL_HOSTNAME=derp.example.org \
    DERPER_INSTALL_NETWORK=host \
    DERPER_INSTALL_CERT_MODE=letsencrypt \
    DERPER_INSTALL_HTTPS_PORT='80; bad' \
    DERPER_INSTALL_VERIFY_CLIENTS=false; then
    echo "invalid port was accepted" >&2
    return 1
  fi

  assert_file_contains "$workdir/error.txt" 'Invalid DERPer HTTPS port'
}

test_invalid_ipv4_is_rejected() {
  local workdir="$tmp_root/ipv4-invalid"
  prepare_workdir "$workdir"

  if run_installer_expect_failure "$workdir" \
    DERPER_INSTALL_HOSTNAME=derp.example.org \
    DERPER_INSTALL_NETWORK=host \
    DERPER_INSTALL_CERT_MODE=letsencrypt \
    DERPER_INSTALL_IPV4='1.2.3.4", "IPv6": "::1' \
    DERPER_INSTALL_VERIFY_CLIENTS=false; then
    echo "invalid IPv4 was accepted" >&2
    return 1
  fi

  assert_file_contains "$workdir/error.txt" 'Invalid public IPv4'
}


test_missing_compose_files_prints_download_url() {
  local workdir="$tmp_root/missing-compose"
  mkdir -p "$workdir"
  cp "$repo_root"/install.sh "$workdir"/

  run_installer "$workdir" \
    DERPER_INSTALL_HOSTNAME=derp.example.org \
    DERPER_INSTALL_NETWORK=host \
    DERPER_INSTALL_CERT_MODE=manual \
    DERPER_INSTALL_CERT_FULLCHAIN=/tmp/nonexistent/fullchain.pem \
    DERPER_INSTALL_CERT_PRIVKEY=/tmp/nonexistent/privkey.pem \
    DERPER_INSTALL_VERIFY_CLIENTS=false

  assert_file_contains "$workdir/output.txt" 'would download docker-compose.yml from https://raw.githubusercontent.com/DYS7516461/derper-docker/main/docker-compose.yml'
  assert_file_contains "$workdir/output.txt" 'would download docker-compose.manual-cert.yml from https://raw.githubusercontent.com/DYS7516461/derper-docker/main/docker-compose.manual-cert.yml'
}

test_custom_repo_overrides_download_base_and_default_image() {
  local workdir="$tmp_root/custom-repo"
  mkdir -p "$workdir"
  cp "$repo_root"/install.sh "$workdir"/

  run_installer "$workdir" \
    DERPER_INSTALL_REPO=octocat/derper \
    DERPER_INSTALL_BRANCH=dev \
    DERPER_INSTALL_HOSTNAME=derp.example.org \
    DERPER_INSTALL_NETWORK=host \
    DERPER_INSTALL_CERT_MODE=letsencrypt \
    DERPER_INSTALL_VERIFY_CLIENTS=false

  assert_file_contains "$workdir/output.txt" 'would download docker-compose.yml from https://raw.githubusercontent.com/octocat/derper/dev/docker-compose.yml'
  assert_file_contains "$workdir/.env" '^DERPER_IMAGE="ghcr.io/octocat/derper:latest"$'
}

for test_name in \
  test_host_manual_cert_generates_env_derpmap_and_compose_command \
  test_bridge_letsencrypt_uses_default_ports_without_manual_cert_compose \
  test_bridge_manual_cert_uses_bridge_manual_compose \
  test_verify_clients_adds_socket_compose_file \
  test_valid_ipv4_is_written_to_derpmap \
  test_invalid_port_is_rejected \
  test_invalid_ipv4_is_rejected \
  test_missing_compose_files_prints_download_url \
  test_custom_repo_overrides_download_base_and_default_image
do
  "$test_name"
  printf 'ok - %s\n' "$test_name"
done
