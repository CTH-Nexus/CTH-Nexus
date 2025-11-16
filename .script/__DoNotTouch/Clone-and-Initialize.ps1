<#
Clone-and-Initialize.ps1

更新点（セキュリティ／誤指定防止強化）:
  - UNC 実在確認後に net use 実行（到達不可なら即停止）
  - 引数は名前付きのみ（PositionalBinding=$false）
  - repoPath の許可範囲を R:\UsersVault\{NAME}.git のみへ厳格化
  - teamRepo はフルパス必須 / R:\{NAME}.git のみ許可（直下1階層）、存在＆ベアRepo簡易チェック
  - net use の戻りコード／R: 再確認で異常を検知
  - ベアリポジトリ簡易検証（config/objects/refs が存在するか）

仕様（変わらず）:
  1) R: のドライブ準備（既存なら情報表示のみ、無いなら UNC 実在確認の上 net use）
  2) %USERPROFILE%\MyVault に clone (--recurse-submodules)
  3) clone 先へカレント移動
  4) upstream を追加/更新（pushUrl を DISABLE）
  5) .script\__DoNotTouch\Git-ConfigCheck.ps1 を起動（失敗で停止）
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    # Step 1: net use に渡す UNC パス（例：\\fileserver\ICS\UsersVault）
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\\\\')] # UNC 形式
    [Alias('rShareUNC')]
    [string]$rShareUNC,

    # Step 2: clone の対象（R:\UsersVault\{NAME}.git のみ許可）
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^R:\\UsersVault\\[^\\]+\.git$')]
    [Alias('repoPath')]
    [string]$repoPath,

    # Step 4: upstream の対象（R:\{TEAM_REPO}.git のみ許可／直下1階層）
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^R:\\[^\\]+\.git$')]
    [Alias('teamRepo')]
    [string]$teamRepo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level,
        [string]$Message
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $color = switch ($Level) { 'INFO' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} default {'White'} }
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
}

function Assert-BareRepo {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "指定パスが存在しません: $Path"
    }
    # ベアリポジトリ簡易検証（最低限の構造）
    $hasConfig  = Test-Path -LiteralPath (Join-Path $Path 'config')
    $hasObjects = Test-Path -LiteralPath (Join-Path $Path 'objects')
    $hasRefs    = Test-Path -LiteralPath (Join-Path $Path 'refs')
    if (-not ($hasConfig -and $hasObjects -and $hasRefs)) {
        throw "ベアリポジトリではない可能性があります（config/objects/refs のいずれかが欠落）: $Path"
    }
}

# ===== PortableGit の git.exe =====
$UserId = $env:USERNAME
$GitExe = "D:\Users\$UserId\Software\PortableGit\cmd\git.exe"
if (-not (Test-Path -LiteralPath $GitExe)) {
    Write-Log ERROR "PortableGit が見つかりません: $GitExe`n期待配置: D:\Users\{USER_ID}\Software\PortableGit\cmd\git.exe"
    exit 1
}
Write-Log INFO "Git 実行ファイル: $GitExe"

