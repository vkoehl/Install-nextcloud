#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# NEXTCLOUD 35 - DEBIAN 13
# Apache + PHP + MariaDB + Redis
# HTTP uniquement (sans SSL, sans Certbot, sans reverse proxy)
# Stockage local : /var/ncdata
# ==========================================================

NC_VERSION="35.0.3"
NC_URL="https://download.nextcloud.com/server/releases/nextcloud-${NC_VERSION}.zip"
NC_CHECKSUM_URL="${NC_URL}.sha256"

NC_DIR="/var/www/nextcloud"
NC_DATA="/var/ncdata"
NC_DB="nextcloud"
NC_DB_USER="ncuser"

APACHE_CONF="/etc/apache2/sites-available/nextcloud.conf"
CRON_FILE="/etc/cron.d/nextcloud"

TEMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# ----------------------------------------------------------
# Vérifications
# ----------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "Erreur : lance ce script en root."
    exit 1
fi

if ! grep -q 'VERSION_ID="13"' /etc/os-release; then
    echo "Erreur : ce script est prévu pour Debian 13."
    exit 1
fi

if [[ -d "$NC_DIR" ]]; then
    echo "Erreur : $NC_DIR existe déjà."
    echo "Le script refuse d'écraser une installation existante."
    exit 1
fi

if [[ -d "$NC_DATA" ]]; then
    echo "Erreur : $NC_DATA existe déjà."
    echo "Vérifie son contenu avant de poursuivre."
    exit 1
fi

# ----------------------------------------------------------
# Paramètres utilisateur
# ----------------------------------------------------------

echo
echo "===== Installation Nextcloud ${NC_VERSION} ====="
echo

read -rp "Nom de domaine ou IP du serveur (ex: cloud.mondomaine.fr) : " NC_HOST
read -rp "Nom du compte administrateur Nextcloud : " NC_ADMIN

read -rsp "Mot de passe administrateur Nextcloud : " NC_ADMIN_PASS
echo

read -rsp "Confirme le mot de passe administrateur : " NC_ADMIN_PASS_CONFIRM
echo

if [[ "$NC_ADMIN_PASS" != "$NC_ADMIN_PASS_CONFIRM" ]]; then
    echo "Erreur : les mots de passe ne correspondent pas."
    exit 1
fi

if [[ -z "$NC_HOST" || -z "$NC_ADMIN" || -z "$NC_ADMIN_PASS" ]]; then
    echo "Erreur : un champ obligatoire est vide."
    exit 1
fi

# ----------------------------------------------------------
# Base de données
# ----------------------------------------------------------

if mariadb -NBe "SHOW DATABASES LIKE '${NC_DB}';" 2>/dev/null | grep -q "${NC_DB}"; then
    echo "Erreur : la base ${NC_DB} existe déjà."
    exit 1
fi

if mariadb -NBe "SELECT User FROM mysql.user WHERE User='${NC_DB_USER}';" 2>/dev/null | grep -q "${NC_DB_USER}"; then
    echo "Erreur : l'utilisateur SQL ${NC_DB_USER} existe déjà."
    exit 1
fi

DB_PASS="$(openssl rand -base64 36 | tr -d '\n')"

# ----------------------------------------------------------
# Mise à jour Debian
# ----------------------------------------------------------

echo
echo "===== Mise à jour du système ====="

apt update
apt full-upgrade -y

# ----------------------------------------------------------
# Installation des paquets
# ----------------------------------------------------------

echo
echo "===== Installation des dépendances ====="

apt install -y \
    apache2 \
    mariadb-server \
    redis-server \
    unzip \
    curl \
    wget \
    rsync \
    sudo \
    cron \
    libapache2-mod-php \
    php \
    php-cli \
    php-common \
    php-mysql \
    php-gd \
    php-curl \
    php-mbstring \
    php-xml \
    php-zip \
    php-intl \
    php-bcmath \
    php-gmp \
    php-imagick \
    php-apcu \
    php-redis \
    php-ldap \
    php-bz2

systemctl enable --now apache2
systemctl enable --now mariadb
systemctl enable --now redis-server
systemctl enable --now cron

# ----------------------------------------------------------
# Configuration PHP
# ----------------------------------------------------------

echo
echo "===== Configuration PHP ====="

PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_INI="/etc/php/${PHP_VERSION}/apache2/php.ini"

if [[ ! -f "$PHP_INI" ]]; then
    echo "Erreur : php.ini introuvable : $PHP_INI"
    exit 1
fi

sed -i 's/^memory_limit = .*/memory_limit = 512M/' "$PHP_INI"
sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 10G/' "$PHP_INI"
sed -i 's/^post_max_size = .*/post_max_size = 10G/' "$PHP_INI"
sed -i 's/^max_execution_time = .*/max_execution_time = 3600/' "$PHP_INI"
sed -i 's/^max_input_time = .*/max_input_time = 3600/' "$PHP_INI"

sed -i 's/^;date.timezone =.*/date.timezone = Europe\/Paris/' "$PHP_INI"

cat >> "$PHP_INI" <<EOF

; Nextcloud optimisations
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=1
apc.enable_cli=1
EOF

# ----------------------------------------------------------
# Configuration MariaDB
# ----------------------------------------------------------

echo
echo "===== Configuration MariaDB ====="

mysql -u root <<SQL
CREATE DATABASE ${NC_DB}
CHARACTER SET utf8mb4
COLLATE utf8mb4_general_ci;

