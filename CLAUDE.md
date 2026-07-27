# CLAUDE.md

## 這個 repo 是什麼

Config-driven、無人值守的 WSL2 distro **bring-up** 工具。一個 PowerShell orchestrator
（`bootstrap.ps1`）在 Windows 上跑，把**一支** bash 腳本（`scripts/provision.sh`）pipe
進新建的 WSL distro，中途自動重啟 WSL 兩次。產出：一個乾淨的 Ubuntu 26.04 distro，有
systemd、預設 user、免密碼 sudo、baseline（**git + make + openssh-client**）、**已設好的
git 身分與 SSH keys**、Ubuntu 遙測已 opt-out —— 一台「裝完就 git-ready、clone 組態管理 repo
`make` 起手就能接手」的機器。

**軟體工作環境（Podman / Go / Claude Code / toolchain）不在這裡** —— 由獨立的
`dev-env-ansible` repo 負責，在 distro 內 clone + `make init`。拆兩個 repo 是刻意的：那個
Ansible role 是 host-agnostic、可跨任何 Linux host 用，不該綁在這支 WSL-specific 的
bootstrap。改軟體層去 `dev-env-ansible`，別在這裡加。

**baseline 為什麼是 git + make + openssh（2026-07 收斂）：** bring-up 不該預設你用哪套組態
管理，所以只給「clone repo（git）+ 跑它的操作入口（make）」的最小集。連 `ansible` 都不裝 ——
組態管理 repo 的 Makefile 會在需要時自己 `apt install ansible-core`（不能用 ansible 裝
ansible，這層由 make 補）。`make` 一定要在 baseline：它是 repo 的入口，而 make 指令本身
得先存在才跑得起來（第二層雞生蛋）。`openssh-client` 是因為 bring-up 現在會 `ssh-keygen`、
且 git over ssh 要用。這也讓整套跨平台通用 —— 非 WSL host 只要有 git+make 就能 clone +
`make init`。

**git 身分與 SSH keys 為什麼放 bring-up（而非軟體 repo）：** 它們是「一台個人機」的一部分，
不是軟體工作環境；而且 **SSH key 得先在，才能 clone 私有的組態管理 repo**（雞生蛋）。放在
bring-up，裝完 distro 就 git-ready、公鑰已印出可貼平台。生成在這裡，但**貼到 GitHub/GitLab
是手動**（不自動佈署平台憑證）。設定在 `config.ps1`（`$GitName`/`$GitEmail`/`$SshKey*`）。

**這不是會長期跑的服務，是一次性建置腳本。**「正確」= 在乾淨 Windows 上從零跑到底、
零互動、結束後 `scripts/verify.sh` 全過。

## 文件分工

| 檔案 | 讀者 | 內容 |
|---|---|---|
| `CLAUDE.md`（本檔） | 在**這個 repo 改碼**的 Claude | bring-up 的架構、慣例、地雷、排查 |
| `README.md` | 人類（英文，對外） | 專案簡介與用法 |

軟體層的地雷與慣例在 `dev-env-ansible/CLAUDE.md`。改動影響對外行為就同步 `README.md`。

## 架構決策（已定案，不要重新論證）

- **兩個 repo，職責分離。** `wsl-bootstrap`（Windows 端，只做 WSL 能做的：建 distro +
  wsl.conf + 重啟）＋ `dev-env-ansible`（在 box 上跑的 Ansible role，裝軟體）。軟體層決策
  （podman、Go、toolchain）記在 dev-env-ansible，別在這裡論證。
- **單一 WSL2 distro 就是開發環境**，不做 per-project devcontainer。
- **底座 Ubuntu 26.04**（Resolute Raccoon，podman 5.7；24.04 凍在 4.9.3，理由見
  dev-env-ansible / git 歷史）。
