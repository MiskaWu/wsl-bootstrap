#!/usr/bin/env bash
# =============================================================================
# Provision (root)：把 Ubuntu WSL distro 帶到「git-ready、可 clone + make 起手」。
# 由 bootstrap.ps1 pipe 進 distro；fresh build 與 `-Update` 共用同一支（單一 source
# of truth），差別只在下面兩個環境變數。
#   - 建 user + NOPASSWD sudo
#   - /etc/wsl.conf（systemd + 預設 user）
#   - baseline：git + make + openssh-client（clone repo + Makefile 起手 + git over ssh）
#   - git 身分（~/.gitconfig）+ SSH keys（per scope ed25519）+ ~/.ssh/config（host→key）
#   - OOBE metrics opt-out（首次互動啟動不再跳提問）
#
# **冪等**：重跑不爆不重複（建 user 前 id 檢查、檔案 install 覆寫、ssh-keygen 已存在跳過、
# ssh config 用 managed 區塊）——所以能對現有 distro 收斂（bootstrap.ps1 -Update）。
#   BS_DRY_RUN   非空 → 預覽：只顯示會改什麼（檔案做 unified diff、套件/key 只報告），不動機器。
#   BS_SKIP_UPGRADE 非空 → 跳過 apt upgrade（-Update 預設如此，避免每次順手動整個系統）。
#
# 軟體工作環境（ansible/podman/go/claude/toolchain）**都不在這裡**——交給組態管理 repo。
# 有改到 wsl.conf 時需 `wsl --shutdown` 讓 systemd / 預設 user / wsl.conf 生效。
# =============================================================================
set -euo pipefail

: "${BS_USER:?BS_USER not set}"
DRY="${BS_DRY_RUN:-}"                  # 非空 = 預覽（不動機器）
SKIP_UPGRADE="${BS_SKIP_UPGRADE:-}"    # 非空 = 跳過 apt upgrade

log()  { printf '\033[1;34m[provision]\033[0m %s\n' "$*"; }
plan() { printf '\033[1;33m[plan]\033[0m %s\n' "$*"; }   # 預覽模式的「會做什麼」

# 產生內容用 stdin 餵進來 | write_or_diff <path> <owner> <mode>
#   預覽：跟現況做 unified diff、印出、不寫。 套用：install 到位（owner + mode）。
# diff 差異回傳 1，會被 set -e 抓——所以用 `|| true` 擋住。
write_or_diff() {
  local path="$1" owner="$2" mode="$3" tmp; tmp="$(mktemp)"; cat > "$tmp"
  if [ -n "$DRY" ]; then
    if [ ! -e "$path" ]; then
      plan "${path}：會新建 ↓"; sed 's/^/    +/' "$tmp"
    elif diff -q "$path" "$tmp" >/dev/null 2>&1; then
      plan "${path}：無變更"
    else
      plan "${path}：會變更 ↓"; { diff -u "$path" "$tmp" || true; } | sed 's/^/    /'
    fi
    rm -f "$tmp"
  else
    install -o "$owner" -g "$owner" -m "$mode" "$tmp" "$path"; rm -f "$tmp"
  fi
}

export DEBIAN_FRONTEND=noninteractive
[ -n "$DRY" ] && log "=== DRY-RUN 預覽：以下只顯示會做什麼，不動機器 ==="

# ---- apt ---------------------------------------------------------------------
if [ -n "$DRY" ]; then
  plan "apt-get update"
  if [ -n "$SKIP_UPGRADE" ]; then plan "apt-get upgrade：跳過"; else plan "apt-get upgrade：會執行"; fi
else
  if [ -n "$SKIP_UPGRADE" ]; then log "apt update"; else log "apt update / upgrade"; fi
  apt-get update -y
  [ -z "$SKIP_UPGRADE" ] && apt-get upgrade -y
fi

# ---- baseline ----------------------------------------------------------------
pkgs="git make openssh-client"
if [ -n "$DRY" ]; then
  missing=""
  for p in $pkgs; do dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"; done
  if [ -n "$missing" ]; then plan "baseline 會裝：${missing# }"; else plan "baseline（$pkgs）：都在"; fi
else
  log "baseline：$pkgs"
  apt-get install -y $pkgs
fi

# ---- user + NOPASSWD sudo ----------------------------------------------------
if id "${BS_USER}" &>/dev/null; then
  if [ -n "$DRY" ]; then plan "user ${BS_USER}：已存在"; else log "user ${BS_USER} 已存在，略過"; fi
elif [ -n "$DRY" ]; then
  plan "會建 user ${BS_USER}（-G sudo）+ NOPASSWD sudo"
else
  log "建立 user: ${BS_USER}"
  useradd -m -s /bin/bash -G sudo "${BS_USER}"
  # 免密碼 sudo（開發機常見；不想要就刪這行改設密碼）
  echo "${BS_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${BS_USER}"
  chmod 0440 "/etc/sudoers.d/${BS_USER}"
fi

home="$(getent passwd "${BS_USER}" | cut -d: -f6)"
: "${home:?無法取得 ${BS_USER} 的 home}"

# ---- OOBE metrics opt-out（Ubuntu 26.04 的 ubuntu-insights）------------------
# 首次互動啟動時 wsl-setup 會問「opt-in platform metrics?」——違反零互動。預先為 user 寫
# consent 檔（consent_state=false），OOBE 偵測到就跳過提問、且覆蓋 Windows registry 預設。
# 用 runuser 建目錄，確保 ~/.config 這層中間目錄也是 user 所有（root 的 install -d 會把
# 中間目錄建成 root，之後在 ~/.config 下動東西會 permission denied）。
[ -z "$DRY" ] && runuser -u "${BS_USER}" -- mkdir -p "${home}/.config/ubuntu-insights"
for src in linux wsl_setup ubuntu_release_upgrader; do
  printf 'consent_state = false\n' \
    | write_or_diff "${home}/.config/ubuntu-insights/${src}-consent.toml" "${BS_USER}" 0644
