# AnyTLS 一键安装

中文交互式安装器，使用 **SagerNet 官方 sing-box** 提供 AnyTLS，直接为公网 **IPv4** 申请 **Let’s Encrypt 受信任证书**。无需域名，不使用自签名证书，客户端不需要跳过验证。

- 自选 TCP 端口，默认 `443`，检查占用；`80` 保留给证书验证。
- 自动生成高强度密码，或交互输入自定义密码（不回显）。
- **默认开启 BBR + FQ**，可选择跳过；检查内核支持并持久化。
- 自动获取 sing-box 最新稳定版，核对 GitHub 官方发布的 SHA-256。
- 独立低权限服务账户，开机自启、异常重启。
- IP 短期证书，每日两次检查续期，成功后自动部署证书并重启 AnyTLS。
- 输出 AnyTLS 导入链接、Mihomo / Clash Meta 节点条目。
- 重复运行保留配置和密码，并提供状态检查、续期演练和到期续期。

## 支持环境

| 项目 | 要求 |
|---|---|
| 系统 | Debian 12 / 13、Ubuntu 22.04 / 24.04 |
| 架构 | x86_64、ARM64 |
| 权限 | root / sudo，运行中的 systemd |
| 地址 | 公网 IPv4；NAT 主机必须正确映射端口 |
| 入站 | TCP 80，以及所选 AnyTLS TCP 端口 |
| 出站 | 能访问 GitHub、PyPI、Let’s Encrypt、系统软件源 |

不支持普通 Docker 容器内安装、IPv6-only 地址、已经被其他网站占用的 TCP 80。脚本不自动关闭防火墙、不操作云安全组，也不会为了签证书停止已有网站。

## 安装

仓库已公开，无需 GitHub 账号或 `gh`。在目标服务器执行：

```bash
curl -fsSL https://raw.githubusercontent.com/chainfix/anytls/main/install.sh -o install-anytls.sh && sudo bash install-anytls.sh
```

已使用 root 登录且未安装 `sudo` 时执行：

```bash
curl -fsSL https://raw.githubusercontent.com/chainfix/anytls/main/install.sh -o install-anytls.sh && bash install-anytls.sh
```

也可以先下载并查看脚本，再运行。脚本是独立文件，不依赖仓库里的其他文件；保存后执行还能自动安装管理菜单。

安装时依次选择：

1. 公网 IPv4（自动检测，可手动修改）。
2. AnyTLS TCP 端口、节点名称。
3. 密码（默认随机生成）、可选证书联系邮箱。
4. 是否开启 BBR + FQ（默认开启）。
5. 确认放行端口并同意 Let’s Encrypt 服务条款。
6. 安装结束后，可选择立即执行自动续期演练。

首次安装会使用系统软件源安装依赖，证书签发可能需要数分钟。若失败，脚本保留已取得的证书；修正网络或端口后重新执行即可。已成功安装的机器重复选择安装只显示现有节点，不静默更新二进制、换密码或覆盖配置。

安装完成后使用：

```bash
sudo anytls
```

若脚本通过管道运行而未保存为文件，管理入口可能无法复制；请保留下载后的脚本并重新执行。

## 端口与证书

AnyTLS 可以选择 `1–65535` 中未占用的 TCP 端口，排除 `80`。默认 `443` 通常更容易通过限制网络，但可能与网站冲突；非常用端口不代表更抗封锁。

**证书不绑定端口。** 客户端 SNI 使用服务器公网 IP，保持“跳过证书验证”关闭。服务器 IP 改变后需要重新签发相应 IP 的证书；当前管理菜单不提供迁移 IP 的功能。

这里使用 Certbot 的 `shortlived` 证书配置，IP 证书有效期约六天。续期定时器每日运行两次，Certbot 根据续期窗口决定是否签发；不会每次都强制申请。

**TCP 80 必须一直允许公网入站，且在验证时可用。** Certbot 只在签发或续期时临时监听，不常驻 HTTP 服务。之后若在 80 端口部署网站，需另行改用 webroot 等验证方式，否则续期会失败。

