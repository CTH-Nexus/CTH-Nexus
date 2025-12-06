<#
.SYNOPSIS
  Git リポジトリ（ローカル作業ツリー／共有フォルダ上ベアリポジトリ）の設定を
  組織ポリシーに合わせて「検査＆是正」します。（ポータブル Git 対応）

.DESCRIPTION
  Windows／SMB 共有（UNC 禁止・R: ドライブ強制）環境における Git 設定を、
  宣言的に監査・是正するための運用ツールです。ポータブル Git 利用時に
  PATH が通っていなくても .env や自動探索で git.exe を検出して動作します。

  - ローカル（作業ツリー）：安全性・履歴方針・性能・Windows 整合の各設定を適用
  - ベア（共有フォルダ）：危険な push 拒否、整合性チェック、自動 GC 無効化 等
  - DRYRUN モード：差分を可視化のみ（承認付き半自動運用に適合）
  - 成果サマリ：OK／APPLIED／DRYRUN／SKIP 件数を表示
  - origin の方針強制はオプション（-EnforceOrigin -UserId）
  - .env 対応：GIT_EXE, REMOTE_GIT_DIR, USER_ID などを読み込み可能

.PARAMETER RemoteGitDir
  共有フォルダ上ベアリポジトリ (.git) のパス（例: R:\UsersVault\USERID.git）。
  未指定の場合は、origin から推定を試みます（UNC は拒否、R:\ のみ許容）。
  .env の REMOTE_GIT_DIR があれば優先されます。

.PARAMETER DryRun
  変更を加えず、適用予定の差分を表示します。
  .env の DRYRUN=true があれば既定で DryRun 扱いになります（指定が上書き）。

.PARAMETER EnforceOrigin
  origin の URL を R:\UsersVault\{UserId}.git に強制合わせします。
  .env では無視されます（キーを書かない運用を推奨）。

.PARAMETER UserId
  -EnforceOrigin 時に使用するユーザーID（例：KUBOKAWA）。
  .env の USER_ID があれば優先されます。

.NOTES
  要件:
    - OS: Windows
    - Git: Git for Windows 2.51.2.windows.1（厳密バージョン検査は未実装）
    - ネットワーク: UNC 不可、R: ドライブ割当て必須（例: `net use R:`）
    - 共有: 所有者と利用者が一致（safe.directory 不要）
    - ポータブル Git: PATH 不要。`.env` または自動探索で git.exe を検出

  既知事項:
    - core.sharedRepository は Windows/ACL 環境では効果が限定的なため未使用
    - BARE 側の fetch.prune は、ベアが fetch を行わない前提のため未設定

.LINK
  運用ガイドライン／社内手順書（該当 URL/パスを追記してください）
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
  [Parameter(Mandatory=$false)]
  [string]$RemoteGitDir,

  [switch]$DryRun,

  [switch]$EnforceOrigin,

  [string]$UserId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- Portable Git support (.env / auto-discovery) ----------
$script:GitExe     = $null
$script:ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# 現在のユーザーIDを %USERPROFILE% から導出（例：D:\Users\{{USER_ID}} -> {{USER_ID}}）
function Get-CurrentUserId {
  try {
    $leaf = Split-Path -Leaf $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($leaf)) { return $env:USERNAME }
    return $leaf
  } catch {
    return $env:USERNAME
  }
}

# .env の値に含まれる {{USER_ID}} と環境変数（%USERPROFILE% など）を展開
function Expand-EnvPlaceholders([string]$value) {
  if ([string]::IsNullOrWhiteSpace($value)) { return $value }
  $v = [Environment]::ExpandEnvironmentVariables($value)  # %VAR% を展開
  $uid = Get-CurrentUserId
  # 置換は Regex ではなく文字列置換で安全に
  $v = $v.Replace('{{USER_ID}}', $uid)
  return $v
}

