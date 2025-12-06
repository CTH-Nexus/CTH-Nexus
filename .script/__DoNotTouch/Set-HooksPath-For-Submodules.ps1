# Set-HooksPath-For-Submodules.ps1 (DryRun対応版 / Portable Git 対応 / 相対パス計算修正)
# 親の .script\__DoNotTouch\hooks を、親＋全サブモジュールの hooksPath に登録する
# 実行場所: 親リポジトリのワークツリーのルート
[CmdletBinding()]
param(
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- Portable Git support (.env / auto-discovery) ----------
$script:GitExe     = $null
$script:ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Get-CurrentUserId {
    try {
        $leaf = Split-Path -Leaf $env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($leaf)) { return $env:USERNAME }
        return $leaf
    } catch {
        return $env:USERNAME
    }
}

function Expand-EnvPlaceholders([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return $value }
    $v = [Environment]::ExpandEnvironmentVariables($value)  # %VAR% を展開（例: %USERPROFILE%）
    $uid = Get-CurrentUserId
    $v = $v.Replace('{{USER_ID}}', $uid)                    # {{USER_ID}} を置換（文字列置換で安全）
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

                $val = Expand-EnvPlaceholders $raw

                switch -Regex ($key.ToUpper()) {
                    '^GIT_EXE$'         { $script:GitExe = $val }
                    '^USER_ID$'         { $script:UserIdFromEnv = $val }  # 任意: 表示用途
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
    # 1) .env の GIT_EXE（展開済み）最優先
    if ($script:GitExe -and (Test-Path -LiteralPath $script:GitExe)) { return }
    # 2) ENV:GIT_EXE（展開して確認）
    if ($env:GIT_EXE) {
        $cand = Expand-EnvPlaceholders $env:GIT_EXE
        if (Test-Path -LiteralPath $cand) { $script:GitExe = $cand; return }
    }
    # 3) チーム標準: %USERPROFILE%\Software\PortableGit\cmd\git.exe
    $userProfileCand = Join-Path $env:USERPROFILE 'Software\PortableGit\cmd\git.exe'
    if (Test-Path -LiteralPath $userProfileCand) { $script:GitExe = $userProfileCand; return }
    # 4) スクリプト近傍
    $cands = @(
        (Join-Path $script:ScriptRoot 'PortableGit\cmd\git.exe'),
        (Join-Path $script:ScriptRoot 'Git\cmd\git.exe'),
        (Join-Path $script:ScriptRoot 'cmd\git.exe'),
        (Join-Path (Split-Path -Parent $script:ScriptRoot) 'PortableGit\cmd\git.exe')
    )
    foreach ($p in $cands) {
        if (Test-Path -LiteralPath $p) { $script:GitExe = $p; return }
    }
    # 5) PATH（最終手段）
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) { $script:GitExe = $cmd.Path; return }

    throw "git.exe が見つかりません。`.env` の GIT_EXE にフルパス（または %USERPROFILE%/{{USER_ID}} を含む書式）を指定するか、%USERPROFILE%\Software\PortableGit\cmd\git.exe に配置してください。"
}

function Invoke-Git {
    param([Parameter(Mandatory=$true)][string[]]$Args)
    & $script:GitExe @Args
}

# ---------- 相対パス計算（修正済み） ----------
function New-DirUri([string]$path) {
    # ディレクトリのベース URI 用に末尾セパレータを確保
    $p = $path
    if ($p -notmatch '[\\/]\s*$') { $p = $p + [System.IO.Path]::DirectorySeparatorChar }
    return [System.Uri]::new($p)
}

function Get-RelativePath([string]$From, [string]$To) {
    # From から To への相対パス（フォワードスラッシュで返す）
    $fromFull = (Resolve-Path -LiteralPath $From -ErrorAction Stop).ProviderPath
    $toFull   = (Resolve-Path -LiteralPath $To   -ErrorAction Stop).ProviderPath

    $fromItem = Get-Item -LiteralPath $fromFull -ErrorAction Stop
    $toItem   = Get-Item -LiteralPath $toFull   -ErrorAction Stop

    # 別ドライブ等で相対が引けない場合は絶対パスにフォールバック
    $rootFrom = [System.IO.Path]::GetPathRoot($fromItem.FullName)
    $rootTo   = [System.IO.Path]::GetPathRoot($toItem.FullName)
    if ($rootFrom -ne $rootTo) {
        return ($toItem.FullName -replace '\\','/')
    }

    $baseUri = New-DirUri $fromItem.FullName
    $toUri   = [System.Uri]::new($toItem.FullName)
    $relUri  = $baseUri.MakeRelativeUri($toUri).ToString()

    return ([System.Uri]::UnescapeDataString($relUri) -replace '\\','/')
}

