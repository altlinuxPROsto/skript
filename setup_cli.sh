#!/bin/bash
set -e

# Hostname и сеть (DHCP)
hostnamectl set-hostname cli.lab.local
IFACE=ens18
mkdir -p /etc/net/ifaces/$IFACE
cat > /etc/net/ifaces/$IFACE/options <<EOF
TYPE=eth
BOOTPROTO=dhcp
ONBOOT=yes
NM_CONTROLLED=no
DISABLED=no
EOF
# DNS-клиент сначала временно, потом через DHCP
cat > /etc/net/ifaces/$IFACE/resolv.conf <<EOF
search lab.local
nameserver 8.8.8.8
EOF
systemctl restart network
apt-get update

# Установка пакетов
apt-get install -y sudo openssh-server htop procps ansible openssh-clients bind-utils samba-client cifs-utils task-auth-ad-sssd krb5-workstation sshpass chrony

# Локальные пользователи и sudo
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

# SSH (порт 2222)
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
cat > /etc/chrony.conf <<EOF
server 172.16.0.1 iburst
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
systemctl enable --now chronyd

# Ввод в домен (только если не введены)
if ! realm list | grep -q "lab.local"; then
    echo "P@ssw0rd" | realm join -U Administrator lab.local
fi

# Настройка DNS на DC
cat > /etc/net/ifaces/$IFACE/resolv.conf <<EOF
search lab.local
nameserver 172.16.0.10
EOF
systemctl restart network

# Ansible инвентарь (создаём, если нет)
INVENTORY="/etc/ansible/inventory.ini"
if [ ! -f "$INVENTORY" ]; then
    mkdir -p /etc/ansible
    cat > "$INVENTORY" <<EOF
[servers]
dc ansible_host=172.16.0.10 ansible_user=admin ansible_ssh_port=2222
srv ansible_host=172.16.0.20 ansible_user=admin ansible_ssh_port=2222
isp ansible_host=172.16.0.1 ansible_user=admin ansible_ssh_port=2222

[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
EOF
fi

# SSH-ключи для admin (генерируем, если нет)
su - admin <<'ADMIN_SCRIPT'
if [ ! -f ~/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -q <<< y >/dev/null 2>&1
fi
for ip in 172.16.0.1 172.16.0.10 172.16.0.20; do
    ssh-copy-id -o StrictHostKeyChecking=no -p 2222 admin@$ip 2>/dev/null || true
done
cat > ~/.ssh/config <<EOF
Host isp
  HostName 172.16.0.1
  User admin
  Port 2222
  IdentityFile ~/.ssh/id_ed25519
Host dc
  HostName 172.16.0.10
  User admin
  Port 2222
  IdentityFile ~/.ssh/id_ed25519
Host srv
  HostName 172.16.0.20
  User admin
  Port 2222
  IdentityFile ~/.ssh/id_ed25519
EOF
chmod 600 ~/.ssh/config
ADMIN_SCRIPT

# Ansible плейбук для установки htop (если ещё не запускали)
if ! ansible all -m ping -i "$INVENTORY" 2>/dev/null | grep -q "pong"; then
    cat > /etc/ansible/install_htop.yml <<'EOF'
---
- name: Install htop on all servers
  hosts: servers
  become: true
  tasks:
    - name: Install htop with apt-get
      command: apt-get install -y htop
      changed_when: false
EOF
    ansible-playbook -i "$INVENTORY" /etc/ansible/install_htop.yml
fi

# Монтирование CIFS-шар (если не смонтированы)
# Получаем UID/GID для ivanov через winbind
if getent passwd ivanov >/dev/null 2>&1; then
    IVANOV_UID=$(id -u ivanov)
    IVANOV_GID=$(id -g ivanov)
    ADMINS_GID=$(getent group "admins" | cut -d: -f3)
else
    IVANOV_UID=11105
    IVANOV_GID=10513
    ADMINS_GID=11103
fi
mkdir -p /mnt/instructions /mnt/share /mnt/secret
mount -t cifs //172.16.0.20/instructions /mnt/instructions -o username=ivanov,password=P@ssw0rd,domain=LAB.LOCAL,vers=3.0,uid=$IVANOV_UID,gid=$IVANOV_GID 2>/dev/null || true
mount -t cifs //172.16.0.20/share /mnt/share -o username=ivanov,password=P@ssw0rd,domain=LAB.LOCAL,vers=3.0,uid=$IVANOV_UID,gid=$IVANOV_GID 2>/dev/null || true
mount -t cifs //172.16.0.20/secret /mnt/secret -o username=ivanov,password=P@ssw0rd,domain=LAB.LOCAL,vers=3.0,uid=$IVANOV_UID,gid=$ADMINS_GID 2>/dev/null || true

# Корневой сертификат (если доступен)
if scp -P 2222 admin@172.16.0.10:/root/ca/certs/lab-root-ca.crt /tmp/ 2>/dev/null; then
    if [ -d /etc/pki/ca-trust/source/anchors ]; then
        cp /tmp/lab-root-ca.crt /etc/pki/ca-trust/source/anchors/
        update-ca-trust
    elif [ -d /usr/local/share/ca-certificates ]; then
        cp /tmp/lab-root-ca.crt /usr/local/share/ca-certificates/
        update-ca-certificates
    fi
fi

echo "=== CLI setup finished ==="
