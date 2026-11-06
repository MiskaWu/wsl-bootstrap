# wsl-bootstrap

Config 驅動的 WSL2 distro **bring-up** 工具（互動引導,`-Yes` 可無人值守）—— 只把 distro
帶到「可以 clone 你的組態管理 repo、用 `make` 起手」的狀態。

一份 config、一道指令，跑完走人。產出一個乾淨的 Ubuntu 26.04 WSL2 distro，內含 systemd、
你的 user、免密碼 sudo、baseline（`git` + `make` + `openssh-client`）、**設好的 git 身分與
SSH keys**，並關掉 Ubuntu 遙測 —— 一台裝完就 git-ready、可交給任何組態管理接手的機器。

真正的開發環境（Podman、Go、Claude Code、toolchain）由另一個獨立 repo **dev-env-ansible**
負責：在機器上 clone 它、`make init` 一路裝好。刻意拆成兩個 repo：那個 role 是
host-agnostic、任何 Linux 都能用，不該綁死在這支 WSL 專用的 bootstrap。連 `ansible` 都
不放進 baseline —— 它的 Makefile 會在需要時自己補（不能用 ansible 裝 ansible）。

## 為什麼拆兩個 repo

- **`wsl-bootstrap`**（本 repo，Windows/PowerShell）做「只有 Windows 能做」的事：建
  distro、在 `/etc/wsl.conf` 設預設 user + systemd、以及讓它們生效的 VM 重啟。
- **`dev-env-ansible`**（獨立 repo，在機器上跑）是軟體環境，一個冪等的 Ansible role：
  `make install` 安裝、`make check` 預覽（乾跑 diff）、`make install TAGS=node` 之後補裝單項
  —— 不砍掉重建。

## 需求

- Windows 11（24H2+）或支援 `wsl --install --name` 的 WSL 版本
- 已啟用 WSL2（保險起見先 `wsl --update`）
- 從 PowerShell 執行

## 用法

```powershell
cp config.example.ps1 config.ps1   # 首次
notepad config.ps1                 # 設 distro / user / git 身分 / SSH key scopes
.\bootstrap.ps1                    # 跑起來就自己問：不存在→問要不要建、已存在→更新（先看 diff）
```

**直接 `.\bootstrap.ps1` 就好，它偵測狀態並互動引導,不必記旗標。** 想無人值守（全程不問）
就加 `-Yes`。建置中會自動重啟 WSL 兩次。

bootstrap 會在收尾印出 SSH 公鑰 —— 貼到 GitHub/GitLab 後就能 clone 私有 repo。接著進 distro，
clone 你的組態管理 repo，用它的 Makefile 起手：

```bash
wsl -d dev
git clone <你的 dev-env-ansible repo> ~/projects/dev-env-ansible
cd ~/projects/dev-env-ansible
make init     # 自己補 ansible → 裝軟體 → 印收尾清單
```

（baseline 沒有 `ansible`，Makefile 第一次跑會自己 `apt install ansible-core`；只想預覽用
`make check`。git 身分與 SSH keys 已在 bring-up 備好，不用再設。）

驗證 bring-up：

```powershell
wsl -d dev -u miskawu -- bash -l < scripts/verify.sh
```

## bring-up 做了什麼（`scripts/provision.sh`，root 身分）

- 建立你的 user（`$User`）並給免密碼 `sudo`
- 寫 `/etc/wsl.conf`：開 systemd、`$User` 為預設登入、WSL 管理 `resolv.conf`、附加
  Windows PATH
- `apt update && upgrade`
- 裝 baseline：`git` + `make` + `openssh-client` —— clone 組態管理 repo、用它的 Makefile
  起手、git over ssh（連 `ansible` 都不裝，交給那個 repo 的 Makefile 自己補）
