
#Requires -Version 5.1
<#
.SYNOPSIS
  .env を取り込み、安全チェック → Register → Finalize を一括実行するオーケストレーター。
  PowerShell 5.1 / 7 互換。DryRun対応。色付きログ。Summary表示。拡張容易な構造。

.PARAMETER EnvPath
  .env のパス。既定はリポジトリ直下の .env

.PARAMETER Mode
  'Stable'（固定SHA再現） / 'Latest'（--remote）。既定は 'Stable'。

.PARAMETER DryRun
  実行を行わず計画のみ表示（.envのDRY_RUNを上書き可）。

.PARAMETER Summary
  結果サマリを表示。

.PARAMETER GitExe
  git 実行ファイルのパス（.envのGIT_EXEを上書き可）。

.PARAMETER Lock
  競合防止ロックを取る（既定: 有効）。

.NOTES
  - 保存は UTF-8 with BOM を推奨（PS 5.1での安定のため）。
  - 既存の Register-Submodules.ps1 / Finalize-Submodules.ps1 と同ディレクトリに置いてください。
#>

param(
    [string]$EnvPath = ".\.env",
    [ValidateSet('Stable','Latest')] [string]$Mode = 'Stable',
    [switch]$DryRun,
    [switch]$Summary,
    [string]$GitExe,
    [switch]$Lock = $true
)

# script-scoped Git command (決定後に設定)
$script:GitCmd = 'git'

# ---------------- Colors ----------------
function Write-Color {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('Black','DarkBlue','DarkGreen','DarkCyan','DarkRed','DarkMagenta','DarkYellow','Gray','DarkGray','Blue','Green','Cyan','Red','Magenta','Yellow','White')]
        [string]$ForegroundColor = 'Gray'
    )
    Write-Host $Message -ForegroundColor $ForegroundColor
}
function Info  ($m) { Write-Color $m 'Cyan'     }
function Ok    ($m) { Write-Color $m 'Green'    }
function Warn  ($m) { Write-Color $m 'Yellow'   }
function Err   ($m) { Write-Color $m 'Red'      }
function Dry   ($m) { Write-Color $m 'Magenta'  }

# ---------------- UTF-8 BOM writer (PS 5.1/7 安定化) ----------------
function Write-AllTextUtf8Bom {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Value
    )
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $enc  = New-Object System.Text.UTF8Encoding($true) # BOM=true
        [System.IO.File]::WriteAllText($full, $Value, $enc)
        return $true
    } catch {
        return $false
    }
}

# ---------------- Utilities ----------------
function Expand-EnvVars {
    param([Parameter(Mandatory=$true)][string]$Text)
    return [Environment]::ExpandEnvironmentVariables($Text)
}

function Parse-EnvFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $lines = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        $trim = $line.Trim()
        if ($trim.Length -eq 0 -or $trim.StartsWith('#')) { continue }
        $idx = $trim.IndexOf('=')
        if ($idx -lt 0) { continue }
        $key = $trim.Substring(0,$idx).Trim()
        $val = $trim.Substring($idx+1).Trim()
        # 値の両端の引用符除去（"..." or '...')
        if ($val.StartsWith('"') -and $val.EndsWith('"')) { $val = $val.Substring(1, $val.Length-2) }
        elseif ($val.StartsWith("'") -and $val.EndsWith("'")) { $val = $val.Substring(1, $val.Length-2) }
        # %VAR% 展開
        $val = Expand-EnvVars -Text $val
        $result[$key] = $val
    }
    return $result
}

function To-Bool {
    param([Parameter(Mandatory=$true)][string]$Text,[bool]$Default=$false)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Default }
    switch ($Text.ToLowerInvariant()) {
        'true'  { return $true }
        '1'     { return $true }
        'yes'   { return $true }
        'false' { return $false }
        '0'     { return $false }
        'no'    { return $false }
        default { return $Default }
    }
}

function Convert-BashDateFormatToDotNet {
    param([Parameter(Mandatory=$true)][string]$BashFmt)
    # 重複キーを避けるため、タプル配列で順次置換
    $pairs = @(
        @('%Y','yyyy'),
        @('%y','yy'),
        @('%m','MM'),
        @('%d','dd'),
        @('%H','HH'),
        @('%M','mm'),
        @('%S','ss'),
        @('%z','zzz'), # ±hh:mm
        @('%Z','zzz')  # Windows IDでは省略、近似でzzz
    )
    $dotnet = $BashFmt
    foreach ($p in $pairs) { $dotnet = $dotnet.Replace($p[0], $p[1]) }
    return $dotnet
}

