# MSPProcess shared devcontainer

One devcontainer for both MSPProcess repos: the .NET backend and the React
frontend. It is opened on THIS folder, not on either repo, so both checkouts
sit inside the single workspace bind mount and one container can build, run and
debug the whole stack.

## Layout

```
<workspace>/          <- clone this repo here; open THIS folder in VS Code
  .devcontainer/      <- everything in this repo
  .env                <- host-local secrets (created for you, never committed)
  .adlc-artifacts/     <- sidecar data, frontend caches, local-stack state
  MSPProcess/         <- backend checkout   (BACKEND_DIR_NAME)
  mspprocess-ui/      <- frontend checkout  (FRONTEND_DIR_NAME)
```

Either checkout may be missing: the setup scripts skip the steps that need it,
so a frontend-only or backend-only workspace still builds. If your checkouts
use different folder names, change `BACKEND_DIR_NAME` / `FRONTEND_DIR_NAME` in
`.devcontainer/devcontainer.json` - no script hardcodes a folder name.

The agent harness (`.claude/`, `CLAUDE.md`, the ADLC skills) is NOT here. It
belongs to the backend repo and is used from inside that checkout.

## Setup

```bash
git clone <this-repo> msp-process && cd msp-process
git clone <backend-repo>  MSPProcess
git clone <frontend-repo> mspprocess-ui
code .          # then: Reopen in Container
```

On create/start the container installs the CLI toolchain and agent harnesses
(`post-create.sh`), symlinks the local settings overlay into the backend
checkout (`link-local-settings.sh`), and prepares the infrastructure on the
host docker daemon - shared network, data dirs, soketi relay (`infra-up.sh` +
`compose.yaml`). The sidecar containers themselves are NOT started: they come
up on demand, and only the selected ones, via `local-stack.sh --run` below
(`infra-up.sh --with-sidecars` starts the whole set at once).

Fill in any `[REQUIRED]` placeholders that `link-local-settings.sh` seeds into
`.env` before using the integrations that need them.

## Running the stack

One script owns the whole lifecycle, and it acts on a SELECTED SUBSET rather
than everything:

```bash
.devcontainer/local-stack.sh --run       # checkbox menu, then build + start + stream logs
.devcontainer/local-stack.sh --run -c minimal
.devcontainer/local-stack.sh --status    # read-only UP/DOWN table
.devcontainer/local-stack.sh --stop
.devcontainer/local-stack.sh --list      # every component id and preset
```

Components - sidecars, dotnet hosts, Functions hosts, Vite apps - are declared
one line each in `.devcontainer/local-stack-components.sh`; the menu, build
list, health checks and log streaming all derive from that registry, so adding
one is a one-line change.

## Files

| File | Role |
|---|---|
| `devcontainer.json` | image, features, mounts, ports, container env |
| `compose.yaml` | infrastructure sidecars (run on the HOST daemon) |
| `host-bootstrap.sh` | HOST pre-create (runs in a throwaway alpine container, so one file covers every host OS): dirs and `.env` the daemon must not create as root |
| `post-create.sh` | one-time: CLI toolbox, agent harnesses, scanners |
| `link-local-settings.sh` | symlinks `local/backend-settings/` into the backend checkout |
| `infra-up.sh` | every start: network join, sidecar data dirs, soketi relay (sidecars only with `--with-sidecars`) |
| `local-stack*.sh` | the local stack lifecycle (see above) |
| `local/` | the local settings layer: backend, frontend and infrastructure |
