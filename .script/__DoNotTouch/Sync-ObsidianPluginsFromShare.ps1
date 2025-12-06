#Requires -Version 5.1
<#
.SYNOPSIS
  Sync distributable plugin assets (js/css/etc.) from a shared folder (.env) to .obsidian/plugins safely.

.DESCRIPTION
  - Reads .env at repo root; requires PLUGINS_SOURCE_DIR (R: drive recommended).
  - Allow-list extensions + exclude file names (default lists; can be overridden via .env).
  - Diff by SHA-256 (size pre-check). DryRun lists plan only. Default prompt per plugin (y/N).
  - Overwrite via temp file then Move-Item (pseudo-atomic). Optional .bak backup.
  - Obsidian process detection (warn unless -IgnoreLock).
  - -Y switch forces PromptMode=None (all confirmations auto-yes).
  - Works well when invoked from Setup-Obsidian.ps1 in the same session (& call).

.PARAMETER RepoRoot
  Repository root where .obsidian exists directly under. Default: current directory.

.PARAMETER DryRun
  No write. List all diffs as candidates (no confirmation).

.PARAMETER PromptMode
  Confirmation mode: PerPlugin (default) | PerFile | None.

.PARAMETER Backup
  Create .bak when overwriting.

.PARAMETER IgnoreLock
  Proceed even if Obsidian.exe is running (skip warning).

.PARAMETER Y
  Auto-yes for all confirmations (equivalent to PromptMode=None, highest priority).

.ENV KEYS
  - PLUGINS_SOURCE_DIR       : Source share root, e.g., R:\Obsidian\plugins\{USER_ID} or common path.
  - PLUGINS_EXT_ALLOW        : Comma-separated list of allowed extensions, e.g., "js,css,json,png".
  - PLUGINS_EXCLUDE_NAMES    : Comma-separated list of excluded file names, e.g., "data.json,data.default.json".
  - PLUGINS_PROMPT_MODE      : "PerPlugin" | "PerFile" | "None".
  - PLUGINS_BACKUP           : "1" to enable backup when overwriting (if -Backup not supplied).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File ".\tools\Sync-ObsidianPluginsFromShare.ps1" -RepoRoot . -DryRun

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File ".\tools\Sync-ObsidianPluginsFromShare.ps1" -RepoRoot . -Y -Backup
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$RepoRoot = (Get-Location).Path,
    [switch]$DryRun,
    [ValidateSet('PerPlugin','PerFile','None')]
    [string]$PromptMode = 'PerPlugin',
    [switch]$Backup,
    [switch]$IgnoreLock,
    [switch]$Y
)

# ---- Helpers ----

function Get-UserIdFromUserProfile {
    $profile = $env:USERPROFILE
    if (-not $profile) { throw "USERPROFILE is not available." }
    return (Split-Path -Leaf $profile)
}

function Parse-DotEnv {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw ".env not found: $Path" }

    $map = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $trim = $line.Trim()
        if ($trim -eq "" -or $trim.StartsWith("#") -or $trim.StartsWith(";")) { continue }
        # Split at the first '=' only
        $idx = $trim.IndexOf("=")
        if ($idx -lt 0) { continue }
        $key = $trim.Substring(0, $idx).Trim()
        # Trim surrounding double quotes safely using [char]34
        $val = $trim.Substring($idx + 1).Trim().Trim([char]34)
        $map[$key] = $val
    }
    return $map
}

function Expand-Placeholders {
    param([string]$Value, [string]$UserId)
    if ($null -eq $Value) { return $null }
    return $Value.Replace("{USER_ID}", $UserId)
}

function Get-PluginsRoot([string]$Root) {
    $obs = Join-Path $Root ".obsidian"
    if (-not (Test-Path $obs)) { throw ".obsidian not found: $obs" }
    $plugins = Join-Path $obs "plugins"
    if (-not (Test-Path $plugins)) { throw "plugins not found: $plugins" }
    return $plugins
}

function Get-DefaultAllowExt() {
    # Extend as needed
    return @('.js','.css','.map','.json','.ttf','.woff','.woff2','.eot','.png','.jpg','.jpeg','.gif','.svg','.webp','.ico')
}

function Get-DefaultExcludeNames() {
    return @('data.json','data.default.json')
}

function To-ExtSet([string[]]$items) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($i in $items) {
        $n = $i.Trim().ToLowerInvariant()
        if ($n -ne '') {
            if ($n.StartsWith('.')) { [void]$set.Add($n) } else { [void]$set.Add('.' + $n) }
        }
    }
    return $set
}

function To-NameSet([string[]]$items) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($i in $items) {
        $n = $i.Trim().ToLowerInvariant()
        if ($n -ne '') { [void]$set.Add($n) }
    }
    return $set
}

