#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# NEXTCLOUD 35 - DEBIAN 13 TRIXIE
# Installation directe, sans reverse proxy
#
# Apache : 80 / 443
# PHP    : version Debian
# MariaDB
# Redis
# APCu
# HTTPS  : Let's Encrypt / Certbot
# Data  : /var/ncdata
# ==========================================================

NC_MAJOR="35"
NC_DIR="/var/www/nextcloud"
DATA_DIR="/var/ncdata"
DB_NAME="nextcloud"
DB_USER="ncuser"

CREDENTIALS="/root/nextcloud-credentials.txt"
LOG_FILE="/var/log/nextcloud-install.log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo
echo "=========================================================="
echo " INSTALLATION NEXTCLOUD ${NC_MAJOR} - DEBIAN 13"
echo "=========================================================="
date

# ----------------------------------------------------------
# VERIFICATIONS
# ----------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "ERREUR : exécuter le script en root."
    exit 1
fi

if ! grep -q 'VERSION_ID="13"' /etc/os-release; then
    echo "ERREUR : Debian 13 est requis."
    exit 1
fi

if [[ -e "$NC_DIR" ]]; then
    echo "ERREUR : $NC_DIR existe déjà."
    echo "Installation interrompue pour éviter tout écrasement."
    exit 1
fi

# ----------------------------------------------------------
# CONFIGURATION UTILISATEUR
# ----------------------------------------------------------

read -rp "Nom de domaine (ex: cloud.mondomaine.fr) : " DOMAIN
read -rp "Email Let's Encrypt : " EMAIL
read -rp "Utilisateur administrateur Nextcloud : " ADMIN_USER
read -rsp "Mot de passe administrateur Nextcloud : " ADMIN_PASS
echo