CREATE USER '${NC_DB_USER}'@'localhost'
IDENTIFIED BY '${DB_PASS}';

GRANT ALL PRIVILEGES ON ${NC_DB}.*
TO '${NC_DB_USER}'@'localhost';

FLUSH PRIVILEGES;
SQL

# ----------------------------------------------------------
# Configuration Apache
# ----------------------------------------------------------

echo
echo "===== Configuration Apache ====="

a2enmod rewrite headers env dir mime setenvif

a2dissite 000-default.conf || true

cat > "$APACHE_CONF" <<EOF
<VirtualHost *:80>
    ServerName ${NC_HOST}
    DocumentRoot ${NC_DIR}

    <Directory ${NC_DIR}>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined

    RewriteEngine On

    RewriteRule ^/\\.well-known/carddav$ /remote.php/dav/ [R=301,L]
    RewriteRule ^/\\.well-known/caldav$ /remote.php/dav/ [R=301,L]
</VirtualHost>
EOF

a2ensite nextcloud.conf

# ----------------------------------------------------------
# Téléchargement Nextcloud
# ----------------------------------------------------------

echo
echo "===== Téléchargement Nextcloud ${NC_VERSION} ====="

cd "$TEMP_DIR"

wget -q --show-progress "$NC_URL" -O nextcloud.zip
wget -q "$NC_CHECKSUM_URL" -O nextcloud.zip.sha256

EXPECTED_HASH="$(awk 'NR==1 {print $1}' nextcloud.zip.sha256)"

if [[ ! "$EXPECTED_HASH" =~ ^[a-fA-F0-9]{64}$ ]]; then
    echo "Erreur : checksum SHA256 invalide ou format inattendu."
    cat nextcloud.zip.sha256
    exit 1
fi

printf "%s  nextcloud.zip\n" "$EXPECTED_HASH" > nextcloud-check.sha256

echo "===== Vérification SHA256 ====="

sha256sum -c nextcloud-check.sha256

# ----------------------------------------------------------
# Extraction
# ----------------------------------------------------------

echo
echo "===== Extraction Nextcloud ====="

unzip -q nextcloud.zip -d /var/www/

mkdir -p "$NC_DATA"

chown -R www-data:www-data "$NC_DIR"
chown -R www-data:www-data "$NC_DATA"

chmod 750 "$NC_DATA"

# ----------------------------------------------------------
# Installation Nextcloud
# ----------------------------------------------------------

echo
echo "===== Installation Nextcloud ====="

sudo -u www-data php "$NC_DIR/occ" maintenance:install \
    --database mysql \
    --database-name "$NC_DB" \
    --database-user "$NC_DB_USER" \
    --database-pass "$DB_PASS" \
    --database-host localhost \
    --admin-user "$NC_ADMIN" \
    --admin-pass "$NC_ADMIN_PASS" \
    --data-dir "$NC_DATA"

# ----------------------------------------------------------
# Configuration Nextcloud
# ----------------------------------------------------------

echo
echo "===== Configuration Nextcloud ====="

OCC="sudo -u www-data php ${NC_DIR}/occ"

$OCC config:system:set trusted_domains 0 --value="localhost"
$OCC config:system:set trusted_domains 1 --value="$NC_HOST"

$OCC config:system:set default_phone_region --value="FR"
$OCC config:system:set memcache.local --value="\OC\Memcache\APCu"
$OCC config:system:set memcache.distributed --value="\OC\Memcache\Redis"
$OCC config:system:set memcache.locking --value="\OC\Memcache\Redis"

$OCC config:system:set redis host --value="localhost"
$OCC config:system:set redis port --type=integer --value=6379

$OCC background:cron

# ----------------------------------------------------------
# Configuration Cron
# ----------------------------------------------------------

echo
echo "===== Configuration Cron Nextcloud ====="

cat > "$CRON_FILE" <<EOF
*/5 * * * * www-data php -f ${NC_DIR}/cron.php
EOF

chmod 644 "$CRON_FILE"

# ----------------------------------------------------------
# Finalisation
# ----------------------------------------------------------

echo
echo "===== Finalisation ====="

$OCC maintenance:update:htaccess

systemctl restart mariadb
systemctl restart redis-server
systemctl restart apache2

# Sauvegarde des identifiants
cat > /root/nextcloud-credentials.txt <<EOF
Nextcloud
=========
Adresse : http://${NC_HOST}
Administrateur : ${NC_ADMIN}
Mot de passe : ${NC_ADMIN_PASS}

Base de données
==============
Nom : ${NC_DB}
Utilisateur : ${NC_DB_USER}
Mot de passe : ${DB_PASS}
EOF

chmod 600 /root/nextcloud-credentials.txt

rm -f "$TEMP_DIR/nextcloud.zip"
rm -f "$TEMP_DIR/nextcloud.zip.sha256"

# ----------------------------------------------------------
# Résultat
# ----------------------------------------------------------

echo
echo "=========================================================="
echo " INSTALLATION NEXTCLOUD TERMINEE"
echo "=========================================================="
echo
echo "URL : http://${NC_HOST}"
echo "Stockage : ${NC_DATA}"
echo "Base de données : MariaDB"
echo "Cache : Redis"
echo "PHP : ${PHP_VERSION}"
echo
echo "Identifiants enregistrés dans :"
echo "/root/nextcloud-credentials.txt"
echo
echo "IMPORTANT : installation HTTP uniquement."
echo "Aucun HTTPS, Certbot ou Let's Encrypt n'a été installé."
echo "=========================================================="
