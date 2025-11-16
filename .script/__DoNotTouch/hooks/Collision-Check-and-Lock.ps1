#requires -Version 5.1
# -------------------------------------------
# Git pre-push hook (PowerShell version)
# Git for Windows で動作する pre-push フック。
# このスクリプトは、プッシュ前に整合性検査と保護ブランチ/ロック制御を行う。
# .git/hooks/pre-push に PowerShell スクリプトとして配置し、実行権限を設定する。
#
# ロックは共有リポジトリ側の <remote>\locks 配下に作成され、TTL（既定 300 秒）で自然失効する。
# 事前に管理者が共有リポジトリ上に以下のディレクトリを用意しておくこと：
#   R:\repo.git\locks
#   R:\repo.git\locks\refs
# -------------------------------------------

param(
    [string]$RemoteName,  # Git が自動で渡す：リモート名（例: origin）
    [string]$RemoteUrl    # Git が自動で渡す：リモートリポジトリ URL またはローカルパス（例: R:\repo.git）
)

# エラー動作：一部のコマンドレットで終端エラーに準じた扱い。
# ※ Write-Error は非終端のため、明示的に Fail() で exit する。
$ErrorActionPreference = "Stop"

# ------------------------------
# 5.1 互換ヘルパー群
# ------------------------------

function Get-EnvOrDefault([string]$name, $default) {
    $v = [Environment]::GetEnvironmentVariable($name)
    if ($null -eq $v -or [string]::IsNullOrWhiteSpace($v)) { return $default }
    return $v
}

# 文字列を厳密に真偽値へ変換（未設定なら既定値）
function To-Bool([string]$s, [bool]$default=$true) {
    if ($null -eq $s -or [string]::IsNullOrWhiteSpace($s)) { return $default }
    switch ($s.ToLower()) {
        'true'  { return $true }
        'false' { return $false }
        default { return $default }
    }
}

# 終了ヘルパー：メッセージを出した上で終了コード 1
function Fail([string]$msg) {
    Write-Error $msg
    exit 1
}

# ------------------------------
# Config（環境変数 → 既定値）
# ------------------------------

$TTL      = Get-EnvOrDefault 'LOCK_TTL_SECONDS' 300             # ロック有効期間（秒）
$RetryMax = Get-EnvOrDefault 'LOCK_RETRY_MAX'   15              # ロック取得の最大リトライ回数

$ProtectedBranchesRegex = Get-EnvOrDefault 'PROTECTED_BRANCHES_REGEX' '^(main|master|release/.*)$'  # 保護ブランチ正規表現
$LockBaseSubdir         = Get-EnvOrDefault 'LOCK_BASE_SUBDIR'         'locks'                        # ロックディレクトリの基底サブパス

$EnableGlobalLock = To-Bool $env:ENABLE_GLOBAL_LOCK $true              # グローバルロックの有効化
$EnablePerRefLock = To-Bool $env:ENABLE_PER_REF_LOCK $true             # リファレンス単位ロックの有効化

# ------------------------------
# Remote URL チェック
# ------------------------------

if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
    Fail "pre-push: remote URL is empty"
}

# ------------------------------
# SMB/ローカルパス正規化
# ------------------------------
# Git の file:// URL をドライブレター形式へ揃える（R: ドライブ運用推奨）
function Normalize-RemotePath([string]$url) {
    if ($url -like 'file://*') {
        # "file:///" を許容し、"R:\repo.git" のようなパスへ変換
        $u = $url -replace '^file://+', ''  # 先頭の "file://" をすべて除去
        if ($u -match '^/[A-Za-z]:/') {
            return $u.TrimStart('/') -replace '/', '\'
        }
        return $u
    }
    return $url
}

$remotePath = Normalize-RemotePath $RemoteUrl
$LockBase   = Join-Path $remotePath $LockBaseSubdir
$refsLockDir = Join-Path $LockBase 'refs'

# ロックディレクトリを強制的に作成（既存でも OK）
New-Item -ItemType Directory -Force -Path $LockBase    | Out-Null
New-Item -ItemType Directory -Force -Path $refsLockDir | Out-Null

# ------------------------------
# STDIN（push 対象の ref 群）読取り
# 形式: <local ref> <local sha1> <remote ref> <remote sha1>
# ------------------------------

$updates = @()
while ($line = [Console]::In.ReadLine()) {
    if (-not [string]::IsNullOrWhiteSpace($line)) {
        $updates += $line
    }
}

# ------------------------------
# Pre-flight fetch（整合性用）
# ------------------------------
Write-Host "pre-push: fetching latest from '$RemoteName'..."
git fetch --prune "$RemoteName"

# ------------------------------
# Helpers
# ------------------------------

# タグ判定（refs/tags/*）
function Is-TagRef([string]$ref) {
    return $ref -like 'refs/tags/*'
}

# 保護ブランチ判定（refs/heads/* → ブランチ名へ変換して正規表現判定）
function Is-ProtectedBranch([string]$ref) {
    if ($ref -like 'refs/heads/*') {
        $name = $ref.Substring(11)  # "refs/heads/" を除去
        return [regex]::IsMatch($name, $ProtectedBranchesRegex)
    }
    return $false
}

