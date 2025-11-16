Write-Host "Starting submodule registration..."
Write-Host "Rule: Skipping all paths under 'Member/'."

# 1. Get all submodule 'keys' defined in .gitmodules
try {
    $submoduleKeys = git config --file .gitmodules --name-only --get-regexp "submodule\..*\.path"
}
catch {
    Write-Error "Failed to read .gitmodules. Make sure the file exists."
    exit
}

if ($null -eq $submoduleKeys) {
    Write-Host "No submodules found in .gitmodules."
    exit
}

# 2. Loop through the list of retrieved keys
foreach ($key in $submoduleKeys) {

    # 3. Extract the submodule name (e.g., "Shared/User/{USER_ID}") from the key
    $name = $key -replace "^submodule\.", "" -replace "\.path$", ""

    Write-Host "" # Newline
    Write-Host "--- Processing submodule: $name ---"

    # 4. Get the url and path for that submodule from .gitmodules
    $url = git config --file .gitmodules "submodule.$name.url"
    $path = git config --file .gitmodules "submodule.$name.path"

    # 5. Check if URL and path were retrieved successfully
    # --- FIX: Added parentheses around the entire condition ---
    if ( [string]::IsNullOrEmpty($url) -or [string]::IsNullOrEmpty($path) ) {
        Write-Warning "Could not find URL or Path for '$name'. Skipping."
        continue
    }

    # --- 6. Exception Condition Check ---
    # Does the path start with "Member/"?
    if ($path.StartsWith("Member/")) {
        Write-Warning "SKIPPING: '$path' is under 'Member/' directory."
        continue # Skip everything under 'Member/'
    }
    # --- Check End ---

    # 7. Execute the main repair command
    Write-Host "Executing: git submodule add --force $url $path"

    # Execute command
    git submodule add --force $url $path

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to add submodule '$name' (Path: $path)"
    }
    else {
        Write-Host "Successfully registered '$name'."
    }
}

Write-Host "" # Newline
Write-Host "--- Script finished ---"
Write-Host "All non-Member submodules have been registered in the index."
Write-Host "Please run 'git commit' to finalize the changes."
