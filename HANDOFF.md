# HANDOFF — wsl-bootstrap 執行交接

> 這份文件是給**目標機器上的 Claude CLI** 看的。你的任務是協助使用者（Miska）
> 在一台 Windows 機器上，用這個 repo 建立一個乾淨的 WSL2 開發環境。以下是完整
> 背景、決策脈絡、執行步驟與驗證方式。請照做，並在每個關鍵步驟前與使用者確認。

---

## 0. 一句話目標

在 Windows 上用 PowerShell 跑 `bootstrap.ps1`，**無人值守**建立一個名為
`dev-2026` 的 Ubuntu 24.04 WSL2 distro，內含 Podman（rootless）、最新版 Go、
Claude Code，以及可選的 Node/Python/client tools/SSH keys。

---

## 1. 背景與已定案的決策（不要重新推翻，除非使用者主動要求）

這些是使用者已經深思並拍板的決策，你不需要重新論證：

- **單一 WSL2 distro 就是開發環境**。不採用「每專案 devcontainer」——因為
  Windows→WSL2 已是一層完整隔離，使用者是 solo dev、專案數量少，且 Claude Code
  在 native shell 體驗最佳。
- **容器 runtime 用 Podman（rootless）**，不用 Docker Engine。理由：rootless 安全性、
  與家用 k3s 叢集的 `podman generate kube` 對齊。
- **Go 直接裝最新 binary 到 `/usr/local/go`**，不用版本管理器（gvm/mise）。使用者要輕量。
  build/prod 的 Go 版本由各專案 Dockerfile pin（multi-stage build），與 host 的 Go 各司其職。
- **Node → nvm，Python → uv**。
- **設定全部走 config 檔（config-as-code）**，不是互動式問答。這樣執行過程零互動、
  可版控、可重現。
- **全部重來**：不從舊 distro 搬任何資料，SSH key 在新環境重新產生
  （命名慣例 `id_ed25519_dev2026_<scope>`）。

---

## 2. 前置需求檢查（執行前先確認）

請先協助使用者確認這些，任一不滿足就先解決再往下：

1. **OS / WSL 版本**：Windows 11 24H2+ 或支援 `wsl --install --name` 的 WSL 版本。
   先跑 `wsl --version` 與 `wsl --update`。
2. **WSL2 已啟用**：`wsl --status` 應顯示預設版本為 2。
3. **distro 名稱未被佔用**：`wsl --list --quiet` 不應含 `dev-2026`。若已存在，
   **停下來問使用者**是否要 `wsl --unregister dev-2026`（會刪光內容，不可逆）。
4. **Ubuntu image 名稱**：`wsl --list --online` 確認 `Ubuntu-24.04` 是正確字串
   （偶爾平台上叫法略有差異）。若不同，改 `config.ps1` 的 `$UbuntuImage`。

---

## 3. 執行步驟

```powershell
# 1. 進到 repo 目錄
cd <解壓縮後的 wsl-bootstrap 目錄>

# 2. 建立真實設定檔（首次）
cp config.example.ps1 config.ps1

# 3. 依需求編輯 config.ps1（見下方 §4 建議值）
notepad config.ps1

# 4. 無人值守執行
.\bootstrap.ps1
```

**執行中會發生什麼**（都是自動的，不需值守）：
- Phase 0：安裝 Ubuntu-24.04 為 `dev-2026`（`--no-launch`）
- Phase 1（root）：apt 更新、建 user、寫 `/etc/wsl.conf`（systemd + default user）
  → **自動 `wsl --shutdown`**（讓 systemd 生效）
- Phase 2（root）：裝 Podman + baseline 套件 + compose shim
  → **自動 `wsl --terminate dev-2026`**（讓 group 變更生效）
- Phase 3（user）：裝 Claude Code、Go(latest)、可選 Node/Python/clients、產 SSH key
  → **自動 `wsl --terminate dev-2026`**（收尾，讓第一次進入是乾淨 session）

> ⚠️ PowerShell 執行原則：若遇 execution policy 阻擋，用
> `powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1`，
> **不要**叫使用者永久放寬全域 execution policy。

---

## 4. config.ps1 建議值（對齊使用者的既定決策）

```powershell
$Distro      = 'dev-2026'
$UbuntuImage = 'Ubuntu-26.04'   # 見下方說明
$User        = 'miska'

$Runtime     = 'podman'      # 已定案
$ComposeShim = $true         # 讓現有 docker-compose.yml 不改就能跑

$GoVersion   = 'latest'      # 自動抓 go.dev 最新版

$InstallNode        = $false # 使用者傾向只在需要的專案裝；要就改 $true
$NodeVersion        = 'lts'
$InstallPython      = $true  # uv
$InstallClientTools = $true  # psql, redis-cli, nats

$GenerateSSHKey = $true
$SSHKeyScopes   = @('github', 'gitlab', 'homelab')
$SSHKeyComment  = 'miska@dev-2026'

$UnregisterOld  = $false     # 先留舊 distro 當 rollback，驗證過再手動刪
$OldDistroName  = ''
```

