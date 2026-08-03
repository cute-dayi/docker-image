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
        /usr/local/bin/docker-image-banner \
        /usr/local/bin/configure-resolv /usr/local/bin/resolver-web.js \
        /usr/local/bin/dev /usr/local/bin/update-status /usr/local/bin/docker-image-manager \
        docker dockerd dockerd-rootless.sh newuidmap newgidmap \
        slirp4netns fuse-overlayfs ldd \
        htop jq lsof ncdu tree dig mtr tcpdump rsync socat pstree strace \
        sshfs fusermount3 \
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
        /usr/local/bin/configure-resolv \
        /usr/local/bin/docker-image-banner \
        /usr/local/bin/dev /usr/local/bin/update-status \
        /etc/s6-overlay/s6-rc.d/runtime-status/run \
        /etc/s6-overlay/s6-rc.d/code-server/run \
        /etc/s6-overlay/s6-rc.d/dockerd-rootless/run \
        /etc/s6-overlay/s6-rc.d/manager/run \
        /etc/s6-overlay/s6-rc.d/nginx/run \
        /etc/s6-overlay/s6-rc.d/resolver-web/run \
        /etc/s6-overlay/s6-rc.d/tailscaled/run
    node --check /usr/local/bin/resolver-web.js
    test "${CONTAINER_STATE_DIR}" = /opt/__container
    test "${CODE_SERVER_USER_DATA_DIR}" = /opt/__container/code-server
    test "${RESOLV_STATE_FILE}" = /opt/__container/resolver.json
    test "${TS_STATE_DIR}" = /opt/__container/tailscale
    test "${DOCKERD_DATA_ROOT}" = /opt/__container/docker
    test "${DOCKERD_CONFIG_DIR}" = /opt/__container/dockerd/config
    test "${DOCKERD_CACHE_DIR}" = /opt/__container/dockerd/cache
    test "${NPM_CONFIG_CACHE}" = /opt/__container/npm
    test "${UV_CACHE_DIR}" = /opt/__container/uv
    test "${MANAGER_CONFIG_DIR}" = /opt/__container
    grep -Fq -- "--user-data-dir \"\$user_data_dir\"" /etc/s6-overlay/s6-rc.d/code-server/run
    grep -Fq '/opt/__container/resolver.json' /usr/local/bin/configure-resolv
    grep -Fq '/opt/__container/tailscale' /etc/s6-overlay/s6-rc.d/tailscaled/run
    grep -Fq '/opt/__container/docker' /etc/s6-overlay/s6-rc.d/dockerd-rootless/run
    resolv_test_file="$(mktemp)"
    printf 'nameserver 9.9.9.9\n' >"$resolv_test_file"
    resolv_before="$(sha256sum "$resolv_test_file")"
    RESOLV_CONFIG_FILE="$resolv_test_file" RESOLV_AUTO_CONFIG=false \
        /usr/local/bin/configure-resolv >/dev/null
    [ "$resolv_before" = "$(sha256sum "$resolv_test_file")" ]
    rm -f "$resolv_test_file"
    resolv_test_dir="$(mktemp -d)"
    resolv_test_file="$resolv_test_dir/resolv.conf"
    printf "search internal.example\nnameserver 9.9.9.9\n" >"$resolv_test_file"
    printf "#!/bin/sh\necho \\;\\; SERVER:\n" >"$resolv_test_dir/dig"
    chmod 755 "$resolv_test_dir/dig"
    PATH="$resolv_test_dir:$PATH" \
        RESOLV_CONFIG_FILE="$resolv_test_file" \
        /usr/local/bin/configure-resolv >/dev/null
    grep -q "^nameserver 127.0.0.1$" "$resolv_test_file"
    grep -q "^nameserver 1.1.1.1$" "$resolv_test_file"
    [ "$(grep -c "^nameserver 9.9.9.9$" "$resolv_test_file")" = 1 ]
    [ "$(stat -c "%a" "$resolv_test_file")" = 644 ]
    rm -rf "$resolv_test_dir"
    banner="$(NGINX_SERVER_NAMES=code.example.test \
        NGINX_SERVICE_LINKS="Echo|/echo|127.0.0.1:8080" \
        RESOLV_WEB_PASSWORD=smoke-secret \
        /usr/local/bin/docker-image-banner)"
    printf '%s\n' "$banner" | grep -Fq 'DOCKER IMAGE'
    printf '%s\n' "$banner" | grep -Fq 'https://code.example.test:443/services/'
    printf '%s\n' "$banner" | grep -Fq 'https://code.example.test:443/dns/'
    /usr/local/bin/docker-image-banner | grep -Fq 'DNS       disabled'
    [ -z "$(STARTUP_BANNER=false /usr/local/bin/docker-image-banner)" ]
    /usr/local/bin/dev help | grep -Fq 'status'
    NGINX_SERVER_NAMES=code.example.test \
        NGINX_SERVICE_LINKS="Echo|/echo|127.0.0.1:8080" \
        /etc/s6-overlay/scripts/configure-nginx
    ! grep -Fq "location = /dns/" /run/nginx/nginx.conf
    ! grep -Fq "location ^~ /dns/api/" /run/nginx/nginx.conf
    NGINX_SERVER_NAMES=code.example.test \
        RESOLV_WEB_ALLOW_UNAUTHENTICATED=true \
        /etc/s6-overlay/scripts/configure-nginx
    grep -Fq "location = /dns/" /run/nginx/nginx.conf
    ! grep -Fq "auth_basic_user_file" /run/nginx/nginx.conf
    NGINX_SERVER_NAMES=code.example.test \
        NGINX_SERVICE_LINKS="Echo|/echo|127.0.0.1:8080" \
        RESOLV_WEB_PASSWORD=smoke-secret \
        /etc/s6-overlay/scripts/configure-nginx
    nginx -t -q -c /run/nginx/nginx.conf
    openssl x509 -in /run/nginx/default-certificate/tls.crt -noout -ext subjectAltName \
        | grep -q "DNS:code.example.test"
    grep -Fq "location ^~ /echo/" /run/nginx/nginx.conf
    grep -Fq "proxy_pass http://127.0.0.1:8080/;" /run/nginx/nginx.conf
    grep -Fq "href=\"/echo/\"" /run/nginx/services/index.html
    grep -Fq "href=\"/status/\"" /run/nginx/services/index.html
    grep -Fq "location = /status/" /run/nginx/nginx.conf
    grep -Fq status.json /run/nginx/status/index.html
    grep -Fq "location = /dns/" /run/nginx/nginx.conf
    grep -Fq "location ^~ /dns/api/" /run/nginx/nginx.conf
    grep -Fq "proxy_read_timeout 20s" /run/nginx/nginx.conf
    grep -Fq "auth_basic_user_file /run/nginx/resolver.htpasswd;" /run/nginx/nginx.conf
    test "$(stat -c "%a %U %G" /run/nginx/resolver.htpasswd)" = "640 root www-data"
    test -s /run/nginx/dns/index.html
    test -s /run/nginx/status/status.json
    PASSWORD=smoke-secret \
        NGINX_SERVER_NAMES=code.example.test \
        NGINX_SERVICE_LINKS="Echo|/echo|127.0.0.1:8080" \
        /etc/s6-overlay/scripts/configure-nginx
    nginx -t -q -c /run/nginx/nginx.conf
    grep -Fq "auth_basic \"Docker image\";" /run/nginx/nginx.conf
    grep -Fq "auth_basic_user_file /run/nginx/gateway.htpasswd;" /run/nginx/nginx.conf
    grep -Fq "location = /healthz" /run/nginx/nginx.conf
    grep -Fq "location ^~ /manage/api/" /run/nginx/nginx.conf
    grep -Fq "proxy_set_header Host \$http_host;" /run/nginx/nginx.conf
    grep -Fq "auth_basic off;" /run/nginx/nginx.conf
    ! test -e /run/nginx/resolver.htpasswd
    test "$(stat -c "%a %U %G" /run/nginx/gateway.htpasswd)" = "640 root www-data"
    STATUS_ONCE=true \
        NGINX_SERVICE_LINKS="Echo|/echo|127.0.0.1:8080" \
        /usr/local/bin/update-status
    jq -e ".services | length == 2" \
        /run/nginx/status/status.json >/dev/null
    /usr/local/bin/dev routes | grep -Fq 'Echo'

    tunnel_test_dir="$(mktemp -d)"
    printf "%s\n" \
        "#!/bin/bash" \
        "trap \"exit 0\" TERM INT" \
        "printf \"https://smoke-test.trycloudflare.com\\n\" >&2" \
        "while :; do sleep 1; done" \
        >"$tunnel_test_dir/cloudflared"
    chmod 755 "$tunnel_test_dir/cloudflared"
    CLOUDFLARED_BIN="$tunnel_test_dir/cloudflared" \
        RESOLV_WEB_PORT=18787 \
        RESOLV_STATE_FILE="$tunnel_test_dir/resolver.json" \
        node /usr/local/bin/resolver-web.js >"$tunnel_test_dir/first.log" 2>&1 &
    resolver_pid=$!
    for _ in $(seq 1 30); do
        curl -fsS http://127.0.0.1:18787/api/tunnel >/dev/null 2>&1 && break
        sleep 0.1
    done
    tunnel_result="$(curl -fsS -X POST \
        -H "Content-Type: application/json" \
        --data "{\"target\":\"127.0.0.1:8080\"}" \
        http://127.0.0.1:18787/api/tunnel/start)"
    tunnel_pid="$(printf "%s\n" "$tunnel_result" | jq -r .pid)"
    kill -0 "$tunnel_pid"
    kill -KILL "$resolver_pid"
    wait "$resolver_pid" 2>/dev/null || true
    kill -0 "$tunnel_pid"
    CLOUDFLARED_BIN="$tunnel_test_dir/cloudflared" \
        RESOLV_WEB_PORT=18787 \
        RESOLV_STATE_FILE="$tunnel_test_dir/resolver.json" \
        node /usr/local/bin/resolver-web.js >"$tunnel_test_dir/second.log" 2>&1 &
    resolver_pid=$!
    for _ in $(seq 1 60); do
        if curl -fsS http://127.0.0.1:18787/api/tunnel \
            | jq -e ".running == false" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
    curl -fsS http://127.0.0.1:18787/api/tunnel | jq -e ".running == false" >/dev/null
    ! kill -0 "$tunnel_pid" 2>/dev/null
    kill -TERM "$resolver_pid"
    wait "$resolver_pid"
    rm -rf "$tunnel_test_dir"

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
    if NGINX_SERVICE_LINKS="bad|/services|127.0.0.1:8080" \
        /etc/s6-overlay/scripts/configure-nginx >/dev/null 2>&1; then
        echo "Reserved NGINX_SERVICE_LINKS path was accepted" >&2
        exit 1
    fi
    if NGINX_SERVICE_LINKS="bad|/status|127.0.0.1:8080" \
        /etc/s6-overlay/scripts/configure-nginx >/dev/null 2>&1; then
        echo "Reserved status path was accepted" >&2
        exit 1
    fi
    if NGINX_SERVICE_LINKS="bad|/status.json|127.0.0.1:8080" \
        /etc/s6-overlay/scripts/configure-nginx >/dev/null 2>&1; then
        echo "Reserved status JSON path was accepted" >&2
        exit 1
    fi
    if NGINX_SERVICE_LINKS="bad|/dns|127.0.0.1:8080" \
        /etc/s6-overlay/scripts/configure-nginx >/dev/null 2>&1; then
        echo "Reserved DNS path was accepted" >&2
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
    -e PASSWORD=smoke-secret \
    -e NGINX_SERVER_NAMES=smoke.example.test \
    -e NGINX_SERVICE_LINKS='Echo|/echo|127.0.0.1:8080' \
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
    if docker logs "$container" 2>&1 | grep -Fq 'DOCKER IMAGE'; then
        break
    fi
    sleep 1
done
docker logs "$container" 2>&1 | grep -Fq 'DOCKER IMAGE'

for _ in {1..30}; do
    curl --noproxy '*' -fkS \
        --resolve "smoke.example.test:${https_port}:127.0.0.1" \
        "https://smoke.example.test:${https_port}/healthz" >/dev/null 2>&1 && break
    sleep 1
done
curl --noproxy '*' -fkS \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/healthz" >/dev/null
portal_page="$(curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/services/")"
printf '%s\n' "$portal_page" | grep -Fq 'href="/echo/"'
curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/echo/healthz" >/dev/null
redirect_headers="$(curl --noproxy '*' -skSI \
    --resolve "smoke.example.test:${http_port}:127.0.0.1" \
    "http://smoke.example.test:${http_port}/healthz" | tr -d '\r')"
