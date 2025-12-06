<#
Clone-and-Initialize.ps1

更新点（セキュリティ／誤指定防止強化＋.env対応＋DryRun）:
  - .env を読み込み（CLI > .env > 自動生成）で最終値を決定
  - UNC 実在確認後に net use 実行（到達不可なら即停止）
  - 引数は名前付きのみ（PositionalBinding=$false）・Aliasは不使用
  - REPO_PATH は未指定なら R:\UsersVault\<%USERNAME%>.git を自動生成
  - repoPath の許可範囲を R:\UsersVault\{NAME}.git のみへ厳格化
  - teamRepo はフルパス必須 / R:\{NAME}.git のみ許可（直下1階層）、存在＆ベアRepo簡易チェック
  - net use の戻りコード／R: 再確認で異常を検知
  - ベアリポジトリ簡易検証（config/objects/refs が存在するか）
  - -DryRun では、副作用のある操作（net use / clone / remote変更 / 外部スクリプト起動）をスキップし、実行予定をログ出力

仕様（変わらず）:
  1) R: のドライブ準備（既存なら情報表示のみ、無いなら UNC 実在確認の上 net use）
  2) %USERPROFILE%\MyVault に clone (--recurse-submodules)
  3) clone 先へカレント移動
  4) upstream を追加/更新（pushUrl を DISABLE）
  5) .script\__DoNotTouch\Git-ConfigCheck.ps1 を起動（失敗で停止）
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    # Step 1: net use に渡す UNC パス（例：\\fileserver\ICS\UsersVault）
    [string]$rShareUNC,

    # Step 2: clone の対象（R:\UsersVault\{NAME}.git のみ許可）
    [string]$repoPath,

    # Step 4: upstream の対象（R:\{TEAM_REPO}.git のみ許可／直下1階層）
    [string]$teamRepo,

    # DryRun モード（副作用のある操作をスキップ）
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ===== 共通関数（先に定義） =====

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

function Assert-BareRepo {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "指定パスが存在しません: $Path"
    }
    # ベアリポジトリ簡易検証（最低限の構造）
    $hasConfig  = Test-Path -LiteralPath (Join-Path $Path 'config')
    $hasObjects = Test-Path -LiteralPath (Join-Path $Path 'objects')
    $hasRefs    = Test-Path -LiteralPath (Join-Path $Path 'refs')
    if (-not ($hasConfig -and $hasObjects -and $hasRefs)) {
        throw "ベアリポジトリではない可能性があります（config/objects/refs のいずれかが欠落）: $Path"
    }
}

function Get-UpstreamHeadBranch {
    param(
        [Parameter(Mandatory=$true)][string]$RepoPath,
        [Parameter(Mandatory=$true)][string]$GitExe
    )
    $branch = ''

    # 第一候補: ls-remote --symref upstream HEAD
    try {
        $out = & $GitExe -C "$RepoPath" ls-remote --symref upstream HEAD 2>$null
        foreach ($line in $out) {
            if ($line -match '^ref:\s+refs/heads/([^ ]+)\s+HEAD$') {
                $branch = $Matches[1].Trim()
                break
            }
        }
    } catch { }

    # 第二候補: remote show upstream
    if ([string]::IsNullOrWhiteSpace($branch)) {
        try {
            $show = & $GitExe -C "$RepoPath" remote show upstream 2>$null
            foreach ($line in $show) {
                if ($line -match 'HEAD branch:\s+(.+)$') {
                    $branch = $Matches[1].Trim()
                    break
                }
            }
        } catch { }
    }

    # フォールバック: main
    if ([string]::IsNullOrWhiteSpace($branch)) {
        $branch = 'main'
    }
    return $branch
}


# ===== .env 探索＆読み込み =====
$ScriptDir = $null
try {
  if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
    $ScriptDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
  }
} catch {}
if (-not $ScriptDir -or $ScriptDir -eq '') {
  if ($PSScriptRoot) { $ScriptDir = $PSScriptRoot } else { $ScriptDir = (Get-Location).Path }
}
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

# ユーザーIDの取得（.env に USER_ID があれば優先、なければ %USERNAME%）
$UserId = Split-Path -Leaf $env:USERPROFILE

# REPO_PATH は未指定なら自動生成：R:\UsersVault\<USER_ID>.git
$repoPath_Final = if (-not [string]::IsNullOrWhiteSpace($repoPath)) {
    $repoPath
} elseif (-not [string]::IsNullOrWhiteSpace($envMap['REPO_PATH'])) {
    $envMap['REPO_PATH']
} else {
    "R:\UsersVault\${UserId}.git"
}

