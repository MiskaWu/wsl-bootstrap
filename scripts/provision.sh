#!/usr/bin/env bash
# =============================================================================
# Provision (root)：把乾淨的 Ubuntu WSL distro 帶到「Ansible 管得動」的狀態。
#   - 建 user + NOPASSWD sudo
#   - /etc/wsl.conf（systemd + 預設 user）
#   - baseline：git, make, ansible-core, python3 —— 讓 dev-env-ansible 能本機 make apply
#   - OOBE metrics opt-out（首次互動啟動不再跳提問）
#
# 軟體工作環境（podman / go / claude / toolchain）**不在這裡** —— 交給獨立的
# dev-env-ansible repo（在 distro 內 `make apply`）。這支只負責 bring-up。
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

log "baseline：git make ansible-core python3"
apt-get install -y git make ansible-core python3 ca-certificates curl

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

# 給 dev-env-ansible 一個落腳處（之後 clone 到這，在此 make apply）。
log "建立 ~/projects"
install -d -o "${BS_USER}" -g "${BS_USER}" -m 0755 "${home}/projects"

log "provision 完成 —— 需要 wsl --shutdown"