- **網路用 `networkingMode=mirrored`（2026-07 實測定案）。**
  **⚠️ 這條先前寫反過——原本記「留預設 NAT 就夠、實測 Windows→容器 port 通」，但那次
  「實測」是在 mirrored 開著時做的，功勞被錯算給 NAT。** 關掉 mirrored 後重測（容器確認
  存活、並用純 WSL 程序作對照組）：

  | 模式 | Windows → 純 WSL 程序 | Windows → rootless podman 容器 port |
  |---|---|---|
  | NAT | ✅ | ❌ **不通** |
  | mirrored | ✅ | ✅ |

  `localhostForwarding` 只轉 WSL init netns 裡的 listener，**不轉 pasta 為 rootless 容器
  發佈的 port**。而「Windows 直接用 localhost 使用 distro 內服務、不做手動 forward」是硬
  需求，所以 mirrored 必要。**只用 `[wsl2]` 的 `networkingMode`，不加 `[experimental]` 的
  `hostAddressLoopback`**——實測 `127.0.0.1` 路徑不靠它（它只多開「用本機 LAN IP 連」那條）。
  已知 mirrored 風險（#13868 WSL 內 127.0.0.1 連不到、#13317 容器 ~3 分 timeout）**本機
  實測皆未發生**（4 分鐘仍活）；#14080 是 Windows 更新會靜默停用 mirrored，**WSL 更新後
  要重驗這三項**。
  教訓：**跨 Windows/WSL 邊界的網路結論，一定要確認當下的 `networkingMode` 再歸因。**
- **全域 `.wslconfig` 由本 repo 管理（2026-07 起）。** repo 裡的 `wslconfig` 是 source of
  truth，`bootstrap.ps1` 依 `$DeployWslConfig` 部署到 `%USERPROFILE%\.wslconfig`（內容不同
  才寫、覆蓋前備份）。起因：原本那份 `.wslconfig` 標的 source of truth
  （`infra/windows/wslconfig`）**根本不存在**，部署副本是唯一一份、誤刪就沒了。
  **政策：只用穩定設定，不碰 `[experimental]`。** 該區段照定義就不穩定。歷史教訓：
  `autoMemoryReclaim` / `sparseVhd` 曾被誤放在 `[wsl2]`，WSL 直接忽略並印 unknown key
  警告 —— 等於**從未生效**，所以「修好它」不是回復原狀，是引入沒驗證過的行為。
  寫檔要用 .NET `WriteAllText` + 無 BOM UTF8：PS 5.1 的 `Set-Content -Encoding UTF8`
  會帶 BOM，而這個檔是 WSL 自己解析的。
- **Ansible 本機 `make apply`**，不走 control node SSH → 所以 bring-up **不裝 sshd**。
- **設定走 config 檔、執行零互動**（唯一例外：不可逆操作的確認，如 unregister distro）。
- **pipe-to-shell（`curl … | bash`）已接受**（infra 工程師知道風險，別擅自改 checksum）。
- **免密碼 sudo 刻意**（開發機）。
- **SSH keys 由 bring-up 生成**（provision.sh 的 `ssh-keygen`，per scope，無 passphrase），
  但**貼公鑰到 GitHub/GitLab 這一步保持手動**（bootstrap 只印公鑰、不自動佈署，不把平台憑證
  帶進自動化）。**Claude Code 認證也保持手動**（瀏覽器 OAuth）。生成 ≠ 佈署：生成在這裡，
  佈署（貼平台）是你的事。
- **非預設檔名的 key 一定要配 `~/.ssh/config`（2026-07 踩過）。** key 叫
  `id_ed25519_<tag>_<scope>`，SSH 預設只找 `id_ed25519`/`id_rsa` 那些標準名，**不會**自動拿
  我們的去用 —— 少了 config，`git pull`/`clone` over ssh 完全不會碰到這些 key（症狀：明明有
  key 卻認證失敗/沒反應）。所以 provision 生成 key 後**同時寫 `~/.ssh/config`**：每個 scope 一段
  `Host <host>` + `IdentityFile <該把 key>` + `IdentitiesOnly yes`（只用指定那把，避免多 key 時
  "Too many authentication failures"）。scope→host 對應：github→github.com、gitlab→gitlab.com、
  bitbucket→bitbucket.org，其餘原樣。config 用 managed 標記包住、重跑只覆蓋自己那段。

## 流程結構（為什麼有重啟）

```
Phase 0   (PS)     wsl --install --no-launch
provision (root)   apt + 建 user + wsl.conf + baseline(git+make+openssh) + git身分 + SSHkeys + OOBE opt-out
          ↓ wsl --shutdown      ← systemd 與 default user 只在 VM 重啟後才生效
          ↓ wsl --terminate     ← 收尾，讓第一次進入是乾淨 session（避 user-session race）
```

