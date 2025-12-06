
#Requires -Version 5.1

# --- Script Configuration ---
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ============================================================
# Utilities
# ============================================================
function Resolve-GitExe {
    <#
      .SYNOPSIS
        Git実行ファイルの場所を解決する（PATH非前提）。
      .DESCRIPTION
        優先順:
          1) $env:GIT_EXE が指定されていればそれ
          2) %USERPROFILE%\Software\PortableGit\cmd\git.exe
          3) PATH 上の 'git'
      .OUTPUTS
        [string] 既定で使う git.exe のフルパス or 'git'
    #>
    $candidates = @()

    if ($env:GIT_EXE) {
        $candidates += $env:GIT_EXE
    }

    $portable = Join-Path $env:USERPROFILE "Software\PortableGit\cmd\git.exe"
    $candidates += $portable

    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) { return $p }
    }

    # 最後に 'git'（PATH 前提）へフォールバック
    return "git"
}
# グローバル既定 GitExe（必要なら Main の引数で上書き可能）
$Script:GitExe = Resolve-GitExe

function Invoke-GitCommand {
    param (
        [Parameter(Mandatory)]
        [string]$Arguments,

        [Parameter(Mandatory)]
        [string]$ErrorMessage
    )

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $Script:GitExe
    $processInfo.Arguments = $Arguments
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError  = $true
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.WorkingDirectory = (Get-Location).Path

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo

    # 起動だけの try/catch（PowerShell レベルの失敗用）
    try {
        $process.Start() | Out-Null
    } catch {
        Write-Warning "Failed to start git process: $($Script:GitExe) $Arguments"
        Write-Warning "Original Exception: $($_.ToString())"
        if ($_.Exception.Message -match "Operation manually stopped" -or $_.Exception.Message -match "中断") {
            throw $_.Exception
        }
        throw "PowerShell failed to start git process for: git $Arguments. Reason: $($_.Exception.Message)"
    }

    $process.WaitForExit()

    # 出力は終了後にまとめて同期読み込み
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()

    # 重複防止しつつコンソールへ表示
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        Write-Host $stdout.TrimEnd()
    }
    if ((-not [string]::IsNullOrWhiteSpace($stderr)) -and ($stderr -ne $stdout)) {
        Write-Host $stderr.TrimEnd()
    }

    $FullOutputString = "$stdout`n$stderr"

    if ($process.ExitCode -ne 0) {
        Write-Warning "Git command failed: $($Script:GitExe) $Arguments"
        Write-Warning "Exit Code: $($process.ExitCode)"
        Write-Warning "Output (stdout + stderr): $FullOutputString"

        if ($process.ExitCode -eq 130 -or $FullOutputString -match "signal 2" -or $FullOutputString -match "中断") {
            throw "Operation manually stopped (Ctrl+C). ($ErrorMessage)"
        }
        throw $ErrorMessage
    }

    return $stdout
}

function Invoke-GitRaw {
    <#
      .SYNOPSIS
        失敗時も例外を投げず ExitCode を返す低レベル呼び出し。
      .DESCRIPTION
        例: ls-remote の ExitCode 2 を「ブランチ無し」として扱いたいケースで使用。
      .OUTPUTS
        PSCustomObject @{ ExitCode; StdOut; StdErr }
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Script:GitExe
    $psi.Arguments = $Arguments
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = (Get-Location).Path

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi

    try {
        $p.Start() | Out-Null
    } catch {
        # 起動失敗は致命的とみなし例外
        throw "Failed to start git process (raw): $($Script:GitExe) $Arguments. Reason: $($_.Exception.Message)"
    }

    $p.WaitForExit()

    [pscustomobject]@{
        ExitCode = $p.ExitCode
        StdOut   = $p.StandardOutput.ReadToEnd()
        StdErr   = $p.StandardError.ReadToEnd()
    }
}

