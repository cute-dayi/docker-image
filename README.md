# docker-image

一个面向远程开发的 Debian 13 Docker 镜像，支持 `linux/amd64` 和 `linux/arm64`，内置：

- `s6-overlay`：作为容器内的 init / supervisor，启动和守护服务
- `OpenSSH Server`：使用公钥登录，并启用协议层 keepalive
- `code-server`：在浏览器中使用 VS Code
- `Nginx`：统一 Web 出口，默认将 HTTP 重定向到 HTTPS，并反代 code-server 的 WebSocket
- `Tailscale`：可选的容器内 tailnet 接入服务
- `Docker CLI`、Buildx、Compose plugin，以及可选的 rootless Docker-in-Docker daemon
- `uv`：Python 包管理/运行工具
- 常用工具：`git`、`curl`、`wget`、`vim`、`tmux`、`ping`、`iproute2`、`net-tools`、`traceroute`、`procps`，以及常用维护工具

镜像使用 `/init` 作为 PID 1。启动时会恢复空的 `/root` 卷、更新 GitHub SSH 公钥、生成 SSH host keys 和默认 TLS 证书，然后由 s6-overlay 分别管理 `sshd`、`code-server`、`nginx`、可选的 `tailscaled` 和 rootless `dockerd`。

普通 SSH/code-server 模式不需要 `privileged`、systemd、`/sys/fs/cgroup` 或 Compose 的 `init: true`。启用 Tailscale 内核网络时才需要 `/dev/net/tun`、`NET_ADMIN` 和 `NET_RAW`；启用 rootless Docker-in-Docker 时需要外层容器使用 `--privileged`，具体原因和使用方式见下文。

## 基础维护工具

镜像预装以下无需额外服务的维护工具：

- 进程与文件：`htop`、`pstree`、`lsof`、`strace`
- 磁盘与目录：`ncdu`、`tree`
- DNS 与网络诊断：`dig`、`mtr`、`tcpdump`、`socat`
- 数据与同步：`jq`、`rsync`

`tcpdump` 抓包需要容器具备 `NET_RAW` 能力；受默认 seccomp 或 ptrace 限制的运行环境中，`strace` 可能需要额外授予调试权限。

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
  -e NGINX_SERVER_NAMES=code.example.com \
  -p 2222:22 \
  -p 80:80 \
  -p 443:443 \
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
      NGINX_SERVER_NAMES: code.example.com
    ports:
      - "2222:22"
      - "80:80"
      - "443:443"
    volumes:
      - docker-image-root:/root
      - docker-image-workspace:/workspace
    restart: unless-stopped

volumes:
  docker-image-root:
  docker-image-workspace:
```

不要为此服务设置 `init: true`；s6-overlay 提供的 `/init` 必须保持 PID 1。

## Nginx HTTPS 统一入口

Nginx 默认启用，是 code-server 唯一对外的 Web 入口：容器内 code-server 默认只绑定 `127.0.0.1:8080`，HTTP `80` 会以 `308` 重定向到 HTTPS `443`。Nginx 会转发 WebSocket 和 `X-Forwarded-*` 头，因此可以直接用浏览器访问 code-server。

SSH 仍独立使用 `22` 端口。正常部署只需映射 `22`、`80` 和 `443`，不要再映射 `8080`。

### 域名

将 DNS 的 A/AAAA 记录指向宿主机后，设置逗号分隔的域名列表：

```yaml
environment:
  NGINX_SERVER_NAMES: code.example.com,*.dev.example.com
ports:
  - "80:80"
  - "443:443"
```

`NGINX_SERVER_NAMES` 只接受精确域名和 `*.example.com` 形式的通配域名，避免把环境变量直接当作 Nginx 配置注入。未设置时为 `_`，可用于本地访问；默认自签名证书的名称是 `localhost`。

### TLS 证书

没有提供证书时，容器每次创建会自动生成一个有效期 10 年的自签名证书，放在临时目录 `/run/nginx/default-certificate/`。它让 HTTPS 开箱可用，但浏览器会显示不受信任警告，不应作为生产证书。

生产部署可只读挂载证书目录，Nginx 会优先使用其中的 `tls.crt` 和 `tls.key`：

```bash
docker run -d \
  --name docker-image \
  -e GITHUB_USER=rabbit-dayi \
  -e PASSWORD='change-this-password' \
  -e NGINX_SERVER_NAMES=code.example.com \
  -p 80:80 \
  -p 443:443 \
  -v ./certs:/etc/nginx/certs:ro \
  -v docker-image-root:/root \
  -v docker-image-workspace:/workspace \
  ghcr.io/rabbit-dayi/docker-image:latest
