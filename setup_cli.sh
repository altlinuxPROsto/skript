#!/bin/bash
# ========== cli.lab.local ==========
set -e

hostnamectl set-hostname cli.lab.local
IFACE=ens18
mkdir -p /etc/net/ifaces/$IFACE
cat /etc/net/ifaces/ens18/options
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

apt-get install -y ansible openssh-clients bind-utils samba-client cifs-utils
mkdir -p /etc/ansible
cat > /etc/ansible/inventory.ini <<'EOF'
[servers]
isp ansible_host=172.16.0.1
dc  ansible_host=172.16.0.10
srv ansible_host=172.16.0.20

[servers:vars]
ansible_user=admin
ansible_port=2222
ansible_become=true
ansible_become_method=sudo
ansible_python_interpreter=/usr/bin/python3
EOF
chown -R admin:admin /etc/ansible

apt-get install -y task-auth-ad-sssd krb5-workstation
cat > /etc/net/ifaces/$IFACE/resolv.conf <<EOF
search lab.local
nameserver 172.16.0.10
EOF
systemctl restart network

realm discover lab.local
echo "P@ssw0rd" | realm join -U Administrator lab.local

grep -q '^passwd:.*sss' /etc/nsswitch.conf || sed -i '/^passwd:/ s/$/ sss/' /etc/nsswitch.conf
grep -q '^group:.*sss' /etc/nsswitch.conf || sed -i '/^group:/ s/$/ sss/' /etc/nsswitch.conf
grep -q '^shadow:.*sss' /etc/nsswitch.conf || sed -i '/^shadow:/ s/$/ sss/' /etc/nsswitch.conf
systemctl restart sssd
sss_cache -E

realm list
echo "P@ssw0rd" | kinit Administrator@LAB.LOCAL
klist
id ivanov@lab.local

mkdir -p /mnt/instructions /mnt/share /mnt/secret
cat > /root/.smb-ivanov <<'EOF'
username=ivanov
password=P@ssw0rd
domain=LAB
EOF
chmod 600 /root/.smb-ivanov
mount -t cifs //srv.lab.local/instructions /mnt/instructions -o credentials=/root/.smb-ivanov,vers=3.0
mount -t cifs //srv.lab.local/share /mnt/share -o credentials=/root/.smb-ivanov,vers=3.0
mount -t cifs //srv.lab.local/secret /mnt/secret -o credentials=/root/.smb-ivanov,vers=3.0
df -h | grep mnt

sshpass -p 'P@ssw0rd' scp -o StrictHostKeyChecking=no -P 2222 admin@172.16.0.10:/root/ca/certs/lab-root-ca.crt /tmp/lab-root-ca.crt
if [ -d /etc/pki/ca-trust/source/anchors ]; then
  cp /tmp/lab-root-ca.crt /etc/pki/ca-trust/source/anchors/lab-root-ca.crt
  update-ca-trust
elif [ -d /usr/local/share/ca-certificates ]; then
  cp /tmp/lab-root-ca.crt /usr/local/share/ca-certificates/lab-root-ca.crt
  update-ca-certificates
else
  mkdir -p /etc/ssl/certs
  cp /tmp/lab-root-ca.crt /etc/ssl/certs/lab-root-ca.crt
fi
openssl verify -CAfile /tmp/lab-root-ca.crt /tmp/lab-root-ca.crt

# Настройка SSH ключей от admin
su - admin <<'ADMIN_CMDS'
mkdir -p ~/.ssh
chmod 700 ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
sshpass -p 'P@ssw0rd' ssh-copy-id -o StrictHostKeyChecking=no -p 2222 admin@172.16.0.1
sshpass -p 'P@ssw0rd' ssh-copy-id -o StrictHostKeyChecking=no -p 2222 admin@172.16.0.10
sshpass -p 'P@ssw0rd' ssh-copy-id -o StrictHostKeyChecking=no -p 2222 admin@172.16.0.20
cat > ~/.ssh/config <<'EOF'
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
ssh isp hostname -f
ssh dc hostname -f
ssh srv hostname -f
ADMIN_CMDS

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
ansible all -i /etc/ansible/inventory.ini -m ping
ansible-playbook -i /etc/ansible/inventory.ini /etc/ansible/install_htop.yml

echo "=== cli done ==="
