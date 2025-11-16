#requires -Version 5.1
<#
  pre-commit.ps1
  目的:
    1) ステージ済み画像（__Attachment/ 配下・SVG除外）を R:\Upload\{USER_ID}\<repo相対パス> へミラー
    2) ステージ済み .md の画像参照を file:///R:/Upload/{USER_ID}/<repo相対パス> に置換
    3) 元画像をリポジトリから削除（インデックス＆作業ツリー）
    4) リポジトリ直下 uploads.log へ記録

  最適化:
    - Robocopy が使えれば /MT（並列）と /J（大容量向け）で高速コピー（閾値で動的に選択）
    - ハッシュ検証はサイズしきい値超過時に mtime へフォールバック可能
    - ステージ済み .md のみ読込・置換・再ステージ（無駄なI/O抑制）

  設定 (.env: repo-root 直下)
    UPLOAD_ROOT=R:\Upload
    USER_ID=%USERNAME%
    IMAGE_EXTS=.png,.jpg,.jpeg,.gif,.bmp,.tif,.tiff,.webp   # ※svgは含めない
    ATTACHMENT_ROOT=__Attachment                             # この配下「のみ」対象
    REWRITE_MD=true
    MD_STAGED_ONLY=true
    DELETE_ORIGINAL=true
    LOG_PATH=uploads.log

    # コピー動作と閾値
    COPY_MODE=hash      # hash | mtime
    LARGE_FILE_MB=128   # これ以上はハッシュ負荷高→mtimeへフォールバック可
    HASH_LARGE=false    # trueなら巨大でもハッシュする（遅くなる）
    ROBOCOPY_ENABLE=true
    ROBOCOPY_MT=4       # 並列スレッド（共有やEDRを考慮し控えめ）
    ROBOCOPY_J=true     # 大容量に適した /J (unbuffered I/O)
    ROBOCOPY_R=1        # リトライ回数
    ROBOCOPY_W=1        # リトライ待ち秒
    ROBOCOPY_THRESHOLD_MB=16  # このサイズ以上は Robocopy 優先
    DRY_RUN=false

  注意:
    - Robocopy の終了コード 0〜7 は成功（差分あり/なし等）。8以上は失敗で扱う。
    - .md 置換は alt 文言維持し、"![alt](uri)" へ正しく置換。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Log([string]$msg) { Write-Host "[pre-commit] $msg" }

# --- Helpers ---------------------------------------------------------------

function Join-Norm([string]$a, [string]$b) {
  if ([string]::IsNullOrWhiteSpace($a)) { return $b }
  return (Join-Path $a $b)
}

function Ensure-Dir($p) {
  if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

function Load-DotEnv([string]$path) {
  $map = @{}
  if (-not (Test-Path $path)) { return $map }
  foreach ($line in Get-Content -LiteralPath $path) {
    $l = $line.Trim()
    if ($l -eq '' -or $l.StartsWith('#') -or $l.StartsWith(';')) { continue }
    $kv = $l -split '=', 2
    if ($kv.Count -eq 2) {
      $key = $kv[0].Trim()
      $val = $kv[1].Trim()
      $map[$key] = $val
    }
  }
  return $map
}

function Expand-EnvLike([string]$s) {
  if ($null -eq $s) { return $null }
  return ([regex]::Replace($s, '%([^%]+)%', {
    param($m)
    $name = $m.Groups[1].Value
    $v = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrEmpty($v)) { $m.Value } else { $v }
  }))
}

function HasExt($path, $exts) {
  $e = ([IO.Path]::GetExtension($path)).ToLowerInvariant()
  return $exts -contains $e
}

Add-Type -AssemblyName System.Drawing | Out-Null
function Get-ImageInfo($path) {
  $si = Get-Item -LiteralPath $path
  $sizeBytes = $si.Length
  $shaHex = $null
  try {
    $img=[System.Drawing.Image]::FromFile($path)
    $w=$img.Width; $h=$img.Height; $fmt=$img.RawFormat.Guid.ToString()
    $img.Dispose()
  } catch { $w=$null; $h=$null; $fmt='Unknown' }

  [pscustomobject]@{
    SizeBytes = $sizeBytes
    Width = $w
    Height = $h
    Format = $fmt
    Hash = $shaHex  # 後で必要なら計算
  }
}