```

其中 `./certs/tls.crt` 应是完整证书链，`./certs/tls.key` 是未加密私钥。使用其他挂载路径或文件名时，同时设置 `NGINX_TLS_CERT_FILE` 与 `NGINX_TLS_KEY_FILE`。证书续期后重启容器即可加载新文件。

若要保留旧的直连方式，显式关闭 Nginx 并将 code-server 改回公开监听：

```bash
docker run -d \
  --name docker-image-direct \
  -e GITHUB_USER=rabbit-dayi \
  -e PASSWORD='change-this-password' \
  -e NGINX_ENABLE=false \
  -e CODE_SERVER_BIND_ADDR=0.0.0.0:8080 \
  -p 8080:8080 \
  ghcr.io/rabbit-dayi/docker-image:latest
```

## Rootless Docker-in-Docker

镜像始终内置 Docker CLI、Buildx 和 Compose plugin，但 rootless daemon 默认关闭。要在容器内构建、运行和管理独立的 Docker 容器，显式启用 `DOCKERD_ROOTLESS_ENABLE=true`：

```bash
docker run -d \
  --name docker-image-dind \
  --privileged \
  -e GITHUB_USER=rabbit-dayi \
  -e PASSWORD='change-this-password' \
  -e DOCKERD_ROOTLESS_ENABLE=true \
  -p 2222:22 \
  -p 80:80 \
  -p 443:443 \
  -v docker-image-root:/root \
  -v docker-image-workspace:/workspace \
  -v docker-image-docker:/home/dockerd/.local/share/docker \
  ghcr.io/rabbit-dayi/docker-image:latest
```

`dockerd` 以镜像内 UID 1000 的 `dockerd` 用户运行；root 的 SSH、终端和 code-server 已预设 `DOCKER_HOST=unix:///run/user/1000/docker.sock`，进入后可直接执行：

```bash
docker info
docker run --rm hello-world
docker buildx version
docker compose version
```

Docker API 默认不监听 TCP 端口，也不需要挂载宿主机的 `/var/run/docker.sock`。镜像中的 Docker 数据位于 `/home/dockerd/.local/share/docker`，应单独持久化，不要混入 `/root` 卷。

Docker 官方的 rootless Docker-in-Docker 运行方式仍要求外层容器放开 seccomp、AppArmor 和 mount mask；本镜像使用文档推荐的 `--privileged` 方式。rootless 仅确保内层 `dockerd` 不以外层容器的 root 身份运行，不能抵消 `--privileged` 带来的外层容器风险。因此只应为受信任的开发或 CI 工作负载启用此模式。

### Docker Compose

```yaml
services:
  dev:
    image: ghcr.io/rabbit-dayi/docker-image:latest
    privileged: true
    environment:
      GITHUB_USER: rabbit-dayi
      PASSWORD: change-this-password
      DOCKERD_ROOTLESS_ENABLE: "true"
    ports:
      - "2222:22"
      - "80:80"
      - "443:443"
    volumes:
      - docker-image-root:/root
      - docker-image-workspace:/workspace
      - docker-image-docker:/home/dockerd/.local/share/docker
    restart: unless-stopped

volumes:
  docker-image-root:
  docker-image-workspace:
  docker-image-docker:
```

启用前，宿主机必须允许非特权 user namespace；服务启动时还会检查 `/dev/fuse`。条件不满足时 rootless `dockerd` 会保持 idle，SSH 和 code-server 不受影响。rootless Docker 的已知限制仍然适用，例如默认不能发布低于 1024 的端口，且没有 systemd/cgroup v2 委派时部分容器级资源限制不会生效。

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
https://localhost
```

默认使用 `PASSWORD` 或 `HASHED_PASSWORD` 认证：

```yaml
environment:
  PASSWORD: change-this-password
