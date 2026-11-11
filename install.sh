#!/usr/bin/env bash
set -euo pipefail

TULIP_REPO="${TULIP_REPO:-https://github.com/OpenAttackDefenseTools/tulip.git}"
TULIP_REF="${TULIP_REF:-523e5179043a5b6ae1bbcc1990d774f23166319b}"
TULIP_DIR="${TULIP_DIR:-/opt/tulip}"
WEB_USER="${WEB_USER:-team}"
WEBPASS="${WEBPASS:-}"
DOMAIN="${DOMAIN:-}"
SERVICES="${SERVICES:-}"
TICK_START="${TICK_START:-}"
FLAG_REGEX="${FLAG_REGEX:-}"
VM_IP="${VM_IP:-10.10.3.1}"
TICK_LENGTH="${TICK_LENGTH:-180000}"
SSH_PORT="${SSH_PORT:-22}"

WITH_CADDY=1
WITH_FIREWALL=1
CONFIG_ONLY=0
FORCE=0

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: install.sh [options]

  --no-caddy        skip HTTPS reverse proxy (SSH tunnel only)
  --no-firewall     do not touch ufw
  --config-only     only regenerate .env / services.txt / configurations.py
  --force           overwrite existing .env and services.txt
  --ref <git-ref>   Tulip version (default: pinned commit)
  --dir <path>      install path (default: /opt/tulip)

Env: IP WEBPASS DOMAIN SERVICES TICK_START FLAG_REGEX VM_IP TICK_LENGTH WEB_USER SSH_PORT
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-caddy) WITH_CADDY=0 ;;
    --no-firewall) WITH_FIREWALL=0 ;;
    --config-only) CONFIG_ONLY=1 ;;
    --force) FORCE=1 ;;
    --ref) TULIP_REF="${2:?}"; shift ;;
    --dir) TULIP_DIR="${2:?}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || die "run as root"

if [ -t 0 ] && [ "$CONFIG_ONLY" -eq 0 ]; then
  [ -n "$TICK_START" ] || read -r -p "CTF start, UTC (e.g. 2026-11-15T09:00:00Z): " TICK_START
  [ -n "$SERVICES" ]  || read -r -p "Services (ip:port name, ip:port name): " SERVICES
  [ -n "$WEBPASS" ]   || { read -r -s -p "Web password (empty = random): " WEBPASS; echo; }
fi

TICK_START="${TICK_START:-$(date -u +%Y-%m-%dT%H:00:00Z)}"
[ -n "$FLAG_REGEX" ] || FLAG_REGEX='[A-Z0-9]{31}='

if [ -z "$WEBPASS" ]; then
  WEBPASS="$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-24)"
fi

if [ "$CONFIG_ONLY" -eq 0 ]; then
  export DEBIAN_FRONTEND=noninteractive
  log "Installing base packages"
  apt-get update -qq
  apt-get install -y -qq git curl ca-certificates python3 >/dev/null

  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true

  swap_mb="$(free -m | awk '/^Swap:/{print $2}')"
  if [ "${swap_mb:-0}" -lt 2048 ] && [ ! -f /swapfile ]; then
    log "Creating 4G swap"
    fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
fi

if [ ! -d "$TULIP_DIR/.git" ]; then
  log "Cloning Tulip"
  git clone "$TULIP_REPO" "$TULIP_DIR"
fi

cd "$TULIP_DIR"
git fetch -q origin
git reset -q --hard "$TULIP_REF"

log "Applying build fixes"
cat > services/timescale/Dockerfile <<'EOF'
FROM timescale/timescaledb:latest-pg15 AS builder
RUN apk add --no-cache build-base git
COPY tulip /tulip
RUN cd /tulip && make USE_PGXS=1 with_llvm=no install && \
    git clone --depth 1 https://github.com/ossc-db/pg_hint_plan --branch PG15 && \
    cd pg_hint_plan && make USE_PGXS=1 with_llvm=no install

FROM timescale/timescaledb:latest-pg15
COPY --from=builder /usr/local/lib/postgresql/ /usr/local/lib/postgresql/
COPY --from=builder /usr/local/share/postgresql/extension/ /usr/local/share/postgresql/extension/
EOF

grep -q '127.0.0.1:3000:3000' docker-compose.yml || sed -i 's/- "3000:3000"/- "127.0.0.1:3000:3000"/' docker-compose.yml
grep -q '127.0.0.1:3000:3000' docker-compose.yml || die 'could not bind frontend to localhost, check docker-compose.yml'

if [ ! -f .env ] || [ "$FORCE" -eq 1 ]; then
  log "Writing .env"
  cat > .env <<EOF
TIMESCALE="postgres://tulip@timescale:5432/tulip"
TRAFFIC_DIR_HOST="$TULIP_DIR/traffic"
TRAFFIC_DIR_DOCKER="/traffic"
BPF=""
VISUALIZER_URL=""
TICK_START="$TICK_START"
TICK_LENGTH=$TICK_LENGTH
FLAG_REGEX="$FLAG_REGEX"
VM_IP="$VM_IP"
TEAM_ID="1"
PCAP_OVER_IP=
DUMP_PCAPS=
DUMP_PCAPS_INTERVAL="1m"
DUMP_PCAPS_FILENAME="2006-01-02_15-04-05.pcap"
FLAGID_SCRAPE=
FLAGID_SCAN=
FLAG_LIFETIME=
FLAGID_ENDPOINT="http://flagidendpoint:8000/flagids.json"
FLAG_VALIDATOR_TYPE=
FLAG_VALIDATOR_TEAM=42
SURICATA_DIR_HOST="./suricata"
EOF
else
  warn ".env exists, keeping it (use --force to overwrite)"
