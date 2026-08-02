#!/usr/bin/env bash
set -euo pipefail

image="${1:?usage: tests/smoke.sh IMAGE}"
container="docker-image-smoke-${RANDOM}"
tls_container="${container}-tls"
tmpdir="$(mktemp -d)"
cleanup() {
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker rm -f "$tls_container" >/dev/null 2>&1 || true
    rm -rf "$tmpdir"
}
trap cleanup EXIT

assert_config() {
    local pattern=$1
    grep -qE "$pattern" "$tmpdir/sshd-config" || {
        echo "Missing sshd setting: $pattern" >&2
        exit 1
    }
}

docker run --rm --entrypoint /bin/bash "$image" -c '
    set -e
    command -v /init sshd code-server uv tailscale tailscaled cloudflared nginx openssl \
        docker dockerd dockerd-rootless.sh newuidmap newgidmap \
        slirp4netns fuse-overlayfs ldd \
        htop jq lsof ncdu tree dig mtr tcpdump rsync socat pstree strace \
        node npm npx >/dev/null
    test -x /usr/bin/true
    command -v docker-rootlesskit >/dev/null || command -v rootlesskit >/dev/null
    getent passwd dockerd | grep -q "^dockerd:x:1000:1000:"
    grep -qx "dockerd:100000:65536" /etc/subuid
    grep -qx "dockerd:100000:65536" /etc/subgid
    docker buildx version >/dev/null
    docker compose version >/dev/null
    bash -n /etc/s6-overlay/scripts/init-root \
        /etc/s6-overlay/scripts/configure-nginx \
        /etc/s6-overlay/scripts/configure-tailscale \
        /etc/s6-overlay/s6-rc.d/code-server/run \
        /etc/s6-overlay/s6-rc.d/dockerd-rootless/run \
        /etc/s6-overlay/s6-rc.d/nginx/run \
        /etc/s6-overlay/s6-rc.d/tailscaled/run
    NGINX_SERVER_NAMES=code.example.test /etc/s6-overlay/scripts/configure-nginx
    nginx -t -q -c /run/nginx/nginx.conf
    openssl x509 -in /run/nginx/default-certificate/tls.crt -noout -ext subjectAltName \
        | grep -q "DNS:code.example.test"
    NGINX_HTTP_PORT=8081 NGINX_HTTPS_PORT=8443 \
        /etc/s6-overlay/scripts/configure-nginx
    nginx -t -q -c /run/nginx/nginx.conf
    grep -Fq "return 308 https://\$host:8443\$request_uri;" /run/nginx/nginx.conf
    NGINX_HTTP_PORT=8081 NGINX_HTTPS_PORT=8443 NGINX_HTTP_REDIRECT=false \
        /etc/s6-overlay/scripts/configure-nginx
    nginx -t -q -c /run/nginx/nginx.conf
    grep -Fq "proxy_set_header X-Forwarded-Proto http;" /run/nginx/nginx.conf
    if NGINX_SERVER_NAMES="bad;name" /etc/s6-overlay/scripts/configure-nginx >/dev/null 2>&1; then
        echo "Invalid NGINX_SERVER_NAMES was accepted" >&2
        exit 1
    fi
    sshd -t
'
docker run --rm --entrypoint /usr/sbin/sshd "$image" -T >"$tmpdir/sshd-config"
assert_config '^clientaliveinterval 60$'
assert_config '^clientalivecountmax 3$'
assert_config '^tcpkeepalive yes$'
assert_config '^passwordauthentication no$'
assert_config '^pubkeyauthentication yes$'
assert_config '^permitrootlogin (without-password|prohibit-password)$'

ssh-keygen -q -t ed25519 -N '' -f "$tmpdir/id_ed25519"
cp "$tmpdir/id_ed25519.pub" "$tmpdir/authorized_keys"
chmod 444 "$tmpdir/authorized_keys"
# GitHub-hosted runners bind-mount files as the runner user, not root.
chown 1001:1001 "$tmpdir/authorized_keys"
original_keys="$(sha256sum "$tmpdir/authorized_keys")"

