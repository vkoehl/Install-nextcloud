
#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# NEXTCLOUD 35 - DEBIAN 13
# HTTP uniquement - Sans reverse proxy - Sans HTTPS
# Apache / PHP / MariaDB / Redis
# ==========================================================

NC_VERSION="35.0.3"

NC_DIR="/var/www/nextcloud"
NC_DATA="/var/ncdata"

NC_DB="nextcloud"
NC_DB_USER="ncuser"

APACHE_CONF="/etc/apache2/sites-available/nextcloud.conf"
CRON_FILE="/etc/cron.d/nextcloud"

NC_URL="https://download.nextcloud.com/server/releases/nextcloud-${NC_VERSION}.zip"
NC_CHECKSUM_URL="${NC_URL}.sha256"

TEMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# ----------------------------------------------------------
# Vérifications système
# ----------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "Erreur : lance le script en root."
    exit 1
fi

if ! grep -q 'VERSION_ID="13"' /etc/os-release; then
    echo "Erreur : Debian 13 est requise."
    exit 1
fi

echo
echo "=========================================="
echo " INSTALLATION NEXTCLOUD ${NC_VERSION}"
echo "=========================================="

# ----------------------------------------------------------
# Détection de l'ancienne installation
# ----------------------------------------------------------

EXISTING=0

if [[ -d "$NC_DIR" ]]; then
    EXISTING=1
fi

if [[ -d "$NC_DATA" ]]; then
    EXISTING=1
fi

if [[ -f "$APACHE_CONF" ]]; then
    EXISTING=1
fi

if [[ -f "$CRON_FILE" ]]; then
    EXISTING=1
fi

echo
echo "===== Vérification des anciennes installations ====="

if command -v mariadb >/dev/null 2>&1; then
    if mariadb -NBe "SHOW DATABASES LIKE '${NC_DB}';" 2>/dev/null | grep -q "${NC_DB}"; then
        EXISTING=1
    fi

    if mariadb -NBe "SELECT User FROM mysql.user WHERE User='${NC_DB_USER}';" 2>/dev/null | grep -q "${NC_DB_USER}"; then
        EXISTING=1
    fi
fi

if [[ "$EXISTING" -eq 1 ]]; then

    echo
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo " ANCIENNE INSTALLATION NEXTCLOUD DETECTEE"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo
    echo "Les éléments suivants peuvent être supprimés :"
    echo
    echo "- ${NC_DIR}"
    echo "- ${NC_DATA}"
    echo "- Base MariaDB : ${NC_DB}"
    echo "- Utilisateur SQL : ${NC_DB_USER}"
    echo "- Configuration Apache Nextcloud"
    echo "- Cron Nextcloud"
    echo
    echo "ATTENTION : TOUTES LES DONNEES NEXTCLOUD"
    echo "SERONT DEFINITIVEMENT SUPPRIMEES !"
    echo

    read -rp "Pour confirmer la suppression, tape OUI : " CONFIRM

    if [[ "$CONFIRM" != "OUI" ]]; then
        echo "Annulation de l'installation."
        exit 1
    fi

    echo
    echo "===== Nettoyage de l'ancienne installation ====="

    # Désactivation du site Apache
    if [[ -f "$APACHE_CONF" ]]; then
        a2dissite nextcloud.conf 2>/dev/null || true
        rm -f "$APACHE_CONF"
    fi

    # Suppression du cron
    rm -f "$CRON_FILE"

    # Suppression de l'application
    rm -rf "$NC_DIR"

    # Suppression des données
    rm -rf "$NC_DATA"

    # Suppression DB et utilisateur MariaDB
    if command -v mariadb >/dev/null 2>&1; then
        mariadb <<SQL