if [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$ADMIN_USER" || -z "$ADMIN_PASS" ]]; then
    echo "ERREUR : tous les champs sont obligatoires."
    exit 1
fi

if [[ "$DOMAIN" == *"/"* || "$DOMAIN" == *" "* ]]; then
    echo "ERREUR : domaine invalide."
    exit 1
fi

# ----------------------------------------------------------
# MISE A JOUR DEBIAN
# ----------------------------------------------------------

echo
echo "[1/11] Mise à jour Debian..."

apt-get update
apt-get upgrade -y

# ----------------------------------------------------------
# INSTALLATION PAQUETS
# ----------------------------------------------------------

echo
echo "[2/11] Installation des paquets..."

apt-get install -y \
    apache2 \
    mariadb-server \
    redis-server \
    cron \
    unzip \
    curl \
    wget \
    openssl \
    ca-certificates \
    certbot \
    python3-certbot-apache \
    libapache2-mod-php \
    php \
    php-cli \
    php-common \
    php-gd \
    php-mysql \
    php-curl \
    php-zip \
    php-xml \
    php-mbstring \
    php-intl \
    php-bcmath \
    php-gmp \
    php-imagick \
    php-apcu \
    php-redis \
    php-bz2 \
    php-ldap

systemctl enable --now apache2
systemctl enable --now mariadb
systemctl enable --now redis-server
systemctl enable --now cron

# ----------------------------------------------------------
# DETECTION PHP
# ----------------------------------------------------------

PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
PHP_INI="/etc/php/${PHP_VERSION}/apache2/php.ini"

echo "PHP détecté : ${PHP_VERSION}"

if [[ ! -f "$PHP_INI" ]]; then
    echo "ERREUR : php.ini introuvable."
    exit 1
fi

# ----------------------------------------------------------
# CONFIGURATION MARIADB
# ----------------------------------------------------------

echo
echo "[3/11] Configuration MariaDB..."

DB_PASS=""

DB_EXISTS=$(mariadb -Nse \
    "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';")

USER_EXISTS=$(mariadb -Nse \
    "SELECT COUNT(*) FROM mysql.user WHERE User='${DB_USER}' AND Host='localhost';")

if [[ "$DB_EXISTS" -eq 0 ]]; then
    echo "Création de la base ${DB_NAME}..."

    mariadb -e "
        CREATE DATABASE \`${DB_NAME}\`
        CHARACTER SET utf8mb4
        COLLATE utf8mb4_general_ci;
    "
else
    echo "Base ${DB_NAME} déjà présente : conservée."
fi

if [[ "$USER_EXISTS" -eq 0 ]]; then
    DB_PASS=$(openssl rand -hex 32)

    echo "Création utilisateur MariaDB ${DB_USER}..."

    mariadb -e "
        CREATE USER '${DB_USER}'@'localhost'
        IDENTIFIED BY '${DB_PASS}';
    "
else
    echo "Utilisateur MariaDB ${DB_USER} déjà présent."

    read -rsp "Mot de passe MariaDB existant pour ${DB_USER} : " DB_PASS
    echo

    if [[ -z "$DB_PASS" ]]; then
        echo "ERREUR : mot de passe vide."
        exit 1
    fi
fi

mariadb -e "
    GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.*
    TO '${DB_USER}'@'localhost';

    FLUSH PRIVILEGES;
"

# ----------------------------------------------------------
# CONFIGURATION PHP
# ----------------------------------------------------------

echo
echo "[4/11] Configuration PHP..."

sed -i 's/^memory_limit = .*/memory_limit = 512M/' "$PHP_INI"
sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 10G/' "$PHP_INI"
sed -i 's/^post_max_size = .*/post_max_size = 10G/' "$PHP_INI"
sed -i 's/^max_execution_time = .*/max_execution_time = 3600/' "$PHP_INI"
sed -i 's/^max_input_time = .*/max_input_time = 3600/' "$PHP_INI"

cat >> "$PHP_INI" <<'EOF'

; Nextcloud
date.timezone = Europe/Paris
output_buffering = 0

; OPcache
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.save_comments=1
opcache.revalidate_freq=1

; APCu
apc.enable_cli=1
EOF

# ----------------------------------------------------------
# CONFIGURATION APACHE
# ----------------------------------------------------------

echo
echo "[5/11] Configuration Apache..."

a2enmod rewrite headers env dir mime setenvif ssl

cat > /etc/apache2/sites-available/nextcloud.conf <<EOF
<VirtualHost *:80>

    ServerName ${DOMAIN}
    DocumentRoot ${NC_DIR}

    <Directory ${NC_DIR}>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
    </Directory>

    RewriteEngine On

    RewriteRule ^/\\.well-known/carddav$ /remote.php/dav/ [R=301,L]
    RewriteRule ^/\\.well-known/caldav$ /remote.php/dav/ [R=301,L]

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined

</VirtualHost>
EOF

a2dissite 000-default.conf || true
a2ensite nextcloud.conf

# ----------------------------------------------------------
# TELECHARGEMENT NEXTCLOUD
# ----------------------------------------------------------

echo
echo "[6/11] Téléchargement Nextcloud ${NC_MAJOR}..."

cd /tmp

ARCHIVE="latest-${NC_MAJOR}.zip"
CHECKSUM="${ARCHIVE}.sha256"

URL="https://download.nextcloud.com/server/releases/${ARCHIVE}"

rm -f "$ARCHIVE" "$CHECKSUM"

curl -fL --retry 3 --retry-delay 5 "$URL" -o "$ARCHIVE"
curl -fL --retry 3 --retry-delay 5 "${URL}.sha256" -o "$CHECKSUM"

if [[ ! -s "$ARCHIVE" || ! -s "$CHECKSUM" ]]; then
    echo "ERREUR : téléchargement incomplet."
    exit 1
fi

# Récupération du hash et normalisation du format
EXPECTED_HASH=$(awk 'NR==1 {print $1}' "$CHECKSUM")

if [[ ! "$EXPECTED_HASH" =~ ^[a-fA-F0-9]{64}$ ]]; then
    echo "ERREUR : format SHA256 invalide."
    cat "$CHECKSUM"
    exit 1
fi

printf "%s  %s\n" "$EXPECTED_HASH" "$ARCHIVE" > /tmp/nextcloud-checksum.tmp

if ! sha256sum -c /tmp/nextcloud-checksum.tmp; then
    echo "ERREUR : SHA256 incorrect."
    exit 1
fi

echo "Checksum validé."

# ----------------------------------------------------------
# EXTRACTION
# ----------------------------------------------------------

echo
echo "[7/11] Extraction Nextcloud..."

unzip -q "$ARCHIVE" -d /var/www/

mkdir -p "$DATA_DIR"

chown -R www-data:www-data "$NC_DIR"
chown -R www-data:www-data "$DATA_DIR"

chmod 750 "$DATA_DIR"

# ----------------------------------------------------------
# INSTALLATION NEXTCLOUD
# ----------------------------------------------------------

echo
echo "[8/11] Installation Nextcloud..."

systemctl restart apache2

runuser -u www-data -- php "${NC_DIR}/occ" maintenance:install \
    --database mysql \
    --database-name "${DB_NAME}" \
    --database-user "${DB_USER}" \
    --database-pass "${DB_PASS}" \
    --admin-user "${ADMIN_USER}" \
    --admin-pass "${ADMIN_PASS}" \
    --data-dir "${DATA_DIR}"

# ----------------------------------------------------------
# CONFIGURATION NEXTCLOUD
# ----------------------------------------------------------

echo
echo "[9/11] Configuration Nextcloud..."

OCC="runuser -u www-data -- php ${NC_DIR}/occ"

$OCC config:system:set trusted_domains 0 \
    --value="${DOMAIN}"

$OCC config:system:set overwrite.cli.url \
    --value="https://${DOMAIN}"

$OCC config:system:set default_phone_region \
    --value="FR"

# Cache local APCu
$OCC config:system:set memcache.local \
    --value='\OC\Memcache\APCu'

# Redis locking
$OCC config:system:set memcache.locking \
    --value='\OC\Memcache\Redis'

$OCC config:system:set redis host \
    --value="127.0.0.1"

$OCC config:system:set redis port \
    --type=integer --value=6379

# Cron
$OCC background:cron

cat > /etc/cron.d/nextcloud <<EOF
*/5 * * * * www-data php -f ${NC_DIR}/cron.php
EOF

chmod 644 /etc/cron.d/nextcloud

$OCC maintenance:update:htaccess

# ----------------------------------------------------------
# HTTPS CERTIFICAT
# ----------------------------------------------------------

echo
echo "[10/11] Installation certificat Let's Encrypt..."

systemctl reload apache2

certbot --apache \
    --non-interactive \
    --agree-tos \
    --email "${EMAIL}" \
    --redirect \
    -d "${DOMAIN}"

# Configuration HTTPS Nextcloud
$OCC config:system:set overwriteprotocol \
    --value="https"

# ----------------------------------------------------------
# FINALISATION
# ----------------------------------------------------------

echo
echo "[11/11] Finalisation..."

cat > "$CREDENTIALS" <<EOF
NEXTCLOUD_URL=https://${DOMAIN}
NEXTCLOUD_ADMIN=${ADMIN_USER}
MARIADB_DATABASE=${DB_NAME}
MARIADB_USER=${DB_USER}
MARIADB_PASSWORD=${DB_PASS}
DATA_DIRECTORY=${DATA_DIR}
EOF

chmod 600 "$CREDENTIALS"

systemctl restart mariadb
systemctl restart redis-server
systemctl restart apache2

rm -f "/tmp/${ARCHIVE}" "/tmp/${CHECKSUM}" "/tmp/nextcloud-checksum.tmp"

echo
echo "=========================================================="
echo " INSTALLATION TERMINEE"
echo "=========================================================="
echo
echo "Nextcloud : https://${DOMAIN}"
echo "Apache   : ports 80 / 443"
echo "PHP      : ${PHP_VERSION}"
echo "Data     : ${DATA_DIR}"
echo
echo "Identifiants enregistrés dans :"
echo "${CREDENTIALS}"
echo
runuser -u www-data -- php "${NC_DIR}/occ" status
echo
echo "=========================================================="