docker run -d \
    --name "$container" \
    -e GITHUB_USER= \
    -e CODE_SERVER_AUTH=none \
    -e NGINX_SERVER_NAMES=smoke.example.test \
    -e TS_ENABLE=false \
    -p 127.0.0.1::22 \
    -p 127.0.0.1::80 \
    -p 127.0.0.1::443 \
    -v "$tmpdir/authorized_keys:/root/.ssh/authorized_keys:ro" \
    "$image" >/dev/null

ssh_port="$(docker port "$container" 22/tcp | sed 's/.*://')"
http_port="$(docker port "$container" 80/tcp | sed 's/.*://')"
https_port="$(docker port "$container" 443/tcp | sed 's/.*://')"
for _ in {1..30}; do
    if ssh -i "$tmpdir/id_ed25519" -p "$ssh_port" \
        -o BatchMode=yes -o ConnectTimeout=2 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        root@127.0.0.1 true 2>/dev/null; then
        break
    fi
    sleep 1
done
ssh -i "$tmpdir/id_ed25519" -p "$ssh_port" \
    -o BatchMode=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@127.0.0.1 'test "$(ps -p 1 -o comm=)" = s6-svscan'

for _ in {1..30}; do
    curl --noproxy '*' -fkS \
        --resolve "smoke.example.test:${https_port}:127.0.0.1" \
        "https://smoke.example.test:${https_port}/healthz" >/dev/null 2>&1 && break
    sleep 1
done
curl --noproxy '*' -fkS \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/healthz" >/dev/null
redirect_headers="$(curl --noproxy '*' -skSI \
    --resolve "smoke.example.test:${http_port}:127.0.0.1" \
    "http://smoke.example.test:${http_port}/healthz" | tr -d '\r')"
printf '%s\n' "$redirect_headers" | grep -qE '^HTTP/.* 308'
printf '%s\n' "$redirect_headers" | grep -qi '^location: https://smoke.example.test/healthz$'
[ "$original_keys" = "$(sha256sum "$tmpdir/authorized_keys")" ]
docker exec "$container" pgrep -x sshd >/dev/null
docker exec "$container" pgrep -f code-server >/dev/null
docker exec "$container" pgrep -x nginx >/dev/null
docker exec "$container" openssl x509 \
    -in /run/nginx/default-certificate/tls.crt -noout -ext subjectAltName \
    | grep -q 'DNS:smoke.example.test'
! docker exec "$container" pgrep -x dockerd >/dev/null
[ "$(docker inspect -f '{{.RestartCount}}' "$container")" = 0 ]

# A mounted certificate pair takes precedence over the generated default.
mkdir -p "$tmpdir/certs"
openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 1 \
    -keyout "$tmpdir/certs/tls.key" \
    -out "$tmpdir/certs/tls.crt" \
    -subj '/CN=custom.example.test' >/dev/null 2>&1
docker run -d \
    --name "$tls_container" \
    -e GITHUB_USER= \
    -e CODE_SERVER_AUTH=none \
    -e NGINX_SERVER_NAMES=custom.example.test \
    -p 127.0.0.1::443 \
    -v "$tmpdir/certs:/etc/nginx/certs:ro" \
    "$image" >/dev/null
custom_https_port="$(docker port "$tls_container" 443/tcp | sed 's/.*://')"
for _ in {1..30}; do
    curl --noproxy '*' -fkS \
        --resolve "custom.example.test:${custom_https_port}:127.0.0.1" \
        "https://custom.example.test:${custom_https_port}/healthz" >/dev/null 2>&1 && break
    sleep 1
done
curl --noproxy '*' -fkS \
    --resolve "custom.example.test:${custom_https_port}:127.0.0.1" \
    "https://custom.example.test:${custom_https_port}/healthz" >/dev/null
