#!/bin/bash
set -e

# --- 颜色定义 ---
GREEN='\033[0;32m'
NC='\033[0m' 
BACKUP_FILE="/usr/share/root_backup.tar.gz"

echo -e "${GREEN}[Entrypoint] Starting initialization...${NC}"

# --- 1. 智能恢复 /root ---
# 检查 .bashrc 是否存在。如果不存在，通常意味着 /root 被挂载了空卷，或者目录丢失。
if [ ! -f "/root/.bashrc" ]; then
    echo -e "${GREEN}[Entrypoint] /root appears empty or mounted (missing .bashrc). Restoring from backup...${NC}"
    
    # 解压备份
    # -k (--keep-old-files): 安全起见，如果目标文件已存在（用户手动放进去的），不要覆盖
    # -C / : 还原到根目录 (因为包内路径是 root/xxx)
    tar -xzf "$BACKUP_FILE" -C / --keep-newer-files 2>/dev/null || true
    
    echo -e "${GREEN}[Entrypoint] Restore complete.${NC}"
else
    echo -e "${GREEN}[Entrypoint] /root contains data. Skipping restore.${NC}"
fi

# --- 2. 下载 GitHub SSH 公钥 ---
mkdir -p /root/.ssh

if [ -n "${GITHUB_USER:-}" ]; then
    if [[ ! "$GITHUB_USER" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
        echo "[Entrypoint] Invalid GitHub username: ${GITHUB_USER}" >&2
        exit 1
    fi

    echo -e "${GREEN}[Entrypoint] Downloading GitHub SSH keys for ${GITHUB_USER}...${NC}"
    tmp_keys="$(mktemp)"
    if curl -fsSL "https://github.com/${GITHUB_USER}.keys" -o "$tmp_keys" && [ -s "$tmp_keys" ]; then
        mv "$tmp_keys" /root/.ssh/authorized_keys
        echo -e "${GREEN}[Entrypoint] GitHub SSH keys installed.${NC}"
    else
        rm -f "$tmp_keys"
        echo "[Entrypoint] Failed to download non-empty GitHub SSH keys for ${GITHUB_USER}." >&2
        exit 1
    fi
else
    echo -e "${GREEN}[Entrypoint] GITHUB_USER is empty. Keeping existing authorized_keys.${NC}"
    touch /root/.ssh/authorized_keys
fi

# --- 3. 权限修正 (至关重要) ---
# 无论是还原的还是挂载的，必须确保 SSH 权限正确，否则 StrictModes 会拒绝连接
chmod 700 /root/.ssh 2>/dev/null || true
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
chown -R root:root /root 2>/dev/null || true

# --- 4. 生成主机密钥 ---
# 如果 /etc/ssh 被挂载或密钥丢失，重新生成
ssh-keygen -A

# --- 5. 准备 SSH 服务运行目录 ---
mkdir -p /var/run/sshd

echo -e "${GREEN}[Entrypoint] Initialization done. Executing command: $@${NC}"

# --- 6. 执行主命令 ---
exec "$@"