<#
.SYNOPSIS
  Git リポジトリ（ローカル作業ツリー／共有フォルダ上ベアリポジトリ）の設定を
  組織ポリシーに合わせて「検査＆是正」します。

.DESCRIPTION
  本スクリプトは、Windows／SMB 共有（UNC 禁止・R: ドライブ強制）環境における
  Git 設定を、宣言的に監査・是正するための運用ツールです。
  - ローカル（作業ツリー）：安全性・履歴方針・性能・Windows 整合の各設定を適用
  - ベア（共有フォルダ）：危険な push 拒否、整合性チェック、自動 GC 無効化 等
  - DRYRUN モード：差分を可視化のみ（承認付き半自動運用に適合）
  - 成果サマリ：OK／APPLIED／DRYRUN／SKIP 件数を表示
  - origin の方針強制はオプション（-EnforceOrigin -UserId）

  重要（運用前提）:
    * UNC 経由を明示禁止し、R:\UsersVault\{USER_ID}.git のみ許容します。
    * 自動 GC はベア側で停止（gc.auto=0）し、グローバル pre-push フック等で
      需要ベースの GC/FSCK を行う設計を想定します（本スクリプトは GC を実行しません）。
    * ログはコンソール出力のみ（ファイル出力なし）。

.PARAMETER RemoteGitDir
  共有フォルダ上ベアリポジトリ (.git) のパス（例: R:\UsersVault\USERID.git）。
  未指定の場合は、origin から推定を試みます（UNC は拒否、R:\ のみ許容）。

.PARAMETER DryRun
  変更を加えず、適用予定の差分を表示します。

.PARAMETER EnforceOrigin
  origin の URL をポリシー（R:\UsersVault\{USER_ID}.git）に強制合わせします。
  -UserId と組み合わせて使用してください。DRYRUN 対応。

.PARAMETER UserId
  -EnforceOrigin 時に使用するユーザーID（例：KUBOKAWA）。
  期待される origin は R:\UsersVault\<UserId>.git になります。

.EXAMPLE
  # 監査のみ（差分表示／是正なし）
  pwsh .\Git-ConfigCheck.ps1 -DryRun

.EXAMPLE
  # 監査＆是正（origin は触らない）
  pwsh .\Git-ConfigCheck.ps1

.EXAMPLE
  # origin を方針に合わせて強制（DRYRUN で確認）
  pwsh .\Git-ConfigCheck.ps1 -EnforceOrigin -UserId KUBOKAWA -DryRun

.EXAMPLE
  # origin を方針に合わせて強制（適用）
  pwsh .\Git-ConfigCheck.ps1 -EnforceOrigin -UserId KUBOKAWA

