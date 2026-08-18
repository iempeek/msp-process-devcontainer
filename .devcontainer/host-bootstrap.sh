#!/bin/sh
# =============================================================================
# .devcontainer/host-bootstrap.sh
#
# Runs on the HOST (initializeCommand) before the container is created or
# started - but NOT in the host's shell. devcontainer.json runs it inside a
# throwaway `docker run alpine` with the workspace and the host's ~/.claude
# bind-mounted in, so this is plain POSIX sh on EVERY host OS. Docker is the
# one runtime a devcontainer host is guaranteed to have, which is what makes
# this work on Linux and Windows from a single file. (It replaces the old
# initialize.sh + initialize_win.bat pair, which had to be kept in sync by
# hand.)
#
# Mount points (see initializeCommand in devcontainer.json):
#   /w          -> ${localWorkspaceFolder}
#   /hostclaude -> $HOME/.claude (or %USERPROFILE%\.claude)
#
# It pre-creates, USER-owned, everything the docker daemon would otherwise
# auto-create as ROOT and thereby brick later steps:
#   * .env                      - runArgs --env-file hard-fails if missing
#   * .adlc-artifacts/claude    - mount TARGET; missing targets are created by
#                                 the daemon as root INSIDE the workspace bind
#                                 mount, leaving .adlc-artifacts/ unwritable for vscode
#   * .adlc-artifacts/<svc>_data - bind SOURCES for compose.yaml sidecars
#   * .adlc-artifacts/frontend/cache - shared pnpm store / yarn cache used by
#                                 the natively-run frontend dev servers
#   * ~/.claude                 - mount SOURCE; same root-owned trap if absent
#
# OWNERSHIP: this container runs as root, so anything it creates on a Linux
# host would land root-owned - the exact breakage it exists to prevent. The
# workspace root itself is always owned by the human running VS Code, so it is
# used as the uid/gid reference to chown new paths back. On Docker Desktop
# (Windows/macOS) the bind mounts are a translation layer with no real Unix
# ownership: the reference reads back as root/arbitrary and the chowns are
# skipped or silently ignored, which is correct - there is nothing to fix.
# =============================================================================
set -eu

REF_UID="$(stat -c '%u' /w)"
REF_GID="$(stat -c '%g' /w)"

# Chown a path back to the workspace owner. No-op when the reference is root
# (Docker Desktop) or the path is already owned correctly.
reown() {
  [ "$REF_UID" = 0 ] && return 0
  [ "$(stat -c '%u' "$1")" = "$REF_UID" ] && return 0
  chown "$REF_UID:$REF_GID" "$1" 2>/dev/null || true
}

# --- .env: runArgs --env-file hard-fails if the file does not exist ----------
if [ ! -e /w/.env ]; then
  : > /w/.env
  reown /w/.env
fi

# --- host ~/.claude: bind SOURCE for the mounts entry ------------------------
# Docker auto-creates the source if it is missing, so by the time this runs the
# directory exists - possibly root-owned. Only the directory itself is
# reowned, never its contents: an existing config dir keeps whatever it has.
reown /hostclaude

# --- workspace dirs ----------------------------------------------------------
# .adlc-artifacts/claude is the mount TARGET for the above. The data dirs are
# bind SOURCES for compose.yaml sidecars (mssql uses a named Docker volume
# instead, so it is not listed); infra-up.sh re-creates them in-container on
# every start, so keep the list in sync with both. frontend/cache is the shared
# pnpm store + yarn cache for the frontend sub-apps, which run natively in the
# devcontainer (see .devcontainer/local-stack-frontend.sh).
for d in \
  .adlc-artifacts/claude \
  .adlc-artifacts/mongo_data \
  .adlc-artifacts/azurite_data \
  .adlc-artifacts/n8n_data \
  .adlc-artifacts/frontend/cache
do
  [ -d "/w/$d" ] && continue
  mkdir -p "/w/$d"
  # Reown every level this mkdir -p may have brought into existence.
  p=/w
  for seg in $(echo "$d" | tr '/' ' '); do
    p="$p/$seg"
    reown "$p"
  done
done
