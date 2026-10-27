#!/usr/bin/env bash
# Ubuntu 新装服务器初始化；单文件、root 执行、统一问卷、模块独立验收。
# Python 按要求 make && make install 到 /usr/local，遮蔽 PATH 中的 python3。
# 本脚本固定使用 /usr/bin/python3 处理系统配置；不覆盖 Ubuntu 管理的文件。
# 支持目标：Ubuntu 22.04/24.04/26.04 LTS，amd64/arm64，真实 systemd 环境。
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C.UTF-8
umask 077
SYS_PY=/usr/bin/python3
declare -A STATUS=()
declare -a MODULES=()
FAILURES=0; MOD=main

help_text() {
cat <<'HELP'
用法：以 root 执行 bash ubuntu-init.sh；查看说明：bash ubuntu-init.sh --help
所有选项在开始时填写，确认执行计划后才开始安装；中途不再询问安装选项。
日志/解析出的版本/外部探测结果：/var/log/ubuntu-init/<运行编号>/
配置备份：/var/backups/ubuntu-init/<运行编号>/（JSON 中保存原内容、权限、属主）
退出码：0=通过（可能有明确警告）；1=失败；2=只有外网 SSH 未验证；130=中断。

Python 默认 stable，允许 3.13 等系列和完整版本（最低3.11）；Node 默认 lts；
Rust 默认 stable，接受完整版本；Axel 总是解析官方最新正式 release。
Python 使用 make && make install，prefix=/usr/local；标准 PATH 中 python3/pip3
会优先使用新版本。/usr/bin/python3 保留，系统 APT/fail2ban 使用系统解释器。
源码/二进制安装的 Python、Node、Axel 不由 APT 自动更新，需要另行维护。
Python 第三方包为独立可选项，装在 /opt/server-init-venv。
Docker 为独立可选模块，默认不安装；选择后安装官方 stable 仓库最新版本，
包括 Engine、CLI、containerd、Buildx 和 Compose 插件，并运行 hello-world 验收。
Docker 仅供 root 使用，不给普通用户添加 docker 组权限；不开放远程 Docker API。
已有冲突软件包或重复 Docker 源时先报告失败，不自动卸载已有容器运行时。
Docker 验收需要连通官方软件源和 Docker Hub；镜像拉取或运行失败会标记模块失败。
Docker 发布的容器端口可能绕过 UFW 规则，需另外配置容器端口访问控制。
同时选择 Docker/fail2ban 时，SSH 封禁使用 iptables action 兼容 Docker 默认后端。
swap 旧文件先停用、删除，再创建 /swapfile，不保留旧文件；分区只停用不删除。
swap 自动重建支持 ext4/xfs；zram、加密 swap、自定义 swap unit 拒绝自动处理。
时区默认保持当前配置，用户可以选择 Etc/UTC 等名称。不会自动重启服务器。

账户及密码由用户在执行前准备；本脚本不创建用户、不修改密码、组或 sudo 权限。
SSH：普通用户使用密码登录，root 禁止直接 SSH 登录；管理时使用已有 root 密码 su -。
问卷只需指定一个已有普通用户，用于只读检查账号和密码登录配置。
SSH 设置 PasswordAuthentication yes / AuthenticationMethods password，不修改公钥或证书配置。
先禁止 root SSH 登录，同时保留旧、新端口；外部 TCP 通过后才移除旧监听端口。
Check-Host 会收到问卷中填写的公网 IP/端口并生成公开报告，无需提供云凭据。
公网 IP 必须为本机入站地址，同端口映射；不要填写共享出口 NAT IP。
关闭探测、服务不可用或端口不通，均显示 UNVERIFIED 并返回非零退出码。
探测只证明成功节点的 TCP 路径；不能代替实际密码登录或覆盖所有来源网络。
本脚本处理活动 UFW；保留其他现有防火墙策略；云安全组需事先放行新端口。
禁用 root 登录不会终止已有会话。请保持当前连接，另开终端验证新端口登录。
复杂 SSH 启动参数、AllowUsers/Match 特殊认证要求等会拒绝自动处理并报错。

参考：man.openbsd.org/sshd_config；check-host.net/about/api；
docs.python.org/3/using/unix.html；nodejs.org/dist/index.json；
rust-lang.github.io/rustup/installation/；github.com/fail2ban/fail2ban；
github.com/axel-download-accelerator/axel；docs.docker.com/engine/install/ubuntu/。
HELP
}

# 追踪与错误处理：模块在非条件调用的独立子 shell 中启用 errexit。
log() { printf '[%s] [%-14s] [%s] %s\n' "$(date '+%F %T%z')" "$MOD" "$1" "$2"; }
fail() { log FAIL "$*" >&2; return 1; }
warn() { log WARN "$*"; : >"$RUN/$MOD.warn"; }
step() { local label=$1; shift; log STEP "$label"; "$@"; }
py() { "$SYS_PY" -I "$HELPER" "$@"; }
field() { py field "$RUN/$1.json" "$2"; }
backup() { py snapshot "$BACKUP/config.json" "$@"; }
write_conf() { py write "$1" "${2:-0644}"; }
on_error() {
    local code=$1 line=$2 cmd=$3
    trap - ERR INT TERM; set +e
    log FAIL "exit=$code line=$line command=$cmd"
    if [[ $MOD == docker && ${DOCKER_REPO_DIRTY:-0} == 1 ]]; then
        if py restore "$BACKUP/docker-repo.json"; then log WARN 'Docker 软件源验证/解析失败，已恢复本次修改前的软件源与签名公钥'
        else log FAIL 'Docker 软件源自动恢复失败，请查看 docker-repo.json 备份'; fi
    fi
    if [[ $MOD == ssh && ${SSH_DIRTY:-0} == 1 ]]; then ssh_restore; fi
    if [[ $MOD == fail2ban && ${BAN_TEST:-0} == 1 ]]; then fail2ban-client set sshd unbanip 192.0.2.123 || log FAIL '测试封禁清理失败'; fi
    exit "$code"
}
run_module() {
    local name=$1 enabled=$2 func=$3 dependencies=${4:-} dep rc start=$SECONDS
    MODULES+=("$name")
    if [[ $enabled != 1 ]]; then STATUS[$name]=SKIP; return; fi
    for dep in $dependencies; do
        if [[ ${STATUS[$dep]:-} != OK && ${STATUS[$dep]:-} != WARN ]]; then
            STATUS[$name]=BLOCKED; FAILURES=$((FAILURES+1)); log FAIL "$name 依赖 $dep 未通过，跳过"; return
        fi
    done
    log START "$name"
    (
        trap - EXIT
        MOD=$name; set -Eeuo pipefail
        trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
        trap 'on_error 130 "$LINENO" interrupted' INT TERM
        "$func"
    )
    rc=$?
    if ((rc==0)); then
        if [[ -f $RUN/$name.warn ]]; then STATUS[$name]=WARN; else STATUS[$name]=OK; fi
    elif ((rc==42)); then STATUS[$name]=UNVERIFIED; FAILURES=$((FAILURES+1))
    else STATUS[$name]=FAIL; FAILURES=$((FAILURES+1)); fi
    log "${STATUS[$name]}" "$name 耗时 $((SECONDS-start)) 秒"
}

