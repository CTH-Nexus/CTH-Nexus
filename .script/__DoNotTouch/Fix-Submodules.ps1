# 1. .gitmodules に定義されているすべてのサブモジュールの「キー」を取得
#    (例: submodule.Shared/User/A1253419.path)
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

# 2. 取得したキーのリストをループ処理
foreach ($key in $submoduleKeys) {
    
    # 3. キーからサブモジュール名 (例: "Shared/User/A1253419") を抽出
    $name = $key -replace "^submodule\.", "" -replace "\.path$", ""
    
    Write-Host "" # 改行
    Write-Host "--- Processing submodule: $name ---"

    # 4. .gitmodules から、そのサブモジュールの url と path を取得
    $url = git config --file .gitmodules "submodule.$name.url"
    $path = git config --file .gitmodules "submodule.$name.path"

    # 5. URLとパスが取得できたか確認
    if ([string]::IsNullOrEmpty($url) -or [string]::IsNullOrEmpty($path)) {
        Write-Warning "Could not find URL or Path for '$name'. Skipping."
        continue
    }
    
    # 6. メインの修復コマンドを実行
    Write-Host "Executing: git submodule add --force $url $path"
    
    # コマンド実行
    git submodule add --force $url $path
    
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to add submodule '$name' (Path: $path)"
    } else {
        Write-Host "Successfully registered '$name'."
    }
}

Write-Host "" # 改行
Write-Host "--- Script finished ---"
Write-Host "All submodules have been registered in the index."
Write-Host "Please run 'git commit' to finalize the changes."
