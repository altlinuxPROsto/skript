#!/bin/bash
set -e

# RAID5 (только если не существует)
if [ ! -b /dev/md0 ]; then
    apt-get install -y mdadm e2fsprogs
    mdadm --create /dev/md0 --level=5 --raid-devices=3 /dev/vdb /dev/vdc /dev/vdd --run
    mkfs.ext4 -F /dev/md0
    mkdir -p /srv/storage
    UUID=$(blkid -s UUID -o value /dev/md0)
    echo "UUID=$UUID /srv/storage ext4 defaults 0 2" >> /etc/fstab
    mount /srv/storage
else
    mount -a   # монтируем, если ещё не смонтировано
fi
mkdir -p /srv/storage/{instructions,share,secret}
chmod 755 /srv/storage/instructions
chmod 777 /srv/storage/share
chmod 770 /srv/storage/secret

# Локальные пользователи и SSH
apt-get update
apt-get install -y sudo openssh-server htop procps sshpass
for u in admin monitor; do
    id "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash "$u"
    echo "$u:P@ssw0rd" | chpasswd
done
cat > /etc/sudoers.d/lab-users <<'EOF'
admin ALL=(ALL) NOPASSWD: ALL
Cmnd_Alias MONITORING = /usr/bin/htop, /bin/htop, /usr/bin/df, /bin/df, /usr/bin/free, /bin/free, /usr/bin/journalctl, /bin/journalctl, /usr/bin/systemctl status *, /bin/systemctl status *
monitor ALL=(root) NOPASSWD: MONITORING
EOF
chmod 0440 /etc/sudoers.d/lab-users
echo "Authorized access only" > /etc/issue.net
SSHD_CONFIG=/etc/openssh/sshd_config
[ -f /etc/ssh/sshd_config ] && SSHD_CONFIG=/etc/ssh/sshd_config
if ! grep -q "^Port 2222" "$SSHD_CONFIG"; then
    sed -i '/^Port/d' "$SSHD_CONFIG"
    echo "Port 2222" >> "$SSHD_CONFIG"
    echo "Banner /etc/issue.net" >> "$SSHD_CONFIG"
    echo "MaxAuthTries 2" >> "$SSHD_CONFIG"
    echo "PermitRootLogin no" >> "$SSHD_CONFIG"
    echo "AllowUsers admin monitor" >> "$SSHD_CONFIG"
    systemctl restart sshd
fi

# NTP-клиент
apt-get install -y chrony
cat > /etc/chrony.conf <<EOF
server 172.16.0.1 iburst
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
systemctl enable --now chronyd