function Load-DotEnv {
  param([string]$BasePath)
  $cands = @(
    (Join-Path $BasePath '.env'),          # 実行ディレクトリ直下優先
    (Join-Path $script:ScriptRoot '.env')  # スクリプト直下
  )
  foreach ($p in $cands) {
    if (Test-Path -LiteralPath $p) {
      Get-Content -LiteralPath $p | ForEach-Object {
        $line = $_.Trim()
        if (-not $line) { return }
        if ($line.StartsWith('#')) { return }
        if ($line -notmatch '=') { return }

        $kv  = $line -split '=', 2
        $key = $kv[0].Trim()
        $raw = $kv[1].Trim()

        # ★ プレースホルダ・環境変数を展開
        $val = Expand-EnvPlaceholders $raw

        switch -Regex ($key.ToUpper()) {
          '^GIT_EXE$'         { $script:GitExe = $val }
          '^REMOTE_GIT_DIR$'  { if (-not $PSBoundParameters.ContainsKey('RemoteGitDir')) { $RemoteGitDir = $val } }
          '^USER_ID$'         { if (-not $PSBoundParameters.ContainsKey('UserId'))      { $UserId = $val } }
          '^ENFORCE_ORIGIN$'  { } # 今回不要なので .env からは無視（キーを書かない運用推奨） }
          '^DRYRUN$'          { if (-not $PSBoundParameters.ContainsKey('DryRun')) {
                                  if ($val.ToLower() -in @('1','true','yes')) { $DryRun = $true }
                                }
                              }
          default { }
        }
      }
      break
    }
  }
}

function Resolve-GitExe {
  # 1) .env / ENV を最優先（.env では Expand-EnvPlaceholders 済み）
  if ($script:GitExe -and (Test-Path -LiteralPath $script:GitExe)) { return }
  if ($env:GIT_EXE) {
    $cand = Expand-EnvPlaceholders $env:GIT_EXE
    if (Test-Path -LiteralPath $cand) { $script:GitExe = $cand; return }
  }

  # 2) チーム標準配置（%USERPROFILE%\Software\PortableGit\cmd\git.exe）
  $userProfileCand = Join-Path $env:USERPROFILE 'Software\PortableGit\cmd\git.exe'
  if (Test-Path -LiteralPath $userProfileCand) { $script:GitExe = $userProfileCand; return }

  # 3) スクリプト近傍（既存ロジック）
  $cands = @(
    (Join-Path $script:ScriptRoot 'PortableGit\cmd\git.exe'),
    (Join-Path $script:ScriptRoot 'Git\cmd\git.exe'),
    (Join-Path $script:ScriptRoot 'cmd\git.exe'),
    (Join-Path (Split-Path -Parent $script:ScriptRoot) 'PortableGit\cmd\git.exe')
  )
  foreach ($p in $cands) {
    if (Test-Path -LiteralPath $p) { $script:GitExe = $p; return }
  }

  # 4) PATH（最終手段）
  $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
  if ($cmd) { $script:GitExe = $cmd.Path; return }

  throw "git.exe が見つかりません。`.env` の GIT_EXE にフルパス（または %USERPROFILE%/{{USER_ID}} を含む書式）を指定するか、%USERPROFILE%\Software\PortableGit\cmd\git.exe に配置してください。"
}

function Invoke-Git {
  param([Parameter(Mandatory=$true)][string[]]$Args)
  & $script:GitExe @Args
}

#region Utilities (Logging)
function Write-Section([string]$text) {
  Write-Host "== $text ==" -ForegroundColor Cyan
}
function Show-Change([string]$scope, [string]$key, [string]$from, [string]$to, [switch]$Applied) {
  $fmt = if ($Applied) { "[APPLIED]  {0}: {1} : '{2}' -> '{3}' (changed)" }
         else          { "[DRYRUN]   {0}: {1} : '{2}' -> '{3}' (will change)" }
  Write-Host ($fmt -f $scope, $key, $from, $to) -ForegroundColor Green
}
function Show-Ok([string]$scope, [string]$key, [string]$val) {
  Write-Host ("[NO-CHANGE] {0}: {1} = '{2}'" -f $scope, $key, $val) -ForegroundColor DarkGreen
}
function Show-Skip([string]$scope, [string]$reason) {
  Write-Host ("[SKIP]      {0}: {1}" -f $scope, $reason) -ForegroundColor Yellow
}
#endregion

#region Pre-Checks / Resolvers
function Assert-GitAvailable {
  try {
    $ver = (Invoke-Git @('--version'))
    if (-not $ver) { throw "git not found" }
    Write-Host "Git detected: $ver" -ForegroundColor DarkGray
  } catch {
    throw "Git が見つかりません。ポータブル版の場合は .env の GIT_EXE に git.exe のフルパスを指定してください。"
  }
}

function Assert-RDriveReady {
  $drv = Get-PSDrive -Name R -ErrorAction SilentlyContinue
  if (-not $drv) {
    Show-Skip "BARE" "R: ドライブが未割当です（`net use R:` を先に実施してください）。"
    return $false
  }
  return $true
}