printf '%s\n' "$redirect_headers" | grep -qE '^HTTP/.* 308'
printf '%s\n' "$redirect_headers" | grep -qi '^location: https://smoke.example.test/healthz$'
[ "$original_keys" = "$(sha256sum "$tmpdir/authorized_keys")" ]
status_page="$(curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/status/")"
printf '%s\n' "$status_page" | grep -Fq 'Container status'
status_json="$(curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/status.json")"
printf '%s\n' "$status_json" | jq -e '.services | map(select(.name == "Echo")) | length == 1' >/dev/null
printf '%s\n' "$status_json" | jq -e '.components.code_server == "up"' >/dev/null
root_unauthenticated_status="$(curl --noproxy '*' -skS -o /dev/null -w '%{http_code}' \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/")"
[ "$root_unauthenticated_status" = 401 ]
curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/" >/dev/null
dns_unauthenticated_status="$(curl --noproxy '*' -skS -o /dev/null -w '%{http_code}' \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/dns/api/resolver")"
[ "$dns_unauthenticated_status" = 401 ]
dns_page="$(curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/dns/")"
printf '%s\n' "$dns_page" | grep -Fq 'id="resolver-form"'
printf '%s\n' "$dns_page" | grep -Fq 'https://try.cloudflare.com/'
printf '%s\n' "$dns_page" | grep -Fq 'id="tunnel-start"'
dns_json="$(curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/dns/api/resolver")"
printf '%s\n' "$dns_json" | jq -e '.config.local_nameserver == "127.0.0.1"' >/dev/null
tunnel_json="$(curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/dns/api/tunnel")"
printf '%s\n' "$tunnel_json" | jq -e '.running == false and .default_target == "http://127.0.0.1:8080"' >/dev/null
tunnel_invalid="$(curl --noproxy '*' -skS -X POST \
    -u admin:smoke-secret \
    -H 'Content-Type: application/json' \
    --data '{"target":"file:///etc/passwd"}' \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/dns/api/tunnel/start")"
