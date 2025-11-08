# ==============================================================================
# Gitmodules File Generator Script (PowerShell) - Final Version (GUI Path Selection)
# Uses Windows Forms for file and folder selection and assumes R: drive is mounted.
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
    $Dialog.InitialDirectory = Get-Location  # 現在のディレクトリを初期表示
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
    $Folder = $Shell.BrowseForFolder(0, "STEP 2/3: Select the parent directory where submodules will be placed (e.g., 'members')", 16, $InitialFolder.Path)

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


# Generate .gitmodules content
$GitmodulesContent = @()

foreach ($ID in $IDs) {
    # Remove leading/trailing spaces from the ID
    $CleanID = $ID.Trim()

    # Submodule Path (Git prefers forward slashes)
    $Path = "$SubmoduleParentDir/$CleanID"

    # Submodule URL (Native Windows path format: R:/<ID>.git)
    # Using {} to safely enclose the variable and avoid InvalidVariableReferenceWithDrive error.
    $URL = "${BaseDriveLetter}:/$CleanID.git"

    $GitmodulesContent += "[submodule `"$Path`"]"
    $GitmodulesContent += "	path = $Path"
    $GitmodulesContent += "	url = $URL"
    $GitmodulesContent += "`n" # Add an empty line between entries
}


# Output file
$OutputFile = ".\.gitmodules"
$GitmodulesContent | Out-File $OutputFile -Encoding UTF8

Write-Host "`n=========================================================" -ForegroundColor Green
Write-Host "🎉 .gitmodules generation complete!" -ForegroundColor Green
Write-Host "Output file: $OutputFile" -ForegroundColor Green
Write-Host "`n⚠️ IMPORTANT: Verify R: drive has all required '{USER_ID}.git' bare repos and is currently mounted." -ForegroundColor Yellow
Write-Host "`nCommit the generated file and then run the following command to fetch submodules:" -ForegroundColor Cyan
Write-Host "`n  git add .gitmodules" -ForegroundColor Cyan
Write-Host "  git commit -m 'Add $($IDs.Count) member submodules'" -ForegroundColor Cyan
Write-Host "  git submodule update --init --recursive" -ForegroundColor Cyan
Write-Host "`n=========================================================" -ForegroundColor Green

# Wait for user input to close
Read-Host "Press Enter to close the window."
