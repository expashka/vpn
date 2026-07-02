# NL IKEv2 VPN

Установка strongSwan, подключение к NL-серверу по IKEv2 и переключение
исходящего трафика root через VPN.

Установщик также добавляет публичный корневой сертификат `VPN Root CA` и
проверяет его SHA-256 fingerprint перед установкой.
Физический адрес IKEv2-клиента определяется только по основной таблице
маршрутизации, поэтому повторное подключение не использует старый VPN-адрес.

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

- `vpn on` устанавливает IKEv2 и направляет исходящий трафик root через NL;
- `vpn off` удаляет правило root и отключает IKEv2;
- `vpn status` показывает соединение, режим root и внешний IPv4.

После `vpn on` Codex можно запускать от root обычной командой:

```bash
codex
```

Отдельный пользователь и обёртка с `sudo -iu` не требуются.

Сообщения `adding DNS server failed` и `unable to install source route` допустимы
до применения таблицы командой `vpn on`. Соединение установлено, если вывод содержит
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
