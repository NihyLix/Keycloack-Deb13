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

NEED_BUILD=0
NEED_RESTART=0
NEED_DAEMON_RELOAD=0

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR:-}"' EXIT

install_if_changed() {
  local src="$1"
  local dest="$2"
  local mode="$3"
  local owner="$4"
  local group="$5"

  if [[ ! -f "${dest}" ]] || ! cmp -s "${src}" "${dest}"; then
    install -m "${mode}" -o "${owner}" -g "${group}" "${src}" "${dest}"
    return 0
  fi

  chown "${owner}:${group}" "${dest}"
  chmod "${mode}" "${dest}"
  return 1
}

ensure_group() {
  local group="$1"

  if ! getent group "${group}" >/dev/null 2>&1; then
    log "Création groupe système ${group}"
    groupadd --system "${group}"
  else
    log "Groupe déjà présent : ${group}"
  fi
}

ensure_user() {
  local user="$1"
  local group="$2"

  if ! id "${user}" >/dev/null 2>&1; then
    log "Création utilisateur système ${user}"
    useradd \
      --system \
      --gid "${group}" \
      --home-dir /var/lib/keycloak \
      --create-home \
      --shell /usr/sbin/nologin \
      "${user}"
  else
    log "Utilisateur déjà présent : ${user}"

    if ! id -nG "${user}" | tr ' ' '\n' | grep -qx "${group}"; then
      log "Ajout de ${user} au groupe ${group}"
      usermod -aG "${group}" "${user}"
    fi
  fi
}

log "Installation dépendances Debian 13"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates \
  curl \
  tar \
  gzip \
  procps \
  "${JAVA_PACKAGE}"

ensure_group "${KEYCLOAK_GROUP}"
ensure_user "${KEYCLOAK_USER}" "${KEYCLOAK_GROUP}"

install -d -m 0755 "${KEYCLOAK_INSTALL_ROOT}"
install -d -m 0755 "${KEYCLOAK_INSTALL_ROOT}/releases"
install -d -m 0750 -o "${KEYCLOAK_USER}" -g "${KEYCLOAK_GROUP}" /var/lib/keycloak
install -d -m 0750 -o "${KEYCLOAK_USER}" -g "${KEYCLOAK_GROUP}" /var/log/keycloak
install -d -m 0750 -o root -g "${KEYCLOAK_GROUP}" "${KEYCLOAK_CONF_DIR}"
install -d -m 0750 -o root -g "${KEYCLOAK_GROUP}" "${KEYCLOAK_MARKER_DIR}"

if [[ ! -d "${KEYCLOAK_RELEASE_DIR}" ]]; then
  log "Téléchargement Keycloak ${KEYCLOAK_VERSION}"

  curl -fsSL "${KEYCLOAK_DOWNLOAD_URL}" -o "${TMP_DIR}/${KEYCLOAK_URL_BASENAME}"
  curl -fsSL "${KEYCLOAK_DOWNLOAD_SHA1_URL}" -o "${TMP_DIR}/${KEYCLOAK_URL_BASENAME}.sha1"

  EXPECTED_SHA1="$(awk '{print $1}' "${TMP_DIR}/${KEYCLOAK_URL_BASENAME}.sha1")"
  ACTUAL_SHA1="$(sha1sum "${TMP_DIR}/${KEYCLOAK_URL_BASENAME}" | awk '{print $1}')"

  [[ "${EXPECTED_SHA1}" == "${ACTUAL_SHA1}" ]] || \
    fail "SHA1 Keycloak invalide. Attendu=${EXPECTED_SHA1} Obtenu=${ACTUAL_SHA1}"

  tar -xzf "${TMP_DIR}/${KEYCLOAK_URL_BASENAME}" -C "${KEYCLOAK_INSTALL_ROOT}/releases"
  chown -R "${KEYCLOAK_USER}:${KEYCLOAK_GROUP}" "${KEYCLOAK_RELEASE_DIR}"

  NEED_BUILD=1
  NEED_RESTART=1
else
  log "Release déjà présente : ${KEYCLOAK_RELEASE_DIR}"
fi

CURRENT_TARGET="$(readlink -f "${KEYCLOAK_CURRENT}" 2>/dev/null || true)"
if [[ "${CURRENT_TARGET}" != "${KEYCLOAK_RELEASE_DIR}" ]]; then
  log "Mise à jour du symlink current -> ${KEYCLOAK_RELEASE_DIR}"
  ln -sfn "${KEYCLOAK_RELEASE_DIR}" "${KEYCLOAK_CURRENT}"
  NEED_BUILD=1
  NEED_RESTART=1
