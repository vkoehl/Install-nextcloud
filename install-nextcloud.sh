
#!/bin/bash
set -Eeuo pipefail

# ==========================================
# NEXTCLOUD 34 - DEBIAN 12 / PROXMOX
# Apache 8080 + MariaDB + Redis
# Reverse Proxy Nginx externe
# ==========================================

NC_VERSION="34"
NC_DIR="/var/www/nextcloud"
DATA_DIR="/var/ncdata"
DB_NAME="nextcloud"
DB_USER="ncuser"
BACKUP_FILE="/root/nextcloud-install-credentials.txt"

# Vérification root
if [[ "$EUID" -ne 0 ]]; then
    echo "Lance ce script avec sudo ou en root."
    exit 1
fi

if ! grep -q 'VERSION_ID="12"' /etc/os-release; then
    echo "Ce script nécessite Debian 12."
    exit 1
fi

if [[ -e "$NC_DIR" ]]; then
    echo "Nextcloud est déjà présent. Arrêt."
    exit 1
fi

echo "=========================================="
echo " INSTALLATION NEXTCLOUD SUR PROXMOX"
echo "=========================================="

read -rp "Domaine Nextcloud (cloud.mondomaine.fr) : " DOMAIN
read -rp "IP LAN de cette VM Debian : " VM_IP
read -rp "IP LAN du reverse proxy Nginx : " PROXY_IP
read -rp "Utilisateur administrateur Nextcloud : " ADMIN_USER
read -rsp "Mot de passe administrateur : " ADMIN_PASS
echo

if [[ -z "$DOMAIN" || -z "$VM_IP" || -z "$PROXY_IP" || -z "$ADMIN_USER" || -z "$ADMIN_PASS" ]]; then
    echo "Erreur : tous les champs sont obligatoires."
    exit 1
fi

if [[ "$DOMAIN" == *"/"* || "$DOMAIN" == *" "* ]]; then
    echo "Nom de domaine invalide."
    exit 1
fi

# Génération du mot de passe MariaDB
DB_PASS=$(openssl rand -hex 32)

echo
echo "Installation pour : $DOMAIN"
echo "IP VM : $VM_IP"
echo "IP Proxy : $PROXY_IP"
echo

# ------------------------------------------
# 1. Mise à jour Debian
# ------------------------------------------

echo "[1/10] Mise à jour Debian..."

apt-get update
apt-get upgrade -y

# ------------------------------------------
# 2. Installation des paquets
# ------------------------------------------

echo "[2/10] Installation Apache, PHP, MariaDB et Redis..."

apt-get install -y \
    apache2 \
    mariadb-server \
    redis-server \
    cron \
    curl \
    wget \
    unzip \
    openssl \
    ca-certificates \
    libapache2-mod-php8.2 \
    php8.2 \
    php8.2-cli \
    php8.2-common \
    php8.2-gd \
    php8.2-mysql \
    php8.2-curl \
    php8.2-zip \
    php8.2-xml \
    php8.2-mbstring \
    php8.2-intl \
    php8.2-bcmath \
    php8.2-gmp \
    php8.2-imagick \
    php8.2-apcu \
    php8.2-redis \
    php8.2-bz2 \
    php8.2-ldap

systemctl enable --now apache2
systemctl enable --now mariadb
systemctl enable --now redis-server
systemctl enable --now cron


# ------------------------------------------
# 3. Configuration MariaDB
# ------------------------------------------

echo "[3/10] Configuration MariaDB..."

# Génération d'un mot de passe uniquement si nécessaire
DB_PASS=$(openssl rand -hex 32)

# Vérification de l'existence de la base
DB_EXISTS=$(mariadb -Nse \
    "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';")