$teamRepo_Final  = if (-not [string]::IsNullOrWhiteSpace($teamRepo))  { $teamRepo }  else { $envMap['TEAM_REPO'] }

# ===== 必須チェック =====
$missing = @()
if ([string]::IsNullOrWhiteSpace($rShareUNC_Final)) { $missing += 'rShareUNC (R_SHARE_UNC)' }
# repoPath_Final は自動生成されるため欠落しない想定
if ([string]::IsNullOrWhiteSpace($teamRepo_Final))  { $missing += 'teamRepo (TEAM_REPO)' }

if ($missing.Count -gt 0) {
    Write-Log ERROR ("必要な設定が不足しています。CLI引数または .env に以下を指定してください: " + ($missing -join ', '))
    exit 1
}

# ===== パターン検証（従来の ValidatePattern 相当） =====
if ($rShareUNC_Final -notmatch '^\\\\') {
    Write-Log ERROR "rShareUNC は UNC 形式である必要があります（例：\\fileserver\ICS\UsersVault）。指定値: $rShareUNC_Final"
    exit 1
}
if ($repoPath_Final -notmatch '^R:\\UsersVault\\[^\\]+\.git$') {
    Write-Log ERROR "repoPath は R:\UsersVault\{NAME}.git のみ許可です。指定値: $repoPath_Final"
    exit 1
}
if ($teamRepo_Final -notmatch '^R:\\[^\\]+\.git$') {
    Write-Log ERROR "teamRepo は R:\{TEAM_REPO}.git（直下1階層）のみ許可です。指定値: $teamRepo_Final"
    exit 1
}

# ===== PortableGit の git.exe =====
$UserIdForGit = $env:USERNAME
$GitExe = "D:\Users\$UserIdForGit\Software\PortableGit\cmd\git.exe"
if (-not (Test-Path -LiteralPath $GitExe)) {
    Write-Log ERROR "PortableGit が見つかりません: $GitExe`n期待配置: D:\Users\${UserId}\Software\PortableGit\cmd\git.exe"
    exit 1
}
Write-Log INFO "Git 実行ファイル: $GitExe"

# ===== Step 1: R ドライブの準備 =====
try {
    $rDrive = Get-PSDrive -Name R -ErrorAction SilentlyContinue
    if ($null -ne $rDrive) {
        Write-Log INFO "R: ドライブは既に存在します。net use 情報を表示します。"
        cmd.exe /c "net use R:" | ForEach-Object { Write-Host $_ }
    } else {
        Write-Log INFO "UNC 実在確認: $rShareUNC_Final"
        if (-not (Test-Path -LiteralPath $rShareUNC_Final)) {
            throw "指定された UNC が存在しません、またはアクセスできません: $rShareUNC_Final"
        }

        if (-not $DryRun) {
            Write-Log INFO "R: ドライブをマウントします -> $rShareUNC_Final"
            cmd.exe /c "net use R: `"$rShareUNC_Final`" /persistent:yes"
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                throw "net use 失敗（ExitCode=$exitCode）。資格情報や到達性をご確認ください。"
            }

            # 再確認
            $rDrive2 = Get-PSDrive -Name R -ErrorAction SilentlyContinue
            if ($null -eq $rDrive2) {
                throw "R: のマウントに失敗しました（net use 成功後も R: が存在しません）。"
            }
            Write-Log INFO "R: ドライブのマウントに成功しました。"
        } else {
            Write-Log INFO "[DryRun] net use R: `"$rShareUNC_Final`" /persistent:yes をスキップします。"
        }
    }
} catch {
    Write-Log ERROR ("R ドライブ準備中に失敗: " + $_.Exception.Message)
    exit 1
}

# ===== Step 2: MyVault へ clone =====
$VaultPath = Join-Path $env:USERPROFILE 'MyVault'

