---
tags:
  - readme
title: .script\README.md
---

# 📦 What's in Here?

Convenient Scripts (For Developers)

- `SoftwareCheck.ps1`
- `Generate-Gitmodules.ps1`
- `Create-BareRepos.ps1`
- `Setup-UserSparseCheckout.ps1`
- `Fix-Submodules.ps1`
- `Set-HooksPath-For-Submodules.ps1`
- `Clone-and-Initialize.ps1`
- `Git-ConfigCheck.ps1`
- `Setup-Obsidian.ps1`

## `SoftwareCheck.ps1`

Obsidian / PortableGit / VSCode のインストール状況を確認し、共有フォルダにある最新インストーラと比較して 未導入または旧バージョンなら更新する

### Usage

```powershell
# 共有フォルダを R: に割り当て（例）
subst R: "\\path\to\your\repository"

# DryRun（インストールせず計画のみ表示）
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File ".\.script\__DoNotTouch\SoftwareCheck.ps1" -DryRun

# スクリプト実行（インストーラの置いてあるパスを手動で選択する）
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File ".\.script\__DoNotTouch\SoftwareCheck.ps1"

# スクリプト実行（引数として渡すことも可能）
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA `
  -File ".\.script\__DoNotTouch\SoftwareCheck.ps1" `
  -SharedFolder "R:\path\to\your\installer\folder" `
  -DryRun
```


## `Generate-Gitmodules.ps1`

### Usage

Executing the following command will open File Explorer.
**First**, select the ID list text file as the input source.
**Next**, File Explorer will open **again** (or **similarly**) for selecting a folder.
Specify the directory where you want to place the submodules
(in this repository, **these are** `Member` and `Shared/{User,Project}`).

```powershell
subst R: "\\path\\to\\your\\repository"
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File ".\.script\__DoNotTouch\Generate-Gitmodules.ps1"
```

### Input (sample)

```plaintext
{USER_ID}
```

### Output (sample)

```ini
[submodule "/Member/{USER_ID}"]
	path = /Member/{USER_ID}
	url = R:/{USER_ID}.git
```

## `Create-BareRepos.ps1`

### Usage

Executing the following command will open File Explorer.
**Once** you select the ID list,
a repository will be created on the shared folder (`R:\`) based on that list.

```powershell
# net use R: "\\path\\to\\your\\remote\\repository"
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File ".\.script\__DoNotTouch\Create-BareRepos.ps1"
```

### Input (sample)

```plaintext
{USER_ID}
```

### Output (sample)

```powershell
# net use R: "\\path\\to\\your\\remote\\repository"
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File ".\.script\__DoNotTouch\Create-BareRepos.ps1"
--- Bare Repository Creator Script (R:\ Drive) ---
✅ ID List File: C:\Users\ningensei848\Downloads\temp\id_list.txt
STEP 2/2: Number of bare repos to create: 1
✅ Target drive 'R:' is mounted. Starting creation...
Processing {USER_ID}...  [SUCCESS] Created bare repo.

=========================================================
🎉 Bare Repository Creation Summary
Total IDs: 1
Successful Creations: 1
Failed/Skipped: 0

=========================================================
Press Enter to close the window.:
```

## `Setup-UserSparseCheckout.ps1`

This script pushes this repository,
after it has been customized for personal use, initialized, and built, to the shared folder.

Executing the following command will open File Explorer.
**Once** you select the ID list,
a repository will be created on the shared folder (`R:\UsersVault`) based on that list.

### Usage

```powershell
# net use R: "\\path\\to\\your\\remote\\repository"
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File ".\.script\__DoNotTouch\Setup-UserSparseCheckout.ps1"
```

### Input (sample)

```plaintext
{USER_ID}
```

### Output

Create `R:\UsersVault\{USER_ID}.git` (initialized) on the shared folder.

## `Fix-Submodules.ps1`

`.gitmodules` を含むリポジトリを clone する際に `--recurse-submodules` をつけなかった場合、なんか意図しない挙動になる

これを避けるため、改めて `--force` をつけて `git submodule add` する

ただし、`Member/`配下には自分のものだけを置く想定であるため、スクリプトの例外処理はせず、自身でコマンドを実行する

```shell
git submodule add --force "R:\Member\{USER_ID}.git" "Member/{USER_ID}"
```

... 本当なら `git submodule update --init --recursive` でどうにかなるはずなのだが、なぜか動かないためこのようにする必要がある

### Usage

```powershell
# net use R: "\\path\\to\\your\\remote\\repository"
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File ".\.script\__DoNotTouch\Fix-Submodules.ps1"
```

### Input (sample)

```ini
[submodule "Shared/User/{USER_ID}"]
	path = Shared/User/{USER_ID}
	url = R:/Shared/User/{USER_ID}.git

# Member 以下の記述はすべて無視される
[submodule "Member/{USER_ID}"]
	path = Member/{USER_ID}
	url = R:/Member/{USER_ID}.git
```

### Output

gitlink が生成され、サブモジュールとして追跡できるようになる

自分だけが管理する `Member/{USER_ID}` については、自身でコマンドを実行させる

```
git submodule add --force R:\Submodule\Member\{USER_ID} Member/{USER_ID}
```

## `Set-HooksPath-For-Submodules.ps1`

`.gitmodules` をもとにサブモジュールを走査し、そこに含まれる `.git/config` に対して `core.hooksPath` を指定する

### Usage

```powershell
subst R: "\\path\\to\\your\\repository"
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File ".\.script\__DoNotTouch\Set-HooksPath-For-Submodules.ps1"
```


## `Clone-and-Initialize.ps1`

### Usage

```powershell
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File ".\.script\__DoNotTouch\Clone-and-Initialize.ps1" `
  -rShareUNC "\\fileserver\to\R\Drive" `
  -repoPath "R:\UsersVault\{USER_REPO}.git" `
  -teamRepo "R:\{TEAM_REPO}.git"
```


## `Git-ConfigCheck.ps1`

### Usage

```powershell
# DryRun で確認してから実行可能
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File ".\.script\__DoNotTouch\Git-ConfigCheck.ps1"　-DryRun
# 本番
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File ".\.script\__DoNotTouch\Git-ConfigCheck.ps1"
```

## `Setup-Obsidian.ps1`

`.env.example` を参考に、`.env` を作成してから実行する

`PLUGINS_SOURCE_DIR` を、共有フォルダ上のプラグイン置き場に指定する

### Usage

```powershell
# DryRun で確認してから実行可能
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File ".\.script\__DoNotTouch\Setup-Obsidian.ps1"　-DryRun
# 本番
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File ".\.script\__DoNotTouch\Setup-Obsidian.ps1" -y
```
