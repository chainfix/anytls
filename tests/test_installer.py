import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from urllib.parse import parse_qs, unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]


def bash(code, env=None, answers=None):
    merged = dict(os.environ, **(env or {}))
    preamble = 'source "$SCRIPT"\n'
    merged['SCRIPT'] = str(ROOT / 'install.sh')
    if answers is None:
        return subprocess.run(['bash', '-c', preamble + code], env=merged,
                              capture_output=True, text=True, timeout=15)
    # A duplex fd emulates /dev/tty without relying on a human terminal.
    parent, child = socket.socketpair()
    try:
        merged['TEST_FD'] = str(child.fileno())
        parent.sendall(answers.encode())
        parent.shutdown(socket.SHUT_WR)
        return subprocess.run(['bash', '-c', preamble + 'exec 3<&"$TEST_FD"\n' + code],
                              env=merged, pass_fds=(child.fileno(),),
                              capture_output=True, text=True, timeout=15)
    finally:
        parent.close()
        child.close()


class InstallerTests(unittest.TestCase):
    def test_help_without_installing(self):
        r = subprocess.run(['bash', str(ROOT/'install.sh'), '--help'],
                           capture_output=True, text=True, timeout=5)
        self.assertEqual(r.returncode, 0)
        self.assertIn('交互式', r.stdout)

    def test_public_ipv4_only(self):
        for value in ['1.1.1.1', '8.8.8.8']:
            self.assertEqual(bash('valid_ip "$VALUE"', {'VALUE': value}).returncode, 0)
        for value in ['127.0.0.1', '10.0.0.1', '192.168.1.1', '100.64.0.1',
                      '0.0.0.0', '224.0.0.1', '192.0.2.1', '::1', '2606:4700::1111',
                      'example.com', '1.1.1.1;echo unsafe']:
            with self.subTest(value=value):
                self.assertNotEqual(bash('valid_ip "$VALUE"', {'VALUE': value}).returncode, 0)

    def test_ports(self):
        for value in ['1', '443', '8443', '65535', '00443']:
            self.assertEqual(bash('valid_port "$VALUE"', {'VALUE': value}).returncode, 0)
        for value in ['0', '80', '00080', '65536', '999999', '-1', '443/tcp', '1+2', '']:
            self.assertNotEqual(bash('valid_port "$VALUE"', {'VALUE': value}).returncode, 0)

    def test_prompt_assignment_and_default(self):
        r = bash('ask answer "输入" fallback; printf "%s" "$answer"', answers='\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, 'fallback')
        r = bash('confirm "测试" y', answers='\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        r = bash('confirm "测试"', answers='\n')
        self.assertEqual(r.returncode, 1)

    def test_collect_options_custom_port_bbr_default_and_password(self):
        code = '''
curl() { printf 1.1.1.1; }
check_port() { :; }
collect_options
printf '\nRESULT:%s|%s|%s|%s|%s' "$PUBLIC_IP" "$PORT" "$ENABLE_BBR" "$NODE_NAME" "${#PASSWORD}"
'''
        r = bash(code, answers='\n8443\nTest Node\n\n\n\ny\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('RESULT:1.1.1.1|8443|1|Test Node|43', r.stdout)

    def test_collect_retries_invalid_port_and_skips_bbr(self):
        code = '''
curl() { printf 1.1.1.1; }
check_port() { :; }
collect_options
printf '\nRESULT:%s|%s' "$PORT" "$ENABLE_BBR"
'''
        r = bash(code, answers='\n80\n00443\n\n\n\nn\ny\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('RESULT:443|0', r.stdout)

    def test_input_closed_is_error(self):
        r = bash('ask value test', answers='')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('交互输入已结束', r.stderr)

    def test_occupied_port_refused(self):
        r = bash('ss() { printf "LISTEN 0 128 *:443"; }; check_port 443')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('已被占用', r.stderr)

    def test_config_and_uri_preserve_special_characters(self):
        with tempfile.TemporaryDirectory() as d:
            password = 'long pass@word:/?#%"\\中文$(false)'
            name = '测试 & node / #1'
            env = {'TEST_DIR': d, 'PUBLIC_IP': '1.1.1.1', 'PORT': '8443',
                   'NODE_NAME': name, 'PASSWORD': password}
            r = bash('CONFIG_DIR=$TEST_DIR; chown() { :; }; write_config', env)
            self.assertEqual(r.returncode, 0, r.stderr)
            p = Path(d)
            config = json.loads((p/'config.json').read_text())
            self.assertEqual(config['inbounds'][0]['users'][0]['password'], password)
            self.assertEqual(config['inbounds'][0]['listen_port'], 8443)
            (p/'installed.json').write_text(json.dumps({'ip': '1.1.1.1', 'port': 8443, 'name': name}))
            r = bash('CONFIG_DIR=$TEST_DIR; show_node', env)
            self.assertEqual(r.returncode, 0, r.stderr)
            uri = next(line for line in r.stdout.splitlines() if line.startswith('anytls://'))
            parsed = urlsplit(uri)
            self.assertEqual(unquote(parsed.username), password)
            self.assertEqual(unquote(parsed.fragment), name)
            self.assertEqual(parse_qs(parsed.query)['insecure'], ['0'])
            proxy_line = next(line for line in r.stdout.splitlines() if line.startswith('  - '))
            proxy = json.loads(proxy_line[4:])
            self.assertFalse(proxy['skip-cert-verify'])
            self.assertEqual(proxy['password'], password)

    def test_unsupported_bbr_does_not_write_settings(self):
        code = '''
ENABLE_BBR=1
modprobe() { return 1; }
sysctl() { printf 'reno cubic'; }
install() { echo unexpected-write >&2; return 99; }
enable_bbr
'''
        r = bash(code)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('不支持 BBR', r.stdout)
        self.assertNotIn('unexpected-write', r.stderr)

    def test_failed_install_disables_only_new_units(self):
        with tempfile.TemporaryDirectory() as d:
            r = bash('''
CONFIG_DIR=$TEST_DIR
INSTALL_STARTED=1; INSTALL_OK=0; NEW_SERVICE=1
systemctl() { printf 'SYSTEMCTL:%s\\n' "$*"; }
trap cleanup EXIT
exit 7
''', {'TEST_DIR': d})
            self.assertEqual(r.returncode, 7)
            self.assertIn('安装未完成', r.stderr)


if __name__ == '__main__':
    unittest.main()