- 設 git 身分：`$GitName` / `$GitEmail` 寫進 user 的 `~/.gitconfig`（留空則略過）
- 生成 SSH keys：每個 `$SshKeyScopes` 一把 ed25519（無 passphrase），並**印出公鑰**供你貼
  GitHub/GitLab；同時寫 `~/.ssh/config` 把每個 host 對到它的 key（非預設檔名的 key 一定要
  這個對應表，否則 git over ssh 根本不會用到）—— 裝完就能 clone 私有 repo（冪等：key 已存在
  就跳過、config 只覆蓋自己的 managed 區塊）
- 關掉 Ubuntu 26.04 遙測：寫 `~/.config/ubuntu-insights/*-consent.toml`
  （`consent_state = false`），首次啟動不跳互動式 metrics 提問

之後自動重啟 WSL 兩次（一次讓 systemd／預設 user 生效，一次讓你第一次進去是乾淨 session）。

## 更新已建好的 distro

改了 bring-up 設定（`config.ps1`、`provision.sh`、`wslconfig`）後，**不必 unregister 重建**
—— 直接再跑一次 `.\bootstrap.ps1`。它偵測到 distro 已存在，就進更新模式：先給你看 diff、
問你要不要套用。冪等收斂，**不動你的 key / 資料 / 已 clone 的東西**。

```powershell
.\bootstrap.ps1            # 已存在 → 顯示 diff → 問 y → 套用（互動）
.\bootstrap.ps1 -WhatIf    # 只看 diff，不問不改
.\bootstrap.ps1 -Yes       # 跳過詢問直接套用（無人值守）
.\bootstrap.ps1 -Upgrade   # 順便 apt upgrade（預設跳過，免每次動整個系統）
```

預覽會逐項顯示會不會變：baseline 套件、`wsl.conf` / `~/.ssh/config` / `~/.gitconfig` /
consent / `.wslconfig` 的 diff、哪些 key 會生成。**只有動到 `wsl.conf` / `.wslconfig` 才需
`wsl --shutdown` 生效**，其他即時。

同一支 `provision.sh` 靠 `BS_DRY_RUN` 切換預覽 / 套用，所以「看到的 diff」與「實際套用」
是同一份邏輯、不會漂移。（軟體層的更新是另一回事：進 distro `make install`。）

## 設定（`config.ps1`）

| 選項 | 預設 | 控制 |
|---|---|---|
| `$Distro` | `dev` | WSL distro 名（`wsl -d <名>`） |
| `$UbuntuImage` | `Ubuntu-26.04` | 來源 image（`wsl --list --online`） |
| `$User` | `miskawu` | distro 內建立的登入 user |
| `$DeployWslConfig` | `$true` | 把 repo 的 `wslconfig` 部署到 `%USERPROFILE%\.wslconfig`（內容不同才動，覆蓋前備份） |
| `$GitName` / `$GitEmail` | `Your Name` / `you@example.com` | 寫進 user 的 `~/.gitconfig`（兩個都留空則略過） |
| `$SshKeyTag` | `dev` | SSH key 檔名前綴 `id_ed25519_<Tag>_<scope>` |
| `$SshKeyComment` | `you@host` | key 註解基底（接上 `-<scope>` 與生成日期） |
| `$SshKeyScopes` | `@('github','gitlab')` | 為哪些平台各產一把 key（`@()` 則不產） |
| `$UnregisterOld` / `$OldDistroName` | `$false` / — | 建置成功後詢問是否移除指定的舊 distro（需明確確認） |

軟體環境的一切（容器 runtime、Go 版本、Node/Python/clients）在 `dev-env-ansible`，不在這裡。
git 身分與 SSH keys 則相反 —— 在**這裡**（bring-up 就備好，key 得先在才能 clone 私有 repo）。

## 全域 `.wslconfig` 也由本 repo 管理

`wslconfig` 是 source of truth，`bootstrap.ps1` 會部署到 `%USERPROFILE%\.wslconfig`
（內容不同才寫，覆蓋前備份成 `.wslconfig.bak-<時間>`）。這樣全域設定才進版控 ——
2026-07 發現原本那份部署副本標的 source of truth 根本不存在，它是唯一一份，誤刪就沒了。