```

如果 `CODE_SERVER_AUTH=password` 但没有提供密码，code-server 会保持 idle，不会反复重启刷日志。

本地使用默认自签名证书时，需要在浏览器确认一次证书警告；命令行检查可使用 `curl -k https://localhost/healthz`。部署域名和正式证书后，访问 `https://<你的域名>`。

## 内置 Tailscale

Tailscale 默认关闭。启用后，容器中的 SSH 和 Nginx HTTPS 入口可以通过该容器自己的 Tailscale IP 访问；原有端口映射仍可作为本地或故障恢复入口。

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
      - "80:80"
      - "443:443"
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
| `CODE_SERVER_BIND_ADDR` | `127.0.0.1:8080` | code-server 监听地址；默认只允许 Nginx 反代。 |
| `CODE_SERVER_AUTH` | `password` | code-server 认证模式：`password` 或 `none`。 |
| `PASSWORD` | 未设置 | code-server 明文密码。 |
| `HASHED_PASSWORD` | 未设置 | code-server 哈希密码，适合长期部署。 |
| `CODE_SERVER_WORKDIR` | `/workspace` | code-server 默认工作目录。 |
| `NGINX_ENABLE` | `true` | 严格设为 `true` 时启用统一 HTTPS Web 入口。 |
| `NGINX_HTTP_PORT` | `80` | Nginx HTTP 监听端口。 |
| `NGINX_HTTPS_PORT` | `443` | Nginx HTTPS 监听端口。 |
| `NGINX_HTTP_REDIRECT` | `true` | 是否将 HTTP 以 308 重定向到 HTTPS；设为 `false` 时 HTTP 也反代到上游。 |
| `NGINX_SERVER_NAMES` | `_` | 逗号分隔的精确域名或通配域名，用于 Nginx `server_name` 和默认证书 SAN。 |
| `NGINX_UPSTREAM` | `127.0.0.1:8080` | Nginx 反代的单个 `host:port` 上游；更改 code-server 端口时一并更新。 |
| `NGINX_TLS_CERT_FILE` | 未设置 | 自定义证书绝对路径；必须与 `NGINX_TLS_KEY_FILE` 一同设置。 |
| `NGINX_TLS_KEY_FILE` | 未设置 | 自定义未加密私钥绝对路径；必须与 `NGINX_TLS_CERT_FILE` 一同设置。 |
| `TS_ENABLE` | `false` | 设为严格的 `true` 才启用 Tailscale。 |
| `TS_AUTHKEY` | 未设置 | Tailscale auth key，只应在运行时安全注入。 |
| `TS_AUTH_ONCE` | `true` | 已有有效持久化登录时不重复使用 auth key。 |
| `TS_HOSTNAME` | 未设置 | 可选的 tailnet 节点名。 |
| `TS_ACCEPT_DNS` | `false` | 是否接受 Tailscale DNS 配置。 |
| `TS_ADVERTISE_TAGS` | 未设置 | 逗号分隔的 tags，例如 `tag:dev,tag:container`。 |
| `TS_CONFIG_TIMEOUT` | `30` | 等待和配置 Tailscale 的秒数，允许 5–300。 |
| `DOCKERD_ROOTLESS_ENABLE` | `false` | 严格设为 `true` 才启动镜像内的 rootless Docker daemon；需要外层容器使用 `--privileged`。 |
| `DOCKER_HOST` | `unix:///run/user/1000/docker.sock` | 镜像内 Docker CLI 默认连接的 rootless daemon socket。 |
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
  -p 80:80 \
  -p 443:443 \
  -v ./authorized_keys:/root/.ssh/authorized_keys:ro \
  ghcr.io/rabbit-dayi/docker-image:latest