重啟是**功能性的**，不是保守做法。以前還有 phase2（容器 runtime）/ phase3（toolchain），
已整批搬進 `dev-env-ansible`，所以現在只剩一支 provision。

## 更新機制（no-arg 自動判斷 / dry-run，2026-07 加）

bring-up 不只一次性建置——**直接 `bootstrap.ps1`（no-arg）就會偵測狀態**：distro 已存在
→ 進更新模式對它冪等收斂（不必 unregister 重建，不動 key / 資料 / 已 clone 的東西）；不存在
→ 問要不要從零建。互動優先（跑起來自己問），旗標只是捷徑。關鍵設計：

- **同一支 `provision.sh` 跑 fresh 與 update（單一 source of truth）**，靠 `BS_DRY_RUN`
  切換：非空 = 預覽（managed 檔做 unified diff、套件/key 只報告），空 = 實際套用。這樣
  「預覽看到的」與「套用做的」保證同一份邏輯、不會漂移。
- **`write_or_diff` helper**（provision.sh）：內容用 stdin 餵，dry-run diff 現況、套用
  `install` 到位（owner/mode）。所有 managed 檔（wsl.conf、consent、`~/.ssh/config`）都走它。
  ssh config 先組「更新後完整內容」（`sed` 砍舊 managed 區塊 + 附新）再交給它 diff/寫。
- **流程**：更新模式 = 預覽 diff → 互動 `Read-Host` 問（接受 `y`/`yes`）→ 套用；建立模式 =
  問「要建嗎」→ 建。旗標：`-Yes` 跳過所有確認（無人值守）、`-WhatIf` 只預覽、`-Update` 顯式
  要求更新（對不存在的 distro 報錯，防打錯字誤建）、`-Upgrade` 才 apt upgrade。
- **`BS_SKIP_UPGRADE` 要看「模式」不是「旗標」（2026-07 踩過）。** update 預設跳過 apt upgrade，
  但一開始把它綁在 `-Update` 旗標上——no-arg 自動進更新時 `$Update` 是 false，upgrade 就沒被
  跳過。改成 `Invoke-Provision -SkipUpgrade:(-not $Upgrade)` 由**呼叫點依所在模式**決定：更新
  分支傳跳過、fresh 分支不傳（照裝 upgrade）。
- **不自動重啟**（不打斷 running distro）：只有動到 wsl.conf / .wslconfig 才需 `wsl --shutdown`，
  由收尾訊息提示。`Sync-WslConfig -Preview` 也會 diff `.wslconfig` 並警告要 shutdown。
- **bootstrap.ps1 結構**：`Get-Script` / `Invoke-Wsl` / `Invoke-Provision` / `Sync-WslConfig`
  四個函式 + 模式分派（依 `$existing -contains $Distro`：存在→更新、不存在→建立）。`-Update`
  只是「強制更新且斷言存在」（不存在就 Die，防誤建）。
- provision 的冪等（見「慣例」）本來就是前提，更新只是把它反過來用在現有 distro。

## 設定如何流動

`config.ps1`（gitignored）→ `bootstrap.ps1` 讀成 PS 變數 → `Invoke-Wsl` 以 `BS_*` 環境
變數前綴注入 bash → `provision.sh` 讀 `${BS_XXX}`。目前傳：`BS_USER`、`BS_GIT_NAME`、
`BS_GIT_EMAIL`、`BS_SSH_KEY_TAG`、`BS_SSH_KEY_COMMENT`、`BS_SSH_KEY_SCOPES`（陣列以空白
join 成字串，bash 端 `for scope in ${BS_SSH_KEY_SCOPES}` 迭代）。未定義的 config 變數在
StrictMode-off 下是 `$null` → `[string]$null=''`，provision 對應步驟會略過，所以舊 config 不會壞。

軟體層的設定（runtime、go 版本、Node/Python/clients 開關）在 `dev-env-ansible`，**不在這裡**。
但 **git 身分與 SSH keys 的設定在這裡**（`config.ps1`）—— 它們屬 bring-up（key 得先在才能
clone 私有 repo）。新增 bring-up 設定項要改：`config.example.ps1`（+註解）、`config.ps1`、
`bootstrap.ps1`（`-EnvVars`）、`provision.sh`（讀 `BS_XXX`）、`verify.sh`、`README.md` 表格。

