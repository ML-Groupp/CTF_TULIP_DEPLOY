#!/usr/bin/env bash
set -euo pipefail

TULIP_DIR="${TULIP_DIR:-/opt/tulip}"
INSTALLER="${TULIP_INSTALLER:-/root/tulip-install.sh}"
cd "$TULIP_DIR"

case "${1:-status}" in
  status)
    docker compose ps
    docker ps --filter name=caddy --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || true
    ;;
  logs)
    shift
    docker compose logs -f --tail=100 "$@"
    ;;
  restart)
    docker compose restart
    docker restart caddy >/dev/null 2>&1 || true
    echo "restarted"
    ;;
  services)
    "${EDITOR:-nano}" "$TULIP_DIR/services.txt"
    bash "$INSTALLER" --config-only
    docker compose up -d --build api
    echo "api rebuilt"
    ;;
  reset)
    docker compose down -v
    docker compose up -d timescale api frontend assembler enricher
    echo "database reset"
    ;;
  update)
    bash "$INSTALLER" --ref origin/master
    ;;
  *)
    echo "usage: tulip {status|logs [service]|restart|services|reset|update}" >&2
    exit 1
    ;;
esac