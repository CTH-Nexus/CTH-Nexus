# ==============================================================================
# Bare Repository Creation Script (PowerShell) - Air-Gap/SMB Support
# Creates R:\<ID>.git bare repositories and pushes an initial commit.
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
    $Dialog.Title = "STEP 1/3: Select the User ID list file (one ID per line)"

    if ($Dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $Dialog.FileName
    }
    return $null
}

# --- 2. Function to select the target base directory via dialog ---
function Select-TargetBaseDirectory {

    # Check if the target drive is mounted
    if (-not (Test-Path "${BaseDriveLetter}:/")) {
        Write-Host "❌ FATAL ERROR: Target drive letter '${BaseDriveLetter}' is not mounted." -ForegroundColor Red
        return $null
    }

    # Use stable Shell.Application COM object for folder selection
    $Shell = New-Object -ComObject Shell.Application

    # Set the R: drive root as the initial folder
    $InitialFolder = "${BaseDriveLetter}:\"

    # Create the folder browser dialog
    $Title = "STEP 2/3: Select the base directory on R: drive for bare repositories (e.g., R:\USERS_REPOS)"
    # 16 is BIF_RETURNONLYFSDIRS
    $Folder = $Shell.BrowseForFolder(0, $Title, 16, $InitialFolder)

    # Release the Shell object to prevent resource leak
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($Shell) | Out-Null

    # Check if the user selected a folder (did not press 'Cancel')
    if ($Folder -ne $null) {
        $SelectedPath = $Folder.Self.Path

        # Verify selection is on the target drive
        if (-not ($SelectedPath -like "${BaseDriveLetter}:*")) {
             Write-Host "❌ ERROR: Selected folder must be on the target drive '${BaseDriveLetter}:'." -ForegroundColor Red
             return $null
        }

        # Convert path to Git/PowerShell friendly format (R:/path/to/folder)
        return $SelectedPath.Replace('\', '/')
    }
    return $null
}

# ----------------- Main Processing -----------------

Write-Host "--- Bare Repository Creator Script (${BaseDriveLetter}: Drive) ---" -ForegroundColor Yellow

# Get paths to the parent repo's git files (assuming script is run from parent root)
$ParentRepoRoot = Get-Location
$SourceGitIgnore = Join-Path $ParentRepoRoot ".gitignore"
$SourceGitAttributes = Join-Path $ParentRepoRoot ".gitattributes"
Write-Host "Using parent files:"
if (Test-Path $SourceGitIgnore) { Write-Host "  - .gitignore" }
if (Test-Path $SourceGitAttributes) { Write-Host "  - .gitattributes" }

# Get the ID list file
$IDListPath = Select-IdListFile
if (-not $IDListPath) {
    Write-Host "File selection cancelled. Exiting script." -ForegroundColor Red
    Read-Host "Press Enter to close the window."
    exit
}
Write-Host "✅ STEP 1: ID List File: $IDListPath" -ForegroundColor Green

# Get the target base path for repo creation
$TargetBasePath = Select-TargetBaseDirectory
if (-not $TargetBasePath) {
    Write-Host "Target directory selection cancelled or failed. Exiting script." -ForegroundColor Red
    Read-Host "Press Enter to close the window."
    exit
}
Write-Host "✅ STEP 2: Target Base Path: $TargetBasePath" -ForegroundColor Green

# Read IDs
$IDs = Get-Content $IDListPath | Where-Object { $_ -match '\S' } # Exclude empty lines
Write-Host "STEP 3/3: Number of bare repos to create: $($IDs.Count)" -ForegroundColor Cyan

# Check if the target drive is mounted (redundant check, but safe)
if (-not (Test-Path "${BaseDriveLetter}:/")) {
    Write-Host "❌ FATAL ERROR: Target drive letter '${BaseDriveLetter}' is not mounted." -ForegroundColor Red
    Write-Host "Please ensure 'net use ${BaseDriveLetter}: \\server\share' was run successfully." -ForegroundColor Red
    Read-Host "Press Enter to close the window."
    exit
}
Write-Host "✅ Drive is mounted. Starting creation..." -ForegroundColor Green

# Create a single unique temporary directory for all clone operations
$TempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $TempDirectory | Out-Null
Write-Host "Using temporary work directory: $TempDirectory" -ForegroundColor Gray

$SuccessCount = 0
$FailureCount = 0

foreach ($ID in $IDs) {
    ${CleanID} = $ID.Trim()

    # Path to the bare repo on R: drive
    $RepoPath = (Join-Path $TargetBasePath "${CleanID}.git").Replace('\', '/')
    # Path for the temporary local clone
    $TempClonePath = Join-Path $TempDirectory ${CleanID}

    Write-Host "`nProcessing ${CleanID}..."

    # Check if the repository already exists
    if (Test-Path $RepoPath) {
        Write-Host "  [SKIP] Bare repository already exists at $RepoPath" -ForegroundColor Yellow
        $FailureCount++
        continue
    }

    try {
        # 1. Create the bare repository
        Write-Host "  [1/5] Creating bare repo..." -NoNewline
        git init --bare $RepoPath 3>&1 4>&1 | Out-Null
        Write-Host " Done." -ForegroundColor Green

        # 2. Clone the empty bare repo to the temp location
        Write-Host "  [2/5] Creating temporary clone..." -NoNewline
        git clone $RepoPath $TempClonePath 3>&1 4>&1 | Out-Null
        Write-Host " Done." -ForegroundColor Green

        # 3. Populate the temp clone (Set-Location is critical)
        Set-Location $TempClonePath
        Write-Host "  [3/5] Populating files..." -NoNewline

        # Set a default branch (e.g., main)
        git checkout -b main 3>&1 4>&1 | Out-Null

        # Copy files from parent
        if (Test-Path $SourceGitIgnore) {
            Copy-Item $SourceGitIgnore -Destination .
        }
        if (Test-Path $SourceGitAttributes) {
            Copy-Item $SourceGitAttributes -Destination .
        }

        Write-Host " Done." -ForegroundColor Green

        # 4. Add, commit, and push the initial commit
        Write-Host "  [4/5] Committing and pushing initial state..." -NoNewline
        git add . 3>&1 4>&1 | Out-Null

        $CommitMessage = "Initial commit: Add standard files only"
        git commit -m $CommitMessage 3>&1 4>&1 | Out-Null
        # Push to the bare repo on R: drive
        git push -u origin main 3>&1 4>&1 | Out-Null
        Write-Host " Done." -ForegroundColor Green

        # 5. Return to the original directory
        Set-Location $ParentRepoRoot

        Write-Host "  [5/5] Successfully initialized ${CleanID}." -ForegroundColor Green
        $SuccessCount++
    }
    catch {
        Write-Host "  [ERROR] An exception occurred for ${CleanID}: $($_.Exception.Message)" -ForegroundColor Red
        $FailureCount++
        # Ensure we are not stuck in the temp directory if an error occurs
        Set-Location $ParentRepoRoot
    }
}

# --- After the loop ---

# 6. Clean up the temporary directory
Write-Host "`nCleaning up temporary directory..."
Remove-Item -Recurse -Force $TempDirectory

Write-Host "`n=========================================================" -ForegroundColor Green
Write-Host "🎉 Bare Repository Creation Summary" -ForegroundColor Green
Write-Host "Total IDs: $($IDs.Count)"
Write-Host "Successful Creations: $SuccessCount" -ForegroundColor Green
Write-Host "Failed/Skipped: $FailureCount" -ForegroundColor Yellow
Write-Host "`n=========================================================" -ForegroundColor Green

# Wait for user input to close
Read-Host "Press Enter to close the window."
