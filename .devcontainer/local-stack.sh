#!/usr/bin/env bash
# .devcontainer/local-stack.sh
#
# ONE entry point for the local dev stack lifecycle. The mode is the first
# argument:
#
#   local-stack.sh --run     [options]   build + start a selected subset
#   local-stack.sh --build   [options]   build only (dotnet + frontend installs)
#   local-stack.sh --status              read-only UP/DOWN table (no changes)
#   local-stack.sh --stop    [options]   stop what --run started
#   local-stack.sh --list                print every component id and preset
#   local-stack.sh --help                this text
#
# The bare words (`run`, `build`, `status`, `stop`, `list`, `help`) work too.
#
# The stack is too heavy to run whole on a modest machine, so every component
# is individually selectable. What exists is defined ONCE in
# local-stack-components.sh (sourced registry, plus local-stack-frontend.sh for
# the Vite helpers) - see the header there to add or remove one; every mode
# below picks it up automatically.
#
# ---------------------------------------------------------------------------
# --run [selection] [--detach|-d]
#
#   Builds (via the same code path as --build) and starts the selection: the
#   docker sidecars (.devcontainer/compose.yaml), the dotnet hosts, the
#   core-flow Azure Functions and the frontend sub-apps.
#
#   Selection (pick at most one form):
#     (nothing)                interactive checkbox menu on a terminal, seeded
#                              with your last choice; the remembered choice
#                              without a menu when not on a terminal
#     --menu                   always show the menu, even when passed a spec
#     --no-menu                never show the menu; use the remembered choice
#     -c, --components SPEC    non-interactive: comma-separated ids and/or
#                              presets, e.g. "api,fe-web" or "backend,mssql"
#     --all                    everything (same as --components all)
#     --only-backend           back-compat alias for --components backend
#     --only-frontend          back-compat alias for --components frontend
#
#   Other flags:
#     --detach, -d             start everything and exit instead of streaming
#     --no-save                start this selection WITHOUT remembering it, so
#                              the next bare --run still uses your own choice.
#                              For tool callers that pick a selection per task
#                              (the ADLC harness's "run" command passes it).
#
#   The selection is remembered in .adlc-artifacts/local-stack/selection
#   (gitignored), so the next run without flags starts the same subset -
#   unless --no-save says otherwise.
#   UNCHECKED COMPONENTS ARE SIMPLY NOT STARTED - nothing already running is
#   stopped for you except the selected hosts themselves (restarted, so
#   re-running is idempotent). Stop things with --stop.
#
#   By default the script stays in the foreground after the health checks and
#   streams the combined logs of everything it started. Ctrl-C DETACHES - it
#   stops the tailing, not the stack. Use --detach for non-interactive callers
#   (the ADLC harness's "run" command passes it).
#
# ---------------------------------------------------------------------------
# --build [selection]
#
#   Scoped build - only the components you actually run locally, not the full
#   106-project solution. Run `commands.build` (dotnet build AlertManager.sln)
#   separately as the full CI-parity gate; this mode is for the fast local
#   iterate loop.
#
#     (nothing)                build the remembered selection (all, if none)
#     -c, --components SPEC    comma-separated component ids and/or presets
#     --all / --only-backend / --only-frontend   as above
#
#   --build never opens the interactive menu and never rewrites the remembered
#   selection; --run owns that and passes the resolved selection down.
#
# ---------------------------------------------------------------------------
# --status
#
#   Which components are currently running and on which URLs, and which ones
#   your remembered selection asks for (the SEL column - "sel" means --run
#   would start it, "-" means it is deliberately not part of your subset).
#   Changes nothing.
#
#   Backend detection is port-truth first: a host counts as UP if its
#   well-known port answers, regardless of what the pid file says (the pid file
#   only adds the pid/log columns when it agrees). This keeps the output honest
#   when the pid file is stale or hosts were started by hand.
#
# ---------------------------------------------------------------------------
# --stop [selection] [--quiet]
#
#   Stops what --run started: the processes it owns (the dotnet and Functions
#   hosts and the Vite dev servers, from .adlc-artifacts/local-stack/pids) and
#   - only when you ask for them by id - the infra sidecars. Safe to run when
#   nothing is running, or when the pid file is stale or missing.
#
#     (nothing)                stop every backend host and frontend app
#                              (the historical default; sidecars are left up)
#     -c, --components SPEC    stop only these ids/presets - sidecars included
#                              if you name them (e.g. "api,fe-web" or "all")
#     --last                   stop exactly what the remembered selection lists
#     --only-backend/--only-frontend  back-compat aliases
#     --quiet, -q              suppress the per-component INFO lines
#
#   Sidecars are excluded from the default because they're cheap to leave
#   running and are shared with other tooling; `docker compose -p
#   mspprocess-infra -f .devcontainer/compose.yaml down` still removes
#   everything at once. Frontend apps ARE stopped by default: they are plain
#   local processes owned by this script's start/stop lifecycle exactly like
#   the dotnet hosts, and each one can be stopped individually.
#
# ---------------------------------------------------------------------------
# Requires: docker (sidecars), dotnet (backend hosts), node (frontend apps -
# they run natively here, see local-stack-frontend.sh; the sibling
# mspprocess-ui checkout must sit next to the backend in the workspace). The
# Functions hosts
# additionally require the `func` CLI (Azure Functions Core Tools) - if
# missing, --run tries `npm install -g azure-functions-core-tools@4` once; if
# that also fails, it skips the Functions hosts and still succeeds for the rest
# of the selection.
#
# errexit is switched on per mode (--run/--build want it, --stop/--status
# deliberately keep going through missing pids and dead containers).
set -uo pipefail