# ============================================================
# Top-level steps (Main orchestration)
# ============================================================
function Select-IdListFile {
    Add-Type -AssemblyName System.Windows.Forms
    $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $fileDialog.Title = "Select User ID List File"
    $fileDialog.Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*"
    $fileDialog.InitialDirectory = $PSScriptRoot

    try {
        if ($fileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $fileDialog.FileName
        }
    } catch {
        Write-Warning "Failed to show file dialog. Attempting to find 'id_list.txt' in script directory."
        $fallbackPath = Join-Path $PSScriptRoot "id_list.txt"
        if (Test-Path $fallbackPath) { return $fallbackPath }
    }
    return $null
}

function Get-UserIdsFromFile {
    param([Parameter(Mandatory)][string]$IdListFile)

    try {
        $raw = Get-Content $IdListFile |
               ForEach-Object { $_.Trim() } |
               Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
               ForEach-Object { $_.TrimEnd('\') }

        $ids = @($raw)
        if ($ids.Count -eq 0) {
            throw "ID list file '$IdListFile' is empty or contains no valid IDs."
        }
        return $ids
    } catch {
        throw "Failed to read ID list file: $IdListFile. Reason: $($_.Exception.Message)"
    }
}

function Initialize-WorkDirectory {
    param([Parameter(Mandatory)][string]$WorkRootDir,
          [Parameter(Mandatory)][string]$IdListFile)

    [System.IO.Directory]::CreateDirectory($WorkRootDir) | Out-Null

    $hashPrefix = 'nohash'
    try {
        if (Test-Path $IdListFile) {
            $hashPrefix = (Get-FileHash -Algorithm SHA256 -Path $IdListFile).Hash.Substring(0,8)
        }
    } catch {
        # 失敗時は nohash のまま
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmssfff'
    $RunKey    = "{0}_{1}_pid{2}" -f $timestamp, $hashPrefix, $PID
    $WorkBaseDir = Join-Path $WorkRootDir $RunKey

    Write-Host "Creating per-run work directory at: $WorkBaseDir"
    [System.IO.Directory]::CreateDirectory($WorkBaseDir) | Out-Null
    return $WorkBaseDir
}

function Select-SourceRepository {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "ソースリポジトリのフォルダを選択してください（例：R:\Knewrova.git）"
    $dlg.ShowNewFolderButton = $false
    $res = $dlg.ShowDialog()
    if ($res -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dlg.SelectedPath
    } else {
        Write-Warning "ソースリポジトリの選択がキャンセルされました。処理を中止します。"
        return $null
    }
}

function Process-AllUsers {
    <#
      .SYNOPSIS
        全ユーザ処理のドライバ。個別処理（Ensure/Assert/Clone/Configure/Checkout/Configure/Test/Invoke）を呼び出す。
    #>
    param(
        [Parameter(Mandatory)][string]$WorkBaseDir,
        [Parameter(Mandatory)][string]$SourceRepoPath,
        [Parameter(Mandatory)][string[]]$UserIDs
    )

    $totalUsers   = $UserIDs.Count
    $globalSuccess = $true
    $manualStop    = $false

    Write-Host "--- Found $totalUsers users ---"

    $currentUserIndex = 0
    foreach ($UserID in $UserIDs) {
        $currentUserIndex++
        $UserStopwatch    = [System.Diagnostics.Stopwatch]::StartNew()
        $UserWorkDir      = Join-Path $WorkBaseDir $UserID
        $TargetBareRepoPath = "R:\UsersVault\$($UserID).git"

        Write-Host "------------------------------------------------------------"
        Write-Host "Processing User: $UserID ($currentUserIndex/$totalUsers)"
        Write-Host "WorkDir        : $UserWorkDir"
        Write-Host "Target Bare    : $TargetBareRepoPath"
        Write-Host "------------------------------------------------------------"

        $UserSuccess = $false
        $SkipPush    = $false

        # git の作業ディレクトリは run 毎のベースへ
        Set-Location $WorkBaseDir

        # --- 短い try-catch：主要処理の呼び出しのみ ---
        try {
            # 1) ターゲットベアの存在確認・なければ初期化
            $repoInit = Ensure-TargetBareRepoInitialized -TargetBareRepoPath $TargetBareRepoPath

            # 念のための防御（配列化しても最後の要素＝PSCustomObjectを採用）
            if ($repoInit -is [System.Array]) { $repoInit = $repoInit[-1] }

            if ($repoInit.AlreadyExists) {
                Write-Host "Skipping remaining steps for user '$UserID' because target bare already exists."
                $UserSuccess = $true      # スキップを成功扱いにするなら true
                continue                  # 元コードの挙動と完全等価
            }

            # 2) ソースベアの妥当性確認
            Assert-ValidSourceBareRepo -SourceRepoPath $SourceRepoPath

            # 3) ソース（upstream）をユーザ作業ディレクトリへクローン（no-checkout）
            Clone-UpstreamForUser -SourceRepoPath $SourceRepoPath -UserID $UserID -UserWorkDir $UserWorkDir

            # 4) スパースチェックアウト（cone）＋対象パス設定
            Configure-SparseCheckout -UserWorkDir $UserWorkDir -UserID $UserID

            # 5) main ブランチをチェックアウト
            Checkout-MainBranch -UserWorkDir $UserWorkDir

            # 6) リモート設定（origin=UsersVault, upstream=ソース、push無効）
            Configure-Remotes -UserWorkDir $UserWorkDir -TargetBareRepoPath $TargetBareRepoPath

            # 7) 初回 push が必要か判定（origin に main があるか）
            $check    = Test-NeedInitialPush -UserWorkDir $UserWorkDir
            $SkipPush = -not $check.ShouldPush

            # 8) 必要なら初回 push
            Invoke-InitialPush -UserWorkDir $UserWorkDir -SkipPush:$SkipPush

            $UserSuccess = $true
        } catch {
            $globalSuccess = $false
            if ($_.Exception.Message -match "Operation manually stopped" -or $_.Exception.Message -match "中断") {
                Write-Warning "--- PROCESSING MANUALLY STOPPED for User: $UserID ---"
                $manualStop = $true
            } else {
                Write-Warning "!!! FAILED processing User: $UserID !!!"
                Write-Warning "$($_.Exception.Message)"
                Write-Warning "User Script StackTrace: $($_.ScriptStackTrace)"
                Write-Warning "Skipping to next user due to error."
            }
        } finally {
            Set-Location $PSScriptRoot
            $UserStopwatch.Stop()
            if ($UserSuccess) {
                Write-Host ("--- Successfully processed User: {0} in {1} seconds ---" -f $UserID, [math]::Round($UserStopwatch.Elapsed.TotalSeconds,2))
            }
        }

        if ($manualStop) {
            Write-Warning "Manual stop detected. Aborting remaining users."
            break
        }
    }

    [pscustomobject]@{
        GlobalSuccess = $globalSuccess
        ManualStop    = $manualStop
    }
}

function Cleanup-WorkDirectory {
    param(
        [Parameter(Mandatory)][string]$WorkBaseDir
    )

    Write-Host "------------------------------------------------------------"
    Write-Host "--- All processing finished. ---"

    if ($WorkBaseDir -and (Test-Path $WorkBaseDir)) {
        Write-Host "Cleaning up this run's work directory: $WorkBaseDir"
        try {
            Remove-Item -Recurse -Force $WorkBaseDir
            Write-Host "Work directory successfully deleted."
        } catch {
            Write-Warning "Failed to delete work directory: $WorkBaseDir"
            Write-Warning "Reason: $($_.Exception.Message)"
            Write-Warning "You may need to delete it manually."
        }
    } else {
        Write-Host "This run's work directory not found or already cleaned up."
    }
}

# ============================================================
# Per-user operations
# ============================================================

function Ensure-TargetBareRepoInitialized {
    param([Parameter(Mandatory)][string]$TargetBareRepoPath)

    Write-Host "Checking target bare repo: $TargetBareRepoPath"
    if (-not (Test-Path $TargetBareRepoPath)) {
        Write-Warning "Target bare repo does not exist. Creating..."
        # ↓↓↓ 出力を捨てて複数戻り値を防止
        $null = Invoke-GitCommand "init --bare `"$TargetBareRepoPath`"" "Failed to create bare repo"
        Write-Host -ForegroundColor Green "Successfully created bare repo."
        return [pscustomobject]@{ Created = $true; AlreadyExists = $false }
    } else {
        Write-Host -ForegroundColor Cyan "Target bare repo already exists. Skipping setup for this user."
        return [pscustomobject]@{ Created = $false; AlreadyExists = $true }
    }
}

function Assert-ValidSourceBareRepo {
    param([Parameter(Mandatory)][string]$SourceRepoPath)

    Write-Host "Verifying source repository at '$SourceRepoPath'..."
    if (-not (Test-Path (Join-Path $SourceRepoPath "HEAD"))) {
        throw "Source repository '$SourceRepoPath' is not a valid bare repo (missing HEAD)."
    }
    Write-Host "Source repository verified successfully."
}

function Clone-UpstreamForUser {
    param(
        [Parameter(Mandatory)][string]$SourceRepoPath,
        [Parameter(Mandatory)][string]$UserID,
        [Parameter(Mandatory)][string]$UserWorkDir
    )

    Set-Location (Split-Path -Parent $UserWorkDir)
    Write-Host "[1/10] Cloning '$SourceRepoPath' (upstream) into '$UserWorkDir' (local)..."
    $SourceRepoUrl = 'file:///' + ($SourceRepoPath -replace '\\','/')

    # ↓ 戻り値を捨てる
    $null = Invoke-GitCommand "clone --no-checkout --single-branch `"$SourceRepoUrl`" `"$UserID`"" "Git clone failed"
    Set-Location $UserWorkDir
}

function Configure-SparseCheckout {
    param(
        [Parameter(Mandatory)][string]$UserWorkDir,
        [Parameter(Mandatory)][string]$UserID
    )

    Set-Location $UserWorkDir

    Write-Host "[2/10] Initializing sparse-checkout (cone mode)..."
    Invoke-GitCommand "sparse-checkout init --cone" "Failed sparse-checkout init"

    Write-Host "[3/10] Setting sparse-checkout paths for $UserID..."
    $sparsePaths = @(
        ".obsidian/",
        ".vscode/",
        ".script/",
        # "$UserID/",
        "MyWork/",
        "Shared/Project/",
        "Shared/User/",
        "__Attachment/",
        "__Document/",
        "__Template/"
    )
    Invoke-GitCommand "sparse-checkout set $sparsePaths" "Failed sparse-checkout set"
}

function Checkout-MainBranch {
    param([Parameter(Mandatory)][string]$UserWorkDir)
    Set-Location $UserWorkDir
    Write-Host "[4/10] Checking out 'main' branch..."
    # ↓ 戻り値を捨てる
    $null = Invoke-GitCommand "checkout main" "Failed git checkout main"
}

function Configure-Remotes {
    param(
        [Parameter(Mandatory)][string]$UserWorkDir,
        [Parameter(Mandatory)][string]$TargetBareRepoPath
    )

    Set-Location $UserWorkDir
    $TargetRemoteUrl = 'file:///' + ($TargetBareRepoPath -replace '\\','/')

    Write-Host "[5/10] Renaming 'origin' to 'upstream'..."
    $null = Invoke-GitCommand "remote rename origin upstream" "Failed remote rename origin"

    Write-Host "[6/10] Disabling push to 'upstream'..."
    $null = Invoke-GitCommand "remote set-url --push upstream DISABLED" "Failed set-url push upstream"

    Write-Host "[7/10] Adding 'origin' remote: $TargetRemoteUrl"
    $null = Invoke-GitCommand "remote add origin `"$TargetRemoteUrl`"" "Failed remote add origin"

    Write-Host "[8/10] Verifying remote configuration..."
    $remoteConfig = Invoke-GitCommand "remote -v" "Failed remote -v"
    Write-Host "Remote configuration:"
    # ↓ 表示のみで、戻り値は出さない（Write-Host は出力しない）
    $remoteConfig | Write-Host
}

function Test-NeedInitialPush {
    param([Parameter(Mandatory)][string]$UserWorkDir)

    Set-Location $UserWorkDir
    Write-Host "[9/10] Checking 'origin' (UsersVault) for existing 'main' branch..."

    $res = Invoke-GitRaw "ls-remote --exit-code --heads origin main"
    switch ($res.ExitCode) {
        0 {
            Write-Warning "Branch 'main' already exists on 'origin'. Skipping initial push to avoid overwriting existing data."
            return [pscustomobject]@{ ShouldPush = $false; ExitCode = 0 }
        }
        2 {
            Write-Host "Branch 'main' does not exist on 'origin'. Proceeding with initial push."
            return [pscustomobject]@{ ShouldPush = $true; ExitCode = 2 }
        }
        default {
            Write-Warning "Failed to check remote branches on 'origin' (ls-remote exit $($res.ExitCode))."
            throw "ls-remote check failed"
        }
    }
}

function Invoke-InitialPush {
    param(
        [Parameter(Mandatory)][string]$UserWorkDir,
        [Parameter()][switch]$SkipPush
    )

    Set-Location $UserWorkDir

    if (-not $SkipPush) {
        Write-Host "[10/10] Pushing 'main' to 'origin' (UsersVault)..."
        # ↓ 戻り値を捨てる
        $null = Invoke-GitCommand "push -u origin main" "Failed git push"
        Write-Host "Successfully pushed 'main' to 'origin'."
    } else {
        Write-Host "[10/10] Skipping push as 'main' already exists on 'origin'."
    }
}

# ============================================================
# Main orchestration
# ============================================================
function Main {
    param(
        [string]$WorkRootDir = (Join-Path $PSScriptRoot "work"),
        [string]$GitExe = $Script:GitExe
    )

    if ($GitExe) { $Script:GitExe = $GitExe }

    $ScriptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # 既定値（finally でも参照されるため、try の外で初期化）
    $GlobalSuccess = $false
    $ManualStop    = $false

    try {
        $IdListFile = Select-IdListFile
        if (-not $IdListFile) { return }
        Write-Host "Using ID list file: '$IdListFile'"

        $UserIDs     = Get-UserIdsFromFile -IdListFile $IdListFile
        $WorkBaseDir = Initialize-WorkDirectory -WorkRootDir $WorkRootDir -IdListFile $IdListFile

        $SourceRepoPath = Select-SourceRepository
        if (-not $SourceRepoPath) { return }  # キャンセルは正常終了

        # --- 全ユーザ処理 ---
        $summaryAll = Process-AllUsers -WorkBaseDir $WorkBaseDir -SourceRepoPath $SourceRepoPath -UserIDs $UserIDs

        # 防御：配列の場合は「最後の PSCustomObject」を選ぶ
        $summary =
            if ($summaryAll -is [System.Array]) {
                $summaryAll | Where-Object { $_ -is [pscustomobject] } | Select-Object -Last 1
            } else {
                $summaryAll
            }

        if ($null -eq $summary) {
            # サマリーが取得できない場合でも落ちないように
            $GlobalSuccess = $false
            $ManualStop    = $false
        } else {
            $GlobalSuccess = [bool]$summary.GlobalSuccess
            $ManualStop    = [bool]$summary.ManualStop
        }
    } catch {
        $GlobalSuccess = $false
        if ($_.Exception.Message -match "Operation manually stopped" -or $_.Exception.Message -match "中断") {
            $ManualStop = $true
        } else {
            Write-Warning "!!! AN UNEXPECTED TERMINATING ERROR OCCURRED !!!"
            Write-Warning "Exception Message: $($_.Exception.Message)"
        }
    } finally {
        if ($WorkBaseDir) { Cleanup-WorkDirectory -WorkBaseDir $WorkBaseDir }
        $ScriptStopwatch.Stop()

        Write-Host "------------------------------------------------------------"
        if ($ManualStop) {
            Write-Warning "SCRIPT EXECUTION WAS MANUALLY STOPPED."
        } elseif ($GlobalSuccess) {
            Write-Host -ForegroundColor DarkGreen "SCRIPT COMPLETED SUCCESSFULLY."
        } else {
            Write-Warning "SCRIPT COMPLETED WITH ONE OR MORE ERRORS."
        }
        Write-Host "Total execution time: $([math]::Round($ScriptStopwatch.Elapsed.TotalSeconds,2)) seconds."
        Write-Host "------------------------------------------------------------"
    }
}

# --- Entry point ---
Main
