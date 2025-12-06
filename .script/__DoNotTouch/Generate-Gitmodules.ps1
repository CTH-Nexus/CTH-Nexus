#Requires -Version 5.1
# ==============================================================================
# .script\__DoNotTouch\Generate-Gitmodules.ps1
# Gitmodules File Generator Script (PowerShell) - Refactored (Append Mode)
# - Windows Forms for file/folder selection
# - R: drive (SMB) assumed
# - Main orchestration + try/catch
# ==============================================================================

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles() | Out-Null
[System.Windows.Forms.Application]::DoEvents() | Out-Null

# --- [CRITICAL] Base Drive Letter for SMB Share ------------------------------
$BaseDriveLetter = "R"
# -----------------------------------------------------------------------------

# --- Policy defaults for submodule behavior (can be lifted to .env later) ---
# These dictate additional keys in .gitmodules
$DefaultSubmoduleBranch = "main"       # fixed
$DefaultSubmoduleUpdate = "checkout"   # recommended for deterministic, safe updates
$DefaultSubmoduleIgnore = "none"       # strict detection of submodule status
$DefaultSubmoduleShallow = $true       # fixed; lightweight clones
# -----------------------------------------------------------------------------

function Select-IdListFile {
    $Dialog = New-Object System.Windows.Forms.OpenFileDialog
    $Dialog.InitialDirectory = Get-Location
    $Dialog.Filter = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
    $Dialog.Title = "STEP 1/3: Select the User ID list file (one ID per line)"

    if ($Dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $Dialog.FileName
    }
    return $null
}

