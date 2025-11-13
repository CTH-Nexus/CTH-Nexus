#!/usr/bin/env pwsh
# pre-push hook (PowerShell)
# 許可されたリモートURL以外への push を禁止（Rドライブ前提）
# ホワイトリスト中の {USER_ID} は %USERPROFILE% の末尾フォルダ名で置換

param(
    [string]$RemoteName,
    [string]$RemoteUrl
)

# --- USER_ID を USERPROFILE から抽出 ---
# 例) C:\Users\kubo → "kubo"
$USER_ID = Split-Path -Leaf $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($USER_ID)) {
    Write-Host "ERROR: USER_ID を %USERPROFILE% から取得できませんでした。" -ForegroundColor Red
    Write-Host ("USERPROFILE: {0}" -f $env:USERPROFILE) -ForegroundColor DarkGray
    exit 1
}

# --- URL 正規化関数（表記揺れの吸収） ---
function Normalize-Url([string]$u) {
    if ([string]::IsNullOrWhiteSpace($u)) { return "" }
    $n = $u.Trim()

    # file://形式を削除 → R:/repos/.. に寄せる
    $n = $n -replace '^file://+',''

    # バックスラッシュをスラッシュに統一
    $n = $n -replace '\\','/'

    # R:\ → R:/、大文字小文字のゆれも吸収
    $n = $n -replace '^[rR]:\\','R:/'
    $n = $n -replace '^[rR]:/','R:/'

    # 末尾スラッシュは除去
    $n = $n.TrimEnd('/')

    return $n
}

# --- ホワイトリスト（Rドライブのみ。UNCは不可） ---
# {USER_ID} を USERPROFILE に基づく ID で置換
$allowedTemplates = @(
    'R:\UsersVault\{USER_ID}.git',
    'R:\Submodule\Member\{USER_ID}.git',
    'R:\Submodule\Shared\User\{USER_ID}.git',
    'R:\Submodule\Shared\Project\{USER_ID}.git'
)

# 置換＋正規化
$allowedNormalized = foreach ($t in $allowedTemplates) {
    $path = $t -replace '\{USER_ID\}', [Regex]::Escape($USER_ID)
    Normalize-Url $path
}

# リモートURLの正規化
$remoteNormalized = Normalize-Url $RemoteUrl

# --- 許可判定（前方一致） ---
$allowed = $false
foreach ($a in $allowedNormalized) {
    if ($remoteNormalized -like "$a*") {
        $allowed = $true
        break
    }
}

# --- 結果 ---
if (-not $allowed) {
    Write-Host "ERROR: 許可外のリモートURLへの push は禁止されています。" -ForegroundColor Red
    Write-Host ("RemoteName: {0}" -f $RemoteName) -ForegroundColor DarkGray
    Write-Host ("RemoteUrl : {0}" -f $RemoteUrl)  -ForegroundColor DarkGray
    Write-Host "許可リスト（正規化後）：" -ForegroundColor Yellow
    $allowedNormalized | ForEach-Object { Write-Host ("  - {0}" -f $_) -ForegroundColor Yellow }
    exit 1
}

Write-Host ("OK: 許可されたリモートへの push [{0}] を継続します。" -f $RemoteUrl) -ForegroundColor Green
exit 0