# This devcontainer is SHARED by the backend and frontend checkouts, which sit
# side by side INSIDE the workspace it opens:
#
#   <workspace>/            <- WS_ROOT: .devcontainer, .env, .adlc-artifacts
#     .devcontainer/        <- this script (its own git repo)
#     MSPProcess/           <- BACKEND_ROOT  (override: BACKEND_DIR_NAME)
#     mspprocess-ui/        <- FE_ROOT       (override: FRONTEND_DIR_NAME)
#
# So there are two roots, and mixing them up is the one way to break this
# script: WS_ROOT owns everything the devcontainer itself provides (compose
# file, sidecar data, local-stack state, .env), while BACKEND_ROOT is what the
# dotnet/func component targets in local-stack-components.sh are relative to.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_ROOT="$WS_ROOT/${BACKEND_DIR_NAME:-MSPProcess}"
cd "$WS_ROOT"

# shellcheck source=local-stack-components.sh
source "$SCRIPT_DIR/local-stack-components.sh"
# shellcheck source=local-stack-frontend.sh
source "$SCRIPT_DIR/local-stack-frontend.sh"

STATE_DIR="$LS_STATE_DIR"
LOG_DIR="$STATE_DIR/logs"
PID_FILE="$STATE_DIR/pids"
RELAY_PID_FILE="$STATE_DIR/devcontainer-relay.pid"

COMPOSE_FILE="$SCRIPT_DIR/compose.yaml"
COMPOSE_PROJECT="mspprocess-infra"

# SELF is for messages; SELF_PATH is how --run re-invokes this script for its
# --stop and --build steps (see the comment there).
SELF=".devcontainer/local-stack.sh"
SELF_PATH="$SCRIPT_DIR/local-stack.sh"

usage() {
  # The block comment above is the documentation; print it rather than keeping
  # a second copy that can drift. Everything from line 3 up to the first
  # non-comment line, with the leading "# " stripped.
  awk 'NR<3 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
}

# ===========================================================================
# --build
# ===========================================================================
mode_build() {
  set -e

  local spec=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -c|--components)
        [ "$#" -ge 2 ] || { echo "[ERROR] $1 needs a value." >&2; exit 1; }
        spec="$2"; shift 2 ;;
      --components=*)  spec="${1#*=}";  shift ;;
      --all)           spec="all";      shift ;;
      --only-backend)  spec="backend";  shift ;;
      --only-frontend) spec="frontend"; shift ;;
      *)
        echo "[ERROR] $SELF --build: unknown argument: $1" >&2
        echo "Usage: $SELF --build [-c|--components SPEC] [--all] [--only-backend|--only-frontend]" >&2
        exit 1 ;;
    esac
  done

  # The build must not rewrite the remembered selection, so it resolves the
  # spec directly instead of going through ls_choose_selection.
  if [ -n "$spec" ]; then
    ls_resolve_spec "$spec"
  elif ! ls_load_selection; then
    ls_resolve_spec all
  fi

  # -------------------------------------------------------------------------
  # Backend: scoped dotnet builds. A Functions component's target is its
  # project directory (that's what `func start` needs); the csproj inside
  # follows the repo-wide <DirName>/<DirName>.csproj convention.
  # -------------------------------------------------------------------------
  local id dir project
  local projects=()
  while read -r id; do
    [ -n "$id" ] && projects+=("${LS_TARGET[$id]}")
  done < <(ls_selected_ids_of_kind dotnet)
  while read -r id; do
    [ -n "$id" ] || continue
    dir="${LS_TARGET[$id]}"
    projects+=("$dir/$(basename "$dir").csproj")
  done < <(ls_selected_ids_of_kind func)

  if [ "${#projects[@]}" -gt 0 ]; then
    echo "[INFO] === Backend ==="
    for project in "${projects[@]}"; do
      echo "[INFO] Building $project"
      # Targets are BACKEND_ROOT-relative (see the registry), and cwd is WS_ROOT.
      dotnet build "$BACKEND_ROOT/$project" --nologo --verbosity quiet
    done
    echo "[INFO] local-stack --build: selected backend projects built successfully."
  fi

  # -------------------------------------------------------------------------
  # Frontend: install the selected sub-apps' dependencies (no dev server yet).
  # This runs natively - there is no frontend container any more - and is a
  # no-op when the lockfile hash still matches the last install.
  # -------------------------------------------------------------------------
  local fe_ids=()
  while read -r id; do
    [ -n "$id" ] && fe_ids+=("$id")
  done < <(ls_selected_ids_of_kind feapp)

  local fe_failed=false
  if [ "${#fe_ids[@]}" -gt 0 ]; then
    echo "[INFO] === Frontend dependencies (${fe_ids[*]}) ==="
    if ! fe_available; then
      echo "[ERROR] local-stack --build: no frontend checkout at $FE_ROOT." >&2
      echo "[ERROR] Clone mspprocess-ui next to the backend inside the workspace" >&2
      echo "[ERROR] ($WS_ROOT), or set FRONTEND_DIR_NAME if it is named differently." >&2
      exit 1
    fi
    fe_prepare_env || exit 1
    for id in "${fe_ids[@]}"; do
      fe_install "$id" || fe_failed=true
    done
    if [ "$fe_failed" = true ]; then
      echo "[ERROR] local-stack --build: one or more frontend apps failed to install." >&2
      exit 1
    fi
    echo "[INFO] local-stack --build: frontend dependencies ready."
  fi

  if [ "${#projects[@]}" -eq 0 ] && [ "${#fe_ids[@]}" -eq 0 ]; then
    echo "[INFO] local-stack --build: selection contains nothing buildable (sidecars only)."
  fi
}

