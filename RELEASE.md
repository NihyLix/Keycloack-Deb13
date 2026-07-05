# Release notes

## v0.1.0 - Initial Debian 13 release

### Ajouté

- Script de contrôle `00-check-config.sh`
- Script PostgreSQL LXC `10-db-postgresql-install.sh`
- Script Keycloak VM `20-keycloak-install.sh`
- Script de vérification `30-keycloak-verify.sh`
- Script de mise à niveau `40-keycloak-upgrade.sh`
- Fichier `var.config.example`
- Exemple Nginx reverse proxy
- README d'exploitation

### Choix techniques

- Debian 13 uniquement
- Keycloak en service `systemd`
- PostgreSQL séparé sur LXC
- Configuration par fichier `var.config`
- Secret PostgreSQL stocké dans `/etc/keycloak/keycloak.env` avec permissions restrictives
- Keycloak démarré en mode production avec `kc.sh start --optimized`
- Health checks activés sur le port management `9000`
- Reverse proxy HTTPS attendu devant Keycloak

### Non inclus volontairement

- Configuration automatique d'un realm métier
- Configuration LDAP/AD
- Configuration SMTP
- Configuration MFA
- Gestion automatique des certificats TLS
- HA Keycloak multi-nœuds
- HA PostgreSQL

### Points d'attention

- Le compte `temp-admin` est temporaire et doit être supprimé après création d'un compte admin nominatif.
- Le port Keycloak `8080` ne doit pas être exposé directement à Internet.
- PostgreSQL doit rester limité à l'IP de la VM Keycloak.
