#!/usr/bin/env bash
set -euo pipefail

image="${1:?usage: tests/smoke.sh IMAGE}"
container="docker-image-smoke-${RANDOM}"
tmpdir="$(mktemp -d)"
cleanup() {
    docker rm -f "$container" >/dev/null 2>&1 || true
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
    command -v /init sshd code-server uv tailscale tailscaled >/dev/null
    bash -n /etc/s6-overlay/scripts/init-root \
        /etc/s6-overlay/scripts/configure-tailscale \
        /etc/s6-overlay/s6-rc.d/code-server/run \
        /etc/s6-overlay/s6-rc.d/tailscaled/run
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
    -e TS_ENABLE=false \
    -p 127.0.0.1::22 \
    -p 127.0.0.1::8080 \
    -v "$tmpdir/authorized_keys:/root/.ssh/authorized_keys:ro" \
    "$image" >/dev/null

ssh_port="$(docker port "$container" 22/tcp | sed 's/.*://')"
http_port="$(docker port "$container" 8080/tcp | sed 's/.*://')"
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
    curl -fsS "http://127.0.0.1:${http_port}/healthz" >/dev/null 2>&1 && break
    sleep 1
done
curl -fsS "http://127.0.0.1:${http_port}/healthz" >/dev/null
[ "$original_keys" = "$(sha256sum "$tmpdir/authorized_keys")" ]
docker exec "$container" pgrep -x sshd >/dev/null
docker exec "$container" pgrep -f code-server >/dev/null
[ "$(docker inspect -f '{{.RestartCount}}' "$container")" = 0 ]

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

echo "Smoke tests passed for $image"
