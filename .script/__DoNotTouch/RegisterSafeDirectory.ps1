#requires -Version 5.1
<#
Bulk register git safe.directory (PS 5.1/7).
- safe.directory は "/"（スラッシュ）統一で登録。
- UNC (\\server\share) は禁止。ドライブレターでマッピングされた絶対パスを指定。
- id_list.txt は -IdBaseDir 指定時のみ利用。未指定/未検出なら OpenFileDialog で選択可能。
- -DryRun 指定時のみ確認のみ（適用なし）。未指定時は適用モード（承認プロンプトあり）。-NoPrompt で承認なし適用。
- カテゴリA: -IdBaseDir の各ディレクトリ直下に <ID>.git を生成して登録。
- カテゴリB: -TargetDir の各パスをそのまま登録（.obsidian / チームリポジトリ等）。
#>

[CmdletBinding()]
param(
  [string[]]$IdBaseDir,   # ID展開あり（<IdBaseDir>/<ID>.git）
  [string[]]$TargetDir,   # ID展開なし（そのまま safe.directory に登録）
  [string]$IdListPath,    # ScriptDir\id_list.txt を既定（-IdBaseDir がある場合のみ解決）
  [string]$GitExe,
  [switch]$DryRun,
  [switch]$NoPrompt
)

function Write-Log {
    param(
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level,
        [string]$Message
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $color = switch ($Level) { 'INFO' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} default {'White'} }
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
}

function Load-DotEnv {
    param(
        [Parameter(Mandatory=$true)]
        [string]$EnvPath
    )
    $map = @{}
    if (-not (Test-Path -LiteralPath $EnvPath)) {
        return $map
    }
    Get-Content -LiteralPath $EnvPath -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        if ($line.StartsWith('#')) { return }
        # KEY=VALUE をパース（最初の '=' で分割）
        $i = $line.IndexOf('=')
        if ($i -lt 1) { return }
        $key = $line.Substring(0, $i).Trim()
        $val = $line.Substring($i + 1).Trim()

        # 値が "..." で囲われている場合は外す
        if ($val.StartsWith('"') -and $val.EndsWith('"')) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $map[$key] = $val
        }
    }
    return $map
}


# --- ScriptDir を決定（$PSScriptRoot 空対策） ---
$ScriptDir = $null
try {
  if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
    $ScriptDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
  }
} catch {}
if (-not $ScriptDir -or $ScriptDir -eq '') {
  if ($PSScriptRoot) { $ScriptDir = $PSScriptRoot } else { $ScriptDir = (Get-Location).Path }
}

# ===== .env 探索＆読み込み =====
$EnvCandidates = @(
    (Join-Path $ScriptDir '.env')
)
# MyVault が既に存在している場合は、そこにある .env も候補に加える（clone 前は多くの場合未存在）
$VaultPathCandidate = Join-Path $env:USERPROFILE 'MyVault'
if (Test-Path -LiteralPath $VaultPathCandidate) {
    $EnvCandidates += (Join-Path $VaultPathCandidate '.env')
}

# ★ 追加：採用された .env のパスを保持
$UsedEnvPath = $null

# 最初に存在した .env を採用
$envMap = @{}
foreach ($envPath in $EnvCandidates) {
    if (Test-Path -LiteralPath $envPath) {
        $envMap = Load-DotEnv -EnvPath $envPath
        $UsedEnvPath = $envPath   # ★ 追加：採用元を記録
        Write-Log INFO ".env を読み込みました: $envPath"
        break
    }
}

# ===== 値の統合（CLI > .env > 自動生成） =====
# .env のキー名：R_SHARE_UNC / REPO_PATH / TEAM_REPO （任意で USER_ID もサポート）
$rShareUNC_Final = if (-not [string]::IsNullOrWhiteSpace($rShareUNC)) { $rShareUNC } else { $envMap['R_SHARE_UNC'] }

# ---------------------------
# Utilities
# ---------------------------

function Assert-NonUNC([string]$p){
  if($p -and $p.StartsWith('\\')){ throw "UNC は禁止です（ドライブレターでマッピングしてください）: $p" }
}

function Read-ListFile([string]$Path){
  if(-not $Path -or -not (Test-Path -LiteralPath $Path)){
    Write-Warning "id_list.txt not found: $Path（ユーザIDベースはスキップ）"; return @()
  }
  $ids=@()
  foreach($line in Get-Content -LiteralPath $Path){
    if($null -eq $line){continue}
    $t=$line.Trim()
    if($t -eq '' -or $t.StartsWith('#')){continue}
    if($t -notmatch '^[A-Za-z0-9._-]+$'){Write-Warning "不正なID形式をスキップ: '$t'"; continue}
    $ids+= $t
  }
  return $ids
}

