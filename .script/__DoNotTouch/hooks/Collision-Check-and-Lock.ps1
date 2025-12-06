#requires -Version 5.1
# -------------------------------------------
# Git pre-push hook (PowerShell version)
# このスクリプトは、プッシュ前に整合性検査（非FFチェック）とロック制御のみを行う。
# .git/hooks/pre-push.ps1 として保存し、.git/hooks/pre-push（ラッパ）から呼び出す。
#
# ロックは共有リポジトリ側の <remote>\locks 配下に作成され、TTL（既定 300 秒）で自然失効する。
# 事前に共有リポジトリ上に以下のディレクトリが存在することが望ましいが、なければ自動作成される：
#   R:\repo.git\locks
#   R:\repo.git\locks\refs
# -------------------------------------------

param(
    [string]$RemoteName,  # Git が自動で渡す：リモート名（例: origin）
    [string]$RemoteUrl    # Git が自動で渡す：リモートリポジトリ URL またはローカルパス（例: R:\repo.git あるいは file:///R:/repo.git）
)

$ErrorActionPreference = "Stop"

# ------------------------------
# Helper: 終了
# ------------------------------
function Fail([string]$msg) {
    Write-Error $msg
    exit 1
}

# ------------------------------
# Helper: .env 読込（ルート直下）
# フォーマット: KEY=VALUE（# 先頭行はコメント、空行は無視）
# 読込後は Process スコープの環境変数として設定される。
# ------------------------------
function Load-DotEnv([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    Get-Content -LiteralPath $path | ForEach-Object {
        $line = $_.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        if ($line.StartsWith('#')) { return }
        $kv = $line -split '=', 2
        if ($kv.Length -eq 2) {
            $k = $kv[0].Trim()
            $v = $kv[1].Trim()
            [Environment]::SetEnvironmentVariable($k, $v, 'Process')
        }
    }
}

# ------------------------------
# 5.1 互換ヘルパー群
# ------------------------------
function Get-EnvOrDefault([string]$name, $default) {
    $v = (Get-Item -Path "Env:$name" -ErrorAction SilentlyContinue).Value
    if ($null -eq $v -or [string]::IsNullOrWhiteSpace($v)) { return $default }
    return $v
}

# 文字列を厳密に真偽値へ変換（未設定なら既定値）
function To-Bool([string]$s, [bool]$default=$true) {
    if ($null -eq $s -or [string]::IsNullOrWhiteSpace($s)) { return $default }
    switch ($s.ToLowerInvariant()) {
        'true'  { return $true }
        'false' { return $false }
        default { return $default }
    }
}

# ------------------------------
# Remote URL チェック
# ------------------------------
if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
    Fail "pre-push: remote URL is empty"
}

# ------------------------------
# SMB/ローカルパス正規化
# Git の file:// URL をドライブレター形式へ揃える（R: ドライブ運用推奨）
# ------------------------------
function Normalize-RemotePath([string]$url) {
    if ($url -like 'file://*') {
        # "file:///" を許容し、"R:\repo.git" のようなパスへ変換
        $u = $url -replace '^file://+', ''  # 先頭の "file://" を除去
        if ($u -match '^/[A-Za-z]:/') {
            return ($u.TrimStart('/') -replace '/', '\')
        }
        return $u
    }
    return $url
}

# .env をルート（カレント）から読み込む（任意）
try { Load-DotEnv (Join-Path (Get-Location) '.env') } catch {}

# ------------------------------
# Config（環境変数 → 既定値）
# ------------------------------
$TTL        = [int](Get-EnvOrDefault 'LOCK_TTL_SECONDS' 300)        # ロック有効期間（秒）
$RetryMax   = [int](Get-EnvOrDefault 'LOCK_RETRY_MAX'   15)          # ロック取得の最大リトライ回数
$LockBaseSubdir   = Get-EnvOrDefault 'LOCK_BASE_SUBDIR' 'locks'      # ロックディレクトリの基底サブパス

$EnableGlobalLock = To-Bool (Get-EnvOrDefault 'ENABLE_GLOBAL_LOCK' 'true')  $true  # グローバルロックの有効化
$EnablePerRefLock = To-Bool (Get-EnvOrDefault 'ENABLE_PER_REF_LOCK' 'true') $true  # リファレンス単位ロックの有効化

$remotePath  = Normalize-RemotePath $RemoteUrl
$LockBase    = Join-Path $remotePath $LockBaseSubdir
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
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line -split '\s+'
    if ($parts.Length -lt 4) {
        Write-Host "pre-push: skip malformed update line: '$line'"
        continue
    }
    $updates += ,@($parts[0], $parts[1], $parts[2], $parts[3])
}

# ------------------------------
# Pre-flight fetch（整合性用）
# ------------------------------
Write-Host "pre-push: fetching latest from '$RemoteName'..."
try {
    git fetch --prune "$RemoteName" | Out-Null
} catch {
    Fail "pre-push: fetch failed — ensure remote '$RemoteName' is reachable"
}

# ------------------------------
# Helpers
# ------------------------------
function Is-TagRef([string]$ref) {
    return $ref -like 'refs/tags/*'
}

# fast-forward 許可判定
function FastForward-OK([string]$remoteSha, [string]$localSha) {
    # リモートが存在しない場合（新規ブランチ/タグ）は OK
    if ($remoteSha -eq '0000000000000000000000000000000000000000') { return $true }
    # git merge-base --is-ancestor で fast-forward 判定（remote が local の祖先なら OK）
    $p = Start-Process -FilePath 'git' -ArgumentList @('merge-base','--is-ancestor',$remoteSha,$localSha) -NoNewWindow -PassThru -Wait
    return ($p.ExitCode -eq 0)
}

# ------------------------------
# Policy checks（各 ref ごと）
# ------------------------------
foreach ($parts in $updates) {
    $localRef,$localSha,$remoteRef,$remoteSha = $parts

    # タグ更新禁止（既存タグの移動/削除を拒否）※必要に応じてこのブロックを残置
    if (Is-TagRef $remoteRef) {
        if ($remoteSha -ne '0000000000000000000000000000000000000000') {
            Fail "pre-push: immutable tags — moving/deleting '$remoteRef' prohibited"
        }
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
    if (-not (Test-Path -LiteralPath $lockPath)) { return $null }
    try {
        $mtime = (Get-Item -LiteralPath $lockPath).LastWriteTimeUtc
        $now = (Get-Date).ToUniversalTime()
        return [int][Math]::Round((($now - $mtime).TotalSeconds))
    } catch { return $null }
}

# ロック作成：存在チェック → TTL 超過なら古いロック削除 → 新規作成
function MkLock([string]$lockPath, [int]$ttl) {
    $age = Get-LockAgeSeconds $lockPath
    if ($age -ne $null) {
        if ($age -lt $ttl) { return $false }  # ロックが新鮮なら取得失敗（競合中）
        try { Remove-Item -Recurse -Force -LiteralPath $lockPath -ErrorAction SilentlyContinue } catch {}
    }

    try {
        # ロックディレクトリ作成
        New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null

        # 付随メタ情報（作成者、ホスト、PID、作成時刻）を JSON で記録
        $user = $null
        try { $user = (git config user.name) } catch {}
        if ([string]::IsNullOrWhiteSpace($user)) { $user = $env:USERNAME }

        $metaPath = "$lockPath.meta.json"
        $meta = @{
            user  = $user
            host  = $env:COMPUTERNAME
            pid   = $PID
            epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        } | ConvertTo-Json -Compress
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

# 取得済み ref ロックのリスト（自然失効設計のため記録のみ）
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
    foreach ($parts in $updates) {
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

exit 0
