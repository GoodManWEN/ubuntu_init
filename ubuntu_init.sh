# auth
cat>tmp.py<<EOF
with open('/etc/ssh/sshd_config','r') as f:
    text = f.readlines()
for idx in range(len(text)):
    line = text[idx]
    if 'PermitRootLogin yes' in line:
        text[idx] = 'PermitRootLogin no\n'
with open('/etc/ssh/sshd_config','w') as f:
    f.writelines(text)
EOF
python3 tmp.py
rm tmp.py
service ssh restart
service sshd restart

# update
apt update 
apt upgarade -y

# essential
apt install ntpdate vim htop unzip supervisor fail2ban sudo -y

# install python 3.8
sudo apt-get install build-essential libncursesw5-dev libgdbm-dev libc6-dev zlib1g-dev libsqlite3-dev tk-dev libssl-dev openssl libffi-dev libbz2-dev -y
wget https://www.python.org/ftp/python/3.8.10/Python-3.8.10.tgz
tar -zxvf Python-3.8.10.tgz
cd Python-3.8.10
./configure --enable-optimizations
make && make install
pip3 install requests uvloop aiohttp pipeit beautifulsoup4 lxml fastapi uvicorn[standard] -y

# install node 16
curl -sL https://deb.nodesource.com/setup_16.x | sudo -E bash -
sudo apt-get install -y nodejs

# bt
wget -O install.sh http://download.bt.cn/install/install-ubuntu_6.0.sh && sudo bash install.sh

# bbr
echo net.core.default_qdisc=fq >> /etc/sysctl.conf
echo net.ipv4.tcp_congestion_control=bbr >> /etc/sysctl.conf
sysctl -p
sysctl net.ipv4.tcp_available_congestion_control

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
            "alterId": 8
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