function Compute-SHA256Hex($path) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $fs  = [IO.File]::OpenRead($path)
  try {
    $h = $sha.ComputeHash($fs)
    return -join ($h | ForEach-Object { $_.ToString('x2') })
  } finally { $fs.Dispose(); $sha.Dispose() }
}

function ToFileUri($winPath) {
  return ([Uri]::new($winPath)).AbsoluteUri
}

function Robocopy-Available() {
  try { $null = Get-Command robocopy -ErrorAction Stop; return $true }
  catch { return $false }
}

function Robocopy-File([string]$src, [string]$dstDir, [string]$fileName, [int]$mt, [bool]$useJ, [int]$r, [int]$w) {
  # robocopy <srcDir> <dstDir> <file> /COPY:DAT /R:r /W:w [/MT:n] [/J] /NFL /NDL /NP
  $srcDir = Split-Path -Parent $src
  $args = @($srcDir, $dstDir, $fileName, "/COPY:DAT", "/R:$r", "/W:$w", "/NFL", "/NDL", "/NP")
  if ($mt -gt 1) { $args += "/MT:$mt" }
  if ($useJ)     { $args += "/J" }
  $p = Start-Process -FilePath "robocopy" -ArgumentList $args -NoNewWindow -Wait -PassThru
  # robocopy の終了コード 0〜7 は成功
  if ($p.ExitCode -le 7) { return $true } else { return $false }
}

function Copy-FileOptimized([string]$src, [string]$dst, [int]$sizeMBThreshold, [bool]$enableRobocopy, [int]$mt, [bool]$useJ, [int]$r, [int]$w) {
  $si = Get-Item -LiteralPath $src
  $sizeMB = [math]::Round($si.Length / 1MB, 2)
  $dstDir = Split-Path -Parent $dst
  Ensure-Dir $dstDir

  $useRobo = $enableRobocopy -and (Robocopy-Available) -and ($sizeMB -ge $sizeMBThreshold)
  if ($useRobo) {
    $ok = Robocopy-File -src $src -dstDir $dstDir -fileName (Split-Path -Leaf $src) -mt $mt -useJ $useJ -r $r -w $w
    if ($ok) { return $true }
    # robocopy失敗時はフォールバック
  }

  Copy-Item -LiteralPath $src -Destination $dst -Force
  return $true
}

# --- Repo Context ----------------------------------------------------------

$repoRoot = (git rev-parse --show-toplevel).Trim()
Set-Location $repoRoot

# --- Load .env -------------------------------------------------------------

$defaults = @{
  UPLOAD_ROOT = 'R:\Upload'
  USER_ID = $env:USERNAME
  IMAGE_EXTS = '.png,.jpg,.jpeg,.gif,.bmp,.tif,.tiff,.webp'  # svgは含めない
  ATTACHMENT_ROOT = '__Attachment'
  REWRITE_MD = 'true'
  MD_STAGED_ONLY = 'true'
  DELETE_ORIGINAL = 'true'
  LOG_PATH = 'uploads.log'
  COPY_MODE = 'hash'        # hash | mtime
  LARGE_FILE_MB = '128'     # これ以上の巨大ファイル
  HASH_LARGE = 'false'      # trueなら巨大でもハッシュ（遅い）
  ROBOCOPY_ENABLE = 'true'
  ROBOCOPY_MT = '4'
  ROBOCOPY_J = 'true'
  ROBOCOPY_R = '1'
  ROBOCOPY_W = '1'
  ROBOCOPY_THRESHOLD_MB = '16'
  DRY_RUN = 'false'
}