# fast-forward 許可判定
function FastForward-OK([string]$remoteSha, [string]$localSha) {
    # リモートが存在しない場合（新規ブランチ/タグ）は OK
    if ($remoteSha -eq '0000000000000000000000000000000000000000') { return $true }

    # git merge-base --is-ancestor で fast-forward 判定
    $p = Start-Process -FilePath 'git' -ArgumentList @('merge-base','--is-ancestor',$remoteSha,$localSha) -NoNewWindow -PassThru -Wait
    return ($p.ExitCode -eq 0)
}

# ------------------------------
# Policy checks（各 ref ごと）
# ------------------------------

foreach ($u in $updates) {
    $parts = $u -split '\s+'
    $localRef,$localSha,$remoteRef,$remoteSha = $parts

    # タグ更新禁止（既存タグの移動/削除を拒否）
    if (Is-TagRef $remoteRef) {
        if ($remoteSha -ne '0000000000000000000000000000000000000000') {
            Fail "pre-push: immutable tags — moving/deleting '$remoteRef' prohibited"
        }
    }

    # 保護ブランチへの直接 push を禁止
    if (Is-ProtectedBranch $remoteRef) {
        $branch = $remoteRef.Substring(11)
        Fail "pre-push: protected branch '$branch' — direct push prohibited"
    }

    # 非 fast-forward push を拒否
    if (-not (FastForward-OK $remoteSha $localSha)) {
        Fail "pre-push: fast-forward required for '$remoteRef'; fetch & rebase/merge first"
    }
}

# ------------------------------
# Lock acquisition（排他制御）
# ------------------------------

# lockPath の最終更新時刻から経過秒数を返す
function Get-LockAgeSeconds([string]$lockPath) {
    if (-not (Test-Path $lockPath)) { return $null }
    try {
        $mtime = (Get-Item $lockPath).LastWriteTimeUtc
        $now = (Get-Date).ToUniversalTime()
        return [Math]::Round(($now - $mtime.TotalSeconds))
    } catch { return $null }
}

# ロック作成：存在チェック → TTL 超過なら古いロック削除 → 新規作成
function MkLock([string]$lockPath, [int]$ttl) {
    $age = Get-LockAgeSeconds $lockPath
    if ($age -ne $null) {
        if ($age -lt $ttl) { return $false }  # ロックが新鮮なら取得失敗（競合中）
        try { Remove-Item -Recurse -Force $lockPath -ErrorAction SilentlyContinue } catch {}
    }

    try {
        # ロックディレクトリ作成
        New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null

        # 付随メタ情報（作成者、ホスト、PID、作成時刻）を JSON で記録
        $metaPath = "$lockPath.meta.json"
        $meta = @{
            user  = (git config user.name)
            host  = $env:COMPUTERNAME
            pid   = $PID
            epoch = [DateTimeOffset]::new((Get-Date.ToUniversalTime())).ToUnixTimeSeconds()
        } | ConvertTo-Json
        Set-Content -LiteralPath $metaPath -Value $meta -Encoding UTF8
        return $true
    } catch { return $false }
}

# ロック取得（指数バックオフ + リトライ）
function Acquire-WithRetry([string]$lockPath, [int]$retryMax, [int]$ttl) {
    $backoff = 1  # 初回待機 1 秒
    for ($i=0; $i -lt $retryMax; $i++) {
        if (MkLock $lockPath $ttl) { return $true }  # ロック取得成功
        Write-Host "pre-push: lock busy '$lockPath' — retry $($i+1)/$retryMax (sleep ${backoff}s)"
        Start-Sleep -Seconds $backoff
        $backoff = [Math]::Min($backoff * 2, 30)  # バックオフ増加（最大 30 秒）
    }
    return $false
}

# 取得済み ref ロックのリスト（後で必要に応じ解除するための管理用；今回は TTL 自然失効設計）
$lockedRefs = @()

# グローバルロック（リポジトリ単位）
if ($EnableGlobalLock) {
    $globalLock = Join-Path $LockBase 'global.lock'
    if (-not (Acquire-WithRetry $globalLock $RetryMax $TTL)) {
        Fail "pre-push: repository busy (global lock); try later"
    }
}

# リファレンス単位ロック（各 ref ごと）
if ($EnablePerRefLock) {
    foreach ($u in $updates) {
        $parts = $u -split '\s+'
        $remoteRef = $parts[2]
        # ref 名のスラッシュを安全なファイル名へ
        $safeName = ($remoteRef -replace '/', '__')
        $refLock  = Join-Path $refsLockDir "$safeName.lock"

        if (-not (Acquire-WithRetry $refLock $RetryMax $TTL)) {
            Fail "pre-push: ref busy '$remoteRef'; try later"
        }

        $lockedRefs += $refLock
    }
}

# ------------------------------
# Push 許可（以降は Git に制御を戻す）
# ------------------------------

Write-Host "pre-push: locks acquired; proceeding with push."
Write-Host "pre-push: please avoid concurrent pushes for ~$([Math]::Floor($TTL/60)) min."
# ロックの解除は行わない（TTL 経過により自動的に期限切れ）。明示的 unlock は不要。

exit 0