function Get-FileHashSha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $bytes = $sha.ComputeHash($fs)
        return -join ($bytes | ForEach-Object { $_.ToString("x2") })
    } finally { $fs.Dispose(); $sha.Dispose() }
}

function Copy-Atomic {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination,
        [switch]$Backup
    )
    $destDir = Split-Path -Parent $Destination
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

    if ($Backup -and (Test-Path $Destination)) {
        $bak = "$Destination.bak"
        try { Copy-Item -Path $Destination -Destination $bak -Force } catch { Write-Warning "Backup failed: $($_.Exception.Message)" }
    }

    $tmp = Join-Path $destDir ([System.IO.Path]::GetFileName($Destination) + ".__tmp")
    try {
        Copy-Item -Path $Source -Destination $tmp -Force
        Move-Item -Path $tmp -Destination $Destination -Force
    } finally {
        if (Test-Path $tmp) { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Is-ObsidianRunning {
    try {
        Get-Process -Name "Obsidian" -ErrorAction Stop | Out-Null
        return $true
    } catch { return $false }
}

# ---- Main ----

try {
    $pluginsRoot = Get-PluginsRoot -Root $RepoRoot
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

$userId = Get-UserIdFromUserProfile
$envPath = Join-Path $RepoRoot ".env"
$envMap  = Parse-DotEnv -Path $envPath

$srcRoot = Expand-Placeholders -Value $envMap['PLUGINS_SOURCE_DIR'] -UserId $userId
if (-not $srcRoot) { Write-Error "PLUGINS_SOURCE_DIR is not defined in .env"; exit 1 }
if (-not (Test-Path $srcRoot)) { Write-Error ("Source folder not found: {0}" -f $srcRoot); exit 1 }

# Allow/Exclude config
$allowExt = if ($envMap.ContainsKey('PLUGINS_EXT_ALLOW')) {
    To-ExtSet -items ($envMap['PLUGINS_EXT_ALLOW'] -split ',')
} else { To-ExtSet -items (Get-DefaultAllowExt) }

$excludeNames = if ($envMap.ContainsKey('PLUGINS_EXCLUDE_NAMES')) {
    To-NameSet -items ($envMap['PLUGINS_EXCLUDE_NAMES'] -split ',')
} else { To-NameSet -items (Get-DefaultExcludeNames) }

# .env overrides unless CLI already specified
if ($envMap.ContainsKey('PLUGINS_PROMPT_MODE') -and -not $PSBoundParameters.ContainsKey('PromptMode')) {
    $PromptMode = $envMap['PLUGINS_PROMPT_MODE']
}
if ($envMap.ContainsKey('PLUGINS_BACKUP') -and -not $PSBoundParameters.ContainsKey('Backup')) {
    if ($envMap['PLUGINS_BACKUP'] -eq '1') { $Backup = $true }
}

# -Y forces non-interactive
if ($Y) { $PromptMode = 'None' }

Write-Host ("UserID         : {0}" -f $userId) -ForegroundColor Cyan
Write-Host ("RepoRoot       : {0}" -f $RepoRoot) -ForegroundColor Cyan
Write-Host ("PluginsRoot    : {0}" -f $pluginsRoot) -ForegroundColor Cyan
Write-Host ("SourceRoot     : {0}" -f $srcRoot) -ForegroundColor Cyan
Write-Host ("PromptMode     : {0}" -f $PromptMode) -ForegroundColor Cyan
Write-Host ("Backup         : {0}" -f $($Backup.IsPresent)) -ForegroundColor Cyan
Write-Host ("DryRun         : {0}" -f $($DryRun.IsPresent)) -ForegroundColor Cyan
Write-Host ("AutoYes (-y)   : {0}" -f $($Y.IsPresent)) -ForegroundColor Cyan

if ((-not $IgnoreLock) -and (Is-ObsidianRunning)) {
    Write-Warning "Obsidian is running. Some files may be locked. It is recommended to close the app before syncing."
}

# List local plugin IDs
$localPluginDirs = Get-ChildItem -Path $pluginsRoot -Directory -ErrorAction SilentlyContinue
if (-not $localPluginDirs -or $localPluginDirs.Count -eq 0) {
    Write-Host "No local plugins found." -ForegroundColor Yellow
    exit 0
}

[int]$created = 0
[int]$overwritten = 0
[int]$uptodate = 0
[int]$skipped = 0
[int]$errors = 0

foreach ($p in $localPluginDirs) {
    $pluginId = $p.Name
    $srcPluginDir = Join-Path $srcRoot $pluginId
    if (-not (Test-Path $srcPluginDir)) {
        Write-Host ("[Skip] Not found on source: {0}" -f $pluginId) -ForegroundColor DarkYellow
        $skipped++
        continue
    }

    # Collect candidates recursively
    $files = Get-ChildItem -Path $srcPluginDir -Recurse -File -ErrorAction SilentlyContinue
    $plan = @() # per-file plan

    foreach ($f in $files) {
        $name = $f.Name.ToLowerInvariant()
        if ($excludeNames.Contains($name)) { continue }

        $ext = [System.IO.Path]::GetExtension($f.FullName).ToLowerInvariant()
        if (-not $allowExt.Contains($ext)) { continue }

        # relative path
        $rel = $f.FullName.Substring($srcPluginDir.Length).TrimStart('\','/')
        $dst = Join-Path $p.FullName $rel

        $action = $null
        if (Test-Path $dst) {
            $same = $false
            try {
                $lenSrc = (Get-Item $f.FullName).Length
                $lenDst = (Get-Item $dst).Length
                if ($lenSrc -eq $lenDst) {
                    $hashSrc = Get-FileHashSha256 $f.FullName
                    $hashDst = Get-FileHashSha256 $dst
                    if ($hashSrc -eq $hashDst) { $same = $true }
                }
            } catch { $same = $false }

            if ($same) { $action = "UpToDate" } else { $action = "Overwrite" }
        } else {
            $action = "Create"
        }

        $plan += [pscustomobject]@{
            Source = $f.FullName
            Dest   = $dst
            Action = $action
            Rel    = $rel
        }
    }

    $countCreate    = ($plan | Where-Object {$_.Action -eq 'Create'}).Count
    $countOverwrite = ($plan | Where-Object {$_.Action -eq 'Overwrite'}).Count
    $countUpToDate  = ($plan | Where-Object {$_.Action -eq 'UpToDate'}).Count

    if ($countCreate -eq 0 -and $countOverwrite -eq 0 -and $countUpToDate -eq 0) {
        Write-Host ("[Skip] No target files: {0}" -f $pluginId) -ForegroundColor DarkYellow
        $skipped++
        continue
    }

    if ($DryRun) {
        Write-Host ("[DryRun] {0}" -f $pluginId) -ForegroundColor Yellow
        Write-Host ("  Create   : {0}" -f $countCreate)
        Write-Host ("  Overwrite: {0}" -f $countOverwrite)
        Write-Host ("  UpToDate : {0}" -f $countUpToDate)
        foreach ($i in $plan) {
            if ($i.Action -ne 'UpToDate') {
                Write-Host ("   - {0} -> {1} [{2}]" -f $i.Rel, (Split-Path -Leaf $i.Dest), $i.Action)
            }
        }
        continue
    }

    # Confirmation
    $doApply = $false
    switch ($PromptMode) {
        'None'      { $doApply = $true }
        'PerPlugin' {
            Write-Host ("[Plan] {0}" -f $pluginId) -ForegroundColor Cyan
            Write-Host ("  Create   : {0}" -f $countCreate)
            Write-Host ("  Overwrite: {0}" -f $countOverwrite)
            Write-Host ("  UpToDate : {0}" -f $countUpToDate)
            $ans = Read-Host "Apply this plugin? (y/N)"
            if ([string]::IsNullOrWhiteSpace($ans)) { $ans = 'N' }
            if ($ans.ToUpperInvariant() -eq 'Y') { $doApply = $true }
        }
        'PerFile' { $doApply = $true } # will ask per file below
    }

    if (-not $doApply) {
        Write-Host ("[Skip] {0}" -f $pluginId) -ForegroundColor DarkYellow
        $skipped++
        continue
    }

    foreach ($i in $plan) {
        if ($i.Action -eq 'UpToDate') { $uptodate++; continue }

        if ($PromptMode -eq 'PerFile') {
            $ans = Read-Host ("Apply {0}? (y/N)" -f $i.Rel)
            if ([string]::IsNullOrWhiteSpace($ans) -or $ans.ToUpperInvariant() -ne 'Y') {
                Write-Host ("[Skip] {0}" -f $i.Rel) -ForegroundColor DarkYellow
                $skipped++
                continue
            }
        }

        try {
            if ($i.Action -eq 'Create') {
                Copy-Atomic -Source $i.Source -Destination $i.Dest -Backup:$false
                Write-Host ("[Create] {0}" -f $i.Rel) -ForegroundColor Green
                $created++
            } elseif ($i.Action -eq 'Overwrite') {
                Copy-Atomic -Source $i.Source -Destination $i.Dest -Backup:$Backup
                Write-Host ("[Overwrite] {0}" -f $i.Rel) -ForegroundColor Green
                $overwritten++
            }
        } catch {
            Write-Warning ("[Error] {0}: {1}" -f $i.Rel, $_.Exception.Message)
            $errors++
        }
    }
}

Write-Host ""
Write-Host "=== Summary ==="
Write-Host ("Created     : {0}" -f $created)
Write-Host ("Overwritten : {0}" -f $overwritten)
Write-Host ("Up-to-date  : {0}" -f $uptodate)
Write-Host ("Skipped     : {0}" -f $skipped)
Write-Host ("Errors      : {0}" -f $errors)