$envMap = Load-DotEnv (Join-Path $repoRoot '.env')
foreach ($k in $defaults.Keys) {
  if (-not $envMap.ContainsKey($k)) { $envMap[$k] = $defaults[$k] }
}

# Expand & normalize
$UPLOAD_ROOT = Expand-EnvLike $envMap['UPLOAD_ROOT']
$USER_ID     = Expand-EnvLike $envMap['USER_ID']
$IMAGE_EXTS  = ($envMap['IMAGE_EXTS'] -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() }) | Where-Object { $_ -ne '' }
$ATTACH_ROOT = $envMap['ATTACHMENT_ROOT']
$REWRITE_MD  = ($envMap['REWRITE_MD']).ToString().ToLowerInvariant() -eq 'true'
$MD_STAGED_ONLY = ($envMap['MD_STAGED_ONLY']).ToString().ToLowerInvariant() -eq 'true'
$DELETE_ORIGINAL = ($envMap['DELETE_ORIGINAL']).ToString().ToLowerInvariant() -eq 'true'
$LOG_PATH    = if ([IO.Path]::IsPathRooted($envMap['LOG_PATH'])) { $envMap['LOG_PATH'] } else { Join-Path $repoRoot $envMap['LOG_PATH'] }
$COPY_MODE   = ($envMap['COPY_MODE']).ToString().ToLowerInvariant()
$LARGE_MB    = [int]$envMap['LARGE_FILE_MB']
$HASH_LARGE  = ($envMap['HASH_LARGE']).ToString().ToLowerInvariant() -eq 'true'
$ROBO_EN     = ($envMap['ROBOCOPY_ENABLE']).ToString().ToLowerInvariant() -eq 'true'
$ROBO_MT     = [int]$envMap['ROBOCOPY_MT']
$ROBO_J      = ($envMap['ROBOCOPY_J']).ToString().ToLowerInvariant() -eq 'true'
$ROBO_R      = [int]$envMap['ROBOCOPY_R']
$ROBO_W      = [int]$envMap['ROBOCOPY_W']
$ROBO_TH_MB  = [int]$envMap['ROBOCOPY_THRESHOLD_MB']
$DRY_RUN     = ($envMap['DRY_RUN']).ToString().ToLowerInvariant() -eq 'true'

# --- Validate share --------------------------------------------------------

if (-not (Test-Path $UPLOAD_ROOT)) {
  Log "共有パスが見つかりません: $UPLOAD_ROOT（R: を確認してください）"
  exit 1
}

# --- Collect staged --------------------------------------------------------

$staged = (git diff --cached --name-only --diff-filter=AM).Split([Environment]::NewLine) |
          Where-Object { $_ -and (Test-Path $_) }

if (-not $staged -or $staged.Count -eq 0) {
  Log "ステージ済みの変更なし。処理終了。"
  exit 0
}

