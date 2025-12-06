
#Requires -Version 5.1
<#
.SYNOPSIS
  .gitmodules を基に、サブモジュールの初回一括登録（gitlink作成）を安全に行うスクリプト。
  PowerShell 5.1 / 7 互換。DryRun 対応。色付きログ。try-catch で見やすく。

.PARAMETER DryRun
  実行せず、やることだけを表示（副作用なし）。

.PARAMETER Summary
  実行後にサマリを表示。

.PARAMETER GitExe
  git 実行ファイルのパス。省略時は 'git'（PATH）を使用。ポータブル運用時は指定推奨。

.NOTES
  初回 add の後は必ず親で `git add .gitmodules <各サブモジュールパス>` → `git commit` を行うこと。
  その後: `git submodule sync --recursive` → `git submodule update --recursive`
#>

param(
    [switch]$DryRun,
    [switch]$Summary,
    [string]$GitExe = "git"
)

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
    try {
        & $GitExe --version | Out-Null
        return $true
    } catch { return $false }
}

function Get-GitmodulesKeys {
    $keys = & $GitExe config --file .gitmodules --name-only --get-regexp "submodule\..*\.path" 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    return $keys
}

function Get-GitmodulesValue {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [switch]$Optional
    )
    $val = & $GitExe config --file .gitmodules $Name 2>$null
    if ($LASTEXITCODE -ne 0 -and -not $Optional) {
        Warn ("Failed to read '{0}' from .gitmodules" -f $Name)
    }
    return $val
}


function Test-DirIsNonEmpty {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return ($items -ne $null -and $items.Count -gt 0)
}

function Test-GitlinkExistsInHead {
    param([Parameter(Mandatory=$true)][string]$SubmodulePath)
    # HEAD ツリーに 160000 gitlink があるか
    $output = & $GitExe ls-tree HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) { return $false }
    foreach ($line in $output) {
        if ($line -match '^\s*160000\s+commit\s+[0-9a-fA-F]+\s+(.+)$') {
            $path = $Matches[1].Trim()
            if ($path -eq $SubmodulePath) { return $true }
        }
    }
    return $false
}


function Build-AddArgs {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$Path,
        [string]$Branch
    )
    $args = @('submodule','add','--force')
    if (-not [string]::IsNullOrWhiteSpace($Branch)) {
        $args += @('--branch', $Branch)
    }
    $args += @($Url, $Path)
    return $args
}

function Process-Submodule {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Url,
        [string]$Branch
    )
    # 判定ログ（見出し）
    Info ("--- Processing: {0} ---" -f $Name)

    # 入力チェック
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Url)) {
        Warn ("[{0}] Missing URL or Path in .gitmodules. Skipping." -f $Name)
        return @{ Name=$Name; Action='SkipMissing'; }
    }

    # 非空パスガード（冪等）
    if (Test-DirIsNonEmpty -Path $Path) {
        Warn ("[{0}] Path non-empty: {1} -> Skip add (idempotent guard)" -f $Name, $Path)
        $hasGitlink = Test-GitlinkExistsInHead -SubmodulePath $Path
        Info ("[{0}] HEAD gitlink: {1}" -f $Name, ($(if ($hasGitlink) {'exists'} else {'missing'})))
        return @{ Name=$Name; Action='SkipNonEmpty'; HeadGitlink=($(if ($hasGitlink){'exists'}else{'missing'})); }
    }

    # 既に HEAD に gitlink があるなら add不要（冪等）
    if (Test-GitlinkExistsInHead -SubmodulePath $Path) {
        Warn ("[{0}] HEAD already has gitlink for '{1}'. Skipping add." -f $Name, $Path)
        return @{ Name=$Name; Action='SkipGitlink'; }
    }

    # 実施（DryRun時は Would run）
    $addArgs = Build-AddArgs -Url $Url -Path $Path -Branch $Branch
    if ($DryRun) {
        Dry ("[{0}] Would run: git {1}" -f $Name, ($addArgs -join ' '))
        Dry ("[{0}] DryRun simulated" -f $Name)
        return @{ Name=$Name; Action='PlanAdd'; }
    } else {
        Info ("[{0}] Execute: git {1}" -f $Name, ($addArgs -join ' '))
        $code = Invoke-GitArgs -Arguments $addArgs -Quiet
        if ($code -ne 0) {
            Err ("[{0}] Failed to add submodule (exit: {1})" -f $Name, $code)
            return @{ Name=$Name; Action='AddFailed'; ExitCode=$code; }
        } else {
            Ok ("[{0}] Add done" -f $Name)
            return @{ Name=$Name; Action='AddDone'; }
        }
    }
}