# 问卷：显式赋值，不使用 eval；输入从终端读取，避免被安装命令吞掉。
ask() {
    local target=$1 prompt=$2 default=${3:-} answer_text
    printf '%s [%s]: ' "$prompt" "$default" >&3
    IFS= read -r answer_text <&3 || { printf '\n输入中断，退出。\n' >&2; exit 1; }
    printf -v "$target" '%s' "${answer_text:-$default}"
}
yesno() {
    local variable=$1 question=$2 default=$3 reply
    while :; do
        ask reply "$question (y/n)" "$default"
        case ${reply,,} in y|yes) printf -v "$variable" 1; return;; n|no) printf -v "$variable" 0; return;; esac
        printf '请输入 y 或 n。\n' >&3
    done
}
number() {
    local variable=$1 question=$2 default=$3 min=$4 max=$5 reply
    while :; do
        ask reply "$question" "$default"
        if [[ $reply =~ ^[0-9]{1,9}$ ]] && ((10#$reply>=min && 10#$reply<=max)); then
            printf -v "$variable" '%d' "$((10#$reply))"; return
        fi
        printf '请输入 %s 到 %s 之间的整数。\n' "$min" "$max" >&3
    done
}
version_input() {
    local variable=$1 question=$2 default=$3 reply
    while :; do
        ask reply "$question" "$default"
        if [[ $reply =~ ^(stable|lts|v?[0-9]+(\.[0-9]+){0,2})$ ]]; then printf -v "$variable" '%s' "$reply"; return; fi
    done
}
questionnaire() {
    local zone guess
    guess=$(getent passwd | awk -F: '$3>=1000 && $3<65534 && $7 !~ /(nologin|false)$/ {print $1; exit}')
    zone=$(timedatectl show -p Timezone --value) || zone=Etc/UTC
    zone=${zone:-Etc/UTC}
    printf '\nUbuntu %s / %s：填写完问卷后统一执行。\n' "$VERSION_ID" "$ARCH" >&3
    yesno SSH '配置 SSH（禁止 root 登录、修改端口）' y
    SSH_PORT=22000; LOGIN_USER=''; PROBE=0; PUBLIC_IP=''; UFW_ENABLE=0
    if [[ $SSH == 1 ]]; then
        number SSH_PORT 'SSH 目标端口' 22000 1 65535
        while :; do
            ask LOGIN_USER '已有普通 SSH 登录用户（已自行设置密码；仅做只读检查）' "$guess"
            [[ $LOGIN_USER =~ ^[a-z_][a-z0-9_-]{0,30}$ && $LOGIN_USER != root ]] && break
        done
        yesno UFW_ENABLE '如果 UFW 未启用，是否启用（先放行旧、新 SSH 端口）' n
        printf '外部验证会将公网 IP/端口提交给 Check-Host，并生成公开报告。请预先放行云安全组的新端口。\n' >&3
        yesno PROBE '使用外部节点验证入站 TCP' y
        if [[ $PROBE == 1 ]]; then
            while [[ -z $PUBLIC_IP ]]; do ask PUBLIC_IP '服务器入站公网 IP（不填域名/共享出口地址，同端口映射）' ''; done
        fi
    fi
    yesno SWAP '删除旧 swap 文件并重建' y
    SWAP_MB=$(awk '/^MemTotal:/ {printf "%d",($2+1023)/1024}' /proc/meminfo)
    if [[ $SWAP == 1 ]]; then number SWAP_MB 'swap 大小 MiB（默认约等于总内存）' "$SWAP_MB" 64 1048576; fi
    number UPGRADE '升级：0=不升级现有包；1=常规；2=完整依赖升级（允许删除包）' 1 0 2
    yesno ESSENTIAL '安装基础工具 vim/htop/unzip/git/curl/ca-certificates' y
    yesno SUPERVISOR '安装 supervisor' y
    yesno REDIS '安装 redis-tools（客户端）' y
    yesno DOCKER '安装 Docker 官方稳定版（含 Buildx、Compose，执行容器验收）' y
    if [[ $DOCKER == 1 ]]; then
        printf 'Docker 仅供 root 使用；验收需拉取 Docker Hub 镜像。未来发布容器端口时，需单独配置访问控制，不能只依赖 UFW。\n' >&3
    fi
    yesno F2B '安装 fail2ban SSH 防护（120分钟6次，封禁48小时）' y
    TRUST=''
    if [[ $F2B == 1 ]]; then ask TRUST '额外可信 IP/CIDR（空格分隔，留空仅 loopback）' ''; fi
    yesno PYTHON '源码安装 Python，遮蔽标准 PATH 中的 python3' y
    PY_VERSION=stable; PGO=0; TK=0; PYEXTRAS=0
    if [[ $PYTHON == 1 ]]; then
        version_input PY_VERSION 'Python（stable / 3.13 / 完整版本，最低3.11）' stable
        yesno PGO '启用 PGO 编译优化（耗时较长）' y
        yesno TK '包含 Tk/GUI 支持' n
        yesno PYEXTRAS '在 /opt/server-init-venv 安装原脚本的 Python 第三方包' n
    fi
    yesno NODE '安装 Node.js' n
    NODE_VERSION=lts
    if [[ $NODE == 1 ]]; then version_input NODE_VERSION 'Node（lts / 24 / 完整版本）' lts; fi
    yesno RUST '安装 Rust' y
    RUST_VERSION=stable; RUST_USER=root
    if [[ $RUST == 1 ]]; then
        version_input RUST_VERSION 'Rust（stable 或完整版本，如 1.90.0）' stable
        while :; do
            ask RUST_USER 'Rust 所属用户（必须已存在）' root
            [[ $RUST_USER =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] && break
        done
    fi
    yesno AXEL '安装 Axel 最新正式版（16连接）' y
    yesno TIME '配置时间同步' y
    ZONE=$zone
    if [[ $TIME == 1 ]]; then
        while :; do
            ask ZONE '时区（回车保持当前；例如 Etc/UTC）' "$zone"
            [[ $ZONE != /* && $ZONE != *..* && -f /usr/share/zoneinfo/$ZONE ]] && break
        done
    fi
    yesno JOURNAL '设置 journal 持续容量限制' y
    JOURNAL_MB=100; VACUUM=0
    if [[ $JOURNAL == 1 ]]; then
        number JOURNAL_MB 'journal 上限 MiB' 200 32 102400
        yesno VACUUM '同时轮转并清理已有归档日志' n
    fi
    yesno BBR '启用内核已有的 BBR/fq' y
    yesno CORE '禁止新 core dump' y
    printf '\n执行计划：SSH=%s/port=%s/普通登录用户=%s/认证=密码/外网探测=%s；UFW启用=%s\n' "$SSH" "$SSH_PORT" "$LOGIN_USER" "$PROBE" "$UFW_ENABLE" >&3
    printf 'swap=%s/%sMiB；升级=%s；基础=%s；supervisor=%s；redis-tools=%s；Docker=%s；fail2ban=%s\n' "$SWAP" "$SWAP_MB" "$UPGRADE" "$ESSENTIAL" "$SUPERVISOR" "$REDIS" "$DOCKER" "$F2B" >&3
    printf 'Python=%s/%s/PGO=%s/Tk=%s/第三方包=%s；Node=%s/%s；Rust=%s/%s/user=%s；Axel=%s\n' "$PYTHON" "$PY_VERSION" "$PGO" "$TK" "$PYEXTRAS" "$NODE" "$NODE_VERSION" "$RUST" "$RUST_VERSION" "$RUST_USER" "$AXEL" >&3
    printf '时间同步=%s/时区=%s；journal=%s/%sMiB；清理旧日志=%s；BBR=%s；core禁用=%s\n' "$TIME" "$ZONE" "$JOURNAL" "$JOURNAL_MB" "$VACUUM" "$BBR" "$CORE" >&3
    printf '所选模块的必要依赖仍会安装；APT 安装也可能升级这些依赖。不会自动重启。\n' >&3
    yesno GO '确认以上计划并开始' n
    [[ $GO == 1 ]] || { printf '已取消，未修改系统。\n'; exit 0; }
}

# 软件包：严格检查更新索引，等待锁，配置文件采用保留本地版本策略。
apt_run() {
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none UCF_FORCE_CONFFOLD=1 \
    apt-get -y -o DPkg::Lock::Timeout=180 -o Acquire::Retries=3 \
        -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}
packages() { step "安装依赖：$*" apt_run install --no-install-recommends "$@"; }
bootstrap() {
    if command -v cloud-init >/dev/null; then step '等待 cloud-init 完成' timeout 300 cloud-init status --wait; fi
    [[ -z $(dpkg --audit) ]] || fail 'dpkg 存在未完成操作，请先修复'
    step '更新 APT 索引' apt_run -o APT::Update::Error-Mode=any update
    packages ca-certificates curl python3 python3-venv
    write_helper
    "$SYS_PY" -I -m py_compile "$HELPER"
}
upgrade() {
    if [[ $UPGRADE == 2 ]]; then
        apt_run --simulate dist-upgrade >"$RUN/upgrade-plan.txt"
        if grep -Eq '^Remv (openssh-server|sudo|systemd|ubuntu-minimal)( |$)' "$RUN/upgrade-plan.txt"; then fail '升级计划会删除关键管理组件'; fi
        cat "$RUN/upgrade-plan.txt"; step '完整依赖升级' apt_run dist-upgrade
    else step '常规升级（不删除已安装包）' apt_run --with-new-pkgs upgrade; fi
    apt-get check
    [[ -z $(dpkg --audit) ]] || fail '升级后 dpkg 状态不完整'
}

# swap：全部成功停用后才删除旧文件；保留分区本身，修改持久化配置。
swap_module() {
    local fs plan=$RUN/swap.json path free_bytes reclaim needed
    fs=$(findmnt -n -o FSTYPE -T /)
    [[ $fs == ext4 || $fs == xfs ]] || fail "自动 swap 重建仅支持 ext4/xfs，当前 $fs"
    if compgen -G '/etc/systemd/system/*.swap' >/dev/null || compgen -G '/etc/systemd/system/*/*.swap' >/dev/null; then fail '发现自定义 swap unit'; fi
    if [[ -f /etc/crypttab ]] && grep -Eq '^[^#].*\bswap\b' /etc/crypttab; then fail '发现加密 swap 配置'; fi
    py swap-plan "$plan"
    local -a active=() old=() stopped=()
    py field "$plan" active >"$WORK/swap-active"; mapfile -t active <"$WORK/swap-active"
    py field "$plan" old >"$WORK/swap-old"; mapfile -t old <"$WORK/swap-old"
    reclaim=$(py field "$plan" reclaim); free_bytes=$(df -B1 --output=avail / | tail -n1 | tr -d ' ')
    needed=$((SWAP_MB*1024*1024))
    ((free_bytes+reclaim>=needed+512*1024*1024)) || fail '磁盘不足，需在新 swap 外保留至少512MiB'
    backup /etc/fstab
    if [[ -f /etc/initramfs-tools/conf.d/resume ]]; then backup /etc/initramfs-tools/conf.d/resume; command -v update-initramfs >/dev/null; fi
    for path in "${active[@]}"; do
        [[ -n $path ]] || continue
        if swapoff -- "$path"; then stopped+=("$path")
        else
            for path in "${stopped[@]}"; do swapon -- "$path" || log FAIL "恢复旧 swap 失败：$path"; done
            fail 'swapoff 失败；没有删除旧文件'
        fi
    done
    [[ -z $(swapon --noheadings --show=NAME) ]] || fail '仍有活动 swap'
    py swap-fstab "$plan"; systemctl daemon-reload
    for path in "${old[@]}"; do [[ -z $path ]] || step "删除旧 swap $path" rm -f -- "$path"; done
    if [[ -f /etc/initramfs-tools/conf.d/resume ]]; then
        printf 'RESUME=none\n' | write_conf /etc/initramfs-tools/conf.d/resume
        update-initramfs -u
    fi
    [[ ! -e /swapfile && ! -L /swapfile ]] || fail '新 swap 路径存在未预期文件'
    step "分配 ${SWAP_MB}MiB" dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" conv=fsync status=progress
    chmod 0600 /swapfile; chown root:root /swapfile
    step '写入 swap 签名' mkswap /swapfile
    step '启用新 swap' swapon /swapfile
    py swap-verify "$SWAP_MB"
    py swap-fstab "$plan" enable; systemctl daemon-reload
    findmnt --verify --tab-file /etc/fstab
    swapon --show --bytes; free -m
}
essential() { packages vim htop unzip git curl ca-certificates; dpkg-query -W vim htop unzip git curl ca-certificates; }
supervisor() { packages supervisor; systemctl enable --now supervisor; systemctl is-active --quiet supervisor; supervisorctl status; }
redis() { packages redis-tools; redis-cli --version; }

# 官方版本解析与下载：完整版本严格匹配，系列选择最新正式补丁；失败不换版本。
resolve_python() { py resolve python "$PY_VERSION" "$ARCH" "$RUN/python.json"; }
resolve_node() { py resolve node "$NODE_VERSION" "$ARCH" "$RUN/node.json"; }
resolve_rust() { py resolve rust "$RUST_VERSION" "$ARCH" "$RUN/rust.json"; }
resolve_axel() { py resolve axel latest "$ARCH" "$RUN/axel.json"; }
download() {
    local kind=$1 name url checksum
    name=$(field "$kind" name); url=$(field "$kind" url); checksum=$(field "$kind" sha256)
    step "下载 $kind：$url" curl --fail --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 1800 --retry 3 --retry-delay 2 --retry-connrefused \
        -o "$WORK/$name.part" "$url"
    py hash "$WORK/$name.part" "$checksum"
    mv -- "$WORK/$name.part" "$WORK/$name"
    [[ -n $checksum ]] || warn "$kind 无上游资产摘要，仅验证官方HTTPS来源；本地计算的哈希不代表来源认证"
}
unpack() { py extract "$WORK/$(field "$1" name)" "$WORK/extract-$1" "$(field "$1" top)"; }
jobs_count() {
    local count memory cpus
    cpus=$(nproc); memory=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
    count=$((memory/700)); ((count>0)) || count=1
    ((count<=cpus)) || count=$cpus; ((count<=8)) || count=8
    printf '%s\n' "$count"
}

# Python：make 成功才 make install，/usr/local 前缀提供 python3/pip3 遮蔽。
python_module() {
    local version package
    local -a deps=(build-essential pkg-config libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libffi-dev liblzma-dev libncurses-dev libgdbm-dev libgdbm-compat-dev uuid-dev)
    [[ $TK == 0 ]] || deps+=(tk-dev)
    for package in libzstd-dev libmpdec-dev; do if apt-cache show "$package" >/dev/null 2>&1; then deps+=("$package"); fi; done
    packages "${deps[@]}"
    version=$(field python version)
    download python; unpack python
    cd "$WORK/extract-python/$(field python top)"
    local -a options=(--prefix=/usr/local --with-ensurepip=install)
    [[ $PGO == 0 ]] || options+=(--enable-optimizations)
    step '配置 Python' ./configure "${options[@]}"
    # 子 shell 的退出码是 && 链的最终退出码，编译失败绝不被后续 echo 掩盖。
    step '编译成功后安装 Python' /bin/bash -c 'make -j "$1" && make install' -- "$(jobs_count)"
    hash -r
    [[ $(command -v python3) == /usr/local/bin/python3 ]] || fail 'python3 PATH 遮蔽未生效'
    /usr/local/bin/python3 -I - "$version" "$TK" <<'PY_CHECK'
import sys,ssl,sqlite3,bz2,lzma,ctypes,readline,curses,uuid,decimal,venv,ensurepip,dbm.gnu
assert '.'.join(map(str,sys.version_info[:3]))==sys.argv[1],sys.version
assert ssl.create_default_context().cert_store_stats()['x509_ca']>0
assert sqlite3.connect(':memory:').execute('select 1').fetchone()==(1,)
assert bz2.decompress(bz2.compress(b'ok'))==b'ok'
assert lzma.decompress(lzma.compress(b'ok'))==b'ok'
if sys.argv[2]=='1': import tkinter
print(sys.executable,sys.version,ssl.OPENSSL_VERSION)
PY_CHECK
    /usr/local/bin/python3 -m venv "$WORK/venv-check"
    "$WORK/venv-check/bin/python" -m pip --version
    /usr/local/bin/python3 -m pip --version
    "$SYS_PY" -I -c 'import sys; print("Ubuntu system Python:",sys.version)'
    log INFO '标准 PATH 中 python3 已使用新版本；其他已打开的 shell 可能需执行 hash -r'
}
python_extras() {
    local env=/opt/server-init-venv
    if [[ -e $env ]]; then
        [[ -f $env/.ubuntu-init-owned && -x $env/bin/python ]] || fail '现有虚拟环境不属于本脚本或不完整'
        [[ $("$env/bin/python" -c 'import sys;print(sys.version.split()[0])') == "$(field python version)" ]] || fail '现有虚拟环境版本不同，请另行迁移'
    else /usr/local/bin/python3 -m venv "$env"; touch "$env/.ubuntu-init-owned"; fi
    step '安装 Python 应用依赖' "$env/bin/python" -m pip install requests uvloop aiohttp pipeit beautifulsoup4 lxml fastapi 'uvicorn[standard]' ThreadPoolExecutorPlus
    "$env/bin/python" -m pip check
    "$env/bin/python" -c 'import requests,uvloop,aiohttp,pipeit,bs4,lxml,fastapi,uvicorn; from importlib.metadata import version; print(version("ThreadPoolExecutorPlus"))'
    "$env/bin/python" -m pip freeze >"$RUN/python-packages.txt"
    chmod -R go+rX "$env"
}

# Node：下载官网对应架构二进制，独立版本目录，验证 node/npm。
node_module() {
    local version destination binary
    version=$(field node version); destination=/opt/node-v$version
    download node; unpack node
    if [[ -e $destination ]]; then
        [[ -f $destination/.ubuntu-init-owned ]] || fail '已有 Node 目录不属于本脚本'
        [[ $("$destination/bin/node" --version) == v"$version" ]] || fail '已有 Node 版本不符'
    else
        chown -R root:root "$WORK/extract-node/$(field node top)"
        chmod -R go-w "$WORK/extract-node/$(field node top)"
        mv -- "$WORK/extract-node/$(field node top)" "$destination"
        touch "$destination/.ubuntu-init-owned"; chmod -R go+rX "$destination"
    fi
    mkdir -p /usr/local/bin
    for binary in node npm npx corepack; do
        [[ -e $destination/bin/$binary ]] || continue
        if [[ -e /usr/local/bin/$binary && ! -L /usr/local/bin/$binary ]]; then cp -a "/usr/local/bin/$binary" "$BACKUP/$binary.before-node"; fi
        ln -sfn -- "$destination/bin/$binary" "/usr/local/bin/$binary"
    done
    hash -r
    [[ $(node --version) == v"$version" && $(command -v node) == /usr/local/bin/node ]] || fail 'Node 验收失败'
    node -e 'const assert=require("node:assert");assert.equal(2+2,4);console.log(process.version,process.arch)'
    npm --version
}

# Rust：官方 rustup，安装到指定账户；不将普通用户可写目录加入 root 的 PATH。
rust_module() {
    local home version temp
    id "$RUST_USER" >/dev/null || fail 'Rust 用户不存在'
    home=$(getent passwd "$RUST_USER" | cut -d: -f6)
    [[ -d $home && ! -L $home ]] || fail 'Rust 用户 home 无效'
    packages build-essential
    version=$(field rust version); download rust
    temp=$(mktemp -d /var/tmp/ubuntu-init-rust.XXXXXXXX); chmod 0755 "$temp"
    install -m 0755 "$WORK/rustup-init" "$temp/rustup-init"
    local -a as_user=(runuser -u "$RUST_USER" -- env HOME="$home" CARGO_HOME="$home/.cargo" RUSTUP_HOME="$home/.rustup" PATH="$home/.cargo/bin:$PATH")
    "${as_user[@]}" "$temp/rustup-init" -y --profile minimal --default-toolchain "$version" --no-modify-path
    rm -rf -- "$temp"
    cd /
    "${as_user[@]}" "$home/.cargo/bin/rustup" default "$version"
    [[ $("${as_user[@]}" "$home/.cargo/bin/rustc" --version) == "rustc $version "* ]] || fail 'Rust 实际版本不符'
    "${as_user[@]}" "$home/.cargo/bin/cargo" --version
    "${as_user[@]}" /bin/sh -c '
        set -e
        t=$(mktemp -d); trap '\''rm -rf "$t"'\'' EXIT
        printf "%s\n" '\''fn main() { println!("rust-ok"); }'\'' > "$t/check.rs"
        rustc "$t/check.rs" -o "$t/check"
        "$t/check"
        for f in "$HOME/.profile" "$HOME/.bashrc"; do
            [ ! -L "$f" ] || { echo "Refusing profile symlink: $f" >&2; exit 1; }
            if ! grep -qF "# ubuntu-init Rust PATH" "$f" 2>/dev/null; then
                printf "\n%s\n%s\n" "# ubuntu-init Rust PATH" '\''case ":$PATH:" in *":$HOME/.cargo/bin:"*) ;; *) export PATH="$HOME/.cargo/bin:$PATH" ;; esac'\'' >> "$f"
            fi
        done'
}

# Axel：正式 release tarball，TLS 支持与真实 HTTPS 下载检查。
axel_module() {
    local version
    packages build-essential pkg-config gettext libssl-dev
    version=$(field axel version); download axel; unpack axel
    cd "$WORK/extract-axel/$(field axel top)"
    ./configure --prefix=/usr/local --sysconfdir=/etc --with-ssl=yes
    step '编译成功后安装 Axel' /bin/bash -c 'make -j "$1" && make install' -- "$(jobs_count)"
    backup /etc/axelrc
    printf '# Managed by ubuntu-init\nnum_connections = 16\n' | write_conf /etc/axelrc
    /usr/local/bin/axel --version >"$RUN/axel-version.txt"
    cat "$RUN/axel-version.txt"; grep -Fq "$version" "$RUN/axel-version.txt" || fail 'Axel 版本不符'
    timeout 60 /usr/local/bin/axel -n 2 -o "$WORK/axel-https-test" https://www.python.org/robots.txt
    [[ -s $WORK/axel-https-test ]] || fail 'Axel HTTPS 下载失败'
}
# Docker：官方 APT stable 仓库，版本来源/软件包/本机 API/插件/实际容器分步验收。
docker_local() {
    # 显式连接本机 socket，避免继承用户环境后意外操作其他 Docker 主机。
    timeout "${DOCKER_COMMAND_TIMEOUT:-30}" env -u DOCKER_CONTEXT -u DOCKER_HOST -u DOCKER_TLS -u DOCKER_TLS_VERIFY -u DOCKER_CERT_PATH -u DOCKER_API_VERSION \
        /usr/bin/docker --host unix:///var/run/docker.sock "$@"
}
docker_module() {
    local package state codename file=/etc/apt/sources.list.d/docker.sources key=/etc/apt/keyrings/docker.asc spec installed ready=0 i
    local -a conflicts=() install_args=()
    DOCKER_REPO_DIRTY=0
    for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
        state=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)
        [[ $state != installed ]] || conflicts+=("$package")
    done
    if ((${#conflicts[@]}>0)); then fail "发现 Docker 冲突软件包：${conflicts[*]}；请先处理，本模块未卸载任何已有容器运行时"; fi
    codename=${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}
    [[ $codename =~ ^[a-z][a-z0-9]*$ ]] || fail '无法确定 Docker 仓库的 Ubuntu 代号'
    step '检查现有 Docker 软件源，避免重复及 Signed-By 冲突' py docker-sources-check "$file"
    packages ca-certificates curl
    step '下载 Docker 官方仓库签名公钥' curl --fail --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 120 --max-filesize 1048576 --retry 3 \
        -o "$WORK/docker.asc" https://download.docker.com/linux/ubuntu/gpg
    grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----' "$WORK/docker.asc" || fail 'Docker 公钥格式不正确，未写入软件源'
    py snapshot "$BACKUP/docker-repo.json" "$key" "$file"
    DOCKER_REPO_DIRTY=1
    install -d -m 0755 /etc/apt/keyrings
    write_conf "$key" 0644 <"$WORK/docker.asc"
    printf '# Managed by ubuntu-init\nTypes: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: %s\n' "$codename" "$ARCH" "$key" | write_conf "$file" 0644
    step '验证 Docker 仓库签名并更新 APT 索引' apt_run -o APT::Update::Error-Mode=any update
    step '解析官方 stable 仓库最新软件包版本' py docker-versions "$codename" "$ARCH" "$RUN/docker-packages.json"
    py docker-install-args "$RUN/docker-packages.json" >"$WORK/docker-install-args"
    mapfile -t install_args <"$WORK/docker-install-args"
    ((${#install_args[@]}==5)) || fail 'Docker 安装计划不完整'
    DOCKER_REPO_DIRTY=0
    packages "${install_args[@]}"
    for spec in "${install_args[@]}"; do
        package=${spec%%=*}
        installed=$(dpkg-query -W -f='${Version}' "$package")
        [[ $installed == "${spec#*=}" ]] || fail "Docker 软件包版本不符：$package"
    done
    step '启动 Docker/containerd 并设置开机启动' systemctl enable --now containerd.service docker.service
    systemctl is-active --quiet containerd.service
    systemctl is-active --quiet docker.service
    for i in {1..10}; do
        if DOCKER_COMMAND_TIMEOUT=10 docker_local info >"$RUN/docker-info.txt" 2>"$RUN/docker-info-error.txt"; then ready=1; break; fi
        log INFO '等待本机 Docker API 就绪…'; sleep 2
    done
    if [[ $ready != 1 ]]; then cat "$RUN/docker-info-error.txt"; fail 'Docker 服务已启动，但本机 API 尚未就绪'; fi
    step '校验 Docker 客户端与服务端版本' docker_local version
    step '校验 Docker Compose 插件' docker_local compose version
    step '校验 Docker Buildx 插件' docker_local buildx version
    log STEP '拉取并运行官方 hello-world 镜像（无容器网络、不发布端口，结束后删除测试容器）'
    DOCKER_COMMAND_TIMEOUT=180 docker_local run --rm --pull=always --network none docker.io/library/hello-world:latest | tee "$RUN/docker-hello-world.txt"
    grep -Fq 'Hello from Docker!' "$RUN/docker-hello-world.txt" || fail 'Docker 测试容器未输出预期结果'
    log INFO 'Docker Engine、Compose、Buildx 及真实容器运行验收通过；准确软件包版本已留档'
}

# 时间同步：保留当前时区为默认，只运行一个时间同步服务。
time_module() {
    local service synchronized=0 i
    if systemctl is-active --quiet chrony || dpkg-query -W -f='${db:Status-Status}' chrony 2>/dev/null | grep -qx installed; then service=chrony
    elif systemctl is-active --quiet systemd-timesyncd || dpkg-query -W -f='${db:Status-Status}' systemd-timesyncd 2>/dev/null | grep -qx installed; then service=systemd-timesyncd
    else packages chrony; service=chrony; fi
    if systemctl is-active --quiet ntp || systemctl is-active --quiet ntpsec; then fail '存在 ntp/ntpsec，拒绝启动第二个时间服务'; fi
    if [[ $service == chrony ]] && systemctl is-active --quiet systemd-timesyncd; then systemctl disable --now systemd-timesyncd; fi
    timedatectl set-timezone "$ZONE"; systemctl enable --now "$service"
    if [[ $service == chrony ]]; then chronyc waitsync 12 0 0 5; chronyc tracking
    else
        for i in {1..12}; do
            if [[ $(timedatectl show -p NTPSynchronized --value) == yes ]]; then synchronized=1; break; fi
            log INFO '等待时间同步…'; sleep 5
        done
        [[ $synchronized == 1 ]] || fail '时间服务已启动，但未完成同步'
    fi
    [[ $(timedatectl show -p Timezone --value) == "$ZONE" ]] || fail '时区验收失败'
    timedatectl status
}

# journal：容量限制是持久配置；清理已有日志需在问卷中单独选择。
journal_module() {
    local file=/etc/systemd/journald.conf.d/99-ubuntu-init.conf
    backup "$file"
    printf '[Journal]\nSystemMaxUse=%sM\nRuntimeMaxUse=%sM\n' "$JOURNAL_MB" "$JOURNAL_MB" | write_conf "$file"
    systemd-analyze cat-config systemd/journald.conf >"$RUN/journald-effective.txt"
    "$SYS_PY" -I - "$RUN/journald-effective.txt" "$JOURNAL_MB" <<'PY_JOURNAL'
import sys
values={}; section=''
for line in open(sys.argv[1]):
    line=line.strip()
    if line.startswith('['): section=line
    elif section=='[Journal]' and '=' in line and not line.startswith(('#',';')):
        k,v=line.split('=',1); values[k.strip()]=v.strip()
assert values.get('SystemMaxUse')==sys.argv[2]+'M' and values.get('RuntimeMaxUse')==sys.argv[2]+'M','Conflicting journal overrides'
PY_JOURNAL
    systemctl restart systemd-journald; systemctl is-active --quiet systemd-journald
    if [[ $VACUUM == 1 ]]; then journalctl --rotate; journalctl --vacuum-size="${JOURNAL_MB}M"; fi
    journalctl --disk-usage
}

# BBR：不升级内核，不强制改现有网卡队列；写入后读回验证。
bbr_module() {
    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then modprobe tcp_bbr; fi
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control || fail '内核没有 BBR'
    local file=/etc/sysctl.d/99-ubuntu-init-bbr.conf
    backup "$file"
    printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' | write_conf "$file"
    sysctl -p "$file"
    [[ $(sysctl -n net.ipv4.tcp_congestion_control) == bbr && $(sysctl -n net.core.default_qdisc) == fq ]] || fail 'BBR 验收失败'
    log INFO 'BBR 已配置；fq 默认值用于新建队列，现有网卡队列未强制重配'
}

# Core dump：内核丢弃新 core 数据，补充新会话/新服务限制，兼容 Apport。
core_module() {
    local file=/etc/sysctl.d/99-ubuntu-init-core.conf
    backup "$file" /etc/security/limits.d/99-ubuntu-init-core.conf /etc/systemd/system.conf.d/99-ubuntu-init-core.conf /etc/systemd/coredump.conf.d/99-ubuntu-init-core.conf
    printf 'fs.suid_dumpable = 0\nkernel.core_pattern = |/bin/false\n' | write_conf "$file"
    printf '* soft core 0\n* hard core 0\nroot soft core 0\nroot hard core 0\n' | write_conf /etc/security/limits.d/99-ubuntu-init-core.conf
    printf '[Manager]\nDefaultLimitCORE=0\n' | write_conf /etc/systemd/system.conf.d/99-ubuntu-init-core.conf
    printf '[Coredump]\nStorage=none\nProcessSizeMax=0\n' | write_conf /etc/systemd/coredump.conf.d/99-ubuntu-init-core.conf
    if [[ -f /etc/default/apport ]]; then
        backup /etc/default/apport; printf 'enabled=0\n' | write_conf /etc/default/apport
        if systemctl is-active --quiet apport; then systemctl stop apport; fi
    fi
    systemctl daemon-reload; sysctl -p "$file"
    [[ $(sysctl -n fs.suid_dumpable) == 0 && $(sysctl -n kernel.core_pattern) == '|/bin/false' ]] || fail 'Core dump 验收失败'
    log INFO '内核已丢弃新 core 数据；进程限制对新会话/新服务生效，旧转储文件保留'
}

# SSH：兼容 systemd socket，保留原端口直至外部探测通过。
socket_ports() {
    "$SYS_PY" -I - <<'PY_PORTS'
import re,subprocess
text=subprocess.check_output(['systemctl','show','ssh.socket','-p','Listen','--value'],text=True)
ports=sorted(set(re.findall(r':(\d+) \(Stream\)',text)),key=int)
assert ports,'Cannot determine ssh.socket TCP ports'
print(','.join(ports))
PY_PORTS
}
ssh_restart() {
    local ports=$1 port file=/etc/systemd/system/ssh.socket.d/zzzz-ubuntu-init.conf
    if [[ $SOCKET == 1 ]]; then
        {
            printf '[Socket]\nListenStream=\n'
            for port in ${ports//,/ }; do
                printf 'ListenStream=0.0.0.0:%s\n' "$port"
                if [[ -s /proc/net/if_inet6 ]] && [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || printf 1) == 0 ]]; then printf 'ListenStream=[::]:%s\n' "$port"; fi
            done
            printf 'BindIPv6Only=ipv6-only\n'
        } | write_conf "$file"
        systemctl daemon-reload
        systemctl stop ssh.service; systemctl restart ssh.socket; systemctl start ssh.service
        systemctl is-active --quiet ssh.socket
        [[ $(socket_ports) == "$ports" ]] || fail 'SSH socket 实际端口与计划不符'
    else systemctl reload-or-restart ssh.service; fi
    systemctl is-active --quiet ssh.service
    sleep 2
    for port in ${ports//,/ }; do py ssh-local "$port"; done
}
ssh_restore() {
    log FAIL 'SSH 本机应用失败，恢复旧配置；恢复旧配置不代表 root 已禁止登录'
    rm -f "$RUN/ssh-local-ok" "$RUN/ssh-ports.txt"
    if py restore "$BACKUP/ssh.json" && systemctl daemon-reload; then
        if [[ ${SOCKET:-0} == 1 ]]; then systemctl stop ssh.service; systemctl restart ssh.socket; fi
        systemctl restart ssh.service
        if /usr/sbin/sshd -t && systemctl is-active --quiet ssh.service; then log WARN '旧配置已恢复；root 加固失败，请检查旧端口'
        else log FAIL '自动恢复验收失败，请使用云控制台；备份位于 ssh.json'; fi
    else log FAIL '配置恢复失败，请通过云控制台恢复'; fi
}
ssh_module() {
    local current transition port file=/etc/systemd/system/ssh.socket.d/zzzz-ubuntu-init.conf
    SSH_DIRTY=0; SOCKET=0
    step '只读检查已有普通用户及密码状态' py password-account "$LOGIN_USER"
    packages openssh-server openssh-client
    [[ $PROBE == 0 ]] || py public-ip "$PUBLIC_IP"
    install -d -m 0755 /run/sshd
    /usr/sbin/sshd -t
    [[ $(systemctl show ssh.service -p KillMode --value) == process ]] || fail 'SSH KillMode 不是 process，拒绝可能断开现有会话的重启'
    "$SYS_PY" -I - <<'PY_LAUNCH'
import re,shlex,subprocess
def prop(name): return subprocess.check_output(['systemctl','show','ssh.service','-p',name,'--value'],text=True).strip()
m=re.search(r'argv\[\]=([^;]+)',prop('ExecStart'))
assert m and m[1].strip() in ('/usr/sbin/sshd -D $SSHD_OPTS','/usr/sbin/sshd -D'),'Nonstandard ExecStart requires review'
for value in shlex.split(prop('Environment')):
    assert not value.startswith('SSHD_OPTS=') or value=='SSHD_OPTS=','Systemd SSHD_OPTS override requires review'
files=prop('EnvironmentFiles')
assert not files or re.fullmatch(r'/etc/default/ssh \(ignore_errors=(yes|no)\)',files),'Custom EnvironmentFiles requires review'
from pathlib import Path
if Path('/etc/default/ssh').exists():
    for line in Path('/etc/default/ssh').read_text().splitlines():
        if re.match(r'^\s*SSHD_OPTS=',line):
            value=shlex.split(line.split('=',1)[1],comments=True)
            assert not value or value==[''],'Nonempty SSHD_OPTS requires review'
PY_LAUNCH
    if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then SOCKET=1; fi
    current=$(/usr/sbin/sshd -T | awk '$1=="port" {print $2}' | sort -nu | paste -sd,)
    [[ -n $current ]] || fail '无法确定旧 SSH 端口'
    if [[ $SOCKET == 1 ]]; then current=$current,$(socket_ports); fi
    port=$(awk '{print $4}' <<<"${SSH_CONNECTION:-}")
    if [[ $port =~ ^[0-9]+$ ]]; then current=$current,$port; fi
    transition=$(printf '%s\n' "${current//,/$'\n'}" "$SSH_PORT" | sort -nu | paste -sd,)
    if ss -H -ltn "sport = :$SSH_PORT" | grep -q .; then py ssh-local "$SSH_PORT" || fail '目标端口已被其他服务占用'; fi
    py snapshot "$BACKUP/ssh.json" "$file"
    SSH_DIRTY=1
    py ssh-apply /etc/ssh/sshd_config "$transition" "$BACKUP/ssh.json"
    py ssh-effective "$SSH_PORT" "$LOGIN_USER"
    if systemctl is-active --quiet firewalld; then fail '发现 firewalld，未自动更改其策略'; fi
    if [[ $UFW_ENABLE == 1 ]]; then packages ufw; fi
    if command -v ufw >/dev/null && { ufw status | grep -q '^Status: active' || [[ $UFW_ENABLE == 1 ]]; }; then
        for port in ${transition//,/ }; do step "UFW 放行TCP $port" ufw insert 1 allow "$port/tcp" comment ubuntu-init-ssh; done
        if [[ $UFW_ENABLE == 1 ]]; then ufw --force enable; fi
        ufw status verbose
    else log INFO '没有活动 UFW：保留现有防火墙策略，通过外部节点检验入站结果'; fi
    step '启用禁止 root 的旧/新端口过渡配置' ssh_restart "$transition"
    printf '%s\n' "$transition" >"$RUN/ssh-ports.txt"; touch "$RUN/ssh-local-ok"
    if [[ $PROBE == 0 ]]; then
        log FAIL '外网未验证：已禁止 root，保留旧、新端口，返回 UNVERIFIED'
        SSH_DIRTY=0; exit 42
    fi
    if ! timeout 180 "$SYS_PY" -I "$HELPER" probe "$PUBLIC_IP" "$SSH_PORT" "$RUN/ssh-external.json"; then
        log FAIL '外网探测失败：保持已加固的旧、新端口；检查云安全组、IP、NAT、本机防火墙'
        SSH_DIRTY=0; exit 42
    fi
    py ssh-apply /etc/ssh/sshd_config "$SSH_PORT" "$BACKUP/ssh.json"
    py ssh-effective "$SSH_PORT" "$LOGIN_USER"
    step '外网已验证，切换到最终端口' ssh_restart "$SSH_PORT"
    py ssh-audit /etc/ssh/sshd_config
    printf '%s\n' "$SSH_PORT" >"$RUN/ssh-ports.txt"
    SSH_DIRTY=0
    log INFO "已验证 root SSH 禁用、本机握手及外部 TCP：$PUBLIC_IP:$SSH_PORT"
    log INFO "已核验 $LOGIN_USER 的密码认证配置；实际密码登录及 PAM 会话请另开终端验证"
}

# fail2ban：使用 systemd journal；Docker 选择 iptables action，其他场景保留 nftables。
f2b_action() { if [[ ${DOCKER:-0} == 1 ]]; then printf 'iptables-multiport\n'; else printf 'nftables-multiport\n'; fi; }
fail2ban_module() {
    local ports first addr sample=ubuntu-init-$RANDOM file=/etc/fail2ban/jail.d/99-ubuntu-init.local i banned action
    BAN_TEST=0
    action=$(f2b_action)
    if [[ $action == iptables-multiport ]]; then packages fail2ban python3-systemd iptables openssh-client
    else packages fail2ban python3-systemd nftables openssh-client; fi
    if [[ $SSH == 1 ]]; then [[ -f $RUN/ssh-local-ok ]] || fail 'SSH 本机配置未通过'; ports=$(cat "$RUN/ssh-ports.txt")
    else
        /usr/sbin/sshd -t
        ports=$(/usr/sbin/sshd -T | awk '$1=="port" {print $2}' | sort -nu | paste -sd,)
        [[ -n $ports ]] || fail '没有可保护的 SSH 端口'
        for first in ${ports//,/ }; do py ssh-local "$first"; done
    fi
    "$SYS_PY" -I -c 'from systemd import journal; journal.Reader().close()'
    "$SYS_PY" -I -c 'import ipaddress,sys; [ipaddress.ip_network(s,strict=False) for s in sys.argv[1].split()]' "$TRUST"
    backup "$file"
    printf '[sshd]\nenabled = true\nbackend = systemd\nport = %s\nfindtime = 60m\nmaxretry = 6\nbantime = 48h\nignoreip = 127.0.0.0/8 ::1 %s\nbanaction = %s\njournalmatch = _SYSTEMD_UNIT=ssh.service + _SYSTEMD_UNIT=sshd.service + _COMM=sshd + _COMM=sshd-session\n' "$ports" "$TRUST" "$action" | write_conf "$file"
    fail2ban-client -t; systemctl enable fail2ban; systemctl restart fail2ban
    for i in {1..10}; do if fail2ban-client ping >/dev/null 2>&1; then break; fi; sleep 1; done
    fail2ban-client status sshd
    fail2ban-client get sshd journalmatch >"$RUN/fail2ban-journalmatch.txt"
    grep -q '_COMM=sshd' "$RUN/fail2ban-journalmatch.txt" || fail 'journalmatch 未生效'
    [[ $(fail2ban-client get sshd maxretry) == 6 && $(fail2ban-client get sshd bantime) == 172800 ]] || fail 'fail2ban 有覆盖配置'
    first=${ports%%,*}; addr=$(py ssh-address "$first")
    ssh -F /dev/null -o BatchMode=yes -o PreferredAuthentications=none -o PubkeyAuthentication=no \
        -o PasswordAuthentication=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -p "$first" "$sample@$addr" true >/dev/null 2>&1 || :
    journalctl --sync
    journalctl --since '-2 minutes' --no-pager -o short-iso \
        _SYSTEMD_UNIT=ssh.service + _SYSTEMD_UNIT=sshd.service + _COMM=sshd + _COMM=sshd-session >"$WORK/ssh-journal"
    grep -F "$sample" "$WORK/ssh-journal" >"$WORK/ssh-sample" || fail '未读取到本次真实 SSH 失败日志'
    fail2ban-regex "$WORK/ssh-sample" /etc/fail2ban/filter.d/sshd.conf >"$RUN/fail2ban-regex.txt"
    cat "$RUN/fail2ban-regex.txt"
    grep -Eq '[1-9][0-9]* matched' "$RUN/fail2ban-regex.txt" || fail '过滤器没有匹配真实日志'
    # 文档保留地址，仅验证规则安装/删除，不模拟外部攻击，不封禁用户地址。
    banned=$(fail2ban-client get sshd banip)
    banned=${banned//$'\n'/ }
    [[ " $banned " != *' 192.0.2.123 '* ]] || fail '测试地址已有封禁，拒绝覆盖原状态'
    BAN_TEST=1
    fail2ban-client set sshd banip 192.0.2.123
    if [[ $action == iptables-multiport ]]; then iptables-save >"$RUN/fail2ban-firewall-test.txt"
    else nft list ruleset >"$RUN/fail2ban-firewall-test.txt"; fi
    grep -Fq 192.0.2.123 "$RUN/fail2ban-firewall-test.txt" || fail '封禁规则没有安装'
    fail2ban-client set sshd unbanip 192.0.2.123
    banned=$(fail2ban-client get sshd banip)
    banned=${banned//$'\n'/ }
    [[ " $banned " != *' 192.0.2.123 '* ]] || fail '测试规则没有清理'
    BAN_TEST=0
    log INFO "已验证 journal 真实日志匹配及 $action 规则安装/移除；未模拟外部攻击流量"
}

# 所有安装后再次核对 SSH；单独提示系统重启需求。
final_audit() {
    local port
    if [[ $SSH == 1 ]]; then
        [[ -f $RUN/ssh-local-ok ]] || fail 'SSH 缺少通过记录'
        py password-account "$LOGIN_USER"
        py ssh-audit /etc/ssh/sshd_config; py ssh-effective "$SSH_PORT" "$LOGIN_USER"
        for port in $(tr ',' ' ' <"$RUN/ssh-ports.txt"); do py ssh-local "$port"; done
    fi
    if [[ -e /var/run/reboot-required ]]; then warn '系统需要重启；请先另开终端验证普通用户密码登录及 su -，再自行安排重启'; fi
}

# 内嵌 Python 只在私有工作目录落盘，使用 Ubuntu 的固定解释器执行。
write_helper() {
cat >"$HELPER" <<'PY_EMBEDDED_HELPER'
import base64, glob, hashlib, ipaddress, json, os, posixpath, re, shlex, stat
import subprocess, sys, tarfile, tempfile, time, urllib.request, urllib.error, urllib.parse, pwd
from pathlib import Path

def need(ok, message):
    if not ok: raise RuntimeError(message)

def get(url):
    need(url.startswith('https://'), 'HTTPS required')
    for attempt in range(3):
        try:
            request=urllib.request.Request(url, headers={'User-Agent':'ubuntu-init/1.0','Accept':'application/json, */*'})
            with urllib.request.urlopen(request,timeout=20) as response:
                need(response.url.startswith('https://'), 'HTTPS downgrade refused')
                data=response.read(16*1024*1024+1)
                need(len(data)<=16*1024*1024,'Metadata too large')
                return data.decode('utf-8')
        except urllib.error.HTTPError as exc:
            if exc.code==404: raise
            if attempt==2: raise
        except (OSError,ValueError):
            if attempt==2: raise
        time.sleep(attempt+1)

def ver(v):
    need(re.fullmatch(r'\d+\.\d+\.\d+',v), 'Not a final x.y.z version: '+v)
    return tuple(map(int,v.split('.')))

def matches(v,s):
    return s in ('stable','lts','latest') or v==s or v.startswith(s+'.')

def bundle_digest(bundle):
    digest=bundle.get('messageSignature',{}).get('messageDigest',{})
    if digest:
        need(digest.get('algorithm') in ('SHA2_256',1),'Unexpected Sigstore digest algorithm')
        value=base64.b64decode(digest['digest'],validate=True).hex()
    else:
        # Older Python releases used the pre-bundle Sigstore JSON layout.
        entry=bundle.get('rekor_entry',{})
        body=entry.get('body') or entry.get('canonicalized_body')
        need(body, 'Unsupported official Python Sigstore metadata')
        record=json.loads(base64.b64decode(body,validate=True))
        digest=record['spec']['data']['hash']
        need(digest['algorithm']=='sha256','Unexpected Rekor digest algorithm')
        value=digest['value']
    need(re.fullmatch('[a-fA-F0-9]{64}',value),'Invalid SHA256')
    return value

def resolve(kind,selector,arch):
    s=selector.lower().removeprefix('v')
    need(s in ('stable','lts','latest') or re.fullmatch(r'\d+(?:\.\d+){0,2}',s),'Invalid version input')
    if kind=='python':
        versions=set(re.findall(r'href="(3\.\d+\.\d+)/"',get('https://www.python.org/ftp/python/')))
        candidates=sorted((v for v in versions if ver(v)>=(3,11,0) and matches(v,s)),key=ver,reverse=True)
        for v in candidates:
            base='https://www.python.org/ftp/python/'+v+'/'
            name='Python-'+v+'.tar.xz'
            if 'href="'+name+'"' not in get(base): continue
            sha=bundle_digest(json.loads(get(base+name+'.sigstore')))
            return dict(version=v,url=base+name,name=name,top='Python-'+v,sha256=sha,
                        verification='Official HTTPS Sigstore digest; signing identity NOT verified')
        raise RuntimeError('No final Python >=3.11 matches '+s)
    if kind=='node':
        a={'amd64':'x64','arm64':'arm64'}[arch]
        candidates=[]
        for release in json.loads(get('https://nodejs.org/dist/index.json')):
            v=release['version'].removeprefix('v')
            if not re.fullmatch(r'\d+\.\d+\.\d+',v): continue
            if s in ('lts','stable') and not release.get('lts'): continue
            if matches(v,s) and 'linux-'+a in release.get('files',[]): candidates.append(v)
        need(candidates,'No matching official Node release/architecture')
        v=max(candidates,key=ver); top='node-v'+v+'-linux-'+a; name=top+'.tar.xz'
        base='https://nodejs.org/dist/v'+v+'/'
        sha=next((line.split()[0] for line in get(base+'SHASUMS256.txt').splitlines()
                  if len(line.split())==2 and line.split()[1].lstrip('*')==name),'')
        need(re.fullmatch('[a-fA-F0-9]{64}',sha),'Missing official Node checksum')
        return dict(version=v,url=base+name,name=name,top=top,sha256=sha,
                    verification='Official HTTPS SHA256; GPG signature NOT verified')
    if kind=='rust':
        need(s=='stable' or re.fullmatch(r'1\.\d+\.\d+',s),'Rust needs stable or exact 1.x.y')
        manifest=get('https://static.rust-lang.org/dist/channel-rust-'+s+'.toml')
        section=re.search(r'(?ms)^\[pkg\.rust\]\s*\n(.*?)(?=^\[|\Z)',manifest)
        need(section,'Unsupported Rust manifest')
        m=re.search(r'(?m)^version\s*=\s*"(\d+\.\d+\.\d+)\s',section[1]); need(m,'Missing Rust version')
        v=m[1]; need(s=='stable' or s==v,'Rust version mismatch')
        a={'amd64':'x86_64','arm64':'aarch64'}[arch]
        url='https://static.rust-lang.org/rustup/dist/'+a+'-unknown-linux-gnu/rustup-init'
        sha=get(url+'.sha256').split()[0]; need(re.fullmatch('[a-fA-F0-9]{64}',sha),'Invalid rustup checksum')
        return dict(version=v,url=url,name='rustup-init',top='',sha256=sha,verification='Official HTTPS installer SHA256; rustup verifies components')
    release=json.loads(get('https://api.github.com/repos/axel-download-accelerator/axel/releases/latest'))
    need(not release.get('draft') and not release.get('prerelease'),'Axel is not a final release')
    v=release['tag_name'].removeprefix('v'); ver(v)
    asset=next((a for ext in ('.tar.xz','.tar.gz') for a in release['assets'] if a['name']=='axel-'+v+ext),None)
    need(asset,'Missing Axel release tarball; refusing Git snapshot fallback')
    url=asset['browser_download_url']
    need(url.startswith('https://github.com/axel-download-accelerator/axel/releases/download/'),'Unexpected asset origin')
    sha=(asset.get('digest') or '').removeprefix('sha256:')
    need(not sha or re.fullmatch('[a-fA-F0-9]{64}',sha),'Invalid Axel digest')
    return dict(version=v,url=url,name=asset['name'],top='axel-'+v,sha256=sha,
                verification='GitHub HTTPS SHA256' if sha else 'Official HTTPS only; no published asset SHA256')

def atomic(path,data,mode=None,uid=None,gid=None):
    p=Path(path); need(not p.is_symlink(),'Refusing symlink write: '+str(p))
    old=p.stat() if p.exists() else None
    need(old is None or stat.S_ISREG(old.st_mode),'Not a regular file: '+str(p))
    p.parent.mkdir(parents=True,exist_ok=True)
    fd,temp=tempfile.mkstemp(prefix='.init-',dir=p.parent)
    try:
        with os.fdopen(fd,'wb') as f:
            f.write(data if isinstance(data,bytes) else data.encode()); f.flush(); os.fsync(f.fileno())
        os.chmod(temp,mode if mode is not None else stat.S_IMODE(old.st_mode) if old else 0o644)
        os.chown(temp,uid if uid is not None else old.st_uid if old else 0,gid if gid is not None else old.st_gid if old else 0)
        os.replace(temp,p)
        fd=os.open(p.parent,os.O_RDONLY|os.O_DIRECTORY)
        try: os.fsync(fd)
        finally: os.close(fd)
    finally:
        if os.path.exists(temp): os.unlink(temp)

def snapshot(manifest,paths):
    state=json.loads(Path(manifest).read_text()) if Path(manifest).exists() else {}
    for path in paths:
        p=Path(path); need(not p.is_symlink(),'Refusing symlink backup: '+path)
        if path in state: continue
        if not p.exists(): state[path]=None; continue
        st=p.stat(); need(stat.S_ISREG(st.st_mode),'Backup requires regular file')
        state[path]=dict(data=base64.b64encode(p.read_bytes()).decode(),mode=stat.S_IMODE(st.st_mode),uid=st.st_uid,gid=st.st_gid)
    atomic(manifest,json.dumps(state,indent=2),0o600)

def restore(manifest):
    for path,value in json.loads(Path(manifest).read_text()).items():
        if value is None: Path(path).unlink(missing_ok=True)
        else: atomic(path,base64.b64decode(value['data']),value['mode'],value['uid'],value['gid'])

def directive(line):
    if not line.strip() or line.lstrip().startswith('#'): return None,[]
    need(not line.rstrip().endswith('\\'),'Unsupported SSH continuation')
    m=re.match(r'^\s*([A-Za-z][A-Za-z0-9]*)(?:\s*=\s*|\s+)(.*?)\s*$',line)
    need(m,'Unrecognized sshd directive: '+line.rstrip())
    return m[1].lower(),shlex.split(m[2],comments=True)

def graph(main,base='/etc/ssh',allowed='/etc'):
    files={}; stack=[]
    def visit(name):
        p=Path(name).resolve(strict=True)
        need(p.is_relative_to(Path(allowed).resolve()),'Include escapes allowed tree: '+str(p))
        need(p not in stack,'Cyclic SSH Include')
        if str(p) in files: return
        need(len(files)<128 and len(stack)<16,'Complex SSH Include graph refused')
        st=p.stat()
        need(stat.S_ISREG(st.st_mode) and st.st_uid==0 and not(st.st_mode&0o022),'Unsafe SSH file ownership/permissions: '+str(p))
        text=p.read_text(); files[str(p)]=text; stack.append(p)
        for line in text.splitlines():
            key,args=directive(line)
            if key=='include':
                need(args,'Empty Include')
                for pattern in args:
                    need('~' not in pattern and '%' not in pattern,'Unsupported Include expansion')
                    if not os.path.isabs(pattern): pattern=str(Path(base)/pattern)
                    for child in sorted(glob.glob(pattern)): visit(child)
        stack.pop()
    visit(main); return files

START='# BEGIN ubuntu-init SSH\n'; END='# END ubuntu-init SSH\n'

def ssh_apply(main,ports,manifest,base='/etc/ssh',allowed='/etc'):
    ports=sorted(set(map(int,ports.split(',')))); need(ports and all(1<=p<=65535 for p in ports),'Invalid ports')
    files=graph(main,base,allowed); main=str(Path(main).resolve()); changed={}
    for path,text in files.items():
        if path==main:
            need(text.count(START)==text.count(END) and text.count(START)<=1,'Broken SSH markers')
            if START in text:
                a=text.index(START); b=text.index(END); need(a<b,'Broken SSH markers')
                text=text[:a]+text[b+len(END):]
        lines=[]
        for line in text.splitlines(keepends=True):
            key,args=directive(line)
            if key=='permitrootlogin': line='PermitRootLogin no\n'
            elif key=='passwordauthentication': line='PasswordAuthentication yes\n'
            elif key=='authenticationmethods': line='AuthenticationMethods password\n'
            elif key=='port': line='# ubuntu-init original: '+line.rstrip()+'\n'
            elif key=='listenaddress':
                need(len(args)==1,'Complex ListenAddress refused')
                addr=args[0]
                if addr.startswith('['):
                    m=re.fullmatch(r'\[([^]]+)\](?::\d+)?',addr); need(m,'Invalid ListenAddress')
                    ipaddress.IPv6Address(m[1]); addr='['+m[1]+']'
                else:
                    if addr.count(':')==1:
                        addr,port=addr.rsplit(':',1); need(port.isdigit(),'Invalid ListenAddress port')
                    ipaddress.ip_address(addr)
                line='ListenAddress '+addr+'\n'
            lines.append(line)
        changed[path]=''.join(lines)
    changed[main]=(START+'PermitRootLogin no\nPasswordAuthentication yes\nAuthenticationMethods password\n'
                   +''.join('Port '+str(p)+'\n' for p in ports)+END+changed[main])
    snapshot(manifest,list(changed))
    for path,text in changed.items(): atomic(path,text)
    ssh_audit(main,base,allowed)

def ssh_audit(main,base='/etc/ssh',allowed='/etc'):
    files=graph(main,base,allowed)
    text=Path(main).read_text()
    need(text.startswith(START+'PermitRootLogin no\nPasswordAuthentication yes\nAuthenticationMethods password\n'),
         'Missing leading global SSH password/root policy')
    for path,text in files.items():
        for line in text.splitlines():
            key,args=directive(line)
            if key=='permitrootlogin': need(args==['no'],'Unsafe root policy: '+path)
            elif key=='passwordauthentication': need(args==['yes'],'Password login disabled: '+path)
            elif key=='authenticationmethods': need(args==['password'],'Unexpected authentication methods: '+path)
    print('SSH static audit passed:',len(files),'files; root login denied; password authentication required')

def password_account(username):
    need(username!='root','Use an existing ordinary account for SSH; root SSH stays disabled')
    account=pwd.getpwnam(username)
    need(account.pw_uid!=0,'SSH login account must not have UID 0')
    need(account.pw_shell and Path(account.pw_shell).name not in ('nologin','false')
         and os.access(account.pw_shell,os.X_OK),'SSH account has no executable login shell')
    # Read only; never print, save, or change password hashes.
    raw=subprocess.check_output(['getent','shadow',username],text=True)
    fields=raw.rstrip('\n').split(':')
    need(len(fields)==9 and fields[0]==username,'Cannot read local account password status')
    need(fields[1] and not fields[1].startswith(('!','*')),'SSH account password is empty or locked; set it before running')
    today=int(time.time()//86400)
    need(not fields[7] or int(fields[7])>today,'SSH account has expired')
    need(fields[2]!='0','SSH account requires an immediate password reset')
    if fields[2] and fields[4]:
        need(today<int(fields[2])+int(fields[4]),'SSH account password has expired')
    print('Existing SSH account/password status checked (read only):',username)

def effective(port,login_user):
    subprocess.run(['/usr/sbin/sshd','-t'],check=True)
    for user,addr,local in [('root','198.51.100.7','127.0.0.1'),('root','2001:db8::7','::1'),(login_user,'198.51.100.7','127.0.0.1')]:
        result=subprocess.check_output(['/usr/sbin/sshd','-T','-C',f'user={user},host=client.invalid,addr={addr},laddr={local},lport={port}'],text=True)
        values=dict(line.split(' ',1) for line in result.splitlines() if ' ' in line)
        need(values.get('permitrootlogin')=='no','Effective root policy is not no')
        if user==login_user:
            need(values.get('passwordauthentication')=='yes','Effective password authentication is disabled')
            need(values.get('authenticationmethods')=='password','Effective authentication does not permit password-only login')
            need(values.get('forcecommand')=='none' and values.get('chrootdirectory')=='none','Restricted SSH login account')
            need(not any(k in values for k in ('allowusers','denyusers','allowgroups','denygroups')),'Custom allow/deny policies need review')

def addresses(port):
    out=subprocess.check_output(['ss','-H','-ltn'],text=True); values=set()
    for line in out.splitlines():
        parts=line.split()
        if len(parts)<5: continue
        addr,_,p=parts[3].rpartition(':'); addr=addr.strip('[]')
        if p==str(port): values.add('127.0.0.1' if addr in ('*','0.0.0.0') else '::1' if addr=='::' else addr)
    need(values,'No TCP listener on '+str(port)); return sorted(values)

def local_ssh(port):
    out=subprocess.check_output(['/usr/sbin/sshd','-T'],text=True); expected=set()
    for line in out.splitlines():
        if line.startswith('hostkey '):
            key=line.split(' ',1)[1]; public=Path(key+'.pub')
            fields=(public.read_text() if public.exists() else subprocess.check_output(['ssh-keygen','-y','-f',key],text=True)).split()
            expected.add(tuple(fields[:2]))
    for addr in addresses(port):
        scan=subprocess.run(['ssh-keyscan','-T','5','-p',str(port),addr],capture_output=True,text=True)
        keys={tuple(l.split()[1:3]) for l in scan.stdout.splitlines() if not l.startswith('#') and len(l.split())>=3}
        need(expected&keys,'TCP listener is not the expected SSH server: '+addr)
    print('Local SSH handshake and host key verified on',port)

def successful_nodes(results,ip):
    good=[]
    for node,rows in results.items():
        if not isinstance(rows,list): continue
        for row in rows:
            if isinstance(row,dict) and 'error' not in row and isinstance(row.get('time'),(int,float)) and row['time']>=0:
                try:
                    if ipaddress.ip_address(row.get('address',''))==ipaddress.ip_address(ip): good.append(node)
                except ValueError: pass
    return sorted(set(good))

def probe(ip,port,record):
    addr=ipaddress.ip_address(ip); need(addr.is_global,'Need inbound public IP')
    host=f'[{ip}]:{port}' if addr.version==6 else f'{ip}:{port}'
    query=urllib.parse.urlencode({'host':host,'max_nodes':3})
    req=json.loads(get('https://check-host.net/check-tcp?'+query))
    rid=req.get('request_id',''); need(req.get('ok')==1 and re.fullmatch('[A-Za-z0-9_-]{1,100}',rid),'Probe service request failed')
    print('External report: https://check-host.net/check-report/'+rid,flush=True)
    for i in range(12):
        time.sleep(5)
        result=json.loads(get('https://check-host.net/check-result/'+rid)); good=successful_nodes(result,ip)
        atomic(record,json.dumps(dict(target=host,request_id=rid,good_nodes=good,results=result),indent=2),0o600)
        if good: print('EXTERNAL TCP VERIFIED:',', '.join(good),flush=True); return
        print('External TCP not yet verified',i+1,'/12',flush=True)
    raise RuntimeError('External TCP not verified; inspect cloud ACL, IP, NAT and local firewall')

def extract(archive,destination,top):
    dest=Path(destination); dest.mkdir(parents=True,exist_ok=True); need(not any(dest.iterdir()),'Nonempty extraction directory')
    with tarfile.open(archive) as tar:
        for m in tar.getmembers():
            name=posixpath.normpath(m.name)
            need((name==top or name.startswith(top+'/')) and '..' not in Path(m.name).parts,'Unsafe archive path')
            need(m.isfile() or m.isdir() or m.issym() or m.islnk(),'Special archive file refused')
            if m.issym() or m.islnk():
                need(not m.linkname.startswith('/'),'Absolute archive link refused')
                target=posixpath.normpath(posixpath.join(posixpath.dirname(name),m.linkname) if m.issym() else m.linkname)
                need(target==top or target.startswith(top+'/'),'Escaping archive link refused')
        if hasattr(tarfile,'data_filter'): tar.extractall(dest,filter='data')
        else: tar.extractall(dest)

def swaps():
    return json.loads(subprocess.check_output(['swapon','--show','--json','--bytes'],text=True)).get('swapdevices',[])

DOCKER_PACKAGES=('docker-ce','docker-ce-cli','containerd.io','docker-buildx-plugin','docker-compose-plugin')

def docker_sources_check(managed,apt_root='/etc/apt'):
    root=Path(apt_root); own=Path(managed)
    paths=[root/'sources.list',*sorted((root/'sources.list.d').glob('*.list')),
           *sorted((root/'sources.list.d').glob('*.sources'))]
    for path in paths:
        if not path.is_file(): continue
        active='\n'.join(line for line in path.read_text().splitlines() if not line.lstrip().startswith('#'))
        if path==own:
            if active.strip():
                uris=re.findall(r'(?im)^\s*URIs:\s*(.+)$',active)
                need(len(uris)==1 and uris[0].split()==['https://download.docker.com/linux/ubuntu'],
                     'Docker source path contains unrelated/complex sources; refusing overwrite: '+str(path))
            continue
        need(not re.search(r'https?://download\.docker\.com(?:/|\s|$)',active),
             'Existing Docker source needs consolidation before installation: '+str(path))

def docker_versions(codename,arch):
    need(re.fullmatch('[a-z][a-z0-9]*',codename),'Invalid Docker repository codename')
    need(arch in ('amd64','arm64'),'Unsupported Docker architecture')
    packages={}
    for package in DOCKER_PACKAGES:
        rows=subprocess.check_output(['apt-cache','madison',package],text=True)
        best=None
        for row in rows.splitlines():
            parts=[part.strip() for part in row.split('|')]
            if len(parts)!=3 or parts[0]!=package: continue
            origin=parts[2].split()
            if origin!=['https://download.docker.com/linux/ubuntu',codename+'/stable',arch,'Packages']: continue
            version=parts[1]
            need(re.fullmatch('[0-9A-Za-z.+:~_-]+',version),'Invalid Docker package version')
            if best is None: best=version; continue
            comparison=subprocess.run(['dpkg','--compare-versions',version,'gt',best],check=False)
            need(comparison.returncode in (0,1),'Cannot compare Docker package versions')
            if comparison.returncode==0: best=version
        need(best,'No official stable '+package+' package for '+codename+'/'+arch)
        packages[package]=best
    need(packages['docker-ce']==packages['docker-ce-cli'],'Docker Engine/CLI versions differ')
    return dict(codename=codename,architecture=arch,packages=packages)

def swap_plan(file):
    active=swaps(); old=set(); keep=[]
    for item in active:
        need(not item['name'].startswith(('/dev/zram','/dev/mapper/')),'zram/encrypted swap refused')
        if item['type']=='file': old.add(item['name'])
    for line in Path('/etc/fstab').read_text().splitlines(keepends=True):
        fields=shlex.split(line,comments=True)
        if len(fields)>=3 and fields[2]=='swap':
            need('\\' not in fields[0],'Escaped swap paths refused')
            if fields[0].startswith('/') and not fields[0].startswith('/dev/'): old.add(fields[0])
        else: keep.append(line)
    reclaim=0
    for name in old:
        p=Path(name); need(not p.is_symlink() and '\n' not in name,'Unsafe swap path')
        if not p.exists(): continue
        st=p.stat(); need(stat.S_ISREG(st.st_mode) and st.st_uid==0 and st.st_nlink==1,'Unsafe old swap file')
        with p.open('rb') as f: data=f.read(65536)
        need(any(data[n-10:n]==b'SWAPSPACE2' for n in (4096,8192,16384,32768,65536)),'Not a recognized swap file: '+name)
        reclaim+=st.st_blocks*512
    need(not Path('/swapfile').is_symlink(),'Refusing /swapfile symlink')
    need(not Path('/swapfile').exists() or '/swapfile' in old,'/swapfile exists but is not a recognized old swap')
    mem={m[1]:int(m[2])*1024 for m in re.finditer(r'(?m)^(MemAvailable|MemTotal):\s+(\d+)',Path('/proc/meminfo').read_text())}
    need(mem['MemAvailable']>sum(int(i.get('used',0)) for i in active)+max(128*1024**2,mem['MemTotal']//10),'Not enough available RAM for swapoff')
    atomic(file,json.dumps(dict(active=[i['name'] for i in active],old=sorted(old),fstab=''.join(keep),reclaim=reclaim),indent=2),0o600)

def main():
    cmd,*a=sys.argv[1:]
    if cmd=='resolve':
        data=resolve(*a[:3]); atomic(a[3],json.dumps(data,indent=2),0o600); print(json.dumps(data,ensure_ascii=False))
    elif cmd=='field':
        value=json.loads(Path(a[0]).read_text())[a[1]]; print('\n'.join(value) if isinstance(value,list) else value)
    elif cmd=='write': atomic(a[0],sys.stdin.buffer.read(),int(a[1],8) if len(a)>1 else None)
    elif cmd=='snapshot': snapshot(a[0],a[1:])
    elif cmd=='restore': restore(a[0])
    elif cmd=='ssh-apply': ssh_apply(*a)
    elif cmd=='ssh-audit': ssh_audit(*a)
    elif cmd=='ssh-effective': effective(*a)
    elif cmd=='password-account': password_account(a[0])
    elif cmd=='ssh-local': local_ssh(a[0])
    elif cmd=='ssh-address': print(addresses(a[0])[0])
    elif cmd=='probe': probe(*a)
    elif cmd=='public-ip': need(ipaddress.ip_address(a[0]).is_global,'Not a global IP')
    elif cmd=='extract': extract(*a)
    elif cmd=='swap-plan': swap_plan(a[0])
    elif cmd=='docker-sources-check': docker_sources_check(*a)
    elif cmd=='docker-versions':
        data=docker_versions(*a[:2]); atomic(a[2],json.dumps(data,indent=2),0o600)
        for package,version in data['packages'].items(): print(package+'='+version)
    elif cmd=='docker-install-args':
        for package,version in json.loads(Path(a[0]).read_text())['packages'].items(): print(package+'='+version)
    elif cmd=='swap-fstab':
        text=json.loads(Path(a[0]).read_text())['fstab'].rstrip()+'\n'
        if len(a)>1: text+='/swapfile none swap sw 0 0\n'
        atomic('/etc/fstab',text)
    elif cmd=='swap-verify':
        rows=swaps(); need(len(rows)==1 and rows[0]['name']=='/swapfile','Unexpected active swap')
        need(0<=int(a[0])*1024**2-int(rows[0]['size'])<=1024**2,'Swap size mismatch')
    elif cmd=='hash':
        digest=hashlib.sha256()
        with open(a[0],'rb') as f:
            for block in iter(lambda:f.read(1024**2),b''): digest.update(block)
        actual=digest.hexdigest(); print('SHA256',actual,a[0]); need(not a[1] or actual.lower()==a[1].lower(),'SHA256 MISMATCH')
    else: raise RuntimeError('Unknown helper command')

if __name__=='__main__':
    try: main()
    except Exception as exc: print('ERROR:',exc,file=sys.stderr); sys.exit(1)
PY_EMBEDDED_HELPER
chmod 0600 "$HELPER"
}

cleanup() {
    local code=$?
    trap - EXIT
    if [[ -n ${WORK:-} && -d $WORK ]]; then
        if ((code==0 && FAILURES==0)); then rm -rf -- "$WORK"
        else log WARN "失败现场保留在 $WORK，排查后可删除"; fi
    fi
}
main() {
    if [[ ${1:-} == --help || ${1:-} == -h ]]; then help_text; return; fi
    [[ $# == 0 ]] || { printf '未知参数；使用 --help。\n' >&2; exit 1; }
    ((EUID==0)) || { printf '必须以 root 执行，已退出。\n' >&2; exit 1; }
    [[ -r /etc/os-release ]] || { printf '缺少 /etc/os-release\n' >&2; exit 1; }
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ $ID == ubuntu && $VERSION_ID =~ ^(22\.04|24\.04|26\.04)$ ]] || { printf '支持 Ubuntu 22.04/24.04/26.04 LTS。\n' >&2; exit 1; }
    [[ $(cat /proc/1/comm) == systemd ]] || { printf '需要真实 systemd 服务器；拒绝容器/chroot。\n' >&2; exit 1; }
    ARCH=$(dpkg --print-architecture)
    [[ $ARCH == amd64 || $ARCH == arm64 ]] || { printf '仅支持 amd64/arm64。\n' >&2; exit 1; }
    exec 9>/run/lock/ubuntu-init.lock
    flock -n 9 || { printf '已有初始化脚本运行。\n' >&2; exit 1; }
    exec 3<>/dev/tty || { printf '需要交互终端填写问卷。\n' >&2; exit 1; }
    questionnaire
    RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)-$$
    RUN=/var/log/ubuntu-init/$RUN_ID; BACKUP=/var/backups/ubuntu-init/$RUN_ID
    install -d -m 0700 "$RUN" "$BACKUP" || exit 1
    : >"$RUN/run.log" || exit 1
    WORK=$(mktemp -d /var/tmp/ubuntu-init.XXXXXXXX) || exit 1
    HELPER=$WORK/helper.py
    exec 7>&1 8>&2
    exec > >(tee -a "$RUN/run.log") 2>&1
    LOG_PID=$!
    trap cleanup EXIT
    trap 'log FAIL "收到中断，请检查日志及 SSH 连接"; exit 130' INT TERM
    log INFO "Ubuntu $VERSION_ID / $ARCH；日志 $RUN；备份 $BACKUP"
    run_module bootstrap 1 bootstrap
    if [[ ${STATUS[bootstrap]} != OK ]]; then log FAIL '引导依赖失败，停止执行'; exit 1; fi
    run_module upgrade "$((UPGRADE>0))" upgrade bootstrap
    run_module python_version "$PYTHON" resolve_python bootstrap
    run_module node_version "$NODE" resolve_node bootstrap
    run_module rust_version "$RUST" resolve_rust bootstrap
    run_module axel_version "$AXEL" resolve_axel bootstrap
    run_module swap "$SWAP" swap_module bootstrap
    run_module essential "$ESSENTIAL" essential bootstrap
    run_module supervisor "$SUPERVISOR" supervisor bootstrap
    run_module redis_tools "$REDIS" redis bootstrap
    run_module docker "$DOCKER" docker_module bootstrap
    run_module python "$PYTHON" python_module 'bootstrap python_version'
    run_module python_packages "$PYEXTRAS" python_extras python
    run_module node "$NODE" node_module 'bootstrap node_version'
    run_module rust "$RUST" rust_module 'bootstrap rust_version'
    run_module axel "$AXEL" axel_module 'bootstrap axel_version'
    run_module time_sync "$TIME" time_module bootstrap
    run_module journal "$JOURNAL" journal_module bootstrap
    run_module bbr "$BBR" bbr_module bootstrap
    run_module core_dump "$CORE" core_module bootstrap
    run_module ssh "$SSH" ssh_module bootstrap
    run_module fail2ban "$F2B" fail2ban_module bootstrap
    run_module final_audit 1 final_audit bootstrap
    printf '\n%-20s %s\n' MODULE RESULT | tee "$RUN/summary.txt"
    local name code=0
    for name in "${MODULES[@]}"; do printf '%-20s %s\n' "$name" "${STATUS[$name]}"; done | tee -a "$RUN/summary.txt"
    log INFO "日志：$RUN/run.log；配置备份：$BACKUP/config.json 和 ssh.json（如已生成）"
    if [[ -f $RUN/ssh-ports.txt ]]; then log INFO "已核对的 SSH 端口：$(cat "$RUN/ssh-ports.txt")；保持当前连接，另开终端验证 $LOGIN_USER 的密码登录；管理时使用 su -"; fi
    ((FAILURES==0)) || code=1
    if [[ ${STATUS[ssh]:-} == UNVERIFIED && $FAILURES == 1 ]]; then code=2; fi
    exec 1>&7 2>&8
    if ! wait "$LOG_PID"; then printf '日志写入失败。\n' >&2; code=1; fi
    exit "$code"
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
