
#Requires -Version 5.1
<#
.SYNOPSIS
  サブモジュールの初回登録後の「確定処理」（親へのコミット＋sync/update）を自動化。
  PowerShell 5.1 / 7 互換。DryRun対応。色付きログ。Summary表示。

.PARAMETER DryRun
  副作用ゼロで実行予定のみ表示。

.PARAMETER Summary
  実行後に結果サマリを表示。

.PARAMETER Remote
  update 時に --remote を付与（追跡ブランチの最新へ）。既定は付けない（固定SHA再現）。

.PARAMETER NoCommit
  コミット処理をスキップ。

.PARAMETER Message
  コミットメッセージ。省略時は既定文言。

.PARAMETER GitExe
  git 実行ファイルのパス。省略時は 'git'（PATH）を使用。
#>

param(
    [switch]$DryRun,
    [switch]$Summary,
    [switch]$Remote,
    [switch]$NoCommit,
    [string]$Message = 'Pin submodule gitlinks (initial registration)',
    [string]$GitExe = 'git'
)

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

# ---------------- Git helpers ----------------
function Invoke-GitArgs {
    param(
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [switch]$Quiet
    )
    if ($DryRun) {
        if (-not $Quiet) { Dry ("[DryRun] SKIP actual execution: git {0}" -f ($Arguments -join ' ')) }
        return 0
    }
    & $GitExe @Arguments
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $Quiet) {
        Warn ("git exit code: $code (cmd: git {0})" -f ($Arguments -join ' '))
    }
    return $code
}

function Test-GitAvailable {
    try { & $GitExe --version | Out-Null; return $true } catch { return $false }
}

# ---------------- .gitmodules helpers ----------------
function Get-GitmodulesPaths {
    $keys = & $GitExe config --file .gitmodules --name-only --get-regexp "submodule\..*\.path" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $keys) { return @() }

    $paths = @()
    foreach ($k in $keys) {
        $name = $k -replace '^submodule\.', '' -replace '\.path$', ''
        $p = & $GitExe config --file .gitmodules ("submodule.{0}.path" -f $name) 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($p)) {
            $paths += $p
        }
    }
    return $paths
}

# ---------------- repo state helpers ----------------
function Test-StagedChanges {
    & $GitExe diff --cached --quiet 2>$null
    return ($LASTEXITCODE -ne 0)  # 差分ありなら true
}

# ---------------- core actions ----------------
function Stage-GitmodulesAndPaths {
    param([Parameter(Mandatory=$true)][string[]]$Paths)

    $staged = @()
    $skippedMissing = @()

    # .gitmodules をステージ
    if (Test-Path -LiteralPath ".gitmodules") {
        if ($DryRun) {
            Dry 'Would stage: .gitmodules'
        } else {
            Info 'Stage: .gitmodules'
            $null = Invoke-GitArgs -Arguments @('add','.gitmodules') -Quiet
        }
        $staged += '.gitmodules'
    } else {
        Warn ".gitmodules is missing. Nothing to stage for .gitmodules."
    }

    # 各パスをステージ（存在するもののみ）
    foreach ($p in $Paths) {
        if (Test-Path -LiteralPath $p) {
            if ($DryRun) {
                Dry ("Would stage: {0}" -f $p)
            } else {
                Info ("Stage: {0}" -f $p)
                $null = Invoke-GitArgs -Arguments @('add',$p) -Quiet
            }
            $staged += $p
        } else {
            Warn ("Skip (missing path): {0}" -f $p)
            $skippedMissing += $p
        }
    }

    return @{ Staged=$staged; Missing=$skippedMissing }
}

function Commit-IfNeeded {
    param([Parameter(Mandatory=$true)][string]$Message)

    if ($NoCommit) {
        Warn "NoCommit specified. Skipping commit."
        return @{ Committed=$false; Message=$Message }
    }

    $hasChanges = Test-StagedChanges
    if (-not $hasChanges) {
        Warn "Nothing to commit. (No staged changes)"
        return @{ Committed=$false; Message=$Message }
    }

    if ($DryRun) {
        Dry ('Would run: git commit -m "{0}"' -f $Message)
        return @{ Committed=$false; Message=$Message }
    }

    Info ('Execute: git commit -m "{0}"' -f $Message)
    $code = Invoke-GitArgs -Arguments @('commit','-m',$Message) -Quiet
    if ($code -ne 0) {
        Err ("Commit failed (exit: {0}). Please review staged changes." -f $code)
        return @{ Committed=$false; Message=$Message; ExitCode=$code }
    }

    Ok ("Commit done.")
    return @{ Committed=$true; Message=$Message }
}

