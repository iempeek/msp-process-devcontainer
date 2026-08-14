#!/usr/bin/env bash
# .devcontainer/local-stack-components.sh
#
# Shared component registry + selection handling for the local dev stack.
# SOURCED by local-stack.sh (every mode: --run/--build/--stop/--status), never
# run directly. Callers must have WS_ROOT set (dotnet/func targets below are
# relative to BACKEND_ROOT, frontend targets to FE_ROOT - see local-stack.sh).
#
# ===========================================================================
# TO ADD OR REMOVE A COMPONENT: edit the one-line registry below. Nothing
# else in local-stack.sh needs to change - groups, dependencies, presets, the
# interactive menu, the build list, health checks and log streaming are all
# derived from these lines.
#
#   sidecar    <id> <compose-service> <port> <label...>
#   dotnethost <id> <csproj-path>    <port> <label...>
#   funchost   <id> <project-dir>    <port> <label...>
#   webapp     <id> <dir-in-mspprocess-ui> <pnpm|yarn> <port> <label...>
#
# <port> is the well-known port to health-check; write "-" if there is none.
# Everything after the port is the human label. Ids are what you type in
# --components and what gets remembered in the selection file.
# ===========================================================================
#
# The remembered selection lives in .adlc-artifacts/local-stack/selection,
# which is gitignored, so each machine keeps its own answer to "what can this
# box actually afford to run".
#
# Requires: bash 4+ (associative arrays).

# --- registry storage (you should not need to touch this) ------------------
LS_IDS=()
declare -A LS_KIND=() LS_TARGET=() LS_PORT=() LS_LABEL=() LS_PM=()

_ls_add() { # <kind> <id> <target> <port> <label...>
  local kind="$1" id="$2" target="$3" port="$4"; shift 4
  LS_IDS+=("$id")
  LS_KIND["$id"]="$kind"
  LS_TARGET["$id"]="$target"
  LS_PORT["$id"]="$port"
  LS_LABEL["$id"]="$*"
}
# Deliberately NOT named `dotnet` / `func`: those are real CLIs the sibling
# scripts invoke, and a shell function would shadow them. Unset at the end of
# the registry for the same reason.
sidecar()    { _ls_add sidecar "$@"; }
dotnethost() { _ls_add dotnet  "$@"; }
funchost()   { _ls_add func    "$@"; }
# webapp takes one extra field (the package manager) before the port, and its
# id must be "fe-<slug>": the slug names the env file
# (.devcontainer/local/frontend-settings/env.<slug>) and the node_modules store
# (.adlc-artifacts/frontend/nm_<slug>).
webapp() {
  local id="$1" dir="$2" pm="$3"; shift 3
  _ls_add feapp "$id" "$dir" "$@"
  LS_PM["$id"]="$pm"
}

# ===========================================================================
# THE REGISTRY
# Sidecars: keep in sync with .devcontainer/compose.yaml (service names).
# Frontend: dirs are relative to the mspprocess-ui checkout; each id must be
# fe-<slug> where <slug> names its .devcontainer/local/frontend-settings/env.<slug>.
# ===========================================================================
sidecar mssql       mssql        1433  SQL Server "(main + Tech DBs)"
sidecar redis       redis        6379  Redis "(distributed cache)"
sidecar mongo       mongo        27017 Mongo "(CosmosDb Mongo API)"
sidecar azurite     azurite      10000 Azurite "(blobs/queues/tables)"
sidecar servicebus  servicebus   5672  Service Bus emulator
sidecar mailpit     mailpit      8025  Mailpit "(SMTP + web UI)"
sidecar soketi      soketi       6001  Soketi "(Pusher-compatible)"
sidecar stripe-mock stripe-mock  12111 stripe-mock "(billing)"
sidecar wiremock    wiremock     -     WireMock "(3rd-party stubs)"
sidecar n8n         n8n          -     n8n "(workflow automation)"

