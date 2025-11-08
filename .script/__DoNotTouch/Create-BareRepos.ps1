# ==============================================================================
# Bare Repository Creation Script (PowerShell) - Air-Gap/SMB Support
# Creates R:\<ID>.git bare repositories based on an ID list.
# ==============================================================================

# Load Windows Forms assembly for GUI dialogs
Add-Type -AssemblyName System.Windows.Forms

# ⭐ GUI Freeze Countermeasures
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::DoEvents()

# --- [CRITICAL] Base Drive Letter for SMB Share ---
# Adjust this to the drive letter mounted via 'net use' (e.g., 'R').
$BaseDriveLetter = "R"
# -----------------------------------------------

# --- 1. Function to select the ID list file via dialog ---
function Select-IdListFile {
    $Dialog = New-Object System.Windows.Forms.OpenFileDialog
    $Dialog.InitialDirectory = Get-Location
    $Dialog.Filter = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
    $Dialog.Title = "STEP 1/2: Select the Member ID list file (one ID per line)"

    if ($Dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $Dialog.FileName
    }
    return $null
}

# ----------------- Main Processing -----------------

Write-Host "--- Bare Repository Creator Script (R:\ Drive) ---" -ForegroundColor Yellow

# Get the ID list file
$IDListPath = Select-IdListFile
if (-not $IDListPath) {
    Write-Host "File selection cancelled. Exiting script." -ForegroundColor Red
    Read-Host "Press Enter to close the window."
    exit
}
Write-Host "✅ ID List File: $IDListPath" -ForegroundColor Green

# Read IDs
$IDs = Get-Content $IDListPath | Where-Object { $_ -match '\S' } # Exclude empty lines
Write-Host "STEP 2/2: Number of bare repos to create: $($IDs.Count)" -ForegroundColor Cyan

# Check if the target drive is mounted
if (-not (Test-Path "${BaseDriveLetter}:/")) {
    Write-Host "❌ FATAL ERROR: Target drive letter '${BaseDriveLetter}' is not mounted." -ForegroundColor Red
    Write-Host "Please ensure 'net use ${BaseDriveLetter}: \\server\share' was run successfully." -ForegroundColor Red
    Read-Host "Press Enter to close the window."
    exit
}
Write-Host "✅ Target drive '${BaseDriveLetter}:' is mounted. Starting creation..." -ForegroundColor Green

$SuccessCount = 0
$FailureCount = 0

foreach ($ID in $IDs) {
    $CleanID = $ID.Trim()
    $RepoPath = "${BaseDriveLetter}:/${CleanID}.git" # e.g., R:/member_a.git

    Write-Host "Processing $CleanID..." -NoNewline

    # Check if the repository already exists
    if (Test-Path $RepoPath) {
        Write-Host "  [SKIP] Path already exists." -ForegroundColor Yellow
        $FailureCount++
        continue
    }

    # Execute git init --bare
    # The command output is redirected to $null to keep the console clean
    try {
        git init --bare $RepoPath 3>&1 4>&1 | Out-Null

        # Post-check: ensure the .git/HEAD file was created successfully
        if (Test-Path (Join-Path $RepoPath "HEAD")) {
            Write-Host "  [SUCCESS] Created bare repo." -ForegroundColor Green
            $SuccessCount++
        } else {
            Write-Host "  [FAIL] Git command failed or incomplete." -ForegroundColor Red
            $FailureCount++
        }
    }
    catch {
        Write-Host "  [ERROR] An exception occurred: $($_.Exception.Message)" -ForegroundColor Red
        $FailureCount++
    }
}

Write-Host "`n=========================================================" -ForegroundColor Green
Write-Host "🎉 Bare Repository Creation Summary" -ForegroundColor Green
Write-Host "Total IDs: $($IDs.Count)"
Write-Host "Successful Creations: $SuccessCount" -ForegroundColor Green
Write-Host "Failed/Skipped: $FailureCount" -ForegroundColor Yellow
Write-Host "`n=========================================================" -ForegroundColor Green

# Wait for user input to close
Read-Host "Press Enter to close the window."
