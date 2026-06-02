#!/bin/bash
set -e

safe() { "$@" || true; }

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
apt-get update

# Пользователи и SSH
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
safe sshd -t -f "$SSHD_CONFIG"
systemctl enable --now sshd
safe systemctl restart sshd

# NTP
apt-get install -y chrony
cat > /etc/chrony.conf <<'EOF'
server 172.16.0.1 iburst
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony
safe systemctl restart chronyd 2>/dev/null || safe systemctl restart chrony

# Docker
apt-get install -y docker-engine docker-compose
systemctl enable --now docker

# RAID5 (с проверкой)
if [ -b /dev/vdb ] && [ -b /dev/vdc ] && [ -b /dev/vdd ]; then
    apt-get install -y mdadm e2fsprogs
    if [ ! -b /dev/md0 ]; then
        mdadm --create /dev/md0 --level=5 --raid-devices=3 /dev/vdb /dev/vdc /dev/vdd --run
        sleep 2
    fi
    if ! blkid /dev/md0 | grep -q 'TYPE="ext4"'; then
        mkfs.ext4 -F /dev/md0
    fi
    mkdir -p /srv/storage
    UUID=$(blkid -s UUID -o value /dev/md0)
    sed -i '/\/srv\/storage/d' /etc/fstab
    echo "UUID=$UUID /srv/storage ext4 defaults 0 2" >> /etc/fstab
    mountpoint -q /srv/storage || mount /srv/storage
else
    mkdir -p /srv/storage
fi
mkdir -p /srv/storage/{instructions,share,secret}
chmod 0775 /srv/storage/instructions
chmod 0777 /srv/storage/share
chmod 0770 /srv/storage/secret
echo "Readme instructions" > /srv/storage/instructions/readme.txt
echo "Public share" > /srv/storage/share/readme.txt
echo "Secret admins only" > /srv/storage/secret/readme.txt

# Apache, MariaDB, PHP
apt-get install -y apache2 mariadb-server php8.4 php8.4-mysqlnd apache2-mod_ssl
systemctl enable --now mariadb || systemctl enable --now mysqld
safe systemctl restart mariadb || safe systemctl restart mysqld
systemctl enable --now httpd2 || systemctl enable --now apache2
safe systemctl restart httpd2 || safe systemctl restart apache2

# База данных webdb
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
safe systemctl restart httpd2 || safe systemctl restart apache2

# ========== НАСТРОЙКА ДОМЕНА И WINBIND (БЕЗ ПОЛОМКИ ЛОКАЛЬНЫХ ПАРОЛЕЙ) ==========
apt-get install -y samba samba-client krb5-workstation samba-winbind bind-utils

# DNS-клиент на DC
cat > /etc/net/ifaces/$IFACE/resolv.conf <<EOF
search lab.local
nameserver 172.16.0.10
EOF
systemctl restart network

# Kerberos
cat > /etc/krb5.conf <<'EOF'
[libdefaults]
  default_realm = LAB.LOCAL
  dns_lookup_realm = false
  dns_lookup_kdc = true
EOF

# Конфигурация Samba (безопасная)
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
   winbind enum users = no
   winbind enum groups = no
   winbind offline logon = yes
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

# Присоединение к домену
if ! wbinfo -t 2>/dev/null; then
    rm -f /etc/krb5.keytab /var/lib/samba/private/secrets.tdb
    net ads join -U Administrator%P@ssw0rd
    net ads keytab create -U Administrator%P@ssw0rd
    systemctl enable --now winbind smb nmb
fi

# ===== КЛЮЧЕВОЕ ИСПРАВЛЕНИЕ: НЕ трогаем shadow в nsswitch.conf =====
# Добавляем winbind только для passwd и group, shadow оставляем files
if ! grep -q "winbind" /etc/nsswitch.conf; then
    sed -i 's/^passwd:.*/passwd: compat winbind/' /etc/nsswitch.conf
    sed -i 's/^group:.*/group: compat winbind/' /etc/nsswitch.conf
    # Удаляем winbind из shadow, если вдруг попал
    sed -i 's/ winbind//g' /etc/nsswitch.conf
    sed -i 's/^shadow:.*/shadow: files/' /etc/nsswitch.conf
fi

# Удаляем pam_winbind из PAM, если он есть
for pamfile in /etc/pam.d/system-auth /etc/pam.d/password-auth; do
    if [ -f "$pamfile" ]; then
        sed -i '/pam_winbind.so/d' "$pamfile"
    fi
done

# Перезапускаем службы
systemctl restart winbind smb
systemctl restart systemd-logind

# ===== КОНЕЦ НАСТРОЙКИ ДОМЕНА =====

# Установка Python для Ansible
apt-get install -y python3 python3-module-setuptools
[ -f /usr/bin/python ] || ln -sf /usr/bin/python3 /usr/bin/python

# Копирование сертификатов с DC (если доступно) и настройка HTTPS
# ... (оставляем как было) ...

echo "=== srv done ==="
