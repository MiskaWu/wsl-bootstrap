#!/usr/bin/env bash
# =============================================================================
# Phase 1 (root): 系統更新 + 建 user + /etc/wsl.conf (systemd + default user)
# 執行後需要 wsl --shutdown 才會讓 systemd / default user 生效。
# 由 bootstrap.ps1 透過環境變數傳入設定。
# =============================================================================
set -euo pipefail

: "${BS_USER:?BS_USER not set}"

log() { printf '\033[1;34m[phase1]\033[0m %s\n' "$*"; }

log "apt update / upgrade"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

log "建立 user: ${BS_USER}"
if ! id "${BS_USER}" &>/dev/null; then
  useradd -m -s /bin/bash -G sudo "${BS_USER}"
  # 免密碼 sudo（開發機常見；不想要的話刪掉這行改用 passwd 設密碼）
  echo "${BS_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${BS_USER}"
  chmod 0440 "/etc/sudoers.d/${BS_USER}"
else
  log "user 已存在，略過"
fi

log "寫入 /etc/wsl.conf"
cat > /etc/wsl.conf <<EOF
[boot]
systemd=true

[user]
default=${BS_USER}

[network]
generateResolvConf=true

[interop]
appendWindowsPath=true
EOF

log "phase1 完成 —— 需要 wsl --shutdown"
