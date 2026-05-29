# docker-image

一个面向远程开发的 Debian Docker 镜像，内置：

- `s6-overlay`：作为容器内的 init / supervisor，负责启动和守护服务
- `OpenSSH Server`：用于 SSH 登录容器
- `code-server`：在浏览器里使用 VS Code
- `uv`：Python 包管理/运行工具
- 常用工具：`git`、`curl`、`wget`、`vim`、`tmux`、`ping`、`iproute2`、`net-tools`、`traceroute`、`procps`

镜像启动时会先执行初始化逻辑：

1. 如果 `/root` 是空挂载卷，会从镜像内置备份恢复默认配置。
2. 根据 `GITHUB_USER` 下载 GitHub 公开 SSH 公钥。
3. 写入 `/root/.ssh/authorized_keys`。
4. 修复 SSH 文件权限。
5. 生成 SSH host keys。
6. 由 s6-overlay 启动并守护 `sshd` 和 `code-server`。

本镜像不使用 systemd，因此正常使用时不需要 `privileged`、`/sys/fs/cgroup` 或 Docker Compose 的 `init: true`。

## 镜像地址

```text
ghcr.io/rabbit-dayi/docker-image:latest
```

## 快速开始

### Docker 运行

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

### Docker Compose 运行

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

注意：不要给这个服务配置 `init: true`，也不需要配置 `privileged: true`。

## 访问方式

### SSH

容器内默认允许 root 使用公钥登录，禁用密码登录。

```bash
ssh root@localhost -p 2222
```

默认情况下，容器会下载这个地址里的公开 SSH 公钥：

```text
https://github.com/rabbit-dayi.keys
```

如果你要换成自己的 GitHub 公钥：

```bash
docker run -d \
  --name docker-image \
  -e GITHUB_USER=<github-user> \
  -e PASSWORD='change-this-password' \
  -p 2222:22 \
  -p 8080:8080 \
  ghcr.io/rabbit-dayi/docker-image:latest
```

### code-server

浏览器打开：

```text
http://localhost:8080
```

默认启用密码认证，密码来自环境变量 `PASSWORD`：

```yaml
environment:
  PASSWORD: change-this-password
```

也可以使用 code-server 支持的 `HASHED_PASSWORD`：

```yaml
environment:
  HASHED_PASSWORD: "<hashed-password>"
```

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `GITHUB_USER` | `rabbit-dayi` | 启动时下载 `https://github.com/<user>.keys` 并写入 `/root/.ssh/authorized_keys`。 |
| `CODE_SERVER_BIND_ADDR` | `0.0.0.0:8080` | code-server 监听地址。 |
| `CODE_SERVER_AUTH` | `password` | code-server 认证模式。可设为 `password` 或 `none`。 |
| `PASSWORD` | 未设置 | `CODE_SERVER_AUTH=password` 时使用的明文密码。 |
| `HASHED_PASSWORD` | 未设置 | code-server 哈希密码，比明文 `PASSWORD` 更适合长期部署。 |
| `CODE_SERVER_WORKDIR` | `/workspace` | code-server 默认打开的工作目录。 |
| `TZ` | `Asia/Shanghai` | 容器时区。 |
| `LANG` | `C.UTF-8` | 容器语言环境。 |

## SSH 公钥行为

### 使用 GitHub 用户名下载公钥

默认：

```bash
-e GITHUB_USER=rabbit-dayi
```

容器启动时会请求：

```text
https://github.com/rabbit-dayi.keys
```

请求成功且内容非空时，会覆盖 `/root/.ssh/authorized_keys`。

### 禁用自动下载

如果你想自己挂载或预置 `/root/.ssh/authorized_keys`，可以把 `GITHUB_USER` 设为空：

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

### 网络失败时的行为

如果容器 DNS 或网络暂时无法访问 GitHub：

- 如果已有 `/root/.ssh/authorized_keys`，会保留已有文件。
- 如果没有已有公钥文件，会创建空文件并继续启动。
- 容器不会因为 GitHub 公钥下载失败而无限重启。

## 数据卷说明

推荐挂载两个卷：