fi

if [ ! -f services.txt ] || [ "$FORCE" -eq 1 ]; then
  if [ -n "$SERVICES" ]; then
    printf '%s\n' "$SERVICES" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d' > services.txt
  else
    printf '%s\n' "# ip:port name" "$VM_IP:8080 service1" "$VM_IP:5555 service2" > services.txt
  fi
fi

mkdir -p "$TULIP_DIR/traffic"
chmod 755 "$TULIP_DIR/traffic"

log "Generating service map"
SERVICES_FILE="$TULIP_DIR/services.txt" python3 - > services/api/configurations.py <<'PY'
import json, os

items = []
for raw in open(os.environ["SERVICES_FILE"], encoding="utf-8"):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    addr, name = line.split(None, 1)
    ip, port = addr.rsplit(":", 1)
    items.append({"ip": ip, "port": int(port), "name": name})

print("import os")
print("from pathlib import Path")
print()
print('traffic_dir = Path(os.getenv("TULIP_TRAFFIC_DIR", "/traffic"))')
print('dump_pcaps_dir = Path(os.getenv("DUMP_PCAPS", "/traffic"))')
print('tick_length = int(os.getenv("TICK_LENGTH") or 180000)')
print('flag_lifetime = int(os.getenv("FLAG_LIFETIME") or 5)')
print('start_date = os.getenv("TICK_START", "2026-01-01T00:00:00Z")')
print('flag_regex = os.getenv("FLAG_REGEX", "[A-Z0-9]{31}=")')
print('vm_ip = os.getenv("VM_IP", "10.10.3.1")')
print('visualizer_url = os.getenv("VISUALIZER_URL", "http://127.0.0.1:1337")')
print()
print("services = " + json.dumps(items, indent=4))
print()
print('services.append({"ip": vm_ip, "port": -1, "name": "other"})')
PY

if [ "$CONFIG_ONLY" -eq 1 ]; then
  log "Config regenerated in $TULIP_DIR"
  exit 0
fi

log "Building images (10-30 min on 1 vCPU)"
for svc in timescale api frontend; do
  docker compose build "$svc"
  docker builder prune -af >/dev/null
done
docker compose build assembler enricher
docker builder prune -af >/dev/null

log "Starting Tulip"
docker compose up -d timescale api frontend assembler enricher

log "Waiting for API"
code=""
for _ in $(seq 1 90); do
  code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/api/services || true)"
  [ "$code" = "200" ] && break
  sleep 2
done
[ "$code" = "200" ] || die "API did not come up, check: docker compose logs api"

if [ "$WITH_CADDY" -eq 1 ]; then
  IP="${IP:-$(curl -4 -fsS --max-time 5 https://ifconfig.me || true)}"
  [ -n "$IP" ] || IP="$(hostname -I | awk '{print $1}')"
  DOMAIN="${DOMAIN:-$(printf '%s' "$IP" | tr '.' '-').sslip.io}"
  log "Setting up HTTPS on $DOMAIN"

  HASH="$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$WEBPASS")"
  mkdir -p /opt/caddy
  cat > /opt/caddy/Caddyfile <<EOF
{
	admin off
}

https://$DOMAIN {
	basic_auth {
		$WEB_USER $HASH
	}
	reverse_proxy frontend:3000
}
EOF

  docker rm -f caddy >/dev/null 2>&1 || true
  docker run -d --name caddy --restart unless-stopped --network tulip_internal \
    -p 80:80 -p 443:443 \
    -v /opt/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
    -v caddy_data:/data -v caddy_config:/config \
    caddy:2-alpine >/dev/null
  sleep 15
fi

if [ "$WITH_FIREWALL" -eq 1 ] && command -v ufw >/dev/null 2>&1; then
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow "$SSH_PORT"/tcp >/dev/null
  if [ "$WITH_CADDY" -eq 1 ]; then
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
  fi
  ufw --force enable >/dev/null
fi

{
  echo "Tulip installed $(date -u +%F)"
  echo "dir: $TULIP_DIR"
  if [ "$WITH_CADDY" -eq 1 ]; then echo "url: https://$DOMAIN"; fi
  echo "login: $WEB_USER"
  echo "password: $WEBPASS"
} > /root/tulip-access.txt
chmod 600 /root/tulip-access.txt

if [ "$WITH_CADDY" -eq 1 ]; then
  ACCESS="https://$DOMAIN"
else
  ACCESS="ssh -L 3000:127.0.0.1:3000 root@${IP:-SERVER_IP}  ->  http://localhost:3000"
fi

cat <<EOF

  Tulip is up.

  Access:   $ACCESS
  Login:    $WEB_USER
  Password: $WEBPASS

  Services: $TULIP_DIR/services.txt
  Game cfg: $TULIP_DIR/.env
  PCAPs:    $TULIP_DIR/traffic
  Saved to: /root/tulip-access.txt

EOF