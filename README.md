# NL IKEv2 VPN

Минимальная установка strongSwan и подключения к NL-серверу по IKEv2.
Маршрутизация трафика на этом этапе не настраивается.

Установщик также добавляет публичный корневой сертификат `VPN Root CA` и
проверяет его SHA-256 fingerprint перед установкой.

## Установка Одной Командой

Для Debian или Ubuntu:

```bash
curl -fsSL "https://raw.githubusercontent.com/expashka/vpn/main/install.sh?v=$(date +%s)" | sudo bash
```

Параметр с текущим временем не даёт прокси провайдера использовать старую
закэшированную версию установщика.

При первом запуске установщик запросит:

- IP-адрес VPN-сервера, по умолчанию `212.118.54.47`;
- логин / IKEv2 identity;
- пароль.

После установки соединение автоматически запускается командой `vpn on`.

## Управление

```bash
sudo vpn on
sudo vpn off
sudo vpn status
```

- `vpn on` устанавливает IKEv2-соединение `nl-ikev2`;
- `vpn off` отключает соединение;
- `vpn status` показывает состояние соединения.

Сообщения `adding DNS server failed` и `unable to install source route` допустимы
на этапе без настройки маршрутизации. Соединение установлено, если вывод содержит
`IKE_SA ... established`, `CHILD_SA ... established` и
`connection 'nl-ikev2' established successfully`.

Расширенная диагностика:

```bash
sudo ipsec statusall
sudo journalctl -u strongswan-starter.service -n 100 --no-pager
```

## Повторная Установка

Команду установки можно запустить повторно. Сохранённые параметры читаются из
`/etc/codex-vpn.env`. Чтобы заново ввести логин или пароль, удалите этот файл:

```bash
sudo rm /etc/codex-vpn.env
```

Затем снова запустите установку одной командой.

Если `vpn on` заканчивается сообщением `EAP-MS-CHAPv2 failed`, сервер отклонил
пару логин/пароль. Удалите конфигурацию и введите реквизиты заново.

## Устанавливаемые Файлы

- `/etc/codex-vpn.env`
- `/etc/ipsec.conf`
- `/etc/ipsec.secrets`
- `/etc/ipsec.d/cacerts/ca-cert.pem`
- `/etc/strongswan.d/charon/codex-vpn.conf`
- `/usr/local/bin/vpn`

Файлы `/etc/codex-vpn.env` и `/etc/ipsec.secrets` создаются с правами `600`.
