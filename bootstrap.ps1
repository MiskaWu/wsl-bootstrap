# =============================================================================
# wsl-bootstrap :: bootstrap.ps1
# -----------------------------------------------------------------------------
# 無人值守建立一個乾淨的 WSL2 開發 distro。
# 設定全部從 config.ps1 讀（複製自 config.example.ps1）。
#
#   cp config.example.ps1 config.ps1   # 首次
#   notepad config.ps1                 # 改設定
#   .\bootstrap.ps1                    # 跑（中途自動 shutdown，不需值守）
#
# 前置需求: Windows 11 (24H2+) 或含 --name 的 WSL 版本、已啟用 WSL2。
# =============================================================================
[CmdletBinding()]
param(
    # 預設值刻意留空，在下面本體才解析。
    # 不能寫成 "$PSScriptRoot\config.ps1"：以 `-File` 呼叫時，param 預設值求值的當下
    # $PSScriptRoot 還是空的，會算出 '\config.ps1'（當前磁碟機根目錄）然後找不到檔案。
    # 在 PS session 裡 .\bootstrap.ps1 或用 & 呼叫時反而正常——所以這個 bug 只在
    # `-File` 模式浮現，也就是 README/HANDOFF 教的 ExecutionPolicy 繞道那條路。
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

# PS 5.1 的 $OutputEncoding 預設是 US-ASCII，會把 pipe 進 wsl.exe 的腳本裡每個
# 非 ASCII 字元（log 訊息、註解裡的中文）都轉成 '?'。不改的話 phase log 全是問號，
# 出錯時無從讀起。
# 必須用 UTF8Encoding($false)——[Text.Encoding]::UTF8 會帶 BOM，bash 讀到開頭的
# \xEF\xBB\xBF 會直接噴錯。
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Info($m) { Write-Host "[bootstrap] $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "[bootstrap] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[bootstrap] $m" -ForegroundColor Red; exit 1 }

# --- 讀 config -------------------------------------------------------------
# $PSScriptRoot 在本體是可靠的（param 預設值裡才不是），所以在這裡才組路徑。
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.ps1' }
if (-not (Test-Path $ConfigPath)) {
    Die "找不到 $ConfigPath —— 先 `cp config.example.ps1 config.ps1` 再改設定。"
}
. $ConfigPath
Info "已載入設定: $ConfigPath"

# --- 前置檢查 --------------------------------------------------------------
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Die "找不到 wsl.exe —— 請先安裝 WSL。"
}

$existing = (wsl.exe --list --quiet) -replace "`0","" | ForEach-Object { $_.Trim() }
if ($existing -contains $Distro) {
    Die "distro '$Distro' 已存在。若要重建請先 `wsl --unregister $Distro`（會刪光內容！）。"
}

# --- 把 bash 腳本讀進來，之後 pipe 進 wsl（避開 PS heredoc 引號地獄）------
$scriptDir = Join-Path $PSScriptRoot 'scripts'
function Get-Script($name) {
    $p = Join-Path $scriptDir $name
    if (-not (Test-Path $p)) { Die "缺少腳本: $p" }
    # 轉 LF，避免檔案內部的 CRLF 讓 bash 爆 '\r' 錯誤。
    # 注意：這只處理檔案內部——pipe 結尾還會被 PS 補一個 CR，見 Invoke-Wsl。
    # -Encoding UTF8：PS 5.1 對無 BOM 的檔案預設用系統 ANSI codepage（繁中機器是
    # CP950）解讀，會把 .sh 裡的中文註解/訊息解成亂碼再送進 bash。
    (Get-Content $p -Raw -Encoding UTF8) -replace "`r`n","`n"
}

# --- 在 distro 內以指定身分跑一段 bash --------------------------------------
function Invoke-Wsl {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$AsUser,
        [hashtable]$EnvVars = @{},
        [string]$Label = 'phase'
    )
    # 把 env 前綴進 bash（值以單引號包住，內部單引號做 escape）
    $prefix = ""
    foreach ($k in $EnvVars.Keys) {
        $v = [string]$EnvVars[$k]
        $v = $v -replace "'","'\''"
        $prefix += "export $k='$v'; "
    }
    # PowerShell 把字串 pipe 給原生指令時，一定會在結尾補上 Windows 換行 "`r`n"。
    # 那個 CR 會單獨成為最後一行，bash 當成指令執行 → `$'\r': command not found`
    # → exit 127，於是整個 phase 明明做完了卻被判定失敗。
    # 結尾補一行註解，讓那個必然出現的 CR 落在 '#' 後面被 bash 忽略。
    # （不要改用 $Script + "`n"：那樣 CR 會自己佔一行，同樣會爆。）
    $full = $prefix + "`n" + $Script + "`n# EOF"
    Info "執行 $Label (user=$AsUser)"
    $full | wsl.exe -d $Distro -u $AsUser bash -s
    if ($LASTEXITCODE -ne 0) { Die "$Label 失敗 (exit $LASTEXITCODE)" }
}

