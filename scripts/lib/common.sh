#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

log()  { printf '[%s] %s\n' "INFO" "$*"; }
warn() { printf '[%s] %s\n' "WARN" "$*" >&2; }
fail() { printf '[%s] %s\n' "ERROR" "$*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "Ce script doit être exécuté en root."
}

load_config() {
  local config_file="${1:-}"
  [[ -n "${config_file}" ]] || fail "Chemin var.config manquant."
  [[ -f "${config_file}" ]] || fail "Fichier de configuration introuvable : ${config_file}"

  # shellcheck source=/dev/null
  set -a
  source "${config_file}"
  set +a
}

require_debian_13() {
  [[ -r /etc/os-release ]] || fail "/etc/os-release introuvable."
  # shellcheck source=/etc/os-release
  source /etc/os-release
  [[ "${ID:-}" == "debian" ]] || fail "OS non supporté : ${ID:-unknown}. Debian 13 attendu."
  [[ "${VERSION_ID:-}" == "13" ]] || fail "Version Debian non supportée : ${VERSION_ID:-unknown}. Debian 13 attendu."
}

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "Variable obligatoire absente dans var.config : ${name}"
}

require_vars() {
  local name
  for name in "$@"; do
    require_var "${name}"
  done
}

is_true() {
  case "${1:-}" in
    true|TRUE|yes|YES|y|Y|1|oui|OUI) return 0 ;;
    *) return 1 ;;
  esac
}

validate_pg_identifier() {
  local value="$1"
  [[ "${value}" =~ ^[a-zA-Z_][a-zA-Z0-9_]{0,62}$ ]] || fail "Identifiant PostgreSQL invalide : ${value}"
}

backup_file_once() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  local backup="${file}.bak-keycloak"
  [[ -f "${backup}" ]] || cp -a "${file}" "${backup}"
}

single_quote() {
  # Quote POSIX shell simple pour fichiers EnvironmentFile.
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"
}

render_managed_block() {
  local file="$1"
  local begin_marker="$2"
  local end_marker="$3"
  local block_content="$4"
  local tmp
  tmp="$(mktemp)"

  if [[ -f "${file}" ]]; then
    awk -v begin="${begin_marker}" -v end="${end_marker}" '
      $0 == begin { skip=1; next }
      $0 == end   { skip=0; next }
      skip != 1   { print }
    ' "${file}" > "${tmp}"
  fi

  {
    cat "${tmp}"
    printf '\n%s\n' "${begin_marker}"
    printf '%s\n' "${block_content}"
    printf '%s\n' "${end_marker}"
  } > "${file}"

  rm -f "${tmp}"
}

repo_root_from_script() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  cd "${script_dir}/.." && pwd
}
