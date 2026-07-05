#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

CONFIG_FILE="${1:-${REPO_ROOT}/var.config}"

load_config "${CONFIG_FILE}"
require_vars DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD KEYCLOAK_PUBLIC_URL KEYCLOAK_HTTP_PORT KEYCLOAK_MANAGEMENT_PORT

KC_HOST_HEADER="$(printf '%s' "${KEYCLOAK_PUBLIC_URL}" | sed -E 's#^https?://([^/:/]+).*#\1#')"

printf '\n== Service systemd ==\n'
systemctl is-active --quiet keycloak && echo "keycloak: active" || echo "keycloak: inactive/failed"

printf '\n== PostgreSQL depuis VM Keycloak ==\n'
if command -v pg_isready >/dev/null 2>&1; then
  PGPASSWORD="${DB_PASSWORD}" pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" -U "${DB_USER}" || true
else
  echo "pg_isready absent. Installer postgresql-client pour ce test."
fi

printf '\n== Health Keycloak ==\n'
if curl --head -fsS "http://127.0.0.1:${KEYCLOAK_MANAGEMENT_PORT}/health/ready" >/dev/null; then
  echo "Health ready: OK"
else
  echo "Health ready: KO"
fi

printf '\n== OIDC discovery local via Host header ==\n'
if curl -fsS -H "Host: ${KC_HOST_HEADER}" "http://127.0.0.1:${KEYCLOAK_HTTP_PORT}/realms/master/.well-known/openid-configuration" | head -c 300; then
  printf '\nOIDC discovery: OK\n'
else
  printf '\nOIDC discovery: KO\n'
fi

printf '\n== Logs récents ==\n'
journalctl -u keycloak -n 80 --no-pager || true
