#!/bin/bash
# ========== dc.lab.local ==========

hostnamectl set-hostname dc.lab.local
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
apt-get install -y task-samba-dc samba-client bind-utils krb5-workstation sshpass

systemctl disable --now bind named krb5kdc nmb smb slapd 2>/dev/null || true
systemctl disable --now samba 2>/dev/null || true
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

cat > /etc/net/ifaces/$IFACE/resolv.conf <<EOF
search lab.local
nameserver 127.0.0.1
EOF

systemctl restart network
systemctl enable --now samba

samba-tool domain info 127.0.0.1
host -t SRV _kerberos._udp.lab.local.
host -t SRV _ldap._tcp.lab.local.
echo "P@ssw0rd" | kinit Administrator@LAB.LOCAL
klist

# OU и пользователи
samba-tool ou create "OU=admins,DC=lab,DC=local"
samba-tool ou create "OU=others,DC=lab,DC=local"
samba-tool ou create "OU=managers,DC=lab,DC=local"
samba-tool group add admins
samba-tool group add managers
samba-tool user create ivanov 'P@ssw0rd' --userou='OU=admins'
samba-tool user create petrov 'P@ssw0rd' --userou='OU=managers'
samba-tool user create sidorov 'P@ssw0rd' --userou='OU=managers'
samba-tool user setexpiry ivanov --noexpiry
samba-tool user setexpiry petrov --noexpiry
samba-tool user setexpiry sidorov --noexpiry
samba-tool group addmembers admins ivanov
samba-tool group addmembers managers petrov,sidorov

# DNS записи
samba-tool dns add 127.0.0.1 lab.local dc A 172.16.0.10 -U 'Administrator%P@ssw0rd' || true
samba-tool dns add 127.0.0.1 lab.local srv A 172.16.0.20 -U 'Administrator%P@ssw0rd' || true
samba-tool dns add 127.0.0.1 lab.local moodle CNAME dc.lab.local. -U 'Administrator%P@ssw0rd'
samba-tool dns add 127.0.0.1 lab.local web CNAME srv.lab.local. -U 'Administrator%P@ssw0rd'
samba-tool dns add 127.0.0.1 lab.local docker CNAME srv.lab.local. -U 'Administrator%P@ssw0rd'
samba-tool dns zonecreate 127.0.0.1 0.16.172.in-addr.arpa -U 'Administrator%P@ssw0rd' || true
samba-tool dns add 127.0.0.1 0.16.172.in-addr.arpa 10 PTR dc.lab.local. -U 'Administrator%P@ssw0rd' || true
samba-tool dns add 127.0.0.1 0.16.172.in-addr.arpa 20 PTR srv.lab.local. -U 'Administrator%P@ssw0rd' || true
samba-tool dns add 127.0.0.1 0.16.172.in-addr.arpa 1 PTR isp.lab.local. -U 'Administrator%P@ssw0rd' || true

# GPO
samba-tool gpo create "LAB Base Policy" -U 'Administrator%P@ssw0rd'
GPO_GUID=$(samba-tool gpo listall -U 'Administrator%P@ssw0rd' | grep -i "LAB Base Policy" | awk '{print $3}')
samba-tool gpo setlink "DC=lab,DC=local" "$GPO_GUID" -U 'Administrator%P@ssw0rd'

# Пользователи и sudo на dc
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

# NTP клиент
apt-get install -y chrony
cat > /etc/chrony.conf <<'EOF'
server 172.16.0.1 iburst
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony
systemctl restart chronyd 2>/dev/null || systemctl restart chrony

# CA и HTTPS для moodle, сертификат для srv
apt-get install -y openssl apache2 apache2-mod_ssl
a2enmod ssl rewrite 2>/dev/null || true
mkdir -p /root/ca/{certs,csr,newcerts,private}
chmod 700 /root/ca/private
touch /root/ca/index.txt
echo 1000 > /root/ca/serial
openssl genrsa -out /root/ca/private/lab-root-ca.key 4096
openssl req -x509 -new -nodes -key /root/ca/private/lab-root-ca.key -sha256 -days 365 -out /root/ca/certs/lab-root-ca.crt -subj "/C=RU/ST=LAB/L=LAB/O=LAB.LOCAL/OU=IT/CN=LAB.LOCAL Root CA"

# Сертификат для dc
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
openssl req -new -nodes -out /root/ca/csr/dc.lab.local.csr -newkey rsa:2048 -keyout /root/ca/private/dc.lab.local.key -config /root/ca/dc-san.cnf
openssl x509 -req -in /root/ca/csr/dc.lab.local.csr -CA /root/ca/certs/lab-root-ca.crt -CAkey /root/ca/private/lab-root-ca.key -CAcreateserial -out /root/ca/certs/dc.lab.local.crt -days 365 -sha256 -extensions req_ext -extfile /root/ca/dc-san.cnf

# Сертификат для srv
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
openssl req -new -nodes -out /root/ca/csr/srv.lab.local.csr -newkey rsa:2048 -keyout /root/ca/private/srv.lab.local.key -config /root/ca/srv-san.cnf
openssl x509 -req -in /root/ca/csr/srv.lab.local.csr -CA /root/ca/certs/lab-root-ca.crt -CAkey /root/ca/private/lab-root-ca.key -CAcreateserial -out /root/ca/certs/srv.lab.local.crt -days 365 -sha256 -extensions req_ext -extfile /root/ca/srv-san.cnf

# HTTPS moodle на dc
mkdir -p /var/www/moodle
echo "moodle.lab.local HTTPS OK" > /var/www/moodle/index.html
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
    <Directory "/var/www/moodle">
        Require all granted
    </Directory>
</VirtualHost>
EOF
ln -sf /etc/httpd2/conf/sites-available/moodle-https.conf /etc/httpd2/conf/sites-enabled/
grep -q 'Listen 443' /etc/httpd2/conf/httpd2.conf || echo "Listen 443" >> /etc/httpd2/conf/httpd2.conf
systemctl enable --now httpd2 || systemctl enable --now apache2
systemctl restart httpd2 || systemctl restart apache2

# Копирование сертификатов на srv (ждём, пока srv поднимется, но если нет — пропускаем)
if ping -c1 -W2 172.16.0.20 >/dev/null 2>&1; then
    sshpass -p 'P@ssw0rd' scp -o StrictHostKeyChecking=no -P 2222 /root/ca/certs/srv.lab.local.crt admin@172.16.0.20:/tmp/ 2>/dev/null || true
    sshpass -p 'P@ssw0rd' scp -o StrictHostKeyChecking=no -P 2222 /root/ca/private/srv.lab.local.key admin@172.16.0.20:/tmp/ 2>/dev/null || true
    sshpass -p 'P@ssw0rd' scp -o StrictHostKeyChecking=no -P 2222 /root/ca/certs/lab-root-ca.crt admin@172.16.0.20:/tmp/ 2>/dev/null || true
else
    echo "srv not reachable, copy certificates manually later"
fi

echo "=== dc done ==="
