---
tags:
  - readme
title: .script\README.md
---

# 📦 What's in Here?

Convenient Scripts (For Developers)

- `Generate-Gitmodules.ps1`

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