```yaml
volumes:
  - docker-image-root:/root
  - docker-image-workspace:/workspace
```

含义：

- `/root`：保存 root 用户配置、SSH 配置、code-server 用户数据等。
- `/workspace`：默认工作目录，适合放项目代码。

如果 `/root` 是一个新的空卷，容器会自动从镜像内置备份恢复 `.bashrc`、`.profile` 等默认配置。

## 关于 apt 包持久化

在运行中的容器里执行 `apt install`，安装结果只会保存在当前容器的 writable layer 里。

这意味着：

- 如果只是 `docker restart`，包还在。
- 如果容器被删除后重新创建，包会丢失。
- 如果 Compose 因为镜像更新而重建容器，包会丢失。
- 不建议通过挂载 `/usr`、`/bin`、`/lib`、`/var/lib/dpkg` 等系统目录来“持久化 apt”，这样很容易和镜像升级产生冲突。

更现实的做法是把需要长期存在的系统包写进自己的派生镜像：

```dockerfile
FROM ghcr.io/rabbit-dayi/docker-image:latest

RUN apt-get update \
  && apt-get install -y --no-install-recommends your-package \
  && rm -rf /var/lib/apt/lists/*
```

如果只是临时调试，可以直接在运行中的容器里 `apt install`；如果是长期环境，建议做成 Dockerfile。

## 本地构建

```bash
git clone https://github.com/rabbit-dayi/docker-image.git
cd docker-image
docker build -t docker-image:local .
```

本地运行：

```bash
docker run -d \
  --name docker-image \
  -e GITHUB_USER=rabbit-dayi \
  -e PASSWORD='change-this-password' \
  -p 2222:22 \
  -p 8080:8080 \
  docker-image:local
```

## GitHub Actions 自动构建

仓库包含 GitHub Actions workflow。

触发条件：

- push 到 `main`
- push 版本 tag，例如 `v1.0.0`
- Pull Request
- 手动触发 workflow

非 PR 构建会发布镜像到 GitHub Container Registry：

```text
ghcr.io/rabbit-dayi/docker-image:latest
```

## 排障

### 1. code-server 打不开

检查容器是否映射了 8080 端口：

```yaml
ports:
  - "8080:8080"
```

检查是否设置了密码：

```yaml
environment:
  PASSWORD: change-this-password
```

如果 `CODE_SERVER_AUTH=password` 但没有设置 `PASSWORD` 或 `HASHED_PASSWORD`，code-server 服务会保持 idle，不会反复重启刷日志。

### 2. SSH 登录不上

检查是否映射了 22 端口：

```yaml
ports:
  - "2222:22"
```

检查 GitHub 用户名是否正确：

```yaml
environment:
  GITHUB_USER: rabbit-dayi
```

检查 GitHub 公钥地址是否能访问：

```text
https://github.com/<github-user>.keys
```

### 3. 容器里无法解析 github.com

这是容器网络/DNS 问题。镜像会继续启动，但可能不会更新 SSH 公钥。

可以选择：

- 修复 Docker/Compose 的 DNS 配置。
- 设置 `GITHUB_USER=`，然后手动挂载 `authorized_keys`。
- 使用持久化 `/root` 卷，保留上一次成功下载的公钥。

### 4. 不要使用 systemd 参数

这个镜像已经不使用 systemd。不要配置：

```yaml
privileged: true
cgroupns: host
init: true
volumes:
  - /sys/fs/cgroup:/sys/fs/cgroup:rw
```

正常 SSH 和 code-server 不需要这些配置。

## 安全说明

- GitHub `.keys` 地址只包含公开 SSH 公钥，不是私钥。
- 不要把 SSH 私钥、GitHub PAT、密码等秘密写进 Dockerfile、README 或镜像层。
- 如果 GitHub PAT 曾经粘贴到聊天、日志或终端历史里，应立即撤销并重新生成。
- 如果对外暴露 code-server，请务必设置强密码，或者放在反向代理、VPN、内网、SSH tunnel 后面。
- 不建议在公网直接使用 `CODE_SERVER_AUTH=none`。
