# docker-image

一个面向远程开发的 Debian 13 Docker 镜像，支持 `linux/amd64` 和 `linux/arm64`，内置：

- `s6-overlay`：作为容器内的 init / supervisor，启动和守护服务
- `OpenSSH Server`：使用公钥登录，并启用协议层 keepalive
- `code-server`：在浏览器中使用 VS Code
- `Tailscale`：可选的容器内 tailnet 接入服务
- `uv`：Python 包管理/运行工具
- 常用工具：`git`、`curl`、`wget`、`vim`、`tmux`、`ping`、`iproute2`、`net-tools`、`traceroute`、`procps`

镜像使用 `/init` 作为 PID 1。启动时会恢复空的 `/root` 卷、更新 GitHub SSH 公钥、生成 SSH host keys，然后由 s6-overlay 分别管理 `sshd`、`code-server` 和可选的 `tailscaled`。

普通 SSH/code-server 模式不需要 `privileged`、systemd、`/sys/fs/cgroup` 或 Compose 的 `init: true`。只有启用 Tailscale 内核网络时才需要 `/dev/net/tun`、`NET_ADMIN` 和 `NET_RAW`。

## 镜像地址

```text
ghcr.io/rabbit-dayi/docker-image:latest
```

## 快速开始

### Docker

```bash
docker run -d \
  --name docker-image \
  -e GITHUB_USER=rabbit-dayi \
  -e PASSWORD='change-this-password' \
  -p 2222:22 \
  -p 8080:8080 \
  -v docker-image-root:/root \
  -v docker-image-workspace:/workspace \
  ghcr.io/rabbit-dayi/docker-image:latest
```

### Docker Compose

```yaml
services:
  dev:
    image: ghcr.io/rabbit-dayi/docker-image:latest
    environment:
      GITHUB_USER: rabbit-dayi
      PASSWORD: change-this-password
    ports:
      - "2222:22"
      - "8080:8080"
    volumes:
      - docker-image-root:/root
      - docker-image-workspace:/workspace
    restart: unless-stopped

volumes:
  docker-image-root:
  docker-image-workspace:
```

不要为此服务设置 `init: true`；s6-overlay 提供的 `/init` 必须保持 PID 1。

## 访问方式

### SSH

容器默认允许 root 使用公钥登录，禁用 SSH 密码登录：

```bash
ssh root@localhost -p 2222
```

服务端默认配置：

```text
ClientAliveInterval 60
ClientAliveCountMax 3
TCPKeepAlive yes
```

这会周期性发送 SSH 协议层探测，减少 NAT、防火墙、VPN 等中间设备清理空闲连接的概率；它不会因为用户暂时没有输入而主动登出正常客户端。

建议连接端也配置 keepalive：

```sshconfig
Host docker-image
    HostName localhost
    Port 2222
    User root
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

默认会从下面的地址下载公开 SSH 公钥：

```text
https://github.com/rabbit-dayi.keys
```

使用其他 GitHub 用户时设置：

```bash
-e GITHUB_USER=<github-user>
```

### code-server

浏览器打开：

```text
http://localhost:8080
```

默认使用 `PASSWORD` 或 `HASHED_PASSWORD` 认证：

```yaml
environment:
  PASSWORD: change-this-password
```

如果 `CODE_SERVER_AUTH=password` 但没有提供密码，code-server 会保持 idle，不会反复重启刷日志。

## 内置 Tailscale

Tailscale 默认关闭。启用后，容器中的 SSH 和 code-server 可以通过该容器自己的 Tailscale IP 访问；原有端口映射仍可作为本地或故障恢复入口。

### Docker Compose 示例

将 auth key 放在未提交到 Git 的 `.env` 或其他 secret 管理工具中：

```dotenv
TS_AUTHKEY=tskey-auth-...
```

```yaml
services:
  dev:
    image: ghcr.io/rabbit-dayi/docker-image:latest
    environment:
      GITHUB_USER: rabbit-dayi
      PASSWORD: change-this-password
      TS_ENABLE: "true"
      TS_AUTHKEY: ${TS_AUTHKEY}
      TS_AUTH_ONCE: "true"
      TS_HOSTNAME: dev-container
      TS_ACCEPT_DNS: "false"
    devices:
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - NET_ADMIN
      - NET_RAW
    ports:
      - "2222:22"
      - "8080:8080"
    volumes:
      - docker-image-root:/root
      - docker-image-workspace:/workspace
      - docker-image-tailscale:/var/lib/tailscale
    restart: unless-stopped