# __Attachment/ 配下限定（パス区切りの違いを吸収）
function Under-Attachment([string]$repoRel, [string]$attachRoot) {
  $norm = $repoRel.Replace('/', '\').ToLowerInvariant()
  $root = $attachRoot.Replace('/', '\').ToLowerInvariant()
  return $norm.StartsWith(($root.TrimEnd('\') + '\'))
}

$imgPaths = @()
$mdPaths  = @()
foreach ($p in $staged) {
  $abs = Resolve-Path -LiteralPath $p
  $repoRel = [IO.Path]::GetRelativePath($repoRoot, $abs.Path)
  if (Under-Attachment $repoRel $ATTACH_ROOT) {
    if (HasExt $repoRel $IMAGE_EXTS) { $imgPaths += $repoRel }
    elseif (([IO.Path]::GetExtension($repoRel)).ToLowerInvariant() -eq '.md') { $mdPaths += $repoRel }
  } elseif (([IO.Path]::GetExtension($repoRel)).ToLowerInvariant() -eq '.md') {
    # .md はステージ済みでも、参照が __Attachment/ 配下のみ置換するので候補に含めてOK
    $mdPaths += $repoRel
  }
}

Log ("対象（__Attachment/ 限定）: 画像={0}件, md={1}件" -f $imgPaths.Count, $mdPaths.Count)

if ($imgPaths.Count -eq 0 -and $mdPaths.Count -eq 0) {
  Log "対象なし。処理終了。"
  exit 0
}

# --- Destination root ------------------------------------------------------

$destRoot = Join-Path $UPLOAD_ROOT $USER_ID

# --- Copy decision ---------------------------------------------------------

function Should-Copy([string]$srcAbs, [string]$dstAbs) {
  if (-not (Test-Path $dstAbs)) { return $true, $null }
  if ($COPY_MODE -eq 'mtime') {
    $si = Get-Item -LiteralPath $srcAbs; $di = Get-Item -LiteralPath $dstAbs
    $need = ($si.Length -ne $di.Length) -or ($si.LastWriteTimeUtc -gt $di.LastWriteTimeUtc)
    return $need, $null
  } else {
    # hash with large-file fallback
    $si = Get-Item -LiteralPath $srcAbs
    $sizeMB = [math]::Round($si.Length / 1MB, 2)
    if ($sizeMB -gt $LARGE_MB -and -not $HASH_LARGE) {
      # fallback to mtime
      $di = Get-Item -LiteralPath $dstAbs
      $need = ($si.Length -ne $di.Length) -or ($si.LastWriteTimeUtc -gt $di.LastWriteTimeUtc)
      return $need, $null
    }
    $sh = Compute-SHA256Hex $srcAbs
    # 既存側のハッシュは重いので必要時のみ（一致確認）
    try {
      $dh = Compute-SHA256Hex $dstAbs
    } catch { $dh = '' }
    return ($sh -ne $dh), $sh
  }
}

# --- 1) Mirror (copy) ------------------------------------------------------

$mapRepoRelToDestFull = @{}
$imgInfo = @{}
$copyResult = @{}  # repoRel -> Copied|Reused|Failed|WouldCopy|WouldReuse
foreach ($repoRel in $imgPaths) {
  $srcAbs  = Join-Path $repoRoot $repoRel
  $destAbs = Join-Path $destRoot $repoRel
  $destDir = Split-Path -Parent $destAbs
  if (-not $DRY_RUN) { Ensure-Dir $destDir }

  $info = Get-ImageInfo $srcAbs
  $needCopy, $srcHash = Should-Copy -srcAbs $srcAbs -dstAbs $destAbs

  if (-not $DRY_RUN) {
    if ($needCopy) {
      $ok = Copy-FileOptimized -src $srcAbs -dst $destAbs -sizeMBThreshold $ROBO_TH_MB -enableRobocopy $ROBO_EN -mt $ROBO_MT -useJ $ROBO_J -r $ROBO_R -w $ROBO_W
      if ($ok) { $copyResult[$repoRel] = 'Copied' } else { $copyResult[$repoRel] = 'Failed' }
    } else {
      $copyResult[$repoRel] = 'Reused'
    }
  } else {
    $copyResult[$repoRel] = if ($needCopy) { 'WouldCopy' } else { 'WouldReuse' }
  }

  if ($COPY_MODE -eq 'hash' -and $srcHash) { $info.Hash = $srcHash }
  $imgInfo[$repoRel] = $info
  $mapRepoRelToDestFull[$repoRel] = $destAbs

  Log ("Mirror: {0} -> {1} ({2}, size={3}MB)" -f $repoRel, $destAbs, $copyResult[$repoRel], [math]::Round($info.SizeBytes/1MB,2))
}

# --- 2) Rewrite staged .md only -------------------------------------------

function Rewrite-Md([string]$mdRepoRel, $map) {
  $mdAbs = Join-Path $repoRoot $mdRepoRel
  $dir   = Split-Path -Parent $mdAbs
  $raw   = Get-Content -LiteralPath $mdAbs -Raw
  $changed = $false

  # Markdown image: ![alt](path)
  $pattern = '!\[([^\]]*)\]\(([^)]+)\)'
  $new = [regex]::Replace($raw, $pattern, {
    param($m)
    $alt = $m.Groups[1].Value
    $linkRaw = $m.Groups[2].Value.Trim()

    # 引用符除去
    if ($linkRaw.StartsWith('"') -and $linkRaw.EndsWith('"')) { $linkRaw = $linkRaw.Trim('"') }
    if ($linkRaw.StartsWith("'") -and $linkRaw.EndsWith("'")) { $linkRaw = $linkRaw.Trim("'") }

    # 外部リンクは対象外
    if ($linkRaw -match '^(https?://|file://)') { return $m.Value }

    # 相対→絶対→repo相対へ
    $joined = Join-Path $dir $linkRaw
    $abs    = Resolve-Path -LiteralPath $joined -ErrorAction SilentlyContinue
    if (-not $abs) { return $m.Value }
    $repoRel = [IO.Path]::GetRelativePath($repoRoot, $abs.Path)

    # __Attachment/ 配下の画像のみ置換
    if (-not (Under-Attachment $repoRel $ATTACH_ROOT)) { return $m.Value }
    # 対象拡張子のみ
    if (-not (HasExt $repoRel $IMAGE_EXTS)) { return $m.Value }

    # ミラー済みテーブルに無ければスキップ
    if (-not $map.ContainsKey($repoRel)) { return $m.Value }

    $destFull = $map[$repoRel]
    $uri = ToFileUri $destFull
    $changed = $true
    return "![{0}]({1})" -f $alt, $uri
  })

  if ($changed -and -not $DRY_RUN) {
    Set-Content -LiteralPath $mdAbs -Value $new -Encoding utf8
    git add -- $mdRepoRel | Out-Null
  }
  return $changed
}

if ($REWRITE_MD -and $mdPaths.Count -gt 0 -and $mapRepoRelToDestFull.Count -gt 0) {
  foreach ($md in $mdPaths) {
    # ステージ済みのみ：既に $mdPaths はステージ済みを収集済み
    $did = Rewrite-Md -mdRepoRel $md -map $mapRepoRelToDestFull
    if ($did) { Log ("Rewrite & stage: {0}" -f $md) }
  }
}

# --- 3) Delete originals ---------------------------------------------------

if ($DELETE_ORIGINAL -and $imgPaths.Count -gt 0) {
  foreach ($repoRel in $imgPaths) {
    $abs = Join-Path $repoRoot $repoRel
    Log ("Remove original: {0}" -f $repoRel)
    if (-not $DRY_RUN) {
      git rm --cached --force -- $repoRel | Out-Null
      if (Test-Path $abs) { Remove-Item -LiteralPath $abs -Force }
    }
  }
}

# --- 4) uploads.log --------------------------------------------------------

try {
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss K")
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("=== $ts ===")
  foreach ($kv in $mapRepoRelToDestFull.GetEnumerator()) {
    $repoRel = $kv.Key
    $dest    = $kv.Value
    $info    = $imgInfo[$repoRel]
    $uri     = ToFileUri $dest
    $res     = $copyResult[$repoRel]
    $w = if ($info.Width) { $info.Width } else { "?" }
    $h = if ($info.Height){ $info.Height} else { "?" }
    $hash = if ($info.Hash) { $info.Hash } else { "-" }
    $sizeMB = [math]::Round($info.SizeBytes/1MB,2)
    $lines.Add(("IMG  src={0} -> dest={1}  uri={2}  hash={3}  size={4}MB  dims={5}x{6}  result={7}" -f $repoRel, $dest, $uri, $hash, $sizeMB, $w, $h, $res))
  }
   Add-Content -LiteralPath $LOG_PATH -Value ($lines -join [Environment]::NewLine)
  }
  Log ("ログ出力: $LOG_PATH")
} catch {
  Log ("ログ出力エラー: $($_.Exception.Message)")
}

Log "pre-commit 完了。"
exit 0