## 已知地雷（PowerShell↔bash 邊界，全部 2026-07 踩過、已修）

這些**推理不出來、只能實測**——碰到這條邊界的東西，用小實驗隔離驗證，別靠整套重跑。

**`.ps1` 必須存成 UTF-8 帶 BOM。** PS 5.1 讀 `.ps1` **沒 BOM 就用系統 ANSI codepage**
（繁中機器是 CP950/Big5），不是 UTF-8。中文註解的 UTF-8 位元組被當 Big5 解會失步，吐出
雜散引號/反引號，**把 `Die "..."` 的字串邊界弄爛、整份語法錯誤**（症狀是莫名的「缺少
`}`」，指向與真凶無關的行號）。三個 `.ps1`（`bootstrap.ps1`、`config.ps1`、
`config.example.ps1`）開頭都有 `EF BB BF`，**不要拿掉**。很多編輯器預設存無 BOM，改完必驗
`head -c 3 bootstrap.ps1 | xxd -p`（應為 `efbbbf`）。`config.example.ps1` 純 ASCII 時
「剛好」沒 BOM 也能解析——那只是運氣，加中文註解就爆。

**PowerShell → bash 的輸出編碼。** `$script | wsl.exe bash -s` 用 `$OutputEncoding` 編碼，
PS 5.1 預設 US-ASCII，會把中文轉 `?`。`bootstrap.ps1` 開頭設
`$OutputEncoding = [System.Text.UTF8Encoding]::new($false)` 釘成無 BOM UTF-8。
**不要改成 `[Text.Encoding]::UTF8`**——那個帶 BOM，bash 讀到開頭 `\xEF\xBB\xBF` 會噴錯。

**`Get-Content` 讀 `.sh` 一定要 `-Encoding UTF8`。** 同 BOM 問題、讀取端：沒指定編碼時
PS 5.1 用 CP950 解無 BOM 的 `.sh`，中文會變亂碼（`建立` → `撱箇?`）再送進 bash。

**CRLF：`Get-Script` 只擋一半，PS 的 pipe 自己會加回一個 CR。** `Get-Script` 的
`-replace "\r\n","\n"` 處理**檔案內部**；但 **PowerShell 把字串 pipe 給原生指令時一定在
結尾補 `\r\n`**。因為 `Get-Content -Raw` 保留檔案結尾的 `\n`，補上去的 CR **單獨成為最後
一行**，bash 拿它當指令跑 → `$'\r': command not found` → exit 127。**症狀極誤導**：
phase 全做完、log 印到「完成」才 127 失敗。`Invoke-Wsl` 現在結尾補 `"\n# EOF"` 讓那個 CR
落在註解後。**不要改成 `$Script + "\n"`**（CR 一樣自己佔一行照爆）。改 `Invoke-Wsl` 的
pipe 方式必重驗：

