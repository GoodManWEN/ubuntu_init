# 浮点数性能测试
apt install sysbench
# 默认10秒
sysbench cpu --cpu-max-prime=20000 --threads=2 run


# Bench.sh
wget -qO- bench.sh | bash

# SuperBench.sh
wget -qO- --no-check-certificate https://raw.githubusercontent.com/oooldking/script/master/superbench.sh | bash

# 新版
wget -qO- down.vpsaff.net/linux/speedtest/superbench.sh | sudo bash
或
bash <(wget -qO- https://down.vpsaff.net/linux/speedtest/superbench.sh)