```

初始化逻辑不会强制覆盖只读挂载，也不会递归修改整个 `/root` 的属主。启动时会将该文件复制到 root 拥有的临时 SSH key 文件，因此宿主机挂载文件属于非 root 用户时，SSH 公钥登录同样可用。

## 数据卷

推荐的持久化路径：

| 路径 | 用途 |
| --- | --- |
| `/root` | root 用户配置、SSH 配置、code-server 用户数据。 |
| `/workspace` | 项目代码和默认工作目录。 |
| `/var/lib/tailscale` | 可选的 Tailscale 节点身份和状态。 |
| `/home/dockerd/.local/share/docker` | 可选的 rootless Docker-in-Docker 镜像、容器、卷和构建缓存。 |

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

- s6、SSH、code-server、Nginx、OpenSSL、uv 和 Tailscale 可执行文件
- 基础维护工具的可执行文件
- Docker CLI、Buildx、Compose plugin 和 rootless Docker 运行时依赖
- SSH 配置语法和有效的 keepalive/认证设置
- 默认自签名证书、域名 HTTPS 反代、HTTP 到 HTTPS 跳转，以及挂载自定义 TLS 证书
- `/init`、sshd、code-server 和 nginx 的实际运行状态
- 只读 `authorized_keys` 挂载下的真实 SSH 公钥登录
- Tailscale 默认关闭，以及启用但缺少 TUN 时不会影响主服务
- runner 提供 `/dev/net/tun` 时，Tailscale daemon、LocalAPI socket 和主服务的实际运行状态
- 以 `--privileged` 运行时，rootless `dockerd` 的 socket、非 root daemon 身份，以及本地 scratch 镜像的构建和运行

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

默认模式下确认映射了 `443:443`，并使用 `https://<域名>` 访问。检查 `PASSWORD`/`HASHED_PASSWORD`，或明确使用 `CODE_SERVER_AUTH=none`；使用默认自签名证书时浏览器还需要确认一次证书警告。

```bash
docker logs docker-image
docker exec docker-image nginx -t -c /run/nginx/nginx.conf
```

仅在 `NGINX_ENABLE=false` 时才需要映射 `8080`，并将 `CODE_SERVER_BIND_ADDR` 设为 `0.0.0.0:8080`。

### Tailscale 没有上线

检查：

```bash
ls -l /dev/net/tun
docker logs docker-image
docker exec docker-image tailscale \
  --socket=/run/tailscale/tailscaled.sock status
```

确认设置了 `TS_ENABLE=true`、映射 `/dev/net/tun`、添加 `NET_ADMIN`/`NET_RAW`，并提供有效 auth key。若状态卷已经登录，通常不需要再次提供 key。

### rootless Docker 不可用

确认设置了 `DOCKERD_ROOTLESS_ENABLE=true`，且外层容器使用了 `--privileged`（Compose 为 `privileged: true`）。查看 daemon 日志和状态：

```bash
docker logs docker-image
docker exec docker-image docker info
docker exec docker-image ls -l /run/user/1000/docker.sock /dev/fuse
```

若日志提示 user namespace 不可用，需要由宿主机管理员启用非特权 user namespace；若提示 `/dev/fuse` 不可用，通常表示外层容器没有使用 `--privileged`。不要通过挂载宿主机 Docker socket 来替代这些条件，那会让容器直接控制宿主机 daemon。

### DNS 或 GitHub 暂时不可用

GitHub SSH key 下载和 Tailscale 配置失败都不会让 SSH/code-server 无限重启。可以修复 Docker DNS，或使用持久化 `/root` 及手工挂载的 `authorized_keys`。

## 安全说明

- GitHub `.keys` 地址只包含公开 SSH 公钥，不是私钥。
- 不要把 SSH 私钥、GitHub PAT、密码或 `TS_AUTHKEY` 写入 Dockerfile、README、镜像层或提交到 Git。
- 默认 TLS 证书是运行时生成的自签名证书，仅用于开箱访问；公网部署应挂载受信任 CA 签发的证书和私钥。
- auth key 应尽量使用一次性、短期、ephemeral 或受 tag 限制的 key；泄露后立即在 Tailscale 管理控制台吊销。
- 对外暴露 code-server 时应使用强密码，或者通过 Tailscale、反向代理、内网或 SSH tunnel 访问。
- 不建议在公网直接使用 `CODE_SERVER_AUTH=none`。
- Tailscale 模式本身只需要有限 capabilities，不需要 `privileged: true`。
- rootless Docker-in-Docker 的 daemon 不是外层 root，但该模式的外层容器仍需 `--privileged`；不要将其用于不受信任的代码或多租户环境。
