# docker-image

Debian-based development image with s6-overlay, OpenSSH, code-server, Git, curl/wget, tmux, vim, network tools, and `uv`.

At startup, s6-overlay runs an initialization step that can download public SSH keys from GitHub using the `GITHUB_USER` environment variable and write them to `/root/.ssh/authorized_keys`. SSH login is configured for root public-key authentication only.

## Build locally

```bash
docker build -t docker-image:local .
```

## Run

This image uses s6-overlay as PID 1 and does not require `privileged`, cgroup mounts, or Docker Compose `init: true` for normal SSH and code-server usage.

```bash
docker run -d \
  --name docker-image \
  -e GITHUB_USER=rabbit-dayi \
  -e PASSWORD='change-this-password' \
  -p 2222:22 \
  -p 8080:8080 \
  -v docker-image-root:/root \
  -v docker-image-workspace:/workspace \
  docker-image:local
```

SSH:

```bash
ssh root@localhost -p 2222
```

code-server:

```text
http://localhost:8080
```

## Docker Compose

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

## Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `GITHUB_USER` | `rabbit-dayi` | GitHub username used to fetch public SSH keys from `https://github.com/<user>.keys`. |
| `CODE_SERVER_BIND_ADDR` | `0.0.0.0:8080` | code-server bind address. |
| `CODE_SERVER_AUTH` | `password` | code-server auth mode. Use `none` only behind a trusted network, SSH tunnel, or reverse proxy. |
| `PASSWORD` | unset | Runtime code-server password when `CODE_SERVER_AUTH=password`. |
| `HASHED_PASSWORD` | unset | Runtime hashed code-server password alternative. |
| `CODE_SERVER_WORKDIR` | `/workspace` | Initial code-server workspace. |

To use another GitHub account's public SSH keys:

```bash
docker run -d \
  --name docker-image \
  -e GITHUB_USER=<github-user> \
  -e PASSWORD='change-this-password' \
  -p 2222:22 \
  -p 8080:8080 \
  docker-image:local
```

To keep an existing `/root/.ssh/authorized_keys` instead of downloading from GitHub, set `GITHUB_USER` to an empty value and mount or bake your own keys:

```bash
docker run -d \
  --name docker-image \
  -e GITHUB_USER= \
  -e PASSWORD='change-this-password' \
  -p 2222:22 \
  -p 8080:8080 \
  docker-image:local
```

If GitHub key download fails because DNS or network access is unavailable, the container logs a warning and keeps starting. Mount or bake `/root/.ssh/authorized_keys` if SSH access must work without outbound GitHub access.

GitHub `.keys` URLs expose public SSH keys only. Do not put private keys or personal access tokens in environment variables, image layers, or committed files.

## GitHub Container Registry

GitHub Actions builds this image on pushes to `main`, version tags, pull requests, and manual dispatches.

Non-PR builds publish to:

```text
ghcr.io/rabbit-dayi/docker-image
```

After the first successful publish, make sure the package visibility in GitHub Container Registry matches the repository visibility you want.

## Security note

If a GitHub personal access token was pasted into chat, revoke it in GitHub settings and create a new token only if needed. This project does not require committing or storing a PAT; GitHub Actions uses the repository-provided `GITHUB_TOKEN` for GHCR publishing.
