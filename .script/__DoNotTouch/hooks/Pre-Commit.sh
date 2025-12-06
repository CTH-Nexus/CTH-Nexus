# Pre-Commit.ps1 (PowerShell 5.1)
# 直列実行: ①画像退避 -> ②Markdown書き換え
# .env（repo-root 直下）で設定管理し、ログは CLI と uploads.log に出力
# 目的：.env に USER_ID が未定義／空／プレースホルダのみの場合に、%USERPROFILE% の末尾で初期値を安全に埋める

$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [string]$Message,
        [string]$RepoRoot,
        [string]$LogPath,
        [switch]$ConsoleOnly
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$timestamp] $Message"
    Write-Host $line

    # フォールバック（LogPath が空なら既定値）
    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $LogPath = "uploads.log"
    }

    if (-not $ConsoleOnly) {
        $logFile = Join-Path $RepoRoot $LogPath
        # RepoRoot は既存のパス前提（git rev-parse / Get-Location で取得）
        # ログファイルが無くても Add-Content が作成するが、ディレクトリが無い場合は失敗する。
        # RepoRoot 自体が存在することを前提にしているため、ここではディレクトリ作成は不要。
        Add-Content -LiteralPath $logFile -Value $line
    }
}

function Remove-OuterQuotes {
    param([string]$s)
    if ($null -eq $s) { return $null }
    $t = $s.Trim()
    if ($t.Length -ge 2) {
        if (($t.StartsWith('"') -and $t.EndsWith('"')) -or
            ($t.StartsWith("'") -and $t.EndsWith("'"))) {
            return $t.Substring(1, $t.Length - 2)
        }
    }
    return $t
}

function Resolve-UserId {
    param([string]$RepoRoot)

    # 1) %USERPROFILE% の末尾
    $fromEnvProfileLeaf = $null
    if ($env:USERPROFILE) {
        try {
            $fromEnvProfileLeaf = Split-Path -Leaf $env:USERPROFILE
        } catch { $fromEnvProfileLeaf = $null }
    }
    if ($fromEnvProfileLeaf -and ($fromEnvProfileLeaf.Trim() -ne '')) {
        return @{ UserId = $fromEnvProfileLeaf; Source = "USERPROFILE" }
    }

    # 2) RepoRoot から "X:\Users\<ID>\" を抽出
    $fromRepoPath = $null
    try {
        $m = [regex]::Match($RepoRoot, '^[A-Za-z]:\\Users\\([^\\]+)\\')
        if ($m.Success) { $fromRepoPath = $m.Groups[1].Value }
    } catch { $fromRepoPath = $null }
    if ($fromRepoPath -and ($fromRepoPath.Trim() -ne '')) {
        return @{ UserId = $fromRepoPath; Source = "RepoRootPath" }
    }

    # 3) whoami の右側（ドメイン\ユーザー -> ユーザー）
    $fromWhoAmI = $null
    try {
        $wa = (& whoami) 2>$null
        if ($wa) {
            $spl = $wa -split '\\'
            $fromWhoAmI = $spl[-1]
        }
    } catch { $fromWhoAmI = $null }
    if ($fromWhoAmI -and ($fromWhoAmI.Trim() -ne '')) {
        return @{ UserId = $fromWhoAmI; Source = "whoami" }
    }

    # 4) $env:USERNAME
    $fromEnvUserName = $env:USERNAME
    if ($fromEnvUserName -and ($fromEnvUserName.Trim() -ne '')) {
        return @{ UserId = $fromEnvUserName; Source = "ENV USERNAME" }
    }

    # 5) 最後の砦
    return @{ UserId = "UnknownUser"; Source = "Fallback" }
}

function Get-GitExe {
    param([Hashtable]$Cfg)
    if ($Cfg["GIT_EXE"] -and (Test-Path -LiteralPath $Cfg["GIT_EXE"])) {
        return $Cfg["GIT_EXE"]
    }
    return "git"
}

function Get-RepoRoot {
    param([string]$GitExe)
    $out = & $GitExe rev-parse --show-toplevel
    return $out.Trim()
}