dotnethost api      Web/AlertManager.Api/AlertManager.Api.csproj                   5000 AlertManager.Api "(main API)"
dotnethost signalr  Web/MspProcess.SignalR/MspProcess.SignalR.csproj               5229 MspProcess.SignalR
dotnethost livechat Web/AlertManager.LiveChat.Api/AlertManager.LiveChat.Api.csproj 5033 AlertManager.LiveChat.Api

funchost fn-webhook   Azure/MspProcess.Functions.WebHookProcessor   7136 Functions.WebHookProcessor
funchost fn-result    Azure/MspProcess.Functions.ResultProcessor    7007 Functions.ResultProcessor
funchost fn-notify    Azure/MspProcess.Functions.NotificationSender 7197 Functions.NotificationSender
funchost fn-datasaver Azure/MspProcess.Functions.DataSaver          7190 Functions.DataSaver

webapp fe-web                      Web/AlertManager.Web              pnpm 3000 AlertManager.Web "(main app)"
webapp fe-auth                     Web/AlertManager.Auth.Web         yarn 3001 AlertManager.Auth.Web
webapp fe-pod                      Web/AlertManager.Pod.Web          pnpm 3002 AlertManager.Pod.Web
webapp fe-livechat-widget          Web/AlertManager.LiveChatWidget   yarn 3004 AlertManager.LiveChatWidget
webapp fe-tech-verification-widget Web/MspProcess.TechVerificationWidget yarn 3005 MspProcess.TechVerificationWidget
webapp fe-whitelabel               Web/MspProcess.WhiteLabel.Web     pnpm 3006 MspProcess.WhiteLabel.Web
webapp fe-client-portal            Web/AlertManager.ClientPortal.Web pnpm 3008 AlertManager.ClientPortal.Web

unset -f sidecar dotnethost funchost webapp _ls_add

# Sidecars every backend host needs to boot at all. Selecting any dotnet/func
# component pulls these in automatically.
LS_INFRA_DEPS="mssql redis mongo azurite servicebus"

# Extra hand-written presets. Group/kind presets (backend, frontend, sidecar,
# dotnet, func, feapp) plus "all"/"none" are derived and need no entry here.
declare -A LS_EXTRA_PRESETS=(
  # The cheapest thing that still boots a usable app - what a low-spec box
  # should normally run. Infra is added automatically.
  [minimal]="api fe-web"
  [hosts]="api signalr livechat"
  [functions]="fn-webhook fn-result fn-notify fn-datasaver"
  [sidecars]="sidecar"
  [infra]="mssql redis mongo azurite servicebus"
)

# ---------------------------------------------------------------------------
# Derived accessors. group: sidecar | backend | frontend.
# ---------------------------------------------------------------------------
ls_kind()   { echo "${LS_KIND[$1]}"; }
ls_target() { echo "${LS_TARGET[$1]}"; }
ls_label()  { echo "${LS_LABEL[$1]}"; }
ls_port()   { local p="${LS_PORT[$1]}"; [ "$p" = "-" ] && p=""; echo "$p"; }

ls_group() {
  case "${LS_KIND[$1]}" in
    sidecar)     echo sidecar ;;
    dotnet|func) echo backend ;;
    feapp)       echo frontend ;;
  esac
}

ls_requires() { # ids this component cannot run without
  case "${LS_KIND[$1]}" in
    dotnet|func) echo "$LS_INFRA_DEPS" ;;
    *)           echo "" ;;
  esac
}

ls_all_ids() { printf '%s\n' "${LS_IDS[@]}"; }
ls_is_id()   { [ -n "${LS_KIND[$1]:-}" ]; }

LS_STATE_DIR="$WS_ROOT/.adlc-artifacts/local-stack"
LS_SELECTION_FILE="$LS_STATE_DIR/selection"

