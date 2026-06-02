#!/bin/bash
set -e

# Проверяем, не настроен ли уже домен
if [ ! -f /var/lib/samba/private/sam.ldb ]; then
    echo "=== Выполняем provision домена ==="
    apt-get update
    apt-get install -y task-samba-dc samba-client bind-utils krb5-workstation sshpass
    systemctl disable --now bind named krb5kdc nmb smb slapd 2>/dev/null || true
    rm -f /etc/samba/smb.conf
    rm -rf /var/lib/samba /var/cache/samba
    mkdir -p /var/lib/samba/sysvol
    samba-tool domain provision \
        --use-rfc2307 \
        --realm=LAB.LOCAL \
        --domain=LAB \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass='P@ssw0rd' \
        --option='dns forwarder = 8.8.8.8'
    cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
    systemctl enable --now samba
else
    echo "Домен уже существует, пропускаем provision."
fi

# Настройка DNS-сервера для самого себя
echo "nameserver 127.0.0.1" > /etc/net/ifaces/ens18/resolv.conf
systemctl restart network

# Функция для безопасного добавления DNS-записей
add_dns() {
    local zone=$1 name=$2 type=$3 data=$4
    if ! samba-tool dns query 127.0.0.1 "$zone" "$name" "$type" -U Administrator%P@ssw0rd 2>/dev/null | grep -q "$data"; then
        samba-tool dns add 127.0.0.1 "$zone" "$name" "$type" "$data" -U Administrator%P@ssw0rd
    else
        echo "Запись $name $type уже существует, пропускаем."
    fi
}

# Создаём зоны и записи
add_dns lab.local dc A 172.16.0.10
add_dns lab.local srv A 172.16.0.20
add_dns lab.local moodle CNAME dc.lab.local.
add_dns lab.local web CNAME srv.lab.local.
add_dns lab.local docker CNAME srv.lab.local.
if ! samba-tool dns zoneinfo 127.0.0.1 0.16.172.in-addr.arpa -U Administrator%P@ssw0rd 2>/dev/null; then
    samba-tool dns zonecreate 127.0.0.1 0.16.172.in-addr.arpa -U Administrator%P@ssw0rd
fi
add_dns 0.16.172.in-addr.arpa 10 PTR dc.lab.local.
add_dns 0.16.172.in-addr.arpa 20 PTR srv.lab.local.
add_dns 0.16.172.in-addr.arpa 1 PTR isp.lab.local.

# OU, группы, пользователи (с проверкой)
create_ou() {
    if ! samba-tool ou list -U Administrator%P@ssw0rd | grep -q "OU=$1"; then
        samba-tool ou create "OU=$1,DC=lab,DC=local"
    fi
}
create_group() {
    if ! samba-tool group list -U Administrator%P@ssw0rd | grep -q "^$1$"; then
        samba-tool group add "$1"
    fi
}
create_user() {
    if ! samba-tool user list -U Administrator%P@ssw0rd | grep -q "^$1$"; then
        samba-tool user create "$1" 'P@ssw0rd' --userou="OU=$2"
        samba-tool user setexpiry "$1" --noexpiry
    fi
}
create_ou admins; create_ou managers; create_ou others
create_group admins; create_group managers
create_user ivanov admins
create_user petrov managers
create_user sidorov managers
samba-tool group addmembers admins ivanov -U Administrator%P@ssw0rd 2>/dev/null || true
samba-tool group addmembers managers petrov,sidorov -U Administrator%P@ssw0rd 2>/dev/null || true

# GPO: создаём и привязываем
GPO_NAME="LAB Base Policy"
GUID=$(samba-tool gpo listall -U Administrator%P@ssw0rd | grep -B1 "$GPO_NAME" | head -1 | awk '{print $2}')
if [ -z "$GUID" ]; then
    echo "Создаём GPO $GPO_NAME..."
    GUID=$(samba-tool gpo create "$GPO_NAME" -U Administrator%P@ssw0rd | grep -o '{.*}')
fi
if ! samba-tool gpo getlink "DC=lab,DC=local" -U Administrator%P@ssw0rd | grep -q "$GUID"; then
    samba-tool gpo setlink "DC=lab,DC=local" "$GUID" -U Administrator%P@ssw0rd
    echo "GPO привязана к корню домена."
else
    echo "GPO уже привязана."
fi

# Локальные пользователи и SSH (как на других узлах)
apt-get install -y sudo openssh-server htop procps
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

