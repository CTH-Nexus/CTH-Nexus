#Requires -Version 5.1
<#
.SYNOPSIS
  Scalar + split-index + maintenance の初期化／確認を一括実行（PS5.1/7両対応、DryRunあり）

.PARAMETER TargetPath
  対象リポジトリのパス（既定：カレント）

.PARAMETER DryRun
  実行せずに予定だけを表示（既定：実行）

.NOTES
  - PortableGit を PATH 非依存で使用。既定パス：%USERPROFILE%\Software\PortableGit\cmd
  - 共有環境でも安全側（prefetch は常に false に再設定）
  - スケジューラ登録の有無を確認し、未登録なら git maintenance start を実行
#>

param(
  [string]$TargetPath = (Get-Location).Path,
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------
# 共通ヘルパ
# ------------------------------------------------------------
function Write-Step([string]$Message) {
  Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}
function Write-Info([string]$Message) {
  Write-Host $Message -ForegroundColor Gray
}
function Invoke-Cmd {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)] [string]$Exe,
    [Parameter(Mandatory)] [string[]]$Args,
    [switch]$DryRun,
    [string]$Repo = $null,   # フルパスでも短名でも可
    [switch]$Capture         # 出力を画面に表示（戻り値に混ぜない）
  )

  # ★ Repoラベルの方針：
  $prefix = ""
  if ($Repo) {
    if ($DryRun) {
      # フルパスのまま
      $prefix = "[repo=$Repo] "
    } else {
      # Leafに短縮
      try {
        $leaf = Split-Path -Path $Repo -Leaf -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = $Repo }
        $prefix = "[repo=$leaf] "
      }
      catch {
        $prefix = "[repo=$Repo] "
      }
    }
  }

  if ($DryRun) {
    Write-Host "[DryRun] ${prefix}$Exe $($Args -join ' ')"
    return
  }

  if ($Capture) {
    $out = & $Exe @Args
    if ($out) {
      $out | ForEach-Object { Write-Host "${prefix}$($_.ToString())" }
    }
    return
  }

  # 既定：標準出力は捨てる（戻り値混入による配列汚染を防ぐ）
  $null = & $Exe @Args
}


# ------------------------------------------------------------
# Git/Scalar のパス解決＆前提確認
# ------------------------------------------------------------
function Resolve-PortableGitPaths {
  [CmdletBinding()]
  param()

  $portableCmd = Join-Path $Env:USERPROFILE 'Software\PortableGit\cmd'
  $gitExe     = Join-Path $portableCmd 'git.exe'
  $scalarExe  = Join-Path $portableCmd 'scalar.exe'

  if (-not (Test-Path $gitExe)) {
    throw "git.exe が見つかりません: $gitExe"
  }
  if (-not (Test-Path $scalarExe)) {
    Write-Warning "scalar.exe が見つかりません: $scalarExe。Scalar 登録はスキップし、fallback: git maintenance register を試行します。"
  }

  $scalarResolved = $null
  if (Test-Path $scalarExe) {
    $scalarResolved = $scalarExe
  }

  return @{
    Git    = $gitExe
    Scalar = $scalarResolved
  }
}

# ------------------------------------------------------------
# 対象が Git リポジトリか検証
# ------------------------------------------------------------
function Assert-GitRepository {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path $Path)) {
    throw "パスが存在しません: $Path"
  }
  if (-not (Test-Path (Join-Path $Path '.git'))) {
    throw "ここは Git リポジトリではありません: $Path"
  }
}

# ------------------------------------------------------------
# .gitmodules からサブモジュール path を抽出
# ------------------------------------------------------------
function Get-SubmodulePaths {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TargetPath,
    [Parameter(Mandatory)][string]$Git
  )

  $result = @()
  Push-Location $TargetPath
  try {
    if (Test-Path '.gitmodules') {
      $lines = & $Git config --file .gitmodules --get-regexp 'submodule\..*\.path' 2>$null
      foreach ($line in $lines) {
        $parts = $line -split '\s+', 2
        if ($parts.Count -eq 2) {
          $p = $parts[1].Trim()
          if ($p) {
            $p = $p -replace '/', '\'
            $result += $p
          }
        }
      }
    }
  }
  finally { Pop-Location }

  $unique = $result | Where-Object { $_ } | Sort-Object -Unique
  return $unique
}