printf '%s\n' "$tunnel_invalid" | jq -e '.error | contains("HTTP(S)")' >/dev/null
dns_apply="$(curl --noproxy '*' -fkS -X POST \
    -u admin:smoke-secret \
    -H 'Content-Type: application/json' \
    --data '{"auto_config":false,"local_nameserver":"127.0.0.1","fallback_nameserver":"1.1.1.1","fallback_always":false,"check_domain":"example.com"}' \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/dns/api/resolver/apply")"
printf '%s\n' "$dns_apply" | jq -e '.applied == true' >/dev/null
docker exec "$container" jq -e '.auto_config == false' /opt/__container/resolver.json >/dev/null
manager_page="$(curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/manage/")"
printf '%s\n' "$manager_page" | grep -Fq 'Certificate management'
certificate_json="$(curl --noproxy '*' -fkS \
    -u admin:smoke-secret \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/manage/api/certificate")"
printf '%s\n' "$certificate_json" | jq -e '.source == "generated" and .upload_enabled == true' >/dev/null
openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 30 \
    -keyout "$tmpdir/uploaded.key" \
    -out "$tmpdir/uploaded.crt" \
    -subj '/CN=uploaded.example.test' \
    -addext 'subjectAltName=DNS:uploaded.example.test' >/dev/null 2>&1
