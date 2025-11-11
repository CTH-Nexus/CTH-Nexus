#!/usr/bin/env pwsh
# -------------------------------------------
# Git pre-push hook (PowerShell version)
# Git for Windows で動作する pre-push フック。
# このスクリプトは、プッシュ前に整合性検査や保護ブランチ/ロック制御を行う。
# .git/hooks/pre-push に配置し、実行権限を設定して使う。
# TTL (Time To Live) はロック有効時間を秒単位で定義（デフォルト300秒）。
# 実行前に、管理者が共有リポジトリ上に `R:\repo.git\locks` および
#  `R:\repo.git\locks`\refs を作成しておくこと
# -------------------------------------------


param(
    [string]$RemoteName,  # Gitが自動で渡す：リモート名（例: origin）
    [string]$RemoteUrl    # Gitが自動で渡す：リモートリポジトリURLまたはパス
)

# エラー動作設定。エラー発生時に即スクリプトを停止する。
$ErrorActionPreference = "Stop"

# ---- Config ----
# ここで各種環境変数から設定値を取得し、存在しない場合はデフォルト値を適用する。
$TTL = [int](${env:LOCK_TTL_SECONDS} ?? 300)                     # ロックの有効期間（秒）
$RetryMax = [int](${env:LOCK_RETRY_MAX} ?? 15)                   # ロック取得の最大リトライ回数
$ProtectedBranchesRegex = ${env:PROTECTED_BRANCHES_REGEX} ?? '^(main|master|release/.*)$'  # 保護ブランチ正規表現
$LockBaseSubdir = ${env:LOCK_BASE_SUBDIR} ?? 'locks'             # ロックディレクトリの基底サブパス
$EnableGlobalLock = [bool](${env:ENABLE_GLOBAL_LOCK} ?? $true)   # グローバルロックの有効化
$EnablePerRefLock = [bool](${env:ENABLE_PER_REF_LOCK} ?? $true)  # リファレンス単位ロックの有効化

# Remote URL チェック：空ならエラー終了
if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
    Write-Error "pre-push: remote URL is empty"
}

# ---- Resolve SMB path ----
# Remote URLが「file://」形式などの場合に対応。
# Windows共有パスやドライブマウント形式を処理する。
function Normalize-RemotePath([string]$url) {
    if ($url -like 'file://*') { return $url.Substring(7) }  # "file://" の7文字を除去
    # 通常形式（例: R:\repo.git or \\server\share\repo.git）はそのまま返す
    return $url
}

# 正規化されたリモートパスを使ってロックディレクトリを準備
$remotePath = Normalize-RemotePath $RemoteUrl
$LockBase = Join-Path $remotePath $LockBaseSubdir
$refsLockDir = Join-Path $LockBase 'refs'

# ロックディレクトリを強制的に作成（既存でもOK）
New-Item -ItemType Directory -Force -Path $LockBase | Out-Null
New-Item -ItemType Directory -Force -Path $refsLockDir | Out-Null

# ---- Read updates from STDIN ----
# Gitはpush時に更新されるrefのペアをSTDINで渡す。
# 各行形式: <local ref> <local sha1> <remote ref> <remote sha1>
$updates = @()
while ($line = [Console]::In.ReadLine()) {
    if (-not [string]::IsNullOrWhiteSpace($line)) {
        $updates += $line
    }
}

# ---- Pre-flight fetch ----
# リモートの最新情報を取得して整合性チェックに備える。
Write-Host "pre-push: fetching latest from '$RemoteName'..."
git fetch --prune "$RemoteName"

# ---- Helpers ----
# タグ判定
function Is-TagRef([string]$ref) { 
    # 形式が refs/tags/* ならタグ
    return $ref -like 'refs/tags/*' 
}

# 保護ブランチ判定
function Is-ProtectedBranch([string]$ref) {
    # refs/heads/ で始まる場合はブランチとして処理
    if ($ref -like 'refs/heads/*') {
        $name = $ref.Substring(11)  # "refs/heads/" を除いた部分がブランチ名
        return [regex]::IsMatch($name, $ProtectedBranchesRegex)
    }
    return $false
}

# fast-forwardが許可されているか確認
function FastForward-OK([string]$remoteSha, [string]$localSha) {
    # リモートが存在しない場合（新規）はOK
    if ($remoteSha -eq '0000000000000000000000000000000000000000') { return $true }

    # git merge-base --is-ancestor でfast-forward判定
    $p = Start-Process -FilePath 'git' -ArgumentList @('merge-base','--is-ancestor',$remoteSha,$localSha) -NoNewWindow -PassThru -Wait
    return ($p.ExitCode -eq 0)
}

