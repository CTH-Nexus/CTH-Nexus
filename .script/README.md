---
tags:
  - readme
title: .script\README.md
---

# 📦 What's in Here?

Convenient Scripts (For Developers)

- `Generate-Gitmodules.ps1`
- `Create-BareRepos.ps1`

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

## Input (sample)

```plaintext
{USER_ID}
```

## Output (sample)

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