**政策：只用穩定設定，不碰 `[experimental]`。** 那個區段照定義就不穩定；寧可要一台無聊
但可靠的機器。（歷史：`autoMemoryReclaim` / `sparseVhd` 曾被誤放在 `[wsl2]`，WSL 直接
忽略並警告 unknown key，等於從未生效。）

改 `.wslconfig` 要 `wsl --shutdown` 才生效，且影響機器上**所有** WSL2 distro。

**distro 不閒置關機：`[general] instanceIdleTimeout=-1`（2026-11 加）。** 預設是最後一個
WSL 終端機關掉 15 秒後就停掉 distro，distro 裡的常駐服務（systemd user service）跟著停；
`vmIdleTimeout` 只讓 VM 不關、救不到 distro。這個 key 是穩定設定：官方文件列在 `[general]`，
WSL 2.5.7（2025-04）起進正式版，WSL 團隊在 microsoft/WSL#13033、#13291 也這樣建議。

**記憶體會自己還給 Windows，不用另外設 key。** `memory=` 是 WSL 能佔的上限，不是一定佔滿：
Linux 釋放的頁面會還給 Windows（free page reporting，預設開）；檔案快取則在 VM 的 CPU 連續
約 10 分鐘低於 0.5% 時自動丟掉（`autoMemoryReclaim` 沒設時預設就是 `dropCache`，WSL 2.1.3 起）。
常駐吃記憶體的是服務本身，要在服務那邊修。

## 網路：mirrored（實測後的必要選擇）

用 `networkingMode=mirrored`（`.wslconfig` 的 `[wsl2]` 穩定區段）。**這是量測結論，不是
預設值。** 2026-07 在本機實測（容器確認存活時測，並用「純 WSL 程序」當對照組）：

| 模式 | Windows → 純 WSL 程序 port | Windows → rootless podman 容器 port |
|---|---|---|
| NAT（WSL 預設） | ✅ 通 | ❌ **不通** |
| mirrored | ✅ 通 | ✅ **通** |

`localhostForwarding` 只轉發 WSL init netns 裡的 listener，**不轉發 pasta 為 rootless
容器發佈的 port**。而「從 Windows 直接用 `localhost:<port>` 使用 distro 內的服務、不做
手動 forward」是這裡的硬需求 —— 只有 mirrored 做得到。

**只用穩定區段**：`networkingMode` 本身在 `[wsl2]`；**不需要** `[experimental]` 的
`hostAddressLoopback`。實測 `127.0.0.1` 路徑沒有它就通；它只額外打開「用本機 LAN IP 連」
那條（實測沒開時為 `False`），一般開發用不到。

**已知 mirrored 風險 —— 本機實測皆未發生**（WSL issue tracker，2026 仍開著）：
`#13868`（WSL 內 `127.0.0.1` 連不到容器）→ 實測 `PONG`；
`#13317`（容器約 3 分鐘後 timeout）→ 實測 4 分鐘仍存活且可連。
`#14080`（Windows 更新靜默停用 mirrored）→ **WSL 更新後要重驗這三項**。

## 檔案結構

```
wsl-bootstrap/
├── bootstrap.ps1          # PowerShell orchestrator（無人值守）
├── config.example.ps1     # 複製成 config.ps1
├── wslconfig              # 全域 .wslconfig 的 source of truth（部署到 %USERPROFILE%）
└── scripts/
    ├── provision.sh       # 唯一的 root bring-up phase
    └── verify.sh          # 建置後的 bring-up 檢查
```

## 備註

- `config.ps1` 已 gitignore。
- repo 放 WSL 檔案系統（`~/`），不要放 `/mnt/c/` —— I/O，而且 Ansible 會忽略
  world-writable 的 `/mnt/c` 裡的 `ansible.cfg`。
- bring-up 之後：git 身分與 SSH keys 已備好。clone 你的組態管理 repo + `make init` 裝軟體；
  收尾只剩把公鑰貼到 GitHub/GitLab、`claude` 首次 OAuth（都刻意保持手動）。

## 授權

[MIT](LICENSE)
