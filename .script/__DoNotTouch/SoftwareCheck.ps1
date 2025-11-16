[CmdletBinding()]
param(
    [string]$UserID = $env:USERNAME,
    # 既定は未設定：未指定ならフォルダ選択ダイアログを表示
    [string]$SharedFolder,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ===== 実行ドライブを安全に特定（PSScriptRoot → PSCommandPath → 現在ディレクトリ） =====
function Get-ExecutionDriveRoot {
    $candidates = @($PSCommandPath, $PSScriptRoot, $pwd.Path) | Where-Object { $_ }
    foreach ($path in $candidates) {
        try {
            $root = [System.IO.Path]::GetPathRoot($path)
            if ($root -and $root -match '^[A-Za-z]:\\$') { return $root }
        } catch {}
    }
    # フォールバック：システムドライブ（例: C:\）
    return ($env:SystemDrive + '\')
}

$BaseDriveRoot = Get-ExecutionDriveRoot
$UserRoot      = Join-Path $BaseDriveRoot ("Users\{0}" -f $UserID)
Write-Host ("[INFO] 実行ドライブ: {0} / ユーザー基点: {1}" -f $BaseDriveRoot, $UserRoot)

# ===== 既定配置（最終形）— 実行ドライブに合わせる =====
$Paths = @{
    Obsidian = Join-Path $UserRoot 'AppData\Local\Programs\Obsidian'
    Git      = Join-Path $UserRoot 'Software\PortableGit'
    VSCode   = Join-Path $UserRoot 'Software\VSCode'
}

# 共有内ファイル名パターン
$SearchPatterns = @{
    Obsidian = @('Obsidian*')
    Git      = @('PortableGit*','Git*')
    VSCode   = @('VSCode*','Code*')
}

# 実行中チェック用のプロセス名マップ
$ProcessMap = @{
    Obsidian = @('Obsidian')
    VSCode   = @('Code')
    Git      = @('git','git-bash','git-cmd')
}

# ===== ログ（CLIのみ） =====
function Write-Section([string]$msg) { Write-Host "`n[CHECK] $msg" }
function Write-Info   ([string]$msg) { Write-Host "[INFO]  $msg" }
function Write-Warn   ([string]$msg) { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err    ([string]$msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red }

# ===== ネットワークドライブの候補（初期選択） =====
function Get-PreferredNetworkRoot {
    $preferred = @('R:','Y:','Z:')
    try {
        $net = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=4" -ErrorAction Stop |
               Sort-Object -Property DeviceID
        if ($net) {
            $hit = $net | Where-Object { $preferred -contains $_.DeviceID } | Select-Object -First 1
            if ($hit) { return ($hit.DeviceID + '\') }
            return ($net[0].DeviceID + '\')
        }
    } catch {}
    return $null
}

# ===== 共有フォルダ選択（既定で表示） =====
function Select-SharedFolder {
    param([string]$Current)
    try {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "インストーラが置かれている共有フォルダを選択してください（ネットワークドライブ可）"
        $dlg.RootFolder  = [System.Environment+SpecialFolder]::MyComputer
        if ([string]::IsNullOrWhiteSpace($Current) -or -not (Test-Path -LiteralPath $Current)) {
            $initial = Get-PreferredNetworkRoot
            if ($initial -and (Test-Path -LiteralPath $initial)) { $dlg.SelectedPath = $initial }
        } else {
            $dlg.SelectedPath = $Current
        }
        $result = $dlg.ShowDialog()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
        return $null
    } catch {
        Write-Warn "フォルダ選択ダイアログの初期化に失敗: $($_.Exception.Message)"
        return $null
    }
}

# 既定挙動：未指定なら選ばせる
if ([string]::IsNullOrWhiteSpace($SharedFolder)) {
    $SharedFolder = Select-SharedFolder
    if ([string]::IsNullOrWhiteSpace($SharedFolder)) {
        throw "共有フォルダが未選択のため処理を中止します。-SharedFolder で明示指定も可能です。"
    }
} elseif (-not (Test-Path -LiteralPath $SharedFolder)) {
    Write-Warn "指定の共有フォルダが存在しません: $SharedFolder"
    $picked = Select-SharedFolder -Current $SharedFolder
    if ([string]::IsNullOrWhiteSpace($picked)) {
        throw "有効な共有フォルダが選択されなかったため処理を中止します。"
    }
    $SharedFolder = $picked
}
Write-Info "共有フォルダ: $SharedFolder"

# ===== バージョン正規化 =====
function Get-NormalizedVersion {
    param([string]$text)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $m = [regex]::Match($text, '(\d+(?:\.\d+){1,3})')
    if ($m.Success) { try { return [version]$m.Groups[1].Value } catch {} }

    $nums = [regex]::Matches($text, '\d+')
    if ($nums.Count -ge 2) {
        $take   = [Math]::Min(4, $nums.Count)
        $verStr = ($nums[0..($take-1)].Value -join '.')
        try { return [version]$verStr } catch { return $null }
    }
    return $null
}

# ===== インストーラ探索（配列収集→安全にフィルタ） =====
function Find-LatestInstaller {
    param(
        [string]$SoftwareName,
        [string]$SharedFolder,
        [string[]]$Patterns
    )

    if (-not (Test-Path $SharedFolder)) {
        Write-Err "共有フォルダが存在しません: $SharedFolder"
        return $null
    }

    $files = @()
    foreach ($pat in $Patterns) {
        $found = Get-ChildItem -Path $SharedFolder -File -Filter $pat -ErrorAction SilentlyContinue
        if ($found) { $files += $found }
    }
    if (-not $files -or $files.Count -eq 0) { return $null }

    $filtered = @()
    foreach ($f in $files) {
        if ($f.Name -notmatch '(?i)\bold\b') { $filtered += $f }
    }
    if (-not $filtered -or $filtered.Count -eq 0) { return $null }

    $enriched = foreach ($f in $filtered) {
        [PSCustomObject]@{
            FileInfo = $f
            Version  = Get-NormalizedVersion $f.Name
            Updated  = $f.LastWriteTime
            Ext      = $f.Extension.ToLowerInvariant()
        }
    }

    $enriched |
        Sort-Object -Property @{Expression='Version';Descending=$true},
                               @{Expression='Updated';Descending=$true} |
        Select-Object -First 1
}

# ===== インストール済みバージョン取得（VSCodeは ProductVersion のみ） =====
function Get-InstalledVersion {
    param([string]$Software, [string]$Path)

    switch ($Software) {
        'Obsidian' {
            $exe = Join-Path $Path 'Obsidian.exe'
            if (Test-Path $exe) { return Get-NormalizedVersion (Get-Item $exe).VersionInfo.ProductVersion }
        }
        'Git' {
            $exe = Join-Path $Path 'bin\git.exe'
            if (Test-Path $exe) {
                $out = & $exe --version 2>&1
                if ($out) { return Get-NormalizedVersion $out }
            }
        }
        'VSCode' {
            $exe = Join-Path $Path 'Code.exe'
            if (Test-Path $exe) {
                $pv = (Get-Item $exe).VersionInfo.ProductVersion
                if ($pv) { return Get-NormalizedVersion $pv }
            }
        }
    }
    return $null
}

# ===== 実行中プロセスの有無を検査し、見つかれば中断（Killはしない） =====
function Assert-AppNotRunningOrStop {
    param(
        [Parameter(Mandatory)][string]$Software,
        [Parameter(Mandatory)][string[]]$ProcessNames
    )
    $running = @()
    foreach ($n in $ProcessNames) {
        $p = Get-Process -Name $n -ErrorAction SilentlyContinue
        if ($p) { $running += $p }
    }
    if ($running -and $running.Count -gt 0) {
        Write-Err ("{0} の更新を中止します。{0} が実行中です。対象アプリを終了してから、再実行してください。" -f $Software)
        foreach ($proc in $running) {
            $start = $null
            try { $start = $proc.StartTime } catch {}
            if ($start) { Write-Host ("  - {0} (PID {1}, Start {2:yyyy-MM-dd HH:mm:ss})" -f $proc.ProcessName, $proc.Id, $start) }
            else        { Write-Host ("  - {0} (PID {1})" -f $proc.ProcessName, $proc.Id) }
        }
        throw "実行中のため中断: $Software"
    }
}

# ===== フォルダ平坦化（中間サブフォルダ排除） =====
function Flatten-ToRoot {
    param(
        [Parameter(Mandatory)][string]$TargetDir,
        [string[]]$MustExistFiles,
        [string[]]$MustExistDirs
    )

    function Test-FinalShape {
        param($Dir,$Files,$Dirs)
        foreach ($f in ($Files | Where-Object { $_ })) { if (-not (Test-Path (Join-Path $Dir $f))) { return $false } }
        foreach ($d in ($Dirs  | Where-Object { $_ })) { if (-not (Test-Path (Join-Path $Dir $d))) { return $false } }
        return $true
    }

    if (Test-FinalShape -Dir $TargetDir -Files $MustExistFiles -Dirs $MustExistDirs) { return }

    for ($i=0; $i -lt 2; $i++) {
        if (Test-FinalShape -Dir $TargetDir -Files $MustExistFiles -Dirs $MustExistDirs) { break }
        $children = Get-ChildItem -LiteralPath $TargetDir -Force
        $subdirs  = $children | Where-Object { $_.PSIsContainer }
        $files    = $children | Where-Object { -not $_.PSIsContainer }
        if (($subdirs.Count -eq 1) -and ($files.Count -eq 0)) {
            $inner = $subdirs[0].FullName
            Write-Info "平坦化: $inner → $TargetDir"
            Get-ChildItem -LiteralPath $inner -Force | ForEach-Object {
                $dest = Join-Path $TargetDir $_.Name
                if (Test-Path $dest) {
                    if ($_.PSIsContainer) { Copy-Item -Recurse -Force -Path $_.FullName -Destination $dest }
                    else { Copy-Item -Force -Path $_.FullName -Destination $dest }
                } else {
                    Move-Item -Force -Path $_.FullName -Destination $TargetDir
                }
            }
            try { Remove-Item -Recurse -Force -LiteralPath $inner } catch {}
        } else {
            break
        }
    }
}

# ===== SFX(.7z.exe) の静音展開 =====
function Expand-7zSfx {
    param(
        [Parameter(Mandatory)][string]$SfxPath,
        [Parameter(Mandatory)][string]$DestDir
    )
    if (-not (Test-Path $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir | Out-Null
    }
    Start-Process -FilePath $SfxPath -ArgumentList @('-y',("-o$DestDir")) -Wait -WindowStyle Hidden
}

# ===== 一般的な EXE セットアップの静音試行 =====
function Install-ExeSilent {
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [string]$TargetPath,
        [string[]]$ExtraArgs = @()  # 例: /MERGETASKS=!runcode
    )
    $attempts = @()
    if ($TargetPath) {
        $attempts += '/VERYSILENT /SP- /NORESTART /DIR="{0}"' -f $TargetPath
        $attempts += '/SILENT /SP- /NORESTART /DIR="{0}"'    -f $TargetPath
        $attempts += '/S /DIR="{0}"'                          -f $TargetPath
    } else {
        $attempts += '/VERYSILENT /SP- /NORESTART'
        $attempts += '/SILENT /SP- /NORESTART'
        $attempts += '/S'
    }

    foreach ($a in $attempts) {
        try {
            $arg = $a
            if ($ExtraArgs -and $ExtraArgs.Count -gt 0) { $arg = "$a $($ExtraArgs -join ' ')" }
            Start-Process -FilePath $ExePath -ArgumentList $arg -Wait -WindowStyle Hidden
            return $true
        } catch {
            Write-Warn "静音インストールスイッチ失敗: $a"
        }
    }
    return $false
}

# ===== インストール／更新 =====
function Install-Software {
    param(
        [Parameter(Mandatory)][string]$Software,
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string]$TargetPath,
        [switch]$DryRun
    )

    if ($DryRun) {
        Write-Info "[DRY-RUN] $Software をインストール予定: $InstallerPath → $TargetPath"
        return
    }

    if (-not (Test-Path $TargetPath)) { New-Item -ItemType Directory -Path $TargetPath | Out-Null }
    $ext = [System.IO.Path]::GetExtension($InstallerPath).ToLowerInvariant()

    switch ($Software) {
        'Obsidian' {
            Write-Info "Obsidian は既定のユーザフォルダに対話インストールされます。インストーラを起動します。"
            Start-Process -FilePath $InstallerPath
            Write-Info "完了後に本スクリプトを再実行してください。"
        }
        'Git' {
            Write-Info "Git を導入中..."
            if ($InstallerPath -match '(?i)\.7z\.exe$' -or $InstallerPath -match '(?i)7z') {
                Expand-7zSfx -SfxPath $InstallerPath -DestDir $TargetPath
            } elseif ($ext -eq '.zip') {
                Expand-Archive -Path $InstallerPath -DestinationPath $TargetPath -Force
            } elseif ($ext -eq '.exe') {
                $ok = Install-ExeSilent -ExePath $InstallerPath -TargetPath $TargetPath
                if (-not $ok) { Write-Warn "Git の静音インストールに失敗。対話で起動します。"; Start-Process -FilePath $InstallerPath }
            } else {
                throw "Git: 未対応拡張子: $InstallerPath"
            }
            Flatten-ToRoot -TargetDir $TargetPath -MustExistFiles @('git-bash.exe','git-cmd.exe') -MustExistDirs @('bin','usr')
        }
        'VSCode' {
            Write-Info "VSCode を導入中..."
            if ($ext -eq '.zip') {
                Expand-Archive -Path $InstallerPath -DestinationPath $TargetPath -Force
                Flatten-ToRoot -TargetDir $TargetPath -MustExistFiles @('Code.exe') -MustExistDirs @('resources')
            } elseif ($ext -eq '.exe') {
                # 起動抑止：インストール後の runcode タスクを無効化
                $ok = Install-ExeSilent -ExePath $InstallerPath -ExtraArgs @('/MERGETASKS=!runcode')
                if (-not $ok) { Write-Warn "VSCode の静音インストールに失敗。対話で起動します。"; Start-Process -FilePath $InstallerPath }
            } else {
                throw "VSCode: 未対応拡張子: $InstallerPath"
            }
        }
    }
}

# ===== メイン =====
foreach ($software in $Paths.Keys) {
    Write-Section $software

    $path = $Paths[$software]
    $installedVer = Get-InstalledVersion -Software $software -Path $path

    $latest = Find-LatestInstaller -SoftwareName $software -SharedFolder $SharedFolder -Patterns $SearchPatterns[$software]
    if (-not $latest) {
        Write-Warn "$software のインストーラが共有フォルダで見つかりません。スキップします。"
        continue
    }

    $latestVer     = $latest.Version
    $installerPath = $latest.FileInfo.FullName

    if ($installedVer) {
        if ($latestVer) { Write-Info ("現在: {0} / 最新: {1}" -f $installedVer, $latestVer.ToString()) }
        else            { Write-Info ("現在: {0} / 最新: 不明" -f $installedVer) }
    } else {
        if ($latestVer) { Write-Info ("現在: 未インストール / 最新: {0}" -f $latestVer.ToString()) }
        else            { Write-Info ("現在: 未インストール / 最新: 不明") }
    }

    $needInstall = $false
    $isUpdate    = $false  # 既存ありかつ更新が必要な場合のみ true

    if (-not $installedVer) {
        $needInstall = $true
        Write-Info "$software を新規導入します。"
    } elseif ($latestVer -and ($installedVer -lt $latestVer)) {
        $needInstall = $true
        $isUpdate    = $true
        Write-Info "$software を更新します。"
    } elseif (-not $latestVer) {
        Write-Warn "最新インストーラのバージョンが判定できません。安全側で更新は見合わせます。"
    } else {
        Write-Info "$software は最新または同等です。（$installedVer）"
    }

    # 既存が起動中なら、更新を中止して終了依頼を表示 → スクリプト全体を停止
    if ($needInstall -and $isUpdate) {
        $procNames = $ProcessMap[$software]
        if ($procNames) { Assert-AppNotRunningOrStop -Software $software -ProcessNames $procNames }
    }

    if ($needInstall) {
        Install-Software -Software $software -InstallerPath $installerPath -TargetPath $path -DryRun:$DryRun
    }
}

Write-Host "`n[INFO] 全ての処理が完了しました。"