function Get-RepoRoot {
  $root = (Invoke-Git @('rev-parse','--show-toplevel')) 2>$null
  if (-not $root) {
    throw "ここは Git リポジトリではありません。（.git が見つかりません）"
  }
  return $root
}

function Convert-GitUrlToWindowsPath([string]$url) {
  if ([string]::IsNullOrWhiteSpace($url)) { return $null }
  $u = $url.Trim()
  try {
    $uri = [Uri]$u
    if ($uri.Scheme -ieq 'file') {
      return $uri.LocalPath
    } else {
      return ($u -replace '/', '\')
    }
  } catch {
    return ($u -replace '/', '\')
  }
}

function Get-OriginRemotePath($repoRoot) {
  $originUrl = (Invoke-Git @('-C', $repoRoot, 'remote', 'get-url', 'origin')) 2>$null
  if (-not $originUrl) { return $null }
  return (Convert-GitUrlToWindowsPath $originUrl)
}
#endregion

#region Core: Declarative Config Applier
function Ensure-GitConfigs {
  param(
    [Parameter(Mandatory=$true)][ValidateSet('LOCAL','BARE','GLOBAL')]
    [string]$Scope,
    [Parameter(Mandatory=$true)]
    [hashtable]$Desired,
    [string]$RepoRoot,
    [string]$BareGitDir,
    [switch]$DryRun
  )

  $summary = [ordered]@{ OK=0; APPLIED=0; DRYRUN=0; SKIP=0; TOTAL=$Desired.Keys.Count }

  foreach ($k in $Desired.Keys) {
    $want = $Desired[$k]
    $cur  = $null

    if ($Scope -eq 'LOCAL') {
      if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        Show-Skip $Scope "RepoRoot が未指定です"
        $summary.SKIP++; continue
      }
      $cur = (Invoke-Git @('-C', $RepoRoot, 'config', '--local', '--get', $k)) 2>$null

    } elseif ($Scope -eq 'BARE') {
      if ([string]::IsNullOrWhiteSpace($BareGitDir)) {
        Show-Skip $Scope "BareGitDir が未指定です"
        $summary.SKIP++; continue
      }
      $cur = (Invoke-Git @('--git-dir', $BareGitDir, 'config', '--get', $k)) 2>$null

    } elseif ($Scope -eq 'GLOBAL') {
      $cur = (Invoke-Git @('config', '--global', '--get', $k)) 2>$null
    }

    if ($cur -ne $want) {
      if ($DryRun) {
        Show-Change $Scope $k $cur $want
        $summary.DRYRUN++
      } else {
        # 設定の適用
        if ($Scope -eq 'LOCAL') {
          Invoke-Git @('-C', $RepoRoot, 'config', '--local', $k, $want) | Out-Null
        } elseif ($Scope -eq 'BARE') {
          Invoke-Git @('--git-dir', $BareGitDir, 'config', $k, $want) | Out-Null
        } elseif ($Scope -eq 'GLOBAL') {
          Invoke-Git @('config', '--global', $k, $want) | Out-Null
        }
        Show-Change $Scope $k $cur $want -Applied
        $summary.APPLIED++
      }
    } else {
      Show-Ok $Scope $k $want
      $summary.OK++
    }
  }

  return $summary
}
#endregion

# ========== Main ==========
try {
  Write-Section "Pre-Check"
  Write-Section "Legend"
  Write-Host "[NO-CHANGE] 現状がポリシー通り（変更なし）" -ForegroundColor DarkGreen
  Write-Host "[DRYRUN]    現状と差分あり（本番なら 'from' -> 'to' に変更）" -ForegroundColor Green
  Write-Host "[APPLIED]   差分を適用済み（'from' -> 'to' に変更）" -ForegroundColor Green
  Write-Host "[SKIP]      方針/到達性等の理由で対象外" -ForegroundColor Yellow

  # .env 読み込み（実行ディレクトリ直下優先、次にスクリプト直下）
  Load-DotEnv -BasePath (Get-Location).Path

  # Git exe 解決（ポータブル対応）
  Resolve-GitExe
  Assert-GitAvailable

  Write-Section "GLOBAL git config (ユーザー全体)"
  $globalDesired = [ordered]@{
  "protocol.file.allow"      = "always";
  "init.defaultBranch"       = "main";
  "core.longpaths"           = "true";
  "core.autocrlf"            = "true";
  "i18n.logoutput"           = "true";
  # 1) Windows 共有環境での性能と安定性
  "core.fscache"             = "true";
  "core.fsmonitor"           = "true";
  "core.preloadIndex"        = "true";
  "core.splitIndex"          = "true";
  "gc.writeCommitGraph"      = "true";
  "fetch.writeCommitGraph"   = "true";
  # 2) 操作ポリシーの明確化（安全側へ）
  "push.default"             = "simple";
  "advice.pushUpdateRejected"= "true";
  "advice.pushNonFFCurrent"  = "true";
  # 3) 差分品質と衝突解決の効率
  "diff.mnemonicprefix"      = "true";
  "diff.algorithm"           = "patience";
  "merge.conflictStyle"      = "zdiff3";
  "rerere.enabled"           = "true";
  # 4) ロケールと文字列表示の整備
  "core.quotePath"           = "false";
  "log.date"                 = "iso";
  "color.ui"                 = "auto";
  # 5) サブモジュールの安全運用
  "submodule.recurse"        = "false";
  "fetch.recurseSubmodules"  = "on-demand";
  "diff.submodule"           = "log";
  "status.submoduleSummary"  = "true";
  }
  $sumGlobal = Ensure-GitConfigs -Scope GLOBAL -Desired $globalDesired -DryRun:$DryRun

  $repoRoot = Get-RepoRoot
  Write-Host "RepoRoot : $repoRoot" -ForegroundColor DarkGray

  # 任意: origin 方針適合を強制（-EnforceOrigin 指定時のみ）
  if ($EnforceOrigin) {
    if ([string]::IsNullOrWhiteSpace($UserId)) {
      Show-Skip "LOCAL" "EnforceOrigin 指定ですが UserId が未指定のためスキップします。（.env の USER_ID でも可）"
    } else {
      $expectedOrigin = "R:\UsersVault\$UserId.git"
      $currentOriginRaw = (Invoke-Git @('-C', $repoRoot, 'remote', 'get-url', 'origin')) 2>$null
      if ($currentOriginRaw) {
        $currentOriginPath = Convert-GitUrlToWindowsPath $currentOriginRaw
        $isUNC = $currentOriginPath -like '\\\\*'
        if ($isUNC -or ($currentOriginPath -notlike 'R:\*') -or ($currentOriginPath -ne $expectedOrigin)) {
          if ($DryRun) {
            Show-Change "LOCAL" "remote.origin.url" $currentOriginRaw $expectedOrigin
          } else {
            Invoke-Git @('-C', $repoRoot, 'remote', 'set-url', 'origin', $expectedOrigin)
            Show-Change "LOCAL" "remote.origin.url" $currentOriginRaw $expectedOrigin -Applied
          }
        } else {
          Show-Ok "LOCAL" "remote.origin.url" $expectedOrigin
        }
      } else {
        if ($DryRun) {
          Show-Change "LOCAL" "remote.add(origin)" "(none)" $expectedOrigin
        } else {
          Invoke-Git @('-C', $repoRoot, 'remote', 'add', 'origin', $expectedOrigin)
          Show-Change "LOCAL" "remote.add(origin)" "(none)" $expectedOrigin -Applied
        }
      }
    }
  }

  # LOCAL 設定適用
  $localDesired = [ordered]@{
    "core.autocrlf"           = "false";
    "core.filemode"           = "false";
    "core.fscache"            = "true";
    "core.ignoreCase"         = "true";
    "core.safecrlf"           = "warn";
    "core.symlinks"           = "false";
    "gc.writeCommitGraph"     = "true";
    "init.defaultBranch"      = "main";
    "fetch.fsckObjects"       = "true";
    "fetch.prune"             = "true";
    "fetch.writeCommitGraph"  = "true";
    "pull.ff"                 = "only";
    "pull.rebase"             = "true";
    "merge.ff"                = "only";
    "merge.ours.name"         = "Prefer OURS (local~=origin) Version"; # cf. `.gitattributes`
    "merge.ours.driver"       = "true";       # なにもせず (ours) を残す (cp %A %A と同等)
    "merge.theirs.name"       = "Prefer THEIRS (upstream) Version"; # cf. `.gitattributes`
    "merge.theirs.driver"     = "cp %B %A"; # %B（theirs）を結果ファイル %A にコピー
    "push.autoSetupRemote"    = "true";
    "push.default"            = "simple";
    "rebase.autoStash"        = "true";
    "rebase.updateRefs"       = "true";
    "rerere.enabled"          = "true";
  }
  Write-Section "LOCAL repo config (作業ツリー)"
  $sumLocal = Ensure-GitConfigs -Scope LOCAL -Desired $localDesired -RepoRoot $repoRoot -DryRun:$DryRun

  # BARE 側の場所解決（.env 優先）
  if (-not $RemoteGitDir) {
    $RemoteGitDir = Get-OriginRemotePath -repoRoot $repoRoot
    if ($RemoteGitDir) {
      Write-Host "Detected remote from 'origin': $RemoteGitDir" -ForegroundColor DarkGray
    }
  }

  $sumBare = $null
  $remoteUsable = $false
  if (-not (Assert-RDriveReady)) {
    # R ドライブ未割当 → BARE はスキップ（LOCAL は継続）
  } elseif (-not $RemoteGitDir) {
    Show-Skip "BARE" "リモートパスが未指定、かつ origin からも解決できませんでした。（.env の REMOTE_GIT_DIR でも可）"
  } else {
    $isUNC = $RemoteGitDir -like '\\\\*'
    if ($isUNC) {
      Show-Skip "BARE" "UNC パスは方針で許可されていません: $RemoteGitDir"
    } elseif ($RemoteGitDir -notlike 'R:\*') {
      Show-Skip "BARE" "R: ドライブ配下のみ許可: $RemoteGitDir"
    } elseif ($RemoteGitDir -notmatch '\.git$') {
      Show-Skip "BARE" "リモートパスが .git で終わっていません: $RemoteGitDir"
    } elseif (-not (Test-Path -LiteralPath $RemoteGitDir)) {
      Show-Skip "BARE" "リモートパスにアクセスできません: $RemoteGitDir"
    } else {
      $remoteUsable = $true
      Write-Host "BareGitDir: $RemoteGitDir" -ForegroundColor DarkGray
    }
  }

  if ($remoteUsable) {
    $bareDesired = [ordered]@{
      "core.bare"                   = "true";
      "core.filemode"               = "false";
      "receive.denyNonFastForwards" = "true";
      "receive.denyDeletes"         = "true";
      "receive.fsckObjects"         = "true";
      "transfer.fsckObjects"        = "true";
      "gc.auto"                     = "0";
      "gc.writeCommitGraph"         = "true";
      "advice.pushUpdateRejected"   = "true";
      "advice.pushNonFFCurrent"     = "true";
      "repack.writeBitmaps"         = "true";
      "receive.advertisePushOptions"= "true";
    }
    Write-Section "BARE repo config (共有フォルダ上のベアリポジトリ)"
    $sumBare = Ensure-GitConfigs -Scope BARE -Desired $bareDesired -BareGitDir $RemoteGitDir -DryRun:$DryRun
  }

  Write-Section "Done"
  if ($DryRun) {
    Write-Host "DryRun モード：設定は変更していません。" -ForegroundColor Yellow
  } else {
    Write-Host "すべて完了しました。" -ForegroundColor Green
  }

  Write-Section "Summary"
  if ($sumGlobal) {
    Write-Host ("GLOBAL: total={0}, NO-CHANGE={1}, APPLIED={2}, DRYRUN={3}, SKIP={4}" -f `
      $sumGlobal.TOTAL, $sumGlobal.OK, $sumGlobal.APPLIED, $sumGlobal.DRYRUN, $sumGlobal.SKIP) -ForegroundColor DarkGray
  }
  if ($sumLocal) {
    Write-Host ("LOCAL: total={0}, NO-CHANGE={1}, APPLIED={2}, DRYRUN={3}, SKIP={4}" -f `
      $sumLocal.TOTAL, $sumLocal.OK, $sumLocal.APPLIED, $sumLocal.DRYRUN, $sumLocal.SKIP) -ForegroundColor DarkGray
  }
  if ($sumBare) {
    Write-Host ("BARE : total={0}, NO-CHANGE={1}, APPLIED={2}, DRYRUN={3}, SKIP={4}" -f `
      $sumBare.TOTAL,  $sumBare.OK,  $sumBare.APPLIED,  $sumBare.DRYRUN,  $sumBare.SKIP) -ForegroundColor DarkGray
  }

  exit 0

} catch {
  Write-Error $_.Exception.Message
  exit 1
}
# End of File