.NOTES
  要件:
    - OS: Windows
    - Git: Git for Windows 2.51.2.windows.1（厳密バージョン検査は本スクリプトでは未実装）
    - ネットワーク: UNC 不可、R: ドライブ割当て必須（例: `net use R:`）
    - 共有: 所有者と利用者が一致（safe.directory 不要）

  方針:
    - タグ／LFS：不使用
    - シンボリックリンク：不使用（core.symlinks=false）
    - 同時 push 禁止：Hook／運用ルールで担保（本スクリプトでは非対応）
    - GC：自動停止（gc.auto=0）、グローバルフック等で需要ベースに実行

  出力:
    - Console のみ（色付きメッセージ）
    - セクション表示、[OK]/[DRYRUN]/[APPLIED]/[SKIP] の明確化
    - 成果サマリ（LOCAL／BARE の件数）

  終了コード:
    - 0: 正常終了
    - 1: 失敗（事前条件未充足、到達不能、例外等）

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

  # 任意: origin のポリシー適合を強制（R:\UsersVault\{UserId}.git）
  [switch]$EnforceOrigin,

  # 任意: EnforceOrigin 時のユーザーID
  [string]$UserId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
  try {
    $uri = [Uri]$u
    if ($uri.Scheme -ieq 'file') {
      # 例: file:///R:/UsersVault/user.git → R:\UsersVault\user.git
      return $uri.LocalPath
    } else {
      # 非 file スキームは今回の方針対象外だが、単純変換で返す
      return ($u -replace '/', '\')
    }
  } catch {
    # URL 形式でない場合は素朴なスラッシュ -> バックスラッシュ変換
    return ($u -replace '/', '\')
  }
}

function Get-OriginRemotePath($repoRoot) {
  $originUrl = (& git -C $repoRoot remote get-url origin) 2>$null
  if (-not $originUrl) { return $null }
  return (Convert-GitUrlToWindowsPath $originUrl)
}
#endregion

#region Core: Declarative Config Applier
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

  # 成果サマリ用カウンタ
  $summary = [ordered]@{
    OK = 0
    APPLIED = 0
    DRYRUN = 0
    SKIP = 0
    TOTAL = $Desired.Keys.Count
  }

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
        $summary.DRYRUN++
      } else {
        if ($Scope -eq 'LOCAL') {
          & git -C $RepoRoot config --local $k $want | Out-Null
        } else {
          & git --git-dir $BareGitDir config $k $want | Out-Null
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
  Assert-GitAvailable
  $repoRoot = Get-RepoRoot
  Write-Host "RepoRoot : $repoRoot" -ForegroundColor DarkGray

  # --- 任意: origin の方針適合を強制（R:\UsersVault\{UserId}.git） ---
  if ($EnforceOrigin) {
    if ([string]::IsNullOrWhiteSpace($UserId)) {
      Show-Skip "LOCAL" "EnforceOrigin 指定ですが UserId が未指定のためスキップします。"
    } else {
      $expectedOrigin = "R:\UsersVault\$UserId.git"
      $currentOriginRaw = (& git -C $repoRoot remote get-url origin) 2>$null
      if ($currentOriginRaw) {
        $currentOriginPath = Convert-GitUrlToWindowsPath $currentOriginRaw

        # UNC 禁止・R:\ 強制（origin に対しても方針適用）
        $isUNC = $currentOriginPath -like '\\\\*'
        if ($isUNC -or ($currentOriginPath -notlike 'R:\*') -or ($currentOriginPath -ne $expectedOrigin)) {
          if ($DryRun) {
            Show-Change "LOCAL" "remote.origin.url" $currentOriginRaw $expectedOrigin
          } else {
            & git -C $repoRoot remote set-url origin $expectedOrigin
            Show-Change "LOCAL" "remote.origin.url" $currentOriginRaw $expectedOrigin -Applied
          }
        } else {
          Show-Ok "LOCAL" "remote.origin.url" $expectedOrigin
        }
      } else {
        # origin 不在 → 追加
        if ($DryRun) {
          Show-Change "LOCAL" "remote.add(origin)" "(none)" $expectedOrigin
        } else {
          & git -C $repoRoot remote add origin $expectedOrigin
          Show-Change "LOCAL" "remote.add(origin)" "(none)" $expectedOrigin -Applied
        }
      }
    }
  }

  # --- ローカル（作業ツリー）側の適用設定 ---
  $localDesired = [ordered]@{
    "core.filemode"           = "false";
    "core.autocrlf"           = "false";  # 改行は .gitattributes 主導
    "core.safecrlf"           = "warn";
    "pull.ff"                 = "only";
    "merge.ff"                = "only";
    "fetch.prune"             = "true";
    "push.default"            = "simple";
    "push.autoSetupRemote"    = "true";
    "rebase.autoStash"        = "true";
    "pull.rebase"             = "false";
    "fetch.fsckObjects"       = "true";

    # パフォーマンス・Windows 整合
    "core.fscache"            = "true";
    "core.preloadIndex"       = "true";
    "fetch.writeCommitGraph"  = "true";
    "gc.writeCommitGraph"     = "true";
    "core.ignoreCase"         = "true";
    "core.symlinks"           = "false";  # シンボリックリンク不使用
    "init.defaultBranch"      = "main";
  }

  Write-Section "LOCAL repo config (作業ツリー)"
  $sumLocal = Ensure-GitConfigs -Scope LOCAL -Desired $localDesired -RepoRoot $repoRoot -DryRun:$DryRun

  # --- ベア（共有フォルダ）側の場所解決 ---
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
    # UNC 明示禁止 + R:\ 強制
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

  # --- ベアリポジトリ側の適用設定 ---
  $sumBare = $null
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
      # NOTE: fetch.prune は削除（ベア側が fetch しない前提）
      # NOTE: core.sharedRepository は削除（Windows/ACL 前提）
    }

    Write-Section "BARE repo config (共有フォルダ上のベアリポジトリ)"
    $sumBare = Ensure-GitConfigs -Scope BARE -Desired $bareDesired -BareGitDir $RemoteGitDir -DryRun:$DryRun
  }

  # --- 完了メッセージ ---
  Write-Section "Done"
  if ($DryRun) {
    Write-Host "DryRun モード：設定は変更していません。" -ForegroundColor Yellow
  } else {
    Write-Host "すべて完了しました。" -ForegroundColor Green
  }

  # --- 成果サマリ ---
  Write-Section "Summary"
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

# ------------------------------
# CHANGELOG
# ------------------------------
# rev.3:
#   - UNC パス明示拒否 + R:\ ドライブ強制
#   - Convert-GitUrlToWindowsPath を [Uri] ベースで強化
#   - BARE の fetch.prune / core.sharedRepository を削除
#   - 成果サマリ出力を追加
#   - origin 方針強制をオプション化（-EnforceOrigin -UserId）
#   - コメントベースヘルプ（Get-Help 対応）を追加
#
# rev.2:
#   - 初版（LOCAL/BARE の宣言的「検査＆是正」、DRYRUN、ログ整備）
