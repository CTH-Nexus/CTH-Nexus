#Requires -Version 5.1
<#
.SYNOPSIS
  Generate *.json from *.default.json under .obsidian (recursively) by expanding {USER_ID},
  then (optionally) invoke Sync-ObsidianPluginsFromShare.ps1 in the same session.

.DESCRIPTION
  - Scans <vaultRoot>\.obsidian\**\*.default.json (not only plugins).
  - Output file name: *.default.json -> *.json (".default" suffix removed).
  - Replaces {USER_ID} with the last segment of %USERPROFILE% (fallback to %USERNAME%).
  - Writes as UTF-8 without BOM for plugin compatibility.
  - Existing *.json: Skip by default; overwrite with -Force; backup with -Backup (creates .bak).
  - Supports -DryRun / -WhatIf / -Confirm.
  - Finally, if Sync-ObsidianPluginsFromShare.ps1 exists, invoke it in the same session.
    * Pass -RepoRoot (vault root, i.e., parent of .obsidian if .obsidian was passed)
    * Pass through -DryRun / -Backup / -Y (auto-yes for prompts on Sync side)

.PARAMETER VaultPath
  Vault root (which contains .obsidian) or the .obsidian folder itself. Default: current directory.

.PARAMETER PickFolder
  Show FolderBrowserDialog to pick Vault root or .obsidian folder.

.PARAMETER Force
  Overwrite existing *.json generated from *.default.json.

.PARAMETER Backup
  Create *.json.bak when overwriting.

.PARAMETER DryRun
  Do not write anything. Plan only (messages show "Create/Overwrite" to preview).

.PARAMETER Y
  Auto-yes for Sync phase (equivalent to PromptMode=None on Sync side).

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File ".\.script\__DoNotTouch\Setup-Obsidian.ps1" -DryRun

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File ".\.script\__DoNotTouch\Setup-Obsidian.ps1" -Force -Backup -Y
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Position=0)]
    [string]$VaultPath = (Get-Location).Path,

    [switch]$PickFolder,
    [switch]$Force,
    [switch]$Backup,
    [switch]$DryRun,
    [switch]$Y
)

# -----------------------------
# Helpers
# -----------------------------

function Get-UserIdFromUserProfile {
    try {
        $profile = $env:USERPROFILE
        if (-not $profile) { throw "USERPROFILE is not available." }
        return (Split-Path -Leaf $profile)
    } catch {
        Write-Warning $_.Exception.Message
        if ($env:USERNAME) { return $env:USERNAME }
        throw "Failed to determine UserID."
    }
}

function Ensure-ObsidianRootPath {
    param(
        [string]$BasePath,
        [switch]$Pick
    )
    $resolved = $BasePath

    if ($Pick) {
        try {
            Add-Type -AssemblyName System.Windows.Forms | Out-Null
            $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
            $fbd.Description = "Select Vault root (contains .obsidian) or .obsidian folder"
            $fbd.ShowNewFolderButton = $false
            $null = $fbd.ShowDialog()
            if ($fbd.SelectedPath) {
                $resolved = $fbd.SelectedPath
            } else {
                throw "Folder picking was cancelled."
            }
        } catch {
            throw ("Failed to show FolderBrowserDialog: {0}" -f $_.Exception.Message)
        }
    }

    # Resolve .obsidian folder
    $obsidianPath = $null
    if (Test-Path (Join-Path $resolved ".obsidian")) {
        $obsidianPath = (Join-Path $resolved ".obsidian")
    } elseif ((Split-Path -Leaf $resolved) -eq ".obsidian") {
        $obsidianPath = $resolved
    } else {
        throw ("'.obsidian' not found under: {0}" -f $resolved)
    }

    return $obsidianPath
}

function Write-Utf8NoBom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$TargetPath,
        [Parameter(Mandatory=$true)][string]$Content
    )
    $dir = Split-Path -Parent $TargetPath
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false) # no BOM
    $sw = New-Object System.IO.StreamWriter($TargetPath, $false, $encoding)
    try {
        $sw.Write($Content)
    } finally {
        $sw.Dispose()
    }
}