if [[ "$DB_EXISTS" -eq 0 ]]; then
    echo "Création de la base ${DB_NAME}..."
    mariadb -e "
        CREATE DATABASE \`${DB_NAME}\`
        CHARACTER SET utf8mb4
        COLLATE utf8mb4_general_ci;
    "
else
    echo "La base ${DB_NAME} existe déjà : conservation."
fi

# Vérification de l'existence de l'utilisateur
USER_EXISTS=$(mariadb -Nse \
    "SELECT COUNT(*) FROM mysql.user WHERE User='${DB_USER}' AND Host='localhost';")

if [[ "$USER_EXISTS" -eq 0 ]]; then
    echo "Création de l'utilisateur ${DB_USER}..."
    mariadb -e "
        CREATE USER '${DB_USER}'@'localhost'
        IDENTIFIED BY '${DB_PASS}';
    "
else
    echo "L'utilisateur ${DB_USER} existe déjà : conservation."

    # Récupération du mot de passe depuis la configuration Nextcloud
    if [[ -f "${NC_DIR}/config/config.php" ]]; then
        DB_PASS=$(php -r '
            include $argv[1];
            echo $CONFIG["dbpassword"];
        ' "${NC_DIR}/config/config.php")
    else
        echo "ERREUR : impossible de récupérer le mot de passe MariaDB."
        exit 1
    fi
fi

# Attribution des droits
mariadb -e "
    GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.*
    TO '${DB_USER}'@'localhost';

    FLUSH PRIVILEGES;
"

echo "Configuration MariaDB terminée."

# ------------------------------------------
# 4. Configuration Apache
# ------------------------------------------

echo "[4/10] Configuration Apache sur port 8080..."

# Apache écoute uniquement sur l'adresse LAN de la VM
if grep -q '^Listen 80$' /etc/apache2/ports.conf; then
    sed -i "s/^Listen 80$/Listen ${VM_IP}:8080/" /etc/apache2/ports.conf
else
    echo "Listen ${VM_IP}:8080" >> /etc/apache2/ports.conf
fi

a2dissite 000-default.conf || true

a2enmod rewrite headers env dir mime setenvif php8.2

cat > /etc/apache2/sites-available/nextcloud.conf <<EOF
<VirtualHost ${VM_IP}:8080>

    ServerName ${DOMAIN}
    DocumentRoot ${NC_DIR}

    <Directory ${NC_DIR}>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined

</VirtualHost>
EOF

a2ensite nextcloud.conf

# ------------------------------------------
# 5. Configuration PHP
# ------------------------------------------

echo "[5/10] Configuration PHP..."

PHP_INI="/etc/php/8.2/apache2/php.ini"

sed -i 's/^memory_limit = .*/memory_limit = 512M/' "$PHP_INI"
sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 10G/' "$PHP_INI"
sed -i 's/^post_max_size = .*/post_max_size = 10G/' "$PHP_INI"
sed -i 's/^max_execution_time = .*/max_execution_time = 3600/' "$PHP_INI"
sed -i 's/^max_input_time = .*/max_input_time = 3600/' "$PHP_INI"

cat >> "$PHP_INI" <<'EOF'

; Optimisations Nextcloud
date.timezone = Europe/Paris
output_buffering = 0
opcache.enable = 1
opcache.enable_cli = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.save_comments = 1
opcache.revalidate_freq = 1
apc.enable_cli = 1
EOF


# ------------------------------------------
# 6. Téléchargement Nextcloud
# ------------------------------------------

echo "[6/10] Téléchargement Nextcloud ${NC_VERSION}..."

cd /tmp

ARCHIVE="latest-${NC_VERSION}.zip"
CHECKSUM="${ARCHIVE}.sha256"

URL="https://download.nextcloud.com/server/releases/${ARCHIVE}"

# Nettoyage des anciens téléchargements
rm -f "$ARCHIVE" "$CHECKSUM"

# Téléchargement de Nextcloud
echo "Téléchargement de l'archive..."
curl -fL --retry 3 --retry-delay 5 "$URL" -o "$ARCHIVE"

# Téléchargement du checksum
echo "Téléchargement du SHA256..."
curl -fL --retry 3 --retry-delay 5 "${URL}.sha256" -o "$CHECKSUM"

# Vérification de l'existence des fichiers
if [[ ! -s "$ARCHIVE" || ! -s "$CHECKSUM" ]]; then
    echo "ERREUR : archive ou checksum manquant."
    exit 1
fi

# Vérification de l'intégrité
echo "Vérification SHA256..."

if sha256sum --check --ignore-missing "$CHECKSUM"; then
    echo "SHA256 : vérification réussie !"
else
    echo "ERREUR : SHA256 invalide."
    echo "L'installation est interrompue."
    rm -f "$ARCHIVE" "$CHECKSUM"
    exit 1
fi

# Extraction
echo "Extraction de Nextcloud..."

unzip -q "$ARCHIVE" -d /var/www/

# Préparation des dossiers
mkdir -p "$DATA_DIR"

chown -R www-data:www-data "$NC_DIR"
chown -R www-data:www-data "$DATA_DIR"

chmod 750 "$DATA_DIR"

echo "Nextcloud téléchargé et extrait avec succès."

# ------------------------------------------
# 7. Installation Nextcloud
# ------------------------------------------

echo "[7/10] Installation Nextcloud..."

systemctl restart apache2

runuser -u www-data -- php "$NC_DIR/occ" maintenance:install \
    --database mysql \
    --database-name "$DB_NAME" \
    --database-user "$DB_USER" \
    --database-pass "$DB_PASS" \
    --admin-user "$ADMIN_USER" \
    --admin-pass "$ADMIN_PASS" \
    --data-dir "$DATA_DIR"

# ------------------------------------------
# 8. Configuration reverse proxy
# ------------------------------------------

echo "[8/10] Configuration reverse proxy Nginx..."

OCC="runuser -u www-data -- php ${NC_DIR}/occ"

$OCC config:system:set trusted_domains 0 --value="$DOMAIN"

$OCC config:system:set trusted_proxies 0 --value="$PROXY_IP"

$OCC config:system:set overwritehost --value="$DOMAIN"

$OCC config:system:set overwriteprotocol --value="https"

$OCC config:system:set overwrite.cli.url --value="https://${DOMAIN}"

$OCC config:system:set default_phone_region --value="FR"

# ------------------------------------------
# 9. Redis et APCu
# ------------------------------------------

echo "[9/10] Configuration Redis et APCu..."

$OCC config:system:set memcache.local \
    --value='\OC\Memcache\APCu'

$OCC config:system:set memcache.locking \
    --value='\OC\Memcache\Redis'

$OCC config:system:set redis host \
    --value="127.0.0.1"

$OCC config:system:set redis port \
    --type=integer --value=6379

# Mise à jour des règles .htaccess
$OCC maintenance:update:htaccess

# Tâches planifiées
$OCC background:cron

cat > /etc/cron.d/nextcloud <<EOF
*/5 * * * * www-data php -f ${NC_DIR}/cron.php
EOF

chmod 644 /etc/cron.d/nextcloud

# ------------------------------------------
# 10. Sauvegarde des identifiants
# ------------------------------------------

echo "[10/10] Finalisation..."

cat > "$BACKUP_FILE" <<EOF
NEXTCLOUD DOMAIN=${DOMAIN}
NEXTCLOUD ADMIN=${ADMIN_USER}
MARIADB DATABASE=${DB_NAME}
MARIADB USER=${DB_USER}
MARIADB PASSWORD=${DB_PASS}
DATA DIRECTORY=${DATA_DIR}
VM IP=${VM_IP}
NGINX PROXY IP=${PROXY_IP}
EOF

chmod 600 "$BACKUP_FILE"

systemctl restart mariadb
systemctl restart redis-server
systemctl restart apache2

rm -f "/tmp/${ARCHIVE}" "/tmp/${ARCHIVE}.sha256"

echo
echo "=========================================="
echo " INSTALLATION TERMINEE"
echo "=========================================="
echo
echo "Nextcloud : https://${DOMAIN}"
echo "Backend Apache : http://${VM_IP}:8080"
echo "Proxy autorisé : ${PROXY_IP}"
echo "Stockage : ${DATA_DIR}"
echo
echo "Identifiants DB sauvegardés dans :"
echo "$BACKUP_FILE"
echo
echo "IMPORTANT : configure maintenant Nginx."
echo "Voir la configuration fournie séparément."
echo "=========================================="