# ---- Policy checks ----
# 各refごとにpush前ポリシーを適用。
foreach ($u in $updates) {
    $parts = $u -split '\s+'
    $localRef,$localSha,$remoteRef,$remoteSha = $parts

    # タグ更新禁止（既存タグの上書きや削除を防ぐ）
    if (Is-TagRef $remoteRef) {
        if ($remoteSha -ne '0000000000000000000000000000000000000000') {
            Write-Error "pre-push: immutable tags — moving/deleting '$remoteRef' prohibited"
        }
    }

    # 保護ブランチへの直接push禁止
    if (Is-ProtectedBranch $remoteRef) {
        $branch = $remoteRef.Substring(11)
        Write-Error "pre-push: protected branch '$branch' — direct push prohibited"
    }

    # fast-forwardでないpushを拒否
    if (-not (FastForward-OK $remoteSha $localSha)) {
        Write-Error "pre-push: fast-forward required for '$remoteRef'; fetch & rebase/merge first"
    }
}

# ---- Lock acquisition ----
# 以下は排他ロック機構の実装。複数の開発者やプロセスが同時pushするのを防ぐ。

# lockPath の最終更新時刻から経過秒数を算出して返す。
function Get-LockAgeSeconds([string]$lockPath) {
    if (-not (Test-Path $lockPath)) { return $null }
    try {
        $mtime = (Get-Item $lockPath).LastWriteTimeUtc
        $now = (Get-Date).ToUniversalTime()
        return [int]([Math]::Round(($now - $mtime).TotalSeconds))
    } catch { return $null }
}

# ロック作成関数：存在チェック、TTL超過検出、古いロック削除、新規ロック作成
function MkLock([string]$lockPath, [int]$ttl) {
    $age = Get-LockAgeSeconds $lockPath
    if ($age -ne $null) {
        if ($age -lt $ttl) { return $false }  # ロックが新鮮なら失敗
        try { Remove-Item -Recurse -Force $lockPath -ErrorAction SilentlyContinue } catch {}
    }

    try {
        # ロックディレクトリ作成
        New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop | Out-Null

        # 付随メタ情報（作成者、ホスト、PID、作成時刻）をjsonで記録
        $metaPath = "$lockPath.meta.json"
        $meta = @{
            user = (git config user.name)
            host = $env:COMPUTERNAME
            pid  = $PID
            epoch = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        } | ConvertTo-Json
        Set-Content -LiteralPath $metaPath -Value $meta -Encoding UTF8
        return $true
    } catch { return $false }
}

# ロック取得関数：指定回数リトライしながらロックを獲得しようとする。
function Acquire-WithRetry([string]$lockPath, [int]$retryMax, [int]$ttl) {
    $backoff = 1  # 初回待機1秒
    for ($i=0; $i -lt $retryMax; $i++) {
        if (MkLock $lockPath $ttl) { return $true }  # ロック取得成功
        Write-Host "pre-push: lock busy '$lockPath' — retry $($i+1)/$retryMax (sleep ${backoff}s)"
        Start-Sleep -Seconds $backoff
        $backoff = [Math]::Min($backoff * 2, 30)  # バックオフ増加（最大30秒）
    }
    return $false
}

# 取得済みロックのリスト（後で必要に応じ解除するための管理用）
$lockedRefs = @()

# ---- グローバルロック ----
# リポジトリ全体のロックを取得（同時push防止）。
if ($EnableGlobalLock) {
    $globalLock = Join-Path $LockBase 'global.lock'
    if (-not (Acquire-WithRetry $globalLock $RetryMax $TTL)) {
        Write-Error "pre-push: repository busy (global lock); try later"
    }
}

# ---- リファレンス単位ロック ----
# 各refごとに個別ロックを取得可能にする。
if ($EnablePerRefLock) {
    foreach ($u in $updates) {
        $parts = $u -split '\s+'
        $remoteRef = $parts[2]
        # ref名に含まれるスラッシュを安全なファイル名にする
        $safeName = ($remoteRef -replace '/', '__')
        $refLock = Join-Path $refsLockDir "$safeName.lock"

        if (-not (Acquire-WithRetry $refLock $RetryMax $TTL)) {
            Write-Error "pre-push: ref busy '$remoteRef'; try later"
        }

        $lockedRefs += $refLock
    }
}

# ---- Push許可 ----
Write-Host "pre-push: locks acquired; proceeding with push."
Write-Host "pre-push: please avoid concurrent pushes for ~$([int]([Math]::Floor($TTL/60))) min."
# ロックの解除処理は行わず、TTL経過によって自動的に期限切れとなる設計。

exit 0
