FROM debian:13-slim

ARG DEBIAN_MIRROR=mirrors.ustc.edu.cn
ARG S6_OVERLAY_VERSION=v3.2.3.0
ARG CODE_SERVER_VERSION=4.127.0
ARG TAILSCALE_VERSION=1.98.8
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    GITHUB_USER=rabbit-dayi \
    UV_LINK_MODE=symlink \
    UV_COMPILE_BYTECODE=1 \
    S6_KEEP_ENV=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    CODE_SERVER_BIND_ADDR=127.0.0.1:8080 \
    CODE_SERVER_WORKDIR=/workspace \
    NGINX_ENABLE=true \
    NGINX_HTTP_PORT=80 \
    NGINX_HTTPS_PORT=443 \
    NGINX_HTTP_REDIRECT=true \
    NGINX_SERVER_NAMES=_ \
    NGINX_UPSTREAM=127.0.0.1:8080 \
    TS_ENABLE=false \
    TS_AUTH_ONCE=true \
    TS_ACCEPT_DNS=false \
    TS_CONFIG_TIMEOUT=30 \
    DOCKERD_ROOTLESS_ENABLE=false \
    DOCKER_HOST=unix:///run/user/1000/docker.sock \
    STARTUP_BANNER=true \
    STATUS_INTERVAL=5

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY --from=ghcr.io/astral-sh/uv:0.11.28 /uv /usr/local/bin/uv

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
      inetutils-ping iproute2 net-tools traceroute procps \
      htop jq lsof ncdu tree dnsutils mtr-tiny tcpdump rsync socat psmisc strace \
      nodejs npm \
      fuse-overlayfs sshfs slirp4netns uidmap nginx-light openssl; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL --retry 3 --retry-all-errors \
      https://download.docker.com/linux/debian/gpg \
      -o /etc/apt/keyrings/docker.asc; \
    chmod a+r /etc/apt/keyrings/docker.asc; \
    . /etc/os-release; \
    printf '%s\n' \
      'Types: deb' \
      'URIs: https://download.docker.com/linux/debian' \
      "Suites: ${VERSION_CODENAME}" \
      'Components: stable' \
      "Architectures: $(dpkg --print-architecture)" \
      'Signed-By: /etc/apt/keyrings/docker.asc' \
      > /etc/apt/sources.list.d/docker.sources; \
    curl -fsSL --retry 3 --retry-all-errors \
      https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
      -o /usr/share/keyrings/tailscale-archive-keyring.gpg; \
    curl -fsSL --retry 3 --retry-all-errors \
      https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
      -o /etc/apt/sources.list.d/tailscale.list; \
    curl -fsSL --retry 3 --retry-all-errors \
      https://pkg.cloudflare.com/cloudflare-main.gpg \
      -o /usr/share/keyrings/cloudflare-main.gpg; \
    printf '%s\n' \
      'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
      > /etc/apt/sources.list.d/cloudflared.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
      docker-ce-rootless-extras "tailscale=${TAILSCALE_VERSION}" cloudflared; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd --gid 1000 dockerd; \
    useradd --uid 1000 --gid dockerd --create-home --shell /usr/sbin/nologin dockerd; \
    printf '%s\n' 'dockerd:100000:65536' >> /etc/subuid; \
    printf '%s\n' 'dockerd:100000:65536' >> /etc/subgid; \
    ln -fs /usr/share/zoneinfo/${TZ} /etc/localtime; \
    dpkg-reconfigure -f noninteractive tzdata; \
    case "${TARGETARCH:-amd64}" in \
      amd64) s6_arch="x86_64"; code_arch="amd64"; code_sha256="a1cb96f64d5c68736764726cd3b0c9b6e500bdc30cfefebc05f59259149380e2" ;; \
      arm64) s6_arch="aarch64"; code_arch="arm64"; code_sha256="e705774c0680e1feb573d38da3b838dde1466573f8621ce4b2414fcf3e64a01f" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSLO --retry 3 --retry-all-errors \
      "https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz"; \
    curl -fsSLO --retry 3 --retry-all-errors \
      "https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz.sha256"; \
    curl -fsSLO --retry 3 --retry-all-errors \
      "https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-${s6_arch}.tar.xz"; \
    curl -fsSLO --retry 3 --retry-all-errors \
      "https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-${s6_arch}.tar.xz.sha256"; \
    sha256sum -c s6-overlay-noarch.tar.xz.sha256; \
    sha256sum -c "s6-overlay-${s6_arch}.tar.xz.sha256"; \
    tar -C / -Jxpf s6-overlay-noarch.tar.xz; \
    tar -C / -Jxpf "s6-overlay-${s6_arch}.tar.xz"; \
    rm -f s6-overlay-*.tar.xz s6-overlay-*.tar.xz.sha256; \
    curl -fsSLo /tmp/code-server.deb --retry 3 --retry-all-errors \
      "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_${code_arch}.deb"; \
    echo "${code_sha256}  /tmp/code-server.deb" | sha256sum -c -; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/code-server.deb; \
    rm -f /tmp/code-server.deb; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /run/sshd /run/tailscale /run/user /var/lib/tailscale /root/.ssh /workspace; \
    install -d -m 0755 /etc/nginx/certs; \
    install -d -m 0700 -o dockerd -g dockerd \
      /run/user/1000 /home/dockerd/.local/share/docker; \
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
        echo "export DOCKER_HOST=${DOCKER_HOST}"; \
        echo "# UV Auto Completion"; \
        echo 'eval "$(uv generate-shell-completion bash)"'; \
    } >> /root/.bashrc; \
    tar -czf /usr/share/root_backup.tar.gz -C / root

COPY rootfs/ /

RUN set -eux; \
    chmod +x \
      /etc/s6-overlay/scripts/init-root \
      /etc/s6-overlay/scripts/configure-nginx \
      /etc/s6-overlay/scripts/configure-tailscale \
      /etc/s6-overlay/s6-rc.d/runtime-status/run \
      /usr/local/bin/docker-image-banner \
      /usr/local/bin/dev \
      /usr/local/bin/update-status \
      /etc/s6-overlay/s6-rc.d/sshd/run \
      /etc/s6-overlay/s6-rc.d/code-server/run \
      /etc/s6-overlay/s6-rc.d/dockerd-rootless/run \
      /etc/s6-overlay/s6-rc.d/nginx/run \
      /etc/s6-overlay/s6-rc.d/tailscaled/run; \
    /usr/sbin/sshd -t; \
    /usr/sbin/nginx -t

WORKDIR /workspace

EXPOSE 22 80 443

ENTRYPOINT ["/init"]