```powershell
# 必須 exit=0；拿掉 "`n# EOF" 就變 127
("set -euo pipefail`necho OK`n" + "`n# EOF") | wsl.exe -d <distro> bash -s; $LASTEXITCODE
```

**`$PSScriptRoot` 在 `param()` 預設值裡是空的（只有 `-File` 模式）。** 所以 config 路徑在
腳本本體才解析，不能寫進 param 預設。`-File` 正是 README 教的 ExecutionPolicy 繞道，
使用者實際會走這條——測試也要用 `-File`，別只用 `.\bootstrap.ps1`。

**`.gitattributes` 用 `*.sh text eol=lf` 釘死換行，不要拿掉。** 這台 `core.autocrlf=true`，
沒釘的話 clone 下來的 `.sh` 全 CRLF。`provision.sh` 走 `Get-Script` 還撐得住，但
`verify.sh` 是直接 `bash -l < scripts/verify.sh` 餵的，沒東西幫它轉——**新增任何「不經
`Get-Script` 就餵 bash」的檔案，先確認被 `.gitattributes` 蓋到**。

**雙引號字串裡的反引號會被 PowerShell 當 escape 吃掉。** 訊息要引用指令請用單引號字串。

**OOBE metrics opt-out 用 consent 檔，不是 registry。** Ubuntu 26.04 首次互動啟動時
`wsl-setup` 會問「opt-in platform metrics?」（違反零互動）。`provision.sh` 預先為 user 寫
`~/.config/ubuntu-insights/<source>-consent.toml`（`consent_state=false`）——官方認可，
OOBE 偵測到有效 consent 檔就跳過提問、且覆蓋 Windows registry 預設。至少要 `wsl_setup`
這個 source（另兩個 `linux` / `ubuntu_release_upgrader` 一併關月度回報）。

**`.bashrc` 對非互動 shell 無效**（通則，主要咬 dev-env-ansible）。Ubuntu 預設 `.bashrc`
開頭就 `case $- in *i*) ;; *) return;; esac`，寫檔尾的 `export` 只有互動 shell 吃得到；
`wsl -d dev -e <cmd>`、腳本、cron 都讀不到。環境變數放 `~/.profile`；alias 放 `.bashrc`。

## 慣例

- **Bash：** `set -euo pipefail`；必要 env 用 `: "${BS_X:?BS_X not set}"` 開頭 fail fast，
  不給假 fallback（orchestrator 一定會傳，寫死預設只會掩蓋出錯）。
- **Log：** `provision.sh` 用藍色 `log()`；PS 端 `Info`/`Warn`/`Die`。
- **冪等性：** 重跑不爆不重複（建 user 前 `id` 檢查、consent 檔固定內容覆寫、`mkdir -p`、
  `install -d`）。新增步驟比照。
- **註解、log、commit 訊息、README 都用繁體中文**（2026-07 起 README 也改繁中）。
- **不可逆操作要互動確認**，且要求輸入具體名稱而非 y/n（見 `$UnregisterOld` 區塊）。

## 怎麼驗證改動

沒有自動化測試，也不該硬加。改完至少：

- 改 `.sh`：`bash -n scripts/*.sh`、`shellcheck scripts/*.sh`（Windows 端沒裝，在 WSL 跑）。
- 改 `.ps1`：**一定做語法解析**（BOM 缺失只有這抓得到）+ 確認 BOM：

  ```powershell
  $e=$null; [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\bootstrap.ps1).Path, [ref]$null, [ref]$e) | Out-Null; $e
  ```
  ```bash
  head -c 3 bootstrap.ps1 | xxd -p      # efbbbf
  ```

- **用 `-File` 模式測**（見 `$PSScriptRoot` 地雷）。
- 端到端：`wsl --unregister <distro>` 重跑（provision 很輕、快），或建**丟棄用的
  `dev-test`** 驗證不碰 `dev`。驗收：`wsl -d dev -u miskawu -- bash -l < scripts/verify.sh`。

## 出錯時的排查

- **`bootstrap.ps1` 一跑就語法錯**（莫名缺 `}`）：`.ps1` 的 BOM 被存掉了，`head -c 3` 應
  `efbbbf`。
- **provision 中斷**：檢查 `$LASTEXITCODE` 會停在出錯處；`wsl --unregister <distro>` 清半
  成品重跑。
- **`--name` 不支援**：`wsl --update`，或改 `wsl --import` 從 rootfs 建。
- **`is-system-running` degraded / user session 起不來 / rootless socket 起不來**：
  WSL 上 systemd 259 的 `user@<uid>` 起來後 spawn systemd-executor 失敗（journal:
  `Failed to spawn executor: Device or resource busy`），**不是建置失敗**。**要 full
  `wsl --shutdown`（不是 `--terminate`）**——後者只停單一 distro、留 VM 層狀態清不掉，
  full shutdown 重置整個 VM 才行。之後乾淨 session `user@` active、rootless podman.socket
  自動起。（verify.sh 的 settle 迴圈只是等 is-system-running 安定；socket 層的問題要
  `wsl --shutdown`。）
- **首次啟動仍跳 metrics 提問**：確認 provision 寫了 consent 檔
  （`~/.config/ubuntu-insights/wsl_setup-consent.toml` = `consent_state = false`）。
- **軟體層（podman / compose / go / netavark / registries…）的問題** → 見
  `dev-env-ansible/CLAUDE.md`，那些已不是這個 repo 的事。