# ===========================================================================
# --stop
# ===========================================================================
mode_stop() {
  local spec="" quiet=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -c|--components)
        [ "$#" -ge 2 ] || { echo "[ERROR] $1 needs a value." >&2; exit 1; }
        spec="$2"; shift 2 ;;
      --components=*)  spec="${1#*=}";  shift ;;
      --only-backend)  spec="backend";  shift ;;
      --only-frontend) spec="frontend"; shift ;;
      --last)          spec="__last__"; shift ;;
      --quiet|-q)      quiet=true;      shift ;;
      *)
        echo "[ERROR] $SELF --stop: unknown argument: $1" >&2
        echo "Usage: $SELF --stop [-c|--components SPEC] [--last] [--only-backend|--only-frontend] [--quiet]" >&2
        exit 1 ;;
    esac
  done

  case "$spec" in
    "")        ls_resolve_spec "backend,frontend" ;;   # historical default
    __last__)  ls_load_selection || ls_resolve_spec "backend,frontend" ;;
    *)         ls_resolve_spec "$spec" || exit 1 ;;
  esac

  say() { [ "$quiet" = true ] || echo "$@"; }

  # -------------------------------------------------------------------------
  # Backend hosts: SIGTERM by recorded pid, then a pattern sweep for stale pids
  # and children that outlived their parent. The pid file is rewritten with
  # only the entries we did NOT stop, so hosts outside this selection keep
  # their bookkeeping.
  # -------------------------------------------------------------------------
  local id name pid url kept
  local stop_ids=()
  while read -r id; do
    [ -n "$id" ] || continue
    case "${LS_KIND[$id]}" in dotnet|func|feapp) stop_ids+=("$id") ;; esac
  done < <(ls_selected_ids)

  if [ "${#stop_ids[@]}" -gt 0 ]; then
    if [ -f "$PID_FILE" ]; then
      kept="$(mktemp)"
      while IFS='|' read -r name pid url; do
        [ -z "$name" ] && continue
        if printf '%s\n' "${stop_ids[@]}" | grep -qx "$name"; then
          if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            say "[INFO] Stopping $name (pid $pid)"
            # Kill any children first (dotnet run / func start both spawn a
            # child process for the actual host), then the recorded pid itself.
            pkill -TERM -P "$pid" 2>/dev/null || true
            kill -TERM "$pid" 2>/dev/null || true
          fi
        else
          echo "${name}|${pid}|${url}" >> "$kept"
        fi
      done < "$PID_FILE"
      sleep 3
      cat "$kept" > "$PID_FILE" 2>/dev/null || : > "$PID_FILE"
      rm -f "$kept"
    fi

    # `func` (node) does not always exit promptly on SIGTERM, so this fallback
    # escalates to SIGKILL rather than repeating SIGTERM. Patterns come
    # straight from the registry, so a newly added host is covered without
    # editing this.
    for id in "${stop_ids[@]}"; do
      case "${LS_KIND[$id]}" in
        dotnet) pkill -9 -f "dotnet run --project ${LS_TARGET[$id]}" 2>/dev/null || true ;;
        func)   pkill -9 -f "func start --port ${LS_PORT[$id]}" 2>/dev/null || true ;;
        feapp)  pkill -9 -f "vite --host 0.0.0.0 --port ${LS_PORT[$id]}" 2>/dev/null || true ;;
      esac
    done
    say "[INFO] local-stack --stop: stopped ${stop_ids[*]}."
  fi

  # -------------------------------------------------------------------------
  # Sidecars: only ever the ones named explicitly in the selection.
  # -------------------------------------------------------------------------
  local sidecars=()
  while read -r id; do
    [ -n "$id" ] && sidecars+=("${LS_TARGET[$id]}")
  done < <(ls_selected_ids_of_kind sidecar)

  if [ "${#sidecars[@]}" -gt 0 ]; then
    if command -v docker >/dev/null 2>&1 && [ -f "$COMPOSE_FILE" ]; then
      docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" stop "${sidecars[@]}" 2>/dev/null || true
    fi
    say "[INFO] local-stack --stop: sidecars stopped (${sidecars[*]})."
  fi

  say "[INFO] local-stack --stop: done."
}