function Show-NextSteps {
    $next = @"
--- Finished ---
Next steps:
  1) Stage and commit in the parent repo:
     git add .gitmodules <each-submodule-path>
     git commit -m "Pin submodule gitlinks (initial registration)"
  2) Then:
     git submodule sync --recursive
     git submodule update --recursive
  (検証で最新を試す場合: git submodule update --remote --recursive)
"@
    Info $next
}


function Show-Summary {
    param([Parameter(Mandatory=$true)][object[]]$Results)
    $planned   = ($Results | Where-Object { $_.Action -eq 'PlanAdd' } | ForEach-Object { $_.Name })
    $done      = ($Results | Where-Object { $_.Action -eq 'AddDone' } | ForEach-Object { $_.Name })
    $nonempty  = ($Results | Where-Object { $_.Action -eq 'SkipNonEmpty' } | ForEach-Object { $_.Name })
    $gitlinked = ($Results | Where-Object { $_.Action -eq 'SkipGitlink' } | ForEach-Object { $_.Name })
    $missing   = ($Results | Where-Object { $_.Action -eq 'SkipMissing' } | ForEach-Object { $_.Name })
    Write-Host ""
    if ($DryRun) { Dry "[DryRun] Summary:" } else { Info "[Summary]" }
    if ($planned.Count -gt 0)  { Dry ("  Planned add: {0}" -f ($planned -join ", ")) }
    if ($done.Count -gt 0)     { Ok  ("  Add done:    {0}" -f ($done -join ", ")) }
    if ($nonempty.Count -gt 0) { Warn ("  Skipped (non-empty path): {0}" -f ($nonempty -join ", ")) }
    if ($gitlinked.Count -gt 0){ Warn ("  Skipped (HEAD gitlink exists): {0}" -f ($gitlinked -join ", ")) }
    if ($missing.Count -gt 0)  { Warn ("  Skipped (missing url/path): {0}" -f ($missing -join ", ")) }
}


function Main {
    Info "Starting submodule initial registration (Safe, PS 5.1/7 compatible)"
    if ($DryRun) { Dry "Mode: DryRun (no changes will be made)" }

    if (-not (Test-GitAvailable)) {
        throw "git is not available. Specify -GitExe or ensure PATH."
    }

    $keys = Get-GitmodulesKeys
    if (-not $keys -or $keys.Count -eq 0) {
        throw "No submodule path keys found in .gitmodules"
    }

    $results = @()
    foreach ($key in $keys) {
        Write-Host ""
        $name   = $key -replace '^submodule\.', '' -replace '\.path$', ''
        $path   = Get-GitmodulesValue -Name ("submodule.{0}.path" -f $name)
        $url    = Get-GitmodulesValue -Name ("submodule.{0}.url"  -f $name)
        $branch = Get-GitmodulesValue -Name ("submodule.{0}.branch" -f $name) -Optional

        $res = Process-Submodule -Name $name -Path $path -Url $url -Branch $branch
        $results += $res
    }

    if ($Summary) { Show-Summary -Results $results }
    Show-NextSteps
}

try {
    Main
}
catch {
    Err ("[Error] {0}" -f $_.Exception.Message)
    exit 1
}
