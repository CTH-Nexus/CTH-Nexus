# ==============================================================================
# Gitmodules File Generator Script (PowerShell) - Final Version (Append Mode)
# Uses Windows Forms for file and folder selection and assumes R: drive is mounted.
# Checks for duplicates and appends new entries to .gitmodules.
# ==============================================================================

# Load Windows Forms assembly for GUI dialogs
Add-Type -AssemblyName System.Windows.Forms

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::DoEvents()

# --- [CRITICAL] Base Drive Letter for SMB Share ------------------------------
# Adjust this to the drive letter mounted via 'net use' (e.g., 'R').
$BaseDriveLetter = "R"
# -----------------------------------------------------------------------------

# --- 1. Function to select the ID list file via dialog ---
function Select-IdListFile {
    $Dialog = New-Object System.Windows.Forms.OpenFileDialog
    $Dialog.InitialDirectory = Get-Location  # Set initial directory to current path
    $Dialog.Filter = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
    $Dialog.Title = "STEP 1/3: Select the Member ID list file (one ID per line)"

    if ($Dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $FileName = $Dialog.FileName
        return $FileName
    }
    return $null
}

# --- 2. Function to select the submodule parent directory via dialog ---
function Select-SubmoduleParentDirectory {

    # ⭐ 💡 Use stable Shell.Application COM object for folder selection
    $Shell = New-Object -ComObject Shell.Application

    # Set the current repository root as the initial folder
    $InitialFolder = Get-Location

    # Create the folder browser dialog
    # 0: Parent window handle (0 for no parent)
    # 32: Title
    # 16: Options (e.g., BIF_RETURNONLYFSDIRS)
    # $InitialFolder.Path: Root folder
    $Folder = $Shell.BrowseForFolder(0, "STEP 2/3: Select the parent directory where submodules will be placed (e.g., 'Member/')", 16, $InitialFolder.Path)

    # Release the Shell object to prevent resource leak
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($Shell) | Out-Null

    # Check if the user selected a folder (did not press 'Cancel')
    if ($Folder -ne $null) {
        $SelectedPath = $Folder.Self.Path
        $CurrentDir = Get-Location

        # Calculate the path relative to the current repository root
        try {
            # Use Resolve-Path -Relative to get the relative path
            $RelativePath = Resolve-Path -Path $SelectedPath -Relative
        }
        catch {
            Write-Host "❌ ERROR: Selected folder must be inside the current Git repository's working directory." -ForegroundColor Red
            Read-Host "Press Enter to close the window."
            exit
        }

        # Clean up the path: remove './' and convert backslashes to forward slashes (Git standard)
        return $RelativePath.TrimStart('./').Replace('\', '/')
    }
    return $null
}
# ----------------- Main Processing -------------------------------------------

Write-Host "--- .gitmodules Generator Script (Air-Gap/SMB) ---" -ForegroundColor Yellow

# Get the ID list file
$IDListPath = Select-IdListFile
if (-not $IDListPath) {
    Write-Host "File selection cancelled. Exiting script." -ForegroundColor Red
    Read-Host "Press Enter to close the window."
    exit
}
Write-Host "✅ ID List File: $IDListPath" -ForegroundColor Green

# Get the parent directory path
$SubmoduleParentDir = Select-SubmoduleParentDirectory
if (-not $SubmoduleParentDir) {
    Write-Host "Directory selection cancelled. Exiting script." -ForegroundColor Red
    Read-Host "Press Enter to close the window."
    exit
}
Write-Host "✅ Submodule Parent Path (Relative): $SubmoduleParentDir" -ForegroundColor Green

# Read IDs
$IDs = Get-Content $IDListPath | Where-Object { $_ -match '\S' } # Exclude empty lines
Write-Host "STEP 3/3: Number of IDs to process: $($IDs.Count)" -ForegroundColor Cyan


# --- ⭐ MODIFIED SECTION: Read existing paths and append new entries ---

$OutputFile = ".\.gitmodules"
$ExistingPaths = New-Object System.Collections.Generic.HashSet[string]

# 1. Read existing .gitmodules if it exists
if (Test-Path $OutputFile) {
    Write-Host "Reading existing .gitmodules file..."
    try {
        $ExistingContent = Get-Content $OutputFile
        foreach ($line in $ExistingContent) {
            # Find lines that match 'path = ...'
            if ($line -match '^\s*path\s*=\s*(.+)$') {
                # Add the extracted path to the HashSet for duplicate checking
                $ExistingPaths.Add($matches[1].Trim())
            }
        }
        Write-Host "Found $($ExistingPaths.Count) existing submodule paths." -ForegroundColor Gray
    }
    catch {
        Write-Host "❌ ERROR: Failed to read existing .gitmodules file. Check permissions." -ForegroundColor Red
        Read-Host "Press Enter to close the window."
        exit
    }
} else {
    Write-Host "No existing .gitmodules file found. A new one will be created."
}

$AddCount = 0
$SkipCount = 0

Write-Host "Processing IDs and appending new submodules..."

# 2. Loop through IDs, check for duplicates, and append
foreach ($ID in $IDs) {
    # Remove leading/trailing spaces from the ID
    $CleanID = $ID.Trim()

    # Submodule Path (Git prefers forward slashes)
    $Path = "$SubmoduleParentDir/$CleanID"

    # Check if this path is already in the file
    if ($ExistingPaths.Contains($Path)) {
        Write-Host "  [SKIP] $Path already exists." -ForegroundColor Yellow
        $SkipCount++
    } else {
        # This is a new entry, append it
        Write-Host "  [ADD] $Path" -ForegroundColor Green
        
        # Build the new content block
        $URL = "${BaseDriveLetter}:$Path.git" # Using your specific URL format
        
        $NewEntry = @(
            "", # Start with a blank line for separation
            "[submodule `"$Path`"]",
            "	path = $Path",
            "	url = $URL"
        )
        
        # Append this block to the file
        try {
            $NewEntry | Add-Content -Path $OutputFile -Encoding UTF8
        }
        catch {
             Write-Host "❌ ERROR: Failed to write to .gitmodules. Check permissions." -ForegroundColor Red
             Read-Host "Press Enter to close the window."
             exit
        }
        
        # Also add to the HashSet so we don't add duplicates *from the ID list itself*
        $ExistingPaths.Add($Path) 
        $AddCount++
    }
}
# --- ⭐ END OF MODIFIED SECTION ---


# 3. Final Summary Report
Write-Host "`n=========================================================" -ForegroundColor Green
Write-Host "🎉 .gitmodules generation complete!" -ForegroundColor Green
Write-Host "Output file: $OutputFile"
Write-Host " - Added: $AddCount new submodules." -ForegroundColor Green
Write-Host " - Skipped: $SkipCount duplicate submodules." -ForegroundColor Yellow
Write-Host "`n⚠️ IMPORTANT: Verify R: drive has all required '{USER_ID}.git' bare repos and is currently mounted." -ForegroundColor Yellow
Write-Host "`nCommit the changes and then run the following command to fetch submodules:" -ForegroundColor Cyan
Write-Host "`n  git add .gitmodules" -ForegroundColor Cyan
Write-Host "  git commit -m 'Add $AddCount new member submodules'" -ForegroundColor Cyan
Write-Host "  git submodule update --init --recursive" -ForegroundColor Cyan
Write-Host "`n=========================================================" -ForegroundColor Green

# Wait for user input to close
Read-Host "Press Enter to close the window."
