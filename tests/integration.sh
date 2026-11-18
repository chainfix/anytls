#!/usr/bin/env bash
# Destructive only inside the disposable test container.
set -Eeuo pipefail
[[ -e /.dockerenv ]] || { echo 'Run only in a disposable Docker container.' >&2; exit 1; }
cd /src
bash -n install.sh
shellcheck install.sh tests/*.sh
bash tests/unit.sh
# shellcheck source=install.sh
source ./install.sh
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
ARCH=$(dpkg --print-architecture)
fetch_sing_box
prepare_account
install_certbot
"$APP_DIR/certbot" --help all > "$TMP_DIR/certbot-help"
grep -q -- --ip-address "$TMP_DIR/certbot-help"
PUBLIC_IP=1.1.1.1
PORT=18443
NODE_NAME='测试 node @ #'
PASSWORD='fixture-password-@:/?#-long-enough'
export PUBLIC_IP PORT NODE_NAME PASSWORD
write_config

# Real trust validation and real AnyTLS, using a test-only CA in this container.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$TMP_DIR/ca.key" -out "$TMP_DIR/ca.crt" -days 10 \
    -subj /CN=AnyTLS-Integration-CA >/dev/null 2>&1
install -m 0644 "$TMP_DIR/ca.crt" /usr/local/share/ca-certificates/anytls-test.crt
update-ca-certificates >/dev/null 2>&1
lineage=$ACME_DIR/live/$CERT_NAME
mkdir -p "$lineage"
issue_fixture() {
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -keyout "$lineage/privkey.pem" -out "$TMP_DIR/server.csr" \
        -subj /CN=AnyTLS-test >/dev/null 2>&1
    printf 'subjectAltName=IP:1.1.1.1\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' > "$TMP_DIR/ext"
    openssl x509 -req -in "$TMP_DIR/server.csr" -CA "$TMP_DIR/ca.crt" \
        -CAkey "$TMP_DIR/ca.key" -set_serial "$1" -days 3 \
        -extfile "$TMP_DIR/ext" -out "$lineage/cert.pem" >/dev/null 2>&1
    cp "$TMP_DIR/ca.crt" "$lineage/chain.pem"
    cat "$lineage/cert.pem" "$lineage/chain.pem" > "$lineage/fullchain.pem"
}
issue_fixture 1

# An explicit test double replaces systemd, not the proxy or TLS stack.
cat > /usr/local/bin/systemctl <<'SH'
#!/usr/bin/env bash
set -eu
active() {
    [[ -f /run/anytls-test.pid ]] || return 1
    local pid
    pid=$(< /run/anytls-test.pid)
    kill -0 "$pid" 2>/dev/null && [[ $(awk '{print $3}' "/proc/$pid/stat") != Z ]]
}
stop_service() {
    if active; then kill "$(< /run/anytls-test.pid)"; sleep 0.3; fi
    rm -f /run/anytls-test.pid
}
start_service() {
    if [[ -f /run/anytls-fail-next-start ]]; then rm -f /run/anytls-fail-next-start; return 1; fi
    nohup setpriv --reuid anytls-node --regid anytls-node --init-groups \
        /opt/anytls-node/sing-box run -c /etc/anytls-node/config.json \
        >> /run/anytls-test.log 2>&1 </dev/null &
    echo $! > /run/anytls-test.pid
    sleep 0.3
    active
}
case $1 in
    is-active) active ;;
    daemon-reload) : ;;
    enable) start_service ;;
    restart|try-restart) stop_service; start_service ;;
    disable|stop) stop_service ;;
    *) echo "Unexpected test systemctl: $*" >&2; exit 1 ;;
esac
SH
chmod 0755 /usr/local/bin/systemctl
install_deploy_hook
install_units
verify_local
save_state
show_node > "$TMP_DIR/node-output"
grep -q 'insecure=0' "$TMP_DIR/node-output"
[[ $(stat -c %a "$CONFIG_DIR/server.key") == 640 ]]
[[ $(stat -c %G "$CONFIG_DIR/server.key") == anytls-node ]]
[[ $(stat -c %a "$CONFIG_DIR/config.json") == 640 ]]
[[ $(stat -c %a "$CONFIG_DIR/installed.json") == 600 ]]
[[ $(ps -o user= -p "$(< /run/anytls-test.pid)" | xargs) == anytls-node ]]
systemd-analyze verify /etc/systemd/system/anytls-node{,-renew}.service /etc/systemd/system/anytls-node-renew.timer

grep -q -- '--no-random-sleep-on-renew' /etc/systemd/system/anytls-node-renew.service
grep -q '00,12:00:00' /etc/systemd/system/anytls-node-renew.timer

# End-to-end TCP request through the actual AnyTLS protocol with strict TLS.
mkdir "$TMP_DIR/web"
printf 'anytls-end-to-end-ok' > "$TMP_DIR/web/result"
python3 -m http.server 19090 --bind 127.0.0.1 --directory "$TMP_DIR/web" > "$TMP_DIR/http.log" 2>&1 &
http_pid=$!
python3 - "$TMP_DIR/client.json" <<'PY'
import json, os, sys
c = {'log': {'level': 'warn'},
     'inbounds': [{'type': 'mixed', 'listen': '127.0.0.1', 'listen_port': 19080}],
     'outbounds': [{'type': 'anytls', 'server': '127.0.0.1', 'server_port': 18443,
                    'password': os.environ['PASSWORD'],
                    'tls': {'enabled': True, 'server_name': '1.1.1.1', 'insecure': False}}]}
with open(sys.argv[1], 'w') as f: json.dump(c, f)
PY
"$APP_DIR/sing-box" run -c "$TMP_DIR/client.json" > "$TMP_DIR/client.log" 2>&1 &
client_pid=$!
sleep 0.5
result=$(curl --noproxy '' -fsS --max-time 10 --proxy socks5h://127.0.0.1:19080 http://127.0.0.1:19090/result)
[[ $result == anytls-end-to-end-ok ]]
kill "$client_pid"
wait "$client_pid" || true
python3 - "$TMP_DIR/client.json" <<'PY'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c['outbounds'][0]['password'] = 'wrong-password'
with open(p, 'w') as f: json.dump(c, f)
PY
"$APP_DIR/sing-box" run -c "$TMP_DIR/client.json" > "$TMP_DIR/client.log" 2>&1 &
client_pid=$!
sleep 0.5
if curl --noproxy '' -fsS --max-time 4 --proxy socks5h://127.0.0.1:19080 http://127.0.0.1:19090/result >/dev/null 2>&1; then
    echo 'Wrong password was accepted!' >&2; exit 1
fi
kill "$client_pid" "$http_pid"
wait "$client_pid" || true
wait "$http_pid" || true

# Successful renewal deployment, then rollback on a failed service restart.
issue_fixture 2
"$ACME_DIR/renewal-hooks/deploy/50-anytls"
[[ $(openssl x509 -in "$CONFIG_DIR/server.crt" -noout -serial) == serial=02 ]]
verify_local
issue_fixture 3
touch /run/anytls-fail-next-start
if "$ACME_DIR/renewal-hooks/deploy/50-anytls"; then
    echo 'Expected deployment failure' >&2; exit 1
fi
[[ $(openssl x509 -in "$CONFIG_DIR/server.crt" -noout -serial) == serial=02 ]]
verify_local
# Reconciliation retries the saved ACME certificate after a previous failure.
"$ACME_DIR/renewal-hooks/deploy/50-anytls"
[[ $(openssl x509 -in "$CONFIG_DIR/server.crt" -noout -serial) == serial=03 ]]
verify_local
old_pid=$(< /run/anytls-test.pid)
"$ACME_DIR/renewal-hooks/deploy/50-anytls"
[[ $(< /run/anytls-test.pid) == "$old_pid" ]]

# A foreign lineage must not change the installed certificate.
RENEWED_LINEAGE=/tmp/foreign "$ACME_DIR/renewal-hooks/deploy/50-anytls"
[[ $(openssl x509 -in "$CONFIG_DIR/server.crt" -noout -serial) == serial=03 ]]
# Mismatched keys are rejected before changing deployed files.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$lineage/privkey.pem" >/dev/null 2>&1
if "$ACME_DIR/renewal-hooks/deploy/50-anytls"; then
    echo 'Mismatched private key was accepted!' >&2; exit 1
fi
verify_local
# Repeat install does not modify running configuration or rotate credentials.
before=$(sha256sum "$CONFIG_DIR/config.json")
install_node > "$TMP_DIR/repeat-output"
[[ $(sha256sum "$CONFIG_DIR/config.json") == "$before" ]]

# BBR persistence is tested without changing the host kernel or network.
ENABLE_BBR=1
modprobe() { :; }
sysctl() {
    if [[ $1 == -n ]]; then printf 'reno cubic bbr\n'; else
        grep -q 'net.ipv4.tcp_congestion_control = bbr' "$2"
    fi
}
ip() { printf 'default via 10.0.0.1 dev test0\n'; }
tc() {
    if [[ $2 == show ]]; then printf 'qdisc fq_codel 0: root\n'; else
        printf '%s\n' "$*" > "$TMP_DIR/tc-operation"
    fi
}
enable_bbr
[[ $(< "$TMP_DIR/tc-operation") == 'qdisc replace dev test0 root fq' ]]
grep -q 'net.core.default_qdisc = fq' /etc/sysctl.d/99-zz-anytls-node-bbr.conf
grep -q tcp_bbr /etc/modules-load.d/anytls-node-bbr.conf
unset -f modprobe sysctl ip tc
systemctl stop anytls-node.service
printf '\nPASS: input validation, real AnyTLS, strict TLS, authentication, renewal deployment, rollback, permissions, unit files, repeat installation, BBR settings.\n'