续期成功后只更新本安装器管理的 AnyTLS，并短暂重启服务，已有连接可能重新建立。证书部署钩子检查有效期和密钥配对；部署检查或服务重启失败时尝试恢复旧证书。下一次续期检查会重新尝试部署已签发但尚未部署的证书，证书未变化时不会重复重启。

## BBR

BBR 用于 TCP，适用于 AnyTLS。安装器默认启用，可以在交互时选择跳过。

- 检测内核是否有 BBR；不支持时明确提示并保留原算法，不自动更换内核。
- 持久化 `net.ipv4.tcp_congestion_control=bbr` 与 `net.core.default_qdisc=fq`。
- 当前网卡为常见简单队列时切换为 FQ；自定义或多队列调度保持原样，避免破坏已有流量控制。
- 设置对主机新建 TCP 连接生效，会影响其他 TCP 服务；不能保证所有线路都提速。

## 检查与故障处理

菜单提供“检查状态”“测试自动续期”和“检查并执行到期续期”。续期演练使用 Let’s Encrypt 测试环境，不部署测试证书。

```bash
systemctl status anytls-node.service
systemctl list-timers anytls-node-renew.timer
journalctl -u anytls-node.service -n 50 --no-pager
journalctl -u anytls-node-renew.service -n 50 --no-pager
```

| 现象 | 检查方向 |
|---|---|
| TCP 80 被占用 | 先确认现有网站用途；本安装器不会强行停止它 |
| IP 证书签发超时 | 公网 IP、云安全组、主机防火墙、TCP 80 NAT 映射 |
| GitHub API 限流 / 摘要缺失 | 稍后重试；脚本不会跳过二进制校验 |
| 公网客户端超时，本机验证成功 | 所选 TCP 端口的云安全组、防火墙、NAT 和网络线路 |
| 客户端证书报错 | SNI 是否为证书 IP、客户端时间、系统根证书、服务端续期是否成功 |
| BBR 不可用 | 内核是否提供 BBR；安装仍可正常使用 AnyTLS |
| PyPI / ACME 因失效 IPv6 卡住 | 安装器仅对自身下载及 Certbot 使用 IPv4，不关闭主机 IPv6 |

安装结束的 TLS 检查发生在服务器本机，只证明服务、证书链和 IP 匹配；公网可用性仍需在客户端实测。

## 安装位置

| 位置 | 用途 |
|---|---|
| `/usr/local/sbin/anytls` | 管理菜单 |
| `/opt/anytls-node` | sing-box、独立 Certbot Python 环境及 IPv4 包装器 |
| `/etc/anytls-node` | 服务配置、部署后的证书、安装状态 |
| `/var/lib/anytls-node` | 独立 ACME 账户、证书、续期配置和日志 |
| `anytls-node.service` | AnyTLS 服务 |
| `anytls-node-renew.service` / `.timer` | 自动续期任务 |
| `/etc/sysctl.d/99-zz-anytls-node-bbr.conf` | 可选 BBR 持久化设置 |

使用独立的目录和服务名，不改动系统已有 Certbot 配置。密码仅保存在服务器配置中，导入链接会显示在终端；不要将实际配置、链接、私钥上传到仓库。

## 开发验证

```bash
bash -n install.sh
shellcheck install.sh tests/*.sh
bash tests/unit.sh
```

隔离集成测试应在临时容器中运行，不能直接在生产主机执行。它使用临时测试 CA、真实 sing-box 二进制以及受控的服务管理替身，覆盖 TLS 验证、真实 AnyTLS 代理、认证拒绝、证书部署回滚与续期配置。它不模拟或声称完成 Let’s Encrypt 公网签发，生产 CA 流程已在实际服务器单独验证。

```bash
docker build -f tests/Dockerfile -t anytls-test .
docker run --rm anytls-test
```

GitHub Actions 会运行静态检查、单元测试和隔离集成测试。Certbot 固定为 `5.10.0`（支持 IP 和 ACME profile）；升级需在测试后更新脚本。sing-box 在安装时获取官方最新稳定版，因此未来上游不兼容变更可能需要同步更新安装器。
