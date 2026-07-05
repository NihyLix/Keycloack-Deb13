#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

CONFIG_FILE="${1:-${REPO_ROOT}/var.config}"

require_root
load_config "${CONFIG_FILE}"
require_debian_13
require_vars DB_HOST DB_PORT DB_ALLOWED_CIDR DB_LISTEN_ADDRESSES DB_NAME DB_USER DB_PASSWORD
validate_pg_identifier "${DB_NAME}"
validate_pg_identifier "${DB_USER}"

log "Installation PostgreSQL sur LXC Debian 13"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql postgresql-client postgresql-contrib

systemctl enable --now postgresql

PG_MAJOR="$(pg_lsclusters -h | awk '$4 == "online" {print $1; exit}')"
[[ -n "${PG_MAJOR}" ]] || fail "Aucun cluster PostgreSQL online détecté."

PG_CONF_DIR="/etc/postgresql/${PG_MAJOR}/main"
PG_HBA="${PG_CONF_DIR}/pg_hba.conf"
PG_KEYCLOAK_CONF="${PG_CONF_DIR}/conf.d/99-keycloak.conf"

[[ -d "${PG_CONF_DIR}" ]] || fail "Répertoire PostgreSQL introuvable : ${PG_CONF_DIR}"
[[ -f "${PG_HBA}" ]] || fail "pg_hba.conf introuvable : ${PG_HBA}"

backup_file_once "${PG_HBA}"
install -d -m 0755 "${PG_CONF_DIR}/conf.d"

cat > "${PG_KEYCLOAK_CONF}" <<PGCONF
# Managed by keycloak-debian13/scripts/10-db-postgresql-install.sh
listen_addresses = '${DB_LISTEN_ADDRESSES}'
port = ${DB_PORT}
password_encryption = 'scram-sha-256'
PGCONF

PG_HBA_BLOCK="host    ${DB_NAME}    ${DB_USER}    ${DB_ALLOWED_CIDR}    scram-sha-256"
render_managed_block \
  "${PG_HBA}" \
  "# BEGIN KEYCLOAK MANAGED" \
  "# END KEYCLOAK MANAGED" \
  "${PG_HBA_BLOCK}"

log "Création/actualisation du rôle et de la base PostgreSQL"
sudo -u postgres psql -v ON_ERROR_STOP=1 \
  -v db_user="${DB_USER}" \
  -v db_pass="${DB_PASSWORD}" \
  -v db_name="${DB_NAME}" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'db_user', :'db_pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'db_user')\gexec

SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'db_user', :'db_pass')\gexec

SELECT format('CREATE DATABASE %I OWNER %I ENCODING %L', :'db_name', :'db_user', 'UTF8')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db_name')\gexec

SELECT format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', :'db_name', :'db_user')\gexec
SQL

log "Redémarrage PostgreSQL"
systemctl restart postgresql

log "Contrôle local PostgreSQL"
pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -d "${DB_NAME}" || fail "PostgreSQL ne répond pas sur ${DB_HOST}:${DB_PORT}."

cat <<REPORT
PostgreSQL configuré.

Version cluster : ${PG_MAJOR}
Conf            : ${PG_KEYCLOAK_CONF}
HBA             : ${PG_HBA}
Base            : ${DB_NAME}
Utilisateur     : ${DB_USER}
Autorisé        : ${DB_ALLOWED_CIDR}
REPORT