### 為什麼是 Ubuntu-26.04（2026-07 決定）

原本寫 24.04。改用 26.04（Resolute Raccoon，2026-04-23 GA，支援到 2031）的理由：

- **podman 5.7 vs 24.04 的 4.9.3。** Ubuntu LTS 不 rebase，24.04 會凍在 2024 年初的
  podman 直到 2029。rootless + `podman generate kube` 對齊 k3s 是核心架構決策，這個
  差距不能忽略。Kubic repo 已停，沒有可信的替代 apt repo。
- **Docker API 天花板。** podman 4.9 的 API 上限是 1.41，docker client v29 已把最低
  要求拉到 1.44。目前 compose 內含的 moby client 仍會往下協商所以還能動，但那是
  定時炸彈——而 podman 5.x 提供 1.44，26.04 直接避開。
- WSL image 是 `releases.ubuntu.com/resolute/` 上的官方一等釋出物，不是實驗性的。

代價（已知並接受）：26.04 的 userland 換血較大，**uutils（Rust coreutils）**與
**sudo-rs** 成為預設。對本 repo 的暴露面小——NOPASSWD sudo 不會看到提示，
`cp`/`mv`/`rm` 仍是 GNU 版。社群通則是「等 26.04.1」（2026-08-27），但那是給
production server 的建議；這是一台 20 分鐘可重建的開發機。

---

## 5. 安全性注意事項（請主動向使用者說明，不要默默跳過）

1. **pipe-to-shell**：腳本會 `curl … | bash` 安裝 Claude Code、Podman 相關、uv。
   使用者是 infra 工程師，已知此風險。若使用者想更保守，可先個別下載檢視或 pin 版本。
   **不要擅自移除**，這是使用者已接受的取捨。
2. **免密碼 sudo**：phase1 會給該 user 設 NOPASSWD sudo（開發機常見）。若使用者不要，
   改 `phase1-system.sh` 移除該行、改設密碼。
3. **SSH key 佈署與 Claude Code 認證是手動的**，phase3 結束會印清單。這是刻意的——
   金鑰與認證手動確認較安全。**不要試圖自動化貼公鑰或自動登入。**
4. **compose shim（`alias docker=podman` + `DOCKER_HOST`）** 是「假裝成 docker」的過渡層。
   若使用者未來想走純 Podman-native（`podman-compose` / `podman generate kube`），
   這層要移除。目前保留是為了讓 acme 現有 `docker-compose.yml` 零改動。

---

## 6. 執行後驗證清單

**首選：跑驗收腳本**（在 repo 目錄，Windows 端執行）。它涵蓋下面所有項目，
包含最重要的 compose 端到端：

```powershell
wsl -d dev-2026 -u miska -- bash -l < scripts/verify.sh
```

從 stdin 餵、用 `bash -l` 都是刻意的：前者避開 `wsl ... bash -lc '<字串>'` 那三層
引號（實測會吃掉 `$VAR` / `$()`，造成「其實正常卻報 FAIL」的假警報）；後者是因為
`PATH` / `DOCKER_HOST` 在 `~/.profile`，非 login shell 讀不到。

---

以下是同一份清單的手動版本。進 `wsl -d dev-2026` 後逐項確認：

```bash
# 系統
cat /etc/wsl.conf              # systemd=true, default=miska
whoami                          # miska
systemctl is-system-running     # running（degraded 見 §8：terminate 重進即可）

# runtime
podman info                     # rootless 應顯示 rootless: true
podman pull redis:alpine        # short-name 解析（redis 不在內建別名表，會逼出 registries.conf）
systemctl --user is-active podman.socket   # active
echo "$DOCKER_HOST"             # 應有值；空的代表 .profile 沒生效
podman --remote info            # 透過 DOCKER_HOST 打 socket，通了才算 socket 真的能用
docker --version                # 若 compose shim 生效，指向 podman
docker-compose version          # compose shim
```

**⚠️ 上面那些全過，不代表 compose 能用。** 一定要真的跑一次：

```bash
mkdir -p /tmp/t && cd /tmp/t
cat > docker-compose.yml <<'YML'
services:
  cache:
    image: redis:alpine
    ports: ["16379:6379"]
YML
docker-compose up -d            # 容器應為 running，不是卡在 Created
redis-cli -p 16379 ping         # 應回 PONG
docker-compose down
```

為什麼非跑不可：`podman run` 和 `podman pull` 用的是 rootless 預設網路（pasta），
**不碰防火牆規則**；但 compose 一定會建 `<project>_default` bridge network，那才會叫
netavark 下 nftables 規則。所以「`podman run` 全綠 + compose 全炸」是這個環境的
標準失敗形狀——**只驗 podman 不驗 compose，等於沒驗**。

