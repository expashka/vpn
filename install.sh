#!/usr/bin/env bash
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [[ -n "${SCRIPT_SOURCE}" && -f "${SCRIPT_SOURCE}" ]]; then
  REPO_DIR="$(cd -- "$(dirname -- "${SCRIPT_SOURCE}")" && pwd)"
else
  REPO_DIR=""
fi
CONFIG_FILE="${CODEX_VPN_CONFIG:-/etc/codex-vpn.env}"
REPO_RAW_URL="${CODEX_VPN_RAW_URL:-https://raw.githubusercontent.com/expashka/vpn/main}"
CACHE_BUSTER="${CODEX_VPN_CACHE_BUSTER:-$(date +%s)}"
CA_SHA256="D2:70:10:0C:99:09:21:6A:DF:BF:F2:1D:D4:6A:27:7F:D8:71:69:4D:F5:12:9D:17:7E:C4:34:19:DC:AE:EF:06"

die() {
  echo "error: $*" >&2
  exit 1
}

on_error() {
  local line="$1" code="$2"
  echo "error: installation failed at line ${line} (exit ${code})" >&2
}

trap 'on_error "${LINENO}" "$?"' ERR

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "run as root: sudo ./install.sh"
}

prompt_default() {
  local var="$1" prompt="$2" default="$3" value input="/dev/stdin"
  if [[ -n "${!var:-}" ]]; then
    return 0
  fi
  [[ -r /dev/tty ]] && input="/dev/tty"
  read -r -p "${prompt} [${default}]: " value < "${input}"
  printf -v "${var}" '%s' "${value:-${default}}"
}

prompt_secret() {
  local var="$1" prompt="$2" value input="/dev/stdin"
  if [[ -n "${!var:-}" ]]; then
    return 0
  fi
  [[ -r /dev/tty ]] && input="/dev/tty"
  read -r -s -p "${prompt}: " value < "${input}"
  echo
  [[ -n "${value}" ]] || die "${prompt} is required"
  printf -v "${var}" '%s' "${value}"
}

shell_quote() {
  printf '%q' "$1"
}

ipsec_quote() {
  sed 's/[\"\\]/\\&/g'
}

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y strongswan strongswan-starter libcharon-extra-plugins curl iproute2 iptables ca-certificates
  else
    die "this installer currently supports Debian/Ubuntu with apt-get"
  fi
}

repo_file() {
  local rel="$1"
  if [[ -n "${REPO_DIR}" && -r "${REPO_DIR}/${rel}" ]]; then
    printf '%s\n' "${REPO_DIR}/${rel}"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  curl -fsSL "${REPO_RAW_URL}/${rel}?v=${CACHE_BUSTER}" -o "${tmp}"
  printf '%s\n' "${tmp}"
}

load_existing_or_local_env() {
  local local_env=""
  [[ -n "${REPO_DIR}" ]] && local_env="${REPO_DIR}/codex-vpn.env"
  if [[ -n "${local_env}" && -r "${local_env}" ]]; then
    # shellcheck disable=SC1090
    source "${local_env}"
  elif [[ -r "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
  fi
}

ask_config() {
  prompt_default VPN_SERVER "NL VPN server IPv4" "212.118.54.47"
  prompt_default VPN_IDENTITY "NL VPN login / IKEv2 identity" "wavesdev"
  prompt_secret VPN_PASSWORD "NL VPN password"
}

write_config() {
  umask 077
  {
    printf 'VPN_SERVER=%s\n' "$(shell_quote "${VPN_SERVER}")"
    printf 'VPN_IDENTITY=%s\n' "$(shell_quote "${VPN_IDENTITY}")"
    printf 'VPN_PASSWORD=%s\n' "$(shell_quote "${VPN_PASSWORD}")"
    printf 'TABLE_ID=200\n'
    printf 'TABLE_NAME=codexvpn\n'
    printf 'ROOT_PREF=210\n'
    printf 'ROOT_V6_PREF=211\n'
  } > "${CONFIG_FILE}"
  chmod 600 "${CONFIG_FILE}"
}

write_strongswan_config() {
  local identity_escaped password_escaped main_default main_device local_ip
  identity_escaped="$(printf '%s' "${VPN_IDENTITY}" | ipsec_quote)"
  password_escaped="$(printf '%s' "${VPN_PASSWORD}" | ipsec_quote)"
  main_default="$(ip -4 route show table main default | sed -n '1p')"
  main_device="$(
    awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"${main_default}"
  )"
  local_ip="$(
    ip -4 -o addr show dev "${main_device}" scope global |
      awk '{split($4, address, "/"); print address[1]; exit}'
  )"
  [[ -n "${local_ip}" ]] || die "could not detect physical IPv4 from main routing table"

  install -d -m 0755 /etc/strongswan.d/charon

  cat > /etc/ipsec.conf <<EOF
config setup

conn nl-ikev2
    keyexchange=ikev2
    right=${VPN_SERVER}
    rightid=${VPN_SERVER}
    rightsubnet=0.0.0.0/0
    rightauth=pubkey

    left=${local_ip}
    leftauth=eap-mschapv2
    eap_identity=${VPN_IDENTITY}
    leftsourceip=%config

    auto=add
    keyingtries=%forever
    dpdaction=restart
    dpddelay=15s
    dpdtimeout=60s
    closeaction=restart
    reauth=no
EOF

  umask 077
  cat > /etc/ipsec.secrets <<EOF
${identity_escaped} : EAP "${password_escaped}"
EOF
  chmod 600 /etc/ipsec.secrets

  cat > /etc/strongswan.d/charon/codex-vpn.conf <<'EOF'
charon {
    install_routes = no
}
EOF
}

install_ca_certificate() {
  local ca_file fingerprint
  ca_file="$(repo_file certs/ca-cert.pem)"
  fingerprint="$(openssl x509 -in "${ca_file}" -noout -fingerprint -sha256 | cut -d= -f2)"
  [[ "${fingerprint}" == "${CA_SHA256}" ]] || die "VPN Root CA fingerprint mismatch"

  install -d -m 0755 /etc/ipsec.d/cacerts
  install -m 0644 "${ca_file}" /etc/ipsec.d/cacerts/ca-cert.pem
  echo "VPN Root CA installed (${fingerprint})"
}

install_runtime_files() {
  local vpn_script
  vpn_script="$(repo_file scripts/vpn)"
  install -m 0755 "${vpn_script}" /usr/local/bin/vpn
}

enable_services() {
  systemctl disable --now vpn-policy-routing.service 2>/dev/null || true
  rm -f /etc/systemd/system/vpn-policy-routing.service
  systemctl daemon-reload
  systemctl enable strongswan-starter.service
  systemctl restart strongswan-starter.service

  vpn on
}

print_summary() {
  cat <<EOF

Installed.

Checks:
  sudo vpn status
  sudo ipsec statusall

Config:
  ${CONFIG_FILE}
EOF
}

main() {
  need_root
  load_existing_or_local_env
  ask_config
  echo "IKEv2 identity: ${VPN_IDENTITY}"
  echo "[1/5] Installing packages"
  install_packages
  echo "[2/5] Writing credentials"
  write_config
  echo "[3/5] Installing VPN Root CA"
  install_ca_certificate
  echo "[4/5] Installing strongSwan configuration"
  write_strongswan_config
  install_runtime_files
  echo "[5/5] Starting strongSwan and IKEv2 connection"
  enable_services
  print_summary
}

main "$@"
