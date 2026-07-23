# =============================================================================
# wsl-bootstrap config
# -----------------------------------------------------------------------------
# 複製這份成 config.ps1 再改。config.ps1 已被 .gitignore 忽略。
#   cp config.example.ps1 config.ps1
#   notepad config.ps1        # 改成你要的
#   .\bootstrap.ps1           # 無人值守跑完
#
# 這支只負責 **bring-up**：distro + user + systemd + baseline(git/make/ansible)
# + OOBE opt-out。軟體工作環境（podman / go / claude / toolchain）由獨立的
# dev-env-ansible repo 裝（在 distro 內 make apply），設定在那邊的 group_vars。
# =============================================================================

# ---- Distro ----------------------------------------------------------------
$Distro      = 'dev'            # distro 名（wsl -d <名>）
# Ubuntu-26.04 (Resolute Raccoon) 帶 podman 5.7；wsl --list --online 可查 image 名稱。
$UbuntuImage = 'Ubuntu-26.04'
$User        = 'miskawu'        # distro 內登入 user（建議對齊 Windows 帳號）

# ---- 工作環境 repo ---------------------------------------------------------
# 只用在收尾訊息，提示你 clone 哪個 repo 去 make apply。pin 版本就把 URL 換成帶
# tag/branch 的 clone（見 dev-env-ansible README）。不用 submodule。
$EnvRepo     = 'git@github.com:MiskaWu/dev-env-ansible.git'

# ---- 舊 distro 清理（謹慎！） ----------------------------------------------
# $true 會在成功建好新 distro 後，詢問是否 unregister 指定的舊 distro。
$UnregisterOld = $false
$OldDistroName = ''         # 例如 'Ubuntu-24.04'
