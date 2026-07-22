#!/usr/bin/env bash
# =============================================================================
# 驗收腳本：建置完成後的驗收。在 distro 內以目標 user 執行。
#
#   wsl -d dev -u miskawu -- bash -l < scripts/verify.sh
#
# 從 stdin 餵進去是刻意的：`wsl ... bash -lc '<一大串>'` 會經過
# Windows shell → wsl.exe → bash 三層引號，實測會把 $VAR 和 $() 吃掉，
# 導致「明明正常卻報 FAIL」的假警報。stdin 完全避開參數解析。
# 用 `bash -l` 是因為 PATH / DOCKER_HOST 在 ~/.profile，非 login shell 讀不到。
# =============================================================================
set -u

pass=0; fail=0
ok(){ printf '  \033[32m[OK]\033[0m   %-14s %s\n' "$1" "$2"; pass=$((pass+1)); }
ng(){ printf '  \033[31m[FAIL]\033[0m %-14s %s\n' "$1" "$2"; fail=$((fail+1)); }
chk(){ if out=$(eval "$2" 2>&1); then ok "$1" "$out"; else ng "$1" "$out"; fi; }

# distro 冷啟動後，WSL 會先噴一次 "Failed to start the systemd user session"，
# user@<uid>.service 短暫報 failed / is-system-running 報 starting|degraded，
# 幾秒內自癒。不等它穩定就檢查，會得到「開頭兩項 FAIL、後面 compose 卻全過」
# 這種自相矛盾的假警報。等它安定再測，也才符合人真的進 shell 打指令的時序。
settle(){
  local st
  for _ in $(seq 1 30); do
    st=$(systemctl is-system-running 2>&1)
    if { [ "$st" = running ] || [ "$st" = degraded ]; } \
       && systemctl is-active "user@$(id -u).service" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}
settle || echo "  (systemd 等待 30s 仍未安定，以下結果可能不準)"

echo "== 系統 =="
chk "os"          '. /etc/os-release && echo "$PRETTY_NAME"'
chk "whoami"      'whoami'
# degraded 可接受（見 CLAUDE.md 排查），所以判字串不判 exit code——is-system-running
# 在 degraded 時回傳非零，直接餵給 chk 會誤判成 FAIL。
chk "systemd"     'st=$(systemctl is-system-running 2>&1); case "$st" in running) echo "$st";; degraded) echo "$st ($(systemctl --failed --no-legend --no-pager | wc -l) 個 unit 失敗，見 systemctl --failed)";; *) echo "$st"; false;; esac'
chk "user@"       'systemctl is-active "user@$(id -u).service"'

echo "== runtime =="
chk "podman"      'podman --version'
chk "rootless"    'podman info --format "{{.Host.Security.Rootless}}" | grep -qx true && echo true'
chk "socket"      'systemctl --user is-active podman.socket'
chk "DOCKER_HOST" 'test -n "$DOCKER_HOST" && echo "$DOCKER_HOST"'
chk "remote-api"  'podman --remote info --format "{{.Version.Version}}"'
chk "registries"  'grep -q docker.io /etc/containers/registries.conf && echo "docker.io"'
chk "firewall"    'grep -q iptables /etc/containers/containers.conf && echo "iptables driver"'
chk "compose-bin" 'docker-compose version --short'

echo "== toolchain =="
chk "go"          'go version'
chk "claude"      'claude --version'
command -v uv   >/dev/null 2>&1 && chk "uv"   'uv --version'
command -v psql >/dev/null 2>&1 && chk "psql" 'psql --version'
command -v nats >/dev/null 2>&1 && chk "nats" 'nats --version'
command -v node >/dev/null 2>&1 && chk "node" 'node --version'

echo "== SSH =="
if compgen -G "$HOME/.ssh/*.pub" >/dev/null; then
  for f in "$HOME"/.ssh/*.pub; do ok "$(basename "$f" .pub)" "$(cut -d' ' -f3 "$f")"; done
else
  echo "  (未產生 SSH key)"
fi

# ---------------------------------------------------------------------------
# compose 端到端。這段不能省——podman run / pull / info 走 rootless 預設網路
# (pasta)，完全不碰防火牆規則；只有 compose 會建 bridge network，才會叫
# netavark 下 nftables 規則。「podman 全綠 + compose 全炸」是這個環境的標準
# 失敗形狀，只驗 podman 等於沒驗。
# ---------------------------------------------------------------------------
echo "== compose 端到端（唯一能抓到 netavark 問題的檢查）=="
d=$(mktemp -d); trap 'cd /; rm -rf "$d"' EXIT
cd "$d" || { ng "compose-up" "無法進入暫存目錄 $d"; exit 1; }
cat > docker-compose.yml <<'YML'
services:
  cache:
    image: redis:alpine
    ports: ["16399:6379"]
YML
if timeout 90 docker-compose up -d >/dev/null 2>&1; then
  sleep 2
  state=$(docker-compose ps --format '{{.State}}' 2>/dev/null | head -1)
  if [ "$state" = "running" ]; then
    ok "compose-up" "容器 running"
  else
    ng "compose-up" "容器狀態=$state（卡在 Created 通常是 netavark/nftables）"
  fi
  if command -v redis-cli >/dev/null 2>&1; then
    chk "redis-ping" 'redis-cli -p 16399 ping'
  else
    chk "port-open"  'timeout 5 bash -c "</dev/tcp/127.0.0.1/16399" && echo "16399 通"'
  fi
  timeout 60 docker-compose down >/dev/null 2>&1
else
  ng "compose-up" "docker-compose up 失敗或逾時"
fi

echo
printf '結果: \033[32m%d 過\033[0m / \033[31m%d 失敗\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
