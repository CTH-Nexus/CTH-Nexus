#requires -Version 5.1
# pre-push hook (PowerShell)
# 許可されたリモートURL以外への push を禁止（Rドライブ前提）
# さらに、main への push はリポジトリ所有者（USER_ID一致）のみ許可
# ホワイトリスト中の {{USER_ID}} は %USERPROFILE% の末尾フォルダ名で置換
# 追加: .env（リポジトリ直下）から TEAM_REPO を読み込み、{{TEAM_REPO}} を解決

param(
    [string]$RemoteName,
    [string]$RemoteUrl
)

$ErrorActionPreference = 'Stop'

# --- USER_ID を USERPROFILE から抽出 ---
function Get-UserIdFromUserProfile {
    $up = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($up)) { return $null }
    try {
        $leaf = Split-Path -Leaf $up
        if ([string]::IsNullOrWhiteSpace($leaf)) { return $null }
        return $leaf
    } catch { return $null }
}

$USER_ID = Get-UserIdFromUserProfile
if ([string]::IsNullOrWhiteSpace($USER_ID)) {
    Write-Host "ERROR: USER_ID を %USERPROFILE% から取得できませんでした。" -ForegroundColor Red
    Write-Host ("USERPROFILE: {0}" -f $env:USERPROFILE) -ForegroundColor DarkGray
    exit 1
}

# --- URL 正規化関数（表記揺れの吸収） ---
function Normalize-Url([string]$u) {
    if ([string]::IsNullOrWhiteSpace($u)) { return "" }
    $n = $u.Trim()

    # file:// 形式を削除（file:/// や file://localhost/ を吸収）
    $n = $n -replace '^file://(localhost/)?', ''

    # UNC はここでは正規化しない（後段で明示的に拒否）
    # バックスラッシュをスラッシュに統一
    $n = $n -replace '\\', '/'

    # R:\ → R:/、大文字小文字のゆれも吸収
    $n = $n -replace '^[rR]:\\', 'R:/'
    $n = $n -replace '^[rR]:/',  'R:/'

    # 末尾スラッシュは除去（明示的に char を渡す）
    $n = $n.TrimEnd([char]'/')

    return $n
}

# --- UNC 拒否チェック（Normalize には依存しない） ---
function Is-Unc([string]$raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
    $s = $raw.Trim()
    # 先頭が \\ または // は UNC とみなして拒否
    return ($s.StartsWith('\\') -or $s.StartsWith('//'))
}

# --- .env 探索用（リポジトリ直下の .env を読む） ---
function Get-RepoRoot([string]$ScriptDir) {
    # 1) GIT_DIR があれば優先
    if ($env:GIT_DIR -and (Test-Path -LiteralPath $env:GIT_DIR)) {
        try {
            $gitDirItem = Get-Item -LiteralPath $env:GIT_DIR
            if ($gitDirItem -and $gitDirItem.PSIsContainer) {
                return $gitDirItem.Parent.FullName
            }
        } catch { }
    }
    # 2) スクリプトの親から .git を探す（既定 hooks 配置: .git\hooks\*.ps1）
    try {
        $start = if ($ScriptDir) { Get-Item -LiteralPath $ScriptDir } else { Get-Item -LiteralPath (Get-Location) }
        $cur = $start
        for ($i=0; $i -lt 5 -and $cur -ne $null; $i++) {
            $candidate = Join-Path $cur.FullName '.git'
            if (Test-Path -LiteralPath $candidate) {
                $gitDirItem = Get-Item -LiteralPath $candidate
                return $gitDirItem.Parent.FullName
            }
            $cur = $cur.Parent
        }
    } catch { }
    # 3) カレントから .git を探す
    try {
        $candidate2 = Join-Path (Get-Location).Path '.git'
        if (Test-Path -LiteralPath $candidate2) {
            return (Get-Item -LiteralPath $candidate2).Parent.FullName
        }
    } catch { }
    return $null
}

function Load-DotEnv([string]$repoRoot) {
    $envPath = if ($repoRoot) { Join-Path $repoRoot '.env' } else { '.env' }
    $map = @{}
    if (-not (Test-Path -LiteralPath $envPath)) { return $map }
    foreach ($line in Get-Content -LiteralPath $envPath) {
        $s = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if ($s.StartsWith('#')) { continue }
        $idx = $s.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $s.Substring(0, $idx).Trim()
        $val = $s.Substring($idx + 1).Trim()
        # 囲み引用の除去
        if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        $map[$key] = $val
    }
    return $map
}

