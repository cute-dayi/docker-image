FROM debian:latest

# --- 构建参数 ---
ARG DEBIAN_MIRROR=mirrors.ustc.edu.cn

# --- 环境变量 ---
ENV DEBIAN_FRONTEND=noninteractive \
    container=docker \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    GITHUB_USER=rabbit-dayi \
    UV_LINK_MODE=symlink \
    UV_COMPILE_BYTECODE=1

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# --- 1. 获取 uv 二进制文件 ---
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# --- 2. 注入 Entrypoint 脚本 ---
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# --- 3. 系统安装与配置 ---
RUN set -eux; \
    # [换源]
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
      sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list.d/debian.sources; \
      sed -i "s|security.debian.org|${DEBIAN_MIRROR}/debian-security|g" /etc/apt/sources.list.d/debian.sources; \
    else \
      sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list; \
      sed -i "s|security.debian.org|${DEBIAN_MIRROR}/debian-security|g" /etc/apt/sources.list; \
    fi; \
    \
    # [安装基础软件]
    apt-get update; \
    apt-get -y upgrade; \
    apt-get install -y --no-install-recommends \
      systemd systemd-sysv openssh-server git curl wget vim ca-certificates tzdata tini tmux\
      inetutils-ping iproute2 net-tools traceroute procps; \
    rm -rf /var/lib/apt/lists/*; \
    \
    # [配置时区]
    ln -fs /usr/share/zoneinfo/${TZ} /etc/localtime; \
    dpkg-reconfigure -f noninteractive tzdata; \
    \
    # [准备 /root 目录结构]
    mkdir -p /var/run/sshd /root/.ssh; \
    \
    # [准备 SSH 授权文件]
    touch /root/.ssh/authorized_keys; \
    chmod 700 /root/.ssh; \
    chmod 600 /root/.ssh/authorized_keys; \
    \
    # [配置 User Profile]
    # 复制 skeleton 文件，防止缺失
    cp /etc/skel/.bashrc /root/.bashrc; \
    cp /etc/skel/.profile /root/.profile; \
    \
    # [注入环境变量到 .bashrc]
    # 这样 SSH 登录时也能获取到正确的 UV 配置和时区
    { \
        echo ""; \
        echo "# --- Docker Injected Env Vars ---"; \
        echo "export TZ=${TZ}"; \
        echo "export LANG=${LANG}"; \
        echo "export UV_LINK_MODE=${UV_LINK_MODE}"; \
        echo "export UV_COMPILE_BYTECODE=${UV_COMPILE_BYTECODE}"; \
        echo "# UV Auto Completion"; \
        echo 'eval "$(uv generate-shell-completion bash)"'; \
    } >> /root/.bashrc; \
    \
    # [配置 SSHD]
    sed -ri 's/^#?PermitRootLogin\s+.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config; \
    sed -ri 's/^#?PasswordAuthentication\s+.*/PasswordAuthentication no/' /etc/ssh/sshd_config; \
    sed -ri 's/^#?PubkeyAuthentication\s+.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config; \
    grep -qE '^\s*AuthorizedKeysFile' /etc/ssh/sshd_config || echo 'AuthorizedKeysFile .ssh/authorized_keys' >> /etc/ssh/sshd_config; \
    systemctl enable ssh.service; \
    \
    # [关键步骤：备份配置好的 /root]
    # 打包 /root 目录到安全位置，供 Entrypoint 恢复使用
    tar -czf /usr/share/root_backup.tar.gz -C / root

WORKDIR /workspace

EXPOSE 22

STOPSIGNAL SIGRTMIN+3

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

CMD ["/lib/systemd/systemd"]