# ------------------------------------------------------------
# ① split-index 初期化（親 + 子サブモジュール）
# ------------------------------------------------------------
function Initialize-SplitIndex {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TargetPath,
    [Parameter(Mandatory)][string]$Git,
    [string[]]$SubmodulePaths = @(),
    [switch]$DryRun
  )

  if ($SubmodulePaths -is [string]) { throw "内部エラー: SubmodulePaths が文字列化されています: '$SubmodulePaths'" }
  if ($SubmodulePaths -isnot [System.Array]) { $SubmodulePaths = @($SubmodulePaths) }

  Write-Step "① split-index 初期化"
  Push-Location $TargetPath
  try {
    Invoke-Cmd -Exe $Git -Args @('update-index','--split-index') -DryRun:$DryRun -Repo $TargetPath
  }
  finally { Pop-Location }

  if ($SubmodulePaths.Count -gt 0) {
    Write-Host (" - サブモジュール数: {0}（各子リポジトリにも update-index を適用）" -f $SubmodulePaths.Count) -ForegroundColor Gray
  }

  foreach ($sm in $SubmodulePaths) {
    $smFull = if (Split-Path -IsAbsolute $sm) { $sm } else { Join-Path $TargetPath $sm }
    if (-not (Test-Path (Join-Path $smFull '.git'))) { continue }

    Push-Location $smFull
    try {
      Invoke-Cmd -Exe $Git -Args @('update-index','--split-index') -DryRun:$DryRun -Repo $smFull
      Invoke-Cmd -Exe $Git -Args @('config','--local','core.splitIndex','true') -DryRun:$DryRun -Repo $smFull
    }
    finally { Pop-Location }
  }
}

# ------------------------------------------------------------
# ② Scalar 登録（本体／サブモジュール）
# ------------------------------------------------------------
function Register-ScalarOrMaintenance {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TargetPath,
    [Parameter(Mandatory)][string]$Git,
    [string]$Scalar,
    [string[]]$SubmodulePaths = @(),
    [switch]$DryRun
  )

  Write-Step "② Scalar / maintenance 登録（本体）"
  Push-Location $TargetPath
  try {
    if ($Scalar) {
      Invoke-Cmd -Exe $Scalar -Args @('register','.') -DryRun:$DryRun -Repo $TargetPath
    } else {
      try {
        Invoke-Cmd -Exe $Git -Args @('maintenance','register') -DryRun:$DryRun -Repo $TargetPath
      }
      catch {
        Write-Warning "git maintenance register に失敗: $($_.Exception.Message)"
      }
    }
  }
  finally { Pop-Location }

  Write-Step "--> サブモジュール登録"
  foreach ($sm in $SubmodulePaths) {
    $smFull = if (Split-Path -IsAbsolute $sm) { $sm } else { Join-Path $TargetPath $sm }
    if (-not (Test-Path (Join-Path $smFull '.git'))) { continue }

    Write-Host " - $sm"
    Push-Location $smFull
    try {
      if ($Scalar) {
        Invoke-Cmd -Exe $Scalar -Args @('register','.') -DryRun:$DryRun -Repo $smFull
      } else {
        try {
          Invoke-Cmd -Exe $Git -Args @('maintenance','register') -DryRun:$DryRun -Repo $smFull
        }
        catch {
          Write-Warning "git maintenance register（$sm）に失敗: $($_.Exception.Message)"
        }
      }
    }
    finally { Pop-Location }
  }

  return $null
}