function Ensure-Git() {
    try {
        Invoke-Git @('--version') | Out-Null
    } catch {
        Write-Host "ERROR: git が見つかりません。" -ForegroundColor Red
        exit 1
    }
}

function Set-HooksPath([string]$repoPath, [string]$hooksDirInSuper, [switch]$DryRun) {
    # repoPath: 対象リポジトリ（親 or サブモジュール）のワークツリー
    # hooksDirInSuper: 親ワークツリーにある hooks ディレクトリの絶対パス
    $rel = Get-RelativePath -From $repoPath -To $hooksDirInSuper

    if ($DryRun) {
        # 実際には書き込まず、想定適用内容を表示
        Write-Host ("[DRY-RUN] {0}`n     設定予定 core.hooksPath = {1}" -f $repoPath, $rel) -ForegroundColor DarkCyan
    } else {
        # hooksPath 登録
        Invoke-Git @('-C', "$repoPath", 'config', '--local', 'core.hooksPath', "$rel") | Out-Null
        # 確認表示（CLIのみ）
        $setVal = Invoke-Git @('-C', "$repoPath", 'config', '--local', '--get', 'core.hooksPath')
        Write-Host ("[OK] {0}`n     hooksPath = {1}" -f $repoPath, $setVal) -ForegroundColor Green
    }
}

# --- 実行開始 ---
Load-DotEnv -BasePath (Get-Location).Path
Resolve-GitExe
Ensure-Git

# 親ワークツリーの絶対パス
$superRoot = (Invoke-Git @('rev-parse', '--show-toplevel')).Trim()
if (-not $superRoot) {
    Write-Host "ERROR: 親リポジトリのルートが取得できませんでした。" -ForegroundColor Red
    exit 1
}

# hooks ディレクトリの絶対パス（親の .script\__DoNotTouch\hooks）
$hooksDir = Join-Path $superRoot '.script\__DoNotTouch\hooks'
if (-not (Test-Path -LiteralPath $hooksDir)) {
    Write-Host ("ERROR: hooks ディレクトリが見つかりません: {0}" -f $hooksDir) -ForegroundColor Red
    exit 1
}

# 親に適用（DryRunなら設定予定のみ表示）
Set-HooksPath -repoPath $superRoot -hooksDirInSuper $hooksDir -DryRun:$DryRun

# サブモジュールを初期化（未初期化がある場合）
# DryRunでも実体を把握するため実行（対象把握精度を優先）
Invoke-Git @('submodule', 'update', '--init', '--recursive') | Out-Null

# 各サブモジュールのワークツリー絶対パスを取得（再帰）
$lines = Invoke-Git @('submodule', 'foreach', '--recursive', 'git rev-parse --show-toplevel') 2>$null
$subRoots = @()
foreach ($line in $lines) {
    $t = $line.Trim()
    if ($t -match '^[A-Za-z]:\\') {
        $subRoots += $t
    }
}

# .gitmodules からのフォールバック（foreach が何も返さない場合用）
if ($subRoots.Count -eq 0 -and (Test-Path (Join-Path $superRoot '.gitmodules'))) {
    Push-Location $superRoot
    try {
        $paths = Invoke-Git @('config', '--file', '.gitmodules', '--get-regexp', '^submodule\..*\.path$') 2>$null `
            | ForEach-Object { ($_ -split '\s+', 2)[1] }
        foreach ($p in $paths) {
            $abs = Join-Path $superRoot $p
            if (Test-Path -LiteralPath $abs) { $subRoots += $abs }
        }
    } finally { Pop-Location }
}

# 適用（DryRunなら設定予定のみ表示）
foreach ($sub in $subRoots) {
    try {
        Set-HooksPath -repoPath $sub -hooksDirInSuper $hooksDir -DryRun:$DryRun
    } catch {
        Write-Host ("[WARN] 失敗: {0}  -> {1}" -f $sub, $_.Exception.Message) -ForegroundColor Yellow
    }
}

if ($DryRun) {
    Write-Host "DRY-RUN完了: 親＋全サブモジュールに対して、core.hooksPath を設定した場合の内容を表示しました（書き込みなし）。" -ForegroundColor Cyan
} else {
    Write-Host "完了: 親＋全サブモジュールの hooksPath (.git/config) に .script\__DoNotTouch\hooks を登録しました。" -ForegroundColor Cyan
}