else
  log "Symlink current déjà correct"
fi

if [[ ! -x "${KEYCLOAK_CURRENT}/bin/kc.sh" ]]; then
  fail "Binaire Keycloak introuvable ou non exécutable : ${KEYCLOAK_CURRENT}/bin/kc.sh"
fi

log "Préparation configuration Keycloak"

KEYCLOAK_CONF_TMP="${TMP_DIR}/keycloak.conf"
cat > "${KEYCLOAK_CONF_TMP}" <<KCCONF
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

if install_if_changed "${KEYCLOAK_CONF_TMP}" "${KEYCLOAK_CURRENT}/conf/keycloak.conf" 0640 "${KEYCLOAK_USER}" "${KEYCLOAK_GROUP}"; then
  log "Configuration Keycloak modifiée"
  NEED_BUILD=1
  NEED_RESTART=1
else
  log "Configuration Keycloak inchangée"
fi

KEYCLOAK_ENV_TMP="${TMP_DIR}/keycloak.env"
cat > "${KEYCLOAK_ENV_TMP}" <<ENVFILE
# Managed by keycloak-debian13/scripts/20-keycloak-install.sh
KC_DB_PASSWORD=$(single_quote "${DB_PASSWORD}")
JAVA_OPTS_APPEND=$(single_quote "${JAVA_OPTS_APPEND}")
ENVFILE

if install_if_changed "${KEYCLOAK_ENV_TMP}" "${KEYCLOAK_ENV_FILE}" 0640 root "${KEYCLOAK_GROUP}"; then
  log "Fichier environnement Keycloak modifié"
  NEED_RESTART=1
else
  log "Fichier environnement Keycloak inchangé"
fi

if [[ "${NEED_BUILD}" -eq 1 ]]; then
  log "Build optimisé Keycloak requis"
  runuser -u "${KEYCLOAK_USER}" -- "${KEYCLOAK_CURRENT}/bin/kc.sh" build
else
  log "Build Keycloak non requis"
fi

if is_true "${KEYCLOAK_BOOTSTRAP_ADMIN_ENABLE:-false}"; then
  require_vars KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD

  if [[ ! -f "${KEYCLOAK_BOOTSTRAP_MARKER}" ]]; then
    log "Bootstrap admin temporaire initial"

    if systemctl is-active --quiet keycloak 2>/dev/null; then
      log "Arrêt temporaire du service Keycloak pour bootstrap admin"
      systemctl stop keycloak
      NEED_RESTART=1
    fi

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
    chown root:"${KEYCLOAK_GROUP}" "${KEYCLOAK_BOOTSTRAP_MARKER}"
    chmod 0640 "${KEYCLOAK_BOOTSTRAP_MARKER}"

    NEED_RESTART=1
  else
    log "Bootstrap admin déjà marqué comme effectué : ${KEYCLOAK_BOOTSTRAP_MARKER}"
  fi
fi

log "Préparation service systemd"

SERVICE_TMP="${TMP_DIR}/keycloak.service"
cat > "${SERVICE_TMP}" <<SERVICE
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

if install_if_changed "${SERVICE_TMP}" /etc/systemd/system/keycloak.service 0644 root root; then
  log "Service systemd modifié"
  NEED_DAEMON_RELOAD=1
  NEED_RESTART=1
else
  log "Service systemd inchangé"
fi

if [[ "${NEED_DAEMON_RELOAD}" -eq 1 ]]; then
  systemctl daemon-reload
fi

if ! systemctl is-enabled --quiet keycloak 2>/dev/null; then
  log "Activation du service Keycloak au démarrage"
  systemctl enable keycloak
else
  log "Service Keycloak déjà activé"
fi

if [[ "${NEED_RESTART}" -eq 1 ]]; then
  log "Redémarrage Keycloak requis"
  systemctl restart keycloak
elif ! systemctl is-active --quiet keycloak; then
  log "Service Keycloak arrêté : démarrage"
  systemctl start keycloak
else
  log "Aucun redémarrage requis : service déjà actif"
fi

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

Actions effectuées :
Build requis       : ${NEED_BUILD}
Restart requis     : ${NEED_RESTART}
Daemon reload      : ${NEED_DAEMON_RELOAD}

Important : le compte ${KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME:-temp-admin} est temporaire.
Créer un vrai admin nominatif + MFA, puis supprimer ce compte temporaire.
REPORT