# IANA → Windows タイムゾーンIDのマッピング
function Resolve-TimeZoneId {
    param([string]$InputId)
    if ([string]::IsNullOrWhiteSpace($InputId)) { return $null }

    # まずそのまま試す（環境によりIANAが通る場合がある）
    try {
        [void][System.TimeZoneInfo]::FindSystemTimeZoneById($InputId)
        return $InputId
    } catch {
        $ianaToWin = @{
            'UTC'                 = 'UTC'
            'Etc/UTC'             = 'UTC'
            'Asia/Tokyo'          = 'Tokyo Standard Time'
            'Asia/Seoul'          = 'Korea Standard Time'
            'Asia/Shanghai'       = 'China Standard Time'
            'America/Los_Angeles' = 'Pacific Standard Time'
            'America/New_York'    = 'Eastern Standard Time'
            'Europe/London'       = 'GMT Standard Time'
            'Europe/Paris'        = 'Romance Standard Time'
        }
        if ($ianaToWin.ContainsKey($InputId)) {
            return $ianaToWin[$InputId]
        } else {
            if ($InputId -match '^(Etc/)?UTC$') { return 'UTC' }
            return $null
        }
    }
}

function Get-Timestamp {
    param([string]$TimeZoneId,[string]$BashFmt='%Y-%m-%d %H:%M:%S')
    $fmt = Convert-BashDateFormatToDotNet -BashFmt $BashFmt
    try {
        if ([string]::IsNullOrWhiteSpace($TimeZoneId)) {
            return (Get-Date).ToString($fmt)
        }
        $resolved = Resolve-TimeZoneId -InputId $TimeZoneId
        if ($null -eq $resolved) {
            Warn ("Invalid TIMEZONE '{0}', fallback to local." -f $TimeZoneId)
            return (Get-Date).ToString($fmt)
        }
        $tz   = [System.TimeZoneInfo]::FindSystemTimeZoneById($resolved)
        $utc  = [DateTime]::UtcNow
        $local= [System.TimeZoneInfo]::ConvertTimeFromUtc($utc, $tz)
        return $local.ToString($fmt)
    } catch {
        Warn ("Invalid TIMEZONE '{0}', fallback to local." -f $TimeZoneId)
        return (Get-Date).ToString($fmt)
    }
}

function Test-GitAvailable {
    param([string]$GitExeCandidate)
    try {
        & $GitExeCandidate --version | Out-Null
        return $true
    } catch { return $false }
}

function Test-InGitRepo {
    try { & $script:GitCmd rev-parse --git-dir 2>$null | Out-Null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}

function Get-SubmodulePathsFromGitmodules {
    $keys = & $script:GitCmd config --file .gitmodules --name-only --get-regexp "submodule\..*\.path" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $keys) { return @() }
    $paths = @()
    foreach ($k in $keys) {
        $name = $k -replace '^submodule\.', '' -replace '\.path$', ''
        $p = & $script:GitCmd config --file .gitmodules ("submodule.{0}.path" -f $name) 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($p)) { $paths += $p }
    }
    return $paths
}

# ---------------- Lock (競合防止) ----------------

