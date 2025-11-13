<#
  Git-ConfigCheck.ps1  (rev.2)

  ローカル（作業ツリー）および共有フォルダ上ベアリポジトリの Git 設定を
  貴環境ポリシーに合わせて「検査＆是正」します。

  前提（今回の採用方針）：
    - タグ運用／LFS：不使用
    - シンボリックリンク：不使用（core.symlinks=false）
    - origin URL：R:\UsersVault\{USER_ID}.git（UNC 不可）
    - Git for Windows 2.51.2.windows.1
    - 所有者と利用者が一致（safe.directory は不要）

  ログはコンソールのみ出力。ファイル出力なし。
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$false)]
  [string]$RemoteGitDir,

  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Section([string]$text) {
  Write-Host "== $text ==" -ForegroundColor Cyan
}

function Assert-GitAvailable {
  try {
    $ver = (& git --version)
    if (-not $ver) { throw "git not found" }
    Write-Host "Git detected: $ver" -ForegroundColor DarkGray
  } catch {
    throw "Git が見つかりません。Git for Windows をインストールし、PATH を通してください。"
  }
}

function Get-RepoRoot {
  $root = (& git rev-parse --show-toplevel) 2>$null
  if (-not $root) {
    throw "ここは Git リポジトリではありません。（.git が見つかりません）"
  }
  return $root
}

function Convert-GitUrlToWindowsPath([string]$url) {
  if ([string]::IsNullOrWhiteSpace($url)) { return $null }
  $u = $url.Trim()
  if ($u -match '^file:///?') { $u = $u -replace '^file:///?', '' }
  $u = $u -replace '/', '\'
  return $u
}

function Get-OriginRemotePath($repoRoot) {
  $originUrl = (& git -C $repoRoot remote get-url origin) 2>$null
  if (-not $originUrl) { return $null }
  return (Convert-GitUrlToWindowsPath $originUrl)
}

function Show-Change([string]$scope, [string]$key, [string]$from, [string]$to, [switch]$Applied) {
  $msg = if ($Applied) {
    "[APPLIED] $scope: $key : '$from' -> '$to'"
  } else {
    "[DRYRUN]  $scope: $key : '$from' -> '$to'"
  }
  Write-Host $msg -ForegroundColor Green
}

function Show-Ok([string]$scope, [string]$key, [string]$val) {
  Write-Host "[OK]      $scope: $key = '$val'" -ForegroundColor DarkGreen
}

function Show-Skip([string]$scope, [string]$reason) {
  Write-Host "[SKIP]    $scope: $reason" -ForegroundColor Yellow
}

function Ensure-GitConfigs {
  param(
    [Parameter(Mandatory=$true)] [ValidateSet('LOCAL','BARE')]
    [string]$Scope,

    [Parameter(Mandatory=$true)]
    [hashtable]$Desired,

    [string]$RepoRoot,
    [string]$BareGitDir,
    [switch]$DryRun
  )

  foreach ($k in $Desired.Keys) {
    $want = $Desired[$k]
    $cur  = $null

    if ($Scope -eq 'LOCAL') {
      $cur = (& git -C $RepoRoot config --local --get $k) 2>$null
    } else {
      $cur = (& git --git-dir $BareGitDir config --get $k) 2>$null
    }

    if ($cur -ne $want) {
      if ($DryRun) {
        Show-Change $Scope $k $cur $want
      } else {
        if ($Scope -eq 'LOCAL') {
          & git -C $RepoRoot config --local $k $want | Out-Null
        } else {
          & git --git-dir $BareGitDir config $k $want | Out-Null
        }
        Show-Change $Scope $k $cur $want -Applied
      }
    } else {
      Show-Ok $Scope $k $want
    }
  }
}

# ========== Main ==========
try {
  Write-Section "Pre-Check"
  Assert-GitAvailable
  $repoRoot = Get-RepoRoot
  Write-Host "RepoRoot : $repoRoot" -ForegroundColor DarkGray

  # --- ローカル側に適用する設定（採用方針反映） ---
  $localDesired = [ordered]@{
    # 既存のご指定
    "core.filemode"           = "false";
    "core.autocrlf"           = "false";  # 改行は .gitattributes 主導
    "core.safecrlf"           = "warn";
    "pull.ff"                 = "only";
    "merge.ff"                = "only";
    "fetch.prune"             = "true";
    "push.default"            = "simple";
    "push.autoSetupRemote"    = "true";
    "rebase.autoStash"        = "true";

    # 新規採用（挙動の明示・安全性）
    "pull.rebase"             = "false";
    "fetch.fsckObjects"       = "true";

    # パフォーマンス最適化・Windows 整合
    "core.fscache"            = "true";
    "core.preloadIndex"       = "true";
    "fetch.writeCommitGraph"  = "true";
    "gc.writeCommitGraph"     = "true";
    "core.ignoreCase"         = "true";
    "core.symlinks"           = "false";  # シンボリックリンク不使用
    "init.defaultBranch"      = "main";
  }

  Write-Section "LOCAL repo config (作業ツリー)"
  Ensure-GitConfigs -Scope LOCAL -Desired $localDesired -RepoRoot $repoRoot -DryRun:$DryRun

  # --- リモート（ベア）側の場所解決 ---
  if (-not $RemoteGitDir) {
    $RemoteGitDir = Get-OriginRemotePath -repoRoot $repoRoot
    if ($RemoteGitDir) {
      Write-Host "Detected remote from 'origin': $RemoteGitDir" -ForegroundColor DarkGray
    }
  }

  $remoteUsable = $false
  if (-not $RemoteGitDir) {
    Show-Skip "BARE" "リモートパスが未指定、かつ origin からも解決できませんでした。"
  } else {
    if ($RemoteGitDir -notmatch '\.git$') {
      Show-Skip "BARE" "リモートパスが .git で終わっていません: $RemoteGitDir"
    } elseif (-not (Test-Path -LiteralPath $RemoteGitDir)) {
      Show-Skip "BARE" "リモートパスにアクセスできません: $RemoteGitDir"
    } else {
      $remoteUsable = $true
      Write-Host "BareGitDir: $RemoteGitDir" -ForegroundColor DarkGray
    }
  }

  # --- ベアリポジトリ側に適用する設定（採用方針反映） ---
  if ($remoteUsable) {
    $bareDesired = [ordered]@{
      # 既存のご指定
      "core.bare"                   = "true";
      "core.filemode"               = "false";
      "core.sharedRepository"       = "group";
      "receive.denyNonFastForwards" = "true";
      "receive.denyDeletes"         = "true";
      "receive.fsckObjects"         = "true";
      "transfer.fsckObjects"        = "true";
      "gc.auto"                     = "0";
      "gc.writeCommitGraph"         = "true";
      "fetch.prune"                 = "true";
      "advice.pushUpdateRejected"   = "true";
      "advice.pushNonFFCurrent"     = "true";

      # 新規採用
      "repack.writeBitmaps"         = "true";
      "receive.advertisePushOptions"= "true";
    }

    Write-Section "BARE repo config (共有フォルダ上のベアリポジトリ)"
    Ensure-GitConfigs -Scope BARE -Desired $bareDesired -BareGitDir $RemoteGitDir -DryRun:$DryRun
  }

  Write-Section "Done"
  if ($DryRun) {
    Write-Host "DryRun モード：設定は変更していません。" -ForegroundColor Yellow
  } else {
    Write-Host "すべて完了しました。" -ForegroundColor Green
  }
  exit 0

} catch {
  Write-Error $_.Exception.Message
  exit 1
}
