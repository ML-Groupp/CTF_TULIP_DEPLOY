# tulip-deploy

Установщик [Tulip](https://github.com/OpenAttackDefenseTools/tulip) для Attack/Defense CTF: одна команда — рабочий стенд с HTTPS и логином.

Репозиторий не форкает Tulip, а тянет upstream на зафиксированном коммите и применяет два обязательных патча (сборка TimescaleDB и привязка фронта к localhost). Обновление — осознанно, через `tulip update`.

## Требования

- Ubuntu 22.04 / 24.04, root
- 2 ГБ RAM минимум (установщик сам добавит 4 ГБ swap), лучше 4 ГБ
- 25–40 ГБ диска: образы + база + pcap
- Открытые 80/443, если нужен веб-доступ

## Установка

```bash
git clone https://github.com/godofhustle/tulip-deploy.git /root/tulip-deploy
bash /root/tulip-deploy/install.sh
```

Скрипт спросит три вещи: время старта CTF (UTC), список сервисов и пароль для веба (можно оставить пустым — сгенерирует сам).

Неинтерактивный вариант:

```bash
TICK_START="2026-11-15T09:00:00Z" \
FLAG_REGEX="[A-Z0-9]{31}=" \
SERVICES="10.10.3.1:8080 service1, 10.10.3.1:5555 service2" \
WEBPASS="MyTeamPass123" \
bash /root/tulip-deploy/install.sh
```

### Флаги

| Флаг | Что делает |
|---|---|
| `--no-caddy` | без HTTPS-прокси, доступ только через SSH-туннель |
| `--no-firewall` | не трогать ufw |
| `--config-only` | только перегенерить `.env`, `services.txt`, `configurations.py` |
| `--force` | перезаписать существующие `.env` и `services.txt` |
| `--ref <git-ref>` | версия Tulip (по умолчанию зафиксированный коммит) |
| `--dir <path>` | каталог установки (по умолчанию `/opt/tulip`) |

## Что делает установщик

1. Ставит Docker, git, swap 4 ГБ.
2. Клонирует Tulip в `/opt/tulip` на проверенном коммите.
3. Патчит `services/timescale/Dockerfile` (иначе сборка падает на `clang-19`) и биндит фронт на `127.0.0.1:3000`.
4. Генерит `.env` (время старта, флаг-регекс, VM IP) и `services/api/configurations.py` из `services.txt`.
5. Собирает образы по очереди с очисткой кэша (важно на маленьком диске).
6. Поднимает `timescale, api, frontend, assembler, enricher`.
7. Ставит Caddy: HTTPS через Let's Encrypt (имя `<ip-через-дефисы>.sslip.io`) + Basic Auth.
8. Настраивает ufw: 22, 80, 443.
9. Пишет доступы в `/root/tulip-access.txt`.

## После установки

```bash
cat /root/tulip-access.txt
```

Там URL, логин и пароль. Файлы конфигурации:

- `/opt/tulip/.env` — время старта, длина тика, флаг-регекс, VM IP
- `/opt/tulip/services.txt` — список сервисов
- `/opt/tulip/traffic` — сюда кладутся pcap

Формат `services.txt` (по одному в строке):

```
10.10.3.1:8080 service1
10.10.3.1:5555 service2
```

## День A/D

1. Прописать сервисы и пересобрать api:

```bash
/root/tulip-deploy/tulip.sh services
```

2. Проверить `.env` (особенно `TICK_START` и `FLAG_REGEX`) и перезапустить:

```bash
cd /opt/tulip && docker compose up -d
```

3. На vulnbox снимать трафик и забирать его на сервер:

```bash
mkdir -p /pcaps
tcpdump -i eth0 -G 300 -w '/pcaps/traffic_%Y-%m-%d_%H-%M-%S.pcap'

# cron на vulnbox, каждую минуту
* * * * * rsync -az --remove-source-files /pcaps/ root@TULIP_IP:/opt/tulip/traffic/
```

4. Убедиться, что трафик заходит:

```bash
cd /opt/tulip && docker compose logs -f assembler
```

Assembler сам подхватывает новые файлы, перезапуск не нужен.

## Управление

```bash
/root/tulip-deploy/tulip.sh status          # контейнеры
/root/tulip-deploy/tulip.sh logs api        # логи сервиса
/root/tulip-deploy/tulip.sh restart         # перезапуск
/root/tulip-deploy/tulip.sh services        # редактор списка + пересборка api
/root/tulip-deploy/tulip.sh reset           # снести базу и поднять заново
/root/tulip-deploy/tulip.sh update          # обновить Tulip до origin/master
```

Если положить скрипт в `/usr/local/bin/tulip`, можно писать `tulip status` и т.д.

## Доступ по SSH

Только по ключу:

```bash
ssh -i ~/.ssh/tulip_key root@SERVER_IP
```

Туннель до веба, если не хочется вводить пароль:

```bash
ssh -i ~/.ssh/tulip_key -L 3000:127.0.0.1:3000 root@SERVER_IP
# затем http://localhost:3000
```

## Обновление, сброс, удаление

```bash
# обновить код Tulip и пересобрать
/root/tulip-deploy/tulip.sh update

# откатиться на конкретный коммит
TULIP_REF=<sha> bash /root/tulip-deploy/install.sh

# полный сброс базы (pcap остаются)
/root/tulip-deploy/tulip.sh reset

# удалить всё
cd /opt/tulip && docker compose down -v
docker rm -f caddy
docker volume rm caddy_data caddy_config 2>/dev/null || true
rm -rf /opt/tulip /opt/caddy
```

## Если что-то сломалось

- `make: clang-19: No such file` — патч не применился, перезапусти `install.sh` (он перезапишет Dockerfile).
- `no space left on device` — `docker builder prune -af` и `docker image prune -f`, затем повтори сборку.
- `api` пишет `connection refused` первые 20 секунд — это нормально, ждёт Postgres.
- 502 от Caddy — проверь `docker compose ps`, обычно лежит `api` или `timescale`.
- Браузер ругается на сертификат — убедись, что заходишь по имени `*.sslip.io`, а не по IP (для IP браузер не шлёт SNI).
- Свой домен: `DOMAIN=tulip.example.com bash /root/tulip-deploy/install.sh`, A-запись должна указывать на сервер.

## Структура репозитория

```
install.sh            основной установщик
tulip.sh              управление стеком
services.example.txt  пример списка сервисов
README.md
```