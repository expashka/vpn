# Codex VPN

Переносимая настройка NL IKEv2 VPN для серверов, где Codex должен работать
через нероссийский выход.

Что ставится:

- strongSwan IKEv2-клиент с NL-сервером `212.118.54.47` по умолчанию.
- Linux-пользователь `vpn`; весь трафик этого пользователя всегда идёт через VPN.
- Команда `/usr/local/bin/vpn`: `vpn on`, `vpn off`, `vpn status` для root.
- `vpn-policy-routing.service`, который собирает таблицу маршрутизации `200 codexvpn`.
- Опциональная маршрутизация выбранных Docker-контейнеров через VPN.

Обычный трафик сервера остаётся на прямом uplink провайдера. Codex нужно запускать
под пользователем `vpn`, тогда он всегда будет выходить через NL, даже если root VPN
выключен.

## Установка На Новый Сервер

Установка одной командой:

```bash
curl -fsSL https://raw.githubusercontent.com/expashka/vpn/main/install.sh | sudo bash
```

При первом запуске установщик спросит:

- IPv4 NL VPN-сервера, по умолчанию `212.118.54.47`
- логин / IKEv2 identity от NL-сервера
- пароль от NL-сервера
- Linux-пользователя для Codex, по умолчанию `vpn`
- включать ли VPN для root сразу после установки

Ручная установка через clone:

```bash
git clone https://github.com/expashka/vpn.git
cd vpn
sudo ./install.sh
```

Установщик сохраняет секреты в `/etc/codex-vpn.env` и `/etc/ipsec.secrets` с
правами `600`. Настоящие пароли в репозиторий не коммитить.

Если нужно заранее заполнить конфиг:

```bash
cp env.example codex-vpn.env
nano codex-vpn.env
sudo ./install.sh
```

## Использование

```bash
sudo vpn status
sudo vpn on
sudo vpn off
```

Ожидаемое поведение:

- `sudo vpn on`: root выходит через NL.
- `sudo vpn off`: root выходит напрямую через провайдера сервера.
- `sudo -iu vpn`: пользователь Codex всегда выходит через NL.

Запуск Codex:

```bash
sudo -iu vpn
codex
```

Проверки:

```bash
sudo vpn status
sudo runuser -u vpn -- curl -4 -s https://api.ipify.org
sudo ipsec statusall
ip rule show
ip route show table codexvpn
```

## Docker-Контейнеры Через VPN

Если нужно завести отдельные контейнеры в VPN, отредактируй `/etc/codex-vpn.env`:

```bash
VPN_CONTAINERS="telegram-notify-1:205 codex-sidecar-1:206"
```

Формат: `имя_контейнера:pref`, где `pref` должен быть уникальным числом для
`ip rule`.

Применить:

```bash
sudo systemctl restart vpn-policy-routing.service
```

Если деплой пересоздаёт контейнеры и меняет их IP, после `docker compose up -d
--force-recreate` нужно снова перезапустить `vpn-policy-routing.service`.
Для deploy-hook можно скопировать `hooks/post-up.sh` в `.deploy/post-up.sh`
проекта.

## Прямой Выход Для Отдельных CIDR

Некоторые направления могут требовать реальный IP сервера, а не NL. Добавь их
CIDR-ами через пробел:

```bash
DIRECT_CIDRS="87.240.128.0/18 93.186.224.0/20 95.142.192.0/20 95.213.0.0/18"
sudo systemctl restart vpn-policy-routing.service
```

## Куда Ставятся Файлы

- `/etc/codex-vpn.env`
- `/etc/ipsec.conf`
- `/etc/ipsec.secrets`
- `/etc/strongswan.d/charon/codex-vpn.conf`
- `/usr/local/bin/vpn`
- `/usr/local/sbin/vpn-policy-routing.sh`
- `/etc/systemd/system/vpn-policy-routing.service`
