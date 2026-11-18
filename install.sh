#!/usr/bin/env bash
# AnyTLS interactive installer. Requires a saved file, Bash, root and systemd.
set -Eeuo pipefail
umask 077

APP_DIR=/opt/anytls-node
CONFIG_DIR=/etc/anytls-node
STATE_DIR=/var/lib/anytls-node
ACME_DIR=$STATE_DIR/letsencrypt
UNIT=anytls-node.service
TIMER=anytls-node-renew.timer
CERT_NAME=anytls-ip
CERTBOT_VERSION=5.10.0
SCRIPT_VERSION=1.0.0
TMP_DIR=
INSTALL_STARTED=0
INSTALL_OK=0
NEW_SERVICE=0

info() { printf '\n%s\n' "$*"; }
die() { printf '\n错误：%s\n' "$*" >&2; exit 1; }

cleanup() {
    local rc=$?
    [[ -z ${TMP_DIR:-} ]] || rm -rf -- "$TMP_DIR"
    if (( rc != 0 && INSTALL_STARTED && ! INSTALL_OK )); then
        printf '\n安装未完成；已签发的证书会保留，重新运行可继续。\n' >&2
        if (( NEW_SERVICE )); then
            systemctl disable --now "$UNIT" "$TIMER" >/dev/null 2>&1 || true
            rm -f "$CONFIG_DIR/installed.json"
        fi
    fi
}

ask() {
    local _variable=$1 _message=$2 _default=${3:-} _answer
    printf '%s' "$_message" >&3
    if [[ -n $_default ]]; then printf ' [%s]' "$_default" >&3; fi
    printf '：' >&3
    IFS= read -r _answer <&3 || die '交互输入已结束。'
    printf -v "$_variable" '%s' "${_answer:-$_default}"
}

confirm() {
    local answer default=${2:-n} hint='y/N'
    [[ $default != y ]] || hint='Y/n'
    ask answer "$1 ($hint)" "$default"
    [[ $answer == [yY] || $answer == [yY][eE][sS] ]]
}

require_root() {
    (( EUID == 0 )) || die '请使用 sudo bash install.sh 或以 root 运行。'
}

check_os() {
    [[ -f /etc/os-release ]] || die '找不到系统版本信息。'
    # shellcheck source=/dev/null
    . /etc/os-release
    case "$ID:${VERSION_ID%%.*}" in
        debian:12|debian:13|ubuntu:22|ubuntu:24) ;;
        *) die '当前仅支持 Debian 12/13、Ubuntu 22.04/24.04。' ;;
    esac
    [[ -d /run/systemd/system ]] || die '需要正在运行的 systemd；不支持普通 Docker 容器。'
    case "$(uname -m)" in
        x86_64) ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        *) die '当前仅支持 x86_64 与 ARM64。' ;;
    esac
}

install_dependencies() {
    info '安装系统依赖……'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends ca-certificates curl openssl \
        python3 python3-venv iproute2 kmod tar util-linux
}

valid_ip() {
    python3 - "$1" <<'PY'
import ipaddress, sys
try:
    ip = ipaddress.ip_address(sys.argv[1])
    valid = ip.version == 4 and ip.is_global and not ip.is_multicast
except ValueError:
    valid = False
sys.exit(0 if valid else 1)
PY
}