# ===========================================================================
# --status
# ===========================================================================
mode_status() {
  [ "$#" -eq 0 ] || {
    echo "[ERROR] $SELF --status takes no arguments (got: $*)" >&2
    exit 1
  }

  ls_load_selection >/dev/null 2>&1 || LS_SELECTED=()

  sel_mark() { if ls_selected "$1"; then echo "sel"; else echo "-"; fi; }

  pid_for() {
    # A host's recorded pid; empty when the pid file is missing, the entry is
    # absent, or the recorded process is no longer alive.
    local wanted="$1" name pid url
    [ -f "$PID_FILE" ] || return 0
    while IFS='|' read -r name pid url; do
      if [ "$name" = "$wanted" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "$pid"
        return 0
      fi
    done < "$PID_FILE"
  }

  port_answers() { curl -s -o /dev/null --max-time 2 "http://localhost:$1"; }

  container_state() {
    command -v docker >/dev/null 2>&1 || { echo "docker missing"; return; }
    # `docker inspect` on a missing container still prints an empty line before
    # failing, so normalise rather than relying on its exit code alone.
    local out
    out="$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null | tr -d '\n')"
    echo "${out:-not found}"
  }

  local up_count=0 down_count=0
  tally() { if [ "$1" = UP ]; then up_count=$((up_count + 1)); else down_count=$((down_count + 1)); fi; }

  row() { printf '%-6s %-4s %-20s %-24s %s\n' "$1" "$2" "$3" "$4" "$5"; }

  local id port pid state relay_pid

  echo "=== Local processes (backend hosts + frontend dev servers) ==="
  row STATE SEL COMPONENT URL DETAILS
  for id in $(ls_all_ids); do
    case "${LS_KIND[$id]}" in dotnet|func|feapp) ;; *) continue ;; esac
    port="${LS_PORT[$id]}"
    if port_answers "$port"; then
      pid="$(pid_for "$id")"
      row UP "$(sel_mark "$id")" "$id" "http://localhost:$port" "${pid:+pid $pid, }log: $LOG_DIR/$id.log"
      tally UP
    else
      row DOWN "$(sel_mark "$id")" "$id" "http://localhost:$port" "${LS_LABEL[$id]}"
      tally DOWN
    fi
  done

  echo ""
  echo "=== Sidecars ==="
  row STATE SEL COMPONENT URL DETAILS
  for id in $(ls_all_ids); do
    [ "${LS_KIND[$id]}" = sidecar ] || continue
    state="$(container_state "${COMPOSE_PROJECT}-${LS_TARGET[$id]}-1")"
    port="$(ls_port "$id")"
    if [ "$state" = "running" ]; then
      row UP "$(sel_mark "$id")" "$id" "${port:+localhost:$port}" "${LS_LABEL[$id]}"
      tally UP
    else
      row DOWN "$(sel_mark "$id")" "$id" "${port:+localhost:$port}" "$state"
      tally DOWN
    fi
  done

  echo ""
  echo "=== Relays ==="
  relay_pid=""
  [ -f "$RELAY_PID_FILE" ] && relay_pid="$(cat "$RELAY_PID_FILE" 2>/dev/null || true)"
  if [ -n "$relay_pid" ] && kill -0 "$relay_pid" 2>/dev/null; then
    echo "soketi relay: UP (pid $relay_pid) - localhost:6001 here reaches the soketi sidecar"
  else
    echo "soketi relay: DOWN - restart with: bash .devcontainer/infra-up.sh"
  fi
  echo "(the frontend apps run natively here now, so they reach the backend over"
  echo " plain localhost - only soketi still needs the relay above)"

  echo ""
  if [ -f "$LS_SELECTION_FILE" ]; then
    echo "selection: ${LS_SELECTION_FILE#"$WS_ROOT"/} ($(ls_selected_ids | paste -sd, -))"
  else
    echo "selection: none remembered yet - run '$SELF --run' to pick one"
  fi
  echo "$up_count up, $down_count down."
}

# ===========================================================================
# --run
# ===========================================================================

# PID_FILE lines are "id|pid|url" - '|' never appears in a component id, pid
# or http://host:port URL, so it's unambiguous to split on (unlike ':', which
# also appears inside the URL). PID_FILE tracks every process --run owns: the
# dotnet hosts, the Functions hosts and the Vite dev servers. Sidecars are the
# only compose services left, and they have their own lifecycle.
record_started() { # <id> <pid> <url>
  echo "${1}|${2}|${3}" >> "$PID_FILE"
  STARTED_IDS+=("$1")
}

