# auth
cat>tmp.py<<EOF
with open('/etc/ssh/sshd_config','r') as f:
    text = f.readlines()
for idx in range(len(text)):
    line = text[idx]
    if 'PermitRootLogin yes' in line:
        text[idx] = 'PermitRootLogin no\n'
    elif '#Port ' in line or '# Port' in line or 'Port 'in line:
        text[idx] = 'Port 22000\n'
with open('/etc/ssh/sshd_config','w') as f:
    f.writelines(text)
EOF
python3 tmp.py
rm tmp.py
service ssh restart
service sshd restart

# swap
dd if=/dev/zero of=/swapswap bs=1M count=1024
chmod 0600 /swapswap
mkswap -f /swapswap
swapon /swapswap
echo "/swapswap swap swap defaults 0 0">>/etc/fstab
free -m

# update
apt update 
apt upgrade -y

# install python 3.8
sudo apt-get install build-essential libncursesw5-dev libgdbm-dev libc6-dev zlib1g-dev libsqlite3-dev tk-dev libssl-dev openssl libffi-dev libbz2-dev -y
wget https://www.python.org/ftp/python/3.10.5/Python-3.10.5.tgz
tar -zxvf Python-3.10.5.tgz
cd Python-3.10.5
./configure --enable-optimizations
make && make install
pip3 install requests uvloop aiohttp pipeit beautifulsoup4 lxml fastapi pipeit uvicorn[standard] ThreadPoolExecutorPlus
cd
rm Python-3.10.5.tgz
rm -rf Python-3.10.5

# essential
apt install ntpdate vim htop unzip supervisor fail2ban sudo git curl redis-server redis-tools -y

# ntp
apt install ntp systemd-timesyncd -y
timedatectl set-ntp true
timedatectl set-timezone Asia/Shanghai

# Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source $HOME/.cargo/env

# configure fail2ban
cat>tmp.py<<EOF
import re
with open('/etc/fail2ban/jail.conf','r') as f:
    text = f.readlines()
status = ""
for idx in range(len(text)):
    line = text[idx]
    node = re.search('\[[a-zA-Z0-9_\-]+\]\n', line)
    if node:
        status = node.group()[1:-2]
    if status == 'DEFAULT': 
        if 'bantime  = 10m' in line:
            text[idx] = 'bantime  = 48h\n'
        elif 'maxretry = 5' in line:
            text[idx] = 'maxretry = 6\n'
with open('/etc/fail2ban/jail.conf','w') as f:
    f.writelines(text)
EOF
python3 tmp.py
rm tmp.py
service fail2ban restart

# install node 16
curl -sL https://deb.nodesource.com/setup_16.x | sudo -E bash -
sudo apt-get install -y nodejs

# bbr
echo net.core.default_qdisc=fq >> /etc/sysctl.conf
echo net.ipv4.tcp_congestion_control=bbr >> /etc/sysctl.conf
sysctl -p
sysctl net.ipv4.tcp_available_congestion_control

# axel
wget https://github.com/axel-download-accelerator/axel/releases/download/v2.17.10/axel-2.17.10.tar.gz
tar -zxvf axel-2.17.10.tar.gz
cd axel-2.17.10
./configure --prefix=/usr/local/axel
make && make install
ln /usr/local/axel/bin/axel /usr/local/bin/axel
echo "alias axel='axel -n 16'" >> ~/.bashrc
source ~/.bashrc
cd
rm -rf axel-2.17.10
rm axel-2.17.10.tar.gz

# v2
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-dat-release.sh)
cat>/usr/local/etc/v2ray/config.json<<EOF
{
  "inbounds": [
    {
      "port": 30666,
      "listen":"127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "{{uuid}}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
        "path": "/m3u8"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF
cd
cat>tmp.py<<EOF
import uuid
from pipeit import *
u = uuid.uuid1()
text = Read('/usr/local/etc/v2ray/config.json').replace('{{uuid}}', f'{u}')
Write('/usr/local/etc/v2ray/config.json', text)
print('#'*2000,'\n',u,'\n','#'*2000)
EOF
python3 tmp.py
rm tmp.py
systemctl enable v2ray
systemctl start v2ray

# bt
curl -sSO https://raw.githubusercontent.com/zhucaidan/btpanel-v7.7.0/main/install/install_panel.sh && bash install_panel.sh
sed -i "s|if (bind_user == 'True') {|if (bind_user == 'REMOVED') {|g" /www/server/panel/BTPanel/static/js/index.js
rm -rf /www/server/panel/data/bind.pl
rm -f /www/server/panel/data/bind.pl
