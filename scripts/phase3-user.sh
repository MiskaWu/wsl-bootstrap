#!/usr/bin/env bash
# =============================================================================
# Phase 3 (user): Claude Code + Go + 可選 toolchain + SSH key + shell 設定
# 以目標 user 身分執行（非 root）。
#
# 環境變數:
#   BS_RUNTIME, BS_COMPOSE_SHIM
#   BS_GO_VERSION
#   BS_INSTALL_NODE, BS_NODE_VERSION
#   BS_INSTALL_PYTHON
#   BS_INSTALL_CLIENTS
#   BS_GEN_SSH, BS_SSH_SCOPES (逗號分隔), BS_SSH_COMMENT, BS_SSH_TAG
# =============================================================================

# add_profile / add_bashrc 的參數一律用單引號：要寫進檔案的是字面的 $HOME、
# $(id -u)，等 login 時才展開。改成雙引號會在這裡就展開成 build 當下的值，
# 整個寫死。這是刻意的，所以整份檔案關掉 SC2016。
# shellcheck disable=SC2016

set -euo pipefail

log() { printf '\033[1;32m[phase3]\033[0m %s\n' "$*"; }

BS_GO_VERSION="${BS_GO_VERSION:-1.23.4}"
BS_RUNTIME="${BS_RUNTIME:-podman}"
BS_COMPOSE_SHIM="${BS_COMPOSE_SHIM:-true}"