function Run-SyncUpdate {
    param([switch]$Remote)

    # sync
    if ($DryRun) {
        Dry "Would run: git submodule sync --recursive"
    } else {
        Info "Execute: git submodule sync --recursive"
        $null = Invoke-GitArgs -Arguments @('submodule','sync','--recursive') -Quiet
    }

    # update
    $args = if ($Remote) { @('submodule','update','--remote','--recursive') } else { @('submodule','update','--recursive') }
    if ($DryRun) {
        Dry ("Would run: git {0}" -f ($args -join ' '))
    } else {
        Info ("Execute: git {0}" -f ($args -join ' '))
        $null = Invoke-GitArgs -Arguments $args -Quiet
    }

    return @{ RemoteUsed=([bool]$Remote) }
}

# ---------------- summary / next steps ----------------
function Show-Summary {
    param(
        [Parameter(Mandatory=$true)][object]$StageResult,
        [Parameter(Mandatory=$true)][object]$CommitResult,
        [Parameter(Mandatory=$true)][object]$SyncUpdateResult
    )

    Write-Host ""
    if ($DryRun) { Dry "[DryRun] Summary:" } else { Info "[Summary]" }

    if ($StageResult.Staged.Count -gt 0)   { Ok  ("  Staged:     {0}" -f ($StageResult.Staged -join ", ")) }
    if ($StageResult.Missing.Count -gt 0)  { Warn ("  Missing:    {0}" -f ($StageResult.Missing -join ", ")) }

    $commitState = if ($CommitResult.Committed) { ('Committed ("{0}")' -f $CommitResult.Message) } else { 'No commit' }
    Info ("  Commit:     {0}" -f $commitState)

    $updateMode = if ($SyncUpdateResult.RemoteUsed) { 'remote (--remote)' } else { 'pinned (fixed SHA)' }
    Info ("  Update:     {0}" -f $updateMode)
}

function Show-NextSteps {
    $lines = @(
        '--- Finished ---',
        'Recommended next:',
        '  - Push your commit:',
        '      git push',
        '  - On other machines:',
        '      git clone --recurse-submodules <repo>',
        '      # or in existing clones:',
        '      git submodule sync --recursive',
        '      git submodule update --recursive'
    )
    Info ($lines -join [Environment]::NewLine)
}

# ---------------- main ----------------
function Main {
    Info "Finalize submodules (commit gitlinks + sync/update) [PS 5.1/7 compatible]"
    if ($DryRun)   { Dry "Mode: DryRun (no changes will be made)" }
    if ($NoCommit) { Warn "NoCommit: commit will be skipped." }
    if ($Remote)   { Warn "Remote: update will track branch tips (--remote)." }

    if (-not (Test-GitAvailable)) {
        throw "git is not available. Specify -GitExe or ensure PATH."
    }

    # 1) .gitmodules からパス収集
    $paths = Get-GitmodulesPaths
    if (-not $paths -or $paths.Count -eq 0) {
        throw "No submodule paths found in .gitmodules"
    }

    Write-Host ""
    # 2) ステージ（存在するパスのみ）
    $stageResult = Stage-GitmodulesAndPaths -Paths $paths

    # 3) コミット（必要時のみ）
    $commitResult = Commit-IfNeeded -Message $Message

    # 4) sync/update（Remote スイッチで切替）
    $syncUpdateResult = Run-SyncUpdate -Remote:$Remote

    # 5) Summary / Next
    if ($Summary) { Show-Summary -StageResult $stageResult -CommitResult $commitResult -SyncUpdateResult $syncUpdateResult }
    Show-NextSteps
}

try {
    Main
}
catch {
    Err ("[Error] {0}" -f $_.Exception.Message)
    exit 1
}
