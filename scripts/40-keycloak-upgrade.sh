#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

CONFIG_FILE="${1:-${REPO_ROOT}/var.config}"

require_root
load_config "${CONFIG_FILE}"
require_debian_13
require_vars KEYCLOAK_VERSION KEYCLOAK_INSTALL_ROOT KEYCLOAK_USER KEYCLOAK_GROUP

CURRENT_TARGET="$(readlink -f "${KEYCLOAK_INSTALL_ROOT}/current" 2>/dev/null || true)"
NEW_RELEASE_DIR="${KEYCLOAK_INSTALL_ROOT}/releases/keycloak-${KEYCLOAK_VERSION}"

if [[ "${CURRENT_TARGET}" == "${NEW_RELEASE_DIR}" ]]; then
  log "Déjà sur Keycloak ${KEYCLOAK_VERSION}. Rien à faire."
  exit 0
fi

log "Mise à niveau vers Keycloak ${KEYCLOAK_VERSION}"
"${SCRIPT_DIR}/20-keycloak-install.sh" "${CONFIG_FILE}"

log "Contrôle après mise à niveau"
"${SCRIPT_DIR}/30-keycloak-verify.sh" "${CONFIG_FILE}" || true