# ---------------- Lock (競合防止) — .NETのみで安全に作成/削除 ----------------
function Acquire-Lock {
    param([string]$LockPath)
    if (-not $Lock) {
        Warn "[Lock] Disabled by -Lock:$false. Skipping lock acquisition."
        return $true
    }

    try {
        # 1) 参照パスを絶対パス化
        $fullLock = [System.IO.Path]::GetFullPath($LockPath)
        $dir      = [System.IO.Path]::GetDirectoryName($fullLock)
        Info ("[Lock] Target: {0}" -f $fullLock)
        Info ("[Lock] Dir   : {0}" -f $dir)

        # 2) 親ディレクトリを作成（既存でもOK）
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
        if (-not [System.IO.Directory]::Exists($dir)) {
            Warn ("[Lock] Directory could not be created: {0}" -f $dir)
            return $false
        }

        # 3) 既存ロックの確認
        if ([System.IO.File]::Exists($fullLock)) {
            Warn ("[Lock] Already exists: {0} (another run or stale lock)" -f $fullLock)
            return $false
        }

        # 4) CreateNew + FileShare.None で排他作成
        $fs = New-Object System.IO.FileStream(
            $fullLock,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )

        # 5) UTF-8 BOM で内容を書き込み
        $enc   = New-Object System.Text.UTF8Encoding($true)  # BOM=true
        $bytes = $enc.GetBytes(("{0} {1}" -f (Get-Date), $env:COMPUTERNAME))
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush()
        $fs.Dispose()

        Ok "[Lock] Acquired."
        return $true
    }
    catch {
        Err ("[Lock] Acquire failed: {0}" -f $_.Exception.Message)
        # 追加で例外の型とスタックの先頭をヒント表示
        Warn ("[Lock] ExceptionType: {0}" -f $_.Exception.GetType().FullName)
        if ($_.Exception.InnerException) {
            Warn ("[Lock] Inner: {0}" -f $_.Exception.InnerException.Message)
        }
        return $false
    }
}

function Release-Lock {
    param([string]$LockPath)
    if (-not $Lock) { return }

    try {
        $fullLock = [System.IO.Path]::GetFullPath($LockPath)
        if ([System.IO.File]::Exists($fullLock)) {
            [System.IO.File]::Delete($fullLock)
            Ok ("[Lock] Released: {0}" -f $fullLock)
        } else {
            Info ("[Lock] No lock to release at: {0}" -f $fullLock)
        }
    }
    catch {
        Warn ("[Lock] Release failed: {0}" -f $_.Exception.Message)
    }
}

# ---------------- Orchestration ----------------
function Run-Register {
    param([string]$GitExeUse,[switch]$Dry,[switch]$SummaryUse)
    $args = @(
        ".\.script\__DoNotTouch\Register-Submodules.ps1",
        '-GitExe', $GitExeUse
    )
    if ($Dry)        { $args += @('-DryRun') }
    if ($SummaryUse) { $args += @('-Summary') }

    Info ("[Register] Launch: {0}" -f ($args -join ' '))
    & powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File @args
}

function Run-Finalize {
    param([string]$GitExeUse,[switch]$Dry,[switch]$SummaryUse,[switch]$RemoteUse,[string]$MessageUse)
    $args = @(
        ".\.script\__DoNotTouch\Finalize-Submodules.ps1",
        '-GitExe', $GitExeUse,
        '-Message', $MessageUse
    )
    if ($Dry)        { $args += @('-DryRun') }
    if ($SummaryUse) { $args += @('-Summary') }
    if ($RemoteUse)  { $args += @('-Remote') }

    Info ("[Finalize] Launch: {0}" -f ($args -join ' '))
    & powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File @args
}

function Safety-Precheck {
    # 基本前提チェック
    if (-not (Test-InGitRepo)) { throw "Not a Git repository. Please run in repo root." }
    if (-not (Test-Path -LiteralPath ".gitmodules")) { throw ".gitmodules not found." }

    $paths = Get-SubmodulePathsFromGitmodules
    if (-not $paths -or $paths.Count -eq 0) { throw "No submodule path keys found in .gitmodules" }

    # 目視用ダイジェスト（DryRun時も出す）
    Write-Host ""
    Info "[Safety check]"
    Info ("  Submodules defined: {0}" -f $paths.Count)

    $nonEmpty = @()
    $missing  = @()
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) {
            $items = Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue
            if ($items -and $items.Count -gt 0) { $nonEmpty += $p } else { $missing += $p }
        } else {
            $missing += $p
        }
    }
    if ($nonEmpty.Count -gt 0) { Warn ("  Non-empty paths: {0}" -f ($nonEmpty -join ", ")) }
    if ($missing.Count  -gt 0) { Warn ("  Missing paths:   {0}" -f ($missing  -join ", ")) }

    # 任意：Rドライブ存在確認（ICS標準）
    if (Test-Path -LiteralPath "R:\") {
        Info "  R: drive detected."
    } else {
        Warn "  R: drive not found (UNC禁止方針なら要確認)。"
    }
}