```bash

# toolchain
go version                      # 最新版
claude --version                # Claude Code
uv --version                    # 若 InstallPython=true
psql --version                  # 若 InstallClientTools=true

# SSH
ls ~/.ssh/                      # id_ed25519_dev2026_github 等
```

---

## 7. 手動收尾（phase3 會印出，這裡再列一次）

1. `claude` — 首次登入認證（開瀏覽器 OAuth）
2. 貼 SSH 公鑰到對應平台：
   `cat ~/.ssh/id_ed25519_dev2026_github.pub` → 貼到 GitHub Settings → SSH keys
3. 設 git 身分：
   `git config --global user.name "..."` / `git config --global user.email "..."`
4. `source ~/.profile`（或重開 shell）——PATH / `DOCKER_HOST` 都寫在 `.profile`，
   不是 `.bashrc`（`.bashrc` 對非互動 shell 會提早 return）
5. clone 專案到 `~/projects/`（**放 WSL 檔案系統，不要放 `/mnt/c/`**，I/O 效能差一個數量級）

---

## 8. 若出錯的排查方向

- **`--name` 不被支援**：`wsl --update` 升級，或改用 `wsl --import` 從 rootfs 建 distro。
- **某個 phase 中斷**：`bootstrap.ps1` 每個 phase 檢查 `$LASTEXITCODE`，會停在出錯處。
  可先 `wsl --unregister dev-2026` 清掉半成品再重跑。
- **CRLF 問題**：orchestrator 已自動把 sh 檔轉 LF。若手動改過 sh 檔，確認存成 LF。
- **`bootstrap.ps1` 一跑就噴語法錯（缺少 `}` 之類，行號看起來莫名其妙）**：
  八成是 `.ps1` 的 UTF-8 BOM 被編輯器存掉了。PS 5.1 沒 BOM 會用 ANSI codepage
  （繁中機器 = Big5）解檔，中文註解會失步破壞字串邊界。檢查
  `head -c 3 bootstrap.ps1 | xxd -p` 應為 `efbbbf`，不是就補回去。
- **`systemctl --user` 連不上 / `is-system-running` 是 degraded / socket 不見**：
  先看 `systemctl is-active user@1000.service`。若是 `failed`，journal 會有
  `Failed to spawn executor: Device or resource busy`——這是 systemd 259 在 WSL 上
  被反覆開關 session 撞出的 race，**不是安裝失敗**。`wsl --terminate dev-2026`
  重進即可，實測會全部恢復（running / active / socket 存在）。bootstrap 收尾已經
  自動 terminate 過一次，所以正常情況不該遇到。
- **Podman socket 沒起來**：`systemctl --user enable --now podman.socket`，
  並確認 `loginctl enable-linger miska` 已生效。phase3 這行**刻意不吞錯誤**——
  socket 沒起來卻回報成功的話，會延遲到第一次 `docker-compose up` 才爆。
- **`docker-compose up` 的容器卡在 `Created`，或噴
  `netavark: nftables error: "nft" did not return successfully while applying ruleset`**：
  netavark 預設的 nftables driver 在 WSL2 kernel 上不work。phase2 會裝 `iptables`
  並寫 `/etc/containers/containers.conf` 設 `firewall_driver = "iptables"`；確認兩者都在。
  注意 `podman run` 不受影響（走 pasta 預設網路），所以這個問題只在 compose 浮現。
- **`podman pull postgres` 說 short-name 無法解析**：Ubuntu 完全不出貨
  `/etc/containers/registries.conf`，內建 shortnames 別名表也沒有 postgres/redis/nats。
  phase2 會寫入 `unqualified-search-registries = ["docker.io"]`；確認該檔存在。
  （會 fail fast，不會卡住等輸入，所以不影響無人值守。）
- **`podman run` 正常但 `docker-compose up` 噴 `oom_score_adj: Permission denied`**：
  compose 經由 systemd user unit 呼叫 podman，容器繼承 `OOMScoreAdjust=100`，
  規格要求 0 時無法以非特權調降。解法是給 `user@.service` 加
  `OOMScoreAdjust=0` drop-in。新版 crun 可能已緩解，遇到再處理。
- **go.dev 抓最新版失敗**：把 `$GoVersion` 改成具體版本號（如 `1.23.4`）重跑 phase3。

---

## 9. 給執行方 Claude CLI 的行為準則

- 每個**不可逆動作**（unregister distro、覆寫既有檔案）前，**明確向使用者確認**。
- **不要**擅自改變已定案的架構決策（Podman、單 distro、config 驅動）。
- **不要**自動化 SSH 公鑰佈署或平台登入。
- 遇到腳本內的 pipe-to-shell，向使用者說明但不擅自移除。
- 若使用者中途想改設定，引導他改 `config.ps1` 而非改腳本邏輯。
