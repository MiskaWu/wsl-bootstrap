# CLAUDE.md

## 這個 repo 是什麼

Config-driven、無人值守的 WSL2 開發環境建置工具。一個 PowerShell orchestrator
（`bootstrap.ps1`）在 Windows 上跑，把三支 bash 腳本 pipe 進 WSL distro 執行，
中途自動重啟 WSL 兩次。產出：一個乾淨的 Ubuntu 24.04 distro，內含 Podman
(rootless)、Go、Claude Code，以及可選的 Node/Python/client tools/SSH keys。

**這不是一個會長期跑的服務，是一次性的建置腳本。**「正確」的定義是：在一台乾淨的
Windows 機器上從零跑到底，不需要人介入，且結束後驗證清單全過。

## 兩份文件的分工（不要搞混）

| 檔案 | 讀者 | 內容 |
|---|---|---|
| `CLAUDE.md`（本檔） | 在**這個 repo 裡改程式碼**的 Claude | 架構約束、慣例、已知地雷 |
| `HANDOFF.md` | 在**目標機器上執行建置**的 Claude CLI | 執行步驟、決策脈絡、驗證清單 |
| `README.md` | 人類（英文，對外） | 專案簡介與用法 |

改動若影響執行流程或驗證方式，`HANDOFF.md` 要同步更新；影響對外行為（選項、預設值、
安裝內容）則 `README.md` 要同步。三份不同步是這個 repo 最容易累積的債。

## 架構決策（已定案，不要重新論證）

這些是使用者深思後拍板的，除非他主動要求，不要提議改：

- **單一 WSL2 distro 就是開發環境**，不做 per-project devcontainer。Windows→WSL2
  已是一層完整隔離，solo dev、專案數少，且 Claude Code 在 native shell 體驗最好。
- **容器 runtime 用 Podman (rootless)**，理由是 rootless 安全性 + 與家用 k3s 的
  `podman generate kube` 對齊。容器只用來跑依賴服務（Postgres/NATS/Redis）和 build
  image，不當 app runtime。
- **Go 直接裝 binary 到 `/usr/local/go`**，不用 gvm/mise。build/prod 的 Go 版本由各
  專案 Dockerfile 自己 pin，跟 host 的 Go 各司其職。
- **Node → nvm，Python → uv。**
- **設定走 config 檔，不是互動式問答。** 執行過程零互動是核心價值，任何新增的
  「請使用者輸入」都違反這點——唯一例外是不可逆操作的確認（如 unregister distro）。
- **pipe-to-shell（`curl … | bash`）是已接受的取捨。** 使用者是 infra 工程師，知道
  風險。不要擅自改成下載後驗證 checksum，除非他要求。
- **免密碼 sudo** 是刻意的（開發機）。
- **SSH 公鑰佈署與 Claude Code 認證保持手動**，phase3 只印清單。不要自動化。

## Phase 結構與為什麼不能合併

```
Phase 0  (PS)    wsl --install --no-launch
Phase 1  (root)  apt + 建 user + /etc/wsl.conf
         ↓ wsl --shutdown        ← systemd 與 default user 只在 VM 重啟後生效
Phase 2  (root)  container runtime + baseline 套件
         ↓ wsl --terminate       ← group 變更（docker group / linger）需要重啟 session
Phase 3  (user)  Claude Code, Go, 可選 toolchain, SSH keys
```

重啟點是**功能性的，不是保守做法**。要合併 phase 之前先確認你知道那個重啟在等什麼。

新增安裝步驟時先問：這需要 root 嗎？需要前一個 phase 的重啟生效嗎？據此決定放哪個 phase。

## 設定如何流動

`config.ps1`（gitignored）→ `bootstrap.ps1` 讀成 PS 變數 → `Invoke-Wsl` 以 `BS_*`
環境變數前綴注入 bash → 各 phase 用 `${BS_XXX}` 讀。

新增一個設定項要改四個地方，缺一不可：
1. `config.example.ps1` — 加變數 + 註解說明
2. `bootstrap.ps1` — 加進對應 phase 的 `-EnvVars` hashtable
3. `scripts/phaseN-*.sh` — 讀 `BS_XXX` 並使用
4. `README.md` 的選項表格

布林值經過 `([string]$X).ToLower()` 變成 `"true"`/`"false"` 字串，bash 端一律用
`[ "${BS_X:-false}" = "true" ]` 比較。不要在 bash 端寫 `if [ "$BS_X" ]`——`"false"`
是非空字串，會恆真。

## 已知地雷