volumes:
  docker-image-root:
  docker-image-workspace:
  docker-image-tailscale:
```

不需要 `privileged: true`。`/var/lib/tailscale` 应持久化，否则容器重建后可能在 tailnet 中生成新的节点身份。LocalAPI socket 位于临时目录 `/run/tailscale/tailscaled.sock`，不应持久化。

Tailscale 是附加服务：缺少 auth key、控制面不可达、认证失败、缺少 TUN 或 capabilities 时，SSH 和 code-server 仍会继续运行。可以进入容器后手工检查：

```bash
docker exec docker-image tailscale \
  --socket=/run/tailscale/tailscaled.sock status
```

或手工认证：

```bash
docker exec -it docker-image tailscale \
  --socket=/run/tailscale/tailscaled.sock up
```

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `GITHUB_USER` | `rabbit-dayi` | 下载 `https://github.com/<user>.keys`；设为空可禁用自动下载。 |
| `CODE_SERVER_BIND_ADDR` | `0.0.0.0:8080` | code-server 监听地址。 |
| `CODE_SERVER_AUTH` | `password` | code-server 认证模式：`password` 或 `none`。 |
| `PASSWORD` | 未设置 | code-server 明文密码。 |
| `HASHED_PASSWORD` | 未设置 | code-server 哈希密码，适合长期部署。 |
| `CODE_SERVER_WORKDIR` | `/workspace` | code-server 默认工作目录。 |
| `TS_ENABLE` | `false` | 设为严格的 `true` 才启用 Tailscale。 |
| `TS_AUTHKEY` | 未设置 | Tailscale auth key，只应在运行时安全注入。 |
| `TS_AUTH_ONCE` | `true` | 已有有效持久化登录时不重复使用 auth key。 |
| `TS_HOSTNAME` | 未设置 | 可选的 tailnet 节点名。 |
| `TS_ACCEPT_DNS` | `false` | 是否接受 Tailscale DNS 配置。 |
| `TS_ADVERTISE_TAGS` | 未设置 | 逗号分隔的 tags，例如 `tag:dev,tag:container`。 |
| `TS_CONFIG_TIMEOUT` | `30` | 等待和配置 Tailscale 的秒数，允许 5–300。 |
| `TZ` | `Asia/Shanghai` | 容器时区。 |
| `LANG` | `C.UTF-8` | 容器语言环境。 |

实现不接受任意 `TS_EXTRA_ARGS`，避免 shell 参数拆分和命令注入。需要增加新的 Tailscale 选项时，应在镜像中加入明确、经过校验的环境变量。

## SSH 公钥行为

### 自动下载

`GITHUB_USER` 非空时，容器启动会下载对应 GitHub 用户的公开 SSH keys。下载成功且内容非空时原子替换 `authorized_keys`；下载失败时保留已有文件并继续启动。

### 自己挂载 authorized_keys

将 `GITHUB_USER` 设为空，并可只读挂载文件：

```bash
docker run -d \
  --name docker-image \
  -e GITHUB_USER= \
  -e PASSWORD='change-this-password' \
  -p 2222:22 \
  -p 8080:8080 \
  -v ./authorized_keys:/root/.ssh/authorized_keys:ro \
  ghcr.io/rabbit-dayi/docker-image:latest
```

初始化逻辑不会强制覆盖只读挂载，也不会递归修改整个 `/root` 的属主。

## 数据卷

推荐的持久化路径：

| 路径 | 用途 |
| --- | --- |
| `/root` | root 用户配置、SSH 配置、code-server 用户数据。 |
| `/workspace` | 项目代码和默认工作目录。 |
| `/var/lib/tailscale` | 可选的 Tailscale 节点身份和状态。 |