valid_port() {
    [[ $1 =~ ^[0-9]{1,5}$ ]] || return 1
    local number=$((10#$1))
    (( number >= 1 && number <= 65535 && number != 80 ))
}

check_port() {
    local output
    output=$(ss -H -ltn "sport = :$1")
    [[ -z $output ]] || die "TCP $1 已被占用。请释放该端口后重试；脚本不会停止已有服务。"
}

collect_options() {
    local detected second
    detected=$(curl -4 -fsS --connect-timeout 5 --max-time 8 https://api.ipify.org || true)
    valid_ip "$detected" || detected=
    while :; do
        ask PUBLIC_IP '服务器公网 IPv4（NAT 机器填写公网入口 IP）' "$detected"
        valid_ip "$PUBLIC_IP" && break
        info '请输入有效的公网 IPv4 地址。'
    done
    while :; do
        ask PORT 'AnyTLS TCP 端口（1–65535，80 留给证书验证）' 443
        if valid_port "$PORT"; then PORT=$((10#$PORT)); break; fi
        info '端口无效，或选择了证书验证使用的 80。'
    done
    check_port "$PORT"
    check_port 80
    ask NODE_NAME '节点名称' AnyTLS
    [[ ${#NODE_NAME} -le 80 ]] || die '节点名称最多 80 个字符。'
    while :; do
        printf '节点密码（留空自动生成；输入不回显）：' >&3
        IFS= read -rs PASSWORD <&3 || die '交互输入已结束。'
        printf '\n' >&3
        if [[ -z $PASSWORD ]]; then
            PASSWORD=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
            break
        fi
        [[ ${#PASSWORD} -ge 16 ]] || { info '自定义密码至少需要 16 个字符。'; continue; }
        printf '再次输入密码：' >&3
        IFS= read -rs second <&3 || die '交互输入已结束。'
        printf '\n' >&3
        [[ $PASSWORD == "$second" ]] && break
        info '两次密码不一致，请重试。'
    done
    ask EMAIL '证书账户联系邮箱（可留空）' ''
    if [[ -n $EMAIL && ! $EMAIL =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
        die '邮箱格式不正确。'
    fi
    ENABLE_BBR=0
    if confirm '是否开启 TCP BBR + FQ（全局 TCP 设置，已建立连接不变）' y; then ENABLE_BBR=1; fi
    info "将安装：$NODE_NAME，$PUBLIC_IP:$PORT，证书采用 Let’s Encrypt 公网 IPv4 证书。"
    printf '\n请确保云安全组、主机防火墙和 NAT 允许入站 TCP 80、TCP %s。\n证书续期仍需 TCP 80 可达且空闲，脚本不会自动修改防火墙。\n' "$PORT"
    info "继续表示接受 Let's Encrypt 服务条款：https://letsencrypt.org/repository/"
    confirm '确认开始安装' || die '已取消安装。'
    # Keep secret data out of command-line arguments and shell tracing.
    export PUBLIC_IP PORT NODE_NAME PASSWORD
}

fetch_sing_box() {
    info '从 SagerNet 官方 GitHub 下载最新稳定版并核验 SHA-256……'
    curl -4 -fLsS --retry 2 --connect-timeout 10 --max-time 45 \
        https://api.github.com/repos/SagerNet/sing-box/releases/latest -o "$TMP_DIR/release.json"
    python3 - "$TMP_DIR/release.json" "$ARCH" > "$TMP_DIR/asset" <<'PY'
import json, re, sys
release = json.load(open(sys.argv[1]))
version = release['tag_name'].removeprefix('v')
if release.get('prerelease') or not re.fullmatch(r'\d+\.\d+\.\d+', version):
    raise SystemExit('拒绝非稳定版本。')
if tuple(map(int, version.split('.'))) < (1, 12, 0):
    raise SystemExit('sing-box 版本不支持 AnyTLS。')
name = f'sing-box-{version}-linux-{sys.argv[2]}.tar.gz'
asset = next(a for a in release['assets'] if a['name'] == name)
url, digest = asset['browser_download_url'], asset.get('digest', '')
if not url.startswith('https://github.com/SagerNet/sing-box/releases/download/'):
    raise SystemExit('下载来源不是官方仓库。')
if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
    raise SystemExit('官方发布缺少 SHA-256 digest；停止安装。')
print(version)
print(url)
print(digest.split(':', 1)[1])
PY
    local -a asset
    mapfile -t asset < "$TMP_DIR/asset"
    SING_BOX_VERSION=${asset[0]}
    curl -4 -fLsS --retry 2 --connect-timeout 15 --max-time 180 "${asset[1]}" -o "$TMP_DIR/sing-box.tar.gz"
    printf '%s  %s\n' "${asset[2]}" "$TMP_DIR/sing-box.tar.gz" | sha256sum -c -
    tar -xzf "$TMP_DIR/sing-box.tar.gz" -C "$TMP_DIR" \
        "sing-box-$SING_BOX_VERSION-linux-$ARCH/sing-box"
    install -d -m 0755 "$APP_DIR"
    install -m 0755 "$TMP_DIR/sing-box-$SING_BOX_VERSION-linux-$ARCH/sing-box" "$APP_DIR/sing-box"
}

install_certbot() {
    info "安装独立 Certbot $CERTBOT_VERSION 环境……"
    python3 -m venv "$APP_DIR/venv"
    # Some VPS have broken IPv6. Restrict this process, not the entire host.
    "$APP_DIR/venv/bin/python" - "$CERTBOT_VERSION" <<'PY'
import runpy, socket, sys
version = sys.argv[1]
original = socket.getaddrinfo
def ipv4(host, port, family=0, type=0, proto=0, flags=0):
    if family == socket.AF_UNSPEC and host is not None:
        family = socket.AF_INET
    return original(host, port, family, type, proto, flags)
socket.getaddrinfo = ipv4
sys.argv = ['pip', 'install', '--disable-pip-version-check', '--index-url',
            'https://pypi.org/simple', f'certbot=={version}']
runpy.run_module('pip', run_name='__main__')
PY
    cat > "$APP_DIR/certbot" <<'PY'
#!/opt/anytls-node/venv/bin/python
import socket
from certbot.main import main
original = socket.getaddrinfo
def ipv4(host, port, family=0, type=0, proto=0, flags=0):
    if family == socket.AF_UNSPEC and host is not None:
        family = socket.AF_INET
    return original(host, port, family, type, proto, flags)
socket.getaddrinfo = ipv4
raise SystemExit(main())
PY
    chmod 0755 "$APP_DIR/certbot"
}

certbot_cmd() {
    "$APP_DIR/certbot" "$@" --config-dir "$ACME_DIR" \
        --work-dir "$STATE_DIR/acme-work" --logs-dir "$STATE_DIR/acme-logs"
}

issue_certificate() {
    local -a email_args
    if [[ -n $EMAIL ]]; then email_args=(--email "$EMAIL"); else email_args=(--register-unsafely-without-email); fi
    info '申请受信任的 IP 证书（首次安装不会停止其他服务）……'
    if ! certbot_cmd certonly --standalone --non-interactive --agree-tos \
        "${email_args[@]}" --ip-address "$PUBLIC_IP" --required-profile shortlived \
        --cert-name "$CERT_NAME" --key-type ecdsa --preferred-challenges http \
        --http-01-address 0.0.0.0 --keep-until-expiring; then
        die '签发失败。请核对公网 IPv4、TCP 80 的云安全组／防火墙／NAT，以及是否触发 CA 频率限制。没有安装自签名替代证书，可修正后重跑。'
    fi
    openssl verify -CApath /etc/ssl/certs \
        -untrusted "$ACME_DIR/live/$CERT_NAME/chain.pem" \
        -verify_ip "$PUBLIC_IP" "$ACME_DIR/live/$CERT_NAME/cert.pem"
}

prepare_account() {
    if ! id anytls-node >/dev/null 2>&1; then
        useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin anytls-node
    fi
    [[ $(id -u anytls-node) != 0 ]] || die 'anytls-node 账户 UID 异常。'
    install -d -m 0750 -o root -g anytls-node "$CONFIG_DIR"
    install -d -m 0700 "$STATE_DIR"
}

write_config() {
    python3 - "$CONFIG_DIR/config.json" <<'PY'
import json, os, sys
config = {
    'log': {'level': 'warn', 'timestamp': True},
    'inbounds': [{'type': 'anytls', 'tag': 'anytls-in', 'listen': '0.0.0.0',
                  'listen_port': int(os.environ['PORT']),
                  'users': [{'name': 'owner', 'password': os.environ['PASSWORD']}],
                  'tls': {'enabled': True, 'min_version': '1.2',
                          'certificate_path': '/etc/anytls-node/server.crt',
                          'key_path': '/etc/anytls-node/server.key'}}],
    'outbounds': [{'type': 'direct', 'tag': 'direct'}]
}
with open(sys.argv[1], 'w') as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
    chown root:anytls-node "$CONFIG_DIR/config.json"
    chmod 0640 "$CONFIG_DIR/config.json"
}

install_deploy_hook() {
    install -d -m 0700 "$ACME_DIR/renewal-hooks/deploy"
    cat > "$ACME_DIR/renewal-hooks/deploy/50-anytls" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
expected=/var/lib/anytls-node/letsencrypt/live/anytls-ip
lineage=${RENEWED_LINEAGE:-$expected}
[[ $lineage == "$expected" ]] || exit 0
config=/etc/anytls-node
openssl x509 -in "$lineage/fullchain.pem" -noout -checkend 86400 >/dev/null
cert_key=$(openssl x509 -in "$lineage/cert.pem" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum)
private_key=$(openssl pkey -in "$lineage/privkey.pem" -pubout -outform DER | sha256sum)
[[ $cert_key == "$private_key" ]] || { echo '证书私钥不匹配' >&2; exit 1; }
# Also called after each renewal check: reconcile a prior failed deployment,
# without restarting the service when the installed certificate is unchanged.
if cmp -s "$lineage/fullchain.pem" "$config/server.crt" && cmp -s "$lineage/privkey.pem" "$config/server.key"; then
    exit 0
fi
backup=$(mktemp -d "$config/.cert-backup.XXXXXX")
had_old=0
if [[ -f $config/server.crt && -f $config/server.key ]]; then
    cp -p "$config/server.crt" "$config/server.key" "$backup/"
    had_old=1
fi
restore() {
    rc=$?
    if (( rc != 0 && had_old )); then
        cp -p "$backup/server.crt" "$backup/server.key" "$config/"
        systemctl try-restart anytls-node.service || true
    fi
    rm -rf "$backup"
    rm -f "$config/server.crt.new" "$config/server.key.new"
    exit "$rc"
}
trap restore EXIT
install -m 0640 -o root -g anytls-node "$lineage/fullchain.pem" "$config/server.crt.new"
install -m 0640 -o root -g anytls-node "$lineage/privkey.pem" "$config/server.key.new"
mv "$config/server.key.new" "$config/server.key"
mv "$config/server.crt.new" "$config/server.crt"
/opt/anytls-node/sing-box check -c "$config/config.json"
# First installation starts the service later; renewal restarts the active service.
if systemctl is-active --quiet anytls-node.service; then
    systemctl restart anytls-node.service
    sleep 1
    systemctl is-active --quiet anytls-node.service
fi
SH
    chmod 0700 "$ACME_DIR/renewal-hooks/deploy/50-anytls"
    "$ACME_DIR/renewal-hooks/deploy/50-anytls"
}

install_units() {
    cat > /etc/systemd/system/anytls-node.service <<'UNITFILE'
[Unit]
Description=AnyTLS node (sing-box)
After=network-online.target
Wants=network-online.target

[Service]
User=anytls-node
Group=anytls-node
ExecStart=/opt/anytls-node/sing-box run -c /etc/anytls-node/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
UMask=0077

[Install]
WantedBy=multi-user.target
UNITFILE
    cat > /etc/systemd/system/anytls-node-renew.service <<'UNITFILE'
[Unit]
Description=Renew AnyTLS IP certificate
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/anytls-node/certbot renew --non-interactive --quiet --no-random-sleep-on-renew --config-dir /var/lib/anytls-node/letsencrypt --work-dir /var/lib/anytls-node/acme-work --logs-dir /var/lib/anytls-node/acme-logs
ExecStartPost=/var/lib/anytls-node/letsencrypt/renewal-hooks/deploy/50-anytls
TimeoutStartSec=600
UMask=0077
UNITFILE
    cat > /etc/systemd/system/anytls-node-renew.timer <<'UNITFILE'
[Unit]
Description=Check AnyTLS certificate renewal twice daily

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
UNITFILE
    chmod 0644 /etc/systemd/system/anytls-node{,-renew}.service /etc/systemd/system/anytls-node-renew.timer
    systemctl daemon-reload
    NEW_SERVICE=1
    systemctl enable --now "$UNIT" "$TIMER"
}

enable_bbr() {
    (( ENABLE_BBR )) || return 0
    info '配置 TCP BBR + FQ……'
    # Module load may fail when the feature is compiled into the kernel.
    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true
    if ! sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
        info '当前内核不支持 BBR，保留原拥塞控制算法。AnyTLS 仍可使用。'
        return 0
    fi
    install -d -m 0755 /etc/sysctl.d /etc/modules-load.d
    printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > /etc/sysctl.d/99-zz-anytls-node-bbr.conf
    printf 'tcp_bbr\nsch_fq\n' > /etc/modules-load.d/anytls-node-bbr.conf
    chmod 0644 /etc/sysctl.d/99-zz-anytls-node-bbr.conf /etc/modules-load.d/anytls-node-bbr.conf
    sysctl -p /etc/sysctl.d/99-zz-anytls-node-bbr.conf
    local iface qdisc
    iface=$(ip -4 route show default | awk 'NR==1 {print $5}')
    if [[ -n $iface ]]; then
        qdisc=$(tc qdisc show dev "$iface")
        if [[ $qdisc =~ qdisc\ (fq_codel|pfifo_fast|fq)\ .*root ]]; then
            tc qdisc replace dev "$iface" root fq || info '未能替换当前队列，默认 FQ 将在网卡重新创建时使用。'
        else
            info '网卡使用自定义或多队列调度，保留现有队列；默认 FQ 已设置。'
        fi
    fi
}

verify_local() {
    local tries
    for ((tries=0; tries<20; tries++)); do
        if systemctl is-active --quiet "$UNIT" && [[ -n $(ss -H -ltn "sport = :$PORT") ]]; then break; fi
        sleep 0.5
    done
    systemctl is-active --quiet "$UNIT" || die 'AnyTLS 未能启动，请从“检查状态”查看服务情况。'
    # Local validation proves TLS identity, not public firewall reachability.
    python3 - "$PUBLIC_IP" "$PORT" <<'PY'
import socket, ssl, sys
with socket.create_connection(('127.0.0.1', int(sys.argv[2])), timeout=10) as tcp:
    with ssl.create_default_context().wrap_socket(tcp, server_hostname=sys.argv[1]) as tls:
        print('证书链和 IP 身份验证通过：', tls.version())
PY
}

save_state() {
    export SING_BOX_VERSION
    python3 - "$CONFIG_DIR/installed.json" <<'PY'
import json, os, sys
with open(sys.argv[1], 'w') as f:
    json.dump({'ip': os.environ['PUBLIC_IP'], 'port': int(os.environ['PORT']),
               'name': os.environ['NODE_NAME'], 'sing_box_version': os.environ['SING_BOX_VERSION']},
              f, ensure_ascii=False, indent=2)
    f.write('\n')
PY
    chmod 0600 "$CONFIG_DIR/installed.json"
}

require_install() {
    [[ -f $CONFIG_DIR/installed.json ]] || die '还没有成功完成安装，请先选择安装。'
}

show_node() {
    require_install
    python3 - "$CONFIG_DIR" <<'PY'
import json, pathlib, sys, urllib.parse
p = pathlib.Path(sys.argv[1])
s = json.loads((p/'installed.json').read_text())
c = json.loads((p/'config.json').read_text())
password = c['inbounds'][0]['users'][0]['password']
uri = 'anytls://{}@{}:{}/?{}#{}'.format(
    urllib.parse.quote(password, safe=''), s['ip'], s['port'],
    urllib.parse.urlencode({'sni': s['ip'], 'insecure': '0'}),
    urllib.parse.quote(s['name'], safe=''))
print('\n节点名称：', s['name'])
print('地址：', s['ip'])
print('端口：', s['port'])
print('SNI：', s['ip'])
print('跳过证书验证：关闭')
print('\n导入链接（含密码，请妥善保存）：\n' + uri)
proxy = {'name': s['name'], 'type': 'anytls', 'server': s['ip'], 'port': s['port'],
         'password': password, 'sni': s['ip'], 'skip-cert-verify': False}
print('\nMihomo / Clash Meta 的 proxies 列表条目（需要支持 AnyTLS 的版本）：')
print('  - ' + json.dumps(proxy, ensure_ascii=False))
PY
}

show_status() {
    require_install
    systemctl --no-pager --full status "$UNIT" "$TIMER" || true
    systemctl list-timers "$TIMER" --no-pager
    openssl x509 -in "$CONFIG_DIR/server.crt" -noout -issuer -dates -ext subjectAltName
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
    info '最近续期任务结果：'
    systemctl show anytls-node-renew.service -p Result -p ExecMainStatus
}

test_renewal() {
    require_install
    check_port 80
    info "在 Let's Encrypt 测试环境验证续期，不替换现用证书……"
    certbot_cmd renew --dry-run --non-interactive --no-random-sleep-on-renew
}

renew_now() {
    require_install
    info '检查续期（未到续期窗口时不会重复签发）……'
    systemctl start anytls-node-renew.service
    systemctl show anytls-node-renew.service -p Result -p ExecMainStatus
}

install_node() {
    if [[ -f $CONFIG_DIR/installed.json ]]; then
        info '已安装，保留现有密码、证书与配置。'
        show_node
        return
    fi
    # Never overwrite an unmarked active installation or an unrelated unit.
    if systemctl is-active --quiet "$UNIT"; then die '存在未登记的同名服务，请先核对。'; fi
    if [[ -e /etc/systemd/system/$UNIT ]] && ! grep -q '/opt/anytls-node/sing-box' "/etc/systemd/system/$UNIT"; then
        die '存在其他程序创建的同名服务，停止安装。'
    fi
    check_os
    install_dependencies
    collect_options
    INSTALL_STARTED=1
    TMP_DIR=$(mktemp -d)
    fetch_sing_box
    install_certbot
    prepare_account
    issue_certificate
    write_config
    install_deploy_hook
    enable_bbr
    install_units
    verify_local
    save_state
    INSTALL_OK=1
    unset PASSWORD
    # Save the management entrypoint when run from a real file.
    if [[ -f ${BASH_SOURCE[0]} && ${BASH_SOURCE[0]} != /dev/* ]]; then
        if [[ $(readlink -f "${BASH_SOURCE[0]}") != /usr/local/sbin/anytls ]]; then
            install -m 0700 "${BASH_SOURCE[0]}" /usr/local/sbin/anytls
        fi
    fi
    info '安装完成，服务与证书续期定时器已开机自启。'
    if (( ENABLE_BBR )); then
        info "当前 TCP 算法：$(sysctl -n net.ipv4.tcp_congestion_control)；默认队列：$(sysctl -n net.core.default_qdisc)"
    fi
    info '已验证服务器本机 TLS；请用客户端确认公网连接，云端端口是否放通需要外部测试。'
    show_node
    if confirm '现在执行一次证书自动续期演练'; then test_renewal; fi
}

main() {
    case ${1:-} in
        -h|--help)
            printf 'AnyTLS 交互式安装器 %s\n运行：sudo bash install.sh\n已安装后：sudo anytls\n支持 Debian 12/13、Ubuntu 22.04/24.04，x86_64/ARM64，公网 IPv4。\n' "$SCRIPT_VERSION"
            return ;;
        '') ;;
        *) die '未知参数；使用 --help 查看说明。' ;;
    esac
    require_root
    exec 3<>/dev/tty || die '需要交互终端；请下载脚本后在 SSH 终端运行。'
    install -d -m 0755 /run/lock
    exec 9>/run/lock/anytls-node-installer.lock
    flock -n 9 || die '另一个安装或管理进程正在运行。'
    trap cleanup EXIT
    trap 'printf "\n执行失败（第 %s 行），请根据上方信息修正后重试。\n" "$LINENO" >&2' ERR
    trap 'exit 130' INT
    trap 'exit 143' TERM
    info "AnyTLS 交互式安装器 $SCRIPT_VERSION"
    printf '\n1. 安装 AnyTLS（已有安装则显示节点）\n2. 显示节点及客户端配置\n3. 检查服务、证书和续期状态\n4. 测试自动续期（不替换现用证书）\n5. 检查并执行到期续期\n0. 退出\n\n'
    local choice
    ask choice '请选择' 1
    case $choice in
        1) install_node ;;
        2) show_node ;;
        3) show_status ;;
        4) test_renewal ;;
        5) renew_now ;;
        0) return ;;
        *) die '无效选项。' ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
