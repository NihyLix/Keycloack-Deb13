# Keycloak Debian 13

Scripts d'installation pour une architecture simple :

- VM Debian 13 : Keycloak en service `systemd`
- LXC Debian 13 : PostgreSQL
- Reverse proxy HTTPS devant Keycloak

## Sources techniques

- Keycloak production : https://www.keycloak.org/server/configuration-production
- Keycloak configuration : https://www.keycloak.org/server/configuration
- Keycloak hostname : https://www.keycloak.org/server/hostname
- Keycloak database : https://www.keycloak.org/server/db
- Keycloak supported configurations : https://www.keycloak.org/server/supported-configurations
- Keycloak health checks : https://www.keycloak.org/observability/health
- Keycloak bootstrap admin : https://www.keycloak.org/server/bootstrap-admin-recovery
- Keycloak downloads : https://www.keycloak.org/downloads

## Arborescence

```text
keycloak-debian13/
├── README.md
├── RELEASE.md
├── var.config.example
├── scripts/
│   ├── 00-check-config.sh
│   ├── 10-db-postgresql-install.sh
│   ├── 20-keycloak-install.sh
│   ├── 30-keycloak-verify.sh
│   ├── 40-keycloak-upgrade.sh
│   └── lib/
│       └── common.sh
└── templates/
    └── nginx-keycloak.conf
```

## Pré-requis

### LXC PostgreSQL

- Debian 13
- IP fixe
- Accès réseau depuis la VM Keycloak vers le port PostgreSQL `5432`

### VM Keycloak

- Debian 13
- IP fixe
- Accès réseau vers le LXC PostgreSQL
- Accès Internet pour télécharger Keycloak depuis GitHub
- Reverse proxy HTTPS recommandé devant la VM

## Installation

### 1. Préparer la configuration

Sur les deux machines, déposer le projet puis créer le fichier actif :

```bash
cp var.config.example var.config
nano var.config
```

Variables à modifier obligatoirement :

```bash
KEYCLOAK_APP_IP="10.0.0.10"
DB_HOST="10.0.0.20"
DB_ALLOWED_CIDR="10.0.0.10/32"
DB_LISTEN_ADDRESSES="10.0.0.20"
DB_PASSWORD="CHANGE_ME_STRONG_DB_PASSWORD"
KEYCLOAK_PUBLIC_URL="https://sso.example.local"
KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD="CHANGE_ME_STRONG_TEMP_ADMIN_PASSWORD"
```

Contrôle de cohérence :

```bash
sudo ./scripts/00-check-config.sh ./var.config
```

## 2. Installer PostgreSQL sur le LXC BDD

À exécuter uniquement sur le LXC PostgreSQL :

```bash
sudo ./scripts/10-db-postgresql-install.sh ./var.config
```

Ce script fait uniquement :

- installation PostgreSQL via `apt`
- écoute PostgreSQL sur l'IP définie
- création de la base `keycloak`
- création/actualisation du rôle `keycloak`
- ajout d'une règle `pg_hba.conf` limitée à `DB_ALLOWED_CIDR`
- redémarrage PostgreSQL

## 3. Installer Keycloak sur la VM

À exécuter uniquement sur la VM Keycloak :

```bash
sudo ./scripts/20-keycloak-install.sh ./var.config
```

Ce script fait :

- installation Java
- création de l'utilisateur système `keycloak`
- téléchargement de la distribution Keycloak
- vérification SHA1 fournie par le projet Keycloak
- extraction dans `/opt/keycloak/releases/`
- configuration de `/opt/keycloak/current/conf/keycloak.conf`
- stockage du secret DB dans `/etc/keycloak/keycloak.env`
- build optimisé Keycloak
- création d'un compte admin temporaire si activé
- création et démarrage du service `systemd`

## 4. Vérifier

Sur la VM Keycloak :

```bash
sudo ./scripts/30-keycloak-verify.sh ./var.config
```

Contrôles manuels utiles :

```bash
systemctl status keycloak
journalctl -u keycloak -f
curl --head -fsS http://127.0.0.1:9000/health/ready
```

## 5. Reverse proxy

Un exemple Nginx est fourni :

```text
templates/nginx-keycloak.conf
```

À adapter :

- `server_name`
- chemins de certificats TLS
- IP de la VM Keycloak dans `proxy_pass`

Keycloak est configuré avec :

```text
http-enabled=true
proxy-headers=xforwarded
hostname=https://sso.example.local
```

Le TLS doit donc être porté par le reverse proxy.

## Sécurité post-install obligatoire

Après première connexion :

1. Créer un compte admin nominatif.
2. Activer MFA pour l'administration.
3. Supprimer le compte temporaire `temp-admin`.
4. Sauvegarder le fichier `var.config` dans un coffre ou ne pas le conserver en clair.
5. Restreindre le port `8080` aux seuls reverse proxies.
6. Ne pas exposer PostgreSQL hors réseau serveur.

## Mise à jour Keycloak

Modifier dans `var.config` :

```bash
KEYCLOAK_VERSION="x.y.z"
```

Puis sur la VM Keycloak :

```bash
sudo ./scripts/40-keycloak-upgrade.sh ./var.config
```

Le script réutilise l'installation standard et bascule le symlink `/opt/keycloak/current`.

## Emplacements

```text
/opt/keycloak/releases/        releases Keycloak
/opt/keycloak/current          symlink release active
/etc/keycloak/keycloak.env     secret DB + options JVM
/etc/systemd/system/keycloak.service
/var/log/keycloak/keycloak.log
```

## Remarques

- Debian 13 installe PostgreSQL 17 via le paquet `postgresql` standard.
- Keycloak supporte PostgreSQL 14 à 18, donc PostgreSQL 17 est cohérent.
- OpenJDK 21 est retenu par défaut car supporté par Keycloak et plus prévisible côté Debian.
- OpenJDK 25 peut être utilisé si disponible dans tes dépôts, en modifiant `JAVA_PACKAGE`.
