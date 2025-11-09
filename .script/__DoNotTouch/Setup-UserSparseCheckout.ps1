<#
.SYNOPSIS
    Automates the setup of user-specific sparse-checkout clones from a central monorepo.

.DESCRIPTION
    This script reads a list of User IDs from a text file. For each User ID, it:
    1. Ensures a corresponding bare repository exists in 'UsersVault'. If not, it creates one.
    2. Creates a local working clone from the 'Knewrova' (upstream) repository.
    3. Configures sparse-checkout to pull only user-specific files and shared directories.
    4. Sets the 'origin' remote to the user's 'UsersVault' repository.
    5. Sets the 'upstream' remote to the 'Knewrova' repository (push disabled).
    6. Performs an initial push of the 'main' branch to the 'origin' (UsersVault).

    The script operates in a temporary 'work' directory, which is automatically
    cleaned up upon completion or failure.

.NOTES
    Author: Gemini
    LastModified: 2025-11-09
    Requires: Git for Windows, PowerShell 5.1+
#>

# --- Script Configuration ---
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# --- Helper Function: Invoke Git Command ---
# This function is refactored to use System.Diagnostics.Process
# for robust handling of native executables, stdout/stderr, and exit codes.
function Invoke-GitCommand {
    param (
        [string]$Arguments,
        [string]$ErrorMessage
    )

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = "git"
    $processInfo.Arguments = $Arguments
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true

    # --- FIX: Explicitly set the Working Directory ---
    # Set-Location only affects the PS environment.
    # We must explicitly tell System.Diagnostics.Process where to run.
    $processInfo.WorkingDirectory = (Get-Location).Path

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo

    # This try/catch is *only* for starting the process
    try {
        $process.Start() | Out-Null
    } catch {
        # This catch is only for PowerShell-level errors (e.g., process start failure)
        Write-Warning "Failed to start git process: git $Arguments"
        Write-Warning "Original Exception: $($_.ToString())"

        if ($_.Exception.Message -match "Operation manually stopped" -or $_.Exception.Message -match "中断") {
            throw $_.Exception # Re-throw the manual stop exception
        }
        throw "PowerShell failed to start git process for: git $Arguments. Reason: $($_.Exception.Message)"
    }

    # --- This logic is now OUTSIDE the try/catch block ---
    # Errors here (like ExitCode != 0) will be caught by the *caller's* (foreach loop's) try/catch.

    # Wait for the process to exit *first*. This is a blocking call.
    $process.WaitForExit()

    # --- Synchronous Read ---
    # After the process has exited, read the *entire* output streams.
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()

    # --- FIX: De-duplicate output ---
    # Print the output (so the user sees "Initialized..." etc.)
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            Write-Host $stdout.TrimEnd()
        }
    # Only print stderr if it's DIFFERENT from stdout, or if stdout was empty
    # This prevents "Initialized..." from printing twice.
    if ((-not [string]::IsNullOrWhiteSpace($stderr)) -and ($stderr -ne $stdout)) {
        # Git often prints progress/success to stderr
        Write-Host $stderr.TrimEnd()
    }
    # --- End De-duplicate Read ---

    # Combine output and error streams for logging
        $FullOutputString = "$stdout`n$stderr"

        if ($process.ExitCode -ne 0) {
        # Git command *actually* failed
        Write-Warning "Git command failed: git $Arguments"
            Write-Warning "Exit Code: $($process.ExitCode)"
            Write-Warning "Output (stdout + stderr): $FullOutputString"

            # Check for Ctrl+C (ExitCode 130 is common for SIGINT) or Japanese "interrupted"
            if ($process.ExitCode -eq 130 -or $FullOutputString -match "signal 2" -or $FullOutputString -match "中断") {
                throw "Operation manually stopped (Ctrl+C). ($ErrorMessage)"
        }
        throw $ErrorMessage # Throw the specific error message
    }

    # Return successful output (stdout only)
    return $stdout

    # REMOVED: The flawed 'catch' block that was wrapping the ExitCode check
}