function Select-SubmoduleParentDirectory {
    $Shell = New-Object -ComObject Shell.Application
    $InitialFolder = Get-Location

    $Folder = $Shell.BrowseForFolder(
        0,
        "STEP 2/3: Select the parent directory where submodules will be placed (e.g., 'User/')",
        16,
        $InitialFolder.Path
    )

    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($Shell) | Out-Null

    if ($Folder -ne $null) {
        $SelectedPath = $Folder.Self.Path
        try {
            $RelativePath = Resolve-Path -Path $SelectedPath -Relative
        }
        catch {
            throw "Selected folder must be inside the current Git repository's working directory."
        }

        return $RelativePath.TrimStart('./').Replace('\', '/')
    }
    return $null
}

# (A) Read existing .gitmodules if it exists
function ReadExistingGitmodules {
    param(
        [Parameter(Mandatory=$true)][string]$GitmodulesPath
    )

    $existingPaths = New-Object System.Collections.Generic.HashSet[string]

    if (Test-Path $GitmodulesPath) {
        Write-Host "Reading existing .gitmodules file..."
        try {
            $ExistingContent = Get-Content -LiteralPath $GitmodulesPath -ErrorAction Stop
            foreach ($line in $ExistingContent) {
                if ($line -match '^\s*path\s*=\s*(.+)$') {
                    $null = $existingPaths.Add($matches[1].Trim().TrimStart('/'))
                }
            }
            Write-Host "Found $($existingPaths.Count) existing submodule paths." -ForegroundColor Gray
        }
        catch {
            throw "Failed to read existing .gitmodules file. Check permissions. Details: $($_.Exception.Message)"
        }
    } else {
        Write-Host "No existing .gitmodules file found. A new one will be created."
    }

    return $existingPaths
}

# (B) Loop through IDs, check for duplicates, and append
function AppendSubmodulesFromIds {
    param(
        [Parameter(Mandatory=$true)][string[]]$Ids,
        [Parameter(Mandatory=$true)][string]$ParentDirRelative,   # "" means repo root
        [Parameter(Mandatory=$true)][System.Collections.Generic.HashSet[string]]$ExistingPaths,
        [Parameter(Mandatory=$true)][string]$GitmodulesPath,
        [Parameter(Mandatory=$true)][string]$BaseDriveLetter,
        # Additional keys
        [Parameter(Mandatory=$true)][string]$Branch,
        [Parameter(Mandatory=$true)][ValidateSet('checkout','merge','rebase')][string]$UpdatePolicy,
        [Parameter(Mandatory=$true)][ValidateSet('none','untracked','dirty','all')][string]$IgnorePolicy,
        [Parameter(Mandatory=$true)][bool]$Shallow
    )

    $AddCount = 0
    $SkipCount = 0

    Write-Host "Processing IDs and appending new submodules..."

    foreach ($id in $Ids) {
        $CleanID = $id.Trim()
        if (-not $CleanID) { continue }

        # Join relative parent dir and ID safely, then normalize to Git-style slashes.
        $Path = (Join-Path $ParentDirRelative $CleanID).Replace('\', '/').TrimStart('/')

        if ($ExistingPaths.Contains($Path)) {
            Write-Host "  [SKIP] $Path already exists." -ForegroundColor Yellow
            $SkipCount++
            continue
        }

        Write-Host "  [ADD] $Path" -ForegroundColor Green

        $URL = "${BaseDriveLetter}:/Submodule/$Path.git"
        # Convert boolean to 'true'/'false' for .gitmodules
        $shallowString = if ($Shallow) { "true" } else { "false" }

        $NewEntry = @(
            "", # blank line separator
            "[submodule `"$Path`"]",
            "    path = $Path",
            "    url = $URL",
            "    branch = $Branch",
            "    update = $UpdatePolicy",
            "    ignore = $IgnorePolicy",
            "    shallow = $shallowString"
        )

        try {
            $NewEntry | Add-Content -LiteralPath $GitmodulesPath -Encoding UTF8
        }
        catch {
            throw "Failed to write to .gitmodules. Check permissions. Details: $($_.Exception.Message)"
        }

        $null = $ExistingPaths.Add($Path)
        $AddCount++
    }

    [PSCustomObject]@{
        Added   = $AddCount
        Skipped = $SkipCount
    }
}

# (C) Final Summary Report
function PrintFinalSummary {
    param(
        [Parameter(Mandatory=$true)][string]$GitmodulesPath,
        [Parameter(Mandatory=$true)][int]$Added,
        [Parameter(Mandatory=$true)][int]$Skipped,
        # Echo chosen policies for transparency
        [Parameter(Mandatory=$true)][string]$Branch,
        [Parameter(Mandatory=$true)][string]$UpdatePolicy,
        [Parameter(Mandatory=$true)][string]$IgnorePolicy,
        [Parameter(Mandatory=$true)][bool]$Shallow
    )

    $shallowString = if ($Shallow) { "true" } else { "false" }

    Write-Host "`n=========================================================" -ForegroundColor Green
    Write-Host "🎉 .gitmodules generation complete!" -ForegroundColor Green
    Write-Host "Output file: $GitmodulesPath"
    Write-Host " - Added: $Added new submodules." -ForegroundColor Green
    Write-Host " - Skipped: $Skipped duplicate submodules." -ForegroundColor Yellow
    Write-Host " - Policies: branch=$Branch, update=$UpdatePolicy, ignore=$IgnorePolicy, shallow=$shallowString" -ForegroundColor Gray
    Write-Host "`n⚠️ IMPORTANT: Verify R: drive has all required '{USER_ID}.git' bare repos and is currently mounted." -ForegroundColor Yellow
    Write-Host "`nCommit the changes and then run the following command to fetch submodules:" -ForegroundColor Cyan
    Write-Host "`n  git add .gitmodules" -ForegroundColor Cyan
    Write-Host "  git submodule update --init --recursive" -ForegroundColor Cyan
    Write-Host "`n=========================================================" -ForegroundColor Green
}

function main {
    Write-Host "--- .gitmodules Generator Script (Air-Gap/SMB) ---" -ForegroundColor Yellow

    # 1) Select ID list
    $IDListPath = Select-IdListFile
    if (-not $IDListPath) { throw "File selection cancelled." }
    Write-Host "✅ ID List File: $IDListPath" -ForegroundColor Green

    # 2) Select submodule parent dir (relative to repo root)
    $SubmoduleParentDir = Select-SubmoduleParentDirectory
    if ($null -eq $SubmoduleParentDir) { throw "Directory selection cancelled." }
    $displayParent = if ($SubmoduleParentDir) { $SubmoduleParentDir } else { "(repo root)" }
    Write-Host "✅ Submodule Parent Path (Relative): $displayParent" -ForegroundColor Green

    # 3) Read IDs (strip empty lines)
    $IDs = Get-Content -LiteralPath $IDListPath | Where-Object { $_ -match '\S' }
    Write-Host "STEP 3/3: Number of IDs to process: $($IDs.Count)" -ForegroundColor Cyan

    $OutputFile = ".\.gitmodules"

    # (A) Read existing .gitmodules
    $ExistingPaths = ReadExistingGitmodules -GitmodulesPath $OutputFile

    # (B) Append from IDs with additional keys
    $result = AppendSubmodulesFromIds `
        -Ids $IDs `
        -ParentDirRelative $SubmoduleParentDir `
        -ExistingPaths $ExistingPaths `
        -GitmodulesPath $OutputFile `
        -BaseDriveLetter $BaseDriveLetter `
        -Branch $DefaultSubmoduleBranch `
        -UpdatePolicy $DefaultSubmoduleUpdate `
        -IgnorePolicy $DefaultSubmoduleIgnore `
        -Shallow $DefaultSubmoduleShallow

    # (C) Final summary
    PrintFinalSummary `
        -GitmodulesPath $OutputFile `
        -Added $result.Added `
        -Skipped $result.Skipped `
        -Branch $DefaultSubmoduleBranch `
        -UpdatePolicy $DefaultSubmoduleUpdate `
        -IgnorePolicy $DefaultSubmoduleIgnore `
        -Shallow $DefaultSubmoduleShallow
}

try {
    main
}
catch {
    Write-Host "❌ ERROR: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Read-Host "Press Enter to close the window."
}
