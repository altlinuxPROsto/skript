#!/bin/bash
# ========== isp.lab.local ==========
# Замените MAC-адреса на реальные (узнайте через ip link на dc и srv)
DC_MAC="bc:24:11:2d:28:e0"
SRV_MAC="bc:24:11:6e:ec:2f"
# ------------------------------------
set -e
# Функция для безопасного выполнения команд
safe() { "$@" || true; }

hostnamectl set-hostname isp.lab.local
WAN_IF=ens18
LAN_IF=ens19
mkdir -p /etc/net/ifaces/$WAN_IF /etc/net/ifaces/$LAN_IF

cat > /etc/net/ifaces/$WAN_IF/options <<EOF
TYPE=eth
BOOTPROTO=dhcp
ONBOOT=yes
NM_CONTROLLED=no
DISABLED=no
EOF

cat > /etc/net/ifaces/$LAN_IF/options <<EOF
TYPE=eth
BOOTPROTO=static
ONBOOT=yes
NM_CONTROLLED=no
DISABLED=no
EOF

echo "172.16.0.1/24" > /etc/net/ifaces/$LAN_IF/ipv4address

cat > /etc/hosts <<EOF
127.0.0.1 localhost
172.16.0.1 isp.lab.local isp
172.16.0.10 dc.lab.local dc
172.16.0.20 srv.lab.local srv
EOF

systemctl restart network
safe ping -c 3 8.8.8.8

sed -i 's/^#\?net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/net/sysctl.conf
grep -q '^net.ipv4.ip_forward' /etc/net/sysctl.conf || echo 'net.ipv4.ip_forward = 1' >> /etc/net/sysctl.conf
sysctl -p /etc/net/sysctl.conf

apt-get update

# Установка Python 3 для Ansible с запасными вариантами
if ! command -v python3 >/dev/null 2>&1; then
    apt-get install -y python3
fi
apt-get install -y python3-module-setuptools 2>/dev/null || apt-get install -y python3-setuptools 2>/dev/null || true
[ -f /usr/bin/python ] || ln -sf /usr/bin/python3 /usr/bin/python
python3 --version || echo "Python3 installed but setuptools may be missing"

apt-get install -y iptables

iptables -F
iptables -t nat -F
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -t nat -A POSTROUTING -s 172.16.0.0/24 -o "$WAN_IF" -j MASQUERADE
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -j ACCEPT
iptables -A FORWARD -i "$WAN_IF" -o "$LAN_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables
safe systemctl restart iptables

apt-get install -y dhcp-server
cat > /etc/dhcp/dhcpd.conf <<EOF
authoritative;
default-lease-time 600;
max-lease-time 7200;
option domain-name "lab.local";
option domain-name-servers 172.16.0.10, 8.8.8.8;
subnet 172.16.0.0 netmask 255.255.255.0 {
  option routers 172.16.0.1;
  option subnet-mask 255.255.255.0;
  option broadcast-address 172.16.0.255;
  option domain-name "lab.local";
  option domain-search "lab.local";
  option ntp-servers 172.16.0.1;
  range 172.16.0.200 172.16.0.250;
  host dc {
    hardware ethernet $DC_MAC;
    fixed-address 172.16.0.10;
    option host-name "dc";
  }
  host srv {
    hardware ethernet $SRV_MAC;
    fixed-address 172.16.0.20;
    option host-name "srv";
  }
}
EOF
safe dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf
echo "DHCPDARGS=\"$LAN_IF\"" > /etc/sysconfig/dhcpd
systemctl enable --now dhcpd
safe systemctl restart dhcpd

apt-get install -y chrony
cat > /etc/chrony.conf <<'EOF'
pool pool.ntp.org iburst
local stratum 5
allow 172.16.0.0/24
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony
safe systemctl restart chronyd 2>/dev/null || safe systemctl restart chrony

# Пользователи, sudo, SSH
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
safe visudo -c

echo "Authorized access only" > /etc/issue.net
SSHD_CONFIG=/etc/openssh/sshd_config
[ -f /etc/ssh/sshd_config ] && SSHD_CONFIG=/etc/ssh/sshd_config
cp "$SSHD_CONFIG" "$SSHD_CONFIG.bak.$(date +%F-%H%M%S)"
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

# Расширенный firewall
iptables -F
iptables -t nat -F
iptables -X
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i "$LAN_IF" -s 172.16.0.0/24 -p tcp --dport 2222 -j ACCEPT
iptables -A INPUT -i "$LAN_IF" -s 172.16.0.0/24 -p udp --dport 67 -j ACCEPT
iptables -A INPUT -i "$LAN_IF" -s 172.16.0.0/24 -p udp --dport 123 -j ACCEPT
iptables -A INPUT -i "$LAN_IF" -s 172.16.0.0/24 -p icmp -j ACCEPT
iptables -t nat -A POSTROUTING -s 172.16.0.0/24 -o "$WAN_IF" -j MASQUERADE
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s 172.16.0.0/24 -p tcp -m multiport --dports 80,443 -j ACCEPT
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s 172.16.0.0/24 -p udp --dport 53 -j ACCEPT
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s 172.16.0.0/24 -p tcp --dport 53 -j ACCEPT
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s 172.16.0.0/24 -p udp --dport 123 -j ACCEPT
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s 172.16.0.0/24 -p icmp -j ACCEPT
iptables -A FORWARD -i "$WAN_IF" -o "$LAN_IF" -d 172.16.0.0/24 -j DROP
iptables-save > /etc/sysconfig/iptables
safe systemctl restart iptables

echo "=== isp done ==="