function Get-HooksDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$RepoRoot,
        [Parameter(Mandatory=$true)]
        [string]$GitExe
    )

    # 第一候補: rev-parse --git-path hooks（core.hookPath を反映、未設定なら .git/hooks。通常は成功）
    $hooksPath = $null
    try {
        $out = & $GitExe -C $RepoRoot rev-parse --git-path hooks
        $hp  = ($out | Select-Object -First 1).Trim()
        if (-not [string]::IsNullOrWhiteSpace($hp)) {
            if ([System.IO.Path]::IsPathRooted($hp)) {
                $hooksPath = $hp
            } else {
                $hooksPath = Join-Path $RepoRoot $hp
            }
        }
    } catch {
        $hooksPath = $null
    }

    # 第二候補: core.hookPath を直接取得（相対なら RepoRoot 基準に絶対化）
    if ([string]::IsNullOrWhiteSpace($hooksPath)) {
        try {
            $cfg = & $GitExe -C $RepoRoot config --local --get core.hookPath
            $cfg = ($cfg | Select-Object -First 1).Trim()
            if (-not [string]::IsNullOrWhiteSpace($cfg)) {
                if ([System.IO.Path]::IsPathRooted($cfg)) {
                    $hooksPath = $cfg
                } else {
                    $hooksPath = Join-Path $RepoRoot $cfg
                }
            }
        } catch {
            # 何もしない（最終フォールバックへ）
        }
    }

    # 最終フォールバック: .git/hooks
    if ([string]::IsNullOrWhiteSpace($hooksPath)) {
        $hooksPath = Join-Path $RepoRoot ".git\hooks"
    }

    return $hooksPath
}

# Load-Env ------------------------------------------------------------

function Load-Env {
    param([string]$RepoRoot)

    $envPath = Join-Path $RepoRoot ".env"

    # 既定値
    $cfg = @{
        UPLOAD_ROOT            = "R:\Attachment"
        UPLOAD_URL_ROOT        = ""             # 未設定なら UPLOAD_ROOT を file:/// に自動変換
        USER_ID                = ""             # ここでは空。後段で初期値を設定

        IMAGE_EXTS             = ".png,.jpg,.jpeg,.gif,.bmp,.tif,.tiff,.webp"
        ATTACHMENT_ROOT        = "__Attachment"
        REWRITE_MD             = "true"
        MD_STAGED_ONLY         = "true"
        DELETE_ORIGINAL        = "true"

        COPY_MODE              = "hash"
        LARGE_FILE_MB          = "128"
        HASH_LARGE             = "false"
        ROBOCOPY_ENABLE        = "true"
        ROBOCOPY_MT            = "4"
        ROBOCOPY_J             = "true"
        ROBOCOPY_R             = "1"
        ROBOCOPY_W             = "1"
        ROBOCOPY_THRESHOLD_MB  = "16"

        LOG_PATH               = "uploads.log"
        DRY_RUN                = "false"

        GIT_EXE                = ""
    }

    # 1) .env 読込：行頭コメント／空行スキップ、key=value のみ
    if (Test-Path -LiteralPath $envPath) {
        Get-Content -LiteralPath $envPath | ForEach-Object {
            $line = $_
            if ($line -match '^\s*$' -or $line.Trim().StartsWith('#')) { return }

            $kv = $line -split '=', 2
            if ($kv.Count -ne 2) { return }

            $key = $kv[0].Trim()
            $valRaw = $kv[1]

            # 外側の単純な引用符を除去
            $val = Remove-OuterQuotes $valNoComment

            # プレースホルダ単独値は空扱い
            if ($val -match '^\s*(\{USER_ID\}|%USER_ID%|%USERNAME%|%USERPROFILE%)\s*$') {
                $val = ''
            }

            if ($key) { $cfg[$key] = $val }
        }
    }

    # 2) USER_ID の導出（必ず非空にする）
    $resolved = Resolve-UserId -RepoRoot $RepoRoot
    $resolvedUserId = $resolved.UserId
    $resolvedSource = $resolved.Source

    if ([string]::IsNullOrWhiteSpace($cfg['USER_ID'])) {
        $cfg['USER_ID'] = $resolvedUserId
        Write-Log -Message "USER_ID resolved from $resolvedSource => '$resolvedUserId'" -RepoRoot $RepoRoot -LogPath $cfg["LOG_PATH"]
    } else {
        $cfg['USER_ID'] = $cfg['USER_ID'].Trim()
    }

    # 念のため非空保証
    if ([string]::IsNullOrWhiteSpace($cfg['USER_ID'])) {
        $cfg['USER_ID'] = "UnknownUser"
        Write-Log -Message "WARN: USER_ID remained empty; forced to 'UnknownUser'" -RepoRoot $RepoRoot -LogPath $cfg["LOG_PATH"]
    }


    # 3) UPLOAD_URL_ROOT の既定化
    if (-not $cfg["UPLOAD_URL_ROOT"] -or $cfg["UPLOAD_URL_ROOT"].Trim() -eq "") {
        $cfg["UPLOAD_URL_ROOT"] = "file:///" + ($cfg["UPLOAD_ROOT"] -replace "\\","/")
    }

    # 4) LOG_PATH の再既定化（空や空白なら既定に戻す）
    if ([string]::IsNullOrWhiteSpace($cfg["LOG_PATH"])) {
        $cfg["LOG_PATH"] = "uploads.log"
    }

    return $cfg

}

