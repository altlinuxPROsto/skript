#!/bin/bash
# ========== srv.lab.local ==========
set -e

hostnamectl set-hostname srv.lab.local
IFACE=ens18
mkdir -p /etc/net/ifaces/$IFACE

cat > /etc/net/ifaces/$IFACE/options <<EOF
TYPE=eth
BOOTPROTO=dhcp
ONBOOT=yes
NM_CONTROLLED=no
DISABLED=no
EOF

cat > /etc/net/ifaces/$IFACE/resolv.conf <<EOF
search lab.local
nameserver 8.8.8.8
EOF

cat > /etc/hosts <<EOF
127.0.0.1 localhost
172.16.0.1 isp.lab.local isp
172.16.0.10 dc.lab.local dc
172.16.0.20 srv.lab.local srv
EOF

systemctl restart network
ip -br a

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
sed -i -E '/^[[:space:]]*#?[[:space:]]*(Port|Banner|MaxAuthTries|PermitRootLogin|AllowUsers)[[:space:]]/d' "$SSHD_CONFIG"
cat >> "$SSHD_CONFIG" <<'EOF'

Port 2222
Banner /etc/issue.net
MaxAuthTries 2
PermitRootLogin no
AllowUsers admin monitor
EOF
sshd -t -f "$SSHD_CONFIG"
systemctl enable --now sshd
systemctl restart sshd

apt-get install -y chrony
cat > /etc/chrony.conf <<'EOF'
server 172.16.0.1 iburst
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony
systemctl restart chronyd 2>/dev/null || systemctl restart chrony

apt-get install -y docker-engine docker-compose
systemctl enable --now docker