try {
    if (-not (Test-Path -LiteralPath $VaultPath)) {
        # MyVault が無い → 通常の clone
        Assert-BareRepo -Path $repoPath_Final

        if (-not $DryRun) {
            Write-Log INFO "clone を開始します（--recurse-submodules）: $repoPath_Final -> $VaultPath"
            & $GitExe -c protocol.file.allow=always clone --recurse-submodules --shallow-submodules --single-branch --jobs 4 --progress -- "file:///$repoPath_Final" "$VaultPath"
            Write-Log INFO "clone 完了。"
        } else {
            Write-Log INFO "[DryRun] ベアリポジトリ検証済み: $repoPath_Final"
            Write-Log INFO "[DryRun] 実行予定: git -c protocol.file.allow=always clone --recurse-submodules --shallow-submodules --single-branch --jobs 4 --progress -- `"file:///$repoPath_Final`" `"$VaultPath`""
        }
    }
    else {
        # MyVault が既に存在 → Repository かどうかを確認
        Write-Log WARN "MyVault は既に存在します: $VaultPath"

        $gitDir = Join-Path $VaultPath '.git'
        if (-not (Test-Path -LiteralPath $gitDir)) {
            # Repository でないフォルダが存在 → 要件どおり停止
            Write-Log ERROR "既存の MyVault は Git リポジトリではありません（.git がありません）。安全側で停止します。: $VaultPath"
            Write-Log INFO  "既存フォルダの内容（上位のみ）:"
            Get-ChildItem -LiteralPath $VaultPath -Force |
                Select-Object Mode, Length, LastWriteTime, Name | Format-Table -AutoSize
            exit 1
        }

        # 作業ツリー内かの健全性チェック
        $isWorkTree = ''
        try { $isWorkTree = (& $GitExe -C "$VaultPath" rev-parse --is-inside-work-tree 2>$null).Trim() } catch { $isWorkTree = '' }
        if ($isWorkTree -ne 'true') {
            Write-Log ERROR "既存の MyVault は Git 作業ツリーとして不正です（rev-parse=false）。安全側で停止します。: $VaultPath"
            exit 1
        }
        # origin URL を取得して、期待の個人ベアと一致するかを確認
        try { $originUrl = (& $GitExe -C "$VaultPath" remote get-url origin 2>$null).Trim() } catch { $originUrl = '' }

        if ([string]::IsNullOrWhiteSpace($originUrl)) {
            Write-Log ERROR "既存の MyVault には origin が設定されていません。期待: $repoPath_Final"
            exit 1
        }

        # ★ 比較は大文字小文字無視で、期待値は「実際に確定した $repoPath_Final」を使用
        if ($originUrl -ieq $repoPath_Final) {
            Write-Log INFO "既に目的のリポジトリが clone 済みのため、clone をスキップして続行します。"
            Write-Log INFO "origin: $originUrl"
        } else {
            Write-Log ERROR "既存 MyVault の origin が期待と不一致です。現在: $originUrl / 期待: $repoPath_Final"
            exit 1
        }
    }
} catch {
    Write-Log ERROR ("clone/既存検査 中に失敗: " + $_.Exception.Message)
    exit 1
}
# ===== Step 2.5: .env をリポジトリへ配布（コピー or 生成） =====
try {
    $RepoEnvPath = Join-Path $VaultPath '.env'

    # 採用元 .env がある場合はコピー（既存なら差分検知のみ）
    if ($UsedEnvPath -and (Test-Path -LiteralPath $UsedEnvPath)) {
        if (-not (Test-Path -LiteralPath $RepoEnvPath)) {
            if (-not $DryRun) {
                Copy-Item -LiteralPath $UsedEnvPath -Destination $RepoEnvPath
                Write-Log INFO ".env をリポジトリへコピーしました: $RepoEnvPath"
            } else {
                Write-Log INFO "[DryRun] .env をコピー予定: $UsedEnvPath -> $RepoEnvPath"
            }
        } else {
            # 既存 .env と採用元の .env を比較（ハッシュ）
            $srcHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $UsedEnvPath).Hash
            $dstHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $RepoEnvPath).Hash
            if ($srcHash -ne $dstHash) {
                Write-Log WARN "リポジトリ内の .env は既に存在し、内容が差異あり。既存を保持します: $RepoEnvPath"
                Write-Log INFO "差分を反映したい場合は、手動で更新するか、将来オプション（例：-EnvOverwrite）で上書きしてください。"
            } else {
                Write-Log INFO "リポジトリ内の .env は既に同一内容です。コピー不要。"
            }
        }
    }
    else {
        # 採用元 .env がない → 最小構成を生成（必要キーのみ）
        $minimalEnv = @()
        $minimalEnv += '# --- Generated by Clone-and-Initialize.ps1 (minimal) ---'
        $minimalEnv += "R_SHARE_UNC=$rShareUNC_Final"
        $minimalEnv += "REPO_PATH=$repoPath_Final"
        $minimalEnv += "TEAM_REPO=$teamRepo_Final"
        $minimalEnv += "USER_ID=$UserId"

        if (-not (Test-Path -LiteralPath $RepoEnvPath)) {
            if (-not $DryRun) {
                $minimalEnv | Set-Content -LiteralPath $RepoEnvPath -Encoding UTF8
                Write-Log INFO "最小構成の .env をリポジトリへ生成しました: $RepoEnvPath"
            } else {
                Write-Log INFO "[DryRun] 最小構成の .env を生成予定: $RepoEnvPath"
            }
        } else {
            Write-Log WARN "リポジトリ内に .env が既に存在するため、生成をスキップしました: $RepoEnvPath"
        }
    }
} catch {
    Write-Log ERROR (".env 配布中に失敗: " + $_.Exception.Message)
    exit 1
}