# --- helper: 冪等地把一行加進指定檔案 ---------------------------------------
add_line() {
  local file="$1" line="$2"
  grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

# 環境變數放 ~/.profile：.bashrc 開頭對非互動 shell 就 return，寫在那裡的
# export 只有互動 shell 吃得到，`wsl -d <distro> -e <cmd>` 和腳本都讀不到。
add_profile() { add_line "$HOME/.profile" "$1"; }
# alias 本來就只對互動 shell 有意義，放 .bashrc 是對的。
add_bashrc()  { add_line "$HOME/.bashrc"  "$1"; }

# useradd -m 會從 /etc/skel 複製 .profile；這裡是保險（26.04 有 /etc/skel
# 未複製的零星回報）。缺了 .profile 的話 login shell 不會 source .bashrc，
# alias 會整組失效。
if [ ! -f "$HOME/.profile" ]; then
  log "$HOME/.profile 不存在，建立"
  cat > "$HOME/.profile" <<'EOF'
# ~/.profile — login shell 讀這個
if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then
  . "$HOME/.bashrc"
fi
EOF
fi

# ---------------------------------------------------------------------------
# Claude Code (native installer，不走 npm)
# ---------------------------------------------------------------------------
log "安裝 Claude Code (native)"
curl -fsSL https://claude.ai/install.sh | bash
add_profile 'export PATH="$HOME/.local/bin:$PATH"'

# ---------------------------------------------------------------------------
# Go (latest = 自動查官方最新版；或 config 給具體版本如 1.23.4)
# ---------------------------------------------------------------------------
if [ "${BS_GO_VERSION}" = "latest" ]; then
  # go.dev/VERSION?m=text 第一行是 "go1.xx.x"
  GO_TAG="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)"
  [ -z "${GO_TAG}" ] && { echo "無法取得 Go 最新版" >&2; exit 1; }
else
  GO_TAG="go${BS_GO_VERSION}"
fi
log "安裝 Go ${GO_TAG}"
GO_ARCH="$(dpkg --print-architecture)"   # amd64 / arm64
GO_TGZ="${GO_TAG}.linux-${GO_ARCH}.tar.gz"
curl -fsSL "https://go.dev/dl/${GO_TGZ}" -o "/tmp/${GO_TGZ}"
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf "/tmp/${GO_TGZ}"
rm -f "/tmp/${GO_TGZ}"
add_profile 'export PATH="$PATH:/usr/local/go/bin:$HOME/go/bin"'

# ---------------------------------------------------------------------------
# Node (optional, via nvm)
# ---------------------------------------------------------------------------
if [ "${BS_INSTALL_NODE:-false}" = "true" ]; then
  log "安裝 nvm + Node (${BS_NODE_VERSION:-lts})"
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  if [ "${BS_NODE_VERSION:-lts}" = "lts" ]; then
    nvm install --lts
  else
    nvm install "${BS_NODE_VERSION}"
  fi
fi

# ---------------------------------------------------------------------------
# Python (optional, via uv)
# ---------------------------------------------------------------------------
if [ "${BS_INSTALL_PYTHON:-false}" = "true" ]; then
  log "安裝 uv (Python)"
  curl -fsSL https://astral.sh/uv/install.sh | sh
  add_profile 'export PATH="$HOME/.local/bin:$PATH"'
fi

# ---------------------------------------------------------------------------
# Client tools (optional)
# ---------------------------------------------------------------------------
if [ "${BS_INSTALL_CLIENTS:-false}" = "true" ]; then
  log "安裝 client tools (psql, redis-cli)"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    postgresql-client redis-tools
  # NATS CLI 走 Go install（若 Go 已在 PATH）
  if command -v /usr/local/go/bin/go &>/dev/null; then
    /usr/local/go/bin/go install github.com/nats-io/natscli/nats@latest || \
      log "nats CLI 安裝失敗（非致命），可稍後手動裝"
  fi
fi

# ---------------------------------------------------------------------------
# Podman compose shim aliases
# ---------------------------------------------------------------------------
if [ "${BS_RUNTIME}" = "podman" ]; then
  log "設定 podman 別名 / socket"
  add_bashrc 'alias docker=podman'

  # 這個腳本經 `wsl -u <user> bash -s` 執行，不走 PAM。WSL 的 init 實測上會注入
  # XDG_RUNTIME_DIR / DBUS_SESSION_BUS_ADDRESS，但那不保證 user manager 真的在跑
  # （靠 phase2 的 loginctl enable-linger），也不保證未來版本照舊。自己設一次比較穩。
  XDG_RUNTIME_DIR="/run/user/$(id -u)"
  export XDG_RUNTIME_DIR
  export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

  # 刻意不吞錯誤：socket 沒起來但 DOCKER_HOST 已寫進 profile 的話，bootstrap 會
  # 報成功，然後在你第一次 docker-compose up 時才炸。這裡就是最該大聲失敗的地方。
  # 開 rootless podman socket（給 docker-compose / IDE 用）
  systemctl --user enable --now podman.socket
  add_profile 'export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"'
fi

# ---------------------------------------------------------------------------
# SSH keys (optional)
# ---------------------------------------------------------------------------
if [ "${BS_GEN_SSH:-false}" = "true" ]; then
  log "產生 SSH keys"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  # 檔名前綴由 orchestrator 從 distro 名推導後傳入（BS_SSH_TAG），不再寫死。
  ssh_tag="${BS_SSH_TAG:-dev}"
  # 註解蓋上建置日期，方便日後判斷金鑰年紀 / 輪替；用當下日期，不寫死。
  key_date="$(date +%F)"
  IFS=',' read -ra SCOPES <<< "${BS_SSH_SCOPES:-github}"
  for scope in "${SCOPES[@]}"; do
    scope="$(echo "$scope" | tr -d '[:space:]')"
    [ -z "$scope" ] && continue
    keyfile="$HOME/.ssh/id_ed25519_${ssh_tag}_${scope}"
    if [ -f "$keyfile" ]; then
      log "  $keyfile 已存在，略過"
    else
      ssh-keygen -t ed25519 -N '' \
        -C "${BS_SSH_COMMENT:-miskawu@acme-dev}-${scope} ${key_date}" \
        -f "$keyfile"
      log "  產生 $keyfile"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 收尾: projects 目錄
# ---------------------------------------------------------------------------
mkdir -p "$HOME/projects"

log "phase3 完成"
echo
echo "==================== 手動收尾清單 ===================="
echo " 1. claude          # 首次登入認證"
if [ "${BS_GEN_SSH:-false}" = "true" ]; then
  echo " 2. 把公鑰貼到對應平台:"
  IFS=',' read -ra SCOPES <<< "${BS_SSH_SCOPES:-github}"
  for scope in "${SCOPES[@]}"; do
    scope="$(echo "$scope" | tr -d '[:space:]')"
    [ -z "$scope" ] && continue
    echo "      cat ~/.ssh/id_ed25519_${BS_SSH_TAG:-dev}_${scope}.pub"
  done
fi
echo " 3. git config --global user.name / user.email"
echo " 4. source ~/.profile  (或重開 shell；PATH / DOCKER_HOST 寫在這)"
echo "======================================================"