function AbsSlash([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){return $null}
  try{$a=[System.IO.Path]::GetFullPath($p)}catch{$a=$p}
  return $a.Replace('\','/')
}

function Mount-RDrive {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ShareUNC,

        [switch]$DryRun,

        [ValidateSet('Stop','Continue')]
        [string]$OnError = 'Stop'
    )

    function Invoke-Fail {
        param([string]$Message)
        Write-Log ERROR $Message
        if ($OnError -eq 'Stop') {
            throw $Message
        } else {
            return $false
        }
    }

    try {
        # 既存 R: の確認
        $rDrive = Get-PSDrive -Name R -ErrorAction SilentlyContinue
        if ($null -ne $rDrive) {
            Write-Log INFO "R: ドライブは既に存在します。net use 情報を表示します。"
            cmd.exe /c "net use R:" | ForEach-Object { Write-Host $_ }
            return $true
        }

        # UNC 実在確認
        Write-Log INFO "UNC 実在確認: $ShareUNC"
        if (-not (Test-Path -LiteralPath $ShareUNC)) {
            return Invoke-Fail "指定された UNC が存在しません、またはアクセスできません: $ShareUNC"
        }

        if (-not $DryRun) {
            Write-Log INFO "R: ドライブをマウントします -> $ShareUNC"
            cmd.exe /c "net use R: `"$ShareUNC`" /persistent:yes"
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                return Invoke-Fail "net use 失敗（ExitCode=$exitCode）。資格情報や到達性をご確認ください。"
            }

            # 再確認
            $rDrive2 = Get-PSDrive -Name R -ErrorAction SilentlyContinue
            if ($null -eq $rDrive2) {
                return Invoke-Fail "R: のマウントに失敗しました（net use 成功後も R: が存在しません）。"
            }

            Write-Log INFO "R: ドライブのマウントに成功しました。"
            return $true
        } else {
            Write-Log INFO "[DryRun] net use R: `"$ShareUNC`" /persistent:yes をスキップします。"
            return $true
        }
    }
    catch {
        $msg = "R ドライブ準備中に失敗: " + $_.Exception.Message
        Write-Log ERROR $msg
        if ($OnError -eq 'Stop') {
            throw
        } else {
            return $false
        }
    }
}

# 単一要素でカンマを含む配列を安全に分解（PS 5.1/7 互換）
function Normalize-StringArray([string[]]$arr) {
  if($null -eq $arr){ return @() }
  if($arr.Count -gt 1){ return $arr }         # 既に複数要素ならそのまま
  $one=$arr[0]
  if([string]::IsNullOrWhiteSpace($one)){ return @() }
  if($one.Contains(',')){
    $parts = $one.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    return ,$parts                                 # 明示的に配列を返す
  }
  return $arr
}

# -GitExe 明示は git.exe ファイルのみ受理（誤バインド防止の堅牢化）
function Find-GitExe([string]$Explicit){
  if($Explicit){
    if( (Test-Path -LiteralPath $Explicit) ){
      $item = Get-Item -LiteralPath $Explicit
      if(-not $item.PSIsContainer){
        $leaf = [System.IO.Path]::GetFileName($Explicit)
        if($leaf -and ($leaf.ToLower() -eq 'git.exe')){ return $Explicit }
      }
    }
    Write-Warning "Ignored -GitExe (not a git.exe file): $Explicit"
  }
  # 候補（順序：ユーザPortable -> スクリプト同梱 -> ユーザTools）
  $c=@()
  $c+=(Join-Path $Env:USERPROFILE 'Software\PortableGit\cmd\git.exe')
  $c+=(Join-Path $ScriptDir  'Git\cmd\git.exe')
  $c+=(Join-Path $Env:USERPROFILE 'Tools\Git\cmd\git.exe')
  # PATH fallback
  $git='git.exe'
  try{
    $v=& $git --version 2>$null
    if($LASTEXITCODE -eq 0 -and $v){ return $git }
  }catch{}
  foreach($x in $c){
    if(Test-Path -LiteralPath $x){ return $x }
  }
  throw "Git executable not found. 指定してください: -GitExe 'C:\Path\To\Git\cmd\git.exe'"
}

