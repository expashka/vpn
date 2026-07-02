#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${CODEX_VPN_CONFIG:-/etc/codex-vpn.env}"
if [[ -r "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

TABLE_ID="${TABLE_ID:-200}"
TABLE_NAME="${TABLE_NAME:-codexvpn}"
VPN_SERVER="${VPN_SERVER:-212.118.54.47}"
VPN_USER="${VPN_USER:-vpn}"
TELEGRAM_MSS="${TELEGRAM_MSS:-1360}"
VPN_CONTAINERS="${VPN_CONTAINERS:-}"
DIRECT_CIDRS="${DIRECT_CIDRS:-}"

detect_ipsec_vip() {
  ip -d xfrm policy 2>/dev/null | awk '
    $1=="src" && $3=="dst" && $4=="0.0.0.0/0" {
      split($2,a,"/");
      cand=a[1];
      getline;
      if ($1=="dir" && $2=="out") { print cand; exit }
    }'
}

detect_configured_vip() {
  ip -4 -o addr show | awk '$4 ~ /^10\.10\.10\./ {split($4,a,"/"); print a[1]; exit}'
}

main_route_value() {
  local key="$1"
  ip -4 route show default | awk -v key="${key}" '
    /^default/ {
      for (i = 1; i <= NF; i++) if ($i == key) {print $(i+1); exit}
    }'
}

detect_main_src() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}

if ! id -u "${VPN_USER}" >/dev/null 2>&1; then
  echo "vpn-policy-routing: user ${VPN_USER} does not exist, skipping" >&2
  exit 0
fi

VPN_UID="$(id -u "${VPN_USER}")"
MAIN_IF="$(main_route_value dev)"
MAIN_GW="$(main_route_value via)"
MAIN_SRC="$(main_route_value src)"
if [[ -z "${MAIN_SRC}" ]]; then
  MAIN_SRC="$(detect_main_src)"
fi

VPN_SRC="$(detect_ipsec_vip)"
if [[ -z "${VPN_SRC}" ]]; then
  VPN_SRC="$(detect_configured_vip)"
fi

if [[ -z "${MAIN_IF}" || -z "${MAIN_GW}" || -z "${MAIN_SRC}" ]]; then
  echo "vpn-policy-routing: main route is not ready yet" >&2
  exit 1
fi

for _ in {1..30}; do
  if [[ -n "${VPN_SRC}" ]]; then
    break
  fi
  sleep 1
  VPN_SRC="$(detect_ipsec_vip)"
  if [[ -z "${VPN_SRC}" ]]; then
    VPN_SRC="$(detect_configured_vip)"
  fi
done

if [[ -z "${VPN_SRC}" ]]; then
  echo "vpn-policy-routing: VPN source address (10.10.10.x) is not available" >&2
  exit 1
fi

ip addr add "${VPN_SRC}/32" dev lo 2>/dev/null || true

if ! awk '{print $1" "$2}' /etc/iproute2/rt_tables | awk -v id="${TABLE_ID}" -v name="${TABLE_NAME}" '$1==id && $2==name{found=1} END{exit(found?0:1)}'; then
  printf '%s %s\n' "${TABLE_ID}" "${TABLE_NAME}" >> /etc/iproute2/rt_tables
fi

ip route flush table "${TABLE_ID}" || true
ip route add "${VPN_SERVER}" via "${MAIN_GW}" dev "${MAIN_IF}" src "${MAIN_SRC}" table "${TABLE_ID}"
ip route add default via "${MAIN_GW}" dev "${MAIN_IF}" src "${VPN_SRC}" table "${TABLE_ID}"

# Keep local Docker bridge networks local even when this table is selected.
while read -r subnet spec; do
  [[ -z "${subnet}" ]] && continue
  ip route replace "${subnet}" ${spec} table "${TABLE_ID}" 2>/dev/null || true
done < <(ip route show table main | awk '$2=="dev" && ($3=="docker0" || $3 ~ /^br-/) {sub(/ linkdown/, ""); print}')

for cidr in ${DIRECT_CIDRS}; do
  ip route replace "${cidr}" via "${MAIN_GW}" dev "${MAIN_IF}" src "${MAIN_SRC}" table "${TABLE_ID}" 2>/dev/null || true
done

ip rule del pref 220 2>/dev/null || true
ip rule del pref 200 2>/dev/null || true
ip rule add pref 200 uidrange "${VPN_UID}-${VPN_UID}" lookup "${TABLE_ID}"

route_container_via_vpn() {
  local name="$1" pref="$2" cip
  cip="$(docker inspect "${name}" --format '{{with index .NetworkSettings.Networks "web"}}{{.IPAddress}}{{end}}' 2>/dev/null || true)"
  if [[ -z "${cip}" ]]; then
    cip="$(docker inspect "${name}" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' 2>/dev/null | awk '/^172\./ {print; exit}')"
  fi
  [[ -z "${cip}" ]] && return 0

  ip rule del pref "${pref}" 2>/dev/null || true
  ip rule add pref "${pref}" from "${cip}/32" lookup "${TABLE_ID}"

  while iptables -t nat -D POSTROUTING -s "${cip}/32" -d 172.16.0.0/12 -j RETURN 2>/dev/null; do :; done
  while iptables -t nat -D POSTROUTING -s "${cip}/32" -p tcp --dport 465 -j MASQUERADE 2>/dev/null; do :; done
  while iptables -t nat -D POSTROUTING -s "${cip}/32" -p tcp --dport 587 -j MASQUERADE 2>/dev/null; do :; done
  while iptables -t nat -D POSTROUTING -s "${cip}/32" -j SNAT --to-source "${VPN_SRC}" 2>/dev/null; do :; done
  for cidr in ${DIRECT_CIDRS}; do
    while iptables -t nat -D POSTROUTING -s "${cip}/32" -d "${cidr}" -j SNAT --to-source "${MAIN_SRC}" 2>/dev/null; do :; done
  done

  iptables -t nat -I POSTROUTING 1 -s "${cip}/32" -d 172.16.0.0/12 -j RETURN
  iptables -t nat -I POSTROUTING 2 -s "${cip}/32" -p tcp --dport 465 -j MASQUERADE
  iptables -t nat -I POSTROUTING 3 -s "${cip}/32" -p tcp --dport 587 -j MASQUERADE
  iptables -t nat -I POSTROUTING 4 -s "${cip}/32" -j SNAT --to-source "${VPN_SRC}"
  for cidr in ${DIRECT_CIDRS}; do
    iptables -t nat -I POSTROUTING 1 -s "${cip}/32" -d "${cidr}" -j SNAT --to-source "${MAIN_SRC}"
  done

  while iptables -t mangle -D FORWARD -s "${cip}/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${TELEGRAM_MSS}" 2>/dev/null; do :; done
  while iptables -t mangle -D FORWARD -d "${cip}/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${TELEGRAM_MSS}" 2>/dev/null; do :; done
  iptables -t mangle -I FORWARD 1 -s "${cip}/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${TELEGRAM_MSS}"
  iptables -t mangle -I FORWARD 2 -d "${cip}/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${TELEGRAM_MSS}"
}

if command -v docker >/dev/null 2>&1; then
  declare -A CURRENT_VPN_IPS=()
  for entry in ${VPN_CONTAINERS}; do
    cname="${entry%%:*}"
    cip="$(docker inspect "${cname}" --format '{{with index .NetworkSettings.Networks "web"}}{{.IPAddress}}{{end}}' 2>/dev/null || true)"
    [[ -n "${cip}" ]] && CURRENT_VPN_IPS["${cip}"]=1
  done

  while read -r pref fromip; do
    [[ -z "${fromip}" ]] && continue
    if [[ -z "${CURRENT_VPN_IPS[${fromip}]:-}" ]]; then
      ip rule del pref "${pref}" 2>/dev/null || true
    fi
  done < <(ip rule show | sed -n 's/^\([0-9]\{3\}\):[[:space:]]*from \([0-9.]\+\)[[:space:]]\+lookup codexvpn.*/\1 \2/p' | awk '$1>=205 && $1<=219')

  while read -r staleip; do
    [[ -z "${staleip}" ]] && continue
    [[ -n "${CURRENT_VPN_IPS[${staleip}]:-}" ]] && continue
    while iptables -t nat -D POSTROUTING -s "${staleip}/32" -j SNAT --to-source "${VPN_SRC}" 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -s "${staleip}/32" -d 172.16.0.0/12 -j RETURN 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -s "${staleip}/32" -p tcp --dport 465 -j MASQUERADE 2>/dev/null; do :; done
    while iptables -t nat -D POSTROUTING -s "${staleip}/32" -p tcp --dport 587 -j MASQUERADE 2>/dev/null; do :; done
    for cidr in ${DIRECT_CIDRS}; do
      while iptables -t nat -D POSTROUTING -s "${staleip}/32" -d "${cidr}" -j SNAT --to-source "${MAIN_SRC}" 2>/dev/null; do :; done
    done
    while iptables -t mangle -D FORWARD -s "${staleip}/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${TELEGRAM_MSS}" 2>/dev/null; do :; done
    while iptables -t mangle -D FORWARD -d "${staleip}/32" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "${TELEGRAM_MSS}" 2>/dev/null; do :; done
  done < <(iptables -t nat -S POSTROUTING | sed -n "s|.*-s \([0-9.]\+\)/32 -j SNAT --to-source ${VPN_SRC//./\\.}\$|\1|p" | sort -u)

  for entry in ${VPN_CONTAINERS}; do
    cname="${entry%%:*}"
    cpref="${entry##*:}"
    for _ in {1..40}; do
      if docker inspect "${cname}" >/dev/null 2>&1; then
        break
      fi
      sleep 3
    done
    if docker inspect "${cname}" >/dev/null 2>&1; then
      route_container_via_vpn "${cname}" "${cpref}"
    else
      echo "vpn-policy-routing: container ${cname} not present, skipping" >&2
    fi
  done
fi

# Prevent IPv6 bypass for the always-routed Codex user.
ip -6 rule del pref 201 2>/dev/null || true
ip -6 rule add pref 201 uidrange "${VPN_UID}-${VPN_UID}" prohibit
