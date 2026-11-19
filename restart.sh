#!/usr/bin/env bash
set -Eeuo pipefail

TULIP_DIR="${TULIP_DIR:-/opt/tulip}"
COMPOSE_FILE="${COMPOSE_FILE:-$TULIP_DIR/docker-compose.yml}"
SERVICES=(timescale api frontend assembler enricher)

log() { printf '[restart] %s\n' "$*"; }
die() { printf '[restart] ERROR: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker is not installed"
[ -f "$COMPOSE_FILE" ] || die "compose file not found: $COMPOSE_FILE"
cd "$TULIP_DIR"

docker compose -f "$COMPOSE_FILE" config --quiet || die "invalid Docker Compose configuration"

# Tulip's upstream compose sets this to 128g, which can reserve excessive shared
# memory on a contest server. Keep the intended cache allowance at 128 MiB.
if grep -Eq '^[[:space:]]*shm_size:[[:space:]]*['"'"']?128g['"'"']?[[:space:]]*$' "$COMPOSE_FILE"; then
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$COMPOSE_FILE" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
updated, count = re.subn(
    r'(?m)^(\s*shm_size:\s*)["\']?128g["\']?\s*$',
    r'\g<1>128m',
    text,
    count=1,
)
if count != 1:
    raise SystemExit("could not set TimescaleDB shm_size to 128m")
path.write_text(updated)
PY
  else
    die "python3 is required to safely adjust shm_size in $COMPOSE_FILE"
  fi
  log "Changed TimescaleDB shared memory from 128g to 128m"
fi

log "Stopping and removing Tulip containers (database volume and PCAPs are preserved)"
docker compose -f "$COMPOSE_FILE" down --remove-orphans

log "Rebuilding images and starting Tulip"
docker compose -f "$COMPOSE_FILE" build "${SERVICES[@]}"
docker compose -f "$COMPOSE_FILE" up -d --force-recreate "${SERVICES[@]}"

log "Tulip containers recreated"
docker compose -f "$COMPOSE_FILE" ps
log "For memory usage: docker stats --no-stream"
