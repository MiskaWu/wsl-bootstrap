# =============================================================================
# wsl-bootstrap config
# -----------------------------------------------------------------------------
# 複製這份成 config.ps1 再改。config.ps1 已被 .gitignore 忽略，
# 不會 commit 進 repo（裡面有你的 username / SSH scope 等個人資訊）。
#
#   cp config.example.ps1 config.ps1
#   notepad config.ps1        # 改成你要的
#   .\bootstrap.ps1           # 無人值守跑完
# =============================================================================

# ---- Distro ----------------------------------------------------------------
$Distro      = 'dev-2026'
# Ubuntu-26.04 (Resolute Raccoon, 2026-04 GA) 帶 podman 5.7；24.04 凍在 podman
# 4.9.3 直到 2029。wsl --list --online 可查可用 image 名稱。
$UbuntuImage = 'Ubuntu-26.04'
$User        = 'miska'

# ---- Container runtime -----------------------------------------------------
# 'podman' (預設，rootless，對齊 k3s) 或 'docker' (Docker Engine)
$Runtime     = 'podman'
# 裝 docker-compose 二進位 + DOCKER_HOST shim，讓現有的 docker-compose.yml
# 一個字都不用改就能跑在 Podman socket 上。Runtime=docker 時此項忽略。
$ComposeShim = $true

# ---- Go (寫死必裝，只讓你選版本) -------------------------------------------
# 'latest' = 自動查 go.dev 最新版；或 pin 具體版本如 '1.23.4' 對齊 acme
$GoVersion   = 'latest'

# ---- 可選 toolchain --------------------------------------------------------
$InstallNode        = $false     # acme-gm 你可能只在該專案裝
$NodeVersion        = 'lts'      # nvm 認得的版本字串: 'lts' / '20' / '22.11.0'

$InstallPython      = $true      # 裝 uv (快、少驚喜)
$InstallClientTools = $true      # psql, redis-cli, nats CLI

# ---- SSH key ---------------------------------------------------------------
$GenerateSSHKey = $true
# 每個 scope 產一把 id_ed25519_dev2026_<scope>
$SSHKeyScopes   = @('github', 'gitlab', 'homelab')
$SSHKeyComment  = 'miska@dev-2026'

# ---- 舊 distro 清理（謹慎！） ----------------------------------------------
# $true 會在成功建好 dev-2026 後，詢問是否 unregister 指定的舊 distro。
# 預設 $false —— 你說「保留一個月當 rollback」，所以先不動舊的。
$UnregisterOld      = $false
$OldDistroName      = ''         # 例如 'Ubuntu' 或 'Ubuntu-22.04'
