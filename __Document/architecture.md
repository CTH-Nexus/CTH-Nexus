---
tags:
  - architecture
  - Directory
title: __Document/architecture.md
---

# 📦 What's in Here?

# Architecture

```shell
$ tree -I .git -I README.md --dirsfirst -a
.
├── .script
│   └── __DoNotTouch
│       ├── hooks
│       │   ├── Collision-Check-and-Lock.ps1
│       │   ├── Pre-Commit.sh
│       │   ├── Pre-Push.ps1
│       │   ├── commit-submodules.sh
│       │   ├── handle-images.sh
│       │   ├── pre-commit
│       │   ├── pre-push
│       │   ├── rewrite-mdlink.sh
│       │   ├── sync-original.sh
│       │   └── upload-images.sh
│       ├── Clone-and-Initialize.ps1
│       ├── Create-BareRepos.ps1
│       ├── Finalize-Submodules.ps1
│       ├── Generate-Gitmodules.ps1
│       ├── Git-ConfigCheck.ps1
│       ├── Init-Submodules.ps1
│       ├── Init-UserSparseCheckout.ps1
│       ├── Register-Submodules.ps1
│       ├── RegisterSafeDirectory.ps1
│       ├── Resolve-merge-conflict.ps1
│       ├── Set-HooksPath-For-Submodules.ps1
│       ├── Setup-Obsidian.ps1
│       ├── Setup-RepoMaintenance.ps1
│       ├── SoftwareCheck.ps1
│       └── Sync-ObsidianPluginsFromShare.ps1
├── MyWork
│   ├── Daily
│   └── Misc
├── Shared
│   ├── Project
│   └── User
├── __Attachment
├── __Document
│   ├── FAQ.md
│   ├── TODO.md
│   ├── architecture.md
│   └── install.md
├── __Template
│   ├── Daily.md
│   └── Misc.md
├── .env.example
├── .gitattributes
├── .gitignore
└── LICENSE

13 directories, 35 files
```