mkdir -p /mnt/additional
mount /dev/sr0 /mnt/additional 2>/dev/null || mount /dev/cdrom /mnt/additional 2>/dev/null || true
if [ -d /mnt/additional/docker ]; then
  for img in /mnt/additional/docker/*.tar; do
    [ -f "$img" ] && docker load -i "$img"
  done
fi
if ! docker image inspect mariadb_latest >/dev/null 2>&1; then
  docker pull mariadb:latest && docker tag mariadb:latest mariadb_latest
fi
if ! docker image inspect site_latest >/dev/null 2>&1; then
  docker pull nginx:latest && docker tag nginx:latest site_latest
fi
mkdir -p /opt/testapp
cd /opt/testapp
cat > docker-compose.yml <<'EOF'
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
      DB_HOST: db
      DB_NAME: testdb
      DB_DATABASE: testdb
      DB_USER: test
      DB_USERNAME: test
      DB_PASSWORD: P@ssw0rd
    ports:
      - "8080:80"
volumes:
  dbdata:
EOF
docker compose up -d 2>/dev/null || docker-compose up -d

apt-get install -y apache2 mariadb-server php8.4 php8.4-mysqlnd apache2-mod_ssl
systemctl enable --now mariadb || systemctl enable --now mysqld
systemctl restart mariadb || systemctl restart mysqld
systemctl enable --now httpd2 || systemctl enable --now apache2
systemctl restart httpd2 || systemctl restart apache2

mysql <<'SQL'
CREATE DATABASE IF NOT EXISTS webdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'web'@'localhost' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON webdb.* TO 'web'@'localhost';
FLUSH PRIVILEGES;
SQL
if [ -f /mnt/additional/web/dump.sql ]; then
  mariadb webdb < /mnt/additional/web/dump.sql
fi

DOCROOT=/var/www/html
[ -d /var/www/default/html ] && DOCROOT=/var/www/default/html
mkdir -p "$DOCROOT"
if [ -f /mnt/additional/web/index.php ]; then
  cp -av /mnt/additional/web/index.php "$DOCROOT"/
fi
if [ -d /mnt/additional/web/images ]; then
  cp -av /mnt/additional/web/images "$DOCROOT"/ 2>/dev/null || true
fi
chown -R apache2:apache2 "$DOCROOT" 2>/dev/null || chown -R apache:apache "$DOCROOT" 2>/dev/null || true
find "$DOCROOT" -type d -exec chmod 755 {} \;
find "$DOCROOT" -type f -exec chmod 644 {} \;
sed -i 's/$username = "user";/$username = "web";/' "$DOCROOT/index.php" 2>/dev/null
sed -i 's/$password = "password";/$password = "P@ssw0rd";/' "$DOCROOT/index.php" 2>/dev/null
sed -i 's/$dbname = "db";/$dbname = "webdb";/' "$DOCROOT/index.php" 2>/dev/null
systemctl restart httpd2 || systemctl restart apache2

# RAID5 (используем /dev/vdb, /dev/vdc, /dev/vdd)
if [ -b /dev/vdb ] && [ -b /dev/vdc ] && [ -b /dev/vdd ]; then
  apt-get install -y mdadm e2fsprogs
  mdadm --create /dev/md0 --level=5 --raid-devices=3 /dev/vdb /dev/vdc /dev/vdd --run
  mkfs.ext4 -L RAID5 /dev/md0
  mkdir -p /srv/storage
  UUID=$(blkid -s UUID -o value /dev/md0)
  grep -q '/srv/storage' /etc/fstab || echo "UUID=$UUID /srv/storage ext4 defaults 0 2" >> /etc/fstab
  mount -a
  mdadm --detail --scan > /etc/mdadm.conf
  mkdir -p /srv/storage/instructions /srv/storage/share /srv/storage/secret
  chmod 0775 /srv/storage/instructions
  chmod 0777 /srv/storage/share
  chmod 0770 /srv/storage/secret
  echo "Readme instructions" > /srv/storage/instructions/readme.txt
  echo "Public share" > /srv/storage/share/readme.txt
  echo "Secret admins only" > /srv/storage/secret/readme.txt
else
  mkdir -p /srv/storage/instructions /srv/storage/share /srv/storage/secret
  chmod 0775 /srv/storage/instructions
  chmod 0777 /srv/storage/share
  chmod 0770 /srv/storage/secret
  echo "Readme instructions" > /srv/storage/instructions/readme.txt
  echo "Public share" > /srv/storage/share/readme.txt
  echo "Secret admins only" > /srv/storage/secret/readme.txt
fi

apt-get install -y samba samba-client krb5-workstation samba-winbind bind-utils
cat > /etc/net/ifaces/$IFACE/resolv.conf <<EOF
search lab.local
nameserver 172.16.0.10
EOF
systemctl restart network
cat > /etc/krb5.conf <<'EOF'
[libdefaults]
  default_realm = LAB.LOCAL
  dns_lookup_realm = false
  dns_lookup_kdc = true
EOF
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
   template shell = /bin/bash
   template homedir = /home/%D/%U
   log file = /var/log/samba/%m.log
   max log size = 1000
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
net ads join -U Administrator%P@ssw0rd || true
systemctl enable --now winbind
systemctl enable --now smb nmb || systemctl enable --now samba
systemctl restart winbind
systemctl restart smb nmb || systemctl restart samba

# HTTPS (если сертификаты уже скопированы с dc)
if [ -f /tmp/srv.lab.local.crt ] && [ -f /tmp/srv.lab.local.key ]; then
  mkdir -p /etc/pki/tls/certs /etc/pki/tls/private
  mv /tmp/srv.lab.local.crt /etc/pki/tls/certs/
  mv /tmp/srv.lab.local.key /etc/pki/tls/private/
  mv /tmp/lab-root-ca.crt /etc/pki/tls/certs/
  chmod 600 /etc/pki/tls/private/srv.lab.local.key
  a2enmod ssl proxy proxy_http
  systemctl restart httpd2
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
  grep -q 'Listen 443' /etc/httpd2/conf/httpd2.conf || echo "Listen 443" >> /etc/httpd2/conf/httpd2.conf
  systemctl restart httpd2
else
  echo "SSL certificates not found, HTTPS not configured"
fi

echo "=== srv done ==="