# ---------------------------------------------------------------------------
# Selection state. LS_SELECTED is an associative array id -> 1.
# ---------------------------------------------------------------------------
declare -A LS_SELECTED=()

ls_selected() { [ -n "${LS_SELECTED[$1]:-}" ]; }

ls_selected_ids() { # registry order, so output is stable and readable
  local id
  for id in "${LS_IDS[@]}"; do ls_selected "$id" && echo "$id"; done
  return 0
}

ls_selected_ids_of_kind() {
  local want="$1" id
  for id in $(ls_selected_ids); do
    [ "${LS_KIND[$id]}" = "$want" ] && echo "$id"
  done
  return 0
}

ls_any_of_kind() { [ -n "$(ls_selected_ids_of_kind "$1")" ]; }

ls_selected_targets_of_kind() {
  local id
  for id in $(ls_selected_ids_of_kind "$1"); do echo "${LS_TARGET[$id]}"; done
  return 0
}

# Expand one token (id, kind, group, "all"/"none", or an extra preset).
ls_expand_token() {
  local token="$1" id
  case "$token" in
    all|"*") ls_all_ids; return 0 ;;
    none)    return 0 ;;
  esac
  if ls_is_id "$token"; then echo "$token"; return 0; fi
  # kind or group preset, derived straight from the registry
  for id in "${LS_IDS[@]}"; do
    if [ "${LS_KIND[$id]}" = "$token" ] || [ "$(ls_group "$id")" = "$token" ]; then
      echo "$id"
    fi
  done | grep . && return 0
  if [ -n "${LS_EXTRA_PRESETS[$token]:-}" ]; then
    local sub
    for sub in ${LS_EXTRA_PRESETS[$token]}; do ls_expand_token "$sub" || return 1; done
    return 0
  fi
  echo "[ERROR] unknown component or preset: '$token'" >&2
  echo "[ERROR] components: $(ls_all_ids | tr '\n' ' ')" >&2
  echo "[ERROR] presets:    all none sidecar backend frontend dotnet func feapp ${!LS_EXTRA_PRESETS[*]}" >&2
  return 1
}