# ---------------- Summary ----------------
function Show-SetupSummary {
    param([hashtable]$Env,[string]$GitExeUse,[string]$Message,[string]$ModeUse,[bool]$DryUse)
    Write-Host ""
    Info "[Setup Summary]"
    Info ("  Mode:     {0}" -f $ModeUse)
    Info ("  DryRun:   {0}" -f $DryUse)
    Info ("  GitExe:   {0}" -f $GitExeUse)
    if ($Env.ContainsKey('USER_ID')) { Info ("  UserID:   {0}" -f $Env['USER_ID']) }
    Info ("  Message:  {0}" -f $Message)
}

# ---------------- main ----------------
function Main {
    Info "Setup submodules (env + safety + register + finalize) [PS 5.1/7 compatible]"

    # 1) .env 読込
    $envVals = Parse-EnvFile -Path $EnvPath

    # 2) GitExe 決定
    $gitFromEnv = $null
    if ($envVals.ContainsKey('GIT_EXE')) { $gitFromEnv = $envVals['GIT_EXE'] }

    $gitUse = 'git'
    if (-not [string]::IsNullOrWhiteSpace($GitExe)) {
        $gitUse = $GitExe
    } elseif (-not [string]::IsNullOrWhiteSpace($gitFromEnv)) {
        $gitUse = $gitFromEnv
    }

    if (-not (Test-GitAvailable -GitExeCandidate $gitUse)) {
        throw ("git not available: {0}" -f $gitUse)
    }

    # script-scoped GitCmd を確定
    $script:GitCmd = $gitUse

    # 3) DryRun 決定（CLI優先、なければ .env の DRY_RUN、既定 false）
    $dryFromEnv = $false
    if ($envVals.ContainsKey('DRY_RUN')) { $dryFromEnv = To-Bool -Text $envVals['DRY_RUN'] -Default:$false }

    $dryUse = $dryFromEnv
    if ($DryRun) { $dryUse = $true }

    # 4) コミットメッセージ生成（prefix + timestamp）
    $prefix = 'Setup Submodules'
    if ($envVals.ContainsKey('COMMIT_MESSAGE_PREFIX') -and -not [string]::IsNullOrWhiteSpace($envVals['COMMIT_MESSAGE_PREFIX'])) {
        $prefix = $envVals['COMMIT_MESSAGE_PREFIX']
    }

    $bashFmt = '%Y-%m-%d %H:%M:%S'
    if ($envVals.ContainsKey('DATE_FORMAT') -and -not [string]::IsNullOrWhiteSpace($envVals['DATE_FORMAT'])) {
        $bashFmt = $envVals['DATE_FORMAT']
    }

    $tzId = $null
    if ($envVals.ContainsKey('TIMEZONE') -and -not [string]::IsNullOrWhiteSpace($envVals['TIMEZONE'])) {
        $tzId = $envVals['TIMEZONE']
    }

    $stamp = Get-Timestamp -TimeZoneId $tzId -BashFmt $bashFmt
    $message = "{0} - {1}" -f $prefix, $stamp

    # 5) 安全チェック
    Safety-Precheck

    # 6) 競合防止ロック
    $lockPath = ".\.script\__DoNotTouch\.setup_submodules.lock"
    if (-not (Acquire-Lock -LockPath $lockPath)) { throw "Lock acquisition failed." }

    try {
        # 7) Register（DryRun伝播）
        Run-Register -GitExeUse $gitUse -Dry:$dryUse -SummaryUse:$Summary

        # 8) Finalize（Modeにより Remote 切替）
        $useRemote = $false
        if ($Mode -eq 'Latest') { $useRemote = $true }

        Run-Finalize -GitExeUse $gitUse -Dry:$dryUse -SummaryUse:$Summary -RemoteUse:$useRemote -MessageUse $message

        # 9) Setupサマリ
        Show-SetupSummary -Env $envVals -GitExeUse $gitUse -Message $message -ModeUse $Mode -DryUse:$dryUse

        # 10) 次推奨（push）
        Write-Host ""
        Info "Recommended next: git push"
    }
    finally {
        Release-Lock -LockPath $lockPath
    }
}

try {
    Main
}
catch {
    Err ("[Error] {0}" -f $_.Exception.Message)
    exit 1
}