# Main ---------------------------------------------------------------

function Main {
    try {
        # Git 実行ファイルの決定とリポジトリルート取得
        $git = Get-GitExe -Cfg @{}
        try { $repoRoot = Get-RepoRoot -GitExe $git } catch { $repoRoot = (Get-Location).Path }

        # 設定ロード（ここで USER_ID が初期値で必ず非空に埋まる）
        $cfg = Load-Env -RepoRoot $repoRoot

        # .env 側で GIT_EXE が見えるなら優先
        if ($cfg["GIT_EXE"]) { $git = Get-GitExe -Cfg $cfg }
        $repoRoot = Get-RepoRoot -GitExe $git

        $logPath = $cfg["LOG_PATH"]
        $dry = ($cfg["DRY_RUN"].ToLower() -eq "true")
        Write-Log -Message "BEGIN main (repo=$repoRoot, user=$($cfg['USER_ID']), dry=$dry)" -RepoRoot $repoRoot -LogPath $logPath

        # 機能スクリプトの所在（git が認識するフックディレクトリを採用）
        $hooksDir = Get-HooksDir -RepoRoot $repoRoot -GitExe $git

        $stageImageScript = Join-Path $hooksDir "StageImageEvac.ps1"
        $rewriteMdScript  = Join-Path $hooksDir "RewriteMdLinks.ps1"

        # 存在チェック
        foreach ($p in @($stageImageScript, $rewriteMdScript)) {
            if (-not (Test-Path -LiteralPath $p)) {
                Write-Log -Message "ERROR: script not found -> $p" -RepoRoot $repoRoot -LogPath $logPath -ConsoleOnly
                throw "Missing script: $p"
            }
        }

        # ① 画像退避（__Attachment 配下のステージ済み画像を R:\Attachment\{USER_ID}\<repo相対パス> へ）
        Write-Log -Message "RUN: StageImageEvac.ps1" -RepoRoot $repoRoot -LogPath $logPath
        & $stageImageScript -RepoRoot $repoRoot -GitExe $git -Cfg $cfg
        Write-Log -Message "DONE: StageImageEvac.ps1" -RepoRoot $repoRoot -LogPath $logPath

        # ② Markdown 書き換え（__Attachment 配下参照を file:///.../{USER_ID}/<repo相対> に）
        Write-Log -Message "RUN: RewriteMdLinks.ps1" -RepoRoot $repoRoot -LogPath $logPath
        & $rewriteMdScript -RepoRoot $repoRoot -GitExe $git -Cfg $cfg
        Write-Log -Message "DONE: RewriteMdLinks.ps1" -RepoRoot $repoRoot -LogPath $logPath

        Write-Log -Message "END main (OK)" -RepoRoot $repoRoot -LogPath $logPath
        exit 0
    }
    catch {
        $repoRoot = if ($repoRoot) { $repoRoot } else { (Get-Location).Path }
        Write-Log -Message ("ERROR: " + $_.Exception.Message) -RepoRoot $repoRoot -LogPath ("uploads.log") -ConsoleOnly
        throw
    }
}

# 事前初期化（catch 用の repo/cfg を確保）
$git = Get-GitExe -Cfg @{}
try { $repoRoot = Get-RepoRoot -GitExe $git } catch { $repoRoot = (Get-Location).Path }
$cfg = Load-Env -RepoRoot $repoRoot

# .env の GIT_EXE を優先反映
if ($cfg["GIT_EXE"]) { $git = Get-GitExe -Cfg $cfg }
$repoRoot = Get-RepoRoot -GitExe $git

try { Main -RepoRoot $repoRoot -Cfg $cfg -GitExe $git }
catch {
    Write-Log -Message ("ERROR(Main): " + $_.Exception.Message) -RepoRoot $repoRoot -LogPath $cfg['LOG_PATH'] -ConsoleOnly
    throw
}