# Docker
apt-get install -y docker-engine docker-compose
systemctl enable --now docker
# Загрузка образов из ISO, если есть, иначе из Docker Hub (для демонстрации)
mkdir -p /mnt/additional
mount /dev/sr0 /mnt/additional 2>/dev/null || true
if [ -d /mnt/additional/docker ]; then
    for img in /mnt/additional/docker/*.tar; do
        [ -f "$img" ] && docker load -i "$img"
    done
else
    docker pull mariadb:latest && docker tag mariadb:latest mariadb_latest
    docker pull nginx:latest && docker tag nginx:latest site_latest
fi
mkdir -p /opt/testapp
cat > /opt/testapp/docker-compose.yml <<'EOF'
services:
  db:
    image: mariadb_latest
    container_name: db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: P@ssw0rd
      MYSQL_DATABASE: testdb
      MYSQL_USER: test
      MYSQL_PASSWORD: P@ssw0rd
    volumes:
      - dbdata:/var/lib/mysql
  testapp:
    image: site_latest
    container_name: testapp
    restart: unless-stopped
    depends_on:
      - db
    environment:
      DB_TYPE: maria
      DB_HOST: db
      DB_PORT: 3306
      DB_NAME: testdb
      DB_USER: test
      DB_PASS: P@ssw0rd
    ports:
      - "8080:8000"
volumes:
  dbdata:
EOF
cd /opt/testapp
docker compose up -d

# Apache, MariaDB, PHP
apt-get install -y apache2 mariadb-server php8.4 php8.4-mysqlnd apache2-mod_ssl
systemctl enable --now mariadb
systemctl enable --now httpd2

# База данных webdb и импорт дампа
mariadb <<'SQL'
CREATE DATABASE IF NOT EXISTS webdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'web'@'localhost' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost';
FLUSH PRIVILEGES;
SQL
if [ -f /mnt/additional/web/dump.sql ]; then
    mariadb webdb < /mnt/additional/web/dump.sql
fi
# Копирование файлов сайта
DOCROOT=/var/www/html
[ -d /var/www/default/html ] && DOCROOT=/var/www/default/html
mkdir -p "$DOCROOT"
if [ -f /mnt/additional/web/index.php ]; then
    cp /mnt/additional/web/index.php "$DOCROOT/"
fi
if [ -d /mnt/additional/web/images ]; then
    cp -r /mnt/additional/web/images "$DOCROOT/"
fi
chown -R apache2:apache2 "$DOCROOT" 2>/dev/null || chown -R apache:apache "$DOCROOT" 2>/dev/null || true
find "$DOCROOT" -type d -exec chmod 755 {} \;
find "$DOCROOT" -type f -exec chmod 644 {} \;
sed -i 's/$username = "user";/$username = "web";/' "$DOCROOT/index.php" 2>/dev/null
sed -i 's/$password = "password";/$password = "P@ssw0rd";/' "$DOCROOT/index.php" 2>/dev/null
sed -i 's/$dbname = "db";/$dbname = "webdb";/' "$DOCROOT/index.php" 2>/dev/null

# Ввод в домен и настройка Samba
apt-get install -y samba samba-client krb5-workstation samba-winbind bind-utils
# DNS-клиент
echo "nameserver 172.16.0.10" > /etc/net/ifaces/ens18/resolv.conf
systemctl restart network
# Kerberos
cat > /etc/krb5.conf <<'EOF'
[libdefaults]
  default_realm = LAB.LOCAL
  dns_lookup_realm = false
  dns_lookup_kdc = true
EOF
# Samba конфиг (без дубликатов)
if ! grep -q "^\[share\]" /etc/samba/smb.conf; then
    cat > /etc/samba/smb.conf <<'EOF'
[global]
   workgroup = LAB
   realm = LAB.LOCAL
   security = ADS
   kerberos method = secrets and keytab
   dedicated keytab file = /etc/krb5.keytab
   idmap config * : backend = tdb
   idmap config * : range = 3000-7999
   idmap config LAB : backend = rid
   idmap config LAB : range = 10000-999999
   winbind use default domain = yes
   winbind enum users = yes
   winbind enum groups = yes
   winbind nested groups = yes
   winbind expand groups = 1
   template shell = /bin/bash
   template homedir = /home/%D/%U
   log file = /var/log/samba/%m.log
   max log size = 1000
   ntlm auth = yes
   server signing = auto
[instructions]
   path = /srv/storage/instructions
   browseable = yes
   read only = yes
   guest ok = no
   valid users = @"LAB\Domain Users"
   write list = @"LAB\admins"
[share]
   path = /srv/storage/share
   browseable = yes
   read only = no
   guest ok = no
   valid users = @"LAB\Domain Users"
   create mask = 0666
   directory mask = 0777
[secret]
   path = /srv/storage/secret
   browseable = yes
   read only = no
   guest ok = no
   valid users = @"LAB\admins"
   create mask = 0660
   directory mask = 0770
EOF
fi
# Присоединение к домену (если ещё не присоединены)
if ! wbinfo -t 2>/dev/null; then
    rm -f /etc/krb5.keytab /var/lib/samba/private/secrets.tdb
    net ads join -U Administrator%P@ssw0rd
    net ads keytab create -U Administrator%P@ssw0rd
    systemctl enable --now winbind smb nmb
fi

# Настройка NSS для winbind (идемпотентно)
if ! grep -q "winbind" /etc/nsswitch.conf; then
    sed -i 's/^passwd:.*/passwd: files winbind/' /etc/nsswitch.conf
    sed -i 's/^group:.*/group: files winbind/' /etc/nsswitch.conf
    sed -i 's/^shadow:.*/shadow: files winbind/' /etc/nsswitch.conf
    systemctl restart winbind smb systemd-logind
fi

# Копирование сертификатов с DC (если ещё нет)
if [ ! -f /etc/pki/tls/certs/srv.lab.local.crt ]; then
    mkdir -p /etc/pki/tls/certs /etc/pki/tls/private
    scp -P 2222 admin@172.16.0.10:/root/ca/certs/srv.lab.local.crt /tmp/ 2>/dev/null && \
    scp -P 2222 admin@172.16.0.10:/root/ca/private/srv.lab.local.key /tmp/ 2>/dev/null && \
    scp -P 2222 admin@172.16.0.10:/root/ca/certs/lab-root-ca.crt /tmp/ 2>/dev/null && \
    mv /tmp/srv.lab.local.crt /etc/pki/tls/certs/ && \
    mv /tmp/srv.lab.local.key /etc/pki/tls/private/ && \
    mv /tmp/lab-root-ca.crt /etc/pki/tls/certs/ && \
    chmod 600 /etc/pki/tls/private/srv.lab.local.key
fi
# Настройка HTTPS для web и docker
cat > /etc/httpd2/conf/sites-available/lab-https.conf <<'EOF'
<VirtualHost *:80>
    ServerName web.lab.local
    Redirect 301 / https://web.lab.local/
</VirtualHost>
<VirtualHost *:443>
    ServerName web.lab.local
    DocumentRoot /var/www/html
    SSLEngine on
    SSLCertificateFile /etc/pki/tls/certs/srv.lab.local.crt
    SSLCertificateKeyFile /etc/pki/tls/private/srv.lab.local.key
    <Directory /var/www/html>
        Require all granted
    </Directory>
</VirtualHost>
<VirtualHost *:80>
    ServerName docker.lab.local
    Redirect 301 / https://docker.lab.local/
</VirtualHost>
<VirtualHost *:443>
    ServerName docker.lab.local
    SSLEngine on
    SSLCertificateFile /etc/pki/tls/certs/srv.lab.local.crt
    SSLCertificateKeyFile /etc/pki/tls/private/srv.lab.local.key
    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:8080/
    ProxyPassReverse / http://127.0.0.1:8080/
</VirtualHost>
EOF
ln -sf /etc/httpd2/conf/sites-available/lab-https.conf /etc/httpd2/conf/sites-enabled/
systemctl restart httpd2

echo "=== SRV setup finished ==="