# The workspace .env holds the dev secrets the backend hosts need as ENV VARS
# (MSPPROCESS_AZURE_*_KV_CLIENTSECRET, seeded by link-local-settings.sh; SONAR_*
# appended by sonarqube-bootstrap.sh). It used to be injected by docker at
# container-creation time (devcontainer.json runArgs --env-file), which forced
# the file to exist on the HOST before anything ran - a write that Windows hosts
# refuse. It is now loaded here instead, per host process, exactly like the Vite
# dev servers load their env.<slug> (see local-stack-frontend.sh). Missing file
# is fine: the hosts start without the secrets, same as an unfilled .env did.
load_workspace_env() {
  [ -f "$WS_ROOT/.env" ] || return 0
  set -a
  # shellcheck disable=SC1091
  . "$WS_ROOT/.env"
  set +a
}

start_dotnet_host() {
  local id="$1" project="${LS_TARGET[$1]}" port="${LS_PORT[$1]}"
  # Bind 0.0.0.0 (not localhost) so anything reaching this host over the docker
  # network via the "devcontainer" alias (see infra-up.sh) can connect;
  # "http://localhost:$port" (used for health checks, the summary, and
  # PID_FILE) still works from this same container.
  local url="http://localhost:$port"
  echo "[INFO] Starting $id (${LS_LABEL[$id]}) on $url"
  # `exec` inside the subshell replaces the subshell's own process image with
  # `nohup dotnet run ...` instead of forking a separate background job that
  # the subshell then waits on - the latter leaves an orphaned wrapper
  # process alive indefinitely, holding this script's stdout/stderr pipe
  # open (so callers piping this script's output, e.g. `| tail`, never see
  # EOF even though every real host is up and healthy). `$!` after `&` is
  # then the true, only PID for this host.
  (cd "$BACKEND_ROOT" && load_workspace_env && exec nohup dotnet run --project "$project" --no-launch-profile --urls "http://0.0.0.0:$port" \
    > "$LOG_DIR/${id}.log" 2>&1 < /dev/null) &
  local pid=$!
  sleep 2
  record_started "$id" "$pid" "$url"
}

start_func_host() {
  local id="$1" project_dir="${LS_TARGET[$1]}" port="${LS_PORT[$1]}"
  echo "[INFO] Starting $id (${LS_LABEL[$id]}) on http://localhost:$port"
  # See the comment in start_dotnet_host for why `exec` (not a plain
  # backgrounded job) is required here.
  (cd "$BACKEND_ROOT/$project_dir" && load_workspace_env && exec nohup func start --port "$port" \
    > "$LOG_DIR/${id}.log" 2>&1 < /dev/null) &
  local pid=$!
  sleep 2
  record_started "$id" "$pid" "http://localhost:${port}"
}