function Get-SafeDirs([string]$git){
  $o=& $git config --global --get-all safe.directory 2>$null
  if($LASTEXITCODE -ne 0 -or $null -eq $o){ return @() }
  $lines=@()
  if($o -is [string]){ $lines=@($o) } else { $lines=$o }
  $r=@()
  foreach($l in $lines){ $t=$l.Trim(); if($t -ne ''){ $r+= $t.Replace('\','/') } }
  return $r
}

function Pick-IdListPath(){
  try{ Add-Type -AssemblyName System.Windows.Forms | Out-Null } catch{ Write-Warning "GUIダイアログ不可"; return $null }
  $dlg=New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Title="id_list.txt を選択"; $dlg.Filter="Text (*.txt)|*.txt|All (*.*)|*.*"
  $dlg.InitialDirectory=$ScriptDir; $dlg.FileName="id_list.txt"; $dlg.Multiselect=$false
  $rs=$dlg.ShowDialog()
  if($rs -eq [System.Windows.Forms.DialogResult]::OK -and -not [string]::IsNullOrWhiteSpace($dlg.FileName)){ return $dlg.FileName }
  return $null
}

# ---------------------------
# Main
# ---------------------------
function main{
  param(
    [string[]]$IdBaseDir,[string[]]$TargetDir,[string]$IdListPath,
    [string]$GitExe,[switch]$DryRun,[switch]$NoPrompt
  )
  $ErrorActionPreference='Stop'
  try{
    # Git exe
    $git=Find-GitExe -Explicit $GitExe

    Mount-RDrive -ShareUNC $rShareUNC_Final -DryRun:$DryRun -OnError Stop

    # 受け取り配列の正規化（単一要素カンマ連結対策）
    $IdBaseDir = Normalize-StringArray $IdBaseDir
    $TargetDir = Normalize-StringArray $TargetDir

    # Validate & normalize
    $bases=@()
    if($IdBaseDir){
      foreach($b in $IdBaseDir){ Assert-NonUNC $b; $bases+= AbsSlash $b }
    }
    $targetsExplicit=@()
    if($TargetDir){
      foreach($d in $TargetDir){ Assert-NonUNC $d; $targetsExplicit+= AbsSlash $d }
    }

    # IdListPath (only if IdBaseDir exists) — フォルダが渡ってきた場合はダイアログへフォールバック
    $idPath=$null
    if($bases.Count -gt 0){
      $idPath=$IdListPath
      if(-not $idPath){ $idPath=(Join-Path $ScriptDir 'id_list.txt') }
      $needPick=$true
      if(Test-Path -LiteralPath $idPath){
        $item=Get-Item -LiteralPath $idPath
        if(-not $item.PSIsContainer){ $needPick=$false } # ファイルならそのまま
      }
      if($needPick){
        $sel=Pick-IdListPath
        if($sel){ $idPath=$sel } else { Write-Warning "id_list.txt 未検出のため、ユーザIDベースはスキップ" }
      }
    }

    # Log
    Write-Host "ScriptDir: $ScriptDir"
    Write-Host "Git: $git"
    if($bases.Count -gt 0){ Write-Host ("IdBaseDir: " + ($bases -join ',')) } else { Write-Host "IdBaseDir: (none)" }
    if($targetsExplicit.Count -gt 0){ Write-Host ("TargetDir: " + ($targetsExplicit -join ',')) } else { Write-Host "TargetDir: (none)" }
    Write-Host ("IdList: " + $idPath)
    Write-Host ("DryRun: " + $DryRun.IsPresent + "  NoPrompt: " + $NoPrompt.IsPresent)
    Write-Host ""

    # Collect targets
    $targets=@()

    # A) ID展開（<IdBaseDir>/<ID>.git）
    if($idPath -and (Test-Path -LiteralPath $idPath)){
      $ids=Read-ListFile $idPath
      if($ids.Count -gt 0){
        foreach($id in $ids){
          foreach($bd in $bases){ $targets+= AbsSlash (Join-Path $bd "$id.git") }
        }
      } else {
        Write-Warning "id_list.txt が空です"
      }
    }

    # B) 明示指定（そのまま登録）
    foreach($t in $targetsExplicit){ if($t){ $targets+= $t } }

    # 重複除去
    $targets=$targets | Where-Object { $_ -and $_ -ne '' } | Select-Object -Unique

    # Diff & apply
    $current=Get-SafeDirs $git
    Write-Host "=== Current: $($current.Count) ==="
    foreach($c in $current){ Write-Host ("  - " + $c) }
    Write-Host ""

    $toAdd=@()
    foreach($t in $targets){ if($current -contains $t){ continue } $toAdd+= $t }

    Write-Host "=== To add: $($toAdd.Count) ==="
    foreach($p in $toAdd){
      $exists = Test-Path -LiteralPath ($p -replace '/', '\')   # 存在確認のみローカル表記へ一時変換
      $mark = 'MISS'; if($exists){ $mark = 'OK' }
      Write-Host ("  + {0} [{1}]" -f $p, $mark)
    }
    Write-Host ""

    if($DryRun){
      Write-Host "DRY-RUN: 適用なし"
      Write-Host "`n=== show-origin ==="
      & $git --no-pager config --show-origin --global --get-all safe.directory
      return
    }
    if($toAdd.Count -eq 0){
      Write-Host "差分なし（追加不要）"
      Write-Host "`n=== show-origin ==="
      & $git --no-pager config --show-origin --global --get-all safe.directory
      return
    }

    if(-not $NoPrompt){
      $ans=Read-Host "Proceed to add ($($toAdd.Count)) entries? [y/N]"
      if($ans.ToLower() -ne 'y'){ Write-Host "Aborted."; return }
    }

    # --- git config for submodules ---
    & $git config --global protocol.file.allow always
    & $git config --global core.longpaths true
    foreach($p in $toAdd){
      & $git config --global --add safe.directory $p
      if($LASTEXITCODE -ne 0){ Write-Warning "Failed: $p" } else { Write-Host "Added: $p" }
    }
    # --------------------------------

    Write-Host "`n=== show-origin ==="
    & $git --no-pager config --show-origin --global --get-all safe.directory
  }catch{
    Write-Error $_
    exit 1
  }
}

# Entry
main @PSBoundParameters
