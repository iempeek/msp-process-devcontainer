#!/usr/bin/env bash
# .devcontainer/infra-up.sh
# Runs on every container START (postStartCommand).
#
# PREPARES the infrastructure without starting it: creates the shared network,
# attaches THIS devcontainer to it (so sidecars are reachable by name, e.g.
# http://sonarqube:9000), pre-creates the sidecar data dirs and starts the
# soketi relay. It deliberately does NOT `compose up` the sidecars - starting
# ~10 containers on every container start costs minutes and RAM for a session
# that may never touch them. The sidecars are started on demand, and only the
# ones you select, by:
#
#   bash .devcontainer/local-stack.sh --run [-c <selection>]
#
# Usage: infra-up.sh [--with-sidecars]
#   --with-sidecars   also bring up EVERY compose service (the old behaviour),
#                     for when you really do want the whole stack at once.
set -euo pipefail
trap 'echo "[ERROR] infra-up.sh failed at line $LINENO while running: $BASH_COMMAND" >&2' ERR

NETWORK=mspprocess-infra
COMPOSE_FILE="$(dirname "$0")/compose.yaml"

WITH_SIDECARS=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-sidecars|--sidecars) WITH_SIDECARS=true ;;
    -h|--help)
      echo "Usage: infra-up.sh [--with-sidecars]"
      exit 0
      ;;
    *)
      echo "[ERROR] infra-up: unknown argument '$1' (see --help)." >&2
      exit 2
      ;;
  esac
  shift
done

# Docker socket may not be usable yet on very first create; fail soft.
if ! docker info >/dev/null 2>&1; then
  echo "[WARNING] infra-up: docker daemon not reachable, skipping infra startup."
  exit 0
fi

# 1. Shared network (external - survives compose down, reused across rebuilds)
docker network inspect "$NETWORK" >/dev/null 2>&1 \
  || docker network create "$NETWORK" >/dev/null

# 2. Attach the devcontainer itself to the network, with a STABLE ALIAS
#    ("devcontainer"). The alias mattered when the frontend ran as a sidecar
#    that had to reach back to the natively-hosted APIs; it is kept because
#    other sidecars (n8n, wiremock stubs) can still call back the same way.
#    Inside a container, $(hostname) is its own container ID. Docker won't
#    let you add an alias to an already-connected container, so on a
#    pre-existing attachment without the alias (e.g. container created before
#    this feature existed) this disconnects and reconnects to pick it up.
CONTAINER_ID="$(hostname)"
if docker inspect --format '{{json .NetworkSettings.Networks}}' "$CONTAINER_ID" 2>/dev/null \
     | grep -q "\"$NETWORK\":.*\"devcontainer\""; then
  : # already attached with the alias - nothing to do
else
  docker network disconnect "$NETWORK" "$CONTAINER_ID" 2>/dev/null || true
  docker network connect --alias devcontainer "$NETWORK" "$CONTAINER_ID" 2>/dev/null \
    || echo "[WARNING] infra-up: could not attach devcontainer (alias 'devcontainer') to $NETWORK." >&2
fi

# 3. Sidecar data dirs (bind-mounted from .adlc-artifacts/, see compose.yaml).
#    initialize.sh pre-creates these USER-owned on the host; the mkdir here
#    only covers manual `bash infra-up.sh` runs. Sidecars run AS THIS UID
#    (compose `user:` + the export below), so plain user ownership is enough -
#    no permission widening. Keep the dir list in sync with compose.yaml.
#    mssql is NOT listed here - it uses a named Docker volume, not a bind
#    mount (see the note on that service in compose.yaml).
WS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="$WS_ROOT/.adlc-artifacts"
# The frontend/cache dir is the shared pnpm store + yarn cache, still used by
# the natively-run Vite apps (see .devcontainer/local-stack-frontend.sh).
# The old per-app frontend/nm_<slug> dirs backed the retired frontend
# container's node_modules bind mounts and are no longer created or used.
if ! mkdir -p "$ARTIFACTS/mongo_data" "$ARTIFACTS/azurite_data" \
    "$ARTIFACTS/n8n_data" "$ARTIFACTS/frontend/cache"; then
  echo "[ERROR] infra-up: $ARTIFACTS is not writable. It was likely auto-created" >&2
  echo "        root-owned by the docker daemon (missing mount target). Fix on the" >&2
  echo "        host: sudo rm -rf .adlc-artifacts && bash .devcontainer/initialize.sh" >&2
  exit 1
fi

# Sidecars with bind-mounted data run as the current (host-mapped) uid/gid so
# their data dirs stay user-owned end to end. `docker compose down` from the
# host without these set falls back to the compose defaults (1000:1000).
export SIDECAR_UID="$(id -u)" SIDECAR_GID="$(id -g)"

