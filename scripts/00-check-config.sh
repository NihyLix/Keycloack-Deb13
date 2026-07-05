#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

CONFIG_FILE="${1:-${REPO_ROOT}/var.config}"

load_config "${CONFIG_FILE}"
require_debian_13

require_vars \
  KEYCLOAK_APP_IP \
  DB_HOST \
  DB_PORT \
  DB_ALLOWED_CIDR \
  DB_LISTEN_ADDRESSES \
  DB_NAME \
  DB_USER \
  DB_PASSWORD \
  KEYCLOAK_VERSION \
  KEYCLOAK_INSTALL_ROOT \
  KEYCLOAK_USER \
  KEYCLOAK_GROUP \
  KEYCLOAK_PUBLIC_URL \
  KEYCLOAK_HTTP_ENABLED \
  KEYCLOAK_HTTP_HOST \
  KEYCLOAK_HTTP_PORT \
  KEYCLOAK_PROXY_HEADERS \
  KEYCLOAK_MANAGEMENT_PORT \
  JAVA_PACKAGE

validate_pg_identifier "${DB_NAME}"
validate_pg_identifier "${DB_USER}"

[[ "${KEYCLOAK_PUBLIC_URL}" =~ ^https:// ]] || fail "KEYCLOAK_PUBLIC_URL doit être une URL HTTPS complète. Exemple : https://sso.example.local"
[[ "${DB_PORT}" =~ ^[0-9]+$ ]] || fail "DB_PORT invalide."
[[ "${KEYCLOAK_HTTP_PORT}" =~ ^[0-9]+$ ]] || fail "KEYCLOAK_HTTP_PORT invalide."
[[ "${KEYCLOAK_MANAGEMENT_PORT}" =~ ^[0-9]+$ ]] || fail "KEYCLOAK_MANAGEMENT_PORT invalide."

cat <<REPORT
Configuration OK.

Fichier         : ${CONFIG_FILE}
OS              : Debian 13
Keycloak        : ${KEYCLOAK_VERSION}
URL publique    : ${KEYCLOAK_PUBLIC_URL}
VM Keycloak IP  : ${KEYCLOAK_APP_IP}
PostgreSQL      : ${DB_HOST}:${DB_PORT}/${DB_NAME}
CIDR autorisé   : ${DB_ALLOWED_CIDR}
Java package    : ${JAVA_PACKAGE}
REPORT
