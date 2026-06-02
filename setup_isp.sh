#!/bin/bash
set -e

CONFIG_FILE="/etc/.isp_setup_vars"
INTERACTIVE=false

# Функция для запроса MAC-адресов
ask_mac() {
    local hostname=$1
    local default_mac=$2
    read -p "Введите MAC-адрес для $hostname (например, $default_mac): " mac
    echo "${mac:-$default_mac}"
}

# Загружаем сохранённые переменные или запрашиваем
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    INTERACTIVE=true
    echo "=== Первый запуск. Пожалуйста, введите MAC-адреса для статических привязок DHCP ==="
    DC_MAC=$(ask_mac "dc" "bc:24:11:2d:28:e0")
    SRV_MAC=$(ask_mac "srv" "bc:24:11:6e:ec:2f")
    WAN_IF=${WAN_IF:-ens18}
    LAN_IF=${LAN_IF:-ens19}
    # Сохраняем
    cat > "$CONFIG_FILE" <<EOF
DC_MAC='$DC_MAC'
SRV_MAC='$SRV_MAC'
WAN_IF='$WAN_IF'
LAN_IF='$LAN_IF'
EOF
fi

# Функция для проверки и выполнения команд
safe() { "$@" || true; }

# Установка hostname (если не установлен)
if [ "$(hostname)" != "isp.lab.local" ]; then
    hostnamectl set-hostname isp.lab.local
fi

# Настройка интерфейсов (только если не настроены)
if [ ! -f /etc/net/ifaces/$LAN_IF/ipv4address ]; then
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
    systemctl restart network
fi

# IP-форвардинг
if [ "$(sysctl -n net.ipv4.ip_forward)" -ne 1 ]; then
    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" >> /etc/net/sysctl.conf
fi

# Установка пакетов (повторно не повредит)
apt-get update
apt-get install -y dhcp-server iptables chrony sudo openssh-server htop procps

# Настройка DHCP (только если конфиг не содержит текущих MAC)
if ! grep -q "hardware ethernet $DC_MAC" /etc/dhcp/dhcpd.conf; then
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
    echo "DHCPDARGS=\"$LAN_IF\"" > /etc/sysconfig/dhcpd
    systemctl enable --now dhcpd
else
    echo "DHCP уже настроен, пропускаем."
fi

# Межсетевой экран (проверяем наличие правила MASQUERADE)
if ! iptables -t nat -C POSTROUTING -s 172.16.0.0/24 -o "$WAN_IF" -j MASQUERADE 2>/dev/null; then
    iptables -F
    iptables -t nat -F
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
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
    systemctl enable --now iptables
else
    echo "Правила iptables уже настроены, пропускаем."
fi

# NTP-сервер (chrony)
if ! grep -q "allow 172.16.0.0/24" /etc/chrony.conf; then
    cat > /etc/chrony.conf <<EOF
pool pool.ntp.org iburst
local stratum 5
allow 172.16.0.0/24
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
    systemctl enable --now chronyd
else
    echo "NTP уже настроен, пропускаем."
fi

# Локальные пользователи и sudo (создаём, если нет)
for u in admin monitor; do
    if ! id "$u" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$u"
        echo "$u:P@ssw0rd" | chpasswd
    fi
done
cat > /etc/sudoers.d/lab-users <<'EOF'
admin ALL=(ALL) NOPASSWD: ALL
Cmnd_Alias MONITORING = /usr/bin/htop, /bin/htop, /usr/bin/df, /bin/df, /usr/bin/free, /bin/free, /usr/bin/journalctl, /bin/journalctl, /usr/bin/systemctl status *, /bin/systemctl status *
monitor ALL=(root) NOPASSWD: MONITORING
EOF
chmod 0440 /etc/sudoers.d/lab-users

# SSH (порт 2222, баннер)
echo "Authorized access only" > /etc/issue.net
SSHD_CONFIG=/etc/openssh/sshd_config
if [ -f "$SSHD_CONFIG" ]; then
    if ! grep -q "^Port 2222" "$SSHD_CONFIG"; then
        sed -i '/^Port/d' "$SSHD_CONFIG"
        echo "Port 2222" >> "$SSHD_CONFIG"
        echo "Banner /etc/issue.net" >> "$SSHD_CONFIG"
        echo "MaxAuthTries 2" >> "$SSHD_CONFIG"
        echo "PermitRootLogin no" >> "$SSHD_CONFIG"
        echo "AllowUsers admin monitor" >> "$SSHD_CONFIG"
        systemctl restart sshd
    fi
fi

echo "=== ISP setup finished ==="
