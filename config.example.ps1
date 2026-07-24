# =============================================================================
# wsl-bootstrap config
# -----------------------------------------------------------------------------
# 複製這份成 config.ps1 再改。config.ps1 已被 .gitignore 忽略。
#   cp config.example.ps1 config.ps1
#   notepad config.ps1        # 改成你要的
#   .\bootstrap.ps1           # 無人值守跑完
#
# 這支只負責 **bring-up**：distro + user + systemd + baseline(git/make/ansible)
# + OOBE opt-out。軟體工作環境（container runtime / 語言 / toolchain）不在這裡——
# 用你的組態管理另外裝（例如 Ansible，在 distro 內執行）。bootstrap 不綁特定 repo。
# =============================================================================

# ---- Distro ----------------------------------------------------------------
$Distro      = 'dev'            # distro 名（wsl -d <名>）
# Ubuntu-26.04 (Resolute Raccoon) 帶 podman 5.7；wsl --list --online 可查 image 名稱。
$UbuntuImage = 'Ubuntu-26.04'
$User        = 'miskawu'        # distro 內登入 user（建議對齊 Windows 帳號）

# ---- .wslconfig（全域 WSL2 設定）-------------------------------------------
# $true 會把 repo 裡的 `wslconfig` 部署到 %USERPROFILE%\.wslconfig（覆蓋前備份）。
# 這是讓全域設定進版控、不會誤刪就消失的方式。內容與理由見該檔案。
# 注意：它影響機器上**所有** WSL2 distro，且要 wsl --shutdown 才生效。
$DeployWslConfig = $true

# ---- git 身分（bring-up 直接寫進 user 的 ~/.gitconfig）----------------------
# 裝完就能直接 commit。兩個都留空則略過。
$GitName  = 'Your Name'
$GitEmail = 'you@example.com'

# ---- SSH keys（bring-up 直接生成，裝完就能貼 GitHub/GitLab、clone 私有 repo）-
# 每個 scope 一把 ed25519（無 passphrase）：~/.ssh/id_ed25519_<Tag>_<scope>。
# 生成後 bootstrap 會把公鑰印出來。$SshKeyScopes 設 @() 則不產 key。
$SshKeyTag     = 'dev'                    # 檔名前綴
$SshKeyComment = 'you@host'               # 註解基底（會接上 -<scope> 與生成日期）
$SshKeyScopes  = @('github', 'gitlab')    # 要為哪些平台各產一把

# ---- 舊 distro 清理（謹慎！） ----------------------------------------------
# $true 會在成功建好新 distro 後，詢問是否 unregister 指定的舊 distro。
$UnregisterOld = $false
$OldDistroName = ''         # 例如 'Ubuntu-24.04'