function Initialize-DefaultJsons {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)][string]$ObsRoot,  # .obsidian folder path
        [switch]$Force,
        [switch]$Backup,
        [switch]$DryRun,
        [string]$VaultRoot = $null                      # optional: for placeholder expansion
    )

    $userId = Get-UserIdFromUserProfile
    Write-Host ("UserID: {0}" -f $userId) -ForegroundColor Cyan
    Write-Host ("Scan Root (.obsidian): {0}" -f $ObsRoot) -ForegroundColor Cyan

    # Find all *.default.json recursively under .obsidian
    $targets = Get-ChildItem -Path $ObsRoot -Recurse -Filter "*.default.json" -File -ErrorAction SilentlyContinue

    if (-not $targets -or $targets.Count -eq 0) {
        Write-Host "No targets (*.default.json not found)." -ForegroundColor Yellow
        return
    }

    $processed   = 0
    $skipped     = 0
    $overwritten = 0
    $created     = 0

    $tempStr = ""
    if ($MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
        $tempStr = Split-Path $MyInvocation.MyCommand.Path -Qualifier
    } else {
        $tempStr = Split-Path (Get-Location) -Qualifier
    }
    $driveLetter = $tempStr.Substring(0,1)

    foreach ($t in $targets) {
        $src = $t.FullName

        # "*.default.json" -> "*.json"
        $baseNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($t.Name)  # e.g., "settings.default"
        $noDefault     = $baseNameNoExt -replace '\.default$', ''                # e.g., "settings"
        $dstName       = "$noDefault.json"
        $dst           = Join-Path $t.DirectoryName $dstName

        # Read UTF-8 (with or without BOM)
        $raw = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)

        # Placeholder expansion (extendable)
        $new = $raw.Replace("{{USER_ID}}", $userId)
        if ($VaultRoot) {
            $new = $new.Replace("{{VAULT_ROOT}}", $VaultRoot)
        }
        $new = $new.Replace("{{DRIVE_LETTER}}", $driveLetter)

        if (Test-Path $dst) {
            if (-not $Force) {
                Write-Host ("Skip: exists -> {0}" -f $dst) -ForegroundColor DarkYellow
                $skipped++
                $processed++
                continue
            }
            if ($Backup) {
                $bak = "$dst.bak"
                try {
                    Copy-Item -Path $dst -Destination $bak -Force
                    Write-Host ("Backup: {0} -> {1}" -f $dst, $bak) -ForegroundColor Gray
                } catch {
                    Write-Warning ("Backup failed: {0}" -f $_.Exception.Message)
                }
            }
            if ($PSCmdlet.ShouldProcess($dst, "Overwrite from *.default.json")) {
                if (-not $DryRun) {
                    Write-Utf8NoBom -TargetPath $dst -Content $new
                }
                Write-Host ("Overwrite: {0}" -f $dst) -ForegroundColor Green
                $overwritten++
            }
        } else {
            if ($PSCmdlet.ShouldProcess($dst, "Create from *.default.json")) {
                if (-not $DryRun) {
                    Write-Utf8NoBom -TargetPath $dst -Content $new
                }
                Write-Host ("Create: {0}" -f $dst) -ForegroundColor Green
                $created++
            }
        }
        $processed++
    }

    Write-Host ""
    Write-Host "=== Summary (default.json expansion) ==="
    Write-Host ("Processed : {0}" -f $processed)
    Write-Host ("Created   : {0}" -f $created)
    Write-Host ("Overwrote : {0}" -f $overwritten)
    Write-Host ("Skipped   : {0}" -f $skipped)
    if ($DryRun) { Write-Host "Mode      : DryRun (no writes)" -ForegroundColor Yellow }
}

function Invoke-OptionalSyncFromShare {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)][string]$VaultOrObsPath,  # Vault root or .obsidian
        [switch]$DryRun,
        [switch]$Backup,
        [switch]$Y
    )

    try {
        # Fallback if null/empty
        if ([string]::IsNullOrWhiteSpace($VaultOrObsPath)) {
            $VaultOrObsPath = (Get-Location).Path
            Write-Host ("Info: Sync path empty; fallback to current: {0}" -f $VaultOrObsPath) -ForegroundColor DarkCyan
        }

        # Derive RepoRoot (if .obsidian was passed, use its parent)
        $repoRoot = $VaultOrObsPath
        if ((Split-Path -Leaf $repoRoot) -eq ".obsidian") {
            $repoRoot = Split-Path -Parent $repoRoot
        }

        # Script directory (v5.1-safe)
        $thisScriptDir = $PSScriptRoot
        if ([string]::IsNullOrWhiteSpace($thisScriptDir)) {
            if ($PSCommandPath) {
                $thisScriptDir = Split-Path -Parent $PSCommandPath
            } else {
                $thisScriptDir = (Get-Location).Path
            }
        }


        # Candidate locations
        $candidate1 = Join-Path $thisScriptDir "Sync-ObsidianPluginsFromShare.ps1"
        $candidate2 = Join-Path $repoRoot ".script\__DoNotTouch\Sync-ObsidianPluginsFromShare.ps1"

        $target = $null
        if (Test-Path $candidate1) {
            $target = $candidate1
        } elseif (Test-Path $candidate2) {
            $target = $candidate2
        }

        if (-not $target) {
            Write-Host "Sync script not found: Sync-ObsidianPluginsFromShare.ps1 (done)" -ForegroundColor DarkGray
            return
        }

        Write-Host ("Sync script detected: {0}" -f $target) -ForegroundColor Cyan

        if ($PSCmdlet.ShouldProcess($target, "Invoke Sync-ObsidianPluginsFromShare.ps1 (same session)")) {
            # Same-session invocation (interactive-safe)
            $invokeArgs = @{ RepoRoot = $repoRoot }
            if ($DryRun) { $invokeArgs['DryRun'] = $true }
            if ($Backup) { $invokeArgs['Backup'] = $true }
            if ($Y)      { $invokeArgs['Y']      = $true }

            & $target @invokeArgs

            Write-Host "Sync script invocation completed." -ForegroundColor Green
        }
    } catch {
        Write-Error ("Exception while invoking Sync script: {0}" -f $_.Exception.Message)
    }
}

# -----------------------------
# main
# -----------------------------
try {
    if ([string]::IsNullOrWhiteSpace($VaultPath)) { $VaultPath = (Get-Location).Path }

    $obsidianRoot = Ensure-ObsidianRootPath -BasePath $VaultPath -Pick:$PickFolder

    # Derive Vault root for placeholder {VAULT_ROOT}
    $vaultRoot = $obsidianRoot
    if ((Split-Path -Leaf $vaultRoot) -eq ".obsidian") {
        $vaultRoot = Split-Path -Parent $vaultRoot
    }

    Initialize-DefaultJsons -ObsRoot $obsidianRoot -Force:$Force -Backup:$Backup -DryRun:$DryRun -VaultRoot:$vaultRoot

    # If Sync script exists, invoke it (pass RepoRoot, DryRun, Backup, Y)
    Invoke-OptionalSyncFromShare -VaultOrObsPath $VaultPath -DryRun:$DryRun -Backup:$Backup -Y:$Y
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