# ------------------------------------------------------------
# ③ メンテナンス設定（prefetch=false を再適用）※ログ集約ヘッダを追加
# ------------------------------------------------------------
function Configure-MaintenanceSettings {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TargetPath,
    [Parameter(Mandatory)][string]$Git,
    [string[]]$SubmodulePaths = @(),
    [switch]$DryRun
  )

  if ($SubmodulePaths -is [string]) { throw "内部エラー: SubmodulePaths が文字列化されています: '$SubmodulePaths'" }
  if ($SubmodulePaths -isnot [System.Array]) { $SubmodulePaths = @($SubmodulePaths) }

  Write-Step "③ メンテナンス設定の調整（prefetch=false を再適用）"
  Write-Host (" - サブモジュール数: {0}" -f $SubmodulePaths.Count) -ForegroundColor Gray

  Push-Location $TargetPath
  try {
    Invoke-Cmd -Exe $Git -Args @('config','--local','maintenance.prefetch','false') -DryRun:$DryRun -Repo $TargetPath
    Invoke-Cmd -Exe $Git -Args @('config','--local','maintenance.auto','true')    -DryRun:$DryRun -Repo $TargetPath
    Invoke-Cmd -Exe $Git -Args @('config','--local','maintenance.strategy','incremental') -DryRun:$DryRun -Repo $TargetPath
    Invoke-Cmd -Exe $Git -Args @('config','--local','core.splitIndex','true') -DryRun:$DryRun -Repo $TargetPath
  }
  finally { Pop-Location }

  foreach ($sm in $SubmodulePaths) {
    $smFull = if (Split-Path -IsAbsolute $sm) { $sm } else { Join-Path $TargetPath $sm }
    Push-Location $smFull
    try {
      Invoke-Cmd -Exe $Git -Args @('config','--local','maintenance.prefetch','false') -DryRun:$DryRun -Repo $smFull
      Invoke-Cmd -Exe $Git -Args @('config','--local','maintenance.auto','true')    -DryRun:$DryRun -Repo $smFull
      Invoke-Cmd -Exe $Git -Args @('config','--local','maintenance.strategy','incremental') -DryRun:$DryRun -Repo $smFull
      Invoke-Cmd -Exe $Git -Args @('config','--local','core.splitIndex','true') -DryRun:$DryRun -Repo $smFull
    }
    finally { Pop-Location }
  }
}


# ------------------------------------------------------------
# ④ スケジューラ確認（未登録なら maintenance start）
# ------------------------------------------------------------
function Ensure-MaintenanceScheduledTask {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Git,
    [switch]$DryRun
  )

  Write-Step "④ スケジューラ確認（Git Maintenance タスク）"
  try {
    $tasks = schtasks /query | Out-String
    $gitTasks = ($tasks -split "`r?`n") | Where-Object { $_ -match 'Git Maintenance' }
    if ($gitTasks.Count -gt 0) {
      Write-Host ($gitTasks -join "`n")
      return
    }

    Write-Warning "Git Maintenance タスクが見つかりません。登録を試みます。"
    Invoke-Cmd -Exe $Git -Args @('maintenance','start') -DryRun:$DryRun

    # 再確認
    $tasks2 = schtasks /query | Out-String
    $gitTasks2 = ($tasks2 -split "`r?`n") | Where-Object { $_ -match 'Git Maintenance' }
    if ($gitTasks2.Count -gt 0) {
      Write-Host ($gitTasks2 -join "`n")
    }
    else {
      Write-Warning "スケジューラ登録に失敗した可能性があります（ポリシー／権限）。手動運用（週次の gc/commit-graph）をご検討ください。"
    }
  }
  catch {
    Write-Warning "タスクスケジューラの照会に失敗: $($_.Exception.Message)"
  }
}

# ------------------------------------------------------------
# ⑤ 設定の見える化／sharedindex 状態確認
# ------------------------------------------------------------
function Show-RepoSettingsAndSharedIndex {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TargetPath,
    [Parameter(Mandatory)][string]$Git,
    [switch]$DryRun
  )

  Write-Step "⑤ 設定確認（--show-origin）"
  Push-Location $TargetPath
  try {
    $pattern = '^(maintenance(\..+)?|core\.(splitIndex|untrackedCache|fsmonitor))$'
    Invoke-Cmd -Exe $Git -Args @('config','--show-origin','--get-regexp',$pattern) -DryRun:$DryRun -Repo $TargetPath -Capture
  }
  finally { Pop-Location }

  Write-Step "--> sharedindex.* の確認"
  Get-ChildItem -Force (Join-Path $TargetPath '.git') |
    Where-Object Name -like 'sharedindex.*' |
    Select-Object Name,Length,LastWriteTime |
    Format-Table -AutoSize
}

