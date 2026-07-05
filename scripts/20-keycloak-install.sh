#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

CONFIG_FILE="${1:-${REPO_ROOT}/var.config}"

require_root
load_config "${CONFIG_FILE}"
require_debian_13
require_vars \
  DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD \
  KEYCLOAK_VERSION KEYCLOAK_INSTALL_ROOT KEYCLOAK_USER KEYCLOAK_GROUP \
  KEYCLOAK_PUBLIC_URL KEYCLOAK_HTTP_ENABLED KEYCLOAK_HTTP_HOST KEYCLOAK_HTTP_PORT \
  KEYCLOAK_PROXY_HEADERS KEYCLOAK_MANAGEMENT_PORT KEYCLOAK_HEALTH_ENABLED KEYCLOAK_METRICS_ENABLED \
  JAVA_PACKAGE JAVA_OPTS_APPEND

validate_pg_identifier "${DB_NAME}"
validate_pg_identifier "${DB_USER}"
[[ "${KEYCLOAK_PUBLIC_URL}" =~ ^https:// ]] || fail "KEYCLOAK_PUBLIC_URL doit commencer par https://"

KEYCLOAK_RELEASE_DIR="${KEYCLOAK_INSTALL_ROOT}/releases/keycloak-${KEYCLOAK_VERSION}"
KEYCLOAK_CURRENT="${KEYCLOAK_INSTALL_ROOT}/current"
KEYCLOAK_CONF_DIR="/etc/keycloak"
KEYCLOAK_ENV_FILE="${KEYCLOAK_CONF_DIR}/keycloak.env"
KEYCLOAK_MARKER_DIR="${KEYCLOAK_CONF_DIR}/state"
KEYCLOAK_BOOTSTRAP_MARKER="${KEYCLOAK_MARKER_DIR}/bootstrap-admin.done"
KEYCLOAK_URL_BASENAME="keycloak-${KEYCLOAK_VERSION}.tar.gz"
KEYCLOAK_DOWNLOAD_URL="https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/${KEYCLOAK_URL_BASENAME}"
KEYCLOAK_DOWNLOAD_SHA1_URL="${KEYCLOAK_DOWNLOAD_URL}.sha1"

log "Installation dépendances Debian 13"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates \
  curl \
  tar \
  gzip \
  procps \
  "${JAVA_PACKAGE}"

if ! id "${KEYCLOAK_USER}" >/dev/null 2>&1; then
  log "Création utilisateur système ${KEYCLOAK_USER}"
  useradd --system --home-dir /var/lib/keycloak --create-home --shell /usr/sbin/nologin "${KEYCLOAK_USER}"
fi

install -d -m 0755 "${KEYCLOAK_INSTALL_ROOT}/releases"
install -d -m 0750 -o "${KEYCLOAK_USER}" -g "${KEYCLOAK_GROUP}" /var/lib/keycloak
install -d -m 0750 -o "${KEYCLOAK_USER}" -g "${KEYCLOAK_GROUP}" /var/log/keycloak
install -d -m 0750 "${KEYCLOAK_CONF_DIR}"
install -d -m 0750 "${KEYCLOAK_MARKER_DIR}"

if [[ ! -d "${KEYCLOAK_RELEASE_DIR}" ]]; then
  log "Téléchargement Keycloak ${KEYCLOAK_VERSION}"
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR:-}"' EXIT

  curl -fsSL "${KEYCLOAK_DOWNLOAD_URL}" -o "${TMP_DIR}/${KEYCLOAK_URL_BASENAME}"
  curl -fsSL "${KEYCLOAK_DOWNLOAD_SHA1_URL}" -o "${TMP_DIR}/${KEYCLOAK_URL_BASENAME}.sha1"

  EXPECTED_SHA1="$(awk '{print $1}' "${TMP_DIR}/${KEYCLOAK_URL_BASENAME}.sha1")"
  ACTUAL_SHA1="$(sha1sum "${TMP_DIR}/${KEYCLOAK_URL_BASENAME}" | awk '{print $1}')"
  [[ "${EXPECTED_SHA1}" == "${ACTUAL_SHA1}" ]] || fail "SHA1 Keycloak invalide. Attendu=${EXPECTED_SHA1} Obtenu=${ACTUAL_SHA1}"

  tar -xzf "${TMP_DIR}/${KEYCLOAK_URL_BASENAME}" -C "${KEYCLOAK_INSTALL_ROOT}/releases"
  chown -R "${KEYCLOAK_USER}:${KEYCLOAK_GROUP}" "${KEYCLOAK_RELEASE_DIR}"
else
  log "Release déjà présente : ${KEYCLOAK_RELEASE_DIR}"
fi

ln -sfn "${KEYCLOAK_RELEASE_DIR}" "${KEYCLOAK_CURRENT}"

log "Écriture configuration Keycloak"
cat > "${KEYCLOAK_CURRENT}/conf/keycloak.conf" <<KCCONF
# Managed by keycloak-debian13/scripts/20-keycloak-install.sh
# Secrets are intentionally kept in ${KEYCLOAK_ENV_FILE}

db=postgres
db-url=jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}
db-username=${DB_USER}

