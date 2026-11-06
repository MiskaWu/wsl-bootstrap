# =============================================================================
# wsl-bootstrap :: bootstrap.ps1
# -----------------------------------------------------------------------------
# 無人值守建立一個乾淨的 WSL2 開發 distro，或對現有 distro 收斂（-Update）。
# 設定全部從 config.ps1 讀（複製自 config.example.ps1）。
#
#   cp config.example.ps1 config.ps1   # 首次
#   notepad config.ps1                 # 改設定
#
#   .\bootstrap.ps1           # 聰明預設：distro 不存在→問你要不要建；已存在→更新（先看 diff）
#   .\bootstrap.ps1 -Yes      # 跳過所有確認 = 無人值守（不存在就建、存在就套用）
#   .\bootstrap.ps1 -WhatIf   # 已存在時只看 diff、不問不改（純預覽）
#   .\bootstrap.ps1 -Upgrade  # 更新時連 apt upgrade（預設跳過）
# -Update 為顯式要求更新（對不存在的 distro 會報錯）；平常直接 .\bootstrap.ps1 即可。
#
# 前置需求: Windows 11 (24H2+) 或含 --name 的 WSL 版本、已啟用 WSL2。
# =============================================================================
[CmdletBinding()]
param(
    # 預設值刻意留空，在下面本體才解析。
    # 不能寫成 "$PSScriptRoot\config.ps1"：以 `-File` 呼叫時，param 預設值求值的當下
    # $PSScriptRoot 還是空的，會算出 '\config.ps1'（當前磁碟機根目錄）然後找不到檔案。
    # 在 PS session 裡 .\bootstrap.ps1 或用 & 呼叫時反而正常——所以這個 bug 只在
    # `-File` 模式浮現，也就是 README 教的 ExecutionPolicy 繞道那條路。
    [string]$ConfigPath,

    [switch]$Update,    # 顯式要求更新（對不存在的 distro 會報錯）；平常不必帶，no-arg 自動判斷
    [switch]$WhatIf,    # 只預覽 diff、不問不改（僅在 distro 已存在時有意義）
    [switch]$Yes,       # 跳過所有互動確認 = 無人值守（不存在就建、存在就套用）
    [switch]$Upgrade    # 更新時連 apt upgrade（預設跳過）
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

# --- 用 config 的 BS_* 環境變數跑 provision（fresh 與 update 共用）----------
# 未定義的 config 變數在 StrictMode-off 下是 $null → [string]$null = ''，provision 會略過
# 對應步驟，所以舊的 config.ps1（沒有 git/ssh 設定）也不會壞。
# -DryRun → BS_DRY_RUN=1（provision 只預覽 diff 不動機器）。
# update 模式預設 BS_SKIP_UPGRADE=1（跳過 apt upgrade），除非帶 -Upgrade。
function Invoke-Provision {
    param([switch]$DryRun, [switch]$SkipUpgrade, [string]$Label = 'provision')
    Invoke-Wsl -Script (Get-Script 'provision.sh') -AsUser 'root' -Label $Label -EnvVars @{
        BS_USER            = $User
        BS_GIT_NAME        = $GitName
        BS_GIT_EMAIL       = $GitEmail
        BS_SSH_KEY_TAG     = $SshKeyTag
        BS_SSH_KEY_COMMENT = $SshKeyComment
        BS_SSH_KEY_SCOPES  = ($SshKeyScopes -join ' ')
        BS_DRY_RUN         = $(if ($DryRun) { '1' } else { '' })
        BS_SKIP_UPGRADE    = $(if ($SkipUpgrade) { '1' } else { '' })
    }
}

# --- 部署 / 預覽 .wslconfig（全域設定，影響機器上所有 distro）---------------
# repo 裡的 `wslconfig` 是 source of truth。這樣設定才進版控——2026-07 發現原本標的
# source of truth 根本不存在，部署副本是唯一一份，誤刪就沒了。覆蓋前備份，不弄丟手改內容。
# 改動要 wsl --shutdown 才生效。用 .NET WriteAllText + 無 BOM UTF8：PS 5.1 的
# Set-Content -Encoding UTF8 會帶 BOM，而這個檔是給 WSL 自己解析的，別冒 BOM 的險。
function Sync-WslConfig {
    param([switch]$Preview)
    if (-not $DeployWslConfig) { return }
    $srcCfg = Join-Path $PSScriptRoot 'wslconfig'
    $dstCfg = Join-Path $env:USERPROFILE '.wslconfig'
    if (-not (Test-Path $srcCfg)) { Die "缺少 $srcCfg" }
    $newCfg = Get-Content $srcCfg -Raw -Encoding UTF8
    $oldCfg = if (Test-Path $dstCfg) { Get-Content $dstCfg -Raw -Encoding UTF8 } else { '' }
    if ($Preview) {
        if ($oldCfg -eq $newCfg) { Info ".wslconfig：無變更" }
        else {
            Warn ".wslconfig：會變更（$dstCfg）—— 套用後需 wsl --shutdown 才生效"
            Compare-Object (($oldCfg -replace "`r","") -split "`n") (($newCfg -replace "`r","") -split "`n") |
                ForEach-Object {
                    $s = if ($_.SideIndicator -eq '=>') { '+' } else { '-' }
                    Write-Host "    $s $($_.InputObject)"
                }
        }
        return
    }
    if ($oldCfg -ne $newCfg) {
        if ($oldCfg -ne '') {
            $bak = "$dstCfg.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item $dstCfg $bak
            Warn "既有 .wslconfig 與 repo 版本不同，已備份到 $bak"
        }
        [System.IO.File]::WriteAllText($dstCfg, $newCfg, [System.Text.UTF8Encoding]::new($false))
        Info "已部署 .wslconfig → $dstCfg"
    } else {
        Info ".wslconfig 已與 repo 一致，略過"
    }
}

# ===========================================================================
# 模式分派：直接跑 .\bootstrap.ps1 就會「自己問」——不必記旗標。
#   distro 已存在 → 更新（先看 diff，再問要不要套用）
#   distro 不存在 → 問要不要從零建立
# 旗標只是捷徑：-Yes 跳過所有確認（無人值守）、-WhatIf 只看 diff、-Update 顯式要求更新
# （對不存在的 distro 會報錯，避免打錯字誤建）。
# ===========================================================================
if ($Update -and ($existing -notcontains $Distro)) {
    Die "distro '$Distro' 不存在 —— -Update 是對現有 distro 用的。要新建就直接 .\bootstrap.ps1（不帶 -Update）。"
}

# ---- 更新模式（偵測到已存在，或 -Update）：diff → 問 → 套用 ------------------
if ($existing -contains $Distro) {
    if (-not $Update) { Info "偵測到 distro '$Distro' 已存在 → 更新模式（先給你看 diff）。" }
    Info "=== 預覽（不動機器）：'$Distro' 會有哪些變更 ==="
    Sync-WslConfig -Preview
    Invoke-Provision -DryRun -SkipUpgrade:(-not $Upgrade) -Label 'update-preview'

    if ($WhatIf) { Info "（-WhatIf：僅預覽，未做任何變更。）"; exit 0 }

    if (-not $Yes) {
        Write-Host ""
        $ans = Read-Host "[bootstrap] 套用以上變更到 '$Distro'？(y=套用 / 其他=取消)"
        if ($ans -notmatch '^(y|yes)$') { Info "已取消，未做任何變更。"; exit 0 }
    }

    Info "=== 套用 ==="
    Sync-WslConfig
    Invoke-Provision -SkipUpgrade:(-not $Upgrade) -Label 'update'
    Info "Update 完成。若上面顯示 wsl.conf / .wslconfig 有變更，需 `wsl --shutdown` 才生效"
    Info "（其他多數改動即時生效，不影響你現有的 key / 資料 / 已 clone 的東西）。"
    exit 0
}

# ===========================================================================
# 建立模式（distro 不存在）：問要不要從零建（-Yes 跳過確認即無人值守）
# ===========================================================================
if ($WhatIf) {
    Die "-WhatIf 要 distro 已存在才能 diff；'$Distro' 還不存在。要建立就直接 .\bootstrap.ps1。"
}
if (-not $Yes) {
    Write-Host ""
    $ans = Read-Host "[bootstrap] distro '$Distro' 不存在，要用 image '$UbuntuImage' 從零建立嗎？(y=建立 / 其他=取消)"
    if ($ans -notmatch '^(y|yes)$') { Info "已取消，未建立。"; exit 0 }
}

Sync-WslConfig

# --- Phase 0: 建 distro ----------------------------------------------------
Info "Phase 0 — 安裝 $UbuntuImage 為 '$Distro'"
wsl.exe --install -d $UbuntuImage --name $Distro --no-launch
if ($LASTEXITCODE -ne 0) {
    Warn "--name 可能不被此 WSL 版本支援。"
    Die  "請升級 WSL (`wsl --update`) 或改用 `wsl --import` 手動建 distro。"
}

# --- Provision: 系統 + user + wsl.conf + baseline + git/keys + OOBE --------
# 軟體工作環境（container runtime / 語言 / toolchain）不在這裡——用你的組態管理另外裝
# （clone repo → make init；Makefile 會自己補 ansible）。bootstrap 不綁特定 repo。
Invoke-Provision -Label 'provision'

Info "wsl --shutdown（讓 systemd / 預設 user 生效）"
wsl.exe --shutdown
Start-Sleep -Seconds 3

# --- 收尾 terminate：讓第一次進入是乾淨 session ----------------------------
# 第一次啟動時 systemd 的 user session 可能短暫 cold-start race（is-system-running
# 一瞬間 degraded），terminate 重進即恢復。先 terminate 一次，使用者第一次 wsl -d
# 進去就是乾淨的。
Info "wsl --terminate $Distro（收尾，確保第一次進入是乾淨 session）"
wsl.exe --terminate $Distro
Start-Sleep -Seconds 2

# --- 舊 distro 清理（可選，需明確確認）------------------------------------
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

# --- 收尾訊息 --------------------------------------------------------------
Info "Bring-up 完成！distro '$Distro' 已就緒："
Info "  systemd + 預設 user + 免密碼 sudo + baseline（git + make + openssh-client）"
Info "  + git 身分 + SSH keys + Ubuntu 遙測 opt-out —— 裝完就 git-ready。"
Info ""
Info "SSH 公鑰已在上方 provision log 印出；要再看："
Info "  wsl -d $Distro -- bash -lc 'cat ~/.ssh/id_ed25519_*.pub'"
Info "貼到 GitHub / GitLab 後，就能直接 clone 私有 repo。"
Info ""
Info "軟體工作環境（container runtime / 語言 / toolchain）用你的組態管理另外裝"
Info "（clone repo → make init；Makefile 會自己補 ansible）。bootstrap 不綁特定 repo。"
Info ""
Info "日後要更新這台： 直接 .\bootstrap.ps1（偵測到已存在會自動進更新、先給你看 diff）"
Info "第一次進入： wsl -d $Distro"
