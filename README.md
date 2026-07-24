# wsl-bootstrap

Config 驅動、無人值守的 WSL2 distro **bring-up** 工具 —— 只把 distro 帶到「可以 clone
你的組態管理 repo、用 `make` 起手」的狀態。

一份 config、一道指令，跑完走人。產出一個乾淨的 Ubuntu 26.04 WSL2 distro，內含 systemd、
你的 user、免密碼 sudo、baseline（**只有 `git` + `make`**），並關掉 Ubuntu 遙測 ——
一台乾淨、可交給任何組態管理接手的機器。

真正的開發環境（Podman、Go、Claude Code、toolchain）由另一個獨立 repo **dev-env-ansible**
負責：在機器上 clone 它、`make init` 一路裝好。刻意拆成兩個 repo：那個 role 是
host-agnostic、任何 Linux 都能用，不該綁死在這支 WSL 專用的 bootstrap。連 `ansible` 都
不放進 baseline —— 它的 Makefile 會在需要時自己補（不能用 ansible 裝 ansible）。

## 為什麼拆兩個 repo

- **`wsl-bootstrap`**（本 repo，Windows/PowerShell）做「只有 Windows 能做」的事：建
  distro、在 `/etc/wsl.conf` 設預設 user + systemd、以及讓它們生效的 VM 重啟。
- **`dev-env-ansible`**（獨立 repo，在機器上跑）是軟體環境，一個冪等的 Ansible role：
  `make apply` 安裝、`make check` 預覽（乾跑 diff）、`make apply TAGS=node` 之後補裝單項
  —— 不砍掉重建。

## 需求

- Windows 11（24H2+）或支援 `wsl --install --name` 的 WSL 版本
- 已啟用 WSL2（保險起見先 `wsl --update`）
- 從 PowerShell 執行

## 用法

```powershell
cp config.example.ps1 config.ps1   # 首次
notepad config.ps1                 # 設 distro 名 + user
.\bootstrap.ps1                    # 無人值守；中途自動重啟 WSL 兩次
```

接著進 distro，clone 你的組態管理 repo，用它的 Makefile 起手：

```bash
wsl -d dev
git clone <你的 dev-env-ansible repo> ~/projects/dev-env-ansible
cd ~/projects/dev-env-ansible
make init     # 自己補 ansible → 裝軟體 → 印出要貼 GitHub 的公鑰 → 印收尾清單
```

（`make init` = `make apply` + `make ssh-keys`；只想預覽用 `make check`。baseline 沒有
`ansible`，Makefile 第一次跑會自己 `apt install ansible-core`。）

驗證 bring-up：

```powershell
wsl -d dev -u miskawu -- bash -l < scripts/verify.sh
```

## bring-up 做了什麼（`scripts/provision.sh`，root 身分）

- 建立你的 user（`$User`）並給免密碼 `sudo`
- 寫 `/etc/wsl.conf`：開 systemd、`$User` 為預設登入、WSL 管理 `resolv.conf`、附加
  Windows PATH
- `apt update && upgrade`
- 裝 baseline：**只有 `git` + `make`** —— 剛好夠 clone 組態管理 repo 並用它的 Makefile
  起手（連 `ansible` 都不裝，交給那個 repo 的 Makefile 自己補）
- 關掉 Ubuntu 26.04 遙測：寫 `~/.config/ubuntu-insights/*-consent.toml`
  （`consent_state = false`），首次啟動不跳互動式 metrics 提問
- 建立 `~/projects`

之後自動重啟 WSL 兩次（一次讓 systemd／預設 user 生效，一次讓你第一次進去是乾淨 session）。

## 設定（`config.ps1`）

| 選項 | 預設 | 控制 |
|---|---|---|
| `$Distro` | `dev` | WSL distro 名（`wsl -d <名>`） |
| `$UbuntuImage` | `Ubuntu-26.04` | 來源 image（`wsl --list --online`） |
| `$User` | `miskawu` | distro 內建立的登入 user |
| `$DeployWslConfig` | `$true` | 把 repo 的 `wslconfig` 部署到 `%USERPROFILE%\.wslconfig`（內容不同才動，覆蓋前備份） |
| `$UnregisterOld` / `$OldDistroName` | `$false` / — | 建置成功後詢問是否移除指定的舊 distro（需明確確認） |

軟體環境的一切（容器 runtime、Go 版本、Node/Python/clients、SSH keys）都在
`dev-env-ansible` 的 `group_vars`，不在這裡。

## 全域 `.wslconfig` 也由本 repo 管理

`wslconfig` 是 source of truth，`bootstrap.ps1` 會部署到 `%USERPROFILE%\.wslconfig`
（內容不同才寫，覆蓋前備份成 `.wslconfig.bak-<時間>`）。這樣全域設定才進版控 ——
2026-07 發現原本那份部署副本標的 source of truth 根本不存在，它是唯一一份，誤刪就沒了。

**政策：只用穩定設定，不碰 `[experimental]`。** 那個區段照定義就不穩定；寧可要一台無聊
但可靠的機器。（歷史：`autoMemoryReclaim` / `sparseVhd` 曾被誤放在 `[wsl2]`，WSL 直接
忽略並警告 unknown key，等於從未生效。）

改 `.wslconfig` 要 `wsl --shutdown` 才生效，且影響機器上**所有** WSL2 distro。

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
- bring-up 之後：clone 你的組態管理 repo + `make init`。收尾的手動步驟（把公鑰貼到
  GitHub、`claude` 首次 OAuth）由 `make init` 印清單提示；`make git-config` 設 git 身分。

## 授權

MIT
