#!/usr/bin/env bash
# =============================================================================
# 驗收腳本：確認 bring-up 完成、distro 已「可以 clone + make 起手」。在 distro 內以
# 目標 user 執行：
#
#   wsl -d dev -u miskawu -- bash -l < scripts/verify.sh
#
# 從 stdin 餵是刻意的：`wsl ... bash -lc '<字串>'` 會經 Windows shell → wsl.exe →
# bash 三層引號，實測會吃掉 $VAR / $()，造成「其實正常卻報 FAIL」的假警報。
# 用 bash -l 是因為 baseline 的 PATH 可能在 ~/.profile。
#
# 這裡只驗 bring-up；軟體工作環境（podman/go/claude/...）的驗收在 dev-env-ansible。
# =============================================================================
set -u

pass=0; fail=0
ok(){ printf '  \033[32m[OK]\033[0m   %-14s %s\n' "$1" "$2"; pass=$((pass+1)); }
ng(){ printf '  \033[31m[FAIL]\033[0m %-14s %s\n' "$1" "$2"; fail=$((fail+1)); }
chk(){ if out=$(eval "$2" 2>&1); then ok "$1" "$out"; else ng "$1" "$out"; fi; }

# distro 冷啟動後 systemd 的 user session 會短暫 race，幾秒內自癒；等它安定再驗，
# 避免「開頭 FAIL、後面卻正常」的假警報。
settle(){
  local st
  for _ in $(seq 1 30); do
    st=$(systemctl is-system-running 2>&1)
    { [ "$st" = running ] || [ "$st" = degraded ]; } && return 0
    sleep 1
  done
  return 1
}
settle || echo "  (systemd 等待 30s 仍未安定，以下可能不準)"

echo "== 系統 =="
chk "os"        '. /etc/os-release && echo "$PRETTY_NAME"'
chk "whoami"    'whoami'
chk "wsl.conf"  'grep -h -E "systemd|default" /etc/wsl.conf | tr "\n" " "'
# degraded 可接受（見 CLAUDE.md 排查），判字串不判 exit code。
chk "systemd"   'st=$(systemctl is-system-running 2>&1); case "$st" in running) echo "$st";; degraded) echo "$st";; *) echo "$st"; false;; esac'

echo "== baseline（git + make + openssh：clone repo + Makefile 起手 + git/ssh）=="
# 刻意只有這些 + 下面的 git 身分/keys。ansible / 軟體全交給組態管理 repo 自己裝
# （Makefile 會在需要時補 ansible），所以這裡不驗那些。
chk "git"        'git --version'
chk "make"       'make --version | head -1'
chk "ssh-keygen" 'command -v ssh-keygen'

echo "== git-ready（身分 + SSH keys，bring-up 直接備好）=="
chk "git.name"   'git config --global user.name'
chk "git.email"  'git config --global user.email'
chk "ssh-keys"   'for f in "$HOME"/.ssh/id_ed25519_*.pub; do [ -e "$f" ] && basename "$f"; done | tr "\n" " " | grep .'
# 非預設檔名的 key 一定要有 ~/.ssh/config 的 IdentityFile 對應，git over ssh 才用得到。
chk "ssh-config" 'grep -qi "IdentityFile" "$HOME/.ssh/config" 2>/dev/null && echo "host→key 對應已寫"'

echo "== OOBE metrics opt-out =="
chk "consent"   'f="$HOME/.config/ubuntu-insights/wsl_setup-consent.toml"; grep -q "consent_state = false" "$f" && echo "wsl_setup=false"'

echo
printf '結果: \033[32m%d 過\033[0m / \033[31m%d 失敗\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