# ------------------------------------------------------------
# TargetPath 正規化（絶対パス化・Path文字列化・存在チェック）
# ------------------------------------------------------------
function Resolve-TargetPath {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TargetPath
  )

  # 文字列に混入した引用符を除去（PowerShell外から渡された場合の保険）
  $clean = $TargetPath.Trim('"').Trim("'")

  try {
    # 相対なら現在ディレクトリ基準で絶対化し、PSDrive表現のない Path を取得
    $resolved = Resolve-Path -LiteralPath $clean -ErrorAction Stop
    return $resolved.Path
  }
  catch {
    throw "パス '$TargetPath' が存在しないため検出できません。"
  }
}

# ------------------------------------------------------------
# main の呼び出し側（Initialize-SplitIndex をサブモジュール込みで呼ぶ）
# ------------------------------------------------------------
function Start-RepoMaintenance {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TargetPath,
    [switch]$DryRun
  )

  try {
    $RootPath = Resolve-TargetPath -TargetPath $TargetPath
    Assert-GitRepository -Path $RootPath

    $paths    = Resolve-PortableGitPaths
    $gitExe   = $paths.Git
    $scalarExe= $paths.Scalar

    $submodules = Get-SubmodulePaths -TargetPath $RootPath -Git $gitExe

    # ①
    Write-Host (" - サブモジュール数: {0}（各子にも split-index を適用）" -f $submodules.Count) -ForegroundColor Gray
    Initialize-SplitIndex -TargetPath $RootPath -Git $gitExe -SubmodulePaths $submodules -DryRun:$DryRun

    # ② ★ 再代入なし／副作用のみ
    Register-ScalarOrMaintenance -TargetPath $RootPath -Git $gitExe -Scalar $scalarExe -SubmodulePaths $submodules -DryRun:$DryRun

    # ③
    Configure-MaintenanceSettings -TargetPath $RootPath -Git $gitExe -SubmodulePaths $submodules -DryRun:$DryRun

    Ensure-MaintenanceScheduledTask -Git $gitExe -DryRun:$DryRun
    Show-RepoSettingsAndSharedIndex -TargetPath $RootPath -Git $gitExe -DryRun:$DryRun

    Write-Host "`n完了。DryRun=$($DryRun.IsPresent) / Repo=$RootPath"
  }
  catch { throw $_ }
}

# ------------------------------------------------------------
# スクリプト直接実行時
# ------------------------------------------------------------
$IsDotSourced = ($MyInvocation.InvocationName -eq '.')
if (-not $IsDotSourced) {
  try {
    # 依存関数の存在確認（必要に応じて削除可）
    if (-not (Get-Command -Name Resolve-TargetPath -ErrorAction SilentlyContinue)) {
      throw "Resolve-TargetPath が見つかりません。必要なスクリプト/モジュールを読み込んでください。"
    }
    if (-not (Get-Command -Name Start-RepoMaintenance -ErrorAction SilentlyContinue)) {
      throw "Start-RepoMaintenance が見つかりません。必要なスクリプト/モジュールを読み込んでください。"
    }

    $RootPath = Resolve-TargetPath -TargetPath $TargetPath
    Start-RepoMaintenance -TargetPath $RootPath -DryRun:$DryRun
  }
  catch {
    Write-Error "致命的エラー: $($_.Exception.Message)"
    # CLI用途ならプロセスの終了コードを明示
    exit 1
  }
}
else {
  # ドットソース時は何もしない（必要なら公開関数のエクスポート等をここで）
  Write-Verbose "このスクリプトはドットソースされました。処理本体は自動実行されません。"
}
