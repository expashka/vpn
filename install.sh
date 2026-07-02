#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CODEX_VPN_CONFIG:-/etc/codex-vpn.env}"

die() {
  echo "error: $*" >&2
  exit 1
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "run as root: sudo ./install.sh"
}

prompt_default() {
  local var="$1" prompt="$2" default="$3" value
  if [[ -n "${!var:-}" ]]; then
    return 0
  fi
  read -r -p "${prompt} [${default}]: " value
  printf -v "${var}" '%s' "${value:-${default}}"
}

prompt_secret() {
  local var="$1" prompt="$2" value
  if [[ -n "${!var:-}" ]]; then
    return 0
  fi
  read -r -s -p "${prompt}: " value
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

load_existing_or_local_env() {
  local local_env="${REPO_DIR}/codex-vpn.env"
  if [[ -r "${local_env}" ]]; then
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
  prompt_default VPN_USER "Linux user that always goes through VPN" "vpn"
  prompt_default TABLE_ID "Policy routing table id" "200"
  prompt_default TABLE_NAME "Policy routing table name" "codexvpn"
  prompt_default ROOT_PREF "Root IPv4 rule pref for vpn on/off" "210"
  prompt_default ROOT_V6_PREF "Root IPv6 prohibit rule pref" "211"
  prompt_default AUTO_ENABLE_ROOT "Enable root VPN now and on first install? 1=yes, 0=no" "1"
  prompt_default VPN_CONTAINERS "VPN containers, space-separated name:pref entries" ""
  prompt_default DIRECT_CIDRS "Direct CIDRs that bypass VPN, space-separated" ""
  TELEGRAM_MSS="${TELEGRAM_MSS:-1360}"
  IP_CHECK_URL="${IP_CHECK_URL:-https://api.ipify.org}"
}

write_config() {
  umask 077
  {
    printf 'VPN_SERVER=%s\n' "$(shell_quote "${VPN_SERVER}")"
    printf 'VPN_IDENTITY=%s\n' "$(shell_quote "${VPN_IDENTITY}")"
    printf 'VPN_PASSWORD=%s\n' "$(shell_quote "${VPN_PASSWORD}")"
    printf 'VPN_USER=%s\n' "$(shell_quote "${VPN_USER}")"
    printf 'TABLE_ID=%s\n' "$(shell_quote "${TABLE_ID}")"
    printf 'TABLE_NAME=%s\n' "$(shell_quote "${TABLE_NAME}")"
    printf 'ROOT_PREF=%s\n' "$(shell_quote "${ROOT_PREF}")"
    printf 'ROOT_V6_PREF=%s\n' "$(shell_quote "${ROOT_V6_PREF}")"
    printf 'AUTO_ENABLE_ROOT=%s\n' "$(shell_quote "${AUTO_ENABLE_ROOT}")"
    printf 'VPN_CONTAINERS=%s\n' "$(shell_quote "${VPN_CONTAINERS}")"
    printf 'DIRECT_CIDRS=%s\n' "$(shell_quote "${DIRECT_CIDRS}")"
    printf 'TELEGRAM_MSS=%s\n' "$(shell_quote "${TELEGRAM_MSS}")"
    printf 'IP_CHECK_URL=%s\n' "$(shell_quote "${IP_CHECK_URL}")"
  } > "${CONFIG_FILE}"
  chmod 600 "${CONFIG_FILE}"
}

write_strongswan_config() {
  local identity_escaped password_escaped
  identity_escaped="$(printf '%s' "${VPN_IDENTITY}" | ipsec_quote)"
  password_escaped="$(printf '%s' "${VPN_PASSWORD}" | ipsec_quote)"

  install -d -m 0755 /etc/strongswan.d/charon

  cat > /etc/ipsec.conf <<EOF
config setup

conn nl-ikev2
    keyexchange=ikev2
    right=${VPN_SERVER}
    rightid=${VPN_SERVER}
    rightsubnet=0.0.0.0/0
    rightauth=pubkey

    left=%defaultroute
    leftauth=eap-mschapv2
    eap_identity=${VPN_IDENTITY}
    leftsourceip=%config

    auto=start
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

install_runtime_files() {
  install -m 0755 "${REPO_DIR}/scripts/vpn" /usr/local/bin/vpn
  install -m 0755 "${REPO_DIR}/scripts/vpn-policy-routing.sh" /usr/local/sbin/vpn-policy-routing.sh
  install -m 0644 "${REPO_DIR}/systemd/vpn-policy-routing.service" /etc/systemd/system/vpn-policy-routing.service
}

ensure_user() {
  if ! id -u "${VPN_USER}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${VPN_USER}"
  fi
}

enable_services() {
  systemctl daemon-reload
  systemctl enable strongswan-starter.service
  systemctl restart strongswan-starter.service
  systemctl enable vpn-policy-routing.service
  systemctl restart vpn-policy-routing.service
  if [[ "${AUTO_ENABLE_ROOT}" == "1" ]]; then
    vpn on
  else
    vpn status || true
  fi
}

print_summary() {
  cat <<EOF

Installed.

Checks:
  sudo vpn status
  sudo runuser -u ${VPN_USER} -- curl -4 -s ${IP_CHECK_URL}
  sudo ipsec statusall

Run Codex through VPN:
  sudo -iu ${VPN_USER}
  codex

Config:
  ${CONFIG_FILE}
EOF
}

main() {
  need_root
  load_existing_or_local_env
  ask_config
  install_packages
  write_config
  write_strongswan_config
  install_runtime_files
  ensure_user
  enable_services
  print_summary
}

main "$@"