# ===== Step 3: カレントディレクトリ移動 =====
try {
    # DryRun でも、以降のログや相対参照のためにディレクトリを安定化させる
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $targetPath = $VaultPath
    if (-not (Test-Path -LiteralPath $targetPath)) {
        $targetPath = $ScriptDir
    }
    Set-Location -LiteralPath $targetPath
    Write-Log INFO "カレントディレクトリを移動しました: $targetPath"
} catch {
    Write-Log ERROR ("Set-Location 失敗: " + $_.Exception.Message)
    exit 1
}

# ===== Step 4: upstream の設定（R:\{NAME}.git のみ許可、存在＆ベア判定）=====
try {
    if (-not $DryRun) {
        # ドライブレター始まりのローカルパスなら prefix 付与
        if ($teamRepo_Final -match '^(?i)[A-Z]:') {
            $teamRepo_Final = 'file:///' + $teamRepo_Final
        }
        Assert-BareRepo -Path $teamRepo_Final
        Write-Log INFO "upstream を設定します: $teamRepo_Final"

        # 既存チェック
        $existingUpstreamUrl = ''
        try { $existingUpstreamUrl = (& $GitExe -C "$VaultPath" remote get-url upstream 2>$null) } catch { $existingUpstreamUrl = '' }

        if ([string]::IsNullOrWhiteSpace($existingUpstreamUrl)) {
            & $GitExe -C "$VaultPath" remote add upstream "$teamRepo_Final"
            Write-Log INFO "remote add upstream 実行。"
        } else {
            Write-Log WARN "upstream は既に存在しています（更新します）: $existingUpstreamUrl -> $teamRepo_Final"
            & $GitExe -C "$VaultPath" remote set-url upstream "$teamRepo_Final"
        }

        # pushUrl を DISABLE に設定（push禁止）
        & $GitExe -C "$VaultPath" remote set-url --push upstream DISABLE
        Write-Log INFO "upstream の pushUrl を DISABLE に設定しました。"
    } else {
        Write-Log INFO "[DryRun] ベアリポジトリ検証をスキップ: $teamRepo_Final"
        Write-Log INFO "[DryRun] 実行予定: git -C `"$VaultPath`" remote add/set-url upstream `"$teamRepo_Final`""
        Write-Log INFO "[DryRun] 実行予定: git -C `"$VaultPath`" remote set-url --push upstream DISABLE"
    }
} catch {
    Write-Log ERROR ("upstream 設定中に失敗: " + $_.Exception.Message)
    exit 1
}
# ===== Step 4.5: upstream を fetch して rebase で取り込む =====
try {
    # upstream の HEAD ブランチ名を取得
    $upBranch = Get-UpstreamHeadBranch -RepoPath $VaultPath -GitExe $GitExe
    Write-Log INFO "upstream の HEAD ブランチ: $upBranch"

    # 現在のローカルブランチを確認（detached HEAD を弾く）
    $currentBranch = ''
    try { $currentBranch = (& $GitExe -C "$VaultPath" rev-parse --abbrev-ref HEAD 2>$null).Trim() } catch { $currentBranch = '' }
    if ([string]::IsNullOrWhiteSpace($currentBranch) -or $currentBranch -eq 'HEAD') {
        throw "現在の HEAD がブランチではありません（detached HEAD）。rebase 前にブランチへ切り替えてください。"
    }
    Write-Log INFO "現在のローカルブランチ: $currentBranch"

    if (-not $DryRun) {
        # upstream を取得
        & $GitExe -C "$VaultPath" fetch --prune --tags upstream
        Write-Log INFO "fetch 完了: upstream（--prune --tags）"

        # upstream/<HEAD> を基準に rebase
        & $GitExe -C "$VaultPath" rebase "upstream/$upBranch"
        Write-Log INFO "rebase 完了: $currentBranch <- upstream/$upBranch"
    } else {
        Write-Log INFO "[DryRun] 実行予定: git -C `"$VaultPath`" fetch --prune --tags upstream"
        Write-Log INFO "[DryRun] 実行予定: git -C `"$VaultPath`" rebase upstream/$upBranch"
    }
} catch {
    Write-Log ERROR ("upstream からの取り込み（fetch/rebase）に失敗: " + $_.Exception.Message)
    Write-Log INFO  "対処例: `git -C `"$VaultPath`" rebase --abort` で中断できます。"
    exit 1
}

# ===== Step 4.6: サブモジュールの同期・更新（任意） =====
try {
    if (-not $DryRun) {
        & $GitExe -C "$VaultPath" submodule sync --recursive
        & $GitExe -C "$VaultPath" submodule update --init --recursive
        Write-Log INFO "サブモジュールの sync/update を実行しました。"
        & $GitExe -C "$VaultPath" -c user.name="Copilot" -c user.email="copilot@example.local" commit -m "Add: Submodules"

    } else {
        Write-Log INFO "[DryRun] 実行予定: git -C `"$VaultPath`" submodule sync --recursive"
        Write-Log INFO "[DryRun] 実行予定: git -C `"$VaultPath`" submodule update --init --recursive"
        Write-Log INFO "[DryRun] 実行予定: git -C `"$VaultPath`" commit -m `"Add: Submodules`""
    }
} catch {
    Write-Log ERROR ("サブモジュールの同期・更新に失敗: " + $_.Exception.Message)
    exit 1
}


# ===== Step 5: リポジトリ直下で複数スクリプトを順次起動（独立プロセスで実行） =====
# 実行対象を定義（順序は重要）
$PostScripts = @(
    ".script\__DoNotTouch\Git-ConfigCheck.ps1",
    ".script\__DoNotTouch\Set-HooksPath-For-Submodules.ps1",
    ".script\__DoNotTouch\Setup-Obsidian.ps1",
    ".script\__DoNotTouch\Setup-RepoMaintenance.ps1"
)

try {
    # 実行する PowerShell 実体の決定（基本は Windows PowerShell）
    $psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $psExe)) {
        throw "powershell.exe が見つかりません: $psExe"
    }

    foreach ($relPath in $PostScripts) {
        $scriptPath = Join-Path $VaultPath $relPath

        if (-not (Test-Path -LiteralPath $scriptPath)) {
            Write-Log WARN "起動対象スクリプトが見つからないためスキップします: $scriptPath"
            continue
        }
        $needsY = ($relPath -eq ".script\__DoNotTouch\Setup-Obsidian.ps1")

        if (-not $DryRun) {
            $argList = @(
                '-ExecutionPolicy', 'Bypass',
                '-NoProfile',
                '-STA',
                '-File', "`"$scriptPath`""
            )
            if ($needsY) { $argList += '-Y' }   # ← 追加（-File の後ろ）
            # 親が DryRun なら子へも DryRun 継承
            if ($DryRun) { $argList += '-DryRun' }

            $psArgs = ($argList -join ' ')
            Write-Log INFO "外部スクリプトを起動します: $scriptPath"
            Write-Log INFO "Cmd: $psExe $psArgs"

            $proc = Start-Process -FilePath $psExe `
                                  -ArgumentList $psArgs `
                                  -WorkingDirectory $VaultPath `
                                  -NoNewWindow `
                                  -Wait `
                                  -PassThru

            $exit = $proc.ExitCode
            if ($exit -ne 0) {
                throw "外部スクリプトが異常終了しました。ExitCode=$exit / Script=$scriptPath"
            }
            Write-Log INFO "外部スクリプト実行完了（ExitCode=0）: $scriptPath"
        } else {
            $dryArgs = '-ExecutionPolicy Bypass -NoProfile -STA -File "' + $scriptPath
            $dryArgs += ' -DryRun'
            if ($needsY) { $dryArgs += ' -Y' }  # 表示側も整合
            Write-Log INFO "[DryRun] 外部スクリプト起動をスキップ: $scriptPath"
            Write-Log INFO "[DryRun] 実行予定: $psExe $dryArgs"
        }
    }
} catch {
    Write-Log ERROR ("外部スクリプト起動に失敗: " + $_.Exception.Message)
    exit 1
}


Write-Log INFO "全ステップ完了。"
exit 0
