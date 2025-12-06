#Requires -Version 5.1
param(
  [string]$RepoRoot,
  [string]$Origin   = "origin",
  [string]$Upstream = "upstream",
  [switch]$DryRun,
  [switch]$Refresh,
  [string]$GitExe = "$env:USERPROFILE\Software\PortableGit\cmd\git.exe"
)

function G { param([string[]]$Args)
  & $GitExe -C $RepoRoot @Args 2>&1
  $global:LastExit = $LASTEXITCODE
  return $global:LastExit
}

if ($Refresh) {
  if ($DryRun) { Write-Host "[DRYRUN] fetch $Origin / $Upstream" }
  else {
    G @("fetch", $Origin)   | Out-Null
    G @("fetch", $Upstream) | Out-Null
  }
}

Write-Host "== Plan (FF保証) =="
Write-Host "1) merge --no-ff origin/main"
Write-Host "2) merge --no-ff -X theirs upstream/main"
Write-Host "3) push origin main"

if ($DryRun) {
  Write-Host "[DRYRUN] git merge --no-ff origin/main"
  Write-Host "[DRYRUN] git merge --no-ff -X theirs $Upstream/main"
  Write-Host "[DRYRUN] git push $Origin main"
} else {
  G @("checkout","main") | Out-Null

  # Step 1: origin を祖先に含める結合点（FF不可なら必ず merge が必要）
  G @("merge","--no-ff","$Origin/main") | Out-Null
  if ($global:LastExit -ne 0) { throw "merge(origin/main) 失敗。競合解消後 'git add' → 'git merge --continue'。" }

  # Step 2: 上流優先で取り込み
  G @("merge","--no-ff","-X","theirs","$Upstream/main") | Out-Null
  if ($global:LastExit -ne 0) { throw "merge(upstream/main) 失敗。競合解消後 'git add' → 'git merge --continue'。" }

  # Step 3: FF push
  G @("push",$Origin,"main") | Out-Null
  if ($global:LastExit -ne 0) { throw "push 失敗。並行push禁止や参照更新を確認のうえ再試行。" }

  Write-Host "[DONE] origin へ FF push 完了"
}
