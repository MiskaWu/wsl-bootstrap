# wsl-bootstrap

Config 驅動、無人值守的 WSL2 distro **bring-up** 工具 —— 只把 distro 帶到「可以交給
Ansible 接手」的狀態。

一份 config、一道指令，跑完走人。產出一個乾淨的 Ubuntu 26.04 WSL2 distro，內含 systemd、
你的 user、免密碼 sudo、baseline（`git`、`make`、`ansible-core`），並關掉 Ubuntu 遙測 ——
一台可連、可被組態管理的機器。

真正的開發環境（Podman、Go、Claude Code、toolchain）由另一個獨立 repo **dev-env-ansible**
負責，在機器上用 `make apply` 本機安裝。刻意拆成兩個 repo：那個 Ansible role 是
host-agnostic、任何 Linux 都能用，不該綁死在這支 WSL 專用的 bootstrap。

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

接著進 distro 裝開發環境：

```bash
wsl -d dev
git clone <dev-env-ansible repo> ~/projects/dev-env-ansible
cd ~/projects/dev-env-ansible
make check    # 預覽會裝什麼
make apply    # podman、go、claude、toolchain
```

驗證 bring-up：

```powershell
wsl -d dev -u miskawu -- bash -l < scripts/verify.sh
```

## bring-up 做了什麼（`scripts/provision.sh`，root 身分）

- 建立你的 user（`$User`）並給免密碼 `sudo`
- 寫 `/etc/wsl.conf`：開 systemd、`$User` 為預設登入、WSL 管理 `resolv.conf`、附加
  Windows PATH
- `apt update && upgrade`
- 裝 baseline：`git`、`make`、`ansible-core`、`python3` —— 讓機器能本機跑 Ansible role
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
| `$EnvRepo` | — | dev-env-ansible URL，收尾訊息會顯示 |
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

## 網路：預設 NAT，不用 mirrored

維持預設 WSL2 **NAT**。Windows 靠 `localhostForwarding`（預設開）就能用 `localhost:<port>`
連到 distro 內的服務 —— 包含 rootless Podman 容器 port —— 不用做 forward。刻意不用
mirrored 模式：截至 2026 它對 rootless Podman 仍有 open bug（port-forward timeout、
WSL 內 `127.0.0.1` 連不到），而且會關掉 `localhostForwarding`。若哪天需要別台 LAN 機器
連進 distro，用 Windows OpenSSH 的 ProxyJump 或 Tailscale，不是 mirrored。

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
- bring-up 之後：clone dev-env-ansible + `make apply`，然後 `claude`（首次 OAuth）與
  `git config --global user.name/email`。

## 授權

MIT
