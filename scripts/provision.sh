#!/usr/bin/env bash
# =============================================================================
# Provision (root)：把乾淨的 Ubuntu WSL distro 帶到「git-ready、可以 clone + make 起手」。
#   - 建 user + NOPASSWD sudo
#   - /etc/wsl.conf（systemd + 預設 user）
#   - baseline：git + make + openssh-client（clone repo + Makefile 起手 + git over ssh）
#   - git 身分（~/.gitconfig）與 SSH keys（每 scope 一把 ed25519）—— 裝完就 git-ready，
#     能直接 commit、貼 key 到 GitHub/GitLab、clone 私有 repo
#   - OOBE metrics opt-out（首次互動啟動不再跳提問）
#
# 軟體工作環境（ansible、podman、go、claude、toolchain…）**都不在這裡** —— 交給你的組態
# 管理 repo 自己裝。連 ansible 都不在 baseline：那個 repo 的 Makefile 會在需要時自己
# `apt install ansible-core`（不能用 ansible 裝 ansible，所以由 make 這層補）。make 要在
# baseline 是因為它是那個 repo 的操作入口、指令本身得先存在（第二層雞生蛋）。
# git 身分/keys 放這裡（不放軟體 repo）是刻意的：它們是「一台個人機」的一部分，且 key 得
# 先在才能 clone 私有 repo —— host-agnostic 但屬於 bring-up。
# 執行後需 `wsl --shutdown` 讓 systemd / 預設 user 生效。
# =============================================================================
set -euo pipefail

: "${BS_USER:?BS_USER not set}"

log() { printf '\033[1;34m[provision]\033[0m %s\n' "$*"; }

export DEBIAN_FRONTEND=noninteractive

log "apt update / upgrade"
apt-get update -y
apt-get upgrade -y

log "建立 user: ${BS_USER}"
if ! id "${BS_USER}" &>/dev/null; then
  useradd -m -s /bin/bash -G sudo "${BS_USER}"
  # 免密碼 sudo（開發機常見；不想要就刪這行改設密碼）
  echo "${BS_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${BS_USER}"
  chmod 0440 "/etc/sudoers.d/${BS_USER}"
else
  log "user 已存在，略過"
fi

log "baseline：git make openssh-client（clone repo + Makefile 起手 + git/ssh-keygen；其餘由該 repo 自己裝）"
apt-get install -y git make openssh-client

# OOBE metrics opt-out（Ubuntu 26.04 的 ubuntu-insights）。
# 首次互動啟動時 wsl-setup 會問「opt-in platform metrics?」——這違反零互動。
# 官方認可的做法：預先為該 user 寫 consent 檔（consent_state=false），OOBE 偵測到
# 有效 consent 檔就跳過提問、且覆蓋 Windows registry 的預設。
# 至少要有 wsl_setup 這個 source；linux / ubuntu_release_upgrader 一併關掉月度回報。
log "OOBE metrics opt-out（consent=false）"
home="$(getent passwd "${BS_USER}" | cut -d: -f6)"
# 用 runuser 以 user 身分建目錄，確保連 ~/.config 這層中間目錄都是 user 所有。
# （root 的 `install -d a/b` 會把中間的 a 建成 root，之後 podman / ansible 要在
#   ~/.config 下動東西會 permission denied 或警告。）
runuser -u "${BS_USER}" -- mkdir -p "${home}/.config/ubuntu-insights"
for src in linux wsl_setup ubuntu_release_upgrader; do
  f="${home}/.config/ubuntu-insights/${src}-consent.toml"
  printf 'consent_state = false\n' > "$f"
  chown "${BS_USER}:${BS_USER}" "$f"
  chmod 0644 "$f"
done

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

# ---- git 身分（設在 user 的 global config；未給就略過）----------------------
if [ -n "${BS_GIT_NAME:-}" ] && [ -n "${BS_GIT_EMAIL:-}" ]; then
  log "git 身分：${BS_GIT_NAME} <${BS_GIT_EMAIL}>"
  runuser -u "${BS_USER}" -- git config --global user.name  "${BS_GIT_NAME}"
  runuser -u "${BS_USER}" -- git config --global user.email "${BS_GIT_EMAIL}"
else
  log "未設 BS_GIT_NAME/BS_GIT_EMAIL，略過 git 身分"
fi

# ---- SSH keys（每個 scope 一把 ed25519，無 passphrase；冪等：已存在跳過）------
# 生成後印出公鑰，讓你裝完就能貼到 GitHub/GitLab、clone 私有 repo。
if [ -n "${BS_SSH_KEY_SCOPES:-}" ]; then
  tag="${BS_SSH_KEY_TAG:-dev}"
  comment="${BS_SSH_KEY_COMMENT:-${BS_USER}@$(hostname)}"
  today="$(date +%F)"
  runuser -u "${BS_USER}" -- install -d -m 0700 "${home}/.ssh"
  for scope in ${BS_SSH_KEY_SCOPES}; do
    key="${home}/.ssh/id_ed25519_${tag}_${scope}"
    if [ -f "$key" ]; then
      log "SSH key 已存在，略過：$(basename "$key")"
    else
      log "產生 SSH key：$(basename "$key")"
      runuser -u "${BS_USER}" -- ssh-keygen -t ed25519 -N '' \
        -C "${comment}-${scope} ${today}" -f "$key"
    fi
  done
  log "SSH 公鑰（貼到 GitHub/GitLab）："
  for scope in ${BS_SSH_KEY_SCOPES}; do
    pub="${home}/.ssh/id_ed25519_${tag}_${scope}.pub"
    [ -f "$pub" ] && printf '  %s\n' "$(cat "$pub")"
  done
else
  log "未設 BS_SSH_KEY_SCOPES，略過 SSH keys"
fi

log "provision 完成 —— 需要 wsl --shutdown"