DROP DATABASE IF EXISTS \`${NC_DB}\`;
DROP USER IF EXISTS '${NC_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    fi

    # Suppression éventuelle du fichier d'identifiants
    rm -f /root/nextcloud-credentials.txt

    echo "Ancienne installation supprimée."
fi

# ----------------------------------------------------------
# Paramètres d'installation
# ----------------------------------------------------------

echo
echo "===== Configuration ====="

read -rp "Domaine ou IP (ex: cloud.mondomaine.fr) : " NC_HOST
read -rp "Nom administrateur Nextcloud : " NC_ADMIN

read -rsp "Mot de passe administrateur Nextcloud : " NC_ADMIN_PASS
echo

read -rsp "Confirmer le mot de passe : " NC_ADMIN_PASS_CONFIRM
echo

if [[ "$NC_ADMIN_PASS" != "$NC_ADMIN_PASS_CONFIRM" ]]; then
    echo "Erreur : mots de passe différents."
    exit 1
fi

if [[ -z "$NC_HOST" || -z "$NC_ADMIN" || -z "$NC_ADMIN_PASS" ]]; then
    echo "Erreur : champs obligatoires manquants."
    exit 1
fi

# ----------------------------------------------------------
# Installation des paquets
# ----------------------------------------------------------

echo
echo "===== Mise à jour Debian ====="

apt update
apt full-upgrade -y

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
    openssl \
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
# Configuration MariaDB
# ----------------------------------------------------------

echo
echo "===== Configuration MariaDB ====="

DB_PASS="$(openssl rand -hex 32)"

mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${NC_DB}\`
CHARACTER SET utf8mb4
COLLATE utf8mb4_general_ci;

CREATE USER IF NOT EXISTS '${NC_DB_USER}'@'localhost'
IDENTIFIED BY '${DB_PASS}';

ALTER USER '${NC_DB_USER}'@'localhost'
IDENTIFIED BY '${DB_PASS}';

GRANT ALL PRIVILEGES ON \`${NC_DB}\`.*
TO '${NC_DB_USER}'@'localhost';

FLUSH PRIVILEGES;
SQL

# ----------------------------------------------------------
# Configuration PHP
# ----------------------------------------------------------

echo
echo "===== Configuration PHP ====="

PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
PHP_INI="/etc/php/${PHP_VERSION}/apache2/php.ini"

if [[ ! -f "$PHP_INI" ]]; then
    echo "Erreur : php.ini introuvable."
    exit 1
fi

PHP_CONF_DIR="/etc/php/${PHP_VERSION}/apache2/conf.d"
PHP_NC_CONF="${PHP_CONF_DIR}/99-nextcloud.ini"

cat > "$PHP_NC_CONF" <<EOF
memory_limit=512M
upload_max_filesize=10G
post_max_size=10G
max_execution_time=3600
max_input_time=3600
date.timezone=Europe/Paris

opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.revalidate_freq=1

apc.enable_cli=1
EOF

# ----------------------------------------------------------
# Configuration Apache
# ----------------------------------------------------------

echo
echo "===== Configuration Apache ====="

a2enmod rewrite headers env dir mime setenvif

a2dissite 000-default.conf 2>/dev/null || true

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
# Téléchargement et vérification
# ----------------------------------------------------------

echo
echo "===== Téléchargement Nextcloud ====="

cd "$TEMP_DIR"

wget -q --show-progress "$NC_URL" -O nextcloud.zip
wget -q "$NC_CHECKSUM_URL" -O nextcloud.sha256

EXPECTED_HASH="$(awk 'NR==1 {print $1}' nextcloud.sha256)"
ACTUAL_HASH="$(sha256sum nextcloud.zip | awk '{print $1}')"

if [[ ! "$EXPECTED_HASH" =~ ^[a-fA-F0-9]{64}$ ]]; then
    echo "Erreur : format du checksum officiel inattendu."
    cat nextcloud.sha256
    exit 1
fi

if [[ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]]; then
    echo "ERREUR : SHA256 incorrect."
    echo "Le fichier téléchargé n'est pas valide."
    exit 1
fi

echo "Checksum SHA256 valide."

# ----------------------------------------------------------
# Extraction Nextcloud
# ----------------------------------------------------------

echo
echo "===== Extraction ====="

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

OCC=(sudo -u www-data php "$NC_DIR/occ")

"${OCC[@]}" config:system:set trusted_domains 0 --value="localhost"
"${OCC[@]}" config:system:set trusted_domains 1 --value="$NC_HOST"

"${OCC[@]}" config:system:set default_phone_region --value="FR"

"${OCC[@]}" config:system:set memcache.local --value="\OC\Memcache\APCu"
"${OCC[@]}" config:system:set memcache.distributed --value="\OC\Memcache\Redis"
"${OCC[@]}" config:system:set memcache.locking --value="\OC\Memcache\Redis"

"${OCC[@]}" config:system:set redis host --value="localhost"
"${OCC[@]}" config:system:set redis port --type=integer --value=6379

"${OCC[@]}" background:cron

# ----------------------------------------------------------
# Cron
# ----------------------------------------------------------

echo
echo "===== Configuration Cron ====="

cat > "$CRON_FILE" <<EOF
*/5 * * * * www-data php -f ${NC_DIR}/cron.php
EOF

chmod 644 "$CRON_FILE"

# ----------------------------------------------------------
# Finalisation
# ----------------------------------------------------------

echo
echo "===== Finalisation ====="

"${OCC[@]}" maintenance:update:htaccess

systemctl restart mariadb
systemctl restart redis-server
systemctl restart apache2

# Sauvegarde des identifiants
cat > /root/nextcloud-credentials.txt <<EOF
NEXTCLOUD
==========
URL : http://${NC_HOST}
Administrateur : ${NC_ADMIN}
Mot de passe : ${NC_ADMIN_PASS}

MARIADB
=======
Base : ${NC_DB}
Utilisateur : ${NC_DB_USER}
Mot de passe : ${DB_PASS}
EOF

chmod 600 /root/nextcloud-credentials.txt

# ----------------------------------------------------------
# Résumé
# ----------------------------------------------------------

echo
echo "=============================================="
echo " INSTALLATION TERMINEE"
echo "=============================================="
echo
echo "URL : http://${NC_HOST}"
echo "Données : ${NC_DATA}"
echo "Base : ${NC_DB}"
echo "PHP : ${PHP_VERSION}"
echo
echo "Identifiants : /root/nextcloud-credentials.txt"
echo
echo "HTTP uniquement - Port 80"
echo "Aucun HTTPS ni reverse proxy."
echo "=============================================="