done

# ---- /etc/wsl.conf -----------------------------------------------------------
cat <<EOF | write_or_diff /etc/wsl.conf root 0644
[boot]
systemd=true

[user]
default=${BS_USER}

[network]
generateResolvConf=true

[interop]
appendWindowsPath=true
EOF

# ---- git 身分（設在 user 的 global config；未給就略過）------------------------
if [ -n "${BS_GIT_NAME:-}" ] && [ -n "${BS_GIT_EMAIL:-}" ]; then
  if [ -n "$DRY" ]; then
    cn="$(runuser -u "${BS_USER}" -- git config --global user.name  2>/dev/null || true)"
    ce="$(runuser -u "${BS_USER}" -- git config --global user.email 2>/dev/null || true)"
    if [ "$cn" = "${BS_GIT_NAME}" ] && [ "$ce" = "${BS_GIT_EMAIL}" ]; then
      plan "git 身分：無變更（${BS_GIT_NAME} <${BS_GIT_EMAIL}>）"
    else
      plan "git 身分：${cn:-（未設）} <${ce:-（未設）}> → ${BS_GIT_NAME} <${BS_GIT_EMAIL}>"
    fi
  else
    log "git 身分：${BS_GIT_NAME} <${BS_GIT_EMAIL}>"
    runuser -u "${BS_USER}" -- git config --global user.name  "${BS_GIT_NAME}"
    runuser -u "${BS_USER}" -- git config --global user.email "${BS_GIT_EMAIL}"
  fi
else
  m="未設 BS_GIT_NAME/BS_GIT_EMAIL，略過 git 身分"
  if [ -n "$DRY" ]; then plan "$m"; else log "$m"; fi
fi

# ---- SSH keys（每 scope 一把 ed25519，無 passphrase；冪等：已存在跳過）--------
# 並寫 ~/.ssh/config：非預設檔名的 key，SSH 不會自動用，一定要 IdentityFile 對應，否則
# git over ssh 根本不會碰到這些 key。IdentitiesOnly yes：只用指定那把，避免多 key 時
# "Too many authentication failures"。config 用 managed 標記包住，重跑只覆蓋自己那段。
if [ -n "${BS_SSH_KEY_SCOPES:-}" ]; then
  tag="${BS_SSH_KEY_TAG:-dev}"
  comment="${BS_SSH_KEY_COMMENT:-${BS_USER}@$(hostname)}"
  today="$(date +%F)"
  [ -z "$DRY" ] && runuser -u "${BS_USER}" -- install -d -m 0700 "${home}/.ssh"
  for scope in ${BS_SSH_KEY_SCOPES}; do
    key="${home}/.ssh/id_ed25519_${tag}_${scope}"
    if [ -f "$key" ]; then
      if [ -n "$DRY" ]; then plan "SSH key $(basename "$key")：已存在"; else log "SSH key 已存在，略過：$(basename "$key")"; fi
    elif [ -n "$DRY" ]; then
      plan "SSH key $(basename "$key")：會生成（ed25519, -C '${comment}-${scope} ${today}'）"
    else
      log "產生 SSH key：$(basename "$key")"
      runuser -u "${BS_USER}" -- ssh-keygen -t ed25519 -N '' -C "${comment}-${scope} ${today}" -f "$key"
    fi
  done
  # ~/.ssh/config：組出「更新後的完整內容」再交給 write_or_diff（預覽 diff / 套用寫入）
  cfg="${home}/.ssh/config"
  new="$(mktemp)"
  [ -f "$cfg" ] && sed '/^# >>> wsl-bootstrap managed/,/^# <<< wsl-bootstrap managed/d' "$cfg" > "$new"
  {
    echo "# >>> wsl-bootstrap managed（scope host → key；重跑覆蓋本區塊）>>>"
    for scope in ${BS_SSH_KEY_SCOPES}; do
      case "$scope" in
        github)    sshhost=github.com ;;
        gitlab)    sshhost=gitlab.com ;;
        bitbucket) sshhost=bitbucket.org ;;
        *)         sshhost="$scope" ;;   # 已是 FQDN 或自訂：原樣
      esac
      printf 'Host %s\n    User git\n    IdentityFile %s/.ssh/id_ed25519_%s_%s\n    IdentitiesOnly yes\n\n' \
        "$sshhost" "$home" "$tag" "$scope"
    done
    echo "# <<< wsl-bootstrap managed <<<"
  } >> "$new"
  write_or_diff "$cfg" "${BS_USER}" 0600 < "$new"
  rm -f "$new"
  # 公鑰（套用時印出來，方便貼平台）
  if [ -z "$DRY" ]; then
    log "SSH 公鑰（貼到 GitHub/GitLab）："
    for scope in ${BS_SSH_KEY_SCOPES}; do
      pub="${home}/.ssh/id_ed25519_${tag}_${scope}.pub"
      [ -f "$pub" ] && printf '  %s\n' "$(cat "$pub")"
    done
  fi
else
  m="未設 BS_SSH_KEY_SCOPES，略過 SSH keys"
  if [ -n "$DRY" ]; then plan "$m"; else log "$m"; fi
fi

if [ -n "$DRY" ]; then log "=== DRY-RUN 結束：以上皆未執行 ==="; else log "provision 完成"; fi