printf '\n' | openssl s_client \
    -connect "127.0.0.1:${custom_https_port}" \
    -servername custom.example.test 2>/dev/null \
    | openssl x509 -noout -subject \
    | grep -q 'CN = custom.example.test'
docker rm -f "$tls_container" >/dev/null

# Tailscale is optional: enabling it without a TUN device must not take down SSH/code-server.
docker rm -f "$container" >/dev/null
docker run -d \
    --name "$container" \
    -e GITHUB_USER= \
    -e CODE_SERVER_AUTH=none \
    -e TS_ENABLE=true \
    "$image" >/dev/null
sleep 3
docker exec "$container" pgrep -x sshd >/dev/null
docker exec "$container" pgrep -f code-server >/dev/null
docker logs "$container" 2>&1 | grep -q '/dev/net/tun is unavailable'
[ "$(docker inspect -f '{{.State.Running}}' "$container")" = true ]

# When the runner exposes TUN, also exercise the enabled daemon path without
# joining a tailnet. This verifies the state directory and LocalAPI socket.
if [ -c /dev/net/tun ]; then
    docker rm -f "$container" >/dev/null
    docker run -d \
        --name "$container" \
        --device /dev/net/tun:/dev/net/tun \
        --cap-add NET_ADMIN \
        --cap-add NET_RAW \
        -e GITHUB_USER= \
        -e CODE_SERVER_AUTH=none \
        -e TS_ENABLE=true \
        "$image" >/dev/null
    for _ in {1..30}; do
        if docker exec "$container" test -S /run/tailscale/tailscaled.sock \
            && docker exec "$container" tailscale \
                --socket=/run/tailscale/tailscaled.sock status --json >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
    docker exec "$container" test -S /run/tailscale/tailscaled.sock
    docker exec "$container" tailscale \
        --socket=/run/tailscale/tailscaled.sock status --json >/dev/null
    docker exec "$container" pgrep -x tailscaled >/dev/null
    docker exec "$container" pgrep -x sshd >/dev/null
    docker exec "$container" pgrep -f code-server >/dev/null
fi

# Rootless Docker needs the outer container's relaxed security profile. Verify
# that the daemon runs as the dedicated user and can build and start an inner
# container without depending on an external image registry.
docker rm -f "$container" >/dev/null
docker run -d \
    --name "$container" \
    --privileged \
    -e GITHUB_USER= \
    -e CODE_SERVER_AUTH=none \
    -e DOCKERD_ROOTLESS_ENABLE=true \
    "$image" >/dev/null
rootless_ready=0
for _ in {1..60}; do
    if docker exec "$container" docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q rootless; then
        rootless_ready=1
        break
    fi
    sleep 1
done
if [ "$rootless_ready" -ne 1 ]; then
    docker logs "$container" >&2
    exit 1
fi
docker exec "$container" test -S /run/user/1000/docker.sock
docker exec "$container" docker info --format '{{json .SecurityOptions}}' | grep -q rootless
docker exec "$container" bash -c 'test "$(ps -C dockerd -o user= | tr -d " ")" = dockerd'
docker exec -i "$container" /bin/bash -se <<'INNER_DOCKER_SMOKE'
set -o pipefail
context="$(mktemp -d)"
trap 'rm -rf "$context"' EXIT

mkdir -p "$context/rootfs"
cp --parents /usr/bin/true "$context/rootfs"
ldd /usr/bin/true | awk '/=> \// { print $3 } /^\// { print $1 }' | while IFS= read -r library; do
    cp --parents "$library" "$context/rootfs"
done

docker build --quiet -t rootless-dind-smoke -f - "$context" <<'DOCKERFILE'
FROM scratch
COPY rootfs/ /
ENTRYPOINT ["/usr/bin/true"]
DOCKERFILE
docker run --rm rootless-dind-smoke
INNER_DOCKER_SMOKE
docker exec "$container" pgrep -x sshd >/dev/null
docker exec "$container" pgrep -f code-server >/dev/null

echo "Smoke tests passed for $image"