# ===========================================================================
# Phase 0: 建 distro
# ===========================================================================
Info "Phase 0 — 安裝 $UbuntuImage 為 '$Distro'"
wsl.exe --install -d $UbuntuImage --name $Distro --no-launch
if ($LASTEXITCODE -ne 0) {
    Warn "--name 可能不被此 WSL 版本支援。"
    Die  "請升級 WSL (`wsl --update`) 或改用 `wsl --import` 手動建 distro。"
}

# ===========================================================================
# Phase 1: 系統 + user + wsl.conf → shutdown
# ===========================================================================
Invoke-Wsl -Script (Get-Script 'phase1-system.sh') -AsUser 'root' -Label 'phase1-system' `
    -EnvVars @{ BS_USER = $User }

Info "wsl --shutdown（讓 systemd / default user 生效）"
wsl.exe --shutdown
Start-Sleep -Seconds 3

# ===========================================================================
# Phase 2: runtime + baseline → terminate（讓 docker group 生效）
# ===========================================================================
Invoke-Wsl -Script (Get-Script 'phase2-runtime.sh') -AsUser 'root' -Label 'phase2-runtime' `
    -EnvVars @{
        BS_USER         = $User
        BS_RUNTIME      = $Runtime
        BS_COMPOSE_SHIM = ([string]$ComposeShim).ToLower()
    }

Info "wsl --terminate $Distro（讓 group 變更生效）"
wsl.exe --terminate $Distro
Start-Sleep -Seconds 2

# ===========================================================================
# Phase 3: user-level toolchain
# ===========================================================================
$sshScopes = ($SSHKeyScopes -join ',')
Invoke-Wsl -Script (Get-Script 'phase3-user.sh') -AsUser $User -Label 'phase3-user' `
    -EnvVars @{
        BS_RUNTIME        = $Runtime
        BS_COMPOSE_SHIM   = ([string]$ComposeShim).ToLower()
        BS_GO_VERSION     = $GoVersion
        BS_INSTALL_NODE   = ([string]$InstallNode).ToLower()
        BS_NODE_VERSION   = $NodeVersion
        BS_INSTALL_PYTHON = ([string]$InstallPython).ToLower()
        BS_INSTALL_CLIENTS= ([string]$InstallClientTools).ToLower()
        BS_GEN_SSH        = ([string]$GenerateSSHKey).ToLower()
        BS_SSH_SCOPES     = $sshScopes
        BS_SSH_COMMENT    = $SSHKeyComment
    }

# ===========================================================================
# 收尾 terminate：讓使用者第一次進去是乾淨的 session
# ---------------------------------------------------------------------------
# phase3 跑完的當下，user@1000.service 常處在 failed 狀態（`systemctl --user`
# 連不上、podman.socket 沒在跑、is-system-running 是 degraded）——phase3 過程中
# 反覆以 root/user 身分開關 session 會撞出 systemd 的 race。
# 這不是 phase3 沒做好：podman.socket 在 phase3 當下確實 enable 成功了（journal
# 看得到 "Listening on podman.socket"），是之後 user manager 才崩。
# 一次 terminate 就全部恢復（實測 running / active / socket 存在）。不做的話，
# 使用者照 HANDOFF §6 馬上驗證會看到一片失敗，卻其實只是需要重啟。
# ===========================================================================
Info "wsl --terminate $Distro（收尾，確保第一次進入是乾淨 session）"
wsl.exe --terminate $Distro
Start-Sleep -Seconds 2

# ===========================================================================
# 舊 distro 清理（可選，需明確確認）
# ===========================================================================
if ($UnregisterOld -and $OldDistroName) {
    Warn "準備 unregister 舊 distro: $OldDistroName（無法復原！）"
    $ans = Read-Host "輸入舊 distro 名稱以確認刪除，其他任意鍵取消"
    if ($ans -eq $OldDistroName) {
        wsl.exe --unregister $OldDistroName
        Info "已刪除 $OldDistroName"
    } else {
        Info "略過舊 distro 刪除"
    }
}

Info "完成！ 進入環境:  wsl -d $Distro"
Info "接著跑 phase3 印出的『手動收尾清單』。"
