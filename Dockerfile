FROM debian:latest

ARG DEBIAN_MIRROR=mirrors.ustc.edu.cn
ARG S6_OVERLAY_VERSION=v3.2.3.0
ARG CODE_SERVER_VERSION=4.121.0
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    GITHUB_USER=rabbit-dayi \
    UV_LINK_MODE=symlink \
    UV_COMPILE_BYTECODE=1 \
    S6_KEEP_ENV=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    CODE_SERVER_BIND_ADDR=0.0.0.0:8080 \
    CODE_SERVER_WORKDIR=/workspace

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
      sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list.d/debian.sources; \
      sed -i "s|security.debian.org|${DEBIAN_MIRROR}/debian-security|g" /etc/apt/sources.list.d/debian.sources; \
    else \
      sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list; \
      sed -i "s|security.debian.org|${DEBIAN_MIRROR}/debian-security|g" /etc/apt/sources.list; \
    fi; \
    apt-get update; \
    apt-get -y upgrade; \
    apt-get install -y --no-install-recommends \
      openssh-server git curl wget vim ca-certificates tzdata tmux xz-utils \
      inetutils-ping iproute2 net-tools traceroute procps; \
    rm -rf /var/lib/apt/lists/*; \
    ln -fs /usr/share/zoneinfo/${TZ} /etc/localtime; \
    dpkg-reconfigure -f noninteractive tzdata; \
    case "${TARGETARCH:-amd64}" in \
      amd64) s6_arch="x86_64"; code_arch="amd64" ;; \
      arm64) s6_arch="aarch64"; code_arch="arm64" ;; \
      arm) s6_arch="armhf"; code_arch="armhf" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/s6-overlay-noarch.tar.xz "https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz"; \
    curl -fsSLo /tmp/s6-overlay-${s6_arch}.tar.xz "https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-${s6_arch}.tar.xz"; \
    tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz; \
    tar -C / -Jxpf /tmp/s6-overlay-${s6_arch}.tar.xz; \
    rm -f /tmp/s6-overlay-*.tar.xz; \
    curl -fsSLo /tmp/code-server.deb "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_${code_arch}.deb"; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/code-server.deb; \
    rm -f /tmp/code-server.deb; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /run/sshd /root/.ssh /workspace; \
    touch /root/.ssh/authorized_keys; \
    chmod 700 /root/.ssh; \
    chmod 600 /root/.ssh/authorized_keys; \
    cp /etc/skel/.bashrc /root/.bashrc; \
    cp /etc/skel/.profile /root/.profile; \
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
    sed -ri 's/^#?PermitRootLogin\s+.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config; \
    sed -ri 's/^#?PasswordAuthentication\s+.*/PasswordAuthentication no/' /etc/ssh/sshd_config; \
    sed -ri 's/^#?PubkeyAuthentication\s+.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config; \
    grep -qE '^\s*AuthorizedKeysFile' /etc/ssh/sshd_config || echo 'AuthorizedKeysFile .ssh/authorized_keys' >> /etc/ssh/sshd_config; \
    tar -czf /usr/share/root_backup.tar.gz -C / root

COPY rootfs/ /

RUN set -eux; \
    chmod +x \
      /etc/s6-overlay/scripts/init-root \
      /etc/s6-overlay/s6-rc.d/sshd/run \
      /etc/s6-overlay/s6-rc.d/code-server/run

WORKDIR /workspace

EXPOSE 22 8080

ENTRYPOINT ["/init"]
