chmod +x install-nextcloud.sh
./install-nextcloud.sh

systemctl status apache2
systemctl status mariadb
systemctl status redis-server

runuser -u www-data -- php /var/www/nextcloud/occ status