mode_run() {
  set -e

  local SPEC="" WANT_MENU=auto DETACH=false SAVE=true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -c|--components)
        [ "$#" -ge 2 ] || { echo "[ERROR] $1 needs a value." >&2; exit 1; }
        SPEC="$2"; WANT_MENU=false; shift 2 ;;
      --components=*) SPEC="${1#*=}"; WANT_MENU=false; shift ;;
      --all)          SPEC="all";      WANT_MENU=false; shift ;;
      --only-backend) SPEC="backend";  WANT_MENU=false; shift ;;
      --only-frontend) SPEC="frontend"; WANT_MENU=false; shift ;;
      --menu)    WANT_MENU=true;  shift ;;
      --no-menu) WANT_MENU=false; shift ;;
      --detach|-d) DETACH=true; shift ;;
      --no-save)   SAVE=false; shift ;;
      *)
        echo "[ERROR] $SELF --run: unknown argument: $1" >&2
        usage >&2
        exit 1 ;;
    esac
  done

  # --detach implies non-interactive: a detached caller has nobody to answer
  # the menu, so fall back to the remembered selection.
  [ "$DETACH" = true ] && [ "$WANT_MENU" = auto ] && WANT_MENU=false

  ls_choose_selection "$SPEC" "$WANT_MENU" "$SELF --run" "$SAVE" || exit 1

  if [ -z "$(ls_selected_ids)" ]; then
    echo "[INFO] Nothing selected - nothing to do."
    exit 0
  fi

  mkdir -p "$LOG_DIR"
  touch "$PID_FILE"

  local id port up status log_file p
  local SELECTED_SIDECARS=()
  while read -r id; do
    [ -n "$id" ] && SELECTED_SIDECARS+=("${LS_TARGET[$id]}")
  done < <(ls_selected_ids_of_kind sidecar)

  local SELECTED_FE_IDS=()
  while read -r id; do
    [ -n "$id" ] && SELECTED_FE_IDS+=("$id")
  done < <(ls_selected_ids_of_kind feapp)

  local RUN_FRONTEND=false RUN_BACKEND=false
  [ "${#SELECTED_FE_IDS[@]}" -gt 0 ] && RUN_FRONTEND=true
  { ls_any_of_kind dotnet || ls_any_of_kind func; } && RUN_BACKEND=true

  local SELECTION_CSV OWNED_CSV
  SELECTION_CSV="$(ls_selected_ids | paste -sd, -)"

  # -------------------------------------------------------------------------
  # 0. Stop whatever a previous run started for the SELECTED components, so
  #    re-running the same selection is idempotent. Components outside the
  #    selection are left alone (that's the whole point of selecting).
  #
  #    --stop and --build below are invoked as a fresh PROCESS, not as a local
  #    function call or a subshell. Two reasons: each resolves its own
  #    selection into the shared LS_SELECTED, which this run still needs; and
  #    bash suppresses errexit inside any compound command on the left of
  #    `||` - an explicit `set -e` in there does NOT restore it - so an
  #    in-process `( mode_build ... ) || ...` would sail straight past a failing
  #    `dotnet build` and report success.
  # -------------------------------------------------------------------------
  # Every process --run owns (dotnet, func and the Vite servers) is restarted;
  # the sidecars are compose services whose `up -d` is already idempotent, so
  # stopping them here would just add a restart nobody asked for.
  OWNED_CSV="$( { ls_selected_ids_of_kind dotnet; ls_selected_ids_of_kind func; ls_selected_ids_of_kind feapp; } | paste -sd, - )"
  if [ -n "$OWNED_CSV" ]; then
    "$SELF_PATH" --stop --components "$OWNED_CSV" --quiet || true
  fi

  # -------------------------------------------------------------------------
  # 1. Build only the selected projects (and warm only the selected frontend
  #    apps' dependency installs). Separate process, same reasons as above.
  # -------------------------------------------------------------------------
  echo "[INFO] === Build ==="
  "$SELF_PATH" --build --components "$SELECTION_CSV" || {
    echo "[ERROR] local-stack --run: build failed - not starting anything." >&2
    exit 1
  }

  # -------------------------------------------------------------------------
  # 2. Sidecars: bring up the selected ones, then wait for mssql to report
  #    healthy (only meaningful when a backend host is about to start).
  # -------------------------------------------------------------------------
  if [ "${#SELECTED_SIDECARS[@]}" -gt 0 ]; then
    echo "[INFO] === Sidecars (${SELECTED_SIDECARS[*]}) ==="
    # The container start hook only PREPARES the infra (network, data dirs,
    # soketi relay) - it no longer starts any sidecar, so this is the first
    # `up` in the session. Re-run the prepare step here so a stack started by
    # hand (or after `docker network rm` / a wiped .adlc-artifacts) still finds
    # the external network and its bind-mount targets in place; it's idempotent.
    bash "$SCRIPT_DIR/infra-up.sh" >/dev/null || true
    # Sidecars with bind-mounted data run as this (host-mapped) uid/gid so the
    # dirs under .adlc-artifacts/ stay user-owned - same export infra-up.sh
    # does, repeated because env from that child process doesn't come back here.
    export SIDECAR_UID="${SIDECAR_UID:-$(id -u)}" SIDECAR_GID="${SIDECAR_GID:-$(id -g)}"
    docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" up -d "${SELECTED_SIDECARS[@]}"
  fi

  if [ "$RUN_BACKEND" = true ] && ls_selected mssql; then
    echo "[INFO] Waiting for mssql to become healthy..."
    status="unknown"
    for _ in $(seq 1 30); do
      status="$(docker inspect -f '{{.State.Health.Status}}' "${COMPOSE_PROJECT}-mssql-1" 2>/dev/null || echo unknown)"
      if [ "$status" = "healthy" ]; then
        break
      fi
      sleep 2
    done
    if [ "$status" != "healthy" ]; then
      echo "[WARNING] mssql did not report healthy in time (status: $status) - continuing anyway." >&2
    fi
  fi

  # -------------------------------------------------------------------------
  # 3. Sanity-check the local settings overlay is in place (backend only).
  # -------------------------------------------------------------------------
  if [ "$RUN_BACKEND" = true ]; then
    local OVERLAY="$BACKEND_ROOT/Core/AlertManager.Settings/settings.Local.json"
    local OVERLAY_SRC="$SCRIPT_DIR/local/backend-settings/Core/AlertManager.Settings/settings.Local.json"
    if [ ! -e "$OVERLAY" ]; then
      echo "[WARNING] $OVERLAY does not exist - run link-local-settings.sh, or nothing" >&2
      echo "[WARNING] below will have a working DB/auth/local-emulator config." >&2
    elif ! grep -q 'ConnectionString' "$OVERLAY" 2>/dev/null; then
      # The classic form of this: a stub {} sitting at the target path. Because
      # it is a REAL file, link-local-settings.sh refuses to replace it with the
      # symlink, so the overlay silently contributes nothing and every host dies
      # on the first EF Migrate() with "Format of the initialization string does
      # not conform to specification starting at index 0".
      echo "[WARNING] settings.Local.json has no ConnectionString - hosts will fail at startup." >&2
      if [ ! -L "$OVERLAY" ] && [ -f "$OVERLAY_SRC" ]; then
        echo "[WARNING] It is a real file shadowing the symlink to backend-settings/. Fix with:" >&2
        echo "[WARNING]   rm \"$OVERLAY\" && bash .devcontainer/link-local-settings.sh" >&2
      else
        echo "[WARNING] Run link-local-settings.sh, or fill the overlay in by hand." >&2
      fi
    elif grep -q '\[REQUIRED\]' "$OVERLAY" 2>/dev/null; then
      echo "[WARNING] settings.Local.json still has [REQUIRED] placeholders - some features may fail." >&2
    fi
  fi

  # -------------------------------------------------------------------------
  # 4. Backend hosts. STARTED_IDS drives the health checks and log streaming,
  #    so only what this run actually launched is reported on.
  # -------------------------------------------------------------------------
  all_ok=true
  STARTED_IDS=()

  if ls_any_of_kind dotnet; then
    echo "[INFO] === App hosts ==="
    for id in $(ls_selected_ids_of_kind dotnet); do
      start_dotnet_host "$id"
    done
  fi

  # -------------------------------------------------------------------------
  # 5. Functions hosts - need the `func` CLI. Best-effort: install if missing,
  #    skip with a clear warning if that's not possible.
  # -------------------------------------------------------------------------
  if ls_any_of_kind func; then
    echo "[INFO] === Functions (best-effort) ==="
    if ! command -v func >/dev/null 2>&1; then
      if command -v npm >/dev/null 2>&1; then
        echo "[INFO] 'func' (Azure Functions Core Tools) not found - attempting install via npm..."
        npm install -g azure-functions-core-tools@4 --unsafe-perm true \
          > "$LOG_DIR/func-install.log" 2>&1 \
          || echo "[WARNING] func install failed - see $LOG_DIR/func-install.log. Skipping Functions hosts." >&2
      else
        echo "[WARNING] 'func' not found and npm unavailable - skipping Functions hosts." >&2
      fi
    fi

    if command -v func >/dev/null 2>&1; then
      for id in $(ls_selected_ids_of_kind func); do
        start_func_host "$id"
      done
    else
      echo "[INFO] Functions hosts skipped (no 'func' CLI); the rest of the selection still started."
    fi
  fi

  # -------------------------------------------------------------------------
  # 6. Health-check every backend host started THIS run.
  # -------------------------------------------------------------------------
  if [ "${#STARTED_IDS[@]}" -gt 0 ]; then
    echo "[INFO] === Health checks (backend) ==="
    echo "[INFO] Waiting up to 60s per host for a TCP-level response..."
    for id in "${STARTED_IDS[@]}"; do
      port="${LS_PORT[$id]}"
      up=false
      for _ in $(seq 1 30); do
        if curl -s -o /dev/null --max-time 2 "http://localhost:$port"; then
          up=true
          break
        fi
        sleep 2
      done
      if [ "$up" = true ]; then
        echo "[INFO]  OK   $id - http://localhost:$port  (log: $LOG_DIR/$id.log)"
      else
        echo "[WARNING] DOWN $id - http://localhost:$port did not respond - check $LOG_DIR/$id.log" >&2
        all_ok=false
      fi
    done
  fi

  # -------------------------------------------------------------------------
  # 7. Frontend: install-if-needed already happened in the build step; here the
  #    selected Vite dev servers start as ordinary background processes,
  #    tracked in PID_FILE exactly like the dotnet hosts. No container, no
  #    compose - see local-stack-frontend.sh for why.
  # -------------------------------------------------------------------------
  if [ "$RUN_FRONTEND" = true ]; then
    echo "[INFO] === Frontend (${SELECTED_FE_IDS[*]}) ==="
    if ! fe_available; then
      echo "[WARNING] No frontend checkout at $FE_ROOT - skipping the frontend apps." >&2
      echo "[WARNING] Clone it next to the backend inside the workspace ($WS_ROOT)." >&2
      all_ok=false
    else
      fe_prepare_env || true
      local fe_pid fe_pending still_pending elapsed max_wait interval
      for id in "${SELECTED_FE_IDS[@]}"; do
        echo "[INFO] Starting $id (${LS_LABEL[$id]}) on http://localhost:${LS_PORT[$id]}"
        if fe_pid="$(fe_start "$id" "$LOG_DIR")"; then
          sleep 1
          record_started "$id" "$fe_pid" "http://localhost:${LS_PORT[$id]}"
        else
          all_ok=false
        fi
      done

      echo "[INFO] Waiting up to 120s for the selected dev servers..."
      fe_pending=("${SELECTED_FE_IDS[@]}")
      elapsed=0
      max_wait=120
      interval=3
      while [ "${#fe_pending[@]}" -gt 0 ] && [ "$elapsed" -lt "$max_wait" ]; do
        still_pending=()
        for id in "${fe_pending[@]}"; do
          if curl -s -o /dev/null --max-time 2 "http://localhost:${LS_PORT[$id]}"; then
            echo "[INFO]  OK   $id - http://localhost:${LS_PORT[$id]}  (log: $LOG_DIR/$id.log)"
          else
            still_pending+=("$id")
          fi
        done
        fe_pending=("${still_pending[@]}")
        if [ "${#fe_pending[@]}" -gt 0 ]; then
          sleep "$interval"
          elapsed=$((elapsed + interval))
        fi
      done
      for id in ${fe_pending[@]+"${fe_pending[@]}"}; do
        echo "[WARNING] DOWN $id - http://localhost:${LS_PORT[$id]} did not respond within ${max_wait}s - check $LOG_DIR/$id.log" >&2
        all_ok=false
      done
    fi
  fi

  # -------------------------------------------------------------------------
  # Summary
  # -------------------------------------------------------------------------
  echo ""
  if [ "$RUN_FRONTEND" = true ]; then
    echo "[INFO] Frontend (devcontainer, and the host via devcontainer.json appPort):"
    for id in $(ls_selected_ids_of_kind feapp); do
      printf '[INFO]   http://localhost:%-6s %s\n' "${LS_PORT[$id]}" "${LS_LABEL[$id]}"
    done
    echo "[INFO]   An agent can open these with the 'playwright' MCP server (.mcp.json)."
  fi
  if [ "${#SELECTED_SIDECARS[@]}" -gt 0 ]; then
    echo "[INFO] Sidecars started: ${SELECTED_SIDECARS[*]}"
  fi
  echo "[INFO] Re-pick components with: $SELF --run --menu"
  echo "[INFO] Stop what you started with: $SELF --stop"

  if [ "$all_ok" = true ]; then
    echo "[INFO] local-stack --run: all started components are responding."
    exit_code=0
  else
    echo "[WARNING] local-stack --run: one or more components did not respond - see warnings above." >&2
    exit_code=1
  fi

  if [ "$DETACH" = true ]; then
    exit "$exit_code"
  fi

  # -------------------------------------------------------------------------
  # 8. Stream everything this run started into one prefixed log until the user
  #    detaches: one `tail -F` per owned process log (backend hosts and Vite
  #    dev servers all write to files, not to a docker log), plus one
  #    `docker compose logs -f` scoped to the selected sidecars.
  #
  # `tail -F` (not -f) so a host restarted out-of-band, which replaces the
  # file, is picked up again instead of silently going quiet.
  # -------------------------------------------------------------------------
  STREAM_PIDS=()
  # EXIT too, so an unexpected failure in this block doesn't leave tails behind.
  trap run_detach INT TERM EXIT

  echo ""
  echo "[INFO] === Streaming logs (Ctrl-C detaches, does NOT stop the stack) ==="

  for id in ${STARTED_IDS[@]+"${STARTED_IDS[@]}"}; do
    log_file="$LOG_DIR/${id}.log"
    [ -f "$log_file" ] || continue
    # Process substitution, not `tail | sed`: after a pipeline `$!` is the LAST
    # element's pid (sed), so detach would kill sed and leave an orphaned tail
    # holding this script's stdout open. Here `$!` is tail itself, and the sed
    # child exits on its own once tail is gone and the pipe hits EOF.
    tail -n 20 -F "$log_file" 2>/dev/null > >(sed -u "s/^/[$id] /") &
    STREAM_PIDS+=($!)
  done

  local COMPOSE_LOG_SERVICES=(${SELECTED_SIDECARS[@]+"${SELECTED_SIDECARS[@]}"})
  if [ "${#COMPOSE_LOG_SERVICES[@]}" -gt 0 ]; then
    docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" logs -f --tail 20 "${COMPOSE_LOG_SERVICES[@]}" &
    STREAM_PIDS+=($!)
  fi

  wait
}