# ===== Step 1: R ドライブの準備 =====
try {
    $rDrive = Get-PSDrive -Name R -ErrorAction SilentlyContinue
    if ($null -ne $rDrive) {
        Write-Log INFO "R: ドライブは既に存在します。net use 情報を表示します。"
        cmd.exe /c "net use R:" | ForEach-Object { Write-Host $_ }
    } else {
        Write-Log INFO "UNC 実在確認: $rShareUNC"
        if (-not (Test-Path -LiteralPath $rShareUNC)) {
            throw "指定された UNC が存在しません、またはアクセスできません: $rShareUNC"
        }

        Write-Log INFO "R: ドライブをマウントします -> $rShareUNC"
        cmd.exe /c "net use R: `"$rShareUNC`" /persistent:no"
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "net use 失敗（ExitCode=$exitCode）。資格情報や到達性をご確認ください。"
        }

        # 再確認
        $rDrive2 = Get-PSDrive -Name R -ErrorAction SilentlyContinue
        if ($null -eq $rDrive2) {
            throw "R: のマウントに失敗しました（net use 成功後も R: が存在しません）。"
        }
        Write-Log INFO "R: ドライブのマウントに成功しました。"
    }
} catch {
    Write-Log ERROR ("R ドライブ準備中に失敗: " + $_.Exception.Message)
    exit 1
}

# ===== Step 2: MyVault へ clone =====
$VaultPath = Join-Path $env:USERPROFILE 'MyVault'

try {
    if (Test-Path -LiteralPath $VaultPath) {
        Write-Log ERROR "既に MyVault が存在するため停止します: $VaultPath"
        Write-Log INFO  "既存フォルダの内容（上位のみ）:"
        Get-ChildItem -LiteralPath $VaultPath -Force | Select-Object Mode, Length, LastWriteTime, Name | Format-Table -AutoSize
        exit 1
    }

    # repoPath は R:\UsersVault\{NAME}.git のみ許可、存在・ベア判定
    Assert-BareRepo -Path $repoPath

    Write-Log INFO "clone を開始します（--recurse-submodules）: $repoPath -> $VaultPath"
    & $GitExe clone --recurse-submodules --progress -- "$repoPath" "$VaultPath"
    Write-Log INFO "clone 完了。"
} catch {
    Write-Log ERROR ("clone 中に失敗: " + $_.Exception.Message)
    exit 1
}

# ===== Step 3: カレントディレクトリ移動 =====
try {
    Set-Location -LiteralPath $VaultPath
    Write-Log INFO "カレントディレクトリを移動しました: $VaultPath"
} catch {
    Write-Log ERROR ("Set-Location 失敗: " + $_.Exception.Message)
    exit 1
}

# ===== Step 4: upstream の設定（R:\{NAME}.git のみ許可、存在＆ベア判定）=====
try {
    Assert-BareRepo -Path $teamRepo
    Write-Log INFO "upstream を設定します: $teamRepo"

    # 既存チェック
    $existingUpstreamUrl = ''
    try { $existingUpstreamUrl = (& $GitExe -C "$VaultPath" remote get-url upstream 2>$null) } catch { $existingUpstreamUrl = '' }

    if ([string]::IsNullOrWhiteSpace($existingUpstreamUrl)) {
        & $GitExe -C "$VaultPath" remote add upstream "$teamRepo"
        Write-Log INFO "remote add upstream 実行。"
    } else {
        Write-Log WARN "upstream は既に存在しています（更新します）: $existingUpstreamUrl -> $teamRepo"
        & $GitExe -C "$VaultPath" remote set-url upstream "$teamRepo"
    }

    # pushUrl を DISABLE に設定（push禁止）
    & $GitExe -C "$VaultPath" remote set-url --push upstream DISABLE
    Write-Log INFO "upstream の pushUrl を DISABLE に設定しました。"
} catch {
    Write-Log ERROR ("upstream 設定中に失敗: " + $_.Exception.Message)
    exit 1
}

# ===== Step 5: リポジトリ直下で別スクリプトを起動（独立プロセスで実行）=====
$PostScript = Join-Path $VaultPath ".script\__DoNotTouch\Git-ConfigCheck.ps1"

try {
    if (-not (Test-Path -LiteralPath $PostScript)) {
        throw "起動対象スクリプトが見つかりません: $PostScript"
    }

    # 実行する PowerShell 実体の決定（基本は Windows PowerShell）
    $psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $psExe)) {
        throw "powershell.exe が見つかりません: $psExe"
    }

    # 引数の組み立て
    $psArgs = @(
        '-ExecutionPolicy', 'Bypass',
        '-NoProfile',
        '-STA',
        '-File', "`"$PostScript`""
    ) -join ' '

    Write-Log INFO "Git-ConfigCheck.ps1 を独立プロセスで起動します。"
    Write-Log INFO "Cmd: $psExe $psArgs"

    # 実行（Wait/PassThru で ExitCode を取得）
    $proc = Start-Process -FilePath $psExe `
                          -ArgumentList $psArgs `
                          -WorkingDirectory $VaultPath `
                          -NoNewWindow `
                          -Wait `
                          -PassThru

    $exit = $proc.ExitCode
    if ($exit -ne 0) {
        throw "Git-ConfigCheck.ps1 が異常終了しました。ExitCode=$exit"
    }

    Write-Log INFO "Git-ConfigCheck.ps1 実行完了（ExitCode=0）。"
} catch {
    Write-Log ERROR ("起動に失敗: " + $_.Exception.Message)
    exit 1
}


Write-Log INFO "全ステップ完了。"
exit 0
