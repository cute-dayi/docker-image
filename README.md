# docker-image

Debian-based development image with OpenSSH, systemd, Git, curl/wget, tmux, vim, network tools, and `uv`.

On container startup, the entrypoint downloads public SSH keys from GitHub using the `GITHUB_USER` environment variable and writes them to `/root/.ssh/authorized_keys`. SSH login is configured for root public-key authentication only.

## Build locally

```bash
docker build -t docker-image:local .
```

## Run

Because the image starts systemd as PID 1, run it with cgroup mounted and the privileges systemd needs. Do not also enable Docker's `--init` flag for this container.

```bash
docker run -d \
  --name docker-image \
  --privileged \
  --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -e GITHUB_USER=rabbit-dayi \
  -p 2222:22 \
  docker-image:local
```

Connect with:

```bash
ssh root@localhost -p 2222
```

To use another GitHub account's public SSH keys:

```bash
docker run -d \
  --name docker-image \
  --privileged \
  --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -e GITHUB_USER=<github-user> \
  -p 2222:22 \
  docker-image:local
```

For Docker Compose, do not set `init: true`; systemd must be the container's PID 1.

To keep an existing `/root/.ssh/authorized_keys` instead of downloading from GitHub, set `GITHUB_USER` to an empty value and mount or bake your own keys:

```bash
docker run -d \
  --name docker-image \
  --privileged \
  --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -e GITHUB_USER= \
  -p 2222:22 \
  docker-image:local
```

If GitHub key download fails because DNS or network access is unavailable, the container logs a warning and keeps starting. Mount or bake `/root/.ssh/authorized_keys` if SSH access must work without outbound GitHub access.

GitHub `.keys` URLs expose public SSH keys only. Do not put private keys or personal access tokens in environment variables, image layers, or committed files.

## GitHub Container Registry

GitHub Actions builds this image on pushes to `main`, version tags, pull requests, and manual dispatches.

Non-PR builds publish to:

```text
ghcr.io/<owner>/docker-image
```

After the first successful publish, make sure the package visibility in GitHub Container Registry matches the repository visibility you want.

## Security note

If a GitHub personal access token was pasted into chat, revoke it in GitHub settings and create a new token only if needed. This project does not require committing or storing a PAT; GitHub Actions uses the repository-provided `GITHUB_TOKEN` for GHCR publishing.