uploaded_json="$(curl --noproxy '*' -fkS -X POST \
    -u admin:smoke-secret \
    -H 'X-Requested-With: docker-image-manager' \
    -H "Origin: https://smoke.example.test:${https_port}" \
    -F certificate=@"$tmpdir/uploaded.crt" \
    -F private_key=@"$tmpdir/uploaded.key" \
    --resolve "smoke.example.test:${https_port}:127.0.0.1" \
    "https://smoke.example.test:${https_port}/manage/api/certificate")"
printf '%s\n' "$uploaded_json" | jq -e '.source == "uploaded" and (.names | index("uploaded.example.test")) != null' >/dev/null
docker exec "$container" test -L /opt/__container/tls/current
docker exec "$container" test -f /opt/__container/tls/current/tls.crt
docker exec "$container" dev status | grep -Fq 'components:'
docker exec "$container" dev routes | grep -Fq 'Echo'
docker exec "$container" pgrep -x sshd >/dev/null
docker exec "$container" pgrep -f code-server >/dev/null
docker exec "$container" pgrep -af code-server | grep -Fq -- '--auth none'
docker exec "$container" pgrep -af code-server | grep -Fq -- '--user-data-dir /opt/__container/code-server'
docker exec "$container" pgrep -x nginx >/dev/null
docker exec "$container" openssl x509 \
    -in /opt/__container/tls/current/tls.crt -noout -subject \
    | grep -q 'CN = uploaded.example.test'
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

# Rootless Docker needs the outer container's relaxed security profile and a
# runner that exposes FUSE plus unprivileged user namespaces. Keep the rest of
# the smoke test useful on hosted runners that intentionally restrict either.
rootless_capable=1
if ! docker run --rm --privileged --entrypoint /bin/bash "$image" -c '
    set -e
    test -c /dev/fuse
    /command/s6-setuidgid dockerd /usr/bin/unshare --user --map-root-user true >/dev/null 2>&1
'; then
    rootless_capable=0
    echo "Skipping rootless Docker integration: runner lacks /dev/fuse or unprivileged user namespaces." >&2
fi

if [ "$rootless_capable" -eq 1 ]; then
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
fi

echo "Smoke tests passed for $image"