# --- Helper Function: Show File Dialog ---
function Get-IdListFile {
    try {
        # Add assembly for file dialog
        Add-Type -AssemblyName System.Windows.Forms
        $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
        $fileDialog.Title = "Select User ID List File"
        $fileDialog.Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*"
        $fileDialog.InitialDirectory = $PSScriptRoot

        # Show dialog in STA mode
        if ($fileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $fileDialog.FileName
        } else {
            return $null
        }
    } catch {
        Write-Warning "Failed to show file dialog. Attempting to find 'id_list.txt' in script directory."
        $fallbackPath = Join-Path $PSScriptRoot "id_list.txt"
        if (Test-Path $fallbackPath) {
            return $fallbackPath
        }
        return $null
    }
}

# --- Main Script Execution ---
$ScriptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$GlobalSuccess = $true
$WorkBaseDir = Join-Path $PSScriptRoot "work" # Temporary working directory
$IdListFile = $null
$UserIDs = @()
$ManualStop = $false

try {
    # === 1. Get ID List File ===
    $IdListFile = Get-IdListFile
    if (-not $IdListFile) {
        Write-Error "No ID list file selected. Aborting."
        return
    }
    Write-Host "Using ID list file: '$IdListFile'"

    # === 2. Read and Validate User IDs ===
    try {
        # Read file, trim whitespace, remove empty lines, remove trailing backslashes
        $rawIDs = Get-Content $IdListFile | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.TrimEnd('\') }

        # Ensure $UserIDs is always an array, even if $rawIDs contains only one ID
        $UserIDs = @($rawIDs)

        if ($UserIDs.Count -eq 0) {
            Write-Error "ID list file '$IdListFile' is empty or contains no valid IDs. Aborting."
            return
        }
    } catch {
        $GlobalSuccess = $false
        Write-Warning "--- ERROR ---"
        Write-Warning "Failed to read ID list file: $IdListFile."
        Write-Warning "Reason: $($_.Exception.Message)"
        return
    }

    # === 3. Setup Work Directory ===
    Write-Host "Creating work directory at: $WorkBaseDir"
    if (Test-Path $WorkBaseDir) {
        Write-Warning "Work directory '$WorkBaseDir' already exists. Deleting..."
        Remove-Item -Recurse -Force $WorkBaseDir
    }
    New-Item -ItemType Directory -Path $WorkBaseDir | Out-Null

    # === 4. Process Each User ===
    Write-Host "--- Found $($UserIDs.Count) users in '$IdListFile' ---"
    $totalUsers = $UserIDs.Count
    $currentUserIndex = 0

    foreach ($UserID in $UserIDs) {
        $currentUserIndex++
        $UserStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $UserWorkDir = Join-Path $WorkBaseDir $UserID
        $SourceRepoPath = "R:\Knewrova.git" # Path to the main monorepo
        $TargetBareRepoPath = "R:\UsersVault\$($UserID).git" # Path to the user's bare repo

        Write-Host "------------------------------------------------------------"
        Write-Host "Processing User: $UserID ($currentUserIndex/$totalUsers)"
        Write-Host "------------------------------------------------------------"

        $UserSuccess = $false
        $SkipPush = $false

        # Set location to the base 'work' directory for git commands
        Set-Location $WorkBaseDir

        try {
            # --- A. Check/Create Target Bare Repo ---
            Write-Host "Checking target bare repo: $TargetBareRepoPath"
            if (-not (Test-Path $TargetBareRepoPath)) {
                Write-Warning "Target bare repo does not exist. Creating..."
                try {
                    # Invoke-GitCommand will now print "Initialized empty Git repository..."
                    # because it prints stderr in real-time.
                    Invoke-GitCommand "init --bare `"$TargetBareRepoPath`"" "Failed to create bare repo"

                    # This message is now an explicit confirmation AFTER the command succeeded.
                    Write-Host -ForegroundColor Green "Successfully created bare repo."
                } catch {
                    Write-Warning "Failed to create bare repo at '$TargetBareRepoPath'."
                    Write-Warning "Please check permissions and path. Skipping this user."
                    throw # Throw to outer catch for this user
                }
            } else {
                Write-Host -ForegroundColor Cyan "Target bare repo already exists. Skipping setup for this user."
                continue # Skip to the next user in the foreach loop
            }

            # --- B. Verify Source Repo ---
            Write-Host "Verifying source repository at '$SourceRepoPath'..."
            if (-not (Test-Path (Join-Path $SourceRepoPath "HEAD"))) {
                Write-Warning "Source repository '$SourceRepoPath' does not exist or is not a valid bare repository (missing HEAD file)."
                Write-Warning "Skipping this user."
                throw "Source repo verification failed"
            }
            Write-Host "Source repository verified successfully."

            # --- C. Clone for Local Setup ---
            # We always clone, even if target exists, to set up the local sparse-checkout environment.
            Write-Host "[1/10] Cloning '$SourceRepoPath' (upstream) into '$UserWorkDir' (local)..."
            Invoke-GitCommand "clone --no-checkout `"$SourceRepoPath`" `"$UserID`"" "Git clone failed"

            # Enter the user's directory for subsequent commands
            Set-Location $UserWorkDir

            # --- D. Configure Sparse Checkout ---
            Write-Host "[2/10] Initializing sparse-checkout (cone mode)..."
            Invoke-GitCommand "sparse-checkout init --cone" "Failed sparse-checkout init"

            Write-Host "[3/10] Setting sparse-checkout paths for $UserID..."
            # Define paths. Using an array and Join-Path is safer.
            $sparsePaths = @(
                ".gitignore",
                ".gitattributes",
                ".gitmodules",
                "LICENSE",
                ".script/",
                "Member/$UserID/",
                "Shared/Project/$UserID/",
                "Shared/User/$UserID/",
                "__Attachment/",
                "__Document/",
                "__Template/"
            )
            # Pass paths to git sparse-checkout set
            Invoke-GitCommand "sparse-checkout set $sparsePaths" "Failed sparse-checkout set"

            # --- E. Checkout Main Branch ---
            Write-Host "[4/10] Checking out 'main' branch..."
            Invoke-GitCommand "checkout main" "Failed git checkout main"

            # --- F. Configure Remotes ---
            Write-Host "[5/10] Renaming 'origin' to 'upstream'..."
            Invoke-GitCommand "remote rename origin upstream" "Failed remote rename origin"

            Write-Host "[6/10] Disabling push to 'upstream'..."
            Invoke-GitCommand "remote set-url --push upstream DISABLED" "Failed set-url push upstream"

            Write-Host "[7/10] Adding 'origin' remote: $TargetBareRepoPath"
            Invoke-GitCommand "remote add origin `"$TargetBareRepoPath`"" "Failed remote add origin"

            Write-Host "[8/10] Verifying remote configuration..."
            $remoteConfig = Invoke-GitCommand "remote -v" "Failed remote -v"
            Write-Host "Remote configuration:"
            $remoteConfig | Write-Host

            # --- G. Check if Push is Needed ---
            Write-Host "[9/10] Checking 'origin' (UsersVault) for existing 'main' branch..."

            # We call git.exe directly here, NOT Invoke-GitCommand,
            # because we need to manually inspect the $LASTEXITCODE.
            # 'ls-remote --exit-code' returns:
            #   0 if 'main' is found
            #   2 if 'main' is not found
            #   Other (e.g., 128) if another error occurred

            # We suppress output (stdout/stderr) because we only care about the exit code.
            git ls-remote --exit-code --heads origin main 2>$null 1>$null

            if ($LASTEXITCODE -eq 0) {
                # 0 = Found
                Write-Warning "Branch 'main' already exists on 'origin' ($TargetBareRepoPath)."
                Write-Warning "Skipping initial push to avoid overwriting existing data."
                $SkipPush = $true
            } elseif ($LASTEXITCODE -eq 2) {
                # 2 = Not Found (This is the "good" case for a new repo)
                Write-Host "Branch 'main' does not exist on 'origin'. Proceeding with initial push."
                $SkipPush = $false
            } else {
                # Other error (e.g., 128 for "repo not found" or "no access")
                Write-Warning "Failed to check remote branches on 'origin' (ls-remote failed with exit code $LASTEXITCODE)."
                throw "ls-remote check failed"
            }

            # --- H. Initial Push ---
            if (-not $SkipPush) {
                Write-Host "[10/10] Pushing 'main' to 'origin' (UsersVault)..."
                # Use -u to set tracking for the local main branch
                Invoke-GitCommand "push -u origin main" "Failed git push"
                Write-Host "Successfully pushed 'main' to 'origin'."
            } else {
                Write-Host "[10/10] Skipping push as 'main' already exists on 'origin'."
            }

            $UserSuccess = $true

        } catch {
            $GlobalSuccess = $false

            # --- Per-User Error Handling ---
            # Check if it was a manual stop
            if ($_.Exception.Message -match "Operation manually stopped" -or $_.Exception.Message -match "中断") {
                Write-Warning "--- PROCESSING MANUALLY STOPPED for User: $UserID ---"
                $ManualStop = $true # Set global flag
            } else {
                # Log the specific failure
                Write-Warning "!!! FAILED processing User: $UserID !!!"
                Write-Warning "$($_.Exception.Message)"
                Write-Warning "User Script StackTrace: $($_.ScriptStackTrace)"
                Write-Warning "User Exception Message: $($_.Exception.Message)"
                Write-Warning "Skipping to next user due to error."
            }
        } finally {
            # This block runs whether the user succeeded or failed
            Set-Location $PSScriptRoot # Return to script root
            $UserStopwatch.Stop()
            if ($UserSuccess) {
                Write-Host "--- Successfully processed User: $UserID in $($UserStopwatch.Elapsed.TotalSeconds) seconds ---"
            }

            # If a manual stop was detected, break the foreach loop
            # MOVED: The 'if ($ManualStop) { ... break }' logic was here and caused an error.
        }

        # Check for manual stop *after* the finally block has completed
        if ($ManualStop) {
            Write-Warning "Manual stop detected. Aborting remaining users."
            break # This is now outside the 'finally' block and is valid.
        }

    } # --- END FOREACH USER ---

} catch {
    $GlobalSuccess = $false

    # --- Global Error Handling ---
    # This catches errors outside the user loop (e.g., file dialog, reading IDs)
    # or terminating errors from within the loop that weren't caught locally.

    if ($_.Exception.Message -match "Operation manually stopped" -or $_.Exception.Message -match "中断") {
        # This catches Ctrl+C during the "Get File Dialog" or "Read ID" phases
        $ManualStop = $true
    } else {
        Write-Warning "!!! AN UNEXPECTED TERMINATING ERROR OCCURRED !!!"
        Write-Warning "The script cannot continue. Full error details below:"
        Write-Warning "Exception Type: $($_.Exception.GetType().FullName)"
        Write-Warning "Exception Message: $($_.Exception.Message)"
        Write-Warning "Script StackTrace: $($_.ScriptStackTrace)"
    }

} finally {
    # --- 7. Cleanup ---
    Write-Host "------------------------------------------------------------"
    Write-Host "--- All processing finished. ---"

    if (Test-Path $WorkBaseDir) {
        Write-Host "Cleaning up work directory: $WorkBaseDir"
        try {
            Remove-Item -Recurse -Force $WorkBaseDir
            Write-Host "Work directory successfully deleted."
        } catch {
            Write-Warning "Failed to delete work directory: $WorkBaseDir"
            Write-Warning "Reason: $($_.Exception.Message)"
            Write-Warning "You may need to delete it manually."
        }
    } else {
        Write-Host "Work directory not found or already cleaned up."
    }

    $ScriptStopwatch.Stop()
    Write-Host "------------------------------------------------------------"
    if ($ManualStop) {
        Write-Warning -ForegroundColor DarkRed "SCRIPT EXECUTION WAS MANUALLY STOPPED."
    } elseif ($GlobalSuccess) {
        Write-Host -ForegroundColor DarkGreen "SCRIPT COMPLETED SUCCESSFULLY."
    } else {
        Write-Warning -ForegroundColor DarkYellow "SCRIPT COMPLETED WITH ONE OR MORE ERRORS."
    }
    Write-Host "Total execution time: $($ScriptStopwatch.Elapsed.TotalSeconds) seconds."
    Write-Host "------------------------------------------------------------"
}