# Центр сертификации (CA) и выпуск сертификатов
apt-get install -y openssl apache2 apache2-mod_ssl
a2enmod ssl rewrite
mkdir -p /root/ca/{certs,csr,newcerts,private}
chmod 700 /root/ca/private
touch /root/ca/index.txt
echo 1000 > /root/ca/serial
if [ ! -f /root/ca/certs/lab-root-ca.crt ]; then
    openssl genrsa -out /root/ca/private/lab-root-ca.key 4096
    openssl req -x509 -new -nodes -key /root/ca/private/lab-root-ca.key -sha256 -days 365 -out /root/ca/certs/lab-root-ca.crt -subj "/C=RU/ST=LAB/L=LAB/O=LAB.LOCAL/OU=IT/CN=LAB.LOCAL Root CA"
fi
# Сертификат для dc с SAN
cat > /root/ca/dc-san.cnf <<'EOF'
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext
[dn]
C=RU
ST=LAB
L=LAB
O=LAB.LOCAL
OU=IT
CN=dc.lab.local
[req_ext]
subjectAltName = @alt_names
[alt_names]
DNS.1 = dc.lab.local
DNS.2 = moodle.lab.local
IP.1 = 172.16.0.10
EOF
if [ ! -f /root/ca/certs/dc.lab.local.crt ]; then
    openssl req -new -nodes -out /root/ca/csr/dc.lab.local.csr -newkey rsa:2048 -keyout /root/ca/private/dc.lab.local.key -config /root/ca/dc-san.cnf
    openssl x509 -req -in /root/ca/csr/dc.lab.local.csr -CA /root/ca/certs/lab-root-ca.crt -CAkey /root/ca/private/lab-root-ca.key -CAcreateserial -out /root/ca/certs/dc.lab.local.crt -days 365 -sha256 -extensions req_ext -extfile /root/ca/dc-san.cnf
fi
# Аналогично для srv (сертификат будет скопирован позже скриптом srv)
cat > /root/ca/srv-san.cnf <<'EOF'
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext
[dn]
C=RU
ST=LAB
L=LAB
O=LAB.LOCAL
OU=IT
CN=srv.lab.local
[req_ext]
subjectAltName = @alt_names
[alt_names]
DNS.1 = srv.lab.local
DNS.2 = web.lab.local
DNS.3 = docker.lab.local
IP.1 = 172.16.0.20
EOF
if [ ! -f /root/ca/certs/srv.lab.local.crt ]; then
    openssl req -new -nodes -out /root/ca/csr/srv.lab.local.csr -newkey rsa:2048 -keyout /root/ca/private/srv.lab.local.key -config /root/ca/srv-san.cnf
    openssl x509 -req -in /root/ca/csr/srv.lab.local.csr -CA /root/ca/certs/lab-root-ca.crt -CAkey /root/ca/private/lab-root-ca.key -CAcreateserial -out /root/ca/certs/srv.lab.local.crt -days 365 -sha256 -extensions req_ext -extfile /root/ca/srv-san.cnf
fi

# Настройка HTTPS для moodle на DC
mkdir -p /var/www/moodle
echo "<h1>moodle.lab.local works via HTTPS</h1>" > /var/www/moodle/index.html
mkdir -p /etc/pki/tls/certs /etc/pki/tls/private
cp /root/ca/certs/dc.lab.local.crt /etc/pki/tls/certs/
cp /root/ca/private/dc.lab.local.key /etc/pki/tls/private/
chmod 600 /etc/pki/tls/private/dc.lab.local.key
cat > /etc/httpd2/conf/sites-available/moodle-https.conf <<'EOF'
<VirtualHost *:80>
    ServerName moodle.lab.local
    Redirect 301 / https://moodle.lab.local/
</VirtualHost>
<VirtualHost *:443>
    ServerName moodle.lab.local
    DocumentRoot /var/www/moodle
    SSLEngine on
    SSLCertificateFile /etc/pki/tls/certs/dc.lab.local.crt
    SSLCertificateKeyFile /etc/pki/tls/private/dc.lab.local.key
    <Directory /var/www/moodle>
        Require all granted
    </Directory>
</VirtualHost>
EOF
ln -sf /etc/httpd2/conf/sites-available/moodle-https.conf /etc/httpd2/conf/sites-enabled/
systemctl enable --now httpd2

# Установка Python для Ansible
apt-get install -y python3 python3-module-setuptools
ln -sf /usr/bin/python3 /usr/bin/python

echo "=== DC setup finished ==="