# 4. Sidecars are NOT started here (see the header) - local-stack.sh --run
#    brings up the ones its selection actually needs. Only --with-sidecars
#    starts the whole set, and only if compose.yaml defines any (`docker
#    compose up` exits 1 with "no service selected" on an empty services map,
#    which would fail the whole postStartCommand).
if [ "$WITH_SIDECARS" = true ]; then
  if [ -z "$(docker compose -f "$COMPOSE_FILE" config --services 2>/dev/null)" ]; then
    echo "[INFO] infra-up: no services defined in compose.yaml, nothing to start."
    exit 0
  fi
  docker compose -p "$NETWORK" -f "$COMPOSE_FILE" up -d --remove-orphans
else
  echo "[INFO] infra-up: sidecars left stopped - start them on demand with"
  echo "       bash .devcontainer/local-stack.sh --run   (--with-sidecars here starts all)"
fi

# 5. Relay soketi to this container as localhost:6001. The frontend apps now
#    run natively here (see .devcontainer/local-stack.sh --run), so their
#    own ports need no relay at all and the backend hosts are plain localhost -
#    but the apps' baked-in Pusher URL is http://localhost:6001, and soketi is
#    a sidecar, so that one hop still has to exist for the browser (the
#    `playwright` MCP one included). Started even when soketi itself is
#    stopped: the listener binds immediately and only resolves/dials the
#    upstream per client connection, so it just starts working once the sidecar
#    comes up. An already-running relay is LEFT ALONE - local-stack.sh --run
#    re-runs this script per stack start, and needlessly recycling the listener
#    would drop live websocket connections.
RELAY_PID_FILE="$ARTIFACTS/local-stack/devcontainer-relay.pid"
mkdir -p "$(dirname "$RELAY_PID_FILE")"
RELAY_ALIVE_PID=""
if [ -f "$RELAY_PID_FILE" ]; then
  OLD_RELAY_PID="$(cat "$RELAY_PID_FILE" 2>/dev/null || true)"
  if [ -n "$OLD_RELAY_PID" ] && kill -0 "$OLD_RELAY_PID" 2>/dev/null; then
    RELAY_ALIVE_PID="$OLD_RELAY_PID"
  else
    rm -f "$RELAY_PID_FILE"
  fi
fi
# postStartCommand runs in a non-login shell whose PATH does not include the
# nvm-managed node from the devcontainer "node" feature - resolve the binary
# explicitly instead of trusting `command -v`.
NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ]; then
  for cand in /usr/local/share/nvm/current/bin/node /usr/local/share/nvm/versions/node/*/bin/node; do
    if [ -x "$cand" ]; then
      NODE_BIN="$cand"
      break
    fi
  done
fi

if [ -n "$RELAY_ALIVE_PID" ]; then
  echo "[INFO] infra-up: soketi relay already running on localhost:6001 (pid $RELAY_ALIVE_PID)."
elif ! docker compose -p "$NETWORK" -f "$COMPOSE_FILE" config --services 2>/dev/null | grep -qx soketi; then
  echo "[WARNING] infra-up: skipping soketi relay (no 'soketi' service in compose.yaml)." >&2
elif [ -z "$NODE_BIN" ]; then
  echo "[WARNING] infra-up: skipping soketi relay (node binary not found)." >&2
else
  nohup "$NODE_BIN" "$(dirname "$0")/local/frontend-settings/tcp-relay.mjs" \
    6001:soketi:6001 \
    > /tmp/devcontainer-relay.log 2>&1 &
  echo $! > "$RELAY_PID_FILE"
  echo "[INFO] infra-up: soketi relay started on localhost:6001 (pid $!, log: /tmp/devcontainer-relay.log)."
fi

# 6. If the sonarqube sidecar is defined AND we just started it, provision its
#    token in the BACKGROUND (the server takes ~1 min to come UP on cold start;
#    blocking postStartCommand on that would delay every container start). The
#    bootstrap is idempotent - a valid token in .env makes it a no-op. Skipped
#    when the sidecars weren't started: it would only time out against a
#    server that isn't there.
BOOTSTRAP="$(dirname "$0")/sonarqube-bootstrap.sh"
if [ "$WITH_SIDECARS" = true ] \
   && docker compose -p "$NETWORK" -f "$COMPOSE_FILE" config --services 2>/dev/null | grep -qx sonarqube \
   && [ -f "$BOOTSTRAP" ]; then
  echo "[INFO] infra-up: provisioning SonarQube token in background (log: /tmp/sonarqube-bootstrap.log)"
  nohup bash "$BOOTSTRAP" >/tmp/sonarqube-bootstrap.log 2>&1 &
fi

echo "[INFO] infra-up: done. Sidecars on '$NETWORK' are reachable by service name once started."