新的空 `/root` 卷会自动恢复 `.bashrc`、`.profile` 等默认配置。

容器内临时执行 `apt install` 只会写入当前容器的 writable layer；容器删除重建后会丢失。长期需要的包应写入派生镜像：

```dockerfile
FROM ghcr.io/rabbit-dayi/docker-image:latest

RUN apt-get update \
  && apt-get install -y --no-install-recommends your-package \
  && rm -rf /var/lib/apt/lists/*
```

## 本地构建和测试

```bash
git clone https://github.com/rabbit-dayi/docker-image.git
cd docker-image
docker build -t docker-image:local .
tests/smoke.sh docker-image:local
```

smoke test 会检查：

- s6、SSH、code-server、uv 和 Tailscale 可执行文件
- SSH 配置语法和有效的 keepalive/认证设置
- `/init`、sshd 和 code-server 的实际运行状态
- 只读 `authorized_keys` 挂载下的真实 SSH 公钥登录
- Tailscale 默认关闭，以及启用但缺少 TUN 时不会影响主服务
- runner 提供 `/dev/net/tun` 时，Tailscale daemon、LocalAPI socket 和主服务的实际运行状态

## GitHub Actions

Pull Request 和 push 都会先构建 `linux/amd64` 测试镜像并运行 smoke test。测试通过后再构建 `linux/amd64`、`linux/arm64`；非 PR 构建会发布到：

```text
ghcr.io/rabbit-dayi/docker-image:latest
```

触发条件包括 push 到 `main`、`v*.*.*` tag、Pull Request 和手动触发。

## 排障

### SSH 登录失败

1. 检查 `2222:22` 端口映射。
2. 检查 `GITHUB_USER` 和 `https://github.com/<user>.keys`。
3. 检查容器日志：`docker logs docker-image`。
4. 使用 `GITHUB_USER=` 时，确认挂载的 `authorized_keys` 内容、权限和公钥匹配。

### SSH 仍然断开

镜像已经配置服务端 SSH keepalive；连接端仍建议配置 `ServerAliveInterval`。如果断开时容器重启、sshd 被杀死、宿主网络变化或发生 OOM，keepalive 无法保留原 TCP 会话。检查：

```bash
docker inspect docker-image \
  --format 'running={{.State.Running}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}'
docker logs --since 10m docker-image
```

### code-server 无法访问

确认映射了 8080，并设置了 `PASSWORD`/`HASHED_PASSWORD`，或明确使用 `CODE_SERVER_AUTH=none`。

### Tailscale 没有上线

检查：

```bash
ls -l /dev/net/tun
docker logs docker-image
docker exec docker-image tailscale \
  --socket=/run/tailscale/tailscaled.sock status
```

确认设置了 `TS_ENABLE=true`、映射 `/dev/net/tun`、添加 `NET_ADMIN`/`NET_RAW`，并提供有效 auth key。若状态卷已经登录，通常不需要再次提供 key。

### DNS 或 GitHub 暂时不可用

GitHub SSH key 下载和 Tailscale 配置失败都不会让 SSH/code-server 无限重启。可以修复 Docker DNS，或使用持久化 `/root` 及手工挂载的 `authorized_keys`。

## 安全说明

- GitHub `.keys` 地址只包含公开 SSH 公钥，不是私钥。
- 不要把 SSH 私钥、GitHub PAT、密码或 `TS_AUTHKEY` 写入 Dockerfile、README、镜像层或提交到 Git。
- auth key 应尽量使用一次性、短期、ephemeral 或受 tag 限制的 key；泄露后立即在 Tailscale 管理控制台吊销。
- 对外暴露 code-server 时应使用强密码，或者通过 Tailscale、反向代理、内网或 SSH tunnel 访问。
- 不建议在公网直接使用 `CODE_SERVER_AUTH=none`。
- Tailscale 模式只需要有限 capabilities，不要使用 `privileged: true`。
