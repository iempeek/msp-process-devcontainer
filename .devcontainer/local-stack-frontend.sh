#!/usr/bin/env bash
# .devcontainer/local-stack-frontend.sh
#
# Frontend helpers for the local stack: installing a sub-app's dependencies and
# starting its Vite dev server NATIVELY in the devcontainer. SOURCED by
# local-stack.sh (--build / --run); requires WS_ROOT, SCRIPT_DIR and
# local-stack-components.sh.
#
# This replaces the old `frontend` compose sidecar (a 3.5GB Playwright image
# that idled while the stack was up). The apps now run as ordinary background
# processes here, built and started on demand, and an agent looks at them with
# the `playwright` MCP server (.mcp.json) whose browser is preinstalled by
# post-create.sh. Consequences worth knowing:
#   * the apps reach the backend over plain localhost - no relay containerward
#     (infra-up.sh keeps one small relay for soketi at localhost:6001)
#   * the mspprocess-ui checkout must be visible: it sits next to the backend
#     inside the workspace this devcontainer opens (see FE_ROOT below)
#   * dependencies install straight into each app's own node_modules, the way a
#     human dev would. The old per-app .adlc-artifacts/frontend/nm_<slug> bind
#     stores only existed to keep installs out of a container's mount; they are
#     now dead weight and can be deleted. The shared pnpm/yarn caches under
#     .adlc-artifacts/frontend/cache/ ARE still used.
set -uo pipefail

# Where the frontend checkout is: a sibling of the backend INSIDE the shared
# workspace this devcontainer opens. It used to be bind-mounted at /frontend,
# from a devcontainer that opened the backend repo alone; now that the workspace
# root holds both checkouts, no mount is involved. FRONTEND_ROOT still wins if
# set, so an unusual layout can point straight at it.
FE_ROOT="${FRONTEND_ROOT:-$WS_ROOT/${FRONTEND_DIR_NAME:-mspprocess-ui}}"

# Same cache dirs the frontend container used (it saw them as /frontend-cache),
# so the already-populated pnpm store and yarn cache are reused as-is.
FE_CACHE="$WS_ROOT/.adlc-artifacts/frontend/cache"
FE_BIN_DIR="$FE_CACHE/bin"
FE_ENV_DIR="$SCRIPT_DIR/local/frontend-settings"

# id -> slug. The registry ids are "fe-<slug>" on purpose, so the env file
# (env.<slug>) needs no extra field in the registry.
fe_slug() { echo "${1#fe-}"; }

fe_available() { [ -d "$FE_ROOT" ]; }

# Package managers come from corepack, shimmed into a repo-local bin dir so no
# global install (and no root) is needed. Caches are shared across apps and
# reused from the previous compose-based setup.
fe_prepare_env() {
  mkdir -p "$FE_BIN_DIR" "$FE_CACHE/corepack" "$FE_CACHE/pnpm-store" "$FE_CACHE/yarn"
  export COREPACK_HOME="$FE_CACHE/corepack"
  export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
  export npm_config_store_dir="$FE_CACHE/pnpm-store"
  export YARN_CACHE_FOLDER="$FE_CACHE/yarn"
  # Some sub-apps hardcode Vite's `open: true`; there is no browser to open
  # here (the agent's browser is the MCP one), and BROWSER=none is the standard
  # escape hatch honoured by the `open` package.
  export BROWSER=none
  # Lets newer Vite accept requests carrying a non-localhost Host header.
  export __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=frontend

  if ! command -v corepack >/dev/null 2>&1; then
    echo "[WARNING] corepack not found - cannot provide pnpm/yarn." >&2
    return 1
  fi
  corepack enable --install-directory "$FE_BIN_DIR" >/dev/null 2>&1 || true
  export PATH="$FE_BIN_DIR:$PATH"
}

# Install one app's dependencies, skipping when the lockfile hash matches the
# stamp from last time. This is the "build" half of build-on-demand.
fe_install() {
  local id="$1" dir="${LS_TARGET[$1]}" pm="${LS_PM[$1]}"
  local app_dir="$FE_ROOT/$dir" lockfile stamp hash

  if [ ! -d "$app_dir" ]; then
    echo "[WARNING] [$id] $app_dir not found - is the mspprocess-ui checkout at $FE_ROOT?" >&2
    return 1
  fi

  # The retired frontend container bind-mounted .adlc-artifacts/frontend/nm_<slug>
  # onto each app's node_modules, and the docker daemon created the missing
  # mount points in the checkout as EMPTY root-owned dirs. They survive the
  # container's removal and are unwritable, so an install would die with
  # EACCES. Removing an empty dir only needs write access on its parent, which
  # we have. A non-empty node_modules is a real install and is left alone.
  if [ -d "$app_dir/node_modules" ] && [ -z "$(ls -A "$app_dir/node_modules" 2>/dev/null)" ]; then
    rmdir "$app_dir/node_modules" 2>/dev/null \
      || { echo "[WARNING] [$id] cannot remove the empty node_modules placeholder at $app_dir/node_modules." >&2; return 1; }
  fi

  if [ "$pm" = "pnpm" ]; then lockfile="$app_dir/pnpm-lock.yaml"; else lockfile="$app_dir/yarn.lock"; fi
  stamp="$app_dir/node_modules/.install-stamp"

  if [ ! -f "$lockfile" ]; then
    echo "[WARNING] [$id] no lockfile at $lockfile - skipping install/start." >&2
    return 1
  fi

  hash="$(sha256sum "$lockfile" | awk '{print $1}')"
  if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$hash" ]; then
    echo "[INFO] [$id] dependencies up to date, skipping install."
    return 0
  fi

  echo "[INFO] [$id] installing dependencies ($pm)..."
  if [ "$pm" = "pnpm" ]; then
    (cd "$app_dir" && pnpm install --frozen-lockfile) || return 1
  else
    # yarn 1 hard-fails on an engines.node mismatch against the devcontainer's
    # node version - --ignore-engines is required, not optional, here.
    (cd "$app_dir" && yarn install --frozen-lockfile --ignore-engines) || return 1
  fi
  echo "$hash" > "$stamp"
}

# Start one app's dev server in the background. Echoes "<pid>" on success; the
# caller records it in the pid file exactly like a dotnet host.
fe_start() {
  local id="$1" dir="${LS_TARGET[$1]}" port="${LS_PORT[$1]}" log_dir="$2"
  local app_dir="$FE_ROOT/$dir" env_file
  env_file="$FE_ENV_DIR/env.$(fe_slug "$id")"

  if [ ! -x "$app_dir/node_modules/.bin/vite" ]; then
    echo "[WARNING] [$id] no vite binary - dependencies did not install." >&2
    return 1
  fi

  # --host 0.0.0.0 so the port published by devcontainer.json's appPort reaches
  # it from a host browser too, not just localhost inside the container.
  # `exec` for the same reason as the dotnet hosts (see local-stack.sh):
  # $! must be the real vite pid, with no orphaned wrapper holding the pipe.
  (
    cd "$app_dir" || exit 1
    if [ -f "$env_file" ]; then
      set -a
      # shellcheck disable=SC1090
      . "$env_file"
      set +a
    fi
    exec nohup ./node_modules/.bin/vite --host 0.0.0.0 --port "$port" --strictPort \
      > "$log_dir/${id}.log" 2>&1 < /dev/null
  ) &
  echo $!
}