run_detach() {
  trap - INT TERM EXIT
  # Kill only the tails and the compose log follower. Every real service is
  # either a nohup'd process (backend hosts, Vite servers) or a docker
  # container, so none of them are children of this script and none are
  # affected.
  local p
  for p in ${STREAM_PIDS[@]+"${STREAM_PIDS[@]}"}; do
    kill "$p" 2>/dev/null || true
  done
  echo ""
  echo "[INFO] Detached - the stack is still running."
  echo "[INFO] Re-attach: tail -F $LOG_DIR/*.log   |   docker compose -p $COMPOSE_PROJECT -f $COMPOSE_FILE logs -f"
  echo "[INFO] Stop:      $SELF --stop"
  exit "${exit_code:-0}"
}

# ===========================================================================
# Dispatch
# ===========================================================================
MODE=""
case "${1:-}" in
  --run|run)       MODE=run ;;
  --build|build)   MODE=build ;;
  --status|status) MODE=status ;;
  --stop|stop)     MODE=stop ;;
  --list|list)     ls_list_components; exit 0 ;;
  -h|--help|help)  usage; exit 0 ;;
  "")
    echo "[ERROR] $SELF: a mode is required (--run, --build, --status, --stop)." >&2
    echo "" >&2
    usage >&2
    exit 1 ;;
  *)
    echo "[ERROR] $SELF: unknown mode '$1' - expected --run, --build, --status, --stop, --list or --help." >&2
    exit 1 ;;
esac
shift

# --run/--build abort on the first failure, so a failure trace is useful there.
# --stop/--status deliberately run without errexit (dead pids, missing
# containers and absent pid files are all normal), and an ERR trap fires even
# without errexit - so it stays off for them, or every such probe would print a
# scary line.
case "$MODE" in
  run|build)
    set -E   # ERR traps are not inherited by functions/subshells without this
    trap 'echo "[ERROR] local-stack.sh --$MODE failed at line $LINENO while running: $BASH_COMMAND" >&2' ERR
    ;;
esac

"mode_$MODE" "$@"
