# Set-HooksPath-For-Submodules.ps1
# 親の .script\__DoNotTouch\hooks を、親＋全サブモジュールの hooksPath に登録する
# 実行場所: 親リポジトリのワークツリーのルート

$ErrorActionPreference = 'Stop'

function Ensure-Git() {
    try { git --version | Out-Null } catch {
        Write-Host "ERROR: git が見つかりません。" -ForegroundColor Red
        exit 1
    }
}

function Get-RelativePath([string]$From, [string]$To) {
    # From から To への相対パス（フォワードスラッシュで返す）
    $fromFull = (Resolve-Path -LiteralPath $From).ProviderPath
    $toFull   = (Resolve-Path -LiteralPath $To).ProviderPath

    $fromUri  = [System.Uri]((Get-Item -LiteralPath $fromFull).FullName)
    $toUri    = [System.Uri]((Get-Item -LiteralPath $toFull).FullName)

    # 別ドライブ等で相対が引けない場合は絶対パスにフォールバック
    $rootFrom = [System.IO.Path]::GetPathRoot($fromFull)
    $rootTo   = [System.IO.Path]::GetPathRoot($toFull)
    if ($rootFrom -ne $rootTo) {
        return ($toFull -replace '\\','/')
    }

    $relUri = $fromUri.MakeRelativeUri($toUri).ToString()
    return ([System.Uri]::UnescapeDataString($relUri) -replace '\\','/')
}

function Set-HooksPath([string]$repoPath, [string]$hooksDirInSuper) {
    # repoPath: 対象リポジトリ（親 or サブモジュール）のワークツリー
    # hooksDirInSuper: 親ワークツリーにある hooks ディレクトリの絶対パス
    $rel = Get-RelativePath -From $repoPath -To $hooksDirInSuper

    # hooksPath 登録
    git -C "$repoPath" config --local core.hooksPath "$rel" | Out-Null

    # 確認表示（CLIのみ）
    $setVal = git -C "$repoPath" config --local --get core.hooksPath
    Write-Host ("[OK] {0}`n     hooksPath = {1}" -f $repoPath, $setVal) -ForegroundColor Green
}

# --- 実行開始 ---
Ensure-Git

# 親ワークツリーの絶対パス
$superRoot = (git rev-parse --show-toplevel).Trim()
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

# 親に適用
Set-HooksPath -repoPath $superRoot -hooksDirInSuper $hooksDir

# サブモジュールを初期化（未初期化がある場合）
git submodule update --init --recursive | Out-Null

# 各サブモジュールのワークツリー絶対パスを取得（再帰）
# foreach 内で 'git rev-parse --show-toplevel' を実行して、Windows 絶対パスを受け取る
$lines = git submodule foreach --recursive 'git rev-parse --show-toplevel' 2>$null
$subRoots = @()
foreach ($line in $lines) {
    $t = $line.Trim()
    # 例: C:\path\to\submodule または R:\path\to\submodule
    if ($t -match '^[A-Za-z]:\\') {
        $subRoots += $t
    }
}

# .gitmodules からのフォールバック（foreach が何も返さない場合用）
if ($subRoots.Count -eq 0 -and (Test-Path (Join-Path $superRoot '.gitmodules'))) {
    Push-Location $superRoot
    try {
        $paths = git config --file .gitmodules --get-regexp '^submodule\..*\.path$' 2>$null `
            | ForEach-Object { ($_ -split '\s+', 2)[1] }
        foreach ($p in $paths) {
            $abs = Join-Path $superRoot $p
            if (Test-Path -LiteralPath $abs) { $subRoots += $abs }
        }
    } finally { Pop-Location }
}

# 適用
foreach ($sub in $subRoots) {
    try {
        Set-HooksPath -repoPath $sub -hooksDirInSuper $hooksDir
    } catch {
        Write-Host ("[WARN] 失敗: {0}  -> {1}" -f $sub, $_.Exception.Message) -ForegroundColor Yellow
    }
}

Write-Host "完了: 親＋全サブモジュールの hooksPath (.git/config) に .script\__DoNotTouch\hooks を登録しました。" -ForegroundColor Cyan
