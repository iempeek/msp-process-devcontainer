#!/usr/bin/env bash
# =============================================================================
# .devcontainer/initialize.sh
#
# Runs on the HOST (initializeCommand) before the container is created or
# started. Pre-creates, USER-owned, everything the docker daemon would
# otherwise auto-create as ROOT and thereby brick later steps:
#   * .env                      - runArgs --env-file hard-fails if missing
#   * .adlc-artifacts/claude    - mount TARGET; missing targets are created by
#                                 the daemon as root INSIDE the workspace bind
#                                 mount, leaving .adlc-artifacts/ unwritable for vscode
#   * .adlc-artifacts/<svc>_data - bind SOURCES for compose.yaml sidecars
#   * .adlc-artifacts/frontend/cache - shared pnpm store / yarn cache used by
#                                 the natively-run frontend dev servers
#   * ~/.claude                 - mount SOURCE; same root-owned trap if absent
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

touch .env
mkdir -p "$HOME/.claude"
mkdir -p .adlc-artifacts/claude
# Keep the data-dir list in sync with compose.yaml bind-mount volumes (mssql
# uses a named Docker volume instead, so it isn't listed here).
mkdir -p .adlc-artifacts/mongo_data .adlc-artifacts/azurite_data \
  .adlc-artifacts/n8n_data
# Shared pnpm store + yarn cache for the frontend sub-apps, which run natively
# in the devcontainer (see .devcontainer/local-stack-frontend.sh). Their
# node_modules live in the mspprocess-ui checkout itself; the old per-app
# nm_<slug> bind sources went away with the frontend container.
mkdir -p .adlc-artifacts/frontend/cache