hostname=${KEYCLOAK_PUBLIC_URL}
http-enabled=${KEYCLOAK_HTTP_ENABLED}
http-host=${KEYCLOAK_HTTP_HOST}
http-port=${KEYCLOAK_HTTP_PORT}
proxy-headers=${KEYCLOAK_PROXY_HEADERS}

health-enabled=${KEYCLOAK_HEALTH_ENABLED}
metrics-enabled=${KEYCLOAK_METRICS_ENABLED}
http-management-port=${KEYCLOAK_MANAGEMENT_PORT}

log=console,file
log-file=/var/log/keycloak/keycloak.log
KCCONF

chown "${KEYCLOAK_USER}:${KEYCLOAK_GROUP}" "${KEYCLOAK_CURRENT}/conf/keycloak.conf"
chmod 0640 "${KEYCLOAK_CURRENT}/conf/keycloak.conf"

cat > "${KEYCLOAK_ENV_FILE}" <<ENVFILE
# Managed by keycloak-debian13/scripts/20-keycloak-install.sh
KC_DB_PASSWORD=$(single_quote "${DB_PASSWORD}")
JAVA_OPTS_APPEND=$(single_quote "${JAVA_OPTS_APPEND}")
ENVFILE
chown root:"${KEYCLOAK_GROUP}" "${KEYCLOAK_ENV_FILE}"
chmod 0640 "${KEYCLOAK_ENV_FILE}"

log "Build optimisé Keycloak"
runuser -u "${KEYCLOAK_USER}" -- "${KEYCLOAK_CURRENT}/bin/kc.sh" build

if is_true "${KEYCLOAK_BOOTSTRAP_ADMIN_ENABLE:-false}"; then
  require_vars KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD
  if [[ ! -f "${KEYCLOAK_BOOTSTRAP_MARKER}" ]]; then
    log "Bootstrap admin temporaire initial"
    runuser -u "${KEYCLOAK_USER}" -- env \
      KC_DB="postgres" \
      KC_DB_URL="jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}" \
      KC_DB_USERNAME="${DB_USER}" \
      KC_DB_PASSWORD="${DB_PASSWORD}" \
      KC_HOSTNAME="${KEYCLOAK_PUBLIC_URL}" \
      KC_HTTP_ENABLED="${KEYCLOAK_HTTP_ENABLED}" \
      KC_HTTP_HOST="${KEYCLOAK_HTTP_HOST}" \
      KC_HTTP_PORT="${KEYCLOAK_HTTP_PORT}" \
      KC_PROXY_HEADERS="${KEYCLOAK_PROXY_HEADERS}" \
      KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD="${KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD}" \
      "${KEYCLOAK_CURRENT}/bin/kc.sh" bootstrap-admin user \
        --username "${KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME}" \
        --password:env KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD \
        --optimized \
        --no-prompt
    touch "${KEYCLOAK_BOOTSTRAP_MARKER}"
    chmod 0600 "${KEYCLOAK_BOOTSTRAP_MARKER}"
  else
    log "Bootstrap admin déjà marqué comme effectué : ${KEYCLOAK_BOOTSTRAP_MARKER}"
  fi
fi

log "Création service systemd"
cat > /etc/systemd/system/keycloak.service <<SERVICE
[Unit]
Description=Keycloak IAM Server
Documentation=https://www.keycloak.org/documentation
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${KEYCLOAK_USER}
Group=${KEYCLOAK_GROUP}
WorkingDirectory=${KEYCLOAK_CURRENT}
EnvironmentFile=${KEYCLOAK_ENV_FILE}
ExecStart=${KEYCLOAK_CURRENT}/bin/kc.sh start --optimized
Restart=on-failure
RestartSec=10
TimeoutStartSec=300
LimitNOFILE=102642
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable keycloak
systemctl restart keycloak

log "Contrôle service Keycloak"
systemctl --no-pager --full status keycloak || true

cat <<REPORT
Keycloak installé/configuré.

Version       : ${KEYCLOAK_VERSION}
Répertoire    : ${KEYCLOAK_RELEASE_DIR}
Symlink       : ${KEYCLOAK_CURRENT}
Service       : keycloak.service
URL publique  : ${KEYCLOAK_PUBLIC_URL}
Port HTTP     : ${KEYCLOAK_HTTP_PORT}
Port mgmt     : ${KEYCLOAK_MANAGEMENT_PORT}

Important : le compte ${KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME:-temp-admin} est temporaire.
Créer un vrai admin nominatif + MFA, puis supprimer ce compte temporaire.
REPORT