# Parse a comma/space separated spec into LS_SELECTED (replacing it).
ls_resolve_spec() {
  local spec="$1" token id expanded
  LS_SELECTED=()
  for token in ${spec//,/ }; do
    # Capture first, THEN check the status: a `while read < <(...)` reports the
    # while loop's exit code, so an unknown token would slip through silently.
    expanded="$(ls_expand_token "$token")" || return 1
    for id in $expanded; do LS_SELECTED["$id"]=1; done
  done
  return 0
}

# Pull in every hard requirement of the current selection. A backend host
# without its infra fails in confusing ways at runtime, so this is automatic
# rather than a warning.
ls_close_requirements() {
  local changed=true id dep added=()
  while [ "$changed" = true ]; do
    changed=false
    for id in $(ls_selected_ids); do
      for dep in $(ls_requires "$id"); do
        if ! ls_selected "$dep"; then
          LS_SELECTED["$dep"]=1
          added+=("$dep")
          changed=true
        fi
      done
    done
  done
  [ "${#added[@]}" -gt 0 ] && echo "[INFO] Also starting required dependencies: ${added[*]}"
  return 0
}

# ---------------------------------------------------------------------------
# Persistence: a plain id-per-line list, trivially hand-editable.
# ---------------------------------------------------------------------------
ls_load_selection() {
  [ -f "$LS_SELECTION_FILE" ] || return 1
  local line found=false
  LS_SELECTED=()
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [ -z "$line" ] && continue
    if ls_is_id "$line"; then
      LS_SELECTED["$line"]=1
      found=true
    else
      echo "[WARNING] $LS_SELECTION_FILE: ignoring unknown component '$line'" >&2
    fi
  done < "$LS_SELECTION_FILE"
  [ "$found" = true ]
}

ls_save_selection() {
  # Never persist an empty selection: a bare re-run would then silently start
  # nothing, with no hint why.
  if [ -z "$(ls_selected_ids)" ]; then
    echo "[INFO] Empty selection - leaving the remembered one untouched."
    return 0
  fi
  mkdir -p "$LS_STATE_DIR"
  {
    echo "# Local dev stack selection - remembered by local-stack.sh --run."
    echo "# One component id per line; edit freely, or re-run with --menu."
    echo "# See every id with: local-stack.sh --list"
    ls_selected_ids
  } > "$LS_SELECTION_FILE"
  echo "[INFO] Selection saved to ${LS_SELECTION_FILE#"$WS_ROOT"/}"
}

ls_print_selection() {
  local id group last_group="" line=""
  echo "[INFO] Selected components:"
  for id in $(ls_selected_ids); do
    group="$(ls_group "$id")"
    if [ "$group" != "$last_group" ]; then
      [ -n "$line" ] && echo "$line"
      line="[INFO]   ${group}:"
      last_group="$group"
    fi
    line="$line $id"
  done
  if [ -n "$line" ]; then echo "$line"; else echo "[INFO]   (none)"; fi
}

ls_list_components() {
  local id group last_group=""
  printf '%-20s %-9s %-8s %-6s %s\n' "ID" "GROUP" "KIND" "PORT" "DESCRIPTION"
  for id in "${LS_IDS[@]}"; do
    group="$(ls_group "$id")"
    [ -n "$last_group" ] && [ "$group" != "$last_group" ] && echo ""
    last_group="$group"
    printf '%-20s %-9s %-8s %-6s %s\n' \
      "$id" "$group" "${LS_KIND[$id]}" "${LS_PORT[$id]}" "${LS_LABEL[$id]}"
  done
  echo ""
  echo "Presets: all none sidecar backend frontend dotnet func feapp ${!LS_EXTRA_PRESETS[*]}"
}

# ---------------------------------------------------------------------------
# Interactive checkbox menu.
#
# Reads from and writes to /dev/tty directly, so it still works when the
# script's stdout is piped. Arrow keys / j / k move, space toggles, Enter
# accepts, q aborts.
# ---------------------------------------------------------------------------
ls_menu_available() { [ -t 0 ] && [ -t 1 ] && [ -r /dev/tty ]; }

_ls_menu_draw() {
  local i id mark pointer group last_group="" lines=0
  for i in $(seq 0 $((${#LS_IDS[@]} - 1))); do
    id="${LS_IDS[$i]}"
    group="$(ls_group "$id")"
    if [ "$group" != "$last_group" ]; then
      printf '\r\033[K  --- %s ---\n' "$group" > /dev/tty
      lines=$((lines + 1))
      last_group="$group"
    fi
    mark=" "; ls_selected "$id" && mark="x"
    pointer="  "; [ "$i" -eq "$LS_MENU_CURSOR" ] && pointer="->"
    printf '\r\033[K%s [%s] %-20s %-6s %s\n' \
      "$pointer" "$mark" "$id" "${LS_PORT[$id]}" "${LS_LABEL[$id]}" > /dev/tty
    lines=$((lines + 1))
  done
  printf '\r\033[K\n' > /dev/tty
  printf '\r\033[K  space toggle   up/down or j/k move   a all   n none   i invert\n' > /dev/tty
  printf '\r\033[K  presets: b backend  f frontend  s sidecars  m minimal  u functions\n' > /dev/tty
  printf '\r\033[K  ENTER start selected   q abort\n' > /dev/tty
  LS_MENU_DRAWN=$((lines + 4))
}

_ls_menu_clear() {
  [ "${LS_MENU_DRAWN:-0}" -gt 0 ] || return 0
  printf '\033[%dA' "$LS_MENU_DRAWN" > /dev/tty
  LS_MENU_DRAWN=0
}

# Leaving the menu: rewind over it AND erase to the end of the screen, so the
# script's own output isn't printed on top of a half-visible checkbox list.
_ls_menu_finish() {
  _ls_menu_clear
  printf '\033[J' > /dev/tty
}

_ls_menu_toggle() {
  local id="$1"
  if ls_selected "$id"; then unset 'LS_SELECTED[$id]'; else LS_SELECTED["$id"]=1; fi
}

ls_menu() {
  local count="${#LS_IDS[@]}" key rest id
  LS_MENU_CURSOR=0
  LS_MENU_DRAWN=0

  printf '\n=== Local dev stack: pick what to run on this machine ===\n' > /dev/tty
  printf 'Unchecked components are simply not started (nothing is stopped for you).\n\n' > /dev/tty

  while true; do
    _ls_menu_draw
    IFS= read -rsn1 key < /dev/tty || { printf '\n' > /dev/tty; return 1; }
    case "$key" in
      $'\x1b')
        # Arrows arrive as ESC [ A/B; read the rest non-blocking so a bare ESC
        # keypress does not hang the menu.
        read -rsn2 -t 0.1 rest < /dev/tty || rest=""
        case "$rest" in
          "[A") LS_MENU_CURSOR=$(( (LS_MENU_CURSOR - 1 + count) % count )) ;;
          "[B") LS_MENU_CURSOR=$(( (LS_MENU_CURSOR + 1) % count )) ;;
        esac
        ;;
      k) LS_MENU_CURSOR=$(( (LS_MENU_CURSOR - 1 + count) % count )) ;;
      j) LS_MENU_CURSOR=$(( (LS_MENU_CURSOR + 1) % count )) ;;
      " ") _ls_menu_toggle "${LS_IDS[$LS_MENU_CURSOR]}" ;;
      a) for id in "${LS_IDS[@]}"; do LS_SELECTED["$id"]=1; done ;;
      n) LS_SELECTED=() ;;
      i) for id in "${LS_IDS[@]}"; do _ls_menu_toggle "$id"; done ;;
      b) ls_resolve_spec backend ;;
      f) ls_resolve_spec frontend ;;
      s) ls_resolve_spec sidecar ;;
      u) ls_resolve_spec functions ;;
      m) ls_resolve_spec minimal ;;
      q) _ls_menu_finish; printf '[INFO] Aborted - nothing was started.\n' > /dev/tty; return 1 ;;
      "") _ls_menu_finish; return 0 ;;
    esac
    _ls_menu_clear
  done
}