**`systemctl --user` 在 phase3：能動，但別依賴它自己能動。**（2026-07 實測更正：
這條原本寫「不會動，因為 `wsl -u <user> bash -s` 不走 PAM 所以 `XDG_RUNTIME_DIR` /
`DBUS_SESSION_BUS_ADDRESS` 沒設」——**那是錯的**。WSL 自己的 init 會注入這兩個變數，
不是靠 PAM，實測 `systemctl --user is-system-running` 在該情境回傳 `running`。）

但變數有設**不等於** user manager 真的在跑——那是靠 phase2 的
`loginctl enable-linger`。所以 phase3 仍自己設一次，當作不依賴 WSL 實作細節的保險：

```bash
XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR
export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
```

注意 WSL 注入的值**帶結尾斜線**（`/run/user/1000/`），拿它去拼路徑會出現雙斜線；
自己用 `$(id -u)` 組就沒這問題。

**不要用 `2>/dev/null || true` 吞掉 `systemctl --user` 的錯誤。** phase3 的
`podman.socket` 那行是整個腳本最該大聲失敗的地方：socket 沒起來但 `DOCKER_HOST`
已經寫進 profile 的話，bootstrap 報成功，然後你第一次 `docker-compose up` 才爆。

**`.bashrc` 對非互動 shell 無效。** Ubuntu 預設 `.bashrc` 開頭就 `case $- in *i*) ;;
*) return;; esac`。`add_line` 是 append 到檔尾，所以寫進去的 `export` 只在互動 shell
生效——`wsl -d dev-2026 -e <cmd>`、腳本、cron 都吃不到。環境變數該放 `~/.profile` 或
`/etc/profile.d/`；alias 放 `.bashrc` 沒問題（本來就只對互動有意義）。

**`.ps1` 必須存成 UTF-8 **帶 BOM**（2026-07 踩到，已修）。** PS 5.1 讀 `.ps1` 時，
**沒有 BOM 就用系統 ANSI codepage**（繁中機器是 CP950/Big5），不是 UTF-8。註解裡中文的
UTF-8 位元組被當 Big5 解會失步，吐出雜散引號/反引號，**把 `Die "..."` 的字串邊界弄爛，
整個檔案語法錯誤跑不起來**（症狀是莫名其妙的「缺少 `}`」，指向與真凶無關的行號）。

三個 `.ps1`（`bootstrap.ps1`、`config.ps1`、`config.example.ps1`）開頭都有 `EF BB BF`，
**不要拿掉**。很多編輯器和工具預設存 UTF-8 無 BOM，改完務必驗：

```bash
head -c 3 bootstrap.ps1 | xxd -p        # 應為 efbbbf
```

```powershell
# 語法驗證（不執行）
$e=$null; [System.Management.Automation.Language.Parser]::ParseFile(
  (Resolve-Path .\bootstrap.ps1).Path, [ref]$null, [ref]$e) | Out-Null; $e
```

注意 `config.example.ps1` 純 ASCII 值時「剛好」沒 BOM 也能解析——別因此以為沒事，
那只是運氣，加了中文註解就會爆。

**PowerShell → bash 的編碼（已修，2026-07）。** `$script | wsl.exe bash -s` 用
`$OutputEncoding` 編碼，PS 5.1 預設 US-ASCII，會把腳本裡的中文轉成 `?`。
`bootstrap.ps1` 開頭現在設 `$OutputEncoding = [System.Text.UTF8Encoding]::new($false)`
把它釘成無 BOM UTF-8。**不要改成 `[Text.Encoding]::UTF8`**——那個帶 BOM，bash 讀到
開頭的 `\xEF\xBB\xBF` 會直接噴錯。以下為原始記錄：中文轉 `?` 目前都在引號/註解內所以沒炸，但新增
程式碼時別依賴這個運氣。

**CRLF：`Get-Script` 只擋一半，PS 的 pipe 自己會加回一個 CR（2026-07 踩到，已修）。**
`Get-Script` 的 `-replace "\r\n","\n"` 處理的是**檔案內部**。但 **PowerShell 把字串
pipe 給原生指令時，一定會在結尾補上 `\r\n`**。因為 `Get-Content -Raw` 保留了檔案結尾的
`\n`，補上去的 CR 就**單獨成為最後一行**，bash 拿它當指令跑：

```
bash: line 43: $'\r': command not found      → exit 127
```

**症狀極具誤導性**：phase 的工作全部做完、log 印到「完成」，然後才以 127 失敗，
看起來像最後一個指令壞了，其實整份腳本都跑完了。

`Invoke-Wsl` 現在在結尾補 `"\n# EOF"`，讓那個必然出現的 CR 落在註解後面。
**不要改成 `$Script + "\n"`**——那樣 CR 一樣自己佔一行，照爆。改動 `Invoke-Wsl` 的
pipe 方式時務必重驗：

