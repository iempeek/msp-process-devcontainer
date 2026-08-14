#!/usr/bin/env bash
# =============================================================================
# .devcontainer/sonarqube-bootstrap.sh
#
# One-shot provisioning of SonarQube auth: generates a user token via the
# server API and writes SONAR_TOKEN / SONAR_HOST_URL into the repo's .env.
# Idempotent - if .env already holds a token that the server accepts, exits
# without changing anything.
#
# Credentials: uses the built-in admin account.
#   SONAR_ADMIN_USER      (default: admin)
#   SONAR_ADMIN_PASSWORD  (default: admin - the server's factory default)
# If the server rejects admin/admin and SONAR_ADMIN_PASSWORD is set, the
# script also tries rotating the factory password to that value first
# (fresh servers can require the default password to be changed before the
# account is fully usable).
#
# Usage:
#   bash .devcontainer/sonarqube-bootstrap.sh
#   SONAR_ADMIN_PASSWORD=newpass bash .devcontainer/sonarqube-bootstrap.sh
# =============================================================================
set -euo pipefail
trap 'echo "[ERROR] sonarqube-bootstrap.sh failed at line $LINENO while running: $BASH_COMMAND" >&2' ERR

SONAR_HOST_URL="${SONAR_HOST_URL:-http://sonarqube:9000}"
ADMIN_USER="${SONAR_ADMIN_USER:-admin}"
ADMIN_PASS="${SONAR_ADMIN_PASSWORD:-admin}"
TOKEN_NAME="${SONAR_TOKEN_NAME:-devcontainer}"

command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq not installed - run post-create.sh" >&2; exit 1; }

# Locate the workspace .env (same file devcontainer.json loads via --env-file).
# Anchored on this script's own location rather than `git rev-parse`, which
# would answer with whichever checkout the caller happens to stand in.
WS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$WS_ROOT/.env"

# --- 1. Wait for the server (first boot takes a while) --------------------------
echo -n "[INFO] waiting for SonarQube at $SONAR_HOST_URL "
for _ in $(seq 1 60); do
  if curl -fsS "$SONAR_HOST_URL/api/system/status" 2>/dev/null | jq -e '.status == "UP"' >/dev/null; then
    echo "- UP."
    UP=1; break
  fi
  echo -n "."; sleep 3
done
if [ "${UP:-0}" != "1" ]; then
  echo ""
  echo "[ERROR] server never came UP. Is the sonarqube service enabled in" >&2
  echo "        compose.yaml and started (bash .devcontainer/infra-up.sh)?" >&2
  exit 1
fi

# --- 2. Idempotency: is there already a working token in .env? -------------------
EXISTING="$(grep -oP '(?<=^SONAR_TOKEN=).*' "$ENV_FILE" 2>/dev/null || true)"
if [ -n "$EXISTING" ]; then
  if curl -fsS -u "$EXISTING:" "$SONAR_HOST_URL/api/authentication/validate" \
       | jq -e '.valid == true' >/dev/null 2>&1; then
    echo "[INFO] existing SONAR_TOKEN in .env is valid - nothing to do."
    exit 0
  fi
  echo "[WARNING] existing SONAR_TOKEN in .env is invalid - regenerating."
fi

# --- 3. Verify admin credentials (rotate factory password if needed) --------------
admin_ok() {
  curl -fsS -u "$ADMIN_USER:$ADMIN_PASS" "$SONAR_HOST_URL/api/authentication/validate" \
    | jq -e '.valid == true' >/dev/null 2>&1
}
if ! admin_ok; then
  # Maybe the server still has factory admin/admin and a custom password was
  # requested: rotate factory -> requested, then retry.
  if [ "$ADMIN_PASS" != "admin" ]; then
    echo "[INFO] trying to rotate factory admin password..."
    curl -fsS -u "admin:admin" -X POST \
      "$SONAR_HOST_URL/api/users/change_password" \
      -d "login=admin" -d "previousPassword=admin" -d "password=$ADMIN_PASS" \
      >/dev/null 2>&1 || true
  fi
  if ! admin_ok; then
    echo "[ERROR] cannot authenticate as '$ADMIN_USER'. If the admin password was" >&2
    echo "        changed manually, pass it: SONAR_ADMIN_PASSWORD=... $0" >&2
    exit 1
  fi
fi

# --- 4. Generate the token ---------------------------------------------------------
# Token names are unique per user: revoke any leftover with the same name first.
curl -fsS -u "$ADMIN_USER:$ADMIN_PASS" -X POST \
  "$SONAR_HOST_URL/api/user_tokens/revoke" -d "name=$TOKEN_NAME" >/dev/null 2>&1 || true

TOKEN="$(curl -fsS -u "$ADMIN_USER:$ADMIN_PASS" -X POST \
  "$SONAR_HOST_URL/api/user_tokens/generate" -d "name=$TOKEN_NAME" | jq -r '.token')"
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "[ERROR] token generation returned nothing." >&2; exit 1; }
echo "[INFO] generated token '$TOKEN_NAME'."

# --- 5. Write .env (create if missing, replace or append keys) ---------------------
touch "$ENV_FILE"
upsert_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}
upsert_env "SONAR_HOST_URL" "$SONAR_HOST_URL"
upsert_env "SONAR_TOKEN" "$TOKEN"
echo "[INFO] wrote SONAR_HOST_URL and SONAR_TOKEN to $ENV_FILE"

echo ""
echo "[INFO] done. Note: the current shell does not have the new variables yet."
echo "       sonarqube.sh reads .env automatically; for manual use run:"
echo "         set -a; source $ENV_FILE; set +a"