# ---------------------------------------------------------------------------
# One-stop selection resolution shared by the --run/--build/--stop modes.
#
#   ls_choose_selection <spec> <want_menu> <caller_label>
#     spec       explicit --components spec, or "" if none was given
#     want_menu  true | false | auto (auto = show it when on a terminal)
#
# Precedence: explicit spec > menu > remembered selection > "all" (the
# historical behaviour of these scripts).
# ---------------------------------------------------------------------------
ls_choose_selection() {
  local spec="$1" want_menu="$2" script_name="$3" show_menu=false

  if [ -n "$spec" ]; then
    ls_resolve_spec "$spec" || return 1
  elif ls_load_selection; then
    echo "[INFO] Using the remembered selection from ${LS_SELECTION_FILE#"$WS_ROOT"/} (change it with --menu)."
  else
    ls_resolve_spec all
  fi

  case "$want_menu" in
    true) show_menu=true ;;
    auto) [ -z "$spec" ] && ls_menu_available && show_menu=true ;;
  esac

  if [ "$show_menu" = true ]; then
    if ! ls_menu_available; then
      echo "[ERROR] $script_name: --menu needs an interactive terminal; use --components instead." >&2
      return 1
    fi
    ls_menu || return 1
    ls_save_selection
  elif [ -n "$spec" ]; then
    ls_save_selection
  fi

  ls_close_requirements
  ls_print_selection
  return 0
}