# --- .env 読み込み（TEAM_REPO を取得） ---
$repoRoot = Get-RepoRoot -ScriptDir $PSScriptRoot
$dotenv   = Load-DotEnv $repoRoot
$TEAM_REPO = $null
if ($dotenv.ContainsKey('TEAM_REPO')) {
    $TEAM_REPO = $dotenv['TEAM_REPO']
}

# --- ホワイトリスト（UNCは不可） ---
# {{USER_ID}} と {{TEAM_REPO}} を置換（正規表現は使わない）
# TEAM_REPO は .env にフルパス（例: R:\Knewrova.git）で記載する前提
$allowedTemplates = @(
    '{{TEAM_REPO}}',                          # ← .env の TEAM_REPO が設定されている時のみ採用
    'R:\UsersVault\{{USER_ID}}.git',
    'R:\Submodule\Shared\User\{{USER_ID}}.git',
    'R:\Submodule\Shared\Project\{{USER_ID}}.git'
)

# 置換＋正規化（$ を含む USER_ID でも安全）
$allowedNormalized = @()

function Convert-FileUriToWindowsPath([string]$uri) {
    # file:///R:/path/to/repo.git → R:\path\to\repo.git
    try {
        $u = [Uri]$uri
        if ($u.Scheme -ne 'file') { return $null }
        if ($u.IsUnc) {
            # file://server/share/... はUNC相当のためここではWindowsパスへ変換しない（禁止対象）
            return $null
        }
        # ローカルドライブ指定（例: /R:/Submodule/...）
        # AbsolutePath 先頭のスラッシュを除去して、スラッシュをバックスラッシュへ
        $p = $u.AbsolutePath.TrimStart('/')
        $p = $p -replace '/', '\'
        return $p
    } catch {
        return $null
    }
}

