# Codex VPN

Portable setup for the same selective NL IKEv2 VPN routing used on the current
server.

What it installs:

- strongSwan IKEv2 client connected to NL server `212.118.54.47` by default.
- Linux user `vpn`; all traffic from this user is always routed through VPN.
- `/usr/local/bin/vpn` with `vpn on`, `vpn off`, `vpn status` for root only.
- `vpn-policy-routing.service`, which builds routing table `200 codexvpn`.
- Optional Docker container routing by container name.

The normal server traffic stays on the provider uplink. Codex should be run
under the `vpn` user, so it always exits through NL even when root routing is
off.

## Install On A New Server

```bash
git clone https://github.com/expashka/vpn.git
cd vpn
sudo ./install.sh
```

The first run asks for:

- NL VPN server IPv4, default `212.118.54.47`
- NL VPN login / IKEv2 identity
- NL VPN password
- Linux user for Codex, default `vpn`
- whether to enable root VPN immediately

The installer writes secrets to `/etc/codex-vpn.env` and `/etc/ipsec.secrets`
with mode `600`. Do not commit real secrets to the repo.

You can also prefill values:

```bash
cp env.example codex-vpn.env
nano codex-vpn.env
sudo ./install.sh
```

## Usage

```bash
sudo vpn status
sudo vpn on
sudo vpn off
```

Expected behavior:

- `sudo vpn on`: root exits through NL.
- `sudo vpn off`: root exits directly through the server provider.
- `sudo -iu vpn`: Codex user always exits through NL.

Run Codex:

```bash
sudo -iu vpn
codex
```

Check:

```bash
sudo vpn status
sudo runuser -u vpn -- curl -4 -s https://api.ipify.org
sudo ipsec statusall
ip rule show
ip route show table codexvpn
```

## Optional Docker Containers

Edit `/etc/codex-vpn.env`:

```bash
VPN_CONTAINERS="telegram-notify-1:205 codex-sidecar-1:206"
```

Then apply:

```bash
sudo systemctl restart vpn-policy-routing.service
```

If a deploy recreates containers and changes their IPs, run the same restart
after `docker compose up -d --force-recreate`. For deploy hooks, copy
`hooks/post-up.sh` into the project's `.deploy/post-up.sh`.

## Direct CIDR Bypass

Some destinations may need the real server IP, not NL. Add them as
space-separated CIDRs:

```bash
DIRECT_CIDRS="87.240.128.0/18 93.186.224.0/20 95.142.192.0/20 95.213.0.0/18"
sudo systemctl restart vpn-policy-routing.service
```

## Files Installed

- `/etc/codex-vpn.env`
- `/etc/ipsec.conf`
- `/etc/ipsec.secrets`
- `/etc/strongswan.d/charon/codex-vpn.conf`
- `/usr/local/bin/vpn`
- `/usr/local/sbin/vpn-policy-routing.sh`
- `/etc/systemd/system/vpn-policy-routing.service`