```powershell
# 這個必須 exit=0；拿掉 "`n# EOF" 就會變 127
("set -euo pipefail`necho OK`n" + "`n# EOF") | wsl.exe -d <distro> bash -s; $LASTEXITCODE
```

**`.gitattributes` 用 `*.sh text eol=lf` 釘死換行，不要拿掉。** 這台
`core.autocrlf=true`，沒釘的話 clone 下來的 `.sh` 全是 CRLF。`phase*.sh` 走
`Get-Script` 還撐得住，但 `verify.sh` 是直接 `bash -l < scripts/verify.sh` 餵進去的，
沒有任何東西幫它轉——**新增任何「不經過 `Get-Script` 就餵給 bash」的檔案時，
先確認它被 `.gitattributes` 蓋到**。

**`Get-Content` 讀 `.sh` 一定要 `-Encoding UTF8`（同上，已修）。** 跟 `.ps1` 的 BOM
是同一類問題、但在讀取端：PS 5.1 對無 BOM 的檔案預設用系統 ANSI codepage（CP950）解，
`.sh` 裡的中文註解與 log 訊息會被解成亂碼（`建立` → `撱箇?`）再送進 bash。目前亂碼都落在
註解/字串內所以「只是」難看，但那是運氣——**別讓中文出現在會影響語法的位置**。

**雙引號字串裡的反引號會被 PowerShell 當 escape 吃掉。** 訊息裡想引用指令請用單引號
字串。

**Arch 命名不一致，別搞混：** docker-compose 資產用 `uname -m`（`x86_64`/`aarch64`），
Go tarball 用 `dpkg --print-architecture`（`amd64`/`arm64`）。兩者都對，但不能互換。

## 慣例

- **Bash：** 一律 `set -euo pipefail`。必要的環境變數用 `: "${BS_X:?BS_X not set}"`
  在開頭 fail fast，不要給假的 fallback 預設值（orchestrator 一定會傳，寫死預設值只會
  在出錯時掩蓋問題）。
- **Log：** 每個 phase 有自己的顏色 `log()`（phase1 藍 / phase2 紫 / phase3 綠），
  PS 端是 `Info`/`Warn`/`Die`。
- **冪等性：** 重跑不該爆炸也不該重複。已有的模式：`add_line` 用 `grep -qxF` 去重、
  建 user 前 `id` 檢查、SSH key 存在就跳過。新增步驟請比照。
- **註解、log 與 commit 訊息用繁體中文**，README 用英文（對外）。
- **不可逆操作要互動確認**，並且要求輸入具體名稱而非 y/n（見 `bootstrap.ps1` 的
  `$UnregisterOld` 區塊）。

## 怎麼驗證改動

**沒有自動化測試，也不該硬加**——這東西的測試就是在乾淨機器上跑一次。

改 bash 腳本後至少做到：
- `shellcheck scripts/*.sh`（Windows 端通常沒裝，可在 WSL 裡跑）
- 語法檢查：`bash -n scripts/phaseN-*.sh`
- 心裡跑一遍冪等性：這步驟重跑會怎樣？

**改 `.ps1` 後一定要做語法解析**——2026-07 那次，`bootstrap.ps1` 因為缺 BOM 直接
整份語法錯誤，而上面那串 bash 檢查一個都照不到：

```powershell
$e=$null; [System.Management.Automation.Language.Parser]::ParseFile(
  (Resolve-Path .\bootstrap.ps1).Path, [ref]$null, [ref]$e) | Out-Null; $e
```

```bash
head -c 3 bootstrap.ps1 | xxd -p      # efbbbf，BOM 不能掉
```

**用 `-File` 模式測，不要只用 `.\bootstrap.ps1`。** 兩者行為不同（`$PSScriptRoot`
在 param 預設值裡只有 `-File` 模式是空的），而 `-File` 正是 README/HANDOFF 教的
ExecutionPolicy 繞道，也就是使用者實際會走的路。

真要端到端驗證，成本是 `wsl --unregister <distro>` 後整套重跑（約 10–20 分鐘）。
所以**改動要小、要能從程式碼推理出正確性**，不要靠「跑跑看」。但注意 2026-07 那三個
bug（BOM、`$PSScriptRoot`、pipe 補 CR）**全都推理不出來、只能實測**——碰到
PowerShell↔bash 邊界的東西，用上面那種小實驗隔離驗證，別用整套重跑當測試。

改完後對照 `HANDOFF.md` §6 的驗證清單，確認你的改動不會讓清單裡某項失效。