foreach ($t in $allowedTemplates) {
    # TEAM_REPO 置換（未設定ならこのエントリはスキップ）
    if ($t.Contains('{{TEAM_REPO}}')) {
        if ([string]::IsNullOrWhiteSpace($TEAM_REPO)) { continue }
        $path = $t.Replace('{{TEAM_REPO}}', $TEAM_REPO)
    } else {
        $path = $t
    }
    # USER_ID 置換
    $path = $path.Replace('{{USER_ID}}', $USER_ID)

    # --- 許可候補の登録（2系統） ---
    if ($path -match '^\s*file:///') {
        # すでに file:/// なので二重付与はしない
        # 1) file URI 系（そのまま）
        $allowedNormalized += (Normalize-Url $path)

        # 2) 裸パス系も許可する（必要であれば）
        $winPath = Convert-FileUriToWindowsPath $path
        if ($winPath) {
            $allowedNormalized += (Normalize-Url $winPath)
        }
    }
    elseif ($path -match '^\s*file://') {
        # ホスト名付き file://server/... はUNC相当（禁止対象）→ 許可リストへは追加しない
        # 必要ならログ等を出したい場合はここで対応
        continue
    }
    else {
        # 裸パス入力
        # 1) 裸パス系
        $allowedNormalized += (Normalize-Url $path)

        # 2) file:/// 版（この時のみ付与し、二重付与を避ける）
        $pathUriLike = $path.Replace('\', '/')
        $fileUriCandidate = 'file:///' + $pathUriLike
        $allowedNormalized += (Normalize-Url $fileUriCandidate)
    }
}

# 重複排除（Normalize-Url の結果が同一になるケースを考慮）
$allowedNormalized = $allowedNormalized | Select-Object -Unique

# リモートURLの正規化
$remoteNormalized = Normalize-Url $RemoteUrl

# --- UNC 拒否 ---
if (Is-Unc $RemoteUrl) {
    Write-Host "ERROR: UNC パスへの push は禁止されています（R: ドライブを使用してください）。" -ForegroundColor Red
    Write-Host ("RemoteUrl (raw): {0}" -f $RemoteUrl) -ForegroundColor DarkGray
    exit 1
}

# --- 許可判定（前方一致；OrdinalIgnoreCase） ---
$allowed = $false
$matchedPrefix = $null
foreach ($a in $allowedNormalized) {
    if ($remoteNormalized.StartsWith($a, [System.StringComparison]::OrdinalIgnoreCase)) {
        $allowed = $true
        $matchedPrefix = $a
        break
    }
}

if (-not $allowed) {
    Write-Host "ERROR: 許可外のリモートURLへの push は禁止されています。" -ForegroundColor Red
    Write-Host ("RemoteName: {0}" -f $RemoteName) -ForegroundColor DarkGray
    Write-Host ("RemoteUrl (raw) : {0}" -f $RemoteUrl)  -ForegroundColor DarkGray
    Write-Host ("RemoteUrl (norm): {0}" -f $remoteNormalized)  -ForegroundColor DarkGray
    Write-Host "許可リスト（正規化後）：" -ForegroundColor Yellow
    $allowedNormalized | ForEach-Object { Write-Host ("  - {0}" -f $_) -ForegroundColor Yellow }
    if ([string]::IsNullOrWhiteSpace($TEAM_REPO)) {
        Write-Host "NOTE: .env の TEAM_REPO が未設定のため、チームリポジトリは許可リストに含まれていません。" -ForegroundColor Yellow
        Write-Host "      例）.env: TEAM_REPO=R:\Knewrova.git" -ForegroundColor Yellow
    }
    exit 1
}

# --- リポジトリ所有者の抽出（正規化されたリモートURLから） ---
# 規約：末尾セグメントが "<owner>.git" であること（例: R:/UsersVault/kubo.git）
function Get-RepoOwnerId([string]$normalizedUrl) {
    if ([string]::IsNullOrWhiteSpace($normalizedUrl)) { return $null }
    # 末尾セグメントを取得
    $segments = $normalizedUrl -split '/'
    if ($segments.Length -lt 1) { return $null }
    $leaf = $segments[$segments.Length - 1]
    # "<owner>.git" にマッチ
    if ($leaf -match '^(?<owner>[^/\\]+)\.git$') {
        return $matches['owner']
    }
    return $null
}

$RepoOwnerId = Get-RepoOwnerId $remoteNormalized
# もし所有者が抽出できない（.git 規約破り等）場合は安全側で不一致扱いにする
if ([string]::IsNullOrWhiteSpace($RepoOwnerId)) {
    # ただし、許可プレフィックスが正確に {{USER_ID}}.git を指している場合はユーザー自身とみなす
    if ($matchedPrefix -and ($matchedPrefix -match '/([^/]+)\.git$')) {
        $RepoOwnerId = $matches[1]
    }
}

# --- STDIN（push 対象の ref 群）読取り ---
# 形式: <local ref> <local sha1> <remote ref> <remote sha1>
$updates = @()
while ($line = [Console]::In.ReadLine()) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line -split '\s+'
    if ($parts.Length -lt 4) {
        Write-Host ("pre-push: skip malformed update line: '{0}'" -f $line) -ForegroundColor DarkGray
        continue
    }
    $updates += ,@($parts[0], $parts[1], $parts[2], $parts[3])
}

# --- main への push は所有者のみ許可 ---
# remoteRef が 'refs/heads/main' の更新が含まれている場合、RepoOwnerId == USER_ID でないと拒否
foreach ($u in $updates) {
    $remoteRef = $u[2]
    if ($remoteRef -eq 'refs/heads/main') {
        if ([string]::IsNullOrWhiteSpace($RepoOwnerId)) {
            Write-Host "ERROR: リポジトリ所有者を特定できないため、main への push は許可できません。" -ForegroundColor Red
            Write-Host ("RemoteUrl (norm): {0}" -f $remoteNormalized)  -ForegroundColor DarkGray
            Write-Host ("USER_ID: {0}" -f $USER_ID) -ForegroundColor DarkGray
            exit 1
        }
        if ($RepoOwnerId -ne $USER_ID) {
            Write-Host "ERROR: main への push はリポジトリ所有者のみ許可されています。" -ForegroundColor Red
            Write-Host ("RepoOwnerId: {0}" -f $RepoOwnerId) -ForegroundColor DarkGray
            Write-Host ("USER_ID    : {0}" -f $USER_ID)      -ForegroundColor DarkGray
            Write-Host ("RemoteRef  : {0}" -f $remoteRef)    -ForegroundColor DarkGray
            exit 1
        }
        # 所有者一致なら許可（他の更新も引き続き検査）
    }
}

Write-Host ("OK: 許可されたリモートへの push [{0}] を継続します。" -f $RemoteUrl) -ForegroundColor Green
exit 0
