#!/usr/bin/env bash
# =============================================================================
# .devcontainer/link-local-settings.sh
#
# Layers local dev settings into the BACKEND checkout (postStartCommand, before
# infra-up.sh). The REAL files live in .devcontainer/local/backend-settings/, which
# mirrors the backend repo layout; each file gets a relative SYMLINK at the
# matching path under the backend checkout. Same inode on host and in the
# container (the workspace is one bind mount), so edits apply live - no
# rebuild, no re-link.
#
# Add a new local file: drop it at .devcontainer/local/backend-settings/<repo/path>
# and re-run this script (or restart the container).
#
# MOSTLY the linked names match a "local developer settings" pattern in the
# BACKEND repo's .gitignore (e.g. Azure/**/local.settings.json), so nothing
# reaches git there. One does NOT:
# Core/AlertManager.Settings/settings.Local.json is tracked as an empty `{}`
# stub. Replacing it with a symlink therefore shows up as a typechange in
# `git status` for the backend checkout. The real fix belongs in that repo
# (`git rm --cached` it and add it to .gitignore, like its Azure sibling);
# until then the placeholder handling below keeps this container working.
# =============================================================================
set -euo pipefail
trap 'echo "[ERROR] link-local-settings.sh failed at line $LINENO while running: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# The link TARGETS live in the backend checkout (a sibling of this devcontainer
# inside the workspace), the SOURCES here in the devcontainer repo. So the
# relative symlinks below now cross out of the backend repo - fine, because
# every target is gitignored there and this script recreates them on start.
BACKEND_ROOT="$WS_ROOT/${BACKEND_DIR_NAME:-MSPProcess}"
SRC_ROOT="$SCRIPT_DIR/local/backend-settings"

[ -d "$BACKEND_ROOT" ] || { echo "[ERROR] link-local-settings: no backend checkout at $BACKEND_ROOT (set BACKEND_DIR_NAME)." >&2; exit 1; }

[ -d "$SRC_ROOT" ] || { echo "[INFO] link-local-settings: no backend-settings dir, nothing to do."; exit 0; }

# Is this an EMPTY placeholder rather than someone's real settings? Some of the
# link targets are committed to the backend repo as a `{}` stub (notably
# Core/AlertManager.Settings/settings.Local.json, which - unlike
# Azure/**/local.settings.json - is tracked and NOT gitignored there), so a
# fresh checkout always has a real file sitting in the way. Skipping those, as
# the clobber guard below used to, is not a safe no-op: AppConfig loads
# settings.Local.json AND skips Key Vault whenever the local flags are set, so
# an empty overlay silently resolves Database:ConnectionString to the literal
# "<AzureKeyVaultValue>" from settings.json and the api dies on startup with
#   System.ArgumentException: Format of the initialization string does not
#   conform to specification starting at index 0.
# Whitespace-and-CR stripped, so a CRLF checkout counts as a stub too.
is_placeholder() {
  case "$(tr -d '[:space:]' < "$1")" in
    '' | '{}' | '[]') return 0 ;;
    *) return 1 ;;
  esac
}

find "$SRC_ROOT" -type f | while IFS= read -r src; do
  rel="${src#"$SRC_ROOT"/}"
  target="$BACKEND_ROOT/$rel"

  # Never clobber a real file someone placed there by hand - only manage
  # missing targets, our own (symlink) targets, and the empty stubs above.
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    if is_placeholder "$target"; then
      echo "[INFO] link-local-settings: $rel is an empty placeholder - replacing it with the link."
      rm -f "$target"
      # The csproj copies these to output with CopyToOutputDirectory=PreserveNewest,
      # and a build made while the placeholder was in the way left a `{}` copy in
      # every project's bin/ that is NEWER than the overlay - so the next build
      # would keep serving the empty one and the api would still fail to start.
      # Touching the overlay makes it the newest and forces the recopy.
      touch "$src"
      echo "[WARNING] link-local-settings: $rel exists as a real file with content - leaving it" >&2
      echo "[WARNING] alone. The overlay in local/backend-settings/ is NOT in effect for it." >&2
      continue
    fi
  fi

  mkdir -p "$(dirname "$target")"
  ln -sfn --relative "$src" "$target"
  echo "[INFO] linked $rel"
done

# Seed .env with the env-var secrets the backend needs but that must never be
# committed anywhere. local-stack.sh sources this file into the environment of
# each dotnet/func host it starts (there is no docker --env-file any more).
# Only appends keys that are absent - existing values are never touched.
ENV_FILE="$WS_ROOT/.env"
touch "$ENV_FILE"
for key in MSPPROCESS_AZURE_KV_CLIENTSECRET MSPPROCESS_AZURE_AUTH_KV_CLIENTSECRET; do
  if ! grep -q "^${key}=" "$ENV_FILE"; then
    echo "${key}=[REQUIRED]" >> "$ENV_FILE"
    echo "[INFO] seeded ${key}=[REQUIRED] in .env - fill in the real dev value."
  fi
done